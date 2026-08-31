#!/usr/bin/env bash
# ctx-plan-revise.sh — the plan-revision-loop BOUND AUTHORITY: a pure,
# deterministic decider mapping a plan-critic verdict plus the number of revision
# rounds already spent to the next loop action, bounded by SINGULAR_PLAN_REVISE_MAX
# (default 1).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-planner-resume.sh and engine/ctx-critique-import.sh). It never owns
# engine/lib.sh and adds no driver-file hook.
#
# This is the fail-closed authority the later planner-re-invocation slice consults
# for whether to revise, park, or import. It implements the requiredCompletion
# predicate "bounded by SINGULAR_PLAN_REVISE_MAX (default 1) ... exhausted budget
# with a still-non-approve verdict park". The SINGULAR_PLAN_CRITIQUE-gated planner
# re-invocation resuming the persisted node session, the rc-86 fresh-fallback
# record, the per-finding disposition events (plan.revised with revisesRunId),
# and the generate-tasks.sh / l1-plan-node.sh driver hooks are the sanctioned
# follow-up slices of this node and are OUT OF SCOPE here.
#
# Public entry points (pure; no side effects, no events, no state writes):
#   singular_plan_revise_max
#     Print the effective revision-round bound. Reads SINGULAR_PLAN_REVISE_MAX,
#     defaulting to 1 when unset or empty. A set-but-invalid value is printed
#     verbatim so the decider can reject it fail-closed (it never silently
#     coerces a bad bound into the default).
#   singular_plan_revise_decide <verdict> <revisions_done>
#     Print EXACTLY one line and ALWAYS exit 0:
#       verdict=approve                          -> `import`
#       verdict=revise,  revisions_done < max    -> `revise <revisions_done+1>`
#       verdict=revise,  revisions_done >= max   -> `park revise-budget-exhausted`
#       verdict=park (explicit terminal)         -> `park park`
#       empty / unknown verdict                  -> `park <reason>`
#       non-integer / negative revisions_done    -> `park <reason>`
#       non-integer / negative effective max     -> `park <reason>`
#     Fail-closed (evidence invariance): the function NEVER resolves ambiguity to
#     `revise`, so no unbounded revision path can exist.

# Pure helper centralizing the default-1 bound. Empty or unset -> 1. A set value
# (even an invalid one) is echoed verbatim; the decider validates it and fails
# closed to `park` rather than coercing a bad bound into a silent default.
singular_plan_revise_max() {
  local raw="${SINGULAR_PLAN_REVISE_MAX:-}"
  if [[ -z "$raw" ]]; then
    printf '1'
  else
    printf '%s' "$raw"
  fi
}

# The plan-revision-loop decider. Pure: reads only its two arguments and the
# SINGULAR_PLAN_REVISE_MAX knob; prints one line; always exits 0. See header for
# the full contract.
singular_plan_revise_decide() {
  local verdict="${1-}"
  local revisions_done="${2-}"

  # approve is the terminal accept: the loop stops and the batch proceeds to
  # import, independent of the round count.
  if [[ "$verdict" == "approve" ]]; then
    printf 'import\n'
    return 0
  fi

  # revise is the only branch that can request another round, and only within
  # the bound. Everything here fails CLOSED to `park` — never to `revise`.
  if [[ "$verdict" == "revise" ]]; then
    # A non-integer or negative round count is indeterminate budget -> park.
    if [[ ! "$revisions_done" =~ ^[0-9]+$ ]]; then
      printf 'park bad-revisions\n'
      return 0
    fi
    # A non-integer or negative effective bound is an untrustworthy limit -> park.
    local max; max="$(singular_plan_revise_max)"
    if [[ ! "$max" =~ ^[0-9]+$ ]]; then
      printf 'park bad-max\n'
      return 0
    fi
    # Budget remaining -> revise the next round; else the budget is exhausted and
    # a still-non-approve verdict with no budget left parks (never another revise).
    if (( revisions_done < max )); then
      printf 'revise %d\n' "$(( revisions_done + 1 ))"
    else
      printf 'park revise-budget-exhausted\n'
    fi
    return 0
  fi

  # An explicit terminal park verdict parks under its own token.
  if [[ "$verdict" == "park" ]]; then
    printf 'park park\n'
    return 0
  fi

  # Fail-closed: an empty or unknown verdict resolves to park under a stable
  # reason — never to revise.
  if [[ -z "$verdict" ]]; then
    printf 'park empty-verdict\n'
  else
    printf 'park unknown-verdict\n'
  fi
  return 0
}

# --- Durable candidate-lineage attempt state ---------------------------------
#
# Revision bounds used to live only in a shell-local counter. A new reconcile
# process consequently forgot the exhausted budget and re-entered the same
# plan/critic/revise cycle. These helpers persist the counter and terminal park
# against a content identity. Infrastructure attempts have their own counter and
# never increment revisionsDone.

