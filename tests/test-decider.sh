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
    "$root/.singular-state"
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
  export SINGULAR_ROOT="$tmp/repo"
  export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_WORKTREES_DIR="$SINGULAR_ROOT/.worktrees"
  export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
  export SINGULAR_DECIDER_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/decider-verdict.v0.schema.json"
  export SINGULAR_TARGET_BRANCH="target"
  mkdir -p "$SINGULAR_LEASES_DIR" "$SINGULAR_RUNS_DIR" "$SINGULAR_INBOX_DIR" "$SINGULAR_WORKTREES_DIR"
  make_fake_codex
}

make_fake_codex() {
  local bin="$SINGULAR_STATE_DIR/fake-bin"
  mkdir -p "$bin"
  cat >"$bin/codex" <<'SH'
#!/usr/bin/env bash
trap 'exit 143' TERM
sleep "${SINGULAR_FAKE_CODEX_SLEEP:-5}" &
wait "$!"
SH
  chmod +x "$bin/codex"
  export PATH="$bin:$PATH"
}

write_lease() {
  local retry="$1" max="$2"
  cat >"$SINGULAR_LEASES_DIR/TASK-0001.json" <<EOF
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
  "worktree": "$SINGULAR_ROOT",
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
  SINGULAR_DECIDER_TIMEOUT_SEC=1 SINGULAR_FAKE_CODEX_SLEEP=5 \
    "$SCRIPT_DIR/decide.sh" --task TASK-0001 \
      --failure-class "$failure_class" \
      --branch agent/artifact/TASK-0001-timeout \
      --run RUN-TIMEOUT \
      --worktree "$SINGULAR_ROOT"
}

make_payload_runner() {
  local stub="$SINGULAR_STATE_DIR/payload-runner.sh"
  cat >"$stub" <<'SH'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) out="$2"; shift 2 ;;
    --level|--worktree|-C|--run-id|--prompt-file|--session-meta|--resume-session) shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$MOCK_DECIDER_PAYLOAD" >"$out"
SH
  chmod +x "$stub"
  export SINGULAR_RUNNER="$stub"
}

run_decider_payload() {
  local payload="$1" failure_class="${2:-gate-red}"
  MOCK_DECIDER_PAYLOAD="$payload" SINGULAR_DECIDER_TIMEOUT_SEC=30 \
    "$SCRIPT_DIR/decide.sh" --task TASK-0001 \
      --failure-class "$failure_class" \
      --branch agent/artifact/TASK-0001-schema \
      --run RUN-SCHEMA \
      --worktree "$SINGULAR_ROOT"
}

assert_no_gate_results() {
  local count
  count="$(find "$SINGULAR_ORCH_DIR/gates" -type f 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "0" "$count" "$1"
}

test_decider_timeout_retries_buildable_audit_with_budget() {
  with_fixture
  write_lease 0 3

  local out
  out="$(run_decider_timeout audit-needs-fix)"

  assert_contains "$out" "action=retry" "audit-needs-fix timeout should retry when budget remains"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"type":"decider.timeout"' "timeout event emitted"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"action":"retry"' "timeout event records retry"
  assert_contains "$(cat "$SINGULAR_ORCH_DIR/decisions.md")" "decide:retry" "retry decision recorded"
  assert_no_gate_results "decider timeout retry must not write gate results"
}

test_decider_timeout_parks_exhausted_audit_retry_budget() {
  with_fixture
  write_lease 3 3

  local out
  out="$(run_decider_timeout audit-needs-fix)"

  assert_contains "$out" "action=escalate-parked" "exhausted audit-needs-fix timeout should park"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"type":"decider.timeout"' "timeout event emitted"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"action":"escalate-parked"' "timeout event records park"
  assert_contains "$(cat "$SINGULAR_ORCH_DIR/decisions.md")" "decide:escalate-parked" "park decision recorded"
  assert_no_gate_results "exhausted decider timeout must not write gate results"
}

