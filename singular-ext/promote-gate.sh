#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "promote-gate.sh requires bash >= 4 (mapfile); install via 'brew install bash'" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SINGULAR-ext module: resolve the engine install (SINGULAR_ENGINE_HOME) or the sibling
# engine/ dir when run from a source checkout. ENGINE_BIN locates engine scripts
# (dag.sh, etc.) since this promoter no longer lives beside them.
if [[ -z "${SINGULAR_ENGINE_HOME:-}" || ! -f "$SINGULAR_ENGINE_HOME/engine/lib.sh" ]]; then
  SINGULAR_ENGINE_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
export SINGULAR_ENGINE_HOME
ENGINE_BIN="$SINGULAR_ENGINE_HOME/engine"
source "$ENGINE_BIN/lib.sh"

from_reconcile="no"
frontier_mode="no"
if_ready_mode="no"
operator_mode="no"
registers_query=""
declare -a operator_evidence=()
declare -a requested_nodes=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-reconcile)
      from_reconcile="yes"; shift ;;
    --frontier)
      frontier_mode="yes"; shift ;;
    --if-ready)
      # Named nodes with frontier (non-strict) disposition: promote when
      # registered+ready, skip silently otherwise. Used by integrate-time
      # auto-promotion (0.5.0).
      if_ready_mode="yes"; shift ;;
    --operator)
      # Legacy operator authority for kind=evaluation nodes. Schema v2 rejects
      # this artifact-unbound route unless legacyCompatibility.unboundWaivers
      # is explicitly selected; first-class human gates are the default.
      operator_mode="yes"; shift ;;
    --evidence)
      operator_evidence+=("$2"); shift 2 ;;
    --registers)
      # Registry query (0.16.0): exit 0 iff this promoter would act on NODE.
      # `singular doctor` asks the CONFIGURED promoter rather than reimplementing
      # its registry, so a project promoter answers for itself and the check can
      # never drift from the thing it describes. Answered after the registry
      # functions are defined, below; side-effect free.
      registers_query="${2:-}"; shift 2
      [[ -n "$registers_query" ]] || { echo "--registers requires a node" >&2; exit 2; } ;;
    --help|-h)
      echo "usage: $0 [--from-reconcile] [--if-ready] NODE... | [--from-reconcile] --frontier | --registers NODE [legacy: --operator --evidence REF]" >&2
      exit 0 ;;
    -*)
      echo "unknown option: $1" >&2; exit 2 ;;
    *)
      requested_nodes+=("$1"); shift ;;
  esac
done

if [[ "$frontier_mode" != "yes" && -z "$registers_query" && "${#requested_nodes[@]}" -eq 0 ]]; then
  echo "usage: $0 [--from-reconcile] [--if-ready] NODE... | [--from-reconcile] --frontier | --registers NODE [legacy: --operator --evidence REF]" >&2
  exit 2
fi

singular_ensure_state_dirs
gates_dir="${SINGULAR_GATES_DIR:-$SINGULAR_ORCH_DIR/gates}"
evidence_dir="$gates_dir/evidence"
dag_file="${SINGULAR_DAG_FILE:-$SINGULAR_ORCH_DIR/dag.v0.json}"

# --registers is a pure lookup: no target branch, no branch check, no origin
# lock, no directories created. `singular doctor` runs it against a live repo and
# must not contend with a running loop for the origin lock, nor refuse to answer
# because the operator happens to be on a feature branch.
if [[ -z "$registers_query" ]]; then
  singular_require_target_branch

  if [[ "$(singular_current_branch)" != "$SINGULAR_TARGET_BRANCH" ]]; then
    echo "refuse: current branch must be target branch $SINGULAR_TARGET_BRANCH" >&2
    exit 2
  fi

  run_id="$(singular_run_id)"
  if [[ "$from_reconcile" != "yes" ]]; then
    singular_acquire_lock "$run_id"
    trap 'singular_release_lock "$run_id"' EXIT
  fi

  mkdir -p "$gates_dir" "$evidence_dir"
fi

# Schema-v2 consumers write only the hash-bound gate-result.v1 contract.
# Pre-v2 consumers continue to write v0 so existing projects remain compatible.
gate_result_schema_id() {
  if [[ "${SINGULAR_CONFIG_SCHEMA_VERSION:-}" == "v2" ]]; then
    printf '%s\n' "singular.orchestration.gate-result.v1"
  else
    printf '%s\n' "singular.orchestration.gate-result.v0"
  fi
}

# Hash a repo-relative source artifact without following symlinks or allowing
# traversal outside the consumer repository. Files use their byte SHA-256.
# Directories use a stable framed manifest of every directory, regular file,
# and symlink (the link text itself, never its target).
gate_source_sha256() {
  local ref="$1"
  python3 - "$SINGULAR_ROOT" "$ref" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys

root_raw, ref = sys.argv[1:3]
root = pathlib.Path(root_raw).resolve()
rel = pathlib.PurePath(ref)
if (
    not ref
    or not rel.parts
    or rel.is_absolute()
    or any(part in ("", "..") for part in rel.parts)
):
    raise SystemExit(f"unsafe gate evidence ref: {ref!r}")

target = root.joinpath(*rel.parts)
cursor = root
for part in rel.parts[:-1]:
    cursor = cursor / part
    try:
        mode = cursor.lstat().st_mode
    except OSError as exc:
        raise SystemExit(f"gate evidence ref does not exist: {ref}: {exc}")
    if stat.S_ISLNK(mode):
        raise SystemExit(f"unsafe gate evidence ref traverses a symlink: {ref}")

try:
    mode = target.lstat().st_mode
except OSError as exc:
    raise SystemExit(f"gate evidence ref does not exist: {ref}: {exc}")

def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.digest()

if stat.S_ISREG(mode):
    print(file_digest(target).hex())
    raise SystemExit(0)
if stat.S_ISLNK(mode):
    digest = hashlib.sha256()
    digest.update(b"singular-symlink.v0\0")
    digest.update(os.fsencode(os.readlink(target)))
    print(digest.hexdigest())
    raise SystemExit(0)
if not stat.S_ISDIR(mode):
    raise SystemExit(f"unsupported gate evidence artifact type: {ref}")

digest = hashlib.sha256()
digest.update(b"singular-tree.v0\0")

def frame(kind, relative, payload=b""):
    body = kind + b"\0" + os.fsencode(relative) + b"\0" + payload
    digest.update(len(body).to_bytes(8, "big"))
    digest.update(body)

def visit(directory, prefix):
    with os.scandir(directory) as entries:
        ordered = sorted(entries, key=lambda item: os.fsencode(item.name))
    for entry in ordered:
        relative = entry.name if not prefix else f"{prefix}/{entry.name}"
        entry_mode = entry.stat(follow_symlinks=False).st_mode
        if stat.S_ISLNK(entry_mode):
            frame(b"L", relative, os.fsencode(os.readlink(entry.path)))
        elif stat.S_ISREG(entry_mode):
            frame(b"F", relative, file_digest(pathlib.Path(entry.path)))
        elif stat.S_ISDIR(entry_mode):
            frame(b"D", relative)
            visit(entry.path, relative)
        else:
            raise SystemExit(f"unsupported gate evidence artifact type: {ref}/{relative}")

visit(target, "")
print(digest.hexdigest())
PY
}

# A task-set ref is logical evidence rather than a filesystem path. Bind it to
# the exact ordered task ID array with canonical JSON.
gate_task_set_sha256() {
  local ref="$1" tasks_json="$2"
  python3 - "$ref" "$tasks_json" <<'PY'
import hashlib
import json
import sys

ref, tasks_raw = sys.argv[1:3]
payload = {
    "ref": ref,
    "taskIds": json.loads(tasks_raw),
}
encoded = json.dumps(
    payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
).encode("utf-8")
print(hashlib.sha256(encoded).hexdigest())
PY
}

strict_gate_report_outcome=""
strict_gate_report_sha=""

# Normalize a schema-v2 promotion command into a strict, hash-bound report.
# The command itself is responsible for writing gate-observation.v0 to the
# supplied observation ref. A missing/malformed observation or stale baseline
# is infrastructure-inconclusive and can never create a passing gate.
write_strict_gate_report() {
  # node command exit_code log_ref head_sha observation_ref report_ref
  local node="$1" command="$2" exit_code="$3" log_ref="$4" head_sha="$5"
  local observation_ref="$6" report_ref="$7"
  local task_id="${gate_evidence_tasks[0]:-}"
  if [[ ! "$task_id" =~ ^TASK-[0-9]{4,}$ ]]; then
    echo "gate promotion node=$node has no task ID suitable for strict report binding" >&2
    return 2
  fi

  local baseline_ref="" baseline_raw="${SINGULAR_GATE_BASELINE_FILE:-}"
  if [[ -z "$baseline_raw" ]]; then
    local default_baseline="docs/orchestration/gate-baselines/$node.gate-baseline.json"
    [[ -f "$SINGULAR_ROOT/$default_baseline" ]] && baseline_raw="$default_baseline"
  fi
  if [[ -n "$baseline_raw" ]]; then
    if ! baseline_ref="$(python3 - "$SINGULAR_ROOT" "$baseline_raw" <<'PY'
from pathlib import Path, PurePath
import sys

root = Path(sys.argv[1]).resolve()
raw = sys.argv[2]
candidate = Path(raw)
if candidate.is_absolute():
    target = candidate.resolve()
else:
    rel = PurePath(raw)
    if not rel.parts or any(part in ("", "..") for part in rel.parts):
        raise SystemExit(f"unsafe gate baseline ref: {raw!r}")
    target = root.joinpath(*rel.parts).resolve()
try:
    relative = target.relative_to(root)
except ValueError:
    raise SystemExit(f"gate baseline must be inside the consumer repository: {raw}")
if not target.is_file():
    raise SystemExit(f"gate baseline does not exist: {raw}")
print(relative.as_posix())
PY
)"; then
      return 2
    fi
  fi

  local -a normalize_args=(
    --task-id "$task_id"
    --run-id "$run_id"
    --head-sha "$head_sha"
    --command "$command"
    --raw-exit-code "$exit_code"
    --log-ref "$log_ref"
    --log-path "$log_ref"
    --observation "$observation_ref"
    --require-observation
    --phase integration
    --workspace-kind integration
    --output "$report_ref"
  )
  [[ -n "$baseline_ref" ]] && normalize_args+=(--baseline "$baseline_ref")

  rm -f "$SINGULAR_ROOT/$report_ref"
  if ! (cd "$SINGULAR_ROOT" && python3 "$ENGINE_BIN/gate_report.py" "${normalize_args[@]}") \
    >/dev/null; then
    return 2
  fi
  local report_path="$SINGULAR_ROOT/$report_ref" report_json
  [[ -f "$report_path" ]] || return 2
  report_json="$(<"$report_path")"
  singular_json_schema_check \
    "$report_json" \
    "$SINGULAR_ENGINE_HOME/schemas/gate-report.v0.schema.json" \
    "strict gate report" >/dev/null || return 2
  strict_gate_report_outcome="$(singular_json_field "$report_path" outcome)"
  strict_gate_report_sha="$(gate_source_sha256 "$report_ref")" || return 2
}

declare gate_node gate_source_path gate_task_ref gate_command_ref gate_upstream gate_rationale gate_completion_ref gate_requirement_mode gate_storage_proof_red_command
declare -a gate_evidence_tasks gate_required_tasks gate_missing_tasks
declare -a proof_dsn_attempts=()
declare -a gate_signature_labels gate_signature_known_task_sets gate_signature_owned_sets gate_missing_labels
declare block_node_id block_source_path block_source_desc block_rationale block_upstream
gate_task_index_json=""
promoted_total=0
blocked_total=0

