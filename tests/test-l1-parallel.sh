#!/usr/bin/env bash
set -euo pipefail

# Regression tests for the live (opt-in) L1 parallel fanout: gluerun_l1_fanout +
# gluerun_l1_import_staged, generate-tasks.sh staged mode, and l1-plan-node.sh.
# Pure bash + fixtures; NO real codex (planners are stubbed). Verifies that L0
# stays the only serial importer/id-allocator and that STOP/disk/failure/
# validation all fail closed.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-l1-parallel.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Hermetic guard: this checkout may itself be docked as a gluerun consumer
# (gluerun.config.json at the repo root). Source lib.sh against a pristine
# empty root so no consumer config (runner, areaPrefix, env{}) leaks into
# test sandboxes; each test exports its own GLUERUN_ROOT afterwards.
export GLUERUN_ROOT="$(mktemp -d)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/gates" \
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
  cp "$ENGINE_HOME/schemas/l1-lease.v0.schema.json" "$root/schemas/orchestration/l1-lease.v0.schema.json"
  # Two independent ready nodes (disjoint areas): D1.contract (artifact) and
  # S0.storage_substrate_base (storage); D1.storage_proof is NOT ready.
  cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "gluerun.orchestration.dag.v0",
  "nodes": [
    { "id": "D0.contract", "stage": "D0", "area": "kernel", "layer": "contract", "kind": "contract", "dependsOn": [], "requiredCompletion": "contract_complete" },
    { "id": "D1.contract", "stage": "D1", "area": "artifact", "layer": "contract", "kind": "contract", "dependsOn": ["D0.contract"], "requiredCompletion": "contract_complete" },
    { "id": "S0.storage_substrate_base", "stage": "S0", "area": "storage", "layer": "storage_substrate_base", "kind": "substrate", "dependsOn": ["D0.contract"], "requiredCompletion": "storage_substrate_ready" },
    { "id": "D1.storage_proof", "stage": "D1", "area": "artifact", "layer": "storage_proof", "kind": "storage", "dependsOn": ["D1.contract", "S0.storage_substrate_base"], "requiredCompletion": "storage_proof_complete" }
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
  "evidence": [ { "kind": "source-path", "ref": "internal/kernel", "description": "test gate" } ],
  "decidedBy": "test",
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
	  export GLUERUN_LEASES_DIR="$GLUERUN_STATE_DIR/leases"
	  export GLUERUN_EVENTS_FILE="$GLUERUN_STATE_DIR/events.ndjson"
	  export GLUERUN_PLANNER_BACKOFF_FILE="$GLUERUN_STATE_DIR/planner-backoff.json"
	  export GLUERUN_BREAKER_FILE="$GLUERUN_STATE_DIR/circuit.json"
	  export GLUERUN_STATUS_FILE="$GLUERUN_STATE_DIR/STATUS.md"
  # Re-point STOP at the fixture: lib.sh was sourced once (with the real repo),
  # so GLUERUN_STOP_FILE would otherwise still reference the real STOP sentinel and
  # the in-process fanout would (read-only) see it and abort.
  export GLUERUN_STOP_FILE="$GLUERUN_STATE_DIR/STOP"
  export GLUERUN_TARGET_BRANCH="target"
  export GLUERUN_L1_LEASES_DIR="$GLUERUN_STATE_DIR/l1-leases"
  export GLUERUN_L1_LEASE_SCHEMA="$GLUERUN_ROOT/schemas/orchestration/l1-lease.v0.schema.json"
  export GLUERUN_GATE_SCHEMA="$GLUERUN_ROOT/schemas/orchestration/gate-result.v0.schema.json"
  export GLUERUN_REAL_SCRIPT_DIR="$SCRIPT_DIR"
  # Reset all tunables to a clean baseline each test (the test shell is shared).
  export GLUERUN_MAX_L1_CONCURRENT=2
  export GLUERUN_L1_TASKS_PER_NODE=1
  export GLUERUN_MIN_DISK_GB=0
	  unset GLUERUN_TEST_FAIL_NODE GLUERUN_TEST_BADAREA_NODE GLUERUN_L1_PLAN_NODE GLUERUN_CODEX_RUNNER GLUERUN_L1_PLANNER GLUERUN_ENABLE_L1_PARALLEL GLUERUN_AUTO_INTEGRATE GLUERUN_PUSH GLUERUN_AUTO_PROMOTE_GATES GLUERUN_MAX_CONSEC_FAILS 2>/dev/null || true
	}

make_structured_quota_evidence() {
  local run_id="${1:-RUN-quota}" provider="${2:-codex}" status="${3:-429}"
  local dir="$GLUERUN_RUNS_DIR/$run_id"
  mkdir -p "$dir"
  case "$provider:$status" in
    claude:403)
      printf '%s\n' \
        '{"type":"result","subtype":"error","is_error":true,"api_error_status":403,"result":"Organization has disabled subscription access for Claude Code."}' \
        >"$dir/provider-envelope.json"
      ;;
    claude:*)
      printf '{"type":"result","subtype":"error","is_error":true,"api_error_status":%s,"result":"provider unavailable"}\n' \
        "$status" >"$dir/provider-envelope.json"
      ;;
    *)
      printf '{"type":"turn.failed","error":{"status":%s,"code":"rate_limit_exceeded","message":"request rejected"}}\n' \
        "$status" >"$dir/provider-envelope.json"
      ;;
  esac
  gluerun_runner_result_write "$provider" "$run_id" planner planner-core \
    "$dir/runner-result.json" 1 "$dir/provider-envelope.json" "" ""
  printf '%s\n' "$dir/runner-result.json"
}

# A drop-in l1-plan-node stub: creates the node's active lease (real area) and
# stages one candidate. Honors GLUERUN_TEST_FAIL_NODE (exit 1, lease failed) and
# GLUERUN_TEST_BADAREA_NODE (stage a candidate with the wrong area).
make_plan_stub() {
  cat >"$1" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
source "$GLUERUN_REAL_SCRIPT_DIR/lib.sh"
node=""; run_id=""; stage_dir=""; base_sha=""; count=1
while [[ $# -gt 0 ]]; do case "$1" in
  --node) node="$2"; shift 2;; --run-id) run_id="$2"; shift 2;;
  --stage-dir) stage_dir="$2"; shift 2;; --base-sha) base_sha="$2"; shift 2;;
  --count) count="$2"; shift 2;; *) shift;; esac; done
export GLUERUN_EVENTS_FILE="$stage_dir/planner-events.ndjson"
mkdir -p "$stage_dir"
fields="$("$GLUERUN_REAL_SCRIPT_DIR/dag.sh" node-fields "$node")" || { echo "plan-failed:$node"; exit 1; }
area="$(printf '%s\n' "$fields" | sed -n 's/^area=//p' | tail -1)"
stage="$(printf '%s\n' "$fields" | sed -n 's/^stage=//p' | tail -1)"
layer="$(printf '%s\n' "$fields" | sed -n 's/^layer=//p' | tail -1)"
[[ -n "$base_sha" ]] || base_sha="$(git -C "$GLUERUN_ROOT" rev-parse "$GLUERUN_TARGET_BRANCH")"
gluerun_l1_lease_write "$node" "$area" "$stage" "$layer" active "$run_id" "$base_sha" "$GLUERUN_TARGET_BRANCH"
if [[ "${GLUERUN_TEST_FAIL_NODE:-}" == "$node" ]]; then
  gluerun_l1_lease_set_status "$node" failed || true
  echo "plan-failed:$node"; exit 1
fi
emit_area="$area"
[[ "${GLUERUN_TEST_BADAREA_NODE:-}" == "$node" ]] && emit_area="wrong-area"
safe="${node//[^A-Za-z0-9]/_}"
cat >"$stage_dir/TASK-0001.candidate.md" <<EOF
# TASK-0001: Staged fixture $node