singular_plan_attempt_context_sha() {
  local node="${1:-}" stage_dir="${2:-}" out="${3:-$stage_dir/plan-critic-input.md}"
  [[ -n "$node" && -d "$stage_dir" ]] || return 2
  local _pn="plan-critic"
  local policy="${SINGULAR_ORCH_DIR}/prompts/${_pn}.md"
  local base_sha="${SINGULAR_PLAN_ATTEMPT_BASE_SHA:-}"
  if [[ -z "$base_sha" && -f "$stage_dir/plan-attempt-input.json" ]]; then
    base_sha="$(python3 - "$stage_dir/plan-attempt-input.json" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("baseSha", ""))
PY
)"
  fi
  singular_ctx_plan_critic_context "$node" "$stage_dir" "$out" "" "$policy" "$base_sha" || return 2
  singular_sha256_file "$out"
}

singular_plan_attempt_critic_model_version() {
  if [[ -n "${SINGULAR_PLAN_CRITIC_MODEL_VERSION:-}" ]]; then
    printf '%s' "$SINGULAR_PLAN_CRITIC_MODEL_VERSION"
    return
  fi
  local runner="${SINGULAR_RUNNER:-default-runner}" runner_sha=""
  [[ -f "$runner" ]] && runner_sha="$(singular_sha256_file "$runner" 2>/dev/null || printf '%s' "")"
  printf '%s' "${runner}|${runner_sha}|${SINGULAR_CODEX_MODEL:-}|${SINGULAR_CLAUDE_MODEL:-}|${SINGULAR_GEMINI_MODEL:-}|${SINGULAR_OPENCODE_MODEL:-}|${SINGULAR_CURSOR_MODEL:-}|${SINGULAR_OPENROUTER_MODEL:-}|${SINGULAR_GROK_MODEL:-}"
}