gate_promoter_config() {
  local node="$1"
  gate_node="$node"
  gate_completion_ref=""
  gate_requirement_mode="tasks"
  gate_storage_proof_red_command=""
  gate_evidence_tasks=()
  gate_required_tasks=()
  gate_signature_labels=()
  gate_signature_known_task_sets=()
  gate_signature_owned_sets=()
  gate_missing_labels=()
  case "$node" in
    S0.storage_substrate_base)
      gate_completion_ref="storage_substrate_ready"
      gate_source_path="internal/storage"
      gate_task_ref="storage-substrate-base-integrated-tasks"
      gate_command_ref="storage-substrate-base-regression-command"
      gate_upstream="D0.contract"
      gate_rationale="S0.storage_substrate_base storage_substrate_ready is promoted from integrated storage substrate implementation slices plus the accepted S0 gate-result evidence, record, readiness, command-evidence, projection, and JSON-validation helpers. This authoritative record is written by L0 gate promotion after a fresh full regression command."
      gate_evidence_tasks=(
        TASK-0313 TASK-0314 TASK-0316 TASK-0318 TASK-0320 TASK-0322
        TASK-0324 TASK-0326 TASK-0328 TASK-0330 TASK-0332 TASK-0334
      )
      gate_required_tasks=(
        "${gate_evidence_tasks[@]}"
        TASK-0336 TASK-0338 TASK-0340 TASK-0342 TASK-0344 TASK-0346 TASK-0348
      )
      ;;
    D1.storage_spec)
      gate_completion_ref="storage_spec_complete"
      gate_source_path="internal/artifact"
      gate_task_ref="storage-spec-integrated-tasks"
      gate_command_ref="storage-spec-regression-command"
      gate_upstream="D1.contract"
      gate_rationale="D1.storage_spec storage_spec_complete is promoted from integrated artifact storage_spec implementation slices plus the accepted D1 storage-spec completion, gate-result evidence, record, readiness, command-evidence, and document-projection helpers. This authoritative record is written by L0 gate promotion after a fresh full regression command."
      gate_evidence_tasks=(
        TASK-0315 TASK-0317 TASK-0319 TASK-0321 TASK-0323 TASK-0325
        TASK-0327 TASK-0329 TASK-0331 TASK-0333 TASK-0335 TASK-0337
      )
      gate_required_tasks=(
        "${gate_evidence_tasks[@]}"
        TASK-0339 TASK-0341 TASK-0343 TASK-0345 TASK-0347 TASK-0349
      )
      ;;
    D1.storage_proof)
      gate_completion_ref="storage_proof_complete"
      gate_source_path="internal/artifact"
      gate_task_ref="durable-artifact-repository-proof-task"
      gate_command_ref="storage-proof-regression-command"
      gate_upstream="D1.storage_spec S0.storage_substrate_base"
      gate_rationale="D1.storage_proof storage_proof_complete is promoted from the integrated durable artifact repository proof in TASK-0368. That task implements and tests a real PostgreSQL-backed metadata repository plus content-addressed blob payload round trip: write artifact metadata plus payload, recreate database/blob handles, read back by immutable artifact-version ref, verify content hash and blob metadata invariants, and reject conflicting rewrites. This authoritative record supersedes the prior blocked gate after a fresh full regression command."
      gate_evidence_tasks=(TASK-0368)
      gate_required_tasks=("${gate_evidence_tasks[@]}")
      ;;
    D2.storage_proof)
      gate_completion_ref="storage_proof_complete"
      gate_source_path="internal/workflow"
      gate_task_ref="durable-workflow-repository-proof-task"
      gate_command_ref="storage-proof-regression-command"
      gate_upstream="D2.storage_spec D1.storage_proof"
      gate_rationale="D2.storage_proof storage_proof_complete is promoted from the integrated durable workflow repository proof in TASK-0470. That task implements and tests a real PostgreSQL-backed metadata store plus content-addressed blob payload round trip for workflow-owned records: write a workflow template, an immutable template version bound to its content-addressed definition payload, a workflow run, and ordered node runs; recreate the database and blob handles; read every record back by exact immutable ref; and verify content hashes, record identity, node-run ordering, ref-boundary rejection, and immutable rewrite rejection across the restart. This authoritative record supersedes the prior blocked gate after a fresh full regression command."
      gate_evidence_tasks=(TASK-0470)
      gate_required_tasks=("${gate_evidence_tasks[@]}")
      ;;
    D1.service)
      gate_completion_ref="service_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/artifact"
      gate_task_ref="service-closeout-integrated-capability-tasks"
      gate_command_ref="service-closeout-regression-command"
      gate_upstream="D1.storage_proof"
      gate_rationale="D1.service service_complete is promoted from integrated artifact service runtime closeout slices proving alias lifecycle-state lookup, collection member-version lookup, collection completeness lookup, and required-member coverage behavior, plus a fresh full regression command. Capability signatures are resolved by owned files so an integrated duplicate slice can satisfy the predicate without requiring duplicate proof churn."
      gate_signature_labels=(
        "alias lifecycle-state runtime query"
        "collection member-version runtime query"
        "collection completeness runtime query"
        "collection required-member coverage runtime check"
      )
      gate_signature_known_task_sets=(
        "TASK-0435 TASK-0451"
        "TASK-0436 TASK-0444"
        "TASK-0437 TASK-0445"
        "TASK-0438 TASK-0446"
      )
      gate_signature_owned_sets=(
        "internal/artifact/service_runtime_alias_lifecycle_state_lookup.go|internal/artifact/service_runtime_alias_lifecycle_state_lookup_test.go"
        "internal/artifact/service_runtime_collection_member_lookup.go|internal/artifact/service_runtime_collection_member_lookup_test.go"
        "internal/artifact/service_runtime_collection_completeness_lookup.go|internal/artifact/service_runtime_collection_completeness_lookup_test.go"
        "internal/artifact/service_runtime_collection_required_coverage.go|internal/artifact/service_runtime_collection_required_coverage_test.go"
      )
      ;;
    D2.service)
      gate_completion_ref="service_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/workflow"
      gate_task_ref="service-closeout-integrated-capability-tasks"
      gate_command_ref="service-closeout-regression-command"
      gate_upstream="D2.storage_proof D1.service"
      gate_rationale="D2.service service_complete is promoted from the integrated workflow service runtime closeout slices covering fixed template publication, fixed workflow bootstrap and snapshot, run instantiation, initial node run materialization, run and output snapshots and projection, artifact output/input lookups, node-run lookup, terminal snapshot, run status events, and runtime conformance, plus a fresh full regression command. Capability signatures are resolved by owned files so an integrated duplicate slice can satisfy the predicate without requiring duplicate proof churn; the gate promotes only once every required workflow service capability is integrated."
      gate_signature_labels=(
        "workflow fixed template publication runtime service"
        "workflow fixed workflow bootstrap runtime service"
        "workflow fixed workflow snapshot runtime service"
        "workflow run instantiation runtime service"
        "workflow initial node run persistence runtime service"
        "workflow run snapshot runtime service"
        "workflow run output projection runtime service"
        "workflow output artifact lookup runtime service"
        "workflow input artifact lookup runtime service"
        "workflow node run lookup runtime service"
        "workflow node run terminal snapshot runtime service"
        "workflow run status event runtime service"
        "workflow runtime service conformance"
      )
      gate_signature_known_task_sets=(
        "TASK-0471"
        "TASK-0479"
        "TASK-0481"
        "TASK-0472"
        "TASK-0475"
        "TASK-0476"
        "TASK-0485"
        "TASK-0489"
        "TASK-0495"
        "TASK-0496"
        "TASK-0484"
        "TASK-0488"
        "TASK-0492"
      )
      gate_signature_owned_sets=(
        "internal/workflow/service_fixed_template_publication.go|internal/workflow/service_fixed_template_publication_test.go"
        "internal/workflow/service_fixed_workflow_bootstrap.go|internal/workflow/service_fixed_workflow_bootstrap_test.go"
        "internal/workflow/service_fixed_workflow_snapshot.go|internal/workflow/service_fixed_workflow_snapshot_test.go"
        "internal/workflow/service_run_instantiation.go|internal/workflow/service_run_instantiation_test.go"
        "internal/workflow/service_initial_node_run_persistence.go|internal/workflow/service_initial_node_run_persistence_test.go"
        "internal/workflow/service_run_snapshot.go|internal/workflow/service_run_snapshot_test.go"
        "internal/workflow/service_run_output_projection.go|internal/workflow/service_run_output_projection_test.go"
        "internal/workflow/service_output_artifact_lookup.go|internal/workflow/service_output_artifact_lookup_test.go"
        "internal/workflow/service_input_artifact_lookup.go|internal/workflow/service_input_artifact_lookup_test.go"
        "internal/workflow/service_node_run_lookup.go|internal/workflow/service_node_run_lookup_test.go"
        "internal/workflow/service_node_run_terminal_snapshot.go|internal/workflow/service_node_run_terminal_snapshot_test.go"
        "internal/workflow/service_workflow_run_status_event.go|internal/workflow/service_workflow_run_status_event_test.go"
        "internal/workflow/service_runtime.go|internal/workflow/service_runtime_test.go"
      )
      ;;
    D2.contract)
      gate_completion_ref="contract_complete"
      gate_source_path="internal/workflow"
      gate_task_ref="workflow-contract-integrated-tasks"
      gate_command_ref="workflow-contract-regression-command"
      gate_upstream="D1.contract"
      gate_rationale="D2.contract contract_complete is promoted from the integrated workflow contract slices (TASK-0019 through TASK-0048) covering workflow templates, immutable template versions, workflow runs, node runs, and role contracts, plus a fresh regression command. This applies the same completion standard as the D1.contract precedent — integrated contract slices proven by a fresh test — using a stricter full-tree regression (go build, go vet, and go test across all packages) appropriate to workflow's cross-package dependencies on artifact and kernel. It does not require the optional gate-result descriptor or readiness validator tasks, which are not load-bearing for contract completeness. This authoritative record is written by L0 gate promotion."
      gate_evidence_tasks=(
        TASK-0019 TASK-0020 TASK-0021 TASK-0022 TASK-0023 TASK-0024
        TASK-0025 TASK-0026 TASK-0027 TASK-0028 TASK-0029 TASK-0030
        TASK-0031 TASK-0032 TASK-0033 TASK-0034 TASK-0035 TASK-0036
        TASK-0037 TASK-0038 TASK-0039 TASK-0040 TASK-0041 TASK-0042
        TASK-0043 TASK-0044 TASK-0045 TASK-0046 TASK-0047 TASK-0048
      )
      gate_required_tasks=("${gate_evidence_tasks[@]}")
      ;;
    D3.contract)
      gate_completion_ref="contract_complete"
      gate_source_path="internal/binding"
      gate_task_ref="binding-contract-integrated-tasks"
      gate_command_ref="binding-contract-regression-command"
      gate_upstream="D2.contract"
      gate_rationale="D3.contract contract_complete is promoted from the integrated binding contract slices (TASK-0049 through TASK-0071) plus the resolved dispatch role continuation closeout in TASK-0369, covering workspace binding, context pack body/materialization, resolved dispatch binding, role/tool/context/workspace conformance, dispatch readiness, and static continuation-policy conformance to the upstream role contract declaration. This authoritative record is written by L0 gate promotion after a fresh full-tree regression command."
      gate_evidence_tasks=(
        TASK-0049 TASK-0050 TASK-0051 TASK-0052 TASK-0053 TASK-0054
        TASK-0055 TASK-0056 TASK-0057 TASK-0058 TASK-0059 TASK-0060
        TASK-0061 TASK-0062 TASK-0063 TASK-0064 TASK-0065 TASK-0066
        TASK-0067 TASK-0068 TASK-0069 TASK-0070 TASK-0071 TASK-0369
      )
      gate_required_tasks=("${gate_evidence_tasks[@]}")
      ;;
    D4.contract)
      gate_completion_ref="contract_complete"
      gate_source_path="internal/dispatch"
      gate_task_ref="dispatch-contract-integrated-tasks"
      gate_command_ref="dispatch-contract-regression-command"
      gate_upstream="D3.contract"
      gate_rationale="D4.contract contract_complete is promoted from the integrated dispatch contract slices (TASK-0072 through TASK-0096), covering dispatch objectives, attempts, tool invocations, side effects, telemetry, provider sessions, continuation metadata, dispatch trees, output protocol, redaction/sealing, agent dispatch construction/projection, child dispatches, usage rollups, terminal records, output coverage, and execution reconstruction. This authoritative record is written by L0 gate promotion after a fresh full-tree regression command."
      gate_evidence_tasks=(
        TASK-0072 TASK-0073 TASK-0074 TASK-0075 TASK-0076 TASK-0077
        TASK-0078 TASK-0079 TASK-0080 TASK-0081 TASK-0082 TASK-0083
        TASK-0084 TASK-0085 TASK-0086 TASK-0087 TASK-0088 TASK-0089
        TASK-0090 TASK-0091 TASK-0092 TASK-0093 TASK-0094 TASK-0095
        TASK-0096
      )
      gate_required_tasks=("${gate_evidence_tasks[@]}")
      ;;
    D5.contract)
      gate_completion_ref="contract_complete"
      gate_source_path="internal/evidence"
      gate_task_ref="evidence-contract-integrated-tasks"
      gate_command_ref="evidence-contract-regression-command"
      gate_upstream="D4.contract"
      gate_rationale="D5.contract contract_complete is promoted from the integrated evidence contract slices (TASK-0097 through TASK-0131), covering evidence item validation, evidence coverage and bundles, finding sets and finding history, policy evaluation records, decision and gate-decision bodies, decision effects for lifecycle/facet/relation/route/release/recovery/promotion/waiver outcomes, artifact disposition commands, and consistency projections. This authoritative record is written by L0 gate promotion after a fresh full-tree regression command."
      gate_evidence_tasks=(
        TASK-0097 TASK-0098 TASK-0099 TASK-0100 TASK-0101 TASK-0102
        TASK-0103 TASK-0104 TASK-0105 TASK-0106 TASK-0107 TASK-0108
        TASK-0109 TASK-0110 TASK-0111 TASK-0112 TASK-0113 TASK-0114
        TASK-0115 TASK-0116 TASK-0117 TASK-0118 TASK-0119 TASK-0120
        TASK-0121 TASK-0122 TASK-0123 TASK-0124 TASK-0125 TASK-0126
        TASK-0127 TASK-0128 TASK-0129 TASK-0130 TASK-0131
      )
      gate_required_tasks=("${gate_evidence_tasks[@]}")
      ;;
    D6.contract)
      gate_completion_ref="contract_complete"
      gate_source_path="internal/recovery"
      gate_task_ref="recovery-contract-integrated-tasks"
      gate_command_ref="recovery-contract-regression-command"
      gate_upstream="D5.contract"
      gate_rationale="D6.contract contract_complete is promoted from the integrated recovery contract slices (TASK-0132 through TASK-0171), covering recovery actions, eligibility, attempts, replay vocabulary, replay request/result records, idempotency, plan and attempt constructors, replay input and deviation consistency, action semantics, candidate construction, eligibility evaluation, attempt outcome consistency, and replay reconstruction bundles. This authoritative record is written by L0 gate promotion after a fresh full-tree regression command."
      gate_evidence_tasks=(
        TASK-0132 TASK-0133 TASK-0134 TASK-0135 TASK-0136 TASK-0137
        TASK-0138 TASK-0139 TASK-0140 TASK-0141 TASK-0142 TASK-0143
        TASK-0144 TASK-0145 TASK-0146 TASK-0147 TASK-0148 TASK-0149
        TASK-0150 TASK-0151 TASK-0152 TASK-0153 TASK-0154 TASK-0155
        TASK-0156 TASK-0157 TASK-0158 TASK-0159 TASK-0160 TASK-0161
        TASK-0162 TASK-0163 TASK-0164 TASK-0165 TASK-0166 TASK-0167
        TASK-0168 TASK-0169 TASK-0170 TASK-0171
      )
      gate_required_tasks=("${gate_evidence_tasks[@]}")
      ;;
    D7.contract)
      gate_completion_ref="contract_complete"
      gate_source_path="internal/scheduler"
      gate_task_ref="scheduler-contract-integrated-tasks"
      gate_command_ref="scheduler-contract-regression-command"
      gate_upstream="D6.contract"
      gate_rationale="D7.contract contract_complete is promoted from the integrated scheduler contract slices (TASK-0172 through TASK-0312), covering scheduler work items, leases, idempotency, outbox delivery, reconciliation cursors, gate waits, retry schedules, recovery triggers, stale-artifact invalidation, run advancement, reconstruction bundles, command preflight, result envelopes, completed-work projections, and reconciliation bundles. This authoritative record is written by L0 gate promotion after a fresh full-tree regression command."
      gate_evidence_tasks=()
      local n
      for n in $(seq 172 312); do
        gate_evidence_tasks+=("$(printf 'TASK-%04d' "$n")")
      done
      gate_required_tasks=("${gate_evidence_tasks[@]}")
      ;;
    D2.storage_spec)
      gate_completion_ref="storage_spec_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/workflow"
      gate_task_ref="workflow-storage-spec-integrated-capability-tasks"
      gate_command_ref="workflow-storage-spec-regression-command"
      gate_upstream="D2.contract D1.storage_spec"
      gate_rationale="D2.storage_spec storage_spec_complete is promoted from integrated workflow storage-spec closeout slices proving record coverage, materialization path, exact ref boundary, and authority boundary behavior, plus a fresh full regression command. Capability signatures are resolved by owned files so duplicate parked slices do not create duplicate proof churn."
      gate_signature_labels=(
        "workflow storage record coverage specification"
        "workflow storage materialization path specification"
        "workflow storage exact ref boundary specification"
        "workflow storage authority boundary specification"
      )
      gate_signature_known_task_sets=(
        "TASK-0439 TASK-0447"
        "TASK-0440 TASK-0448"
        "TASK-0441 TASK-0449"
        "TASK-0442 TASK-0450"
      )
      gate_signature_owned_sets=(
        "internal/workflow/storage_record_coverage_spec.go|internal/workflow/storage_record_coverage_spec_test.go"
        "internal/workflow/storage_materialization_path_spec.go|internal/workflow/storage_materialization_path_spec_test.go"
        "internal/workflow/storage_exact_ref_boundary_spec.go|internal/workflow/storage_exact_ref_boundary_spec_test.go"
        "internal/workflow/storage_authority_boundary_spec.go|internal/workflow/storage_authority_boundary_spec_test.go"
      )
      ;;
    D3.storage_spec)
      gate_completion_ref="storage_spec_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/binding"
      gate_task_ref="binding-storage-spec-integrated-capability-tasks"
      gate_command_ref="binding-storage-spec-regression-command"
      gate_upstream="D3.contract D2.storage_spec"
      gate_rationale="D3.storage_spec storage_spec_complete is promoted from the integrated binding storage-spec closeout slices covering the foundational workspace storage-unit declaration, record coverage, materialization path, exact ref boundary, authority boundary, context pack, context explanation, context staleness invalidation, credential attachment, credential binding ref, policy evaluation, policy preflight attachment, resolved dispatch binding, resolved dispatch idempotency, resolved runtime selection, workspace attempt isolation, workspace lease history, workspace snapshot manifest, immutable change boundary, and resolved workspace context attachment, plus a fresh full regression command. Capability signatures are resolved by owned files so duplicate parked slices do not create duplicate proof churn; the node stays planner-eligible (it SKIPS, it is not blocked) until every required binding storage-spec capability is integrated -- the immutable change boundary and resolved workspace context attachment slices are accepted but not yet integrated, so the node correctly skips today."
      gate_signature_labels=(
        "binding storage workspace unit specification"
        "binding storage record coverage specification"
        "binding storage materialization path specification"
        "binding storage exact ref boundary specification"
        "binding storage authority boundary specification"
        "binding storage context pack specification"
        "binding storage context explanation specification"
        "binding storage context staleness invalidation specification"
        "binding storage credential attachment specification"
        "binding storage credential binding ref specification"
        "binding storage policy evaluation specification"
        "binding storage policy preflight attachment specification"
        "binding storage resolved dispatch binding specification"
        "binding storage resolved dispatch idempotency specification"
        "binding storage resolved runtime selection specification"
        "binding storage workspace attempt isolation specification"
        "binding storage workspace lease history specification"
        "binding storage workspace snapshot manifest specification"
        "binding storage immutable change boundary specification"
        "binding storage resolved workspace context attachment specification"
      )
      gate_signature_known_task_sets=(
        "TASK-0454"
        "TASK-0473"
        "TASK-0474"
        "TASK-0477"
        "TASK-0478"
        "TASK-0460"
        "TASK-0486"
        "TASK-0483"
        "TASK-0490"
        "TASK-0465"
        "TASK-0464"
        "TASK-0487"
        "TASK-0461"
        "TASK-0491"
        "TASK-0497"
        "TASK-0482"
        "TASK-0493"
        "TASK-0494"
        "TASK-0480"
        "TASK-0498"
      )
      gate_signature_owned_sets=(
        "internal/binding/storage_spec.go|internal/binding/storage_spec_test.go"
        "internal/binding/storage_record_coverage_spec.go|internal/binding/storage_record_coverage_spec_test.go"
        "internal/binding/storage_materialization_path_spec.go|internal/binding/storage_materialization_path_spec_test.go"
        "internal/binding/storage_exact_ref_boundary_spec.go|internal/binding/storage_exact_ref_boundary_spec_test.go"
        "internal/binding/storage_authority_boundary_spec.go|internal/binding/storage_authority_boundary_spec_test.go"
        "internal/binding/storage_context_pack_spec.go|internal/binding/storage_context_pack_spec_test.go"
        "internal/binding/storage_context_explanation_spec.go|internal/binding/storage_context_explanation_spec_test.go"
        "internal/binding/storage_context_staleness_invalidation_spec.go|internal/binding/storage_context_staleness_invalidation_spec_test.go"
        "internal/binding/storage_credential_attachment_spec.go|internal/binding/storage_credential_attachment_spec_test.go"
        "internal/binding/storage_credential_binding_ref_spec.go|internal/binding/storage_credential_binding_ref_spec_test.go"
        "internal/binding/storage_policy_evaluation_spec.go|internal/binding/storage_policy_evaluation_spec_test.go"
        "internal/binding/storage_policy_preflight_attachment_spec.go|internal/binding/storage_policy_preflight_attachment_spec_test.go"
        "internal/binding/storage_resolved_dispatch_binding_spec.go|internal/binding/storage_resolved_dispatch_binding_spec_test.go"
        "internal/binding/storage_resolved_dispatch_idempotency_spec.go|internal/binding/storage_resolved_dispatch_idempotency_spec_test.go"
        "internal/binding/storage_resolved_runtime_selection_spec.go|internal/binding/storage_resolved_runtime_selection_spec_test.go"
        "internal/binding/storage_workspace_attempt_isolation_spec.go|internal/binding/storage_workspace_attempt_isolation_spec_test.go"
        "internal/binding/storage_workspace_lease_history_spec.go|internal/binding/storage_workspace_lease_history_spec_test.go"
        "internal/binding/storage_workspace_snapshot_manifest_spec.go|internal/binding/storage_workspace_snapshot_manifest_spec_test.go"
        "internal/binding/storage_immutable_change_boundary_spec.go|internal/binding/storage_immutable_change_boundary_spec_test.go"
        "internal/binding/storage_resolved_workspace_context_attachment_spec.go|internal/binding/storage_resolved_workspace_context_attachment_spec_test.go"
      )
      ;;
    D3.binding_runtime)
      gate_completion_ref="runtime_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/binding"
      gate_task_ref="binding-runtime-integrated-capability-tasks"
      gate_command_ref="binding-runtime-regression-command"
      gate_upstream="D3.storage_proof D2.service"
      gate_rationale="D3.binding_runtime runtime_complete is promoted from integrated binding runtime slices covering runtime service conformance, resolved-dispatch idempotency, resolved runtime selection, resolved workspace context attachment, resolved credential attachment, resolved policy/budget/preflight attachment, context explanation, resolved continuation policy, context staleness invalidation, workspace boundary, idempotent resolution, reconstruction bundle, workflow conformance, and workspace lease usability, plus a fresh full regression command. Capability signatures are resolved by owned files so duplicate parked slices do not create duplicate proof churn; the node stays planner-eligible (it SKIPS, it is not blocked) until every required binding runtime capability is integrated."
      gate_signature_labels=(
        "binding runtime service conformance"
        "binding resolved-dispatch idempotency runtime query"
        "binding resolved runtime selection runtime query"
        "binding resolved workspace context attachment runtime query"
        "binding resolved credential attachment runtime query"
        "binding resolved policy budget preflight runtime query"
        "binding context explanation runtime query"
        "binding resolved continuation policy runtime query"
        "binding context staleness invalidation runtime query"
        "binding workspace boundary runtime query"
        "binding idempotent resolution runtime command"
        "binding runtime reconstruction bundle query"
        "binding runtime workflow conformance check"
        "binding runtime workspace lease usability guard"
      )
      gate_signature_known_task_sets=(
        "TASK-0502"
        "TASK-0503"
        "TASK-0504"
        "TASK-0505"
        "TASK-0508"
        "TASK-0509"
        "TASK-0512"
        "TASK-0513"
        "TASK-0516"
        "TASK-0517"
        "TASK-0520"
        "TASK-0521"
        "TASK-0524"
        "TASK-0525"
      )
      gate_signature_owned_sets=(
        "internal/binding/service_runtime.go|internal/binding/service_runtime_test.go"
        "internal/binding/runtime_resolved_dispatch_idempotency_query.go|internal/binding/runtime_resolved_dispatch_idempotency_query_test.go"
        "internal/binding/runtime_resolved_runtime_selection_query.go|internal/binding/runtime_resolved_runtime_selection_query_test.go"
        "internal/binding/runtime_resolved_workspace_context_attachment_query.go|internal/binding/runtime_resolved_workspace_context_attachment_query_test.go"
        "internal/binding/runtime_resolved_credential_attachment_query.go|internal/binding/runtime_resolved_credential_attachment_query_test.go"
        "internal/binding/runtime_resolved_policy_budget_preflight_query.go|internal/binding/runtime_resolved_policy_budget_preflight_query_test.go"
        "internal/binding/runtime_context_explanation_query.go|internal/binding/runtime_context_explanation_query_test.go"
        "internal/binding/runtime_resolved_continuation_policy_query.go|internal/binding/runtime_resolved_continuation_policy_query_test.go"
        "internal/binding/runtime_context_staleness_invalidation_query.go|internal/binding/runtime_context_staleness_invalidation_query_test.go"
        "internal/binding/runtime_workspace_boundary_query.go|internal/binding/runtime_workspace_boundary_query_test.go"
        "internal/binding/runtime_idempotent_resolution_command.go|internal/binding/runtime_idempotent_resolution_command_test.go"
        "internal/binding/runtime_reconstruction_bundle_query.go|internal/binding/runtime_reconstruction_bundle_query_test.go"
        "internal/binding/runtime_workflow_conformance_check.go|internal/binding/runtime_workflow_conformance_check_test.go"
        "internal/binding/runtime_workspace_lease_usability_guard.go|internal/binding/runtime_workspace_lease_usability_guard_test.go"
      )
      ;;
    D4.storage_spec)
      gate_completion_ref="storage_spec_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/dispatch"
      gate_task_ref="dispatch-storage-spec-integrated-capability-tasks"
      gate_command_ref="dispatch-storage-spec-regression-command"
      gate_upstream="D4.contract D3.storage_spec"
      gate_rationale="D4.storage_spec storage_spec_complete is promoted from integrated dispatch storage-spec slices covering agent dispatch records, tool invocation records, record coverage, materialization paths, exact ref boundaries, authority boundaries, dispatch status transitions, tool invocation status transitions, dispatch tree queries, tool invocation timeline queries, output artifact refs, runtime raw output refs, usage rollup inputs, and tool side-effect audit queries, plus a fresh full regression command. Capability signatures are resolved by owned files so duplicate parked slices do not create duplicate proof churn; the node stays planner-eligible (it SKIPS, it is not blocked) until every required dispatch storage-spec capability is integrated."
      gate_signature_labels=(
        "dispatch agent dispatch record storage specification"
        "dispatch tool invocation record storage specification"
        "dispatch storage record coverage specification"
        "dispatch storage materialization path specification"
        "dispatch storage exact ref boundary specification"
        "dispatch storage authority boundary specification"
        "dispatch status transition storage specification"
        "dispatch tool invocation status transition storage specification"
        "dispatch tree storage query specification"
        "dispatch tool invocation timeline storage query specification"
        "dispatch output artifact refs storage query specification"
        "dispatch runtime raw output refs storage query specification"
        "dispatch usage rollup inputs storage query specification"
        "dispatch tool side effect audit storage query specification"
      )
      gate_signature_known_task_sets=(
        "TASK-0500"
        "TASK-0501"
        "TASK-0506"
        "TASK-0507"
        "TASK-0510"
        "TASK-0511"
        "TASK-0514"
        "TASK-0515"
        "TASK-0518"
        "TASK-0519"
        "TASK-0522"
        "TASK-0523"
        "TASK-0526"
        "TASK-0527"
      )
      gate_signature_owned_sets=(
        "internal/dispatch/storage_agent_dispatch_spec.go|internal/dispatch/storage_agent_dispatch_spec_test.go"
        "internal/dispatch/storage_tool_invocation_spec.go|internal/dispatch/storage_tool_invocation_spec_test.go"
        "internal/dispatch/storage_record_coverage_spec.go|internal/dispatch/storage_record_coverage_spec_test.go"
        "internal/dispatch/storage_materialization_path_spec.go|internal/dispatch/storage_materialization_path_spec_test.go"
        "internal/dispatch/storage_exact_ref_boundary_spec.go|internal/dispatch/storage_exact_ref_boundary_spec_test.go"
        "internal/dispatch/storage_authority_boundary_spec.go|internal/dispatch/storage_authority_boundary_spec_test.go"
        "internal/dispatch/storage_dispatch_status_transition_spec.go|internal/dispatch/storage_dispatch_status_transition_spec_test.go"
        "internal/dispatch/storage_tool_status_transition_spec.go|internal/dispatch/storage_tool_status_transition_spec_test.go"
        "internal/dispatch/storage_dispatch_tree_query_spec.go|internal/dispatch/storage_dispatch_tree_query_spec_test.go"
        "internal/dispatch/storage_tool_invocation_timeline_query_spec.go|internal/dispatch/storage_tool_invocation_timeline_query_spec_test.go"
        "internal/dispatch/storage_dispatch_output_artifact_refs_query_spec.go|internal/dispatch/storage_dispatch_output_artifact_refs_query_spec_test.go"
        "internal/dispatch/storage_runtime_raw_output_refs_query_spec.go|internal/dispatch/storage_runtime_raw_output_refs_query_spec_test.go"
        "internal/dispatch/storage_dispatch_usage_rollup_inputs_query_spec.go|internal/dispatch/storage_dispatch_usage_rollup_inputs_query_spec_test.go"
        "internal/dispatch/storage_tool_side_effect_audit_query_spec.go|internal/dispatch/storage_tool_side_effect_audit_query_spec_test.go"
      )
      ;;
    D4.dispatch_runtime)
      gate_completion_ref="runtime_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/dispatch"
      gate_task_ref="dispatch-runtime-integrated-capability-tasks"
      gate_command_ref="dispatch-runtime-regression-command"
      gate_upstream="D4.storage_proof D3.binding_runtime"
      gate_rationale="D4.dispatch_runtime runtime_complete is promoted from integrated dispatch runtime slices covering pre-execution agent dispatch start and tool invocation lifecycle recording services, plus a fresh full regression command. Capability signatures are resolved by owned files so duplicate parked slices do not create duplicate proof churn; the node stays planner-eligible (it SKIPS, it is not blocked) until every required dispatch runtime capability is integrated."
      gate_signature_labels=(
        "dispatch runtime pre-execution start service"
        "dispatch runtime tool invocation recording service"
      )
      gate_signature_known_task_sets=(
        "TASK-0532"
        "TASK-0533"
      )
      gate_signature_owned_sets=(
        "internal/dispatch/runtime_dispatch_start_service.go|internal/dispatch/runtime_dispatch_start_service_test.go"
        "internal/dispatch/runtime_tool_invocation_service.go|internal/dispatch/runtime_tool_invocation_service_test.go"
      )
      ;;
    D5.storage_spec)
      gate_completion_ref="storage_spec_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/evidence"
      gate_task_ref="evidence-storage-spec-integrated-capability-tasks"
      gate_command_ref="evidence-storage-spec-regression-command"
      gate_upstream="D5.contract D4.storage_spec"
      gate_rationale="D5.storage_spec storage_spec_complete is promoted from integrated evidence storage-spec slices covering evidence bundle artifact versions, finding set indexes and events, policy evaluation records, authoritative decisions and decision effects, gate-decision artifact-version views, and waiver details, plus a fresh full regression command. Capability signatures are resolved by owned files so duplicate parked slices do not create duplicate proof churn; the node stays planner-eligible (it SKIPS, it is not blocked) until every required evidence storage-spec capability is integrated."
      gate_signature_labels=(
        "evidence bundle artifact-version storage specification"
        "finding set artifact index and event storage specification"
        "policy evaluation storage specification"
        "decision record and effect storage specification"
        "gate decision artifact-version storage specification"
        "waiver detail storage specification"
      )
      gate_signature_known_task_sets=(
        "TASK-0530"
        "TASK-0531"
        "TASK-0534"
        "TASK-0535"
        "TASK-0536"
        "TASK-0537"
      )
      gate_signature_owned_sets=(
        "internal/evidence/storage_evidence_bundle_spec.go|internal/evidence/storage_evidence_bundle_spec_test.go"
        "internal/evidence/storage_finding_set_spec.go|internal/evidence/storage_finding_set_spec_test.go"
        "internal/evidence/storage_policy_evaluation_spec.go|internal/evidence/storage_policy_evaluation_spec_test.go"
        "internal/evidence/storage_decision_record_spec.go|internal/evidence/storage_decision_record_spec_test.go"
        "internal/evidence/storage_gate_decision_spec.go|internal/evidence/storage_gate_decision_spec_test.go"
        "internal/evidence/storage_waiver_detail_spec.go|internal/evidence/storage_waiver_detail_spec_test.go"
      )
      ;;
    D5.storage_proof)
      gate_completion_ref="storage_proof_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/evidence"
      gate_task_ref="evidence-durable-storage-proof-tasks"
      gate_command_ref="evidence-storage-proof-regression-command"
      gate_upstream="$(node_static_field "$node" dependsOn || true)"
      gate_rationale="D5.storage_proof storage_proof_complete is promoted from integrated durable evidence repository proofs covering evidence bundle artifact versions, finding set indexes/events, policy evaluations, and authoritative decisions with decision effects. The completion predicate is keyed to the integrated owned-file proof surface under internal/evidence and is certified by L0's deterministic red/green skip-guard: the proof passes against real PostgreSQL/blob storage and FAILS when that storage is stripped."
      gate_signature_labels=(
        "durable evidence bundle repository round-trip proof"
        "durable finding set repository round-trip proof"
        "durable policy evaluation repository round-trip proof"
        "durable decision record repository round-trip proof"
      )
      gate_signature_known_task_sets=(
        "TASK-0538"
        "TASK-0539"
        "TASK-0542"
        "TASK-0543"
      )
      gate_signature_owned_sets=(
        "internal/evidence/storage_evidence_bundle_repository.go|internal/evidence/storage_evidence_bundle_repository_test.go"
        "internal/evidence/storage_finding_set_repository.go|internal/evidence/storage_finding_set_repository_test.go"
        "internal/evidence/storage_policy_evaluation_repository.go|internal/evidence/storage_policy_evaluation_repository_test.go"
        "internal/evidence/storage_decision_record_repository.go|internal/evidence/storage_decision_record_repository_test.go"
      )
      gate_storage_proof_red_command="go test ./internal/evidence -run 'Test.*StorageRepositoryDurable.*' -count=1"
      ;;
    D6.storage_proof)
      gate_completion_ref="storage_proof_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/recovery"
      gate_task_ref="recovery-durable-storage-proof-tasks"
      gate_command_ref="recovery-storage-proof-regression-command"
      gate_upstream="$(node_static_field "$node" dependsOn || true)"
      gate_rationale="D6.storage_proof storage_proof_complete is promoted from integrated durable recovery repository proofs covering recovery plans/actions, replay requests, recovery attempts/events, and replay results/deviations. The completion predicate is keyed to the integrated owned-file proof surface under internal/recovery and is certified by L0's deterministic red/green skip-guard: the proofs pass against real PostgreSQL storage and FAIL when that storage is stripped (SINGULAR_STORAGE_PROOF_DATABASE_URL/SINGULAR_DATABASE_URL unset)."
      gate_signature_labels=(
        "durable recovery plan/action repository round-trip proof"
        "durable replay request repository round-trip proof"
        "durable recovery attempt/event repository round-trip proof"
        "durable replay result/deviation repository round-trip proof"
      )
      gate_signature_known_task_sets=(
        "TASK-0548"
        "TASK-0549"
        "TASK-0641"
        "TASK-0642"
      )
      gate_signature_owned_sets=(
        "internal/recovery/storage_plan_action_repository.go|internal/recovery/storage_plan_action_repository_test.go"
        "internal/recovery/storage_replay_request_repository.go|internal/recovery/storage_replay_request_repository_test.go"
        "internal/recovery/storage_attempt_event_repository.go|internal/recovery/storage_attempt_event_repository_closure_test.go"
        "internal/recovery/storage_replay_result_repository.go|internal/recovery/storage_replay_result_repository_closure_test.go"
      )
      gate_storage_proof_red_command="go test ./internal/recovery -run 'Durable.*Proof|RoundTrip.*Proof' -count=1"
      ;;
    D6.storage_spec)
      gate_completion_ref="storage_spec_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/recovery"
      gate_task_ref="recovery-storage-spec-integrated-capability-tasks"
      gate_command_ref="recovery-storage-spec-regression-command"
      gate_upstream="D6.contract D5.storage_spec"
      gate_rationale="D6.storage_spec storage_spec_complete is promoted from integrated recovery storage-spec slices covering recovery plans/actions/operator failure summaries, replay requests, recovery attempts/events, and replay results/deviations, plus a fresh full regression command. Capability signatures are resolved by owned files so duplicate parked slices do not create duplicate proof churn; the node stays planner-eligible (it SKIPS, it is not blocked) until every required recovery storage-spec capability is integrated."
      gate_signature_labels=(
        "recovery plan action storage specification"
        "replay request storage specification"
        "recovery attempt event storage specification"
        "replay result deviation storage specification"
      )
      gate_signature_known_task_sets=(
        "TASK-0540"
        "TASK-0541"
        "TASK-0544"
        "TASK-0545"
      )
      gate_signature_owned_sets=(
        "internal/recovery/storage_plan_action_spec.go|internal/recovery/storage_plan_action_spec_test.go"
        "internal/recovery/storage_replay_request_spec.go|internal/recovery/storage_replay_request_spec_test.go"
        "internal/recovery/storage_attempt_event_spec.go|internal/recovery/storage_attempt_event_spec_test.go"
        "internal/recovery/storage_replay_result_spec.go|internal/recovery/storage_replay_result_spec_test.go"
      )
      ;;
    D8.contract)
      gate_completion_ref="contract_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/product"
      gate_task_ref="product-contract-integrated-capability-tasks"
      gate_command_ref="product-contract-regression-command"
      gate_upstream="D7.contract"
      gate_rationale="D8.contract contract_complete is promoted from the integrated product contract slices covering command and query envelopes, projection ref, command result, projection staleness, the spec studio projection, canvas runtime-status/node/edge/graph projections, and the dispatch tree projection, plus a fresh full regression command. It does not require any run-report export capability, which is not part of the D8.contract DAG scope. Capability signatures are resolved by owned files so an integrated duplicate slice can satisfy the predicate without duplicate proof churn; the gate promotes only once every required product contract capability is integrated."
      gate_signature_labels=(
        "product command envelope contract"
        "product query envelope contract"
        "product projection ref contract"
        "product command result contract"
        "product projection staleness contract"
        "product spec studio projection contract"
        "product canvas runtime status projection contract"
        "product canvas node projection contract"
        "product canvas edge projection contract"
        "product canvas graph projection contract"
        "product dispatch tree projection contract"
      )
      gate_signature_known_task_sets=(
        "TASK-0455"
        "TASK-0456"
        "TASK-0457"
        "TASK-0458"
        "TASK-0459"
        "TASK-0462"
        "TASK-0463"
        "TASK-0466"
        "TASK-0467"
        "TASK-0468"
        "TASK-0469"
      )
      gate_signature_owned_sets=(
        "internal/product/command_envelope.go|internal/product/command_envelope_test.go"
        "internal/product/query_envelope.go|internal/product/query_envelope_test.go"
        "internal/product/projection_ref.go|internal/product/projection_ref_test.go"
        "internal/product/command_result.go|internal/product/command_result_test.go"
        "internal/product/projection_staleness.go|internal/product/projection_staleness_test.go"
        "internal/product/spec_studio_projection.go|internal/product/spec_studio_projection_test.go"
        "internal/product/canvas_runtime_status_projection.go|internal/product/canvas_runtime_status_projection_test.go"
        "internal/product/canvas_node_projection.go|internal/product/canvas_node_projection_test.go"
        "internal/product/canvas_edge_projection.go|internal/product/canvas_edge_projection_test.go"
        "internal/product/canvas_graph_projection.go|internal/product/canvas_graph_projection_test.go"
        "internal/product/dispatch_tree_projection.go|internal/product/dispatch_tree_projection_test.go"
      )
      ;;
    D4.storage_proof)
      gate_completion_ref="storage_proof_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/dispatch"
      gate_task_ref="dispatch-durable-storage-proof-tasks"
      gate_command_ref="dispatch-storage-proof-regression-command"
      gate_upstream="$(node_static_field "$node" dependsOn || true)"
      gate_rationale="D4.storage_proof storage_proof_complete is promoted from the integrated durable dispatch repository proofs for agent dispatch and tool invocation records. The completion predicate is keyed to the integrated owned-file proof surface under internal/dispatch and is certified by L0's deterministic red/green skip-guard: the proof passes against real PostgreSQL/blob storage and FAILS when that storage is stripped."
      gate_signature_labels=(
        "durable agent dispatch repository round-trip proof"
        "durable tool invocation repository round-trip proof"
      )
      gate_signature_known_task_sets=("" "")
      gate_signature_owned_sets=(
        "internal/dispatch/storage_agent_dispatch_repository.go|internal/dispatch/storage_agent_dispatch_repository_test.go"
        "internal/dispatch/storage_tool_invocation_repository.go|internal/dispatch/storage_tool_invocation_repository_test.go"
      )
      gate_storage_proof_red_command="go test ./internal/dispatch -run 'Test(AgentDispatchStorageRepository|DispatchToolInvocationStorageRepositoryDurableRoundTripProvesD4StorageProof)' -count=1"
      ;;
    *.storage_proof)
      # Generic, registry-free promotion for every durable storage proof beyond
      # D1/D2 (D3-D7 and any future stage). The proof is resolved by the owned
      # files a durable round-trip task integrates — internal/<area>/
      # storage_repository.go plus its _test.go — so no per-node task IDs are
      # hand-authored. Promotion is gated by the deterministic red/green
      # skip-guard in promote_storage_proof_node, not by a human predicate; an
      # unproven node stays planner-eligible (it is skipped, never blocked) so L1
      # can build the proof autonomously.
      local sp_area
      sp_area="$(node_static_field "$node" area || true)"
      gate_completion_ref="storage_proof_complete"
      gate_requirement_mode="signatures"
      gate_source_path="internal/${sp_area:-unknown}"
      gate_task_ref="${sp_area:-domain}-durable-storage-proof-task"
      gate_command_ref="storage-proof-regression-command"
      gate_upstream="$(node_static_field "$node" dependsOn || true)"
      gate_rationale="$node storage_proof_complete is promoted from an integrated durable ${sp_area:-domain} repository round-trip proof (a task owning internal/${sp_area:-unknown}/storage_repository.go and its _test.go), certified by L0's deterministic red/green skip-guard: the proof passes against real PostgreSQL/blob storage and FAILS when that storage is stripped. This authoritative record is written by L0 gate promotion; no human predicate is required."
      gate_signature_labels=("durable ${sp_area:-domain} repository round-trip proof")
      gate_signature_known_task_sets=("")
      gate_signature_owned_sets=("internal/${sp_area:-unknown}/storage_repository.go|internal/${sp_area:-unknown}/storage_repository_test.go")
      ;;
    *)
      return 1
      ;;
  esac
}