Status: ready
Area: $emit_area
Target branch: \`$GLUERUN_TARGET_BRANCH\`
Worker branch: \`agent/$emit_area/TASK-0001-staged-$safe\`
Test policy: \`strict_test_first\`
Gate command: \`true\`
Dispatch mode: canonical
Depends on: []

## Objective

Staged stub for $node.

## Scope

Owned files:

- \`internal/$area/staged_$safe.go\`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Pass.
EOF
echo "planned:$node"
STUB
  chmod +x "$1"
}

# A codex-runner stub that emits a single-task markdown for whatever area the
# generated planner prompt names (exercises the REAL generate-tasks.sh staged path).
make_codex_md_stub() {
  cat >"$1" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
out=""; prompt=""
while [[ $# -gt 0 ]]; do case "$1" in
  --output-last-message|-o) out="$2"; shift 2;;
  --prompt-file) prompt="$2"; shift 2;;
  *) shift;; esac; done
[[ -n "$out" ]] || exit 2
area="$(sed -n 's/^- area: `\(.*\)`$/\1/p' "$prompt" | tail -1)"
[[ -n "$area" ]] || area="artifact"
cat >"$out" <<EOF
# TASK-0001: Stub task

Status: ready
Area: $area
Target branch: \`target\`
Worker branch: \`agent/$area/TASK-0001-stub\`
Test policy: \`strict_test_first\`
Gate command: \`true\`
Dispatch mode: canonical
Depends on: []

## Objective

Stub.

## Scope

Owned files:

- \`internal/$area/stub.go\`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Pass.
EOF
STUB
  chmod +x "$1"
}

	make_codex_batch_mismatched_id_stub() {
  cat >"$1" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
out=""; prompt=""
while [[ $# -gt 0 ]]; do case "$1" in
  --output-last-message|-o) out="$2"; shift 2;;
  --prompt-file) prompt="$2"; shift 2;;
  *) shift;; esac; done
[[ -n "$out" ]] || exit 2
area="$(sed -n 's/^- area: `\(.*\)`$/\1/p' "$prompt" | tail -1)"
[[ -n "$area" ]] || area="artifact"
cat >"$out" <<EOF
{
  "schema": "gluerun.orchestration.task-batch.v0",
  "tasks": [
    {
      "taskId": "TASK-0313",
      "markdown": "# TASK-0313: Stub batch task\n\nStatus: ready\nArea: $area\nTarget branch: \`target\`\nWorker branch: \`agent/$area/TASK-0313-stub-batch\`\nTest policy: \`strict_test_first\`\nGate command: \`true\`\nDispatch mode: canonical\nDepends on: []\n\n## Objective\n\nStub.\n\n## Scope\n\nOwned files:\n\n- \`internal/$area/stub_batch.go\`\n\nForbidden files:\n\n- Any file outside the owned scope.\n\n## Acceptance Criteria\n\n- Pass."
    }
  ]
}
EOF
STUB
	  chmod +x "$1"
	}

make_codex_quota_stub() {
	  cat >"$1" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "You've hit your usage limit. Try again at 11:21 AM." >&2
source "$GLUERUN_REAL_SCRIPT_DIR/lib.sh"
envelope="$(dirname "$GLUERUN_RUNNER_RESULT_FILE")/planner-provider-envelope.json"
printf '%s\n' '{"type":"turn.failed","error":{"status":429,"code":"rate_limit_exceeded","message":"request rejected"}}' >"$envelope"
gluerun_runner_result_write codex "${GLUERUN_RUNNER_RUN_ID:-RUN-stub}" \
  "${GLUERUN_RUNNER_ROLE:-planner}" "${GLUERUN_RUNNER_CAPABILITY_PROFILE:-planner-core}" \
  "$GLUERUN_RUNNER_RESULT_FILE" 1 "$envelope" "" ""
exit 1
STUB
	  chmod +x "$1"
	}

	make_codex_marker_stub() {
	  local marker="$2"
	  cat >"$1" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >"$marker"
exit 1
STUB
	  chmod +x "$1"
	}

	write_signature_task() {
	  local task_id="$1" status="$2" area="$3" title="$4" objective="$5" owned="$6"
	  cat >"$GLUERUN_TASKS_DIR/$task_id.md" <<EOF
# $task_id: $title

Status: $status
Area: $area
Target branch: \`target\`
Worker branch: \`agent/$area/$task_id-fixture\`
Test policy: \`strict_test_first\`
Gate command: \`true\`
Dispatch mode: canonical
Depends on: []

## Objective

$objective

## Scope

Owned files:

- \`$owned\`

Forbidden files:

- Any file outside the owned scope.
EOF
	}

write_blocked_gate() {
  local node="$1" source_path="$2" missing_task="$3"
  cat >"$GLUERUN_ORCH_DIR/gates/$node.gate-result.json" <<EOF
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "$node",
  "status": "blocked",
  "authoritative": true,
  "evidenceClass": "deterministic-proof",
  "evidence": [
    {
      "kind": "source-path",
      "ref": "$source_path",
      "description": "blocked fixture source"
    },
    {
      "kind": "task-set",
      "ref": "$node-unmet-readiness-tasks",
      "description": "blocked fixture missing task set",
      "taskIds": ["$missing_task"]
    }
  ],
  "decidedBy": "test",
  "rationale": "$node is blocked on unmet task-set evidence.",
  "recordedAt": "2026-06-03T00:00:00Z"
}
EOF
}

task_count() { find "$GLUERUN_TASKS_DIR" -maxdepth 1 -name 'TASK-*.md' -type f 2>/dev/null | wc -l | tr -d ' '; }

# --- generate-tasks.sh staged mode (real planner, codex stub) ---

test_generate_tasks_staged_writes_only_to_stage_dir() {
  with_fixture
  local stub="$GLUERUN_ROOT/codex-stub.sh"; make_codex_md_stub "$stub"
  local sdir="$GLUERUN_STATE_DIR/stage-S0"
  local out
  out="$(GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --node S0.storage_substrate_base --stage-dir "$sdir" --count 1 2>&1)"
  assert_contains "$out" "staged:TASK-0001" "staged mode reports staged: with the node-local temp id"
  [[ -f "$sdir/TASK-0001.candidate.md" ]] || fail "staged candidate must be written to the stage dir"
  assert_eq "$(task_count)" "0" "staged mode must NOT write the global tasks dir"
}

test_generate_tasks_staged_batch_rewrites_planner_id_to_temp_id() {
  with_fixture
  local stub="$GLUERUN_ROOT/codex-batch-stub.sh"; make_codex_batch_mismatched_id_stub "$stub"
  local sdir="$GLUERUN_STATE_DIR/stage-S0"
  local out
  out="$(GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --node S0.storage_substrate_base --stage-dir "$sdir" --count 1 2>&1)"
  assert_contains "$out" "staged:TASK-0001" "staged batch mode reports the rewritten node-local temp id"
  [[ -f "$sdir/TASK-0001.candidate.md" ]] || fail "staged batch candidate must be written using the expected temp id"
  assert_eq "$(gluerun_task_field "$sdir/TASK-0001.candidate.md" taskId 2>/dev/null || echo '')" "TASK-0001" "staged batch candidate taskId is rewritten"
  assert_not_contains "$(cat "$sdir/TASK-0001.candidate.md")" "TASK-0313" "staged batch candidate must not retain the planner's global-looking id"
  assert_eq "$(task_count)" "0" "staged batch rewrite must NOT write the global tasks dir"
}

test_generate_tasks_prompt_directs_slice_folding() {
  with_fixture
  export GLUERUN_L2_SLICE_BUDGET=3
  export GLUERUN_L2_SLICE_BUDGET_MAX=3
  local sdir="$GLUERUN_STATE_DIR/stage-S0" out prompt
  out="$("$SCRIPT_DIR/generate-tasks.sh" --dry-run --node S0.storage_substrate_base --stage-dir "$sdir" --count 3 2>&1)"
  assert_contains "$out" "slice_budget=3" "dry-run reports effective slice budget"
  prompt="$(find "$GLUERUN_RUNS_DIR" -name planner-prompt.md -type f | sort | tail -1)"
  [[ -f "$prompt" ]] || fail "dry-run must assemble a planner prompt"
  local body
  body="$(cat "$prompt")"
  assert_contains "$body" "you MUST fold independent same-node slices" "planner prompt directs folding"
  assert_contains "$body" "Do not split" "planner prompt forbids avoidable single-slice splitting"
  assert_contains "$body" "ceil(N / 3)" "planner prompt gives task-count expectation"
  assert_not_contains "$body" "you may fold" "planner prompt must not make folding optional"
}

test_generate_tasks_backcompat_unchanged() {
  with_fixture
  local stub="$GLUERUN_ROOT/codex-stub.sh"; make_codex_md_stub "$stub"
  local out
  out="$(GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --count 1 2>&1)"
  assert_contains "$out" "generated:TASK-0001" "non-staged mode still writes a real task id"
	  [[ -f "$GLUERUN_TASKS_DIR/TASK-0001.md" ]] || fail "non-staged mode must write the global tasks dir (back-compat)"
	}

	test_generate_tasks_logs_quota_failure_and_sets_backoff() {
	  with_fixture
	  local stub="$GLUERUN_ROOT/codex-quota-stub.sh"; make_codex_quota_stub "$stub"
	  local sdir="$GLUERUN_STATE_DIR/stage-S0" out rc=0
	  out="$(GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --node S0.storage_substrate_base --stage-dir "$sdir" --count 1 2>&1)" || rc=$?
	  [[ "$rc" -ne 0 ]] || fail "quota planner failure must exit non-zero"
	  assert_contains "$out" "planner-failed" "quota failure reports planner-failed"
	  local log
	  log="$(find "$GLUERUN_RUNS_DIR" -name planner-codex.log -type f | sort | tail -1)"
	  [[ -f "$log" ]] || fail "planner codex log must be preserved"
	  assert_contains "$(cat "$log")" "usage limit" "planner codex log contains quota text"
	  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"failureClass":"quota"' "planner.failed event classifies quota"
	  [[ -f "$GLUERUN_PLANNER_BACKOFF_FILE" ]] || fail "quota failure must set planner backoff state"
	}

	test_generate_tasks_honors_active_planner_backoff_without_calling_codex() {
	  with_fixture
	  mkdir -p "$(dirname "$GLUERUN_PLANNER_BACKOFF_FILE")"
	  python3 - "$GLUERUN_PLANNER_BACKOFF_FILE" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"schema":"gluerun.orchestration.planner-backoff.v0","until":"2999-01-01T00:00:00Z","failureClass":"quota"}, f)
    f.write("\n")
PY
	  local marker="$GLUERUN_STATE_DIR/codex-called.txt" stub="$GLUERUN_ROOT/codex-marker-stub.sh"
	  make_codex_marker_stub "$stub" "$marker"
	  local sdir="$GLUERUN_STATE_DIR/stage-S0" out rc=0
	  out="$(GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --node S0.storage_substrate_base --stage-dir "$sdir" --count 1 2>&1)" || rc=$?
	  [[ "$rc" -ne 0 ]] || fail "planner backoff should return non-zero to count as no progress"
	  assert_contains "$out" "planner-backoff" "active backoff is reported"
	  [[ ! -f "$marker" ]] || fail "codex runner must not be called while planner backoff is active"
	  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" "planner.backoff_active" "backoff emits an event"
	  assert_eq "$(task_count)" "0" "backoff must not create tasks"
	}

test_reconcile_defers_serial_planning_during_active_backoff() {
  with_fixture
  GLUERUN_PLANNER_BACKOFF_SECONDS=120 gluerun_planner_backoff_set codex-exit RUN-b D1.contract /dev/null
  local marker="$GLUERUN_STATE_DIR/serial-planner-called" stub="$GLUERUN_ROOT/serial-planner.sh"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
touch "$GLUERUN_STATE_DIR/serial-planner-called"
exit 99
STUB
  chmod +x "$stub"
  local out
  out="$(GLUERUN_ENABLE_L1_PARALLEL=0 GLUERUN_CODEX_RUNNER="$stub" \
    GLUERUN_AUTO_PROMOTE_GATES=0 GLUERUN_AUTO_INTEGRATE=0 GLUERUN_PUSH=0 \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)"
  assert_contains "$out" "planner_backoff_active_this_run=1" "serial reconcile reports deferred backoff"
  assert_contains "$out" "planner_failures_this_run=0" "serial backoff deferral is neutral"
  [[ ! -f "$marker" ]] || fail "serial planner ran during active backoff"
  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" "origin.planner_deferred_backoff" \
    "serial backoff deferral emits telemetry"
}

test_reconcile_defers_parallel_planning_before_leases() {
  with_fixture
  GLUERUN_PLANNER_BACKOFF_SECONDS=120 gluerun_planner_backoff_set timeout RUN-b D1.contract /dev/null
  local marker="$GLUERUN_STATE_DIR/parallel-planner-called" stub="$GLUERUN_ROOT/parallel-planner.sh"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
touch "$GLUERUN_STATE_DIR/parallel-planner-called"
exit 99
STUB
  chmod +x "$stub"
  local out
  out="$(GLUERUN_ENABLE_L1_PARALLEL=1 GLUERUN_L1_PLAN_NODE="$stub" \
    GLUERUN_AUTO_PROMOTE_GATES=0 GLUERUN_AUTO_INTEGRATE=0 GLUERUN_PUSH=0 \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)"
  assert_contains "$out" "planner_backoff_active_this_run=1" "parallel reconcile reports deferred backoff"
  assert_contains "$out" "planner_failures_this_run=0" "parallel backoff deferral is neutral"
  [[ ! -f "$marker" ]] || fail "parallel planner ran during active backoff"
  if [[ -d "$GLUERUN_L1_LEASES_DIR" ]] && find "$GLUERUN_L1_LEASES_DIR" -type f | grep -q .; then
    fail "parallel backoff deferral created an L1 lease"
  fi
}

test_generate_tasks_honors_blocked_gate_without_calling_codex() {
  with_fixture
  write_blocked_gate D1.contract internal/artifact TASK-0099
  local marker="$GLUERUN_STATE_DIR/codex-called.txt" stub="$GLUERUN_ROOT/codex-marker-stub.sh"
  make_codex_marker_stub "$stub" "$marker"
  local sdir="$GLUERUN_STATE_DIR/stage-D1" out rc=0
  out="$(GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --node D1.contract --stage-dir "$sdir" --count 1 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "blocked gate should return non-zero to count as no progress"
  assert_contains "$out" "planner-failed" "blocked gate is reported before planner invocation"
  assert_contains "$out" "node has authoritative blocked gate: D1.contract" "blocked-gate planner failure names the gated node"
  [[ ! -f "$marker" ]] || fail "codex runner must not be called for a blocked closeout gate"
  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" "planner.failed" "blocked gate emits a planner.failed event"
  assert_eq "$(task_count)" "0" "blocked gate must not create tasks"
}

# --- full chain: fanout -> real l1-plan-node -> real generate-tasks -> import ---

test_fanout_full_chain_two_nodes_unique_ids() {
  with_fixture
  local stub="$GLUERUN_ROOT/codex-stub.sh"; make_codex_md_stub "$stub"
  local out plan_root artifact_prompt storage_prompt
  out="$(GLUERUN_CODEX_RUNNER="$stub" gluerun_l1_fanout RUN-chain "$(git -C "$GLUERUN_ROOT" rev-parse target)" 2>&1)"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^generated:')" "2" "fanout imports both planned nodes"
  [[ -f "$GLUERUN_TASKS_DIR/TASK-0001.md" && -f "$GLUERUN_TASKS_DIR/TASK-0002.md" ]] \
    || fail "two staged batches must import as distinct sequential real ids"
  plan_root="$GLUERUN_RUNS_DIR/RUN-chain/l1-staging"
  artifact_prompt="$plan_root/D1.contract/planner-prompt.md"
  storage_prompt="$plan_root/S0.storage_substrate_base/planner-prompt.md"
  [[ -f "$artifact_prompt" && -f "$storage_prompt" ]] \
    || fail "concurrent planners must persist prompts in their node-private staging directories"
  assert_contains "$(cat "$artifact_prompt")" '- area: `artifact`' "artifact node keeps its own planner prompt"
  assert_contains "$(cat "$storage_prompt")" '- area: `storage`' "storage node keeps its own planner prompt"
  [[ -f "$plan_root/D1.contract/planner-out.md" && -f "$plan_root/S0.storage_substrate_base/planner-out.md" ]] \
    || fail "concurrent planners must persist provider output in their node-private staging directories"
  [[ ! -e "$GLUERUN_RUNS_DIR/RUN-chain/planner-prompt.md" && ! -e "$GLUERUN_RUNS_DIR/RUN-chain/planner-out.md" ]] \
    || fail "parallel planners must not fall back to shared parent-run artifacts"
  assert_eq "$(gluerun_l1_lease_status D1.contract)" "released" "planned node lease is released after import"
  assert_eq "$(gluerun_l1_lease_status S0.storage_substrate_base)" "released" "planned node lease is released after import"
}

# --- fanout edge cases via the l1-plan-node stub ---

test_fanout_default_cap_two() {
  with_fixture
  local stub="$GLUERUN_ROOT/plan-stub.sh"; make_plan_stub "$stub"
  local out
  out="$(GLUERUN_L1_PLAN_NODE="$stub" gluerun_l1_fanout RUN-cap "$(git -C "$GLUERUN_ROOT" rev-parse target)" 2>&1)"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^generated:')" "2" "default cap plans two independent nodes"
  assert_eq "$(task_count)" "2" "two tasks imported"
}

test_fanout_unique_ids_from_same_temp_id() {
  with_fixture
  local stub="$GLUERUN_ROOT/plan-stub.sh"; make_plan_stub "$stub"
  GLUERUN_L1_PLAN_NODE="$stub" gluerun_l1_fanout RUN-ids "$(git -C "$GLUERUN_ROOT" rev-parse target)" >/dev/null 2>&1
  # Both stubs stage the SAME temp id TASK-0001; the serial importer must assign
  # distinct sequential real ids (this is the race the design eliminates).
  [[ -f "$GLUERUN_TASKS_DIR/TASK-0001.md" && -f "$GLUERUN_TASKS_DIR/TASK-0002.md" ]] \
    || fail "same temp ids must import as TASK-0001 and TASK-0002"
  assert_eq "$(task_count)" "2" "exactly two distinct tasks"
}

test_fanout_cap_override_one() {
  with_fixture
  local stub="$GLUERUN_ROOT/plan-stub.sh"; make_plan_stub "$stub"
  local out
  out="$(GLUERUN_MAX_L1_CONCURRENT=1 GLUERUN_L1_PLAN_NODE="$stub" gluerun_l1_fanout RUN-1 "$(git -C "$GLUERUN_ROOT" rev-parse target)" 2>&1)"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^generated:')" "1" "cap=1 plans exactly one node"
  assert_eq "$(task_count)" "1" "cap=1 imports one task"
  # DAG order: D1.contract precedes S0; only the first is leased.
  [[ -f "$(gluerun_l1_lease_path D1.contract)" ]] || fail "cap=1 should lease the first DAG-order node"
  [[ ! -f "$(gluerun_l1_lease_path S0.storage_substrate_base)" ]] || fail "cap=1 must not lease the second node"
}

test_fanout_excludes_authoritative_blocked_gate() {
  with_fixture
  write_blocked_gate D1.contract internal/artifact TASK-0099
  local stub="$GLUERUN_ROOT/plan-stub.sh"; make_plan_stub "$stub"
  local out
  out="$(GLUERUN_L1_PLAN_NODE="$stub" gluerun_l1_fanout RUN-blocked "$(git -C "$GLUERUN_ROOT" rev-parse target)" 2>&1)"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^generated:')" "1" "fanout plans only the unblocked ready node"
  assert_eq "$(task_count)" "1" "fanout imports only one task"
  [[ ! -f "$(gluerun_l1_lease_path D1.contract)" ]] || fail "fanout must not lease an authoritative blocked node"
  [[ -f "$(gluerun_l1_lease_path S0.storage_substrate_base)" ]] || fail "fanout should lease the unblocked ready node"
  assert_contains "$(cat "$GLUERUN_TASKS_DIR/TASK-0001.md")" "S0.storage_substrate_base" "imported task comes from the unblocked node"
}

		test_fanout_one_failure_isolated() {
  with_fixture
  local stub="$GLUERUN_ROOT/plan-stub.sh"; make_plan_stub "$stub"
  local out
  out="$(GLUERUN_TEST_FAIL_NODE=S0.storage_substrate_base GLUERUN_L1_PLAN_NODE="$stub" \
        gluerun_l1_fanout RUN-fail "$(git -C "$GLUERUN_ROOT" rev-parse target)" 2>&1)"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^generated:')" "1" "a failed planner does not discard the other's batch"
  assert_eq "$(task_count)" "1" "the successful node still imports"
  assert_eq "$(gluerun_l1_lease_status S0.storage_substrate_base)" "failed" "the failed node's lease is marked failed"
	  assert_eq "$(gluerun_l1_lease_status D1.contract)" "released" "the successful node's lease is released"
	}

	test_fanout_reports_planner_failures_for_breaker_accounting() {
	  with_fixture
	  local stub="$GLUERUN_ROOT/plan-stub.sh"; make_plan_stub "$stub"
	  local out
	  out="$(GLUERUN_TEST_FAIL_NODE=S0.storage_substrate_base GLUERUN_L1_PLAN_NODE="$stub" \
	        gluerun_l1_fanout RUN-fail-count "$(git -C "$GLUERUN_ROOT" rev-parse target)" 2>&1)"
	  assert_contains "$out" "l1_planner_failures=1" "fanout reports planner failure count"
	  assert_contains "$out" "l1_import_rejections=0" "fanout reports import rejection count"
	}

	test_autonomate_counts_planner_failures_against_breaker() {
	  with_fixture
	  local stub="$GLUERUN_ROOT/reconcile-planner-fail-stub.sh"
	  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "glueRun-go origin reconcile (actuate)"
echo "dispatched_this_run=0"
echo "failed_dispatches=0"
echo "integrated_this_run=0"
echo "failed_integrations=0"
echo "planner_failures_this_run=1"
echo "l1_import_rejections_this_run=0"
STUB
	  chmod +x "$stub"
	  local out
	  out="$(GLUERUN_RECONCILE_SCRIPT="$stub" "$SCRIPT_DIR/autonomate.sh" --once 2>&1 || true)"
	  assert_contains "$out" "planner_failures_this_run=1" "autonomate sees planner failure count from reconcile"
	  assert_contains "$out" "breaker -> 1" "autonomate trips breaker on no-progress planner failure"
	  assert_eq "$(gluerun_breaker_count)" "1" "planner failure increments the circuit breaker"
	}

# A reconcile stub that fails the test if autonomate ever calls it (used to prove
# the quota-window path skips the cycle entirely).
write_reconcile_should_not_run_stub() {
  cat >"$1" <<'STUB'
#!/usr/bin/env bash
echo "RECONCILE_WAS_CALLED"
echo "planner_failures_this_run=1"
STUB
  chmod +x "$1"
}

# An active quota backoff means a Claude/codex session usage limit is open. The
# loop must SLEEP through it (auto-recover when it resets), NOT trip the breaker,
# and NOT invoke reconcile (which would burn quota).
test_autonomate_sleeps_through_quota_window_without_breaker() {
  with_fixture
  local evidence
  evidence="$(make_structured_quota_evidence RUN-q)"
  GLUERUN_PLANNER_QUOTA_BACKOFF_SECONDS=120 \
    gluerun_planner_backoff_set quota RUN-q D1.contract "$evidence"
  local stub="$GLUERUN_ROOT/reconcile-should-not-run.sh"
  write_reconcile_should_not_run_stub "$stub"
  local out
  out="$(GLUERUN_QUOTA_SLEEP_CAP=1 GLUERUN_RECONCILE_SCRIPT="$stub" "$SCRIPT_DIR/autonomate.sh" --once 2>&1 || true)"
  assert_contains "$out" "quota window open" "autonomate detects the open quota window"
  assert_not_contains "$out" "RECONCILE_WAS_CALLED" "autonomate does NOT run reconcile during a quota window"
  assert_eq "$(gluerun_breaker_count)" "0" "sleeping through a quota window does not trip the breaker"
}

# Non-quota backoffs still permit reconcile, but a repeated planner refusal is
# neutral while the backoff remains valid.
test_autonomate_nonquota_backoff_neutralizes_repeated_planner_failure() {
  with_fixture
  GLUERUN_PLANNER_BACKOFF_SECONDS=120 gluerun_planner_backoff_set timeout RUN-t D1.contract /dev/null
  local stub="$GLUERUN_ROOT/reconcile-planner-fail.sh"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
echo "dispatched_this_run=0"
echo "failed_dispatches=0"
echo "integrated_this_run=0"
echo "failed_integrations=0"
echo "planner_failures_this_run=1"
echo "l1_import_rejections_this_run=0"
STUB
  chmod +x "$stub"
  local out
  out="$(GLUERUN_RECONCILE_SCRIPT="$stub" "$SCRIPT_DIR/autonomate.sh" --once 2>&1 || true)"
  assert_not_contains "$out" "quota window open" "non-quota backoff is not treated as a quota window"
  assert_contains "$out" "planner refusal neutral" "active non-quota backoff is explicitly neutral"
  assert_eq "$(gluerun_breaker_count)" "0" "repeated planner refusal under active backoff does not count"
}

test_autonomate_nonquota_backoff_still_counts_unrelated_failure() {
  with_fixture
  GLUERUN_PLANNER_BACKOFF_SECONDS=120 gluerun_planner_backoff_set codex-exit RUN-t D1.contract /dev/null
  local stub="$GLUERUN_ROOT/reconcile-dispatch-fail.sh"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
echo "dispatched_this_run=0"
echo "failed_dispatches=1"
echo "integrated_this_run=0"
echo "failed_integrations=0"
echo "planner_failures_this_run=1"
echo "planner_backoff_active_this_run=1"
echo "l1_import_rejections_this_run=0"
STUB
  chmod +x "$stub"
  local out
  out="$(GLUERUN_RECONCILE_SCRIPT="$stub" "$SCRIPT_DIR/autonomate.sh" --once 2>&1 || true)"
  assert_contains "$out" "planner refusal neutral" "planner component is neutralized"
  assert_contains "$out" "breaker -> 1" "unrelated dispatch failure still trips breaker"
  assert_eq "$(gluerun_breaker_count)" "1" "unrelated failure counts during planner backoff"
}

# An EXPIRED quota backoff must fail open: the predicate ignores it, so the loop
# proceeds to a normal cycle instead of sleeping forever.
test_autonomate_expired_quota_backoff_falls_through() {
  with_fixture
  python3 - "$GLUERUN_PLANNER_BACKOFF_FILE" <<'PY'
import json, sys
json.dump({"schema": "gluerun.orchestration.planner-backoff.v0", "failureClass": "quota", "until": "2000-01-01T00:00:00Z"}, open(sys.argv[1], "w"))
PY
  local stub="$GLUERUN_ROOT/reconcile-marker.sh"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
echo "RECONCILE_RAN"
echo "dispatched_this_run=0"
echo "failed_dispatches=0"
echo "integrated_this_run=0"
echo "failed_integrations=0"
echo "planner_failures_this_run=0"
echo "l1_import_rejections_this_run=0"
STUB
  chmod +x "$stub"
  local out
  out="$(GLUERUN_RECONCILE_SCRIPT="$stub" "$SCRIPT_DIR/autonomate.sh" --once 2>&1 || true)"
  assert_not_contains "$out" "quota window open" "expired quota backoff is ignored"
  assert_contains "$out" "RECONCILE_RAN" "loop proceeds to reconcile when the backoff has expired"
}

# A pathologically long quota window must not idle forever: once the cumulative
# wait reaches the budget the loop escalates to STOP rather than sleeping on.
test_autonomate_quota_wait_budget_sets_stop() {
  with_fixture
  local evidence
  evidence="$(make_structured_quota_evidence RUN-q)"
  GLUERUN_PLANNER_QUOTA_BACKOFF_SECONDS=120 \
    gluerun_planner_backoff_set quota RUN-q D1.contract "$evidence"
  local stub="$GLUERUN_ROOT/reconcile-should-not-run.sh"
  write_reconcile_should_not_run_stub "$stub"
  local out
  out="$(GLUERUN_QUOTA_WAIT_BUDGET=0 GLUERUN_RECONCILE_SCRIPT="$stub" "$SCRIPT_DIR/autonomate.sh" --once 2>&1 || true)"
  assert_contains "$out" "quota wait budget exhausted" "budget exhaustion is reported"
  [[ -f "$GLUERUN_STOP_FILE" ]] || fail "budget exhaustion should set the STOP sentinel"
  assert_not_contains "$out" "RECONCILE_WAS_CALLED" "budget-exhaustion path does not run reconcile"
}

# --- C2: limit/403 sleep-through at the breaker chokepoint -----------------------
# A recent structured runner result carrying a provider limit is detected so the
# breaker chokepoint can sleep through instead of tripping.
test_cycle_limit_window_detected_finds_marker() {
  with_fixture
  make_structured_quota_evidence RUN-limit claude 529 >/dev/null
  gluerun_cycle_limit_window_detected \
    || fail "a recent structured usage-limit/overload result must be detected"
}

# Model-authored artifacts must NOT be evidence even when they carry markers --
# audit verdicts and prompt files echo repo prose (the 0.4.0 false-backoff bug).
test_cycle_limit_window_ignores_model_authored_artifacts() {
  with_fixture
  mkdir -p "$GLUERUN_RUNS_DIR/RUN-artifacts"
  cat >"$GLUERUN_RUNS_DIR/RUN-artifacts/audit.json" <<'EOF'
{"rationale":"the quota banner shows: rate limit exceeded"}
EOF
  cat >"$GLUERUN_RUNS_DIR/RUN-artifacts/l2-prompt.md" <<'EOF'
Implement the quota exceeded banner per api_error_status fixtures.
EOF
  if gluerun_cycle_limit_window_detected; then
    fail "audit.json/prompt .md content must never arm a limit window"
  fi
}

# The 403 organization-disabled-subscription window (the 6th-trip mode) is an
# entitlement block, not quota, but is equally un-healable by spinning -> detect.
test_cycle_limit_window_detected_finds_403_org_disabled() {
  with_fixture
  make_structured_quota_evidence RUN-403 claude 403 >/dev/null
  gluerun_cycle_limit_window_detected \
    || fail "a structured 403 org-disabled-subscription result must be detected"
}

# A plain code failure with no limit markers must NOT look like a limit window
# (fail-closed: the breaker still trips on real failures).
test_cycle_limit_window_detected_ignores_plain_failure() {
  with_fixture
  mkdir -p "$GLUERUN_RUNS_DIR/RUN-real"
  cat >"$GLUERUN_RUNS_DIR/RUN-real/worker.log" <<'EOF'
compile error: undefined: Foo
exit status 2
EOF
  if gluerun_cycle_limit_window_detected; then fail "a plain code failure with no limit markers must NOT be detected as a limit window"; fi
}

# A stale (out-of-window) limit marker is ignored so an old window cannot mask a
# fresh real failure forever.
test_cycle_limit_window_detected_ignores_stale_marker() {
  with_fixture
  local result
  result="$(make_structured_quota_evidence RUN-old)"
  touch -t 200001010000 "$result" "$GLUERUN_RUNS_DIR/RUN-old"
  if GLUERUN_LIMIT_SCAN_WINDOW_SEC=900 gluerun_cycle_limit_window_detected; then fail "a stale out-of-window limit marker must NOT be detected"; fi
}

# Chokepoint behavior: a no-progress cycle with structured provider evidence
# arms a quota backoff (for C1 to sleep through) and does NOT trip the breaker.
test_autonomate_limit_induced_failure_arms_backoff_not_breaker() {
  with_fixture
  make_structured_quota_evidence RUN-cycle >/dev/null
  local stub="$GLUERUN_ROOT/reconcile-limit-fail.sh"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
echo "dispatched_this_run=0"
echo "failed_dispatches=1"
echo "integrated_this_run=0"
echo "failed_integrations=0"
echo "planner_failures_this_run=0"
echo "l1_import_rejections_this_run=0"
STUB
  chmod +x "$stub"
  local out
  out="$(GLUERUN_RECONCILE_SCRIPT="$stub" "$SCRIPT_DIR/autonomate.sh" --once 2>&1 || true)"
  assert_contains "$out" "structured provider limit evidence" "a limit-induced cycle is recognized at the chokepoint"
  assert_not_contains "$out" "breaker -> 1" "a limit window does NOT trip the breaker"
  assert_eq "$(gluerun_breaker_count)" "0" "a limit window leaves the breaker at zero"
  [[ -f "$GLUERUN_PLANNER_BACKOFF_FILE" ]] || fail "a limit window arms a quota backoff for the next iteration to sleep through"
  assert_contains "$(cat "$GLUERUN_PLANNER_BACKOFF_FILE")" '"failureClass": "quota"' "the armed backoff is a quota window"
  assert_contains "$(cat "$GLUERUN_PLANNER_BACKOFF_FILE")" 'runner-result.json' "the armed backoff carries result evidence"
}

# Import rejections alone are never limit-eligible: even with a genuine limit
# marker in a runner log, a rejections-only failure cycle trips the breaker
# (0.4.0 armed a false 30-minute backoff here -- the field audit's top defect).
test_autonomate_import_rejections_never_arm_backoff() {
  with_fixture
  make_structured_quota_evidence RUN-rej >/dev/null
  local stub="$GLUERUN_ROOT/reconcile-reject-fail.sh"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
echo "dispatched_this_run=0"
echo "failed_dispatches=0"
echo "integrated_this_run=0"
echo "failed_integrations=0"
echo "planner_failures_this_run=0"
echo "l1_import_rejections_this_run=1"
STUB
  chmod +x "$stub"
  local out
  out="$(GLUERUN_RECONCILE_SCRIPT="$stub" "$SCRIPT_DIR/autonomate.sh" --once 2>&1 || true)"
  assert_contains "$out" "breaker -> 1" "rejections-only failures trip the breaker"
  [[ -f "$GLUERUN_PLANNER_BACKOFF_FILE" ]] && fail "import rejections must never arm a quota backoff"
  true
}

# Safety: with C2 detection active, a real failure (no limit markers anywhere in
# this cycle's run logs) STILL trips the breaker.
test_autonomate_real_failure_still_trips_with_detection_active() {
  with_fixture
  mkdir -p "$GLUERUN_RUNS_DIR/RUN-real"
  cat >"$GLUERUN_RUNS_DIR/RUN-real/worker.log" <<'EOF'
compile error: undefined: Foo
EOF
  local stub="$GLUERUN_ROOT/reconcile-real-fail.sh"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
echo "dispatched_this_run=0"
echo "failed_dispatches=1"
echo "integrated_this_run=0"
echo "failed_integrations=0"
echo "planner_failures_this_run=0"
echo "l1_import_rejections_this_run=0"
STUB
  chmod +x "$stub"
  local out
  out="$(GLUERUN_RECONCILE_SCRIPT="$stub" "$SCRIPT_DIR/autonomate.sh" --once 2>&1 || true)"
  assert_contains "$out" "breaker -> 1" "a real failure with no limit markers still trips the breaker"
  assert_eq "$(gluerun_breaker_count)" "1" "a real failure increments the breaker even with C2 detection active"
  assert_not_contains "$out" "LIMIT/403-induced" "a real failure is not misclassified as a limit window"
}

test_fanout_invalid_staged_imports_nothing_for_that_node() {
  with_fixture
  local stub="$GLUERUN_ROOT/plan-stub.sh"; make_plan_stub "$stub"
  local out
  out="$(GLUERUN_TEST_BADAREA_NODE=D1.contract GLUERUN_L1_PLAN_NODE="$stub" \
        gluerun_l1_fanout RUN-bad "$(git -C "$GLUERUN_ROOT" rev-parse target)" 2>&1)"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^generated:')" "1" "only the valid node imports"
  assert_eq "$(gluerun_l1_lease_status D1.contract)" "failed" "an invalid staged batch marks the node failed"
  [[ ! -f "$GLUERUN_TASKS_DIR/TASK-0001.md" ]] && true  # one valid task imported as some id
  assert_eq "$(task_count)" "1" "the invalid batch imports nothing"
}

# --- frontier scope guard reads the CONFIGURED area map (not hardcoded internal/) ---

test_frontier_scope_guard_excludes_conflict_via_configured_area_map() {
  with_fixture
  # Active L1 lease on an out-of-frontier node (area kernel) whose write scope
  # overlaps frontier area "artifact" ONLY under the configured map
  # (artifact=src/shared/). The old hardcoded internal/artifact/ scope would
  # never conflict with src/shared/, so this proves the guard reads the map.
  gluerun_l1_lease_write D0.contract kernel D0 contract active RUN-scope abc1234 target '["src/shared/"]'
  local out
  out="$(GLUERUN_AREA_PATHS=$'artifact=src/shared/\nstorage=src/storage/' gluerun_select_l1_frontier 2)"
  assert_not_contains "$out" "D1.contract" "configured-scope overlap with an active lease excludes the node"
  assert_contains "$out" "S0.storage_substrate_base" "non-overlapping mapped area is still selected"
}

test_frontier_scope_guard_batch_overlap_via_configured_area_map() {
  with_fixture
  # Both frontier areas map onto the SAME configured scope -> only the first
  # DAG-order node may be selected within one batch.
  local out
  out="$(GLUERUN_AREA_PATHS=$'artifact=src/shared/\nstorage=src/shared/' gluerun_select_l1_frontier 2)"
  assert_contains "$out" "D1.contract" "first DAG-order node is selected"
  assert_not_contains "$out" "S0.storage_substrate_base" "second node sharing the configured scope is excluded from the batch"
}

test_frontier_scope_guard_honors_area_prefix() {
  with_fixture
  # areaPrefix variant: with GLUERUN_AREA_PREFIX=src/, area artifact's scope is
  # src/artifact/ -> conflicts with an active lease scoped to src/artifact/.
  gluerun_l1_lease_write D0.contract kernel D0 contract active RUN-prefix abc1234 target '["src/artifact/"]'
  local out
  out="$(GLUERUN_AREA_PREFIX=src/ gluerun_select_l1_frontier 2)"
  assert_not_contains "$out" "D1.contract" "areaPrefix-derived scope overlap excludes the node"
  assert_contains "$out" "S0.storage_substrate_base" "non-overlapping areaPrefix-derived scope is still selected"
}

test_fanout_stop_blocks() {
  with_fixture
  local stub="$GLUERUN_ROOT/plan-stub.sh"; make_plan_stub "$stub"
  touch "$GLUERUN_STATE_DIR/STOP"
  local out
  out="$(GLUERUN_L1_PLAN_NODE="$stub" gluerun_l1_fanout RUN-stop "$(git -C "$GLUERUN_ROOT" rev-parse target)" 2>&1)"
  assert_eq "$(task_count)" "0" "STOP must prevent any import"
  [[ -z "$(find "$GLUERUN_L1_LEASES_DIR" -name '*.json' 2>/dev/null)" ]] || fail "STOP must create no L1 leases"
  assert_contains "$(cat "$GLUERUN_EVENTS_FILE" 2>/dev/null || true)" "origin.fanout_aborted" "STOP fanout emits an abort event"
}

test_fanout_disk_blocks() {
  with_fixture
  local stub="$GLUERUN_ROOT/plan-stub.sh"; make_plan_stub "$stub"
  local out
  out="$(GLUERUN_MIN_DISK_GB=99999999 GLUERUN_L1_PLAN_NODE="$stub" \
        gluerun_l1_fanout RUN-disk "$(git -C "$GLUERUN_ROOT" rev-parse target)" 2>&1)"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^generated:')" "0" "low disk blocks all fanout imports"
  assert_eq "$(task_count)" "0" "low disk must not create global tasks"
  [[ -z "$(find "$GLUERUN_L1_LEASES_DIR" -name '*.json' 2>/dev/null)" ]] || fail "low disk must create no L1 leases"
  [[ ! -d "$GLUERUN_RUNS_DIR/RUN-disk/l1-staging" ]] || fail "low disk must create no L1 staging"
  assert_contains "$(cat "$GLUERUN_EVENTS_FILE" 2>/dev/null || true)" "origin.disk_pressure" "low disk emits a disk_pressure event"
  assert_contains "$(cat "$GLUERUN_EVENTS_FILE" 2>/dev/null || true)" "origin.fanout_aborted" "low disk emits a fanout_aborted event"
}

test_rewrite_task_id_token_is_token_safe() {
  with_fixture
  local f="$GLUERUN_STATE_DIR/rewrite.md"
  printf '%s\n' '# TASK-0001: x' 'dep TASK-0010 and TASK-00011 and TASK-0001 again' > "$f"
  gluerun_rewrite_task_id_token "$f" TASK-0001 TASK-0003
  local out; out="$(cat "$f")"
  assert_contains "$out" "TASK-0003" "the exact id token is rewritten"
  assert_not_contains "$out" "TASK-0001 " "no bare TASK-0001 token remains"
  assert_contains "$out" "TASK-0010" "a longer token sharing the prefix is untouched"
  assert_contains "$out" "TASK-00011" "another longer token is untouched"
}

test_import_fails_closed_on_missing_lease() {
  with_fixture
  local sdir="$GLUERUN_RUNS_DIR/RUN-nolease/l1-staging/S0.storage_substrate_base"
  mkdir -p "$sdir"
  printf '%s\n' '# TASK-0001: x' '' 'Status: ready' 'Area: storage' 'Dispatch mode: canonical' '' '## Scope' '' 'Owned files:' '' '- `internal/storage/x.go`' > "$sdir/TASK-0001.candidate.md"
  # No lease written for the node.
  gluerun_l1_import_staged RUN-nolease S0.storage_substrate_base >/dev/null 2>&1 || true
  assert_eq "$(task_count)" "0" "import must fail closed (import nothing) when the lease is missing"
}

	test_import_rejects_candidate_without_taskid() {
  with_fixture
  gluerun_l1_lease_write S0.storage_substrate_base storage S0 storage_substrate_base active RUN-x abc1234 target
  local sdir="$GLUERUN_RUNS_DIR/RUN-noid/l1-staging/S0.storage_substrate_base"
  mkdir -p "$sdir"
  # Valid shape but NO "# TASK-...:" header -> taskId is empty.
  printf '%s\n' '# Missing id header' '' 'Status: ready' 'Area: storage' 'Dispatch mode: canonical' '' '## Scope' '' 'Owned files:' '' '- `internal/storage/x.go`' > "$sdir/TASK-0001.candidate.md"
  gluerun_l1_import_staged RUN-noid S0.storage_substrate_base >/dev/null 2>&1 || true
  assert_eq "$(task_count)" "0" "a candidate without a taskId must be rejected"
	  assert_eq "$(gluerun_l1_lease_status S0.storage_substrate_base)" "failed" "the node lease is marked failed"
	}

	test_import_rejects_duplicate_candidate_matching_open_task_signature() {
	  with_fixture
	  # v2 (0.5.0): only OPEN twins (ready/planned/running/needs-review/accepted)
	  # reject a candidate at import.
	  write_signature_task TASK-0099 running storage "Staged fixture S0.storage_substrate_base" \
	    "Original running objective for S0.storage_substrate_base." "internal/storage/staged_S0_storage_substrate_base.go"
	  gluerun_l1_lease_write S0.storage_substrate_base storage S0 storage_substrate_base active RUN-dup abc1234 target
	  local sdir="$GLUERUN_RUNS_DIR/RUN-dup/l1-staging/S0.storage_substrate_base"
	  mkdir -p "$sdir"
	  write_signature_task TASK-0001 ready storage "Staged fixture S0.storage_substrate_base" \
	    "Regenerated objective with different wording but the same owned file set." "internal/storage/staged_S0_storage_substrate_base.go"
	  mv "$GLUERUN_TASKS_DIR/TASK-0001.md" "$sdir/TASK-0001.candidate.md"
	  local out
	  out="$(gluerun_l1_import_staged RUN-dup S0.storage_substrate_base 2>&1 || true)"
	  assert_not_contains "$out" "generated:" "duplicate candidate must not import"
	  assert_eq "$(task_count)" "1" "duplicate rejection preserves the existing task only"
	  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" "duplicate-candidate" "duplicate rejection emits reason"
	  assert_eq "$(gluerun_l1_lease_status S0.storage_substrate_base)" "failed" "duplicate candidate marks node lease failed"
	}

	# The 0.4.0 deadlock regression: a BLOCKED predecessor with the same owned
	# files must NOT reject its successor -- the node could never re-plan and the
	# no-progress loop tripped the breaker (field audit: overnight halt).
	test_import_allows_successor_of_blocked_task() {
	  with_fixture
	  write_signature_task TASK-0099 blocked storage "Staged fixture S0.storage_substrate_base" \
	    "Original blocked objective for S0.storage_substrate_base." "internal/storage/staged_S0_storage_substrate_base.go"
	  gluerun_l1_lease_write S0.storage_substrate_base storage S0 storage_substrate_base active RUN-succ abc1234 target
	  local sdir="$GLUERUN_RUNS_DIR/RUN-succ/l1-staging/S0.storage_substrate_base"
	  mkdir -p "$sdir"
	  write_signature_task TASK-0001 ready storage "Staged fixture S0.storage_substrate_base" \
	    "Successor objective with the same owned file set." "internal/storage/staged_S0_storage_substrate_base.go"
	  mv "$GLUERUN_TASKS_DIR/TASK-0001.md" "$sdir/TASK-0001.candidate.md"
	  local out
	  out="$(gluerun_l1_import_staged RUN-succ S0.storage_substrate_base 2>&1 || true)"
	  assert_contains "$out" "generated:" "successor of a blocked task must import"
	}

test_import_reads_atomic_candidate_generation() {
  with_fixture
  gluerun_l1_lease_write S0.storage_substrate_base storage S0 \
    storage_substrate_base active RUN-pointer abc1234 target
  local sdir="$GLUERUN_RUNS_DIR/RUN-pointer/l1-staging/S0.storage_substrate_base"
  local replacement="$sdir/.replacement"
  mkdir -p "$sdir" "$replacement"
  write_signature_task TASK-0001 ready storage \
    "Atomic staged fixture S0.storage_substrate_base" \
    "Import the atomically selected candidate generation." \
    "internal/storage/atomic_staged.go"
  mv "$GLUERUN_TASKS_DIR/TASK-0001.md" "$sdir/TASK-0001.candidate.md"
  cp "$sdir/TASK-0001.candidate.md" "$replacement/"
  printf '\nGeneration publication marker.\n' \
    >>"$replacement/TASK-0001.candidate.md"
  gluerun_task_batch_replace_stage "$replacement" "$sdir" \
    || fail "candidate generation publication failed"
  [[ -f "$sdir/.candidate-current.json" ]] \
    || fail "candidate generation pointer was not published"

  # The legacy file is deliberately invalid after publication. Import must pin
  # and consume the immutable generation selected by the pointer.
  printf 'invalid legacy candidate\n' >"$sdir/TASK-0001.candidate.md"
  local out
  out="$(gluerun_l1_import_staged RUN-pointer S0.storage_substrate_base 2>&1 || true)"
  assert_contains "$out" "generated:" \
    "L0 import must consume the authoritative candidate generation"
  assert_eq "$(task_count)" "1" \
    "atomic generation import must promote exactly one task"
}

	test_generate_tasks_direct_rejects_duplicate_candidate_matching_open_task_signature() {
	  with_fixture
	  # v2 (0.5.0): creation-time rejection applies to OPEN twins. Integrated
	  # twins no longer reject at creation (recovery work on integrated files is
	  # legitimate and declares `Supersedes:`); dispatch-time dedup still
	  # suppresses undeclared ready twins of integrated work.
	  write_signature_task TASK-0098 running artifact "Stub task" "Stub." "internal/artifact/stub.go"
	  local stub="$GLUERUN_ROOT/codex-stub.sh"; make_codex_md_stub "$stub"
	  local out rc=0
	  out="$(GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --node D1.contract --count 1 2>&1)" || rc=$?
	  [[ "$rc" -ne 0 ]] || fail "direct duplicate generation must exit non-zero"
	  assert_contains "$out" "duplicate-candidate" "direct duplicate rejection is reported"
	  assert_eq "$(task_count)" "1" "direct duplicate rejection must not write a new global task"
	  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" "duplicate-candidate" "direct duplicate rejection emits event"
	}

test_ready_listing_skips_duplicate_ready_task_by_owned_files() {
  with_fixture
  # v2 (0.5.0): an OPEN twin (running) suppresses the ready duplicate at
  # dispatch; a blocked twin no longer does (successors must be dispatchable).
  write_signature_task TASK-0098 running storage "Staged fixture S0.storage_substrate_base" \
    "Original running objective for S0.storage_substrate_base." "internal/storage/staged_S0_storage_substrate_base.go"
  write_signature_task TASK-0099 ready storage "Staged fixture S0.storage_substrate_base" \
    "Regenerated objective with different wording but the same owned file set." "internal/storage/staged_S0_storage_substrate_base.go"
  assert_eq "$(gluerun_list_ready_tasks | wc -l | tr -d ' ')" "0" "duplicate ready task must not be returned for dispatch"
  assert_eq "$(gluerun_select_dispatch_frontier 1 | wc -l | tr -d ' ')" "0" "duplicate ready task must not be selected for dispatch"
  # Successor-of-blocked is dispatchable:
  write_signature_task TASK-0098 blocked storage "Staged fixture S0.storage_substrate_base" \
    "Original blocked objective for S0.storage_substrate_base." "internal/storage/staged_S0_storage_substrate_base.go"
  assert_eq "$(gluerun_list_ready_tasks | wc -l | tr -d ' ')" "1" "successor of a blocked twin is dispatchable"
}

test_active_lease_count_uses_single_json_pass() {
  with_fixture
  mkdir -p "$GLUERUN_LEASES_DIR"
  printf '%s\n' '{"status":"running"}' >"$GLUERUN_LEASES_DIR/TASK-0001.json"
  printf '%s\n' '{"status":"planned"}' >"$GLUERUN_LEASES_DIR/TASK-0002.json"
  printf '%s\n' '{"status":"needs-review"}' >"$GLUERUN_LEASES_DIR/TASK-0003.json"
  printf '%s\n' '{"status":"succeeded"}' >"$GLUERUN_LEASES_DIR/TASK-0004.json"
  printf '%s\n' '{not-json' >"$GLUERUN_LEASES_DIR/TASK-0005.json"
  local out
  out="$(
    gluerun_json_field() { fail "gluerun_active_lease_count must not call gluerun_json_field once per lease"; }
    gluerun_active_lease_count
  )"
  assert_eq "$out" "3" "active lease count includes only in-flight statuses"
}

test_import_rolls_back_partial_promotion_on_mv_failure() {
  with_fixture
  gluerun_l1_lease_write S0.storage_substrate_base storage S0 storage_substrate_base active RUN-x abc1234 target
  local sdir="$GLUERUN_RUNS_DIR/RUN-mv/l1-staging/S0.storage_substrate_base" k
  mkdir -p "$sdir"
  for k in 1 2; do
    printf '%s\n' "# TASK-000$k: c$k" '' 'Status: ready' 'Area: storage' 'Dispatch mode: canonical' 'Depends on: []' '' '## Scope' '' 'Owned files:' '' "- \`internal/storage/c$k.go\`" > "$sdir/TASK-000$k.candidate.md"
  done
  # Override mv to fail on the SECOND call -> first candidate promotes, second fails.
  _mv_calls=0
  mv() { _mv_calls=$((_mv_calls + 1)); [[ "$_mv_calls" -ge 2 ]] && return 1; command mv "$@"; }
  gluerun_l1_import_staged RUN-mv S0.storage_substrate_base >/dev/null 2>&1 || true
  unset -f mv
  assert_eq "$(task_count)" "0" "a failed mv mid-batch rolls back so nothing is promoted (all-or-nothing)"
  assert_eq "$(gluerun_l1_lease_status S0.storage_substrate_base)" "failed" "the node lease is marked failed on promotion failure"
}

	test_rewrite_task_id_token_is_token_safe
	test_import_fails_closed_on_missing_lease
	test_import_rejects_candidate_without_taskid
	test_import_rejects_duplicate_candidate_matching_open_task_signature
	test_import_allows_successor_of_blocked_task
	test_import_reads_atomic_candidate_generation
	test_generate_tasks_direct_rejects_duplicate_candidate_matching_open_task_signature
	test_ready_listing_skips_duplicate_ready_task_by_owned_files
	test_active_lease_count_uses_single_json_pass
	test_import_rolls_back_partial_promotion_on_mv_failure
	test_generate_tasks_staged_writes_only_to_stage_dir
	test_generate_tasks_staged_batch_rewrites_planner_id_to_temp_id
	test_generate_tasks_prompt_directs_slice_folding
	test_generate_tasks_backcompat_unchanged
	test_generate_tasks_logs_quota_failure_and_sets_backoff
	test_generate_tasks_honors_active_planner_backoff_without_calling_codex
	test_reconcile_defers_serial_planning_during_active_backoff
	test_reconcile_defers_parallel_planning_before_leases
	test_generate_tasks_honors_blocked_gate_without_calling_codex
	test_fanout_full_chain_two_nodes_unique_ids
	test_fanout_default_cap_two
	test_fanout_unique_ids_from_same_temp_id
		test_fanout_cap_override_one
		test_fanout_excludes_authoritative_blocked_gate
		test_fanout_one_failure_isolated
	test_fanout_reports_planner_failures_for_breaker_accounting
	test_autonomate_counts_planner_failures_against_breaker
	test_autonomate_sleeps_through_quota_window_without_breaker
	test_autonomate_nonquota_backoff_neutralizes_repeated_planner_failure
	test_autonomate_nonquota_backoff_still_counts_unrelated_failure
	test_autonomate_expired_quota_backoff_falls_through
	test_autonomate_quota_wait_budget_sets_stop
	test_cycle_limit_window_detected_finds_marker
	test_cycle_limit_window_ignores_model_authored_artifacts
	test_cycle_limit_window_detected_finds_403_org_disabled
	test_cycle_limit_window_detected_ignores_plain_failure
	test_cycle_limit_window_detected_ignores_stale_marker
	test_autonomate_limit_induced_failure_arms_backoff_not_breaker
	test_autonomate_import_rejections_never_arm_backoff
	test_autonomate_real_failure_still_trips_with_detection_active
	test_fanout_invalid_staged_imports_nothing_for_that_node
test_frontier_scope_guard_excludes_conflict_via_configured_area_map
test_frontier_scope_guard_batch_overlap_via_configured_area_map
test_frontier_scope_guard_honors_area_prefix
test_fanout_stop_blocks
test_fanout_disk_blocks

echo "l1 parallel tests passed"
