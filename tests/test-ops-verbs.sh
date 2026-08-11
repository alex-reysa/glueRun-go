#!/usr/bin/env bash
set -euo pipefail

# P5 (0.5.0): operator verbs — supersede (four surfaces atomically, live-pid
# guard, idempotent), clear-backoff, breaker, stop/resume, wake.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ops-verbs.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/tasks" "$root/.singular-state/leases" \
  "$root/.singular-state/inbox" "$root/.singular-state/dispatch" "$root/.singular-state/runs"
git -C "$root" init -q
git -C "$root" checkout -q -b target
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

ops() {
  env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks" \
    SINGULAR_LEASES_DIR="$root/.singular-state/leases" SINGULAR_INBOX_DIR="$root/.singular-state/inbox" \
    SINGULAR_DISPATCH_DIR="$root/.singular-state/dispatch" SINGULAR_RUNS_DIR="$root/.singular-state/runs" \
    SINGULAR_WORKTREES_DIR="$root/.worktrees" \
    SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" \
    SINGULAR_TARGET_BRANCH=target \
    bash "$SCRIPT_DIR/ops.sh" "$@"
}

# --- supersede ---------------------------------------------------------------
cat >"$root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: doomed attempt

Status: blocked
Area: core
DAG node: node-a
Dispatch mode: canonical

## Objective

First attempt.

## Scope

Owned files:

- `src/a.ts`
EOF
cat >"$root/docs/orchestration/tasks/TASK-0002.md" <<'EOF'
# TASK-0002: replacement

Status: ready
Area: core
DAG node: node-a
Dispatch mode: canonical

## Objective

Second attempt.

## Scope

Owned files:

- `src/a.ts`
EOF
printf '%s\n' '{"taskId":"TASK-0001","status":"blocked","branch":"agent/core/TASK-0001"}' \
  >"$root/.singular-state/leases/TASK-0001.json"
printf '%s\n' '{"taskId":"TASK-0001","runId":"RUN-1","status":"needs-review"}' \
  >"$root/.singular-state/inbox/RUN-1.json"

out="$(ops supersede TASK-0001 --by TASK-0002 --reason "fixture")"
assert_contains "$out" "superseded TASK-0001 -> TASK-0002" "supersede completes"
[[ -f "$root/docs/orchestration/tasks/superseded/TASK-0001.md" ]] || fail "task file moved"
grep -q "^Status: superseded" "$root/docs/orchestration/tasks/superseded/TASK-0001.md" || fail "status set"
grep -q "^Superseded by: TASK-0002" "$root/docs/orchestration/tasks/superseded/TASK-0001.md" || fail "successor header"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$root/.singular-state/leases/TASK-0001.json")" == "superseded" ]] \
  || fail "lease status"
[[ -f "$root/.singular-state/inbox/superseded/RUN-1.json" ]] || fail "inbox packet quarantined"
grep -q "supersede" "$root/docs/orchestration/decisions.md" || fail "decision recorded"
assert_contains "$(cat "$root/.singular-state/events.ndjson")" '"type":"task.superseded"' "event"

# Idempotent re-run.
out="$(ops supersede TASK-0001)"
assert_contains "$out" "already superseded" "idempotent"

# Live-dispatch guard: refuse without --force.
cat >"$root/docs/orchestration/tasks/TASK-0003.md" <<'EOF'
# TASK-0003: live one

Status: running
Area: core
Dispatch mode: canonical

## Objective

Running attempt.

## Scope

Owned files:

- `src/b.ts`
EOF
( exec -a "worker RUN-live-ops" sleep 60 ) &
live_pid=$!
python3 - "$root/.singular-state/dispatch/TASK-0003.json" "$live_pid" <<'PY'
import json, sys
json.dump({"taskId": "TASK-0003", "runId": "RUN-live-ops", "pid": int(sys.argv[2]),
           "pidStart": "", "pgid": 0, "log": "", "baseSha": "", "batchId": "",
           "state": "launched"}, open(sys.argv[1], "w"), indent=2)
PY
rc=0
ops supersede TASK-0003 >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "live dispatch must refuse without --force (rc=$rc)"
out="$(ops supersede TASK-0003 --force)"
assert_contains "$out" "superseded TASK-0003" "--force supersedes"
kill "$live_pid" 2>/dev/null || true

# --- clear-backoff / breaker / stop / resume / wake ---------------------------
env_lib() {
  env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" \
    bash -c "source '$SCRIPT_DIR/lib.sh'; $1"
}
printf '%s\n' \
  '{"schema":"singular.orchestration.planner-backoff.v0","failureClass":"quota","until":"2999-01-01T00:00:00Z"}' \
  >"$root/.singular-state/planner-backoff.json"
out="$(ops clear-backoff)"
assert_contains "$out" "backoff cleared" "clear-backoff"

env_lib "singular_breaker_trip >/dev/null; singular_breaker_trip >/dev/null"
out="$(ops breaker show)"
assert_contains "$out" "breaker: 2/" "breaker show"
out="$(ops breaker reset)"
assert_contains "$out" "breaker reset (was 2" "breaker reset"