task_integrated() {
  local task_id="$1" task_file="$SINGULAR_TASKS_DIR/$task_id.md"
  # Superseded tasks are archived under tasks/superseded/ (0.5.0 convention).
  [[ -f "$task_file" ]] || task_file="$SINGULAR_TASKS_DIR/superseded/$task_id.md"
  [[ -f "$task_file" ]] || return 1
  grep -Eq '^Status:[[:space:]]+integrated[[:space:]]*$' "$task_file"
}

# Terminal-predecessor tolerance (0.5.0, SINGULAR_PROMOTE_TOLERATE_TERMINAL=1).
# 0.4.0's promoter counted only `Status: integrated` tasks, so superseded or
# blocked predecessors of an integrated successor kept a finished node
# permanently `node-tasks-not-integrated` (field audit: every gate needed a
# manual STOP-drain + hand-supersede of historical attempt chains). A required
# task is SATISFIED when it is integrated, OR when its supersededBy chain
# reaches an integrated task, OR when an integrated task in the same node
# covers its owned files.
task_satisfied() {
  local task_id="$1"
  task_integrated "$task_id" && return 0
  [[ "${SINGULAR_PROMOTE_TOLERATE_TERMINAL:-1}" == "1" ]] || return 1
  local task_file="$SINGULAR_TASKS_DIR/$task_id.md"
  [[ -f "$task_file" ]] || task_file="$SINGULAR_TASKS_DIR/superseded/$task_id.md"
  [[ -f "$task_file" ]] || return 1
  local node
  node="$(singular_task_node "$task_file" 2>/dev/null || true)"
  python3 - "$task_id" "$(singular_node_task_index_json "$node" 2>/dev/null || echo '[]')" <<'PY'
import json
import sys

task_id, index_raw = sys.argv[1], sys.argv[2]
tasks = json.loads(index_raw)
by_id = {t["taskId"]: t for t in tasks}
me = by_id.get(task_id)
if me is None:
    sys.exit(1)
integrated = [t for t in tasks if t["status"] == "integrated"]


def satisfied(t, depth=0):
    if t["status"] == "integrated":
        return True
    if depth > 16:
        return False
    for succ in t.get("supersededBy", []):
        nxt = by_id.get(succ)
        if nxt is not None and satisfied(nxt, depth + 1):
            return True
    owned = set(t.get("ownedFiles", []))
    if owned:
        for it in integrated:
            if owned <= set(it.get("ownedFiles", [])):
                return True
    return False


sys.exit(0 if satisfied(me) else 1)
PY
}