singular_plan_attempt_input_manifest() {
  local node="${1:-}" base_sha="${2:-}" stage_dir="${3:-}" count="${4:-1}"
  local node_fields="${5:-}"
  [[ -n "$node" && -n "$base_sha" && -d "$stage_dir" ]] || return 2
  local authority_file authority_sha="" planner_template="${SINGULAR_ORCH_DIR}/prompts/l1-planner.md"
  local _pc="plan"; _pc="${_pc}-critic"
  local planner_sha="" critic_prompt="${SINGULAR_ORCH_DIR}/prompts/${_pc}.md" critic_sha=""
  authority_file="$(singular_ctx_plan_critic_stage_file "$node" 2>/dev/null || printf '%s' "")"
  [[ -f "$authority_file" ]] && authority_sha="$(singular_sha256_file "$authority_file" 2>/dev/null || printf '%s' "")"
  [[ -f "$planner_template" ]] && planner_sha="$(singular_sha256_file "$planner_template" 2>/dev/null || printf '%s' "")"
  [[ -f "$critic_prompt" ]] && critic_sha="$(singular_sha256_file "$critic_prompt" 2>/dev/null || printf '%s' "")"
  local engine_version="${SINGULAR_ENGINE_VERSION:-}"
  if [[ -z "$engine_version" && -f "${SINGULAR_ENGINE_DIR}/../VERSION" ]]; then
    engine_version="$(tr -d '[:space:]' < "${SINGULAR_ENGINE_DIR}/../VERSION")"
  fi
  local area="" scopes_json="[]"
  area="$(printf '%s\n' "$node_fields" | sed -n 's/^area=//p' | tail -1)"
  if [[ -n "$area" ]]; then
    scopes_json="$(singular_l1_area_write_scopes "$area" | python3 -c '
import json, sys
print(json.dumps([line.strip() for line in sys.stdin if line.strip()], separators=(",", ":")))
')"
  fi
  local slice_budget="${SINGULAR_L2_SLICE_BUDGET:-1}"
  local slice_budget_max="${SINGULAR_L2_SLICE_BUDGET_MAX:-3}"
  [[ "$slice_budget" =~ ^[0-9]+$ && "$slice_budget" -ge 1 ]] || return 2
  [[ "$slice_budget_max" =~ ^[0-9]+$ && "$slice_budget_max" -ge 1 ]] || return 2
  [[ "$slice_budget" -gt "$slice_budget_max" ]] && slice_budget="$slice_budget_max"
  local layer="" single_slice_layers="${SINGULAR_SINGLE_SLICE_LAYERS:-contract}" _ssl
  layer="$(printf '%s\n' "$node_fields" | sed -n 's/^layer=//p' | tail -1)"
  for _ssl in ${single_slice_layers//,/ }; do
    if [[ "$layer" == "$_ssl" ]]; then slice_budget=1; break; fi
  done
  local manifest="$stage_dir/plan-attempt-input.json"
  python3 - "$manifest" "$stage_dir" "$node" "$base_sha" "$node_fields" "$count" \
    "$authority_sha" "$planner_sha" "$critic_sha" "$engine_version" \
    "${SINGULAR_PLAN_CRITIC_POLICY_VERSION:-1}" \
    "$(singular_plan_attempt_critic_model_version)" \
    "$(singular_plan_revise_max)" "$slice_budget" \
    "${SINGULAR_PLAN_ATTEMPT_OVERRIDE_TOKEN:-}" \
    "${SINGULAR_DAG_FILE:-$SINGULAR_ORCH_DIR/dag.v0.json}" \
    "${SINGULAR_GATES_DIR:-$SINGULAR_ORCH_DIR/gates}" "$SINGULAR_TASKS_DIR" \
    "$SINGULAR_ROOT" "$scopes_json" "$SINGULAR_TARGET_BRANCH" <<'PY'
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

(path, stage_dir, node, base_sha, node_fields, count, authority_sha, planner_sha,
 critic_sha, engine_version, policy_version, model_version, revision_max,
 slice_budget, override_token, dag_path, gates_dir, tasks_dir, repo_root,
 scopes_raw, target_branch) = sys.argv[1:22]


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def task_node(text):
    header = text.split("\n## ", 1)[0]
    match = re.search(r"(?im)^DAG node:\s*`?([^`\s]+)`?\s*$", header)
    if match:
        return match.group(1)
    section = re.search(
        r"(?ims)^## Executable DAG frontier\s*$.*?^[-*]\s+node:\s*`?([^`\s]+)`?\s*$",
        text,
    )
    return section.group(1) if section else ""


def task_header(text, pattern, default=""):
    match = re.search(pattern, text, re.MULTILINE | re.IGNORECASE)
    return match.group(1).strip().strip("`") if match else default


# Only tasks already attributed to this node can change what its next slice
# should be. Sibling lifecycle churn is intentionally absent from both the
# lineage and the staged planner's task directory.
relevant_tasks = []
summary_lines = []
relevant_dir = os.path.join(stage_dir, ".plan-relevant-tasks")
tmp_relevant = tempfile.mkdtemp(prefix=".plan-relevant-tasks.", dir=stage_dir)
try:
    if os.path.isdir(tasks_dir):
        for name in sorted(os.listdir(tasks_dir)):
            if not (name.startswith("TASK-") and name.endswith(".md")):
                continue
            source = os.path.join(tasks_dir, name)
            if not os.path.isfile(source):
                continue
            raw = open(source, "rb").read()
            text = raw.decode("utf-8")
            if task_node(text) != node:
                continue
            task_id = task_header(text, r"^#\s+(TASK-[0-9]{4,})\s*:", name[:-3])
            status = task_header(text, r"^Status:\s*(.*?)\s*$", "?")
            title = task_header(text, r"^#\s+TASK-[0-9]{4,}\s*:\s*(.*?)\s*$", "")
            digest = hashlib.sha256(raw).hexdigest()
            relevant_tasks.append({
                "taskId": task_id,
                "status": status,
                "title": title,
                "sha256": digest,
            })
            summary_lines.append(f"- {task_id} [{status}] {title}".rstrip())
            shutil.copyfile(source, os.path.join(tmp_relevant, name))
    if os.path.lexists(relevant_dir):
        if os.path.isdir(relevant_dir) and not os.path.islink(relevant_dir):
            shutil.rmtree(relevant_dir)
        else:
            os.unlink(relevant_dir)
    os.replace(tmp_relevant, relevant_dir)
    tmp_relevant = ""
finally:
    if tmp_relevant and os.path.isdir(tmp_relevant):
        shutil.rmtree(tmp_relevant)

summary = "\n".join(summary_lines) if summary_lines else "(none yet)"
summary_path = os.path.join(stage_dir, "existing-tasks.md")
fd, summary_tmp = tempfile.mkstemp(prefix=".existing-tasks.", dir=stage_dir)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(summary + "\n")
os.replace(summary_tmp, summary_path)

with open(dag_path, encoding="utf-8") as f:
    dag = json.load(f)
nodes = {item.get("id"): item for item in dag.get("nodes", []) if isinstance(item, dict)}
if node not in nodes:
    raise SystemExit(f"planning lineage node missing from DAG: {node}")
node_definition = nodes[node]


def semantic_gate(gate):
    keep = (
        "schema", "node", "status", "authoritative", "blockerClass",
        "evidenceClass", "verificationClassification", "blockedNodes",
        "upstreamGates", "humanGateRef", "humanApprovalRef", "gateReportRef",
    )
    result = {key: gate[key] for key in keep if key in gate}
    evidence = []
    evidence_keep = (
        "kind", "ref", "sha256", "headSha", "exitCode", "command", "taskIds",
    )
    for item in gate.get("evidence", []):
        if isinstance(item, dict):
            evidence.append({key: item[key] for key in evidence_keep if key in item})
    result["evidence"] = evidence
    return result


dependency_inputs = []
for dependency in node_definition.get("dependsOn", []):
    gate_path = os.path.join(gates_dir, f"{dependency}.gate-result.json")
    with open(gate_path, encoding="utf-8") as f:
        gate = json.load(f)
    dependency_inputs.append({
        "node": dependency,
        "definition": nodes.get(dependency),
        "gate": semantic_gate(gate),
    })

try:
    scopes = json.loads(scopes_raw)
except Exception as exc:
    raise SystemExit(f"invalid planning source scopes: {exc}")
if not isinstance(scopes, list) or not all(isinstance(item, str) and item for item in scopes):
    raise SystemExit("planning source scopes must be a non-empty string array")

# Hash only the configured area source tree at the observed commit. Dynamic
# orchestration state is represented separately above (node tasks + direct
# dependency proofs), so sibling task/import/gate telemetry cannot invalidate a
# terminal lineage merely because it was committed to the target branch.
proc = subprocess.run(
    ["git", "-C", repo_root, "ls-tree", "-rz", "--full-tree", base_sha, "--", *scopes],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
if proc.returncode != 0:
    raise SystemExit(proc.stderr.decode("utf-8", errors="replace").strip())
dynamic_prefixes = (
    "docs/orchestration/archive/",
    "docs/orchestration/areas/",
    "docs/orchestration/gates/",
    "docs/orchestration/handoffs/",
    "docs/orchestration/packets/",
    "docs/orchestration/tasks/",
)
dynamic_exact = {"docs/orchestration/project-state.md"}
source_digest = hashlib.sha256()
for entry in proc.stdout.split(b"\0"):
    if not entry:
        continue
    _meta, separator, raw_name = entry.partition(b"\t")
    if not separator:
        raise SystemExit("malformed git ls-tree entry while binding planning source")
    name = raw_name.decode("utf-8", errors="surrogateescape")
    if name in dynamic_exact or any(name.startswith(prefix) for prefix in dynamic_prefixes):
        continue
    source_digest.update(entry)
    source_digest.update(b"\0")

lineage = {
    "node": node,
    "nodeDefinition": node_definition,
    "nodeFields": node_fields,
    "relevantTasks": relevant_tasks,
    "dependencyInputs": dependency_inputs,
    "sourceScopes": scopes,
    "sourceTreeSha256": source_digest.hexdigest(),
    "targetBranch": target_branch,
    "count": count,
    "authoritySha": authority_sha,
    "plannerTemplateSha": planner_sha,
    "criticPromptSha": critic_sha,
    "engineVersion": engine_version,
    "criticPolicyVersion": policy_version,
    "criticModelVersion": model_version,
    "revisionMax": revision_max,
    "sliceBudget": slice_budget,
    "operatorOverrideToken": override_token,
}
lineage_sha = hashlib.sha256(canonical(lineage).encode("utf-8")).hexdigest()
doc = {
    "schema": "singular.orchestration.plan-attempt-input.v2",
    "node": node,
    "baseSha": base_sha,
    "lineageSha256": lineage_sha,
    "lineage": lineage,
}
fd, tmp = tempfile.mkstemp(prefix=".plan-attempt-input.", dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, sort_keys=True); f.write("\n")
os.replace(tmp, path)
PY
  printf '%s' "$manifest"
}

singular_plan_attempt_identity() {
  local node="${1:-}" base_sha="${2:-}" stage_dir="${3:-}" worktree="${4:-.}"
  [[ -n "$node" && -d "$stage_dir" ]] || return 2
  [[ -n "$base_sha" ]] || base_sha="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || printf '%s' "")"

  # l1-plan-node writes this stable manifest before invoking the provider. It
  # deliberately excludes generated candidate bytes. Direct/test callers fall
  # back to other planner inputs, still excluding candidates.
  local stable_manifest="$stage_dir/plan-attempt-input.json"
  if [[ -f "$stable_manifest" ]]; then
    python3 - "$stable_manifest" <<'PY'
import hashlib
import json
import sys

raw = open(sys.argv[1], "rb").read()
doc = json.loads(raw)
lineage = doc.get("lineage")
if isinstance(lineage, dict):
    encoded = json.dumps(
        lineage, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    actual = hashlib.sha256(encoded).hexdigest()
    recorded = doc.get("lineageSha256")
    if recorded and recorded != actual:
        raise SystemExit("planning lineage manifest digest mismatch")
    print(actual)
else:
    # v1 compatibility: the complete stable manifest was the identity.
    print(hashlib.sha256(raw).hexdigest())
PY
    return
  fi

  local authority_file authority_sha="" planner_prompt planner_sha=""
  authority_file="$(singular_ctx_plan_critic_stage_file "$node" 2>/dev/null || printf '%s' "")"
  [[ -f "$authority_file" ]] && authority_sha="$(singular_sha256_file "$authority_file" 2>/dev/null || printf '%s' "")"
  planner_prompt="$stage_dir/planner-prompt.md"
  [[ -f "$planner_prompt" ]] || planner_prompt="${SINGULAR_ORCH_DIR}/prompts/l1-planner.md"
  [[ -f "$planner_prompt" ]] && planner_sha="$(singular_sha256_file "$planner_prompt" 2>/dev/null || printf '%s' "")"

  local engine_version="${SINGULAR_ENGINE_VERSION:-}"
  if [[ -z "$engine_version" && -f "${SINGULAR_ENGINE_DIR}/../VERSION" ]]; then
    engine_version="$(tr -d '[:space:]' < "${SINGULAR_ENGINE_DIR}/../VERSION")"
  fi
  local summary_sha=""
  [[ -f "$stage_dir/existing-tasks.md" ]] \
    && summary_sha="$(singular_sha256_file "$stage_dir/existing-tasks.md" 2>/dev/null || printf '%s' "")"
  python3 - "$node" "$base_sha" "$authority_sha" "$planner_sha" "$summary_sha" \
    "$engine_version" "${SINGULAR_PLAN_CRITIC_POLICY_VERSION:-1}" \
    "$(singular_plan_attempt_critic_model_version)" \
    "$(singular_plan_revise_max)" "${SINGULAR_PLAN_ATTEMPT_OVERRIDE_TOKEN:-}" <<'PY'
import hashlib, json, sys
keys = ("node", "baseSha", "authoritySha", "plannerPromptSha", "existingSummarySha",
        "engineVersion", "criticPolicyVersion", "criticModelVersion", "revisionMax",
        "operatorOverrideToken")
doc = dict(zip(keys, sys.argv[1:]))
raw = json.dumps(doc, sort_keys=True, separators=(",", ":")).encode("utf-8")
print(hashlib.sha256(raw).hexdigest())
PY
}

singular_plan_attempt_record_path() {
  local node="${1:-}" identity="${2:-}"
  [[ -n "$node" && "$identity" =~ ^[0-9a-f]{64}$ ]] || return 2
  local node_key; node_key="$(printf '%s' "$node" | tr -c 'A-Za-z0-9._-' '-')"
  printf '%s/planning-attempts/%s/%s/attempt.json' \
    "${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}" "$node_key" "$identity"
}

# Validate an existing durable attempt record under its per-record lock. Invalid
# JSON or an impossible identity/counter/status is never interpreted as a fresh
# budget. Preserve the exact bytes beside the record, replace the live record
# with a terminal tombstone, and emit one explicit event. Returns 3 when it had
# to quarantine, 0 for absent/valid state, and 2 when quarantine itself failed.
singular_plan_attempt_guard_state() {
  local record="${1:-}" identity="${2:-}" node="${3:-}" run_id="${4:-}" base_sha="${5:-}"
  [[ -n "$record" && -n "$identity" && -n "$node" ]] || return 2
  [[ -f "$record" ]] || return 0
  local outcome="" state="" quarantine="" error_type=""
  outcome="$(python3 - "$record" "$identity" "$node" "$run_id" "$base_sha" <<'PY'
import datetime
import fcntl
import json
import os
import sys
import tempfile

record, identity, node, run_id, base_sha = sys.argv[1:6]


def validate(doc):
    if not isinstance(doc, dict):
        raise ValueError("record-not-object")
    if doc.get("schema") != "singular.orchestration.plan-attempt.v1":
        raise ValueError("record-schema-invalid")
    if doc.get("identity") != identity:
        raise ValueError("record-identity-mismatch")
    if doc.get("node") != node:
        raise ValueError("record-node-mismatch")
    if doc.get("status", "active") not in {"active", "revising", "import", "park"}:
        raise ValueError("record-status-invalid")
    for key in (
        "initialAttempts", "initialInfraAttempts", "revisionsDone",
        "revisionInProgress", "infraAttempts",
    ):
        if key not in doc:
            continue
        value = doc[key]
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"record-counter-invalid:{key}")


with open(record + ".lock", "a+", encoding="utf-8") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    raw = open(record, "rb").read()
    try:
        doc = json.loads(raw.decode("utf-8"))
        validate(doc)
    except Exception as exc:
        directory = os.path.dirname(record)
        fd, quarantine = tempfile.mkstemp(
            prefix="attempt.corrupt.", suffix=".json", dir=directory
        )
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
        now = datetime.datetime.now(datetime.timezone.utc).replace(
            microsecond=0
        ).isoformat().replace("+00:00", "Z")
        tombstone = {
            "schema": "singular.orchestration.plan-attempt.v1",
            "identity": identity,
            "node": node,
            "baseSha": base_sha,
            "initialAttempts": 1,
            "initialInfraAttempts": 0,
            "revisionsDone": 0,
            "revisionInProgress": 0,
            "infraAttempts": 0,
            "status": "park",
            "terminalReason": "attempt-state-corrupt",
            "lastRunId": run_id,
            "corruptDetectedAt": now,
            "corruptSnapshotRef": os.path.basename(quarantine),
            "corruptErrorType": type(exc).__name__,
        }
        fd, temporary = tempfile.mkstemp(prefix=".attempt.", dir=directory)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(tombstone, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, record)
        print("corrupt\t{}\t{}".format(quarantine, type(exc).__name__))
        raise SystemExit(0)
print("valid")
PY
)" || return 2
  IFS=$'\t' read -r state quarantine error_type <<<"$outcome"
  [[ "$state" == "valid" ]] && return 0
  [[ "$state" == "corrupt" && -n "$quarantine" ]] || return 2
  singular_append_event "plan.attempt_state_quarantined" \
    "corrupt planning attempt state was preserved and durably parked" \
    "$(python3 - "$node" "$run_id" "$identity" "$record" "$quarantine" "$error_type" <<'PY'
import json, sys
node, run_id, identity, record, quarantine, error_type = sys.argv[1:7]
print(json.dumps({
    "node": node,
    "runId": run_id,
    "attemptIdentity": identity,
    "record": record,
    "quarantine": quarantine,
    "reason": "attempt-state-corrupt",
    "errorType": error_type,
}, separators=(",", ":")))
PY
)" || true
  return 3
}

