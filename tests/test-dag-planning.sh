#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg: missing '$needle' in: $haystack"
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$msg: unexpected '$needle' in: $haystack"
}

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/areas/artifact" \
    "$root/docs/orchestration/gates" \
    "$root/docs/orchestration/prompts" \
    "$root/docs/orchestration/tasks" \
    "$root/schemas/orchestration" \
    "$root/.gluerun-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$root/docs/orchestration/prompts/l1-planner.md"
  cp "$ENGINE_HOME/schemas/task-batch.v0.schema.json" "$root/schemas/orchestration/task-batch.v0.schema.json"
  cp "$ENGINE_HOME/schemas/dag.v0.schema.json" "$root/schemas/orchestration/dag.v0.schema.json"
  cp "$ENGINE_HOME/schemas/gate-result.v0.schema.json" "$root/schemas/orchestration/gate-result.v0.schema.json"
  cat >"$root/docs/orchestration/project-state.md" <<'EOF'
# Project State
EOF
  cat >"$root/docs/orchestration/areas/artifact/state.md" <<'EOF'
# Area State: Artifact

Current status: complete
EOF
  cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "gluerun.orchestration.dag.v0",
  "layers": ["contract", "storage_substrate_base", "storage_proof"],
  "kinds": ["contract", "substrate", "storage"],
  "requiredNodes": ["S0.storage_substrate_base"],
  "nodes": [
    {
      "id": "D0.contract",
      "stage": "D0",
      "area": "kernel",
      "layer": "contract",
      "kind": "contract",
      "dependsOn": [],
      "requiredCompletion": "contract_complete"
    },
    {
      "id": "D1.contract",
      "stage": "D1",
      "area": "artifact",
      "layer": "contract",
      "kind": "contract",
      "dependsOn": ["D0.contract"],
      "requiredCompletion": "contract_complete"
    },
    {
      "id": "S0.storage_substrate_base",
      "stage": "S0",
      "area": "storage",
      "layer": "storage_substrate_base",
      "kind": "substrate",
      "dependsOn": ["D0.contract"],
      "requiredCompletion": "storage_substrate_ready"
    },
    {
      "id": "D1.storage_proof",
      "stage": "D1",
      "area": "artifact",
      "layer": "storage_proof",
      "kind": "storage",
      "dependsOn": ["D1.contract", "S0.storage_substrate_base"],
      "requiredCompletion": "storage_proof_complete"
    }
  ]
}
EOF
  cat >"$root/docs/orchestration/gates/D0.contract.gate-result.json" <<'EOF'
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "D0.contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "grandfathered",
  "evidence": [
    {
      "kind": "source-path",
      "ref": "internal/kernel",
      "description": "Existing D0 kernel contract package."
    }
  ],
  "decidedBy": "bootstrap",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  make_repo "$tmp/repo"
  export GLUERUN_ROOT="$tmp/repo"
  export GLUERUN_ORCH_DIR="$GLUERUN_ROOT/docs/orchestration"
  export GLUERUN_TASKS_DIR="$GLUERUN_ORCH_DIR/tasks"
  export GLUERUN_STATE_DIR="$GLUERUN_ROOT/.gluerun-state"
  export GLUERUN_RUNS_DIR="$GLUERUN_STATE_DIR/runs"
  export GLUERUN_INBOX_DIR="$GLUERUN_STATE_DIR/inbox"
  export GLUERUN_TARGET_BRANCH="target"
}

test_validate_dag_rejects_missing_storage_substrate() {
  with_fixture
  python3 - "$GLUERUN_ORCH_DIR/dag.v0.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["nodes"] = [n for n in data["nodes"] if n["id"] != "S0.storage_substrate_base"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  local out
  out="$("$SCRIPT_DIR/dag.sh" validate-dag 2>&1 || true)"
  assert_contains "$out" "missing required node" "validate-dag rejects DAG without a required node"
}

test_next_area_ignores_markdown_complete_status() {
  with_fixture
  local out
  out="$("$SCRIPT_DIR/dag.sh" next-area)"
  assert_contains "$out" "node=D1.contract" "next-area selected ungated D1 contract"
  assert_contains "$out" "area=artifact" "next-area selected artifact area"
}

test_area_gate_requires_authoritative_gate_result() {
  with_fixture
  local out
  out="$("$SCRIPT_DIR/dag.sh" area-gate D1.contract 2>&1 || true)"
  assert_contains "$out" "gate result not passed" "area-gate rejects missing gate result"
}