integrated_task_signature_index_json() {
  if [[ -n "$gate_task_index_json" ]]; then
    printf '%s\n' "$gate_task_index_json"
    return 0
  fi
  gate_task_index_json="$(python3 - "$SINGULAR_TASKS_DIR" <<'PY'
import json
import os
import re
import sys

tasks_dir = sys.argv[1]

def clean_path(value):
    value = str(value or "").strip().strip("`").strip()
    while value.startswith("./"):
        value = value[2:]
    return value.rstrip("/")

def parse_task(path):
    task_id = os.path.basename(path).removesuffix(".md")
    status = ""
    owned = []
    in_owned = False
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.rstrip("\n")
                stripped = line.strip()
                if stripped.startswith("Status:"):
                    status = stripped.split(":", 1)[1].strip()
                if stripped == "Owned files:":
                    in_owned = True
                    continue
                if in_owned and (stripped.startswith("Forbidden files:") or stripped.startswith("## ")):
                    in_owned = False
                if in_owned:
                    match = re.match(r"^\s*-\s+(.+?)\s*$", line)
                    if match:
                        owned.append(clean_path(match.group(1)))
    except OSError:
        return None
    return {
        "taskId": task_id,
        "status": status,
        "ownedFiles": sorted({item for item in owned if item}),
    }

items = []
# Include tasks/superseded/ (0.5.0): a superseded predecessor's owned files may
# be the signature evidence that its integrated successor covers.
scan_dirs = [tasks_dir, os.path.join(tasks_dir, "superseded")]
for base in scan_dirs:
    if not os.path.isdir(base):
        continue
    for name in sorted(os.listdir(base)):
        if not name.startswith("TASK-") or not name.endswith(".md") or name == "TEMPLATE.md":
            continue
        item = parse_task(os.path.join(base, name))
        if item:
            items.append(item)
print(json.dumps(items, separators=(",", ":")))
PY
)"
  printf '%s\n' "$gate_task_index_json"
}