# Read a durable terminal without creating or mutating it. Prints
# status<TAB>reason<TAB>terminalCandidateContextSha, or nothing.
singular_plan_attempt_terminal() {
  local node="${1:-}" identity="${2:-}" run_id="${3:-}" base_sha="${4:-}" record guard_rc=0
  record="$(singular_plan_attempt_record_path "$node" "$identity")" || return 2
  [[ -f "$record" ]] || return 1
  singular_plan_attempt_guard_state "$record" "$identity" "$node" "$run_id" "$base_sha" \
    || guard_rc=$?
  [[ "$guard_rc" -eq 0 || "$guard_rc" -eq 3 ]] || return 2
  python3 - "$record" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if d.get("status") not in {"import", "park"}: raise SystemExit(1)
print("{}\t{}\t{}".format(d.get("status", ""), d.get("terminalReason", ""),
                           d.get("terminalCandidateContextSha", "")))
PY
}

# Reserve the single logical initial planning attempt for a stable lineage. The
# provider may be retried under initialInfraAttempts, but initialAttempts remains
# one and is never reset by a restart.
singular_plan_attempt_begin_initial() {
  local node="${1:-}" identity="${2:-}" run_id="${3:-}" base_sha="${4:-}" record guard_rc=0
  record="$(singular_plan_attempt_record_path "$node" "$identity")" || return 2
  mkdir -p "$(dirname "$record")"
  singular_plan_attempt_guard_state "$record" "$identity" "$node" "$run_id" "$base_sha" \
    || guard_rc=$?
  [[ "$guard_rc" -eq 0 ]] || return "$guard_rc"
  python3 - "$record" "$identity" "$node" "$run_id" "$base_sha" <<'PY'
import fcntl, json, os, sys, tempfile
record, identity, node, run_id, base_sha = sys.argv[1:6]
with open(record + ".lock", "a+", encoding="utf-8") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    if os.path.exists(record):
        doc = json.load(open(record, encoding="utf-8"))
    else:
        doc = {
            "schema": "singular.orchestration.plan-attempt.v1",
            "identity": identity, "node": node, "baseSha": base_sha,
            "initialAttempts": 1, "initialInfraAttempts": 0,
            "revisionsDone": 0, "revisionInProgress": 0, "infraAttempts": 0,
            "status": "active", "terminalReason": "",
        }
    doc.setdefault("initialAttempts", 1)
    doc.setdefault("initialInfraAttempts", 0)
    doc["lastRunId"] = run_id
    fd, tmp = tempfile.mkstemp(prefix=".attempt.", dir=os.path.dirname(record))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True); f.write("\n")
    os.replace(tmp, record)