test_generate_tasks_dry_run_uses_manifest_frontier() {
  with_fixture
  local out state
  state="$(cat "$GLUERUN_ORCH_DIR/areas/artifact/state.md")"
  out="$("$SCRIPT_DIR/generate-tasks.sh" --dry-run --count 1 2>&1)"
  assert_contains "$out" "node=D1.contract" "generate dry-run reports manifest node"
  assert_contains "$out" "area=artifact" "generate dry-run reports manifest area"
  assert_contains "$(cat "$GLUERUN_ORCH_DIR/areas/artifact/state.md")" "$state" "generate dry-run leaves area state untouched"
}

make_area_complete_stub() {
  local stub="$1"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message|-o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 2
printf 'AREA-COMPLETE\n' >"$out"
EOF
  chmod +x "$stub"
}

test_area_complete_output_is_not_authoritative() {
  with_fixture
  local stub="$GLUERUN_ROOT/area-complete-stub.sh"
  make_area_complete_stub "$stub"
  local before after out
  before="$(cat "$GLUERUN_ORCH_DIR/areas/artifact/state.md")"
  out="$(GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --count 1 2>&1 || true)"
  after="$(cat "$GLUERUN_ORCH_DIR/areas/artifact/state.md")"
  assert_contains "$out" "planner-failed" "AREA-COMPLETE is rejected as non-authoritative"
  assert_not_contains "$out" "area-complete:artifact" "AREA-COMPLETE no longer completes the area"
  [[ "$before" == "$after" ]] || fail "AREA-COMPLETE mutated area state"
}

# Locate the prompt rendered by a --dry-run generate in the fixture's runs dir.
read_dry_run_prompt() {
  find "$GLUERUN_RUNS_DIR" -name planner-prompt.md -type f 2>/dev/null | head -1
}