find_integrated_task_for_signature() {
  local known_tasks="$1" owned_pipe="$2" index_json
  index_json="$(integrated_task_signature_index_json)"
  python3 - "$known_tasks" "$owned_pipe" "$index_json" <<'PY'
import json
import sys

known_raw, owned_pipe, index_raw = sys.argv[1:4]
known = [item for item in known_raw.split() if item]
required = {
    str(item).strip().strip("`").strip().rstrip("/")
    for item in owned_pipe.split("|")
    if str(item).strip()
}
if not required:
    sys.exit(1)
tasks = json.loads(index_raw)

def matches(task):
    return task.get("status") == "integrated" and required.issubset(set(task.get("ownedFiles", [])))

by_id = {task.get("taskId"): task for task in tasks}
for task_id in known:
    task = by_id.get(task_id)
    if task and matches(task):
        print(task_id)
        sys.exit(0)
for task in tasks:
    if matches(task):
        print(task.get("taskId", ""))
        sys.exit(0)
sys.exit(1)
PY
}

required_tasks_integrated() {
  local task_id
  gate_missing_tasks=()
  gate_missing_labels=()
  if [[ "$gate_requirement_mode" == "signatures" ]]; then
    gate_evidence_tasks=()
    local i label known_tasks owned_pipe matched primary
    for i in "${!gate_signature_labels[@]}"; do
      label="${gate_signature_labels[$i]}"
      known_tasks="${gate_signature_known_task_sets[$i]}"
      owned_pipe="${gate_signature_owned_sets[$i]}"
      if matched="$(find_integrated_task_for_signature "$known_tasks" "$owned_pipe" 2>/dev/null)"; then
        gate_evidence_tasks+=("$matched")
      else
        primary="${known_tasks%% *}"
        gate_missing_tasks+=("$primary")
        gate_missing_labels+=("$label")
      fi
    done
    if [[ "${#gate_missing_tasks[@]}" -gt 0 ]]; then
      echo "required closeout capabilities not integrated for $gate_node: ${gate_missing_labels[*]} (${gate_missing_tasks[*]})" >&2
      return 1
    fi
    return 0
  fi
  for task_id in "${gate_required_tasks[@]}"; do
    task_satisfied "$task_id" || gate_missing_tasks+=("$task_id")
  done
  if [[ "${#gate_missing_tasks[@]}" -gt 0 ]]; then
    echo "required task not integrated for $gate_node: ${gate_missing_tasks[*]}" >&2
    return 1
  fi
}

node_already_passed() {
  "$ENGINE_BIN/dag.sh" area-gate "$1" >/dev/null 2>&1
}

# Block registry: nodes that must record an authoritative BLOCKED gate naming
# the exact unmet predicate rather than silently skipping. A blocked gate is
# authoritative state but NOT completion — dag.sh treats only status==passed as
# done, so a block can never advance the frontier or satisfy a dependent.
gate_block_config() {
  local node="$1"
  block_node_id="$node"
  block_source_path=""
  block_source_desc=""
  block_rationale=""
  block_upstream=""
  case "$node" in
    D1.storage_proof)
      block_source_path="internal/artifact/storage_proof.go"
      block_source_desc="Descriptor-only storage_proof binding: it names proof requirements and performs no database, blob-store, repository, or gate-result file I/O."
      block_rationale="storage_proof_complete requires a durable artifact-repository conformance proof: write artifact metadata plus payload, read it back through a reopened/recreated repository, and verify content-hash and immutable-ref invariants against a real PostgreSQL-backed metadata store and a content-addressed blob store across a restart. No such durable proof exists yet — the repository has no executable database/sql or blob-backed repository round-trip test, only a descriptor validator — so the current evidence is insufficient for storage_proof_complete. This gate is BLOCKED (authoritative, not complete) until that durable round-trip proof is implemented."
      return 0 ;;
    D2.storage_proof)
      block_source_path="internal/workflow"
      block_source_desc="Workflow storage_spec package: declarative workflow storage records exist, but no durable workflow repository proof has written, reopened, and read back records against PostgreSQL plus content-addressed blob storage."
      block_upstream="D2.storage_spec D1.storage_proof"
      block_rationale="D2.storage_proof storage_proof_complete requires a durable workflow repository conformance proof: write workflow/template/run/node records and any payload-bearing references through a real PostgreSQL-backed metadata store plus content-addressed blob store, restart or recreate repository handles, read the records back by exact immutable refs, and verify content hashes, record identity, ordering, and ref boundary invariants across the restart. No such executable durable proof exists yet for workflow-owned records; declarative storage_spec evidence is insufficient. This gate is BLOCKED (authoritative, not complete) until that round-trip proof is implemented and run with real storage infrastructure."
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Promotable nodes that BLOCK (recording the unmet readiness predicate) rather
# than silently skip when their required evidence is not yet integrated.
node_is_promote_or_block() {
  case "$1" in
    D1.service|D2.contract|D2.storage_spec|D3.contract|D4.contract|D5.contract|D6.contract|D7.contract) return 0 ;;
    *) return 1 ;;
  esac
}

gate_current_status() {
  local path="$gates_dir/$1.gate-result.json"
  [[ -f "$path" ]] || return 1
  python3 - "$path" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("status", ""))
except Exception:
    sys.exit(1)
PY
}

node_already_blocked() {
  [[ "$(gate_current_status "$1" 2>/dev/null)" == "blocked" ]]
}

write_gate_json() {
  local node="$1" command="$2" log_ref="$3" sha="$4" head_sha="$5" recorded_at="$6" out_path="$7"
  local green_exit="${8:-0}" red_command="${9:-}" red_log_ref="${10:-}" red_sha="${11:-}" red_exit="${12:-}"
  local report_ref="${13:-}" report_sha="${14:-}" report_outcome="${15:-}"
  local tasks_json schema_id source_sha="" task_set_sha=""
  tasks_json="$(printf '%s\n' "${gate_evidence_tasks[@]}" | python3 -c 'import json,sys; print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))')"
  schema_id="$(gate_result_schema_id)"
  if [[ "$schema_id" == "singular.orchestration.gate-result.v1" ]]; then
    source_sha="$(gate_source_sha256 "$gate_source_path")" || return 1
    task_set_sha="$(gate_task_set_sha256 "$gate_task_ref" "$tasks_json")" || return 1
  fi
  python3 - "$node" "$gate_source_path" "$gate_task_ref" "$gate_command_ref" \
    "$gate_upstream" "$gate_rationale" "$command" "$log_ref" "$sha" \
    "$head_sha" "$recorded_at" "$tasks_json" "$out_path" \
    "$green_exit" "$red_command" "$red_log_ref" "$red_sha" "$red_exit" "$schema_id" \
    "$source_sha" "$task_set_sha" "$report_ref" "$report_sha" "$report_outcome" <<'PY'
import json
import sys

(
    node,
    source_path,
    task_ref,
    command_ref,
    upstream,
    rationale,
    command,
    log_ref,
    sha,
    head_sha,
    recorded_at,
    tasks_raw,
    out_path,
    green_exit,
    red_command,
    red_log_ref,
    red_sha,
    red_exit,
    schema_id,
    source_sha,
    task_set_sha,
    report_ref,
    report_sha,
    report_outcome,
) = sys.argv[1:25]
task_ids = json.loads(tasks_raw)
upstream_gates = [item for item in upstream.split() if item]
evidence = [
    {
        "kind": "source-path",
        "ref": source_path,
        "description": f"{node} source package for the promoted gate.",
    },
    {
        "kind": "task-set",
        "ref": task_ref,
        "description": f"Integrated task slices cited by the {node} gate-result candidate.",
        "taskIds": task_ids,
    },
    {
        "kind": "command-log",
        "ref": command_ref,
        "description": "Fresh full regression command captured during L0 gate promotion.",
        "command": command,
        "exitCode": int(green_exit),
        "logRef": log_ref,
        "sha256": sha,
        "headSha": head_sha,
    },
]
if schema_id == "singular.orchestration.gate-result.v1":
    if report_outcome not in ("passed", "passed-with-acknowledged-baseline"):
        raise SystemExit("gate-result.v1 requires a passing strict gate-report outcome")
    if not report_ref or len(report_sha) != 64:
        raise SystemExit("gate-result.v1 requires a hash-bound strict gate report")
    evidence[0]["sha256"] = source_sha
    evidence[1]["sha256"] = task_set_sha
    evidence.append(
        {
            "kind": "gate-report",
            "ref": report_ref,
            "sha256": report_sha,
            "description": "Strict gate-report.v0 bound to the promoted command, log, and worker head.",
        }
    )
if red_command:
    # The skip-guard: an expected-FAIL run of the durable proof with the storage
    # DSN stripped. Re-hashed like every log; its non-zero exit is what proves
    # the proof is not vacuous. dag.sh permits this red only for storage_proof.
    evidence.append(
        {
            "kind": "command-log",
            "ref": f"{command_ref}-skip-guard-red",
            "description": "Storage-stripped skip-guard: the durable round-trip proof run with SINGULAR_STORAGE_PROOF_DATABASE_URL/SINGULAR_DATABASE_URL unset; it MUST fail (non-zero), proving the proof exercises real storage and is not vacuous.",
            "command": red_command,
            "exitCode": int(red_exit),
            "logRef": red_log_ref,
            "sha256": red_sha,
            "headSha": head_sha,
        }
    )
gate = {
    "schema": schema_id,
    "node": node,
    "status": (
        "passed-with-acknowledged-baseline"
        if report_outcome == "passed-with-acknowledged-baseline"
        else "passed"
    ),
    "authoritative": True,
    "evidenceClass": "deterministic-proof",
    "evidence": evidence,
    "upstreamGates": upstream_gates,
    "decidedBy": "l0-gate-promoter",
    "rationale": rationale,
    "recordedAt": recorded_at,
}
if schema_id.endswith(".v1"):
    gate["verificationClassification"] = "passed"
    gate["gateReportRef"] = report_ref
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(gate, f, indent=2)
    f.write("\n")
PY
}