print(record)
PY
}

singular_plan_attempt_note_initial_infra() {
  local record="${1:-}" failure="${2:-planner-failed}"
  python3 - "$record" "$failure" <<'PY'
import fcntl, json, os, sys, tempfile
record, failure = sys.argv[1:3]
with open(record + ".lock", "a+", encoding="utf-8") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    doc = json.load(open(record, encoding="utf-8"))
    doc["initialInfraAttempts"] = int(doc.get("initialInfraAttempts", 0)) + 1
    doc["lastInitialInfraFailure"] = failure
    fd, tmp = tempfile.mkstemp(prefix=".attempt.", dir=os.path.dirname(record))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True); f.write("\n")
    os.replace(tmp, record)
print(doc["initialInfraAttempts"])
PY
}

# Print: identity<TAB>record<TAB>revisionsDone<TAB>status<TAB>reason<TAB>contextSha
#        <TAB>terminalCandidateMatch
singular_plan_attempt_prepare() {
  local node="${1:-}" run_id="${2:-}" base_sha="${3:-}" stage_dir="${4:-}" worktree="${5:-.}"
  local context_sha identity record sidecar="$stage_dir/.plan-attempt-identity.json" guard_rc=0
  context_sha="$(singular_plan_attempt_context_sha "$node" "$stage_dir")" || return 2

  # Candidate revisions change context but never the pre-provider lineage. Always
  # recompute that lineage from the current stable manifest; a stale stage
  # sidecar must not pin relevant new inputs to an old parked/imported identity.
  identity="$(singular_plan_attempt_identity "$node" "$base_sha" "$stage_dir" "$worktree")" || return 2
  record="$(singular_plan_attempt_record_path "$node" "$identity")" || return 2

  mkdir -p "$(dirname "$record")"
  singular_plan_attempt_guard_state "$record" "$identity" "$node" "$run_id" "$base_sha" \
    || guard_rc=$?
  [[ "$guard_rc" -eq 0 || "$guard_rc" -eq 3 ]] || return 2
  python3 - "$record" "$sidecar" "$identity" "$node" "$run_id" "$base_sha" \
    "$context_sha" <<'PY'
import datetime, fcntl, json, os, sys, tempfile
record, sidecar, identity, node, run_id, base_sha, context_sha = sys.argv[1:8]
os.makedirs(os.path.dirname(record), exist_ok=True)
lock_path = record + ".lock"
with open(lock_path, "a+", encoding="utf-8") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    if os.path.exists(record):
        doc = json.load(open(record, encoding="utf-8"))
        if doc.get("identity") != identity:
            raise SystemExit("planning attempt identity changed after validation")
    else:
        doc = {
            "schema": "singular.orchestration.plan-attempt.v1",
            "identity": identity,
            "node": node,
            "baseSha": base_sha,
            "initialContextSha": context_sha,
            "lastCandidateContextSha": context_sha,
            "revisionsDone": 0,
            "revisionInProgress": 0,
            "infraAttempts": 0,
            "status": "active",
            "terminalReason": "",
        }
    if not doc.get("initialContextSha"):
        doc["initialContextSha"] = context_sha
    if not doc.get("lastCandidateContextSha"):
        doc["lastCandidateContextSha"] = context_sha
    doc["lastRunId"] = run_id
    doc["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    fd, tmp = tempfile.mkstemp(prefix=".attempt.", dir=os.path.dirname(record))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True); f.write("\n")
    os.replace(tmp, record)

os.makedirs(os.path.dirname(sidecar), exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".attempt-identity.", dir=os.path.dirname(sidecar))
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump({"identity": identity}, f, separators=(",", ":")); f.write("\n")
os.replace(tmp, sidecar)
terminal_match = "yes" if (doc.get("terminalCandidateContextSha")
                            and doc.get("terminalCandidateContextSha") == context_sha) else "no"
print("{}\t{}\t{}\t{}\t{}\t{}\t{}".format(
    identity, record, int(doc.get("revisionsDone", 0)), doc.get("status", "active"),
    doc.get("terminalReason", ""), context_sha, terminal_match))
PY
}

# Return "repeat" only when the same normalized finding set is reported for a
# changed candidate context. Same-context restarts are cache/replay, not a new
# product failure.
singular_plan_attempt_note_critique() {
  local record="${1:-}" context_sha="${2:-}" critique="${3:-}"
  python3 - "$record" "$context_sha" "$critique" <<'PY'
import fcntl, hashlib, json, os, sys, tempfile
record, context_sha, critique = sys.argv[1:4]
with open(critique, encoding="utf-8") as f: result = json.load(f)
findings = sorted((str(x.get("id", "")), str(x.get("severity", "")))
                  for x in result.get("findings", []) if isinstance(x, dict))
fp = hashlib.sha256(json.dumps(findings, separators=(",", ":")).encode()).hexdigest()
with open(record + ".lock", "a+", encoding="utf-8") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    doc = json.load(open(record, encoding="utf-8"))
    repeat = bool(doc.get("lastCritiqueContextSha") not in (None, context_sha)
                  and doc.get("lastFindingFingerprint") == fp and findings)
    doc["lastCritiqueContextSha"] = context_sha
    doc["lastFindingFingerprint"] = fp
    fd, tmp = tempfile.mkstemp(prefix=".attempt.", dir=os.path.dirname(record))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True); f.write("\n")
    os.replace(tmp, record)
print("repeat" if repeat else "new")
PY
}

