#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/prompts" \
    "$root/docs/orchestration/gates" \
    "$root/docs/orchestration/tasks" \
    "$root/schemas/orchestration" \
    "$root/.gluerun-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/decider.md" "$root/docs/orchestration/prompts/decider.md"
  cp "$ENGINE_HOME/schemas/decider-verdict.v0.schema.json" "$root/schemas/orchestration/decider-verdict.v0.schema.json"
  printf '# Decisions\n\n## Decision Log\n\n' >"$root/docs/orchestration/decisions.md"
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
  export GLUERUN_LEASES_DIR="$GLUERUN_STATE_DIR/leases"
  export GLUERUN_INBOX_DIR="$GLUERUN_STATE_DIR/inbox"
  export GLUERUN_RUNS_DIR="$GLUERUN_STATE_DIR/runs"
  export GLUERUN_WORKTREES_DIR="$GLUERUN_ROOT/.worktrees"
  export GLUERUN_EVENTS_FILE="$GLUERUN_STATE_DIR/events.ndjson"
  export GLUERUN_DECIDER_SCHEMA="$GLUERUN_ROOT/schemas/orchestration/decider-verdict.v0.schema.json"
  export GLUERUN_TARGET_BRANCH="target"
  mkdir -p "$GLUERUN_LEASES_DIR" "$GLUERUN_RUNS_DIR" "$GLUERUN_INBOX_DIR" "$GLUERUN_WORKTREES_DIR"
  make_fake_codex
}

make_fake_codex() {
  local bin="$GLUERUN_STATE_DIR/fake-bin"
  mkdir -p "$bin"
  cat >"$bin/codex" <<'SH'
#!/usr/bin/env bash
trap 'exit 143' TERM
sleep "${GLUERUN_FAKE_CODEX_SLEEP:-5}" &
wait "$!"
SH
  chmod +x "$bin/codex"
  export PATH="$bin:$PATH"
}

write_lease() {
  local retry="$1" max="$2"
  cat >"$GLUERUN_LEASES_DIR/TASK-0001.json" <<EOF
{
  "taskId": "TASK-0001",
  "branch": "agent/artifact/TASK-0001-timeout",
  "area": "artifact",
  "owner": "l2-developer",
  "fileScope": "internal/artifact/a.go",
  "ownedFiles": ["internal/artifact/a.go"],
  "forbiddenFiles": [],
  "baseSha": "target",
  "batchId": "BATCH",
  "runId": "RUN-TIMEOUT",
  "worktree": "$GLUERUN_ROOT",
  "status": "running",
  "retryCount": $retry,
  "maxRetries": $max,
  "createdAt": "2026-06-06T00:00:00Z",
  "updatedAt": "2026-06-06T00:00:00Z"
}
EOF
}

run_decider_timeout() {
  local failure_class="$1"
  GLUERUN_DECIDER_TIMEOUT_SEC=1 GLUERUN_FAKE_CODEX_SLEEP=5 \
    "$SCRIPT_DIR/decide.sh" --task TASK-0001 \
      --failure-class "$failure_class" \
      --branch agent/artifact/TASK-0001-timeout \
      --run RUN-TIMEOUT \
      --worktree "$GLUERUN_ROOT"
}

assert_no_gate_results() {
  local count
  count="$(find "$GLUERUN_ORCH_DIR/gates" -type f 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "0" "$count" "$1"
}

test_decider_timeout_retries_buildable_audit_with_budget() {
  with_fixture
  write_lease 0 3

  local out
  out="$(run_decider_timeout audit-needs-fix)"

  assert_contains "$out" "action=retry" "audit-needs-fix timeout should retry when budget remains"
  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"type":"decider.timeout"' "timeout event emitted"
  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"action":"retry"' "timeout event records retry"
  assert_contains "$(cat "$GLUERUN_ORCH_DIR/decisions.md")" "decide:retry" "retry decision recorded"
  assert_no_gate_results "decider timeout retry must not write gate results"
}

test_decider_timeout_parks_exhausted_audit_retry_budget() {
  with_fixture
  write_lease 3 3

  local out
  out="$(run_decider_timeout audit-needs-fix)"

  assert_contains "$out" "action=escalate-parked" "exhausted audit-needs-fix timeout should park"
  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"type":"decider.timeout"' "timeout event emitted"
  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"action":"escalate-parked"' "timeout event records park"
  assert_contains "$(cat "$GLUERUN_ORCH_DIR/decisions.md")" "decide:escalate-parked" "park decision recorded"
  assert_no_gate_results "exhausted decider timeout must not write gate results"
}

test_decider_timeout_parks_nonbuildable_failure_class() {
  with_fixture
  write_lease 0 3

  local out
  out="$(run_decider_timeout scope-violation)"

  assert_contains "$out" "action=escalate-parked" "non-buildable timeout should keep parked fallback"
  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"type":"decider.timeout"' "timeout event emitted"
  assert_contains "$(cat "$GLUERUN_ORCH_DIR/decisions.md")" "decide:escalate-parked" "park decision recorded"
  assert_no_gate_results "non-buildable decider timeout must not write gate results"
}

test_decider_timeout_retries_buildable_audit_with_budget
test_decider_timeout_parks_exhausted_audit_retry_budget
test_decider_timeout_parks_nonbuildable_failure_class

echo "decider tests passed"