validate_gate_candidate_file() {
  local node="$1" gate_file="$2" tmp_gates
  tmp_gates="$(mktemp -d)"
  if compgen -G "$gates_dir/*.gate-result.json" >/dev/null; then
    cp "$gates_dir"/*.gate-result.json "$tmp_gates/"
  fi
  cp "$gate_file" "$tmp_gates/$node.gate-result.json"
  SINGULAR_GATES_DIR="$tmp_gates" "$ENGINE_BIN/dag.sh" area-gate "$node" >/dev/null
  rm -rf "$tmp_gates"
}

write_blocked_gate_json() {
  # node source_path source_desc rationale upstream missing_tasks_json out_path
  local node="$1" source_path="$2" source_desc="$3" rationale="$4" upstream="$5" missing_json="$6" out_path="$7" recorded_at
  local schema_id source_sha="" task_set_sha=""
  recorded_at="$(singular_timestamp)"
  schema_id="$(gate_result_schema_id)"
  if [[ "$schema_id" == "singular.orchestration.gate-result.v1" ]]; then
    source_sha="$(gate_source_sha256 "$source_path")" || return 1
    if [[ -n "$missing_json" && "$missing_json" != "[]" ]]; then
      task_set_sha="$(gate_task_set_sha256 "${node}-unmet-readiness-tasks" "$missing_json")" || return 1
    fi
  fi
  python3 - "$node" "$source_path" "$source_desc" "$rationale" "$upstream" "$missing_json" "$recorded_at" "$out_path" \
    "$schema_id" "$source_sha" "$task_set_sha" <<'PY'
import json
import sys

(
    node,
    source_path,
    source_desc,
    rationale,
    upstream,
    missing_json,
    recorded_at,
    out_path,
    schema_id,
    source_sha,
    task_set_sha,
) = sys.argv[1:12]
missing = json.loads(missing_json) if missing_json else []
evidence = [
    {
        "kind": "source-path",
        "ref": source_path,
        "description": source_desc,
    }
]
if missing:
    evidence.append(
        {
            "kind": "task-set",
            "ref": f"{node}-unmet-readiness-tasks",
            "description": "Required task slices not yet integrated; the gate is blocked until these land.",
            "taskIds": missing,
        }
    )
if schema_id == "singular.orchestration.gate-result.v1":
    evidence[0]["sha256"] = source_sha
    if missing:
        evidence[1]["sha256"] = task_set_sha
gate = {
    "schema": schema_id,
    "node": node,
    "status": "blocked",
    "authoritative": True,
    "evidenceClass": "deterministic-proof",
    "evidence": evidence,
    "decidedBy": "l0-gate-promoter",
    "rationale": rationale,
    "recordedAt": recorded_at,
}
if upstream:
    gate["upstreamGates"] = [item for item in upstream.split() if item]
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(gate, f, indent=2)
    f.write("\n")
PY
}

validate_blocked_gate_candidate_file() {
  # A blocked gate must be schema-valid, authoritative, tied to the requested
  # node, and explicitly NOT gate-passed. Planner eligibility is deliberately
  # stronger than this: dag.sh node-fields excludes authoritative blocks so L1
  # cannot keep slicing an already-adjudicated blocker.
  local node="$1" gate_file="$2" tmp_gates
  tmp_gates="$(mktemp -d)"
  if compgen -G "$gates_dir/*.gate-result.json" >/dev/null; then
    cp "$gates_dir"/*.gate-result.json "$tmp_gates/"
  fi
  cp "$gate_file" "$tmp_gates/$node.gate-result.json"
  python3 - "$node" "$gate_file" <<'PY'
import json
import sys

node, gate_file = sys.argv[1:3]
with open(gate_file, "r", encoding="utf-8") as f:
    gate = json.load(f)
if gate.get("node") != node:
    raise SystemExit(f"blocked gate node mismatch: {gate.get('node')} != {node}")
if gate.get("status") != "blocked":
    raise SystemExit(f"blocked gate status must be blocked: {gate.get('status')}")
if gate.get("authoritative") is not True:
    raise SystemExit("blocked gate must be authoritative")
PY
  local out rc=0
  out="$(SINGULAR_GATES_DIR="$tmp_gates" "$ENGINE_BIN/dag.sh" area-gate "$node" 2>&1)" || rc=$?
  rm -rf "$tmp_gates"
  if [[ "$rc" -eq 0 ]]; then
    echo "blocked gate unexpectedly passes area-gate node=$node" >&2
    return 2
  fi
  if [[ "$out" != *"gate result not passed for $node"* ]]; then
    echo "$out" >&2
    return "$rc"
  fi
}

block_with() {
  # node source_path source_desc rationale upstream missing_tasks_json
  local node="$1" source_path="$2" source_desc="$3" rationale="$4" upstream="$5" missing_json="${6:-}"
  if node_already_blocked "$node"; then
    blocked_total=$((blocked_total + 1))
    echo "already-blocked node=$node"
    return 0
  fi
  local gate_path="$gates_dir/$node.gate-result.json"
  local tmp_gate
  tmp_gate="$(mktemp "$gates_dir/.$node.gate-result.json.tmp.XXXXXX")"
  if ! write_blocked_gate_json "$node" "$source_path" "$source_desc" "$rationale" "$upstream" "$missing_json" "$tmp_gate"; then
    rm -f "$tmp_gate"
    echo "refusing to write unhashable blocked gate evidence node=$node" >&2
    return 2
  fi
  if ! validate_blocked_gate_candidate_file "$node" "$tmp_gate"; then
    rm -f "$tmp_gate"
    echo "refusing to write malformed blocked gate node=$node" >&2
    return 2
  fi
  mv "$tmp_gate" "$gate_path"
  singular_append_event "gate_promotion.blocked" "gate blocked" \
    "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
  blocked_total=$((blocked_total + 1))
  echo "blocked node=$node gate=$gate_path"
}

block_only_node() {
  local node="$1" strict="${2:-yes}"
  gate_block_config "$node"
  if node_already_passed "$node"; then
    echo "already-passed node=$node"
    return 0
  fi
  if node_already_blocked "$node"; then
    blocked_total=$((blocked_total + 1))
    echo "already-blocked node=$node"
    return 0
  fi
  if ! "$ENGINE_BIN/dag.sh" node-fields "$node" >/dev/null 2>&1; then
    if [[ "$strict" == "yes" ]]; then
      "$ENGINE_BIN/dag.sh" node-fields "$node" >&2 || true
      return 2
    fi
    return 0
  fi
  block_with "$node" "$block_source_path" "$block_source_desc" "$block_rationale" "$block_upstream" ""
}

# Read one field (area|layer|...) for a node straight from the DAG manifest,
# independent of any gate/readiness state. Empty output + non-zero on miss.
node_static_field() {
  local node="$1" field="$2"
  python3 - "$dag_file" "$node" "$field" <<'PY'
import json, sys
dag_file, node, field = sys.argv[1:4]
try:
    with open(dag_file, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
for n in data.get("nodes", []):
    if n.get("id") == node:
        value = n.get(field, "")
        if isinstance(value, list):
            out = " ".join(str(x) for x in value)
        elif isinstance(value, str):
            out = value
        else:
            out = ""
        print(out)
        sys.exit(0 if out != "" else 1)
sys.exit(1)
PY
}

# Extract ONLY the storage-proof DSN from an env file by sourcing it in a
# SUBSHELL, so the file's other assignments — control vars (SINGULAR_ROOT,
# SINGULAR_GATES_DIR, SINGULAR_PROMOTE_GATE_COMMAND, ...) and the ~dozen unrelated
# PG*/POSTGRES* secrets — never enter the promotion shell or the proof's command
# environment. Echoes the DSN value on stdout; callers MUST capture it into a
# variable, never to a visible stream.
extract_storage_proof_dsn_from_file() {
  local f="$1"
  ( # shellcheck disable=SC1090
    source "$f" >/dev/null 2>&1
    printf '%s' "${SINGULAR_STORAGE_PROOF_DATABASE_URL:-${SINGULAR_DATABASE_URL:-}}" ) || true
}

# DSN resolution ladder for storage proofs: environment -> dedicated proof env
# file -> shared state env file -> (opt-in) local docker postgres. Records what
# was tried in proof_dsn_attempts so a HumanProvisionRequired rationale can name
# it. NEVER prints any DSN value, and never lets an env file's non-DSN
# assignments leak into the promotion shell. Returns 0 once a DSN is exported.
resolve_storage_proof_dsn() {
  proof_dsn_attempts=("env:SINGULAR_STORAGE_PROOF_DATABASE_URL/SINGULAR_DATABASE_URL")
  [[ -n "${SINGULAR_STORAGE_PROOF_DATABASE_URL:-}" || -n "${SINGULAR_DATABASE_URL:-}" ]] && return 0
  local f dsn
  for f in "$SINGULAR_ROOT/.singular-state/singular-storage-proof.env" "$SINGULAR_ROOT/.singular-state/.env"; do
    if [[ -f "$f" ]]; then
      proof_dsn_attempts+=("source:${f#"$SINGULAR_ROOT/"}")
      dsn="$(extract_storage_proof_dsn_from_file "$f")"
      if [[ -n "$dsn" ]]; then
        export SINGULAR_STORAGE_PROOF_DATABASE_URL="$dsn"
        return 0
      fi
    fi
  done
  # Opt-in local provisioning (default OFF: host :5432 may be occupied and
  # bringing up containers is a side effect the loop must not take silently).
  if [[ "${SINGULAR_PROOF_ALLOW_LOCAL_DB:-0}" == "1" ]]; then
    proof_dsn_attempts+=("local:make deps-up")
    if ( cd "$SINGULAR_ROOT" && make deps-up >/dev/null 2>&1 ); then
      f="$SINGULAR_ROOT/.singular-state/singular-storage-proof.env"
      if [[ -f "$f" ]]; then
        dsn="$(extract_storage_proof_dsn_from_file "$f")"
        if [[ -n "$dsn" ]]; then
          export SINGULAR_STORAGE_PROOF_DATABASE_URL="$dsn"
          return 0
        fi
      fi
    fi
  fi
  return 1
}

# Record an authoritative HumanProvisionRequired BLOCK: the one legitimate stop,
# used only after local self-service for the storage DSN has failed. It is an
# external-resource stop, NOT a trust/readiness block.
human_provision_required_block() {
  local node="$1" area="$2" upstream="$3"
  local source_desc rationale
  source_desc="$node storage_proof needs an external PostgreSQL database that agents cannot self-provision; the durable round-trip proof for internal/$area cannot run without it."
  rationale="HumanProvisionRequired: $node storage_proof_complete cannot be certified because no reachable PostgreSQL database is available for the durable round-trip proof. Local self-service was attempted and failed (${proof_dsn_attempts[*]:-none}). This is an EXTERNAL-RESOURCE stop, not a trust or readiness block: provide a PostgreSQL DSN via SINGULAR_STORAGE_PROOF_DATABASE_URL (or SINGULAR_DATABASE_URL) — e.g. set it in .singular-state/singular-storage-proof.env, or run 'make deps-up' for a local Postgres and export its URL — then re-run promotion. Validation after provisioning: go test ./internal/$area -run StorageRepositoryDurableRoundTrip -count=1."
  block_with "$node" "internal/$area" "$source_desc" "$rationale" "$upstream" ""
}

# Promote a *.storage_proof node with a deterministic skip-guard. A durable proof
# is only trustworthy if it FAILS without real storage, so L0 itself runs it
# twice — GREEN (full regression with the DSN present) and RED (the targeted
# durable round-trip with the storage DSN STRIPPED, which MUST fail). A red that
# passes means the "proof" is vacuous (mock/in-memory) and promotion is refused.
# This is the out-of-band, agent-independent check that closes the doer==judge
# gap for storage proofs; dag.sh re-hashes both logs. If no PostgreSQL can be
# resolved at all, the node is recorded as an authoritative HumanProvisionRequired
# block (the one legitimate external-resource stop) rather than faked or skipped.
promote_storage_proof_node() {
  local node="$1"
  local area
  area="$(node_static_field "$node" area || true)"
  if [[ -z "$area" ]]; then
    echo "cannot resolve area for storage_proof node=$node" >&2
    return 2
  fi

  if ! resolve_storage_proof_dsn; then
    echo "storage_proof node=$node: no reachable PostgreSQL after local attempts (${proof_dsn_attempts[*]:-none})" >&2
    human_provision_required_block "$node" "$area" "$gate_upstream"
    return $?
  fi

  local upstream_node
  for upstream_node in $gate_upstream; do
    "$ENGINE_BIN/dag.sh" area-gate "$upstream_node" >/dev/null
  done

  # The green/red commands may be overridden ONLY by test fixtures under
  # SINGULAR_TEST_FIXTURE=1. In production these env vars are ignored, so a stray
  # SINGULAR_PROOF_RED_COMMAND in a launch environment cannot neuter the skip-guard:
  # production always runs the real full regression (green) and the real targeted
  # durable round-trip with storage stripped (red).
  local fixture_overrides="no"
  [[ "${SINGULAR_TEST_FIXTURE:-0}" == "1" ]] && fixture_overrides="yes"

  local green_command green_log_ref green_log_path
  if [[ "$fixture_overrides" == "yes" && -n "${SINGULAR_PROMOTE_GATE_COMMAND:-}" ]]; then
    green_command="$SINGULAR_PROMOTE_GATE_COMMAND"
  else
    green_command="$SINGULAR_DEFAULT_GATE_CMD"
  fi
  green_log_ref="docs/orchestration/gates/evidence/$node.regression.txt"
  green_log_path="$SINGULAR_ROOT/$green_log_ref"
  local observation_ref="docs/orchestration/gates/evidence/$node.gate-observation.json"
  local observation_path="$SINGULAR_ROOT/$observation_ref"
  local report_ref="docs/orchestration/gates/evidence/$node.gate-report.json"
  local schema_id
  schema_id="$(gate_result_schema_id)"

  local red_command red_log_ref red_log_path
  if [[ "$fixture_overrides" == "yes" && -n "${SINGULAR_PROOF_RED_COMMAND:-}" ]]; then
    red_command="$SINGULAR_PROOF_RED_COMMAND"
  elif [[ -n "$gate_storage_proof_red_command" ]]; then
    red_command="$gate_storage_proof_red_command"
  else
    red_command="go test ./internal/$area -run StorageRepositoryDurableRoundTrip -count=1"
  fi
  red_log_ref="docs/orchestration/gates/evidence/$node.skip-guard-red.txt"
  red_log_path="$SINGULAR_ROOT/$red_log_ref"

  local tmp_gate
  tmp_gate="$(mktemp "$gates_dir/.$node.gate-result.json.tmp.XXXXXX")"
  if [[ "$schema_id" == "singular.orchestration.gate-result.v1" ]]; then
    rm -f "$observation_path" "$SINGULAR_ROOT/$report_ref"
  fi

  singular_append_event "gate_promotion.started" "gate promotion started" \
    "{\"runId\":\"$run_id\",\"node\":\"$node\",\"layer\":\"storage_proof\"}"

  # 1) GREEN: full regression with real storage present must pass.
  local green_exit=0
  local -a green_env=()
  [[ "$schema_id" == "singular.orchestration.gate-result.v1" ]] \
    && green_env=(env "SINGULAR_GATE_REPORT_FILE=$observation_path")
  if ( cd "$SINGULAR_ROOT" && "${green_env[@]}" bash -c "$green_command" ) >"$green_log_path" 2>&1; then
    green_exit=0
  else
    green_exit=$?
  fi

  local green_sha head_sha report_sha="" report_outcome=""
  green_sha="$(shasum -a 256 "$green_log_path" | awk '{print $1}')"
  head_sha="$(git -C "$SINGULAR_ROOT" rev-parse HEAD)"
  if [[ "$schema_id" == "singular.orchestration.gate-result.v1" ]]; then
    if ! write_strict_gate_report \
      "$node" "$green_command" "$green_exit" "$green_log_ref" "$head_sha" \
      "$observation_ref" "$report_ref"; then
      rm -f "$tmp_gate"
      singular_append_event "gate_promotion.failed" "strict gate report is missing or invalid" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\",\"classification\":\"inconclusive-infrastructure\",\"logRef\":\"$green_log_ref\"}"
      echo "refusing to promote node=$node: strict gate report is missing or invalid" >&2
      return 2
    fi
    report_sha="$strict_gate_report_sha"
    report_outcome="$strict_gate_report_outcome"
    if [[ "$report_outcome" != "passed" \
      && "$report_outcome" != "passed-with-acknowledged-baseline" ]]; then
      rm -f "$tmp_gate"
      singular_append_event "gate_promotion.failed" "strict gate report did not pass" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\",\"classification\":\"$report_outcome\",\"exitCode\":$green_exit,\"logRef\":\"$green_log_ref\",\"gateReportRef\":\"$report_ref\"}"
      echo "gate promotion did not pass node=$node classification=$report_outcome log=$green_log_ref report=$report_ref" >&2
      [[ "$green_exit" -ne 0 ]] && return "$green_exit"
      return 2
    fi
  elif [[ "$green_exit" -ne 0 ]]; then
    rm -f "$tmp_gate"
    singular_append_event "gate_promotion.failed" "gate promotion command failed" \
      "{\"runId\":\"$run_id\",\"node\":\"$node\",\"exitCode\":$green_exit,\"logRef\":\"$green_log_ref\"}"
    echo "gate promotion command failed node=$node exit=$green_exit log=$green_log_ref" >&2
    return "$green_exit"
  fi

  # 2) RED skip-guard: the durable proof with the storage DSN stripped MUST fail.
  #    exit 0 here == the proof passes without real storage == vacuous == refuse.
  local red_exit=0
  if ( cd "$SINGULAR_ROOT" && env -u SINGULAR_STORAGE_PROOF_DATABASE_URL -u SINGULAR_DATABASE_URL bash -c "$red_command" ) >"$red_log_path" 2>&1; then
    red_exit=0
  else
    red_exit=$?
  fi
  if [[ "$red_exit" -eq 0 ]]; then
    rm -f "$tmp_gate"
    singular_append_event "gate_promotion.failed" "storage_proof skip-guard passed without storage" \
      "{\"runId\":\"$run_id\",\"node\":\"$node\",\"redExitCode\":0,\"logRef\":\"$red_log_ref\"}"
    echo "refusing to promote node=$node: skip-guard RED passed with storage stripped (vacuous/mocked proof); see $red_log_ref" >&2
    return 2
  fi

  local red_sha recorded_at
  red_sha="$(shasum -a 256 "$red_log_path" | awk '{print $1}')"
  recorded_at="$(singular_timestamp)"
  if ! write_gate_json "$node" "$green_command" "$green_log_ref" "$green_sha" "$head_sha" "$recorded_at" "$tmp_gate" \
    "$green_exit" "$red_command" "$red_log_ref" "$red_sha" "$red_exit" \
    "$report_ref" "$report_sha" "$report_outcome"; then
    rm -f "$tmp_gate"
    echo "refusing to write unhashable gate evidence node=$node" >&2
    return 2
  fi
  validate_gate_candidate_file "$node" "$tmp_gate"
  mv "$tmp_gate" "$gates_dir/$node.gate-result.json"
  "$ENGINE_BIN/dag.sh" area-gate "$node" >/dev/null
  singular_append_event "gate_promotion.completed" "gate promoted" \
    "{\"runId\":\"$run_id\",\"node\":\"$node\",\"logRef\":\"$green_log_ref\",\"redLogRef\":\"$red_log_ref\",\"headSha\":\"$head_sha\"}"
  promoted_total=$((promoted_total + 1))
  echo "promoted node=$node gate=$gates_dir/$node.gate-result.json log=$green_log_ref skip-guard-red=$red_log_ref"
}

unsupported_node_help() {
  local node="$1"
  cat >&2 <<EOF
unsupported gate promotion node: $node
  This promoter promotes only nodes in its registry (gate_promoter_config).
  Options:
    - register $node in your project promoter (config key "promoter" in
      singular.config.json points at it)
    - inspect eligibility: singular next-areas --explain
EOF
}

# Run a promotion gate command with a stderr progress heartbeat every
# SINGULAR_PROMOTE_PROGRESS_SECS (default 15; 0 disables). The field run's
# promoter was silent for its full 17-47s regression runtime, so operators
# repeatedly mistook a healthy promotion for a hang. stdout stays byte-
# identical (parsed by reconcile); the heartbeat goes to stderr only.
run_gate_command_with_progress() {
  # args: command log_path [observation_path] -- returns the command's exit code
  local command="$1" log_path="$2" observation_path="${3:-}"
  local -a command_env=()
  [[ -n "$observation_path" ]] \
    && command_env=(env "SINGULAR_GATE_REPORT_FILE=$observation_path")
  local interval="${SINGULAR_PROMOTE_PROGRESS_SECS:-15}"
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=15
  local ec=0
  if (( interval == 0 )); then
    (cd "$SINGULAR_ROOT" && "${command_env[@]}" bash -c "$command") >"$log_path" 2>&1 || ec=$?
    return "$ec"
  fi
  (cd "$SINGULAR_ROOT" && "${command_env[@]}" bash -c "$command") >"$log_path" 2>&1 &
  local child=$! started=$SECONDS
  while kill -0 "$child" 2>/dev/null; do
    sleep 1
    if (( (SECONDS - started) % interval == 0 && SECONDS > started )); then
      echo "promote-gate: still running ($((SECONDS - started))s; log: $log_path)" >&2
    fi
  done
  wait "$child" || ec=$?
  return "$ec"
}

promote_node() {
  local node="$1" strict="${2:-yes}"
  if ! gate_promoter_config "$node"; then
    if [[ "$strict" == "yes" ]]; then
      unsupported_node_help "$node"
      return 2
    fi
    return 0
  fi

  if node_already_passed "$node"; then
    echo "already-passed node=$node"
    return 0
  fi

  if ! "$ENGINE_BIN/dag.sh" node-fields "$node" >/dev/null 2>&1; then
    if node_already_blocked "$node"; then
      :
    elif [[ "$strict" == "yes" ]]; then
      "$ENGINE_BIN/dag.sh" node-fields "$node" >&2 || true
      return 2
    else
      return 0
    fi
  fi

  if ! required_tasks_integrated; then
    # Not ready. Promote-or-block nodes record an authoritative BLOCKED gate
    # naming the precise unmet readiness predicate (so the planner can route a
    # task at exactly that, instead of spinning on descriptor helpers). Legacy
    # promote-only nodes keep their refuse-and-skip behavior.
    if [[ "$node" == *.storage_proof ]]; then
      # An unproven storage proof is NOT blocked: an authoritative block would
      # exclude it from the planner frontier, but L1 must stay free to build the
      # durable proof. So we SKIP (the node stays planner-eligible); the red/green
      # skip-guard in promote_storage_proof_node is what prevents a vacuous proof
      # from ever passing. The only storage_proof block is HumanProvisionRequired,
      # written at promote time when no PostgreSQL can be resolved.
      return 0
    fi
    if node_is_promote_or_block "$node"; then
      local missing_json reason source_desc
      missing_json="$(printf '%s\n' "${gate_missing_tasks[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
      if [[ "$gate_requirement_mode" == "signatures" ]]; then
        reason="$node ${gate_completion_ref:-completion} is blocked: missing closeout capability signatures: ${gate_missing_labels[*]}. Known task evidence still not integrated for those predicates: ${gate_missing_tasks[*]}. This gate is BLOCKED (authoritative, not complete) until those capability slices land; the missing predicate is capability integration, not more L1 slicing."
        source_desc="$node source package; promotion is blocked on unmet closeout capability signatures."
      else
        reason="$node ${gate_completion_ref:-contract_complete} is blocked: every required contract slice must be integrated before promotion, but these are not yet integrated: ${gate_missing_tasks[*]}. This gate is BLOCKED (authoritative, not complete) until those slices land; the missing predicate is the listed task integration, not any unbuilt behavior."
        source_desc="$node source package; promotion is blocked on unmet readiness evidence, not on missing behavior."
      fi
      block_with "$node" "$gate_source_path" "$source_desc" "$reason" "$gate_upstream" "$missing_json"
      return $?
    fi
    if [[ "$strict" == "yes" ]]; then
      return 2
    fi
    return 0
  fi

  # A durable storage proof is certified by an out-of-band red/green skip-guard
  # (run the proof with real storage, then again with it stripped — it MUST fail
  # the second time) rather than the single generic regression. This is what
  # makes it safe to promote an agent-authored storage proof without a human
  # predicate; see promote_storage_proof_node.
  if [[ "$(node_static_field "$node" layer)" == "storage_proof" ]]; then
    promote_storage_proof_node "$node"
    return $?
  fi

  local upstream_node
  for upstream_node in $gate_upstream; do
    "$ENGINE_BIN/dag.sh" area-gate "$upstream_node" >/dev/null
  done

  local command="${SINGULAR_PROMOTE_GATE_COMMAND:-$SINGULAR_DEFAULT_GATE_CMD}"
  local log_ref="docs/orchestration/gates/evidence/$node.regression.txt"
  local log_path="$SINGULAR_ROOT/$log_ref"
  local observation_ref="docs/orchestration/gates/evidence/$node.gate-observation.json"
  local observation_path="$SINGULAR_ROOT/$observation_ref"
  local report_ref="docs/orchestration/gates/evidence/$node.gate-report.json"
  local gate_path="$gates_dir/$node.gate-result.json"
  local tmp_gate schema_id
  schema_id="$(gate_result_schema_id)"
  tmp_gate="$(mktemp "$gates_dir/.$node.gate-result.json.tmp.XXXXXX")"
  if [[ "$schema_id" == "singular.orchestration.gate-result.v1" ]]; then
    rm -f "$observation_path" "$SINGULAR_ROOT/$report_ref"
  fi

  singular_append_event "gate_promotion.started" "gate promotion started" \
    "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
  local exit_code=0
  echo "promote-gate: node=$node running regression (log: $log_ref)" >&2
  run_gate_command_with_progress \
    "$command" \
    "$log_path" \
    "$([[ "$schema_id" == "singular.orchestration.gate-result.v1" ]] && printf '%s' "$observation_path")" \
    || exit_code=$?

  local sha head_sha recorded_at report_sha="" report_outcome=""
  sha="$(shasum -a 256 "$log_path" | awk '{print $1}')"
  head_sha="$(git -C "$SINGULAR_ROOT" rev-parse HEAD)"
  recorded_at="$(singular_timestamp)"
  if [[ "$schema_id" == "singular.orchestration.gate-result.v1" ]]; then
    if ! write_strict_gate_report \
      "$node" "$command" "$exit_code" "$log_ref" "$head_sha" \
      "$observation_ref" "$report_ref"; then
      rm -f "$tmp_gate"
      singular_append_event "gate_promotion.failed" "strict gate report is missing or invalid" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\",\"classification\":\"inconclusive-infrastructure\",\"logRef\":\"$log_ref\"}"
      echo "refusing to promote node=$node: strict gate report is missing or invalid" >&2
      return 2
    fi
    report_sha="$strict_gate_report_sha"
    report_outcome="$strict_gate_report_outcome"
    if [[ "$report_outcome" != "passed" \
      && "$report_outcome" != "passed-with-acknowledged-baseline" ]]; then
      rm -f "$tmp_gate"
      singular_append_event "gate_promotion.failed" "strict gate report did not pass" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\",\"classification\":\"$report_outcome\",\"exitCode\":$exit_code,\"logRef\":\"$log_ref\",\"gateReportRef\":\"$report_ref\"}"
      echo "gate promotion did not pass node=$node classification=$report_outcome log=$log_ref report=$report_ref" >&2
      [[ "$exit_code" -ne 0 ]] && return "$exit_code"
      return 2
    fi
  elif [[ "$exit_code" -ne 0 ]]; then
    rm -f "$tmp_gate"
    singular_append_event "gate_promotion.failed" "gate promotion command failed" \
      "{\"runId\":\"$run_id\",\"node\":\"$node\",\"exitCode\":$exit_code,\"logRef\":\"$log_ref\"}"
    echo "gate promotion command failed node=$node exit=$exit_code log=$log_ref" >&2
    return "$exit_code"
  fi

  if ! write_gate_json \
    "$node" "$command" "$log_ref" "$sha" "$head_sha" "$recorded_at" "$tmp_gate" \
    "$exit_code" "" "" "" "" "$report_ref" "$report_sha" "$report_outcome"; then
    rm -f "$tmp_gate"
    echo "refusing to write unhashable gate evidence node=$node" >&2
    return 2
  fi
  validate_gate_candidate_file "$node" "$tmp_gate"
  mv "$tmp_gate" "$gate_path"
  "$ENGINE_BIN/dag.sh" area-gate "$node" >/dev/null
  singular_append_event "gate_promotion.completed" "gate promoted" \
    "{\"runId\":\"$run_id\",\"node\":\"$node\",\"logRef\":\"$log_ref\",\"headSha\":\"$head_sha\"}"
  promoted_total=$((promoted_total + 1))
  echo "promoted node=$node gate=$gate_path log=$log_ref"
}

# Route one node to the correct disposition: promote (or block-on-readiness)
# for promotable nodes, block for block-registry nodes, refuse/skip otherwise.
# --- Evaluation gates (0.5.0 governance) -------------------------------------
# kind=evaluation nodes are judgment calls, not regression runs. Authority:
#   - pre-v2, or schema v2 with explicit legacy unbound-waiver compatibility,
#     `--operator` promotes with >=1 hashable --evidence ref.
#   - nodes declaring `authority: agent-review-allowed` in the DAG promote on
#     a VALID passing review file at
#     docs/orchestration/gates/evidence/<node>.review.json (gate-review.v0:
#     verdict pass, node match, evidenceRefs exist, headSha ancestor of the
#     target head, age <= SINGULAR_REVIEW_MAX_AGE_HOURS, default 168; 0=off).
#   - default authority (operator) without --operator refuses with the exact
#     unlock instructions. The field run's promoter accepted agent-authored
#     evidence for an operator-only node with no check at all — this closes
#     that hole while codifying the sanctioned sub-agent-review path.
promote_evaluation_node() {
  local node="$1" strict="${2:-yes}"
  if node_already_passed "$node"; then
    echo "already-passed node=$node"
    return 0
  fi
  local head_sha recorded_at gate_path tmp_gate
  head_sha="$(git -C "$SINGULAR_ROOT" rev-parse HEAD)"
  recorded_at="$(singular_timestamp)"
  gate_path="$gates_dir/$node.gate-result.json"

  if [[ "$operator_mode" == "yes" ]]; then
    if [[ ${#operator_evidence[@]} -eq 0 ]]; then
      echo "promote-gate --operator requires at least one --evidence REF for $node" >&2
      return 2
    fi
    local schema_id
    schema_id="$(gate_result_schema_id)"
    if [[ "$schema_id" == "singular.orchestration.gate-result.v1" ]] \
      && ! singular_unbound_waivers_enabled; then
      cat >&2 <<EOF
evaluation node $node: unbound --operator --evidence promotion is disabled under schema v2.
  Record a first-class human-gate request and exact-artifact human approval instead.
  Legacy compatibility requires an explicit "legacyCompatibility": {"unboundWaivers": true} selection.
EOF
      return 2
    fi
    local -a operator_hashes=()
    local evidence_ref evidence_sha
    if [[ "$schema_id" == "singular.orchestration.gate-result.v1" ]]; then
      for evidence_ref in "${operator_evidence[@]}"; do
        if ! evidence_sha="$(gate_source_sha256 "$evidence_ref")"; then
          echo "evaluation node $node: operator evidence cannot be safely hash-bound: $evidence_ref" >&2
          return 2
        fi
        operator_hashes+=("$evidence_sha")
      done
    fi
    tmp_gate="$(mktemp "$gates_dir/.$node.gate-result.json.tmp.XXXXXX")"
    python3 - "$node" "$head_sha" "$recorded_at" "$tmp_gate" "$schema_id" \
      "${#operator_evidence[@]}" "${operator_evidence[@]}" "${operator_hashes[@]}" <<'PY'
import json
import sys

node, head_sha, recorded_at, out_path, schema_id, count_raw = sys.argv[1:7]
count = int(count_raw)
refs = sys.argv[7:7 + count]
hashes = sys.argv[7 + count:]
if schema_id.endswith(".v1") and len(hashes) != len(refs):
    raise SystemExit("operator evidence hash count mismatch")
evidence = []
for index, ref in enumerate(refs):
    item = {
        "kind": "source-path",
        "ref": ref,
        "description": f"operator-reviewed evidence for {node}",
    }
    if schema_id.endswith(".v1"):
        item["sha256"] = hashes[index]
    evidence.append(item)
gate = {
    "schema": schema_id,
    "node": node,
    "status": "passed",
    "authoritative": True,
    "evidenceClass": "operator-review",
    "evidence": evidence,
    "decidedBy": "operator:" + (__import__("os").environ.get("USER") or "cli"),
    "rationale": f"Evaluation gate {node} promoted on operator authority (promote-gate --operator).",
    "recordedAt": recorded_at,
}
if schema_id.endswith(".v1"):
    gate["verificationClassification"] = "not-rerun-evidence-verified"
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(gate, f, indent=2)
    f.write("\n")
PY
    validate_gate_candidate_file "$node" "$tmp_gate"
    mv "$tmp_gate" "$gate_path"
    "$ENGINE_BIN/dag.sh" area-gate "$node" >/dev/null
    singular_append_event "gate_promotion.completed" "evaluation gate promoted (operator)" \
      "{\"runId\":\"$run_id\",\"node\":\"$node\",\"evidenceClass\":\"operator-review\"}"
    promoted_total=$((promoted_total + 1))
    echo "promoted node=$node gate=$gate_path evidenceClass=operator-review"
    return 0
  fi

  local authority
  authority="$(node_static_field "$node" authority 2>/dev/null || echo operator)"
  [[ -n "$authority" ]] || authority="operator"
  local review_file="$gates_dir/evidence/$node.review.json"
  if [[ "$authority" != "agent-review-allowed" ]]; then
    if [[ "$strict" == "yes" ]]; then
      if [[ "$(gate_result_schema_id)" == "singular.orchestration.gate-result.v1" ]] \
        && ! singular_unbound_waivers_enabled; then
        cat >&2 <<EOF
evaluation node $node requires exact-artifact human approval under schema v2.
  Record a first-class human-gate request and approval for this node.
  The unbound --operator --evidence route is available only through explicit legacy compatibility.
EOF
      else
        cat >&2 <<EOF
evaluation node $node requires operator authority.
  Options:
    - rerun with: singular promote-gate $node --operator --evidence <path>...
    - or set "authority": "agent-review-allowed" on the node in dag.v0.json
      and record review evidence at $review_file (gate-review.v0)
EOF
      fi
      return 2
    fi
    return 0
  fi

  if [[ ! -f "$review_file" ]]; then
    if [[ "$strict" == "yes" ]]; then
      echo "evaluation node $node: no review evidence at $review_file (gate-review.v0)" >&2
      return 2
    fi
    return 0
  fi
  local review_json
  if ! review_json="$(singular_normalize_schema_id "$review_file" "gate review")"; then
    echo "evaluation node $node: unreadable review file $review_file" >&2
    return 2
  fi
  if ! singular_json_schema_check "$review_json" "$SINGULAR_ENGINE_HOME/schemas/gate-review.v0.schema.json" "gate review" 2>&1; then
    echo "evaluation node $node: review file failed gate-review.v0 validation" >&2
    return 2
  fi
  local r_node r_verdict r_head r_reviewer_kind r_reviewer_id r_recorded
  r_node="$(singular_json_field "$review_file" node)"
  r_verdict="$(singular_json_field "$review_file" verdict)"
  r_head="$(singular_json_field "$review_file" headSha)"
  r_reviewer_kind="$(singular_json_field "$review_file" reviewer.kind 2>/dev/null || echo agent)"
  r_reviewer_id="$(singular_json_field "$review_file" reviewer.id 2>/dev/null || echo unknown)"
  r_recorded="$(singular_json_field "$review_file" recordedAt)"
  if [[ "$r_node" != "$node" ]]; then
    echo "evaluation node $node: review file names node $r_node" >&2
    return 2
  fi
  if [[ "$r_verdict" != "pass" ]]; then
    echo "evaluation node $node: review verdict is '$r_verdict' — refusing to promote (a failed review never auto-writes a failed gate; that is an operator action)" >&2
    return 2
  fi
  if ! git -C "$SINGULAR_ROOT" merge-base --is-ancestor "$r_head" "$head_sha" 2>/dev/null; then
    echo "evaluation node $node: review headSha $r_head is not an ancestor of the target head — re-review at the current head" >&2
    return 2
  fi
  local max_age="${SINGULAR_REVIEW_MAX_AGE_HOURS:-168}"
  if [[ "$max_age" =~ ^[0-9]+$ && "$max_age" -gt 0 ]]; then
    if ! python3 - "$r_recorded" "$max_age" <<'PY'
import sys
from datetime import datetime, timezone
recorded, max_h = sys.argv[1], int(sys.argv[2])
try:
    t = datetime.fromisoformat(recorded.replace("Z", "+00:00"))
except Exception:
    sys.exit(1)
age_h = (datetime.now(timezone.utc) - t).total_seconds() / 3600.0
sys.exit(0 if age_h <= max_h else 1)
PY
    then
      echo "evaluation node $node: review evidence is older than ${max_age}h (SINGULAR_REVIEW_MAX_AGE_HOURS) — re-review" >&2
      return 2
    fi
  fi
  # Missing evidenceRefs fail closed.
  local missing_ref
  missing_ref="$(python3 - "$review_file" "$SINGULAR_ROOT" <<'PY'
import json, os, sys
review, root = sys.argv[1], sys.argv[2]
data = json.load(open(review))
for ref in data.get("evidenceRefs", []):
    if not os.path.exists(os.path.join(root, ref)):
        print(ref)
        sys.exit(0)
PY
)"
  if [[ -n "$missing_ref" ]]; then
    echo "evaluation node $node: review evidenceRef does not exist in repo: $missing_ref" >&2
    return 2
  fi

  local review_schema_id review_file_ref review_file_sha="" review_refs_json="[]" review_ref_count=0
  local -a review_ref_hashes=()
  review_schema_id="$(gate_result_schema_id)"
  review_file_ref="$(python3 - "$review_file" "$SINGULAR_ROOT" <<'PY'
import os
import sys
print(os.path.relpath(sys.argv[1], sys.argv[2]))
PY
)"
  if [[ "$review_schema_id" == "singular.orchestration.gate-result.v1" ]]; then
    if ! review_file_sha="$(gate_source_sha256 "$review_file_ref")"; then
      echo "evaluation node $node: review file cannot be safely hash-bound: $review_file_ref" >&2
      return 2
    fi
    if ! review_refs_json="$(python3 - "$review_file" <<'PY'
import json
import sys

refs = json.load(open(sys.argv[1], encoding="utf-8")).get("evidenceRefs", [])
for ref in refs:
    if any(char in ref for char in ("\n", "\r", "\0")):
        raise SystemExit(f"unsafe control character in gate review evidenceRef: {ref!r}")
print(json.dumps(refs, ensure_ascii=False, separators=(",", ":")))
PY
)"; then
      echo "evaluation node $node: review evidence refs cannot be safely hash-bound" >&2
      return 2
    fi
    if ! review_ref_count="$(python3 - "$review_refs_json" <<'PY'
import json
import sys
print(len(json.loads(sys.argv[1])))
PY
)"; then
      echo "evaluation node $node: review evidence refs are malformed" >&2
      return 2
    fi
    local review_ref review_index evidence_sha
    for ((review_index = 0; review_index < review_ref_count; review_index++)); do
      if ! review_ref="$(python3 - "$review_refs_json" "$review_index" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])[int(sys.argv[2])], end="")
PY
)"; then
        echo "evaluation node $node: review evidence ref index is malformed" >&2
        return 2
      fi
      if ! evidence_sha="$(gate_source_sha256 "$review_ref")"; then
        echo "evaluation node $node: review evidence cannot be safely hash-bound: $review_ref" >&2
        return 2
      fi
      review_ref_hashes+=("$evidence_sha")
    done
  fi

  tmp_gate="$(mktemp "$gates_dir/.$node.gate-result.json.tmp.XXXXXX")"
  python3 - "$node" "$head_sha" "$recorded_at" "$tmp_gate" "$review_file" "$r_reviewer_kind" "$r_reviewer_id" "$SINGULAR_ROOT" \
    "$review_schema_id" "$review_file_sha" "$review_ref_count" "${review_ref_hashes[@]}" <<'PY'
import json
import os
import sys

(
    node,
    head_sha,
    recorded_at,
    out_path,
    review_file,
    r_kind,
    r_id,
    root,
    schema_id,
    review_file_sha,
    ref_count_raw,
) = sys.argv[1:12]
ref_hashes = sys.argv[12:]
ref_count = int(ref_count_raw)
review = json.load(open(review_file))
evidence = [
    {"kind": "source-path", "ref": os.path.relpath(review_file, root),
     "description": f"gate-review.v0 evidence for {node} (reviewer {r_kind}/{r_id})"}
]
refs = review.get("evidenceRefs", [])
if len(refs) != ref_count:
    raise SystemExit("gate review evidence count changed during promotion")
if schema_id.endswith(".v1") and len(ref_hashes) != len(refs):
    raise SystemExit("gate review evidence hash count mismatch")
if schema_id.endswith(".v1"):
    evidence[0]["sha256"] = review_file_sha
for index, ref in enumerate(refs):
    item = {
        "kind": "source-path",
        "ref": ref,
        "description": f"review-cited evidence for {node}",
    }
    if schema_id.endswith(".v1"):
        item["sha256"] = ref_hashes[index]
    evidence.append(item)
gate = {
    "schema": schema_id,
    "node": node,
    "status": "passed",
    "authoritative": True,
    "evidenceClass": "agent-review",
    "evidence": evidence,
    "decidedBy": f"agent-review:{r_kind}/{r_id}",
    "rationale": review.get("rationale", f"Evaluation gate {node} promoted on independent review evidence."),
    "recordedAt": recorded_at,
}
if schema_id.endswith(".v1"):
    gate["verificationClassification"] = "not-rerun-evidence-verified"
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(gate, f, indent=2)
    f.write("\n")
PY
  validate_gate_candidate_file "$node" "$tmp_gate"
  mv "$tmp_gate" "$gate_path"
  "$ENGINE_BIN/dag.sh" area-gate "$node" >/dev/null
  singular_append_event "gate_promotion.completed" "evaluation gate promoted (agent review)" \
    "{\"runId\":\"$run_id\",\"node\":\"$node\",\"evidenceClass\":\"agent-review\",\"reviewer\":\"$r_reviewer_kind/$r_reviewer_id\"}"
  promoted_total=$((promoted_total + 1))
  echo "promoted node=$node gate=$gate_path evidenceClass=agent-review reviewer=$r_reviewer_kind/$r_reviewer_id"
  return 0
}

process_node() {
  local node="$1" strict="${2:-yes}"
  # Evaluation nodes route to the governance path BEFORE the registry lookup:
  # their promotion is an authority decision, never a regression run.
  local node_kind
  node_kind="$(node_static_field "$node" kind 2>/dev/null || true)"
  if [[ "$node_kind" == "evaluation" ]]; then
    promote_evaluation_node "$node" "$strict"
    return $?
  fi
  if gate_promoter_config "$node"; then
    promote_node "$node" "$strict"
    return $?
  fi
  if gate_block_config "$node"; then
    block_only_node "$node" "$strict"
    return $?
  fi
  if [[ "$strict" == "yes" ]]; then
    unsupported_node_help "$node"
    return 2
  fi
  # Frontier mode is deliberately non-strict -- ordinary build-loop nodes must
  # not be treated as promotion failures. But it was also SILENT: a consumer
  # whose nodes are in no promoter registry saw only "no promotable frontier
  # gates", every iteration, with nothing naming the nodes or the remedy. That
  # is a full day of a field run spent on a graph that could not advance.
  #
  # Still non-fatal; just no longer invisible. One line per node per cycle would
  # be noise, so the caller aggregates and reports once.
  unregistered_nodes+=("$node")
  return 0
}

if [[ -n "$registers_query" ]]; then
  if gate_promoter_config "$registers_query" >/dev/null 2>&1 \
    || gate_block_config "$registers_query" >/dev/null 2>&1; then
    exit 0
  fi
  exit 1
fi

if [[ "$frontier_mode" == "yes" ]]; then
  # Adjudicate the WHOLE read-only frontier: each node is routed to promote,
  # block, or skip by its registered disposition. The promoter no longer
  # hardcodes a promotable subset — unregistered nodes simply skip, so normal
  # build-loop nodes are untouched while registered nodes get a definite
  # promote-or-block decision instead of silent spinning.
  # "no frontier gates to adjudicate" must not double as the report for a DAG
  # that could not be read at all -- singular_dag_next_areas_json warns and emits
  # dag.evaluation_failed, and this stays non-fatal so the cycle continues.
  frontier_json="$(singular_dag_next_areas_json || true)"
  mapfile -t requested_nodes < <(python3 - "$frontier_json" <<'PY'
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
for item in data.get("frontier", []):
    node = item.get("node", "")
    if node:
        print(node)
PY
)
  if [[ "${#requested_nodes[@]}" -eq 0 ]]; then
    echo "no frontier gates to adjudicate"
    exit 0
  fi
fi

strict_arg="$([[ "$frontier_mode" == "yes" || "$if_ready_mode" == "yes" ]] && echo no || echo yes)"
overall_rc=0
unregistered_nodes=()
for node in "${requested_nodes[@]}"; do
  if process_node "$node" "$strict_arg"; then
    :
  else
    node_rc=$?
    [[ "$overall_rc" -eq 0 ]] && overall_rc="$node_rc"
  fi
done
if [[ "$frontier_mode" == "yes" && $((promoted_total + blocked_total)) -eq 0 ]]; then
  echo "no promotable frontier gates"
  # ...and say WHY, when the reason is that this promoter recognises none of
  # them. Without this the message is identical whether the frontier is simply
  # not ready or the graph can never advance unattended.
  if [[ "${#unregistered_nodes[@]}" -gt 0 ]]; then
    echo "  ${#unregistered_nodes[@]} frontier node(s) are in no promoter registry: ${unregistered_nodes[*]}"
    echo "  this graph cannot advance unattended; point \"promoter\" in singular.config.json at a promoter that registers them (see singular doctor)"
    singular_append_event "gate_promotion.unregistered_frontier" \
      "frontier nodes have no registered promoter; the graph cannot advance unattended" \
      "$(python3 - "${unregistered_nodes[@]}" <<'PY'
import json
import sys

print(json.dumps({"nodes": sys.argv[1:], "count": len(sys.argv) - 1},
                 separators=(",", ":")))
PY
)" 2>/dev/null || true
  fi
fi
exit "$overall_rc"