singular_plan_attempt_reserve_revision() {
  local record="${1:-}" max="${2:-}" run_id="${3:-}"
  python3 - "$record" "$max" "$run_id" <<'PY'
import fcntl, json, os, sys, tempfile
record, max_raw, run_id = sys.argv[1:4]
try: maximum = int(max_raw)
except Exception: print("park bad-max"); raise SystemExit
with open(record + ".lock", "a+", encoding="utf-8") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    doc = json.load(open(record, encoding="utf-8"))
    done = int(doc.get("revisionsDone", 0))
    active = int(doc.get("revisionInProgress", 0))
    if active:
        action = "revise {}".format(active)
    elif done >= maximum:
        action = "park revise-budget-exhausted"
    else:
        active = done + 1
        doc["revisionInProgress"] = active
        doc["infraAttempts"] = 0
        doc["status"] = "revising"
        doc["lastRunId"] = run_id
        action = "revise {}".format(active)
    fd, tmp = tempfile.mkstemp(prefix=".attempt.", dir=os.path.dirname(record))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True); f.write("\n")
    os.replace(tmp, record)
print(action)
PY
}

singular_plan_attempt_note_infra() {
  local record="${1:-}" failure="${2:-unknown}"
  python3 - "$record" "$failure" <<'PY'
import fcntl, json, os, sys, tempfile
record, failure = sys.argv[1:3]
with open(record + ".lock", "a+", encoding="utf-8") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    doc = json.load(open(record, encoding="utf-8"))
    doc["infraAttempts"] = int(doc.get("infraAttempts", 0)) + 1
    doc["lastInfraFailure"] = failure
    fd, tmp = tempfile.mkstemp(prefix=".attempt.", dir=os.path.dirname(record))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True); f.write("\n")
    os.replace(tmp, record)