test_decider_timeout_parks_nonbuildable_failure_class() {
  with_fixture
  write_lease 0 3

  local out
  out="$(run_decider_timeout scope-violation)"

  assert_contains "$out" "action=escalate-parked" "non-buildable timeout should keep parked fallback"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"type":"decider.timeout"' "timeout event emitted"
  assert_contains "$(cat "$SINGULAR_ORCH_DIR/decisions.md")" "decide:escalate-parked" "park decision recorded"
  assert_no_gate_results "non-buildable decider timeout must not write gate results"
}

assert_invalid_decider_payload_parks() {
  local payload="$1" msg="$2" out
  with_fixture
  write_lease 0 3
  make_payload_runner

  out="$(run_decider_payload "$payload" gate-red)"

  assert_contains "$out" "action=escalate-parked" "$msg parks"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"type":"decider.invalid_verdict"' "$msg invalid event emitted"
  assert_contains "$(cat "$SINGULAR_ORCH_DIR/decisions.md")" "decide:escalate-parked" "$msg park decision recorded"
  assert_eq "singular.orchestration.decider-verdict.v0" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schema"])' "$SINGULAR_RUNS_DIR/RUN-SCHEMA/decision-gate-red.json")" \
    "$msg fallback verdict schema"
  [[ -f "$SINGULAR_RUNS_DIR/RUN-SCHEMA/decision-gate-red.invalid.json" ]] \
    || fail "$msg invalid verdict should be preserved"
}

test_decider_legacy_schema_id_tolerated_in_warn_mode_rejected_in_reject_mode() {
  # 0.5.0: a well-formed verdict with a legacy pmgo.* schema id is tolerated by
  # default (SINGULAR_LEGACY_SCHEMA_MODE=warn) — the 0.4.0 hard rejection parked
  # every decision in consumers scaffolded with legacy prompts (field audit:
  # 18.5h halt). Reject mode restores the strict behavior post-migration.
  local payload='{"schema":"pmgo.orchestration.decider-verdict.v0","failureClass":"gate-red","taskId":"TASK-0001","action":"retry","rationale":"legacy namespace","nextOwner":"l1"}'
  local out

  with_fixture
  write_lease 0 3
  make_payload_runner
  out="$(SINGULAR_LEGACY_SCHEMA_MODE=warn run_decider_payload "$payload" gate-red)"
  assert_contains "$out" "action=retry" "warn mode honors legacy-schema verdict"

  with_fixture
  write_lease 0 3
  make_payload_runner
  out="$(SINGULAR_LEGACY_SCHEMA_MODE=reject run_decider_payload "$payload" gate-red)"
  assert_contains "$out" "action=escalate-parked" "reject mode parks legacy-schema verdict"
}

test_decider_rejects_bad_schema_missing_fields_unknown_action_and_mismatched_failure_class() {
  assert_invalid_decider_payload_parks \
    '{"schema":"wrong.namespace.decider-verdict.v0","failureClass":"gate-red","taskId":"TASK-0001","action":"retry","rationale":"bad namespace","nextOwner":"l1"}' \
    "bad schema"
  assert_invalid_decider_payload_parks \
    '{"schema":"singular.orchestration.decider-verdict.v0","action":"retry","rationale":"missing fields"}' \
    "missing required fields"
  assert_invalid_decider_payload_parks \
    '{"schema":"singular.orchestration.decider-verdict.v0","failureClass":"gate-red","taskId":"TASK-0001","action":"invent-action","rationale":"bad action","nextOwner":"l1"}' \
    "unknown action"
  assert_invalid_decider_payload_parks \
    '{"schema":"singular.orchestration.decider-verdict.v0","failureClass":"scope-violation","taskId":"TASK-0001","action":"retry","rationale":"wrong failure class","nextOwner":"l1"}' \
    "mismatched failure class"
}

test_decider_timeout_retries_buildable_audit_with_budget
test_decider_timeout_parks_exhausted_audit_retry_budget
test_decider_timeout_parks_nonbuildable_failure_class
test_decider_rejects_bad_schema_missing_fields_unknown_action_and_mismatched_failure_class
test_decider_legacy_schema_id_tolerated_in_warn_mode_rejected_in_reject_mode

echo "decider tests passed"
