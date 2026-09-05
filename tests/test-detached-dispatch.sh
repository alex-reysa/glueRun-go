#!/usr/bin/env bash
# singular-test: serial — asserts wall-clock bounds (a detached cycle must return before
# its stubs finish / a headless browser must settle focus) that a loaded machine breaks.
set -euo pipefail

# Detached dispatch (SINGULAR_DETACHED_DISPATCH=1): reconcile spawns workers and
# returns without waiting; outcomes are attributed by the reaper on later
# cycles via dispatch records + exit files. These tests cover: fast cycle
# return with lock release, pre-lease double-dispatch/scope protection, reap
# correctness for ok/failed/crashed workers, --drain, batch-mode shadow
# accounting parity, breaker semantics under autonomate, and atomic state
# writes leaving no tmp residue.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local want="$1" got="$2" msg="$3"
  [[ "$got" == "$want" ]] || fail "$msg: want '$want', got '$got'"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg: missing '$needle' in: $haystack"
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$msg: unexpectedly found '$needle' in: $haystack"
}

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/packets/imported" \
    "$root/docs/orchestration/areas/artifact" \
    "$root/docs/orchestration/gates" \
    "$root/docs/orchestration/prompts" "$root/schemas/orchestration" "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$root/docs/orchestration/prompts/l1-planner.md"
  cp "$ENGINE_HOME/schemas/state-packet.v0.schema.json" "$root/schemas/orchestration/state-packet.v0.schema.json"
  cp "$ENGINE_HOME/schemas/audit-verdict.v0.schema.json" "$root/schemas/orchestration/audit-verdict.v0.schema.json"
  cp "$ENGINE_HOME/schemas/decider-verdict.v0.schema.json" "$root/schemas/orchestration/decider-verdict.v0.schema.json"
  cp "$ENGINE_HOME/schemas/task-batch.v0.schema.json" "$root/schemas/orchestration/task-batch.v0.schema.json"
  cp "$ENGINE_HOME/schemas/dag.v0.schema.json" "$root/schemas/orchestration/dag.v0.schema.json"
  cp "$ENGINE_HOME/schemas/gate-result.v0.schema.json" "$root/schemas/orchestration/gate-result.v0.schema.json"
  cat >"$root/docs/orchestration/project-state.md" <<'EOF'
# Project State
EOF
  cat >"$root/docs/orchestration/areas/artifact/state.md" <<'EOF'
# Area State: Artifact

Current status: active
EOF
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