print(int(doc["infraAttempts"]))
PY
}

singular_plan_attempt_complete_revision() {
  local record="${1:-}" context_sha="${2:-}"
  python3 - "$record" "$context_sha" <<'PY' >/dev/null
import fcntl, json, os, sys, tempfile
record, context_sha = sys.argv[1:3]
with open(record + ".lock", "a+", encoding="utf-8") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    doc = json.load(open(record, encoding="utf-8"))
    active = int(doc.get("revisionInProgress", 0))
    if active: doc["revisionsDone"] = max(int(doc.get("revisionsDone", 0)), active)
    doc["revisionInProgress"] = 0
    doc["infraAttempts"] = 0
    doc["status"] = "active"
    doc["lastCandidateContextSha"] = context_sha
    fd, tmp = tempfile.mkstemp(prefix=".attempt.", dir=os.path.dirname(record))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True); f.write("\n")
    os.replace(tmp, record)
PY
}

singular_plan_attempt_snapshot_candidates() {
  local record="${1:-}" context_sha="${2:-}" stage_dir="${3:-}" source_dir
  [[ -f "$record" && "$context_sha" =~ ^[0-9a-f]{64}$ && -d "$stage_dir" ]] || return 2
  source_dir="$(singular_task_batch_candidate_dir "$stage_dir")" || return 2
  local target="$(dirname "$record")/approved-candidates/$context_sha"
  python3 - "$source_dir" "$target" <<'PY'
import glob, os, shutil, sys, tempfile
source, target = sys.argv[1:3]
paths = sorted(glob.glob(os.path.join(source, "TASK-*.candidate.md")))
assert paths
os.makedirs(os.path.dirname(target), exist_ok=True)
if not os.path.isdir(target):
    tmp = tempfile.mkdtemp(prefix=".approved-candidates.", dir=os.path.dirname(target))
    try:
        for path in paths:
            shutil.copyfile(path, os.path.join(tmp, os.path.basename(path)))
        try: os.rename(tmp, target)
        except FileExistsError: pass
    finally:
        if os.path.isdir(tmp): shutil.rmtree(tmp)
print(target)
PY
}