# Codex stub that emits a single canonical task owning TWO independent slices
# (four owned files) — exercising the per-task owned-file count end to end.
make_fat_batch_stub() {
  local stub="$1"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message|-o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 2
python3 - "$out" <<'PY'
import json, sys
md = (
    "# TASK-0001: fat substrate slice\n\n"
    "Status: ready\n"
    "Area: storage\n"
    "Target branch: `target`\n"
    "Worker branch: `agent/storage/TASK-0001-fat`\n"
    "Test policy: `strict_test_first`\n"
    "Gate command: `go build ./... && go vet ./... && go test ./...`\n"
    "Dispatch mode: canonical\n"
    "Depends on: []\n\n"
    "## Objective\n\nFold two independent substrate slices into one task.\n\n"
    "## Scope\n\nOwned files:\n\n"
    "- `internal/storage/a.go`\n"
    "- `internal/storage/a_test.go`\n"
    "- `internal/storage/b.go`\n"
    "- `internal/storage/b_test.go`\n\n"
    "Forbidden files:\n\n- `internal/storage/doc.go`\n\n"
    "## Acceptance Criteria\n\n- Tests first demonstrate the two slices.\n"
)
batch = {
    "schema": "gluerun.orchestration.task-batch.v0",
    "tasks": [{"taskId": "TASK-0001", "markdown": md}],
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(batch, f)
PY
EOF
  chmod +x "$stub"
}

test_slice_budget_guardrail_contract_clamped_to_one() {
  with_fixture
  local out prompt
  out="$(GLUERUN_L2_SLICE_BUDGET=3 "$SCRIPT_DIR/generate-tasks.sh" --dry-run --count 1 2>&1)"
  assert_contains "$out" "node=D1.contract" "default frontier is the contract node"
  assert_contains "$out" "slice_budget=1" "contract layer clamps the slice budget to 1"
  prompt="$(read_dry_run_prompt)"
  [[ -n "$prompt" && -f "$prompt" ]] || fail "could not locate dry-run prompt file"
  assert_not_contains "$(cat "$prompt")" "[SLICE-BUDGET]" "prompt token fully substituted (contract)"
  assert_contains "$(cat "$prompt")" 'up to `1` mutually-independent slices' "contract prompt renders budget 1"
}

test_slice_budget_passthrough_on_unguarded_layer() {
  with_fixture
  local out prompt
  out="$(GLUERUN_L2_SLICE_BUDGET=3 "$SCRIPT_DIR/generate-tasks.sh" --dry-run --node S0.storage_substrate_base --count 1 2>&1)"
  assert_contains "$out" "node=S0.storage_substrate_base" "node override selected the substrate node"
  assert_contains "$out" "slice_budget=3" "unguarded layer keeps the configured slice budget"
  prompt="$(read_dry_run_prompt)"
  [[ -n "$prompt" && -f "$prompt" ]] || fail "could not locate dry-run prompt file"
  assert_not_contains "$(cat "$prompt")" "[SLICE-BUDGET]" "prompt token fully substituted (substrate)"
  assert_contains "$(cat "$prompt")" 'up to `3` mutually-independent slices' "substrate prompt renders budget 3"
}

test_slice_budget_clamped_to_max() {
  with_fixture
  local out
  out="$(GLUERUN_L2_SLICE_BUDGET=9 GLUERUN_L2_SLICE_BUDGET_MAX=3 "$SCRIPT_DIR/generate-tasks.sh" --dry-run --node S0.storage_substrate_base --count 1 2>&1)"
  assert_contains "$out" "slice_budget=3" "budget 9 clamps to the configured max of 3"
}

test_slice_budget_rejects_non_integer() {
  with_fixture
  local out rc=0
  out="$(GLUERUN_L2_SLICE_BUDGET=abc "$SCRIPT_DIR/generate-tasks.sh" --dry-run --count 1 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "non-integer slice budget must fail"
  assert_contains "$out" "GLUERUN_L2_SLICE_BUDGET must be an integer" "rejects non-integer slice budget"
}

test_slice_budget_fat_task_passes_validator() {
  with_fixture
  local stub="$GLUERUN_ROOT/fat-batch-stub.sh"
  make_fat_batch_stub "$stub"
  local out task
  out="$(GLUERUN_L2_SLICE_BUDGET=3 GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --node S0.storage_substrate_base --count 1 2>&1 || true)"
  assert_contains "$out" "generated:TASK-0001" "fat multi-owned-file task passes the batch validator"
  assert_contains "$out" "slice_budget=3" "substrate node keeps the configured budget"
  task="$(cat "$GLUERUN_TASKS_DIR/TASK-0001.md")"
  assert_contains "$task" "internal/storage/a_test.go" "generated fat task owns the first slice pair"
  assert_contains "$task" "internal/storage/b_test.go" "generated fat task owns the second slice pair"
}

test_validate_dag_rejects_cycle() {
  with_fixture
  python3 - "$GLUERUN_ORCH_DIR/dag.v0.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
for node in data["nodes"]:
    if node["id"] == "D0.contract":
        node["dependsOn"] = ["D1.contract"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  local out
  out="$("$SCRIPT_DIR/dag.sh" validate-dag 2>&1 || true)"
  assert_contains "$out" "cycle detected" "validate-dag rejects cycles"
}

test_validate_dag_rejects_duplicate_node_id() {
  with_fixture
  python3 - "$GLUERUN_ORCH_DIR/dag.v0.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["nodes"].append(dict(data["nodes"][0]))
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  local out
  out="$("$SCRIPT_DIR/dag.sh" validate-dag 2>&1 || true)"
  assert_contains "$out" "duplicate node id" "validate-dag rejects duplicate node ids"
}

test_validate_dag_rejects_unknown_layer() {
  with_fixture
  python3 - "$GLUERUN_ORCH_DIR/dag.v0.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["nodes"][0]["layer"] = "surprise"
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  local out
  out="$("$SCRIPT_DIR/dag.sh" validate-dag 2>&1 || true)"
  assert_contains "$out" "unknown layer" "validate-dag rejects unknown layers"
}

test_validate_dag_rejects_missing_dependency() {
  with_fixture
  python3 - "$GLUERUN_ORCH_DIR/dag.v0.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["nodes"][1]["dependsOn"] = ["D9.missing"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  local out
  out="$("$SCRIPT_DIR/dag.sh" validate-dag 2>&1 || true)"
  assert_contains "$out" "unknown dependency" "validate-dag rejects missing dependencies"
}

test_gate_result_missing_required_field_rejected() {
  with_fixture
  cat >"$GLUERUN_ORCH_DIR/gates/D1.contract.gate-result.json" <<'EOF'
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "D1.contract",
  "status": "passed",
  "authoritative": true
}
EOF
  local out rc=0
  out="$("$SCRIPT_DIR/dag.sh" area-gate D1.contract 2>&1)" || rc=$?
  assert_contains "$out" "missing required field" "malformed gate is rejected, not honored"
  assert_not_contains "$out" "gate-passed" "malformed gate must not be reported as passed"
  [[ "$rc" -ne 0 ]] || fail "malformed gate must cause a non-zero exit"
}

test_gate_result_rejects_malformed_evidence_object() {
  with_fixture
  cat >"$GLUERUN_ORCH_DIR/gates/D1.contract.gate-result.json" <<'EOF'
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "D1.contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "grandfathered",
  "evidence": [
    {
      "kind": "source-path",
      "ref": "internal/artifact",
      "surprise": "not allowed"
    }
  ],
  "decidedBy": "test",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
  local out rc=0
  out="$("$SCRIPT_DIR/dag.sh" area-gate D1.contract 2>&1)" || rc=$?
  assert_contains "$out" "unknown field" "nested evidence additional properties are rejected"
  [[ "$rc" -ne 0 ]] || fail "malformed evidence object must cause a non-zero exit"
}

test_deterministic_gate_requires_command_log_evidence() {
  with_fixture
  cat >"$GLUERUN_ORCH_DIR/gates/D1.contract.gate-result.json" <<'EOF'
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "D1.contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "deterministic-proof",
  "evidence": [
    {
      "kind": "source-path",
      "ref": "internal/artifact"
    }
  ],
  "decidedBy": "test",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
  local out rc=0
  out="$("$SCRIPT_DIR/dag.sh" area-gate D1.contract 2>&1)" || rc=$?
  assert_contains "$out" "requires command-log evidence" "deterministic gates require command-log evidence"
  [[ "$rc" -ne 0 ]] || fail "deterministic gate without command log must fail"
}

test_deterministic_gate_rejects_missing_log_file() {
  with_fixture
  local head
  head="$(git -C "$GLUERUN_ROOT" rev-parse HEAD)"
  cat >"$GLUERUN_ORCH_DIR/gates/D1.contract.gate-result.json" <<EOF
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "D1.contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "deterministic-proof",
  "evidence": [
    {
      "kind": "command-log",
      "ref": "missing-log",
      "command": "true",
      "exitCode": 0,
      "logRef": "docs/orchestration/gates/evidence/missing.log",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "headSha": "$head"
    }
  ],
  "decidedBy": "test",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
  local out rc=0
  out="$("$SCRIPT_DIR/dag.sh" area-gate D1.contract 2>&1)" || rc=$?
  assert_contains "$out" "logRef does not exist" "deterministic command log must exist"
  [[ "$rc" -ne 0 ]] || fail "missing command log must fail"
}

test_deterministic_gate_rejects_bad_log_digest() {
  with_fixture
  mkdir -p "$GLUERUN_ORCH_DIR/gates/evidence"
  printf 'ok\n' >"$GLUERUN_ORCH_DIR/gates/evidence/test.log"
  local head
  head="$(git -C "$GLUERUN_ROOT" rev-parse HEAD)"
  cat >"$GLUERUN_ORCH_DIR/gates/D1.contract.gate-result.json" <<EOF
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "D1.contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "deterministic-proof",
  "evidence": [
    {
      "kind": "command-log",
      "ref": "bad-digest",
      "command": "true",
      "exitCode": 0,
      "logRef": "docs/orchestration/gates/evidence/test.log",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "headSha": "$head"
    }
  ],
  "decidedBy": "test",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
  local out rc=0
  out="$("$SCRIPT_DIR/dag.sh" area-gate D1.contract 2>&1)" || rc=$?
  assert_contains "$out" "sha256 mismatch" "deterministic command log digest must match"
  [[ "$rc" -ne 0 ]] || fail "bad command log digest must fail"
}

test_deterministic_gate_accepts_valid_command_log() {
  with_fixture
  mkdir -p "$GLUERUN_ORCH_DIR/gates/evidence"
  printf 'ok\n' >"$GLUERUN_ORCH_DIR/gates/evidence/test.log"
  local digest head
  digest="$(shasum -a 256 "$GLUERUN_ORCH_DIR/gates/evidence/test.log" | awk '{print $1}')"
  head="$(git -C "$GLUERUN_ROOT" rev-parse HEAD)"
  cat >"$GLUERUN_ORCH_DIR/gates/D1.contract.gate-result.json" <<EOF
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "D1.contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "deterministic-proof",
  "evidence": [
    {
      "kind": "command-log",
      "ref": "valid-log",
      "command": "true",
      "exitCode": 0,
      "logRef": "docs/orchestration/gates/evidence/test.log",
      "sha256": "$digest",
      "headSha": "$head"
    }
  ],
  "decidedBy": "test",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
  local out
  out="$("$SCRIPT_DIR/dag.sh" area-gate D1.contract)"
  assert_contains "$out" "gate-passed node=D1.contract" "valid deterministic command log gate passes"
}

test_generate_tasks_frozen_by_stop() {
  with_fixture
  touch "$GLUERUN_STATE_DIR/STOP"
  local out
  out="$("$SCRIPT_DIR/generate-tasks.sh" --dry-run --count 1 2>&1)"
  assert_contains "$out" "frozen" "generate-tasks halts under the STOP sentinel"
  assert_not_contains "$out" "node=D1.contract" "generate-tasks selects no frontier under STOP"
  [[ "$(find "$GLUERUN_TASKS_DIR" -name 'TASK-*.md' -type f 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] \
    || fail "STOP must prevent task writes"
}

test_l1_drive_frozen_by_stop() {
  with_fixture
  cat >"$GLUERUN_TASKS_DIR/TASK-0001.md" <<'EOF'
# TASK-0001: Frozen dispatch fixture

Status: ready
Area: artifact
Target branch: `target`
Worker branch: `agent/artifact/TASK-0001-frozen-dispatch`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Exercise STOP.

## Scope

Owned files:

- `internal/artifact/frozen.go`

Forbidden files:

- Any file outside the owned scope unless an L1 scope amendment is recorded.

## Prerequisites

- D0.

## Acceptance Criteria

- Pass.
EOF
  git -C "$GLUERUN_ROOT" add docs/orchestration/tasks/TASK-0001.md
  git -C "$GLUERUN_ROOT" -c user.name=test -c user.email=test@example.local commit -q -m task
  touch "$GLUERUN_STATE_DIR/STOP"
  local out
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 --dry-run 2>&1)"
  assert_contains "$out" "frozen" "l1-drive halts under STOP"
  assert_not_contains "$out" "L1 drive:" "l1-drive must not dispatch under STOP"
}

write_passed_gate() {
  # args: node source-ref — emit a minimal valid grandfathered passing gate.
  cat >"$GLUERUN_ORCH_DIR/gates/$1.gate-result.json" <<EOF
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "$1",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "grandfathered",
  "evidence": [ { "kind": "source-path", "ref": "$2", "description": "test gate" } ],
  "decidedBy": "test",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
}

write_blocked_gate() {
  # args: node source-ref — emit a minimal valid authoritative blocked gate.
  cat >"$GLUERUN_ORCH_DIR/gates/$1.gate-result.json" <<EOF
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "$1",
  "status": "blocked",
  "authoritative": true,
  "evidenceClass": "deterministic-proof",
  "evidence": [ { "kind": "source-path", "ref": "$2", "description": "blocked fixture" } ],
  "decidedBy": "test",
  "rationale": "$1 is blocked by fixture evidence.",
  "recordedAt": "2026-06-03T00:00:00Z"
}
EOF
}

test_next_areas_returns_independent_ready_nodes() {
  with_fixture
  local out
  out="$("$SCRIPT_DIR/dag.sh" next-areas)"
  assert_contains "$out" '"node":"D1.contract"' "next-areas surfaces ready D1 contract"
  assert_contains "$out" '"node":"S0.storage_substrate_base"' "next-areas surfaces ready storage substrate"
  assert_not_contains "$out" '"node":"D1.storage_proof"' "next-areas excludes a node whose deps are ungated"
}

test_next_areas_deterministic_dag_order() {
  with_fixture
  local out prefix
  out="$("$SCRIPT_DIR/dag.sh" next-areas)"
  prefix="${out%%S0.storage_substrate_base*}"
  assert_contains "$prefix" '"node":"D1.contract"' "next-areas emits nodes in DAG declaration order"
}

test_next_areas_no_virtual_completion() {
  with_fixture
  write_passed_gate D1.contract internal/artifact
  local out
  out="$("$SCRIPT_DIR/dag.sh" next-areas)"
  assert_contains "$out" '"node":"S0.storage_substrate_base"' "S0 stays ready after D1.contract is gated"
  assert_not_contains "$out" '"node":"D1.contract"' "a freshly gated node leaves the frontier"
  assert_not_contains "$out" '"node":"D1.storage_proof"' "dependent stays excluded while its dep S0 is only in progress (no virtual completion)"
}

test_next_areas_failed_gate_does_not_advance() {
  with_fixture
  cat >"$GLUERUN_ORCH_DIR/gates/S0.storage_substrate_base.gate-result.json" <<'EOF'
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "S0.storage_substrate_base",
  "status": "failed",
  "authoritative": true,
  "evidenceClass": "grandfathered",
  "evidence": [ { "kind": "source-path", "ref": "internal/storage", "description": "test gate" } ],
  "decidedBy": "test",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
  local out
  out="$("$SCRIPT_DIR/dag.sh" next-areas)"
  assert_contains "$out" '"node":"S0.storage_substrate_base"' "a failed gate keeps the node in the frontier"
  assert_not_contains "$out" '"node":"D1.storage_proof"' "a failed dependency gate excludes dependents"
  out="$("$SCRIPT_DIR/dag.sh" node-fields S0.storage_substrate_base)"
  assert_contains "$out" "node=S0.storage_substrate_base" "failed own gate remains eligible for replanning"
}

test_next_areas_excludes_authoritative_blocked_gate() {
  with_fixture
  write_blocked_gate D1.contract internal/artifact
  local out
  out="$("$SCRIPT_DIR/dag.sh" next-areas)"
  assert_not_contains "$out" '"node":"D1.contract"' "authoritative blocked gates are excluded from planning frontier"
  assert_contains "$out" '"node":"S0.storage_substrate_base"' "independent ready nodes remain eligible"
  assert_not_contains "$out" '"allComplete":true' "blocked-but-unpassed nodes are not treated as all complete"
}

test_next_area_skips_authoritative_blocked_gate_to_next_eligible_node() {
  with_fixture
  write_blocked_gate D1.contract internal/artifact
  local out
  out="$("$SCRIPT_DIR/dag.sh" next-area)"
  assert_contains "$out" "node=S0.storage_substrate_base" "next-area skips blocked node and selects next eligible node"
  assert_not_contains "$out" "node=D1.contract" "next-area must not plan authoritative blocked node"
}

test_node_fields_rejects_authoritative_blocked_gate() {
  with_fixture
  write_blocked_gate D1.contract internal/artifact
  local out rc=0
  out="$("$SCRIPT_DIR/dag.sh" node-fields D1.contract 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "node-fields must reject authoritative blocked gates"
  assert_contains "$out" "node has authoritative blocked gate: D1.contract" "node-fields explains blocked-gate ineligibility"
}

test_next_areas_all_complete() {
  with_fixture
  write_passed_gate D1.contract internal/artifact
  write_passed_gate S0.storage_substrate_base internal/storage
  write_passed_gate D1.storage_proof internal/artifact
  local out
  out="$("$SCRIPT_DIR/dag.sh" next-areas)"
  assert_contains "$out" '"allComplete":true' "every node gated reports allComplete"
  assert_contains "$out" '"frontier":[]' "every node gated yields an empty frontier"
}

test_next_area_backcompat_unchanged() {
  with_fixture
  local out
  out="$("$SCRIPT_DIR/dag.sh" next-area)"
  assert_contains "$out" "node=D1.contract" "next-area still emits its key=value line format"
  assert_not_contains "$out" "frontier" "next-area output is untouched by next-areas"
}

test_validate_dag_rejects_missing_storage_substrate
test_next_area_ignores_markdown_complete_status
test_area_gate_requires_authoritative_gate_result
test_generate_tasks_dry_run_uses_manifest_frontier
test_area_complete_output_is_not_authoritative
test_slice_budget_guardrail_contract_clamped_to_one
test_slice_budget_passthrough_on_unguarded_layer
test_slice_budget_clamped_to_max
test_slice_budget_rejects_non_integer
test_slice_budget_fat_task_passes_validator
test_validate_dag_rejects_cycle
test_validate_dag_rejects_duplicate_node_id
test_validate_dag_rejects_unknown_layer
test_validate_dag_rejects_missing_dependency
test_gate_result_missing_required_field_rejected
test_gate_result_rejects_malformed_evidence_object
test_deterministic_gate_requires_command_log_evidence
test_deterministic_gate_rejects_missing_log_file
test_deterministic_gate_rejects_bad_log_digest
test_deterministic_gate_accepts_valid_command_log
test_next_areas_returns_independent_ready_nodes
test_next_areas_deterministic_dag_order
test_next_areas_no_virtual_completion
test_next_areas_failed_gate_does_not_advance
test_next_areas_excludes_authoritative_blocked_gate
test_next_area_skips_authoritative_blocked_gate_to_next_eligible_node
test_node_fields_rejects_authoritative_blocked_gate
test_next_areas_all_complete
test_next_area_backcompat_unchanged
test_generate_tasks_frozen_by_stop
test_l1_drive_frozen_by_stop

echo "dag planning tests passed"