write_task() {
  local id="$1" status="$2" owned="$3" depends="${4:-[]}"
  cat >"$SINGULAR_TASKS_DIR/$id.md" <<EOF
# $id: Task $id

Status: $status
Area: artifact
Target branch: \`target\`
Worker branch: \`agent/artifact/$id-test\`
Test policy: \`strict_test_first\`
Gate command: \`true\`
Dispatch mode: canonical
Depends on: $depends

## Objective

Exercise $id.

## Scope

Owned files:

- \`$owned\`

Forbidden files:

- \`Any file outside the owned scope unless an L1 scope amendment is recorded.\`

## Prerequisites

- Human-readable prerequisite text.

## Acceptance Criteria

- Pass.
EOF
}

with_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  make_repo "$tmp/repo"
  export SINGULAR_ROOT="$tmp/repo"
  export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_WORKTREES_DIR="$SINGULAR_ROOT/.worktrees"
  export SINGULAR_ORIGIN_STATE_FILE="$SINGULAR_STATE_DIR/origin-state.json"
  export SINGULAR_GIT_LOCK_DIR="$SINGULAR_STATE_DIR/locks/git-op.lock"
  export SINGULAR_DISPATCH_DIR="$SINGULAR_STATE_DIR/dispatch"
  export SINGULAR_PACKET_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/state-packet.v0.schema.json"
  export SINGULAR_AUDIT_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/audit-verdict.v0.schema.json"
  export SINGULAR_DECIDER_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/decider-verdict.v0.schema.json"
  export SINGULAR_STOP_FILE="$SINGULAR_STATE_DIR/STOP"
  export SINGULAR_STATUS_FILE="$SINGULAR_STATE_DIR/STATUS.md"
  export SINGULAR_BREAKER_FILE="$SINGULAR_STATE_DIR/circuit.json"
  export SINGULAR_PLANNER_BACKOFF_FILE="$SINGULAR_STATE_DIR/planner-backoff.json"
  export SINGULAR_TARGET_BRANCH="target"
  source "$SCRIPT_DIR/lib.sh"
}

# Stub driver that sleeps then exits with a per-task code (default 0).
make_sleep_stub() {
  local stub="$1" secs="$2"
  cat >"$stub" <<EOF
#!/usr/bin/env bash
set -euo pipefail
tid="\$1"
echo "\$tid" >>"\$SINGULAR_STATE_DIR/dispatch.log"
sleep $secs
ec_file="\$SINGULAR_STATE_DIR/\$tid.ec"
[[ -f "\$ec_file" ]] && exit "\$(cat "\$ec_file")"
exit 0
EOF
  chmod +x "$stub"
}

actuate() {
  SINGULAR_L1_DRIVER="$1" SINGULAR_GENERATE=0 SINGULAR_AUTO_INTEGRATE=0 \
    SINGULAR_MAX_CONCURRENT="$2" SINGULAR_MAX_DISPATCH="$2" SINGULAR_DETACHED_DISPATCH="$3" \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true
}

field_of() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1
}

wait_for_exit_files() {
  local count="$1" tries=0
  while [[ "$(find "$SINGULAR_DISPATCH_DIR" -name '*.exit' 2>/dev/null | wc -l | tr -d ' ')" -lt "$count" ]]; do
    tries=$((tries + 1))
    [[ "$tries" -ge 50 ]] && fail "timed out waiting for $count exit file(s)"
    sleep 0.2
  done
}

test_detached_cycle_returns_fast_and_releases_lock() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  write_task TASK-0002 ready internal/artifact/b.go "[]"
  local stub="$SINGULAR_ROOT/stub.sh"
  make_sleep_stub "$stub" 5

  local start out elapsed
  start="$(date +%s)"
  out="$(actuate "$stub" 2 1)"
  elapsed=$(( $(date +%s) - start ))

  assert_eq "2" "$(field_of "$out" dispatched_this_run)" "detached cycle dispatched both tasks"
  assert_eq "1" "$(field_of "$out" detached_dispatch)" "detached flag reported"
  [[ "$elapsed" -lt 4 ]] || fail "detached cycle blocked on workers (took ${elapsed}s with 5s stubs)"
  [[ ! -f "$SINGULAR_STATE_DIR/locks/origin.lock.json" ]] || fail "origin lock still held after detached cycle"

  # While the stubs sleep: pre-leases hold the slots and the next cycle defers.
  local out2
  out2="$(actuate "$stub" 2 1)"
  assert_eq "0" "$(field_of "$out2" dispatched_this_run)" "no double dispatch while workers run"
  assert_eq "2" "$(field_of "$out2" workers_running)" "both workers observed running at cycle start"
  assert_contains "$out2" "max-concurrent cap reached" "ready tasks deferred while slots are held"

  # Drain: blocks until the stubs finish, then reaps both.
  local drain_out
  drain_out="$(SINGULAR_DRAIN_TIMEOUT_SECS=30 "$SCRIPT_DIR/reconcile.sh" --drain 2>&1)" || fail "drain did not exit cleanly"
  assert_contains "$drain_out" "no launched dispatch records remain" "drain completed"
  assert_contains "$(cat "$SINGULAR_DISPATCH_DIR/TASK-0001.json")" '"state": "reaped"' "TASK-0001 record finalized"
  assert_contains "$(cat "$SINGULAR_DISPATCH_DIR/TASK-0002.json")" '"state": "reaped"' "TASK-0002 record finalized"
  [[ -z "$(find "$SINGULAR_DISPATCH_DIR" -name '*.exit' 2>/dev/null)" ]] || fail "exit files not cleaned up after reap"
}

test_detached_pre_lease_blocks_scope_overlap() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/shared.go "[]"
  write_task TASK-0002 ready internal/artifact/shared.go "[]"
  local stub="$SINGULAR_ROOT/stub.sh"
  make_sleep_stub "$stub" 4

  local out
  out="$(actuate "$stub" 2 1)"
  assert_eq "1" "$(field_of "$out" dispatched_this_run)" "only one task dispatched for a shared owned file"

  # While TASK-0001 runs under its pre-lease, the overlapping TASK-0002 must
  # stay blocked even though a slot is free.
  local out2
  out2="$(actuate "$stub" 2 1)"
  assert_eq "0" "$(field_of "$out2" dispatched_this_run)" "scope overlap with a pre-leased running task blocks dispatch"
  assert_eq "1" "$(wc -l <"$SINGULAR_STATE_DIR/dispatch.log" | tr -d ' ')" "driver invoked exactly once"

  SINGULAR_DRAIN_TIMEOUT_SECS=30 "$SCRIPT_DIR/reconcile.sh" --drain >/dev/null 2>&1 || true
}

test_detached_reap_attributes_ok_and_failed() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  write_task TASK-0002 ready internal/artifact/b.go "[]"
  local stub="$SINGULAR_ROOT/stub.sh"
  make_sleep_stub "$stub" 0
  echo 9 >"$SINGULAR_STATE_DIR/TASK-0002.ec"

  local out
  out="$(actuate "$stub" 2 1)"
  assert_eq "2" "$(field_of "$out" dispatched_this_run)" "both fast stubs dispatched"
  wait_for_exit_files 2
  [[ -f "$(singular_wake_file)" ]] \
    || fail "detached worker completion did not request an immediate scheduler wake"
  assert_contains "$(cat "$SINGULAR_STATE_DIR/events.ndjson")" \
    '"type":"origin.capacity_released"' "capacity release wake was not recorded"

  # Next cycle (no new dispatch): the reaper attributes one ok + one failure.
  local out2
  out2="$(actuate "$stub" 0 1)"
  assert_eq "1" "$(field_of "$out2" reaped_ok)" "one ok reap"
  assert_eq "1" "$(field_of "$out2" reaped_failures)" "one failed reap"
  assert_eq "0" "$(field_of "$out2" workers_running)" "no workers left running"

  local events
  events="$(cat "$SINGULAR_STATE_DIR/events.ndjson")"
  assert_contains "$events" '"type":"origin.dispatch_reaped"' "dispatch_reaped events emitted"
  assert_contains "$events" '"taskId":"TASK-0002","exitCode":9' "failure attributed with its exit code"

  # The stubs never took lease ownership, so the wrapper cleared the
  # pre-leases: the tasks are re-dispatchable, not stuck holding slots.
  [[ ! -f "$SINGULAR_LEASES_DIR/TASK-0001.json" ]] || fail "pre-lease for TASK-0001 not cleared"
  [[ ! -f "$SINGULAR_LEASES_DIR/TASK-0002.json" ]] || fail "pre-lease for TASK-0002 not cleared"
}

test_detached_crash_detected_by_pid() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  local stub="$SINGULAR_ROOT/stub.sh"
  make_sleep_stub "$stub" 30

  local out
  out="$(actuate "$stub" 1 1)"
  assert_eq "1" "$(field_of "$out" dispatched_this_run)" "worker dispatched"

  local pid
  pid="$(singular_json_field "$SINGULAR_DISPATCH_DIR/TASK-0001.json" pid)"
  [[ -n "$pid" ]] || fail "dispatch record has no pid"
  # Kill the detached session (wrapper + stub) without letting it write an
  # exit file -- simulates a hard crash / SIGKILL.
  kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
  sleep 1

  local out2
  # 0.5.0 tree-liveness treats recent run-dir writes as maybe-alive (bounded
  # conservatism); disable the mtime window so the simulated hard crash reaps
  # immediately in this fixture.
  out2="$(SINGULAR_TREE_ACTIVITY_WINDOW_SEC=0 actuate "$stub" 0 1)"
  assert_eq "1" "$(field_of "$out2" reaped_failures)" "crash counted as a reap failure"
  assert_contains "$(cat "$SINGULAR_STATE_DIR/events.ndjson")" '"outcome":"crashed"' "crash outcome recorded"
  assert_eq "failed" "$(singular_json_field "$SINGULAR_LEASES_DIR/TASK-0001.json" status)" "crashed worker's lease marked failed"
}

test_batch_mode_shadow_accounting_parity() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  write_task TASK-0002 ready internal/artifact/b.go "[]"
  local stub="$SINGULAR_ROOT/stub.sh"
  make_sleep_stub "$stub" 0
  echo 9 >"$SINGULAR_STATE_DIR/TASK-0002.ec"

  # Batch mode (flag off): the wait loop stays authoritative and emits
  # worker_reaped; records + exit files are left for the shadow reaper.
  local out
  out="$(actuate "$stub" 2 0)"
  assert_eq "2" "$(field_of "$out" dispatched_this_run)" "batch dispatched both"
  assert_eq "1" "$(field_of "$out" failed_dispatches)" "batch wait loop counted the failure"
  assert_eq "0" "$(field_of "$out" detached_dispatch)" "batch mode reported"

  local out2
  out2="$(actuate "$stub" 0 0)"
  assert_eq "1" "$(field_of "$out2" reaped_ok)" "shadow reaper saw the ok exit"
  assert_eq "1" "$(field_of "$out2" reaped_failures)" "shadow reaper saw the failed exit"

  # Parity: in-cycle wait accounting and out-of-process reap accounting agree.
  local waited reaped
  waited="$(grep -c '"type":"origin.worker_reaped"' "$SINGULAR_STATE_DIR/events.ndjson" || true)"
  reaped="$(grep -c '"type":"origin.dispatch_reaped"' "$SINGULAR_STATE_DIR/events.ndjson" || true)"
  assert_eq "$waited" "$reaped" "shadow reap count matches wait-loop reap count"
  assert_eq "2" "$waited" "both workers accounted"
}

test_autonomate_breaker_semantics_detached() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  local stub="$SINGULAR_ROOT/stub.sh"
  make_sleep_stub "$stub" 4

  # Dispatch-only cycle: NOT progress (no reset) and NOT failure (no trip).
  local out
  out="$(cd "$SINGULAR_ROOT" && SINGULAR_L1_DRIVER="$stub" SINGULAR_GENERATE=0 SINGULAR_AUTO_INTEGRATE=0 SINGULAR_PUSH=0 \
    SINGULAR_MAX_CONCURRENT=1 SINGULAR_MAX_DISPATCH=1 SINGULAR_DETACHED_DISPATCH=1 \
    "$SCRIPT_DIR/autonomate.sh" --once 2>&1)" || true
  assert_contains "$out" "dispatched_this_run=1" "autonomate cycle dispatched"
  assert_not_contains "$out" "breaker ->" "dispatch-only detached cycle must not trip the breaker"
  assert_eq "0" "$(singular_breaker_count)" "breaker untouched by dispatch-only cycle"
  SINGULAR_DRAIN_TIMEOUT_SECS=30 "$SCRIPT_DIR/reconcile.sh" --drain >/dev/null 2>&1 || true

  # Reap-failure cycle (a previously detached worker failed): trips the breaker.
  with_fixture
  singular_dispatch_record_write "TASK-9001" "RUN-FAKE" "99999999" "" "/dev/null" "sha" "batch"
  singular_dispatch_exit_write "TASK-9001" 9
  local out2
  out2="$(cd "$SINGULAR_ROOT" && SINGULAR_GENERATE=0 SINGULAR_AUTO_INTEGRATE=0 SINGULAR_PUSH=0 \
    SINGULAR_MAX_CONCURRENT=0 SINGULAR_MAX_DISPATCH=0 SINGULAR_DETACHED_DISPATCH=1 \
    "$SCRIPT_DIR/autonomate.sh" --once 2>&1)" || true
  assert_contains "$out2" "reaped_failures=1" "reap failure surfaced to autonomate"
  assert_contains "$out2" "breaker -> 1" "reap failure trips the breaker"
  assert_eq "1" "$(singular_breaker_count)" "breaker incremented by reap failure"
}

test_atomic_state_writes_leave_no_tmp() {
  with_fixture
  singular_lease_write TASK-0001 agent/artifact/TASK-0001 artifact l2 "internal/a.go" running RUN-X "" sha batch '["internal/a.go"]' "[]"
  singular_lease_set_status TASK-0001 needs-review
  singular_lease_update_owned TASK-0001 '["internal/a.go","internal/b.go"]'
  singular_lease_bump_retry TASK-0001 >/dev/null
  write_task TASK-0002 ready internal/artifact/b.go "[]"
  singular_task_set_status "$SINGULAR_TASKS_DIR/TASK-0002.md" blocked

  [[ -z "$(find "$SINGULAR_LEASES_DIR" "$SINGULAR_TASKS_DIR" -name '*.tmp' 2>/dev/null)" ]] \
    || fail "atomic writes left .tmp residue"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SINGULAR_LEASES_DIR/TASK-0001.json" \
    || fail "lease not valid JSON after atomic writes"
  assert_eq "needs-review" "$(singular_json_field "$SINGULAR_LEASES_DIR/TASK-0001.json" status)" "status survived atomic rewrite chain"
  assert_contains "$(cat "$SINGULAR_TASKS_DIR/TASK-0002.md")" "Status: blocked" "task status rewritten atomically"
}

test_detached_cycle_returns_fast_and_releases_lock
test_detached_pre_lease_blocks_scope_overlap
test_detached_reap_attributes_ok_and_failed
test_detached_crash_detected_by_pid
test_batch_mode_shadow_accounting_parity
test_autonomate_breaker_semantics_detached
test_atomic_state_writes_leave_no_tmp

echo "detached dispatch tests passed"