singular_plan_attempt_restore_candidates() {
  local node="${1:-}" identity="${2:-}" stage_dir="${3:-}" record
  record="$(singular_plan_attempt_record_path "$node" "$identity")" || return 2
  [[ -f "$record" && -d "$stage_dir" ]] || return 2
  python3 - "$record" "$stage_dir" <<'PY'
import glob, json, os, shutil, sys, tempfile
record, stage = sys.argv[1:3]
doc = json.load(open(record, encoding="utf-8"))
sha = str(doc.get("terminalCandidateContextSha", ""))
source = os.path.join(os.path.dirname(record), "approved-candidates", sha)
paths = sorted(glob.glob(os.path.join(source, "TASK-*.candidate.md")))
assert sha and paths
tmp = tempfile.mkdtemp(prefix=".restore-candidates.", dir=stage)
try:
    for path in paths:
        shutil.copyfile(path, os.path.join(tmp, os.path.basename(path)))
    for path in sorted(glob.glob(os.path.join(tmp, "TASK-*.candidate.md"))):
        os.replace(path, os.path.join(stage, os.path.basename(path)))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PY
}

singular_plan_attempt_mark_terminal() {
  local record="${1:-}" status="${2:-park}" reason="${3:-}" run_id="${4:-}"
  local candidate_sha="${5:-}"
  local snapshot_ref="${6:-}"
  python3 - "$record" "$status" "$reason" "$run_id" "$candidate_sha" "$snapshot_ref" <<'PY' >/dev/null
import fcntl, json, os, sys, tempfile
record, status, reason, run_id, candidate_sha, snapshot_ref = sys.argv[1:7]
assert status in {"import", "park"}
with open(record + ".lock", "a+", encoding="utf-8") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    doc = json.load(open(record, encoding="utf-8"))
    doc["status"] = status
    doc["terminalReason"] = reason
    doc["lastRunId"] = run_id
    doc["revisionInProgress"] = 0
    if candidate_sha: doc["terminalCandidateContextSha"] = candidate_sha
    if snapshot_ref: doc["approvedCandidateSnapshotRef"] = snapshot_ref
    fd, tmp = tempfile.mkstemp(prefix=".attempt.", dir=os.path.dirname(record))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True); f.write("\n")
    os.replace(tmp, record)
PY
}
