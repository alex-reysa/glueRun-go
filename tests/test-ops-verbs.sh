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
mkdir -p "$root/docs/orchestration/tasks" "$root/.gluerun-state/leases" \
  "$root/.gluerun-state/inbox" "$root/.gluerun-state/dispatch" "$root/.gluerun-state/runs"
git -C "$root" init -q
git -C "$root" checkout -q -b target
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

ops() {
  env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
    GLUERUN_ORCH_DIR="$root/docs/orchestration" GLUERUN_TASKS_DIR="$root/docs/orchestration/tasks" \
    GLUERUN_LEASES_DIR="$root/.gluerun-state/leases" GLUERUN_INBOX_DIR="$root/.gluerun-state/inbox" \
    GLUERUN_DISPATCH_DIR="$root/.gluerun-state/dispatch" GLUERUN_RUNS_DIR="$root/.gluerun-state/runs" \
    GLUERUN_WORKTREES_DIR="$root/.worktrees" \
    GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson" \
    GLUERUN_TARGET_BRANCH=target \
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
  >"$root/.gluerun-state/leases/TASK-0001.json"
printf '%s\n' '{"taskId":"TASK-0001","runId":"RUN-1","status":"needs-review"}' \
  >"$root/.gluerun-state/inbox/RUN-1.json"

out="$(ops supersede TASK-0001 --by TASK-0002 --reason "fixture")"
assert_contains "$out" "superseded TASK-0001 -> TASK-0002" "supersede completes"
[[ -f "$root/docs/orchestration/tasks/superseded/TASK-0001.md" ]] || fail "task file moved"
grep -q "^Status: superseded" "$root/docs/orchestration/tasks/superseded/TASK-0001.md" || fail "status set"
grep -q "^Superseded by: TASK-0002" "$root/docs/orchestration/tasks/superseded/TASK-0001.md" || fail "successor header"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$root/.gluerun-state/leases/TASK-0001.json")" == "superseded" ]] \
  || fail "lease status"
[[ -f "$root/.gluerun-state/inbox/superseded/RUN-1.json" ]] || fail "inbox packet quarantined"
grep -q "supersede" "$root/docs/orchestration/decisions.md" || fail "decision recorded"
assert_contains "$(cat "$root/.gluerun-state/events.ndjson")" '"type":"task.superseded"' "event"

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
python3 - "$root/.gluerun-state/dispatch/TASK-0003.json" "$live_pid" <<'PY'
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
  env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
    GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson" \
    bash -c "source '$SCRIPT_DIR/lib.sh'; $1"
}
printf '%s\n' \
  '{"schema":"gluerun.orchestration.planner-backoff.v0","failureClass":"quota","until":"2999-01-01T00:00:00Z"}' \
  >"$root/.gluerun-state/planner-backoff.json"
out="$(ops clear-backoff)"
assert_contains "$out" "backoff cleared" "clear-backoff"

env_lib "gluerun_breaker_trip >/dev/null; gluerun_breaker_trip >/dev/null"
out="$(ops breaker show)"
assert_contains "$out" "breaker: 2/" "breaker show"
out="$(ops breaker reset)"
assert_contains "$out" "breaker reset (was 2" "breaker reset"

out="$(ops stop)"
assert_contains "$out" "STOP written" "stop"
[[ -f "$root/.gluerun-state/STOP" ]] || fail "STOP file"
out="$(ops resume)"
assert_contains "$out" "STOP removed" "resume"
[[ -f "$root/.gluerun-state/STOP" ]] && fail "STOP gone"

printf '%s\n' \
  '{"schema":"gluerun.orchestration.planner-backoff.v0","failureClass":"quota","until":"2999-01-01T00:00:00Z"}' \
  >"$root/.gluerun-state/planner-backoff.json"
env_lib "gluerun_breaker_trip >/dev/null"
touch "$root/.gluerun-state/STOP"
out="$(ops wake)"
assert_contains "$out" "backoff cleared" "wake clears backoff"
assert_contains "$out" "breaker reset" "wake resets breaker"
assert_contains "$out" "STOP removed" "wake drops STOP"
assert_contains "$out" "wake requested" "wake touches WAKE"
[[ -f "$root/.gluerun-state/WAKE" ]] || fail "WAKE file present"

echo "PASS: test-ops-verbs"