out="$(ops stop)"
assert_contains "$out" "STOP written" "stop"
[[ -f "$root/.singular-state/STOP" ]] || fail "STOP file"
out="$(ops resume)"
assert_contains "$out" "STOP removed" "resume"
[[ -f "$root/.singular-state/STOP" ]] && fail "STOP gone"

printf '%s\n' \
  '{"schema":"singular.orchestration.planner-backoff.v0","failureClass":"quota","until":"2999-01-01T00:00:00Z"}' \
  >"$root/.singular-state/planner-backoff.json"
env_lib "singular_breaker_trip >/dev/null"
touch "$root/.singular-state/STOP"
out="$(ops wake)"
assert_contains "$out" "backoff cleared" "wake clears backoff"
assert_contains "$out" "breaker reset" "wake resets breaker"
assert_contains "$out" "STOP removed" "wake drops STOP"
assert_contains "$out" "wake requested" "wake touches WAKE"
[[ -f "$root/.singular-state/WAKE" ]] || fail "WAKE file present"

# --- unpark ------------------------------------------------------------------
# A transient environment fault used to kill a task permanently: escalate-parked
# writes Status: blocked, dispatch selects only Status: ready, recover.sh filters
# to running|planned|needs-review before it could help, and the only operator
# verb was `supersede` — which buries the task in tasks/superseded/ rather than
# repairing it.
cat >"$root/docs/orchestration/tasks/TASK-0010.md" <<'EOF'
# TASK-0010: parked on a missing dependency

Status: blocked
Area: core
DAG node: node-z
Dispatch mode: canonical

## Objective

Parked by audit-infra.

## Scope

Owned files:

- `src/z.ts`
EOF
# retryCount at the ceiling and a refusals counter: both are what make an
# unpark that only flips the task status useless.
printf '%s\n' '{"taskId":"TASK-0010","status":"blocked","retryCount":3,"branch":"agent/core/TASK-0010"}' \
  >"$root/.singular-state/leases/TASK-0010.json"
printf '3\n' >"$root/.singular-state/dispatch/TASK-0010.refusals"

out="$(ops unpark TASK-0010 --reason "dependency installed")"
assert_contains "$out" "unparked TASK-0010" "unpark completes"
grep -q "^Status: ready" "$root/docs/orchestration/tasks/TASK-0010.md" || fail "unpark: task status"
[[ -f "$root/docs/orchestration/tasks/TASK-0010.md" ]] || fail "unpark: task file must stay in place"
lease_json="$root/.singular-state/leases/TASK-0010.json"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$lease_json")" == "ready" ]] \
  || fail "unpark: lease status"
# Nothing else in the engine ever resets retryCount, and decide.sh reads it to
# decide whether any budget remains — an unpark that leaves it at the ceiling
# parks again on the first failure with no attempt left to spend.
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["retryCount"])' "$lease_json")" == "0" ]] \
  || fail "unpark: retryCount not reset"
# Only cleared on a successful dispatch otherwise, so an unparked task would
# inherit the old count and re-park at the threshold.
[[ ! -f "$root/.singular-state/dispatch/TASK-0010.refusals" ]] || fail "unpark: refusals counter"
grep -q "unpark" "$root/docs/orchestration/decisions.md" || fail "unpark: decision recorded"
assert_contains "$(cat "$root/.singular-state/events.ndjson")" '"type":"task.unparked"' "unpark event"

# The task is dispatch-eligible again — the point of the whole verb.
readyish="$(env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
  SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks" \
  SINGULAR_LEASES_DIR="$root/.singular-state/leases" SINGULAR_TARGET_BRANCH=target \
  bash -c 'source "$0"/lib.sh; singular_list_status_ready_tasks' "$SCRIPT_DIR")"
assert_contains "$readyish" "TASK-0010" "unpark returns the task to the ready set"

# Idempotent.
out="$(ops unpark TASK-0010)"
assert_contains "$out" "already ready" "unpark idempotent"

# It must not override a live status — that would race a running worker.
# A task of its own: the supersede cases above have already moved TASK-0003 into
# tasks/superseded/, so reusing it would exercise the wrong refusal.
cat >"$root/docs/orchestration/tasks/TASK-0011.md" <<'EOF'
# TASK-0011: live worker

Status: running
Area: core
Dispatch mode: canonical

## Objective

In flight.

## Scope

Owned files:

- `src/live.ts`
EOF
rc=0
out="$(ops unpark TASK-0011 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "unpark: must refuse a running task"
assert_contains "$out" "refusing to override a live status" "unpark refuses running"

# A superseded task is buried, not parked; say so instead of resurrecting it.
rc=0
out="$(ops unpark TASK-0001 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "unpark: must refuse a superseded task"
assert_contains "$out" "is superseded, not parked" "unpark refuses superseded"

echo "PASS: test-ops-verbs"
