#!/usr/bin/env bash
set -euo pipefail

# E4 (0.5.0): dispatch exit-code contract (0 ok / 2 refusal / 3 terminal /
# other crash), whole-tree liveness in the reaper, and the l1-drive
# refusal-park threshold.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-reap-classification.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export SINGULAR_ROOT="$tmp/repo"
mkdir -p "$SINGULAR_ROOT/.singular-state/dispatch" "$SINGULAR_ROOT/.singular-state/leases" \
  "$SINGULAR_ROOT/docs/orchestration/tasks" "$SINGULAR_ROOT/.singular-state/runs"
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
export SINGULAR_DISPATCH_DIR="$SINGULAR_STATE_DIR/dispatch"
export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

write_record() {
  # args: task_id pid pgid  (state launched, dead run id)
  python3 - "$SINGULAR_DISPATCH_DIR/$1.json" "$1" "$2" "$3" <<'PY'
import json, sys
path, tid, pid, pgid = sys.argv[1:5]
json.dump({"taskId": tid, "runId": f"RUN-{tid}", "pid": int(pid), "pidStart": "gone",
           "pgid": int(pgid), "log": "", "baseSha": "", "batchId": "", "state": "launched"},
          open(path, "w"), indent=2)
PY
}

# --- 1. Exit-code classification --------------------------------------------
for spec in "TASK-0001:0" "TASK-0002:2" "TASK-0003:3" "TASK-0004:9"; do
  tid="${spec%%:*}"; ec="${spec##*:}"
  write_record "$tid" 99999999 0
  printf '%s\n' "$ec" >"$SINGULAR_DISPATCH_DIR/$tid.exit"
done
out="$(singular_reap_dispatches RUN-classify)"
assert_contains "$out" "reaped_ok=1" "one ok"
assert_contains "$out" "reaped_refused=1" "one refusal"
assert_contains "$out" "reaped_terminal=1" "one terminal"
assert_contains "$out" "reaped_failures=1" "one failure"
assert_eq "refused" "$(singular_json_field "$SINGULAR_DISPATCH_DIR/TASK-0002.json" outcome)" "refusal outcome recorded"
assert_eq "terminal" "$(singular_json_field "$SINGULAR_DISPATCH_DIR/TASK-0003.json" outcome)" "terminal outcome recorded"

# --- 2. Tree liveness: a live decoy carrying the run id keeps the lease ------
tid="TASK-0010"
printf '%s\n' '{"taskId":"TASK-0010","status":"running","branch":"agent/x/TASK-0010"}' >"$SINGULAR_LEASES_DIR/$tid.json"
bash -c "exec sleep 60" &
decoy=$!
# Rewrite record: recorded pid is DEAD (1 has pidStart mismatch), but a live
# process carries the run id on its command line.
python3 - "$SINGULAR_DISPATCH_DIR/$tid.json" "$tid" <<'PY'
import json, sys
path, tid = sys.argv[1:3]
json.dump({"taskId": tid, "runId": "RUN-decoy-marker-xyz", "pid": 99999999, "pidStart": "gone",
           "pgid": 0, "log": "", "baseSha": "", "batchId": "", "state": "launched"},
          open(path, "w"), indent=2)
PY
( exec -a "worker RUN-decoy-marker-xyz" sleep 60 ) &
marker_pid=$!
sleep 0.2
out="$(singular_reap_dispatches RUN-live)"
assert_contains "$out" "workers_running=1" "run-id decoy keeps the dispatch alive"
assert_eq "running" "$(singular_json_field "$SINGULAR_LEASES_DIR/$tid.json" status)" "lease untouched while tree alive"
kill "$marker_pid" "$decoy" 2>/dev/null || true
wait "$marker_pid" "$decoy" 2>/dev/null || true
sleep 0.2
out="$(singular_reap_dispatches RUN-dead)"
assert_contains "$out" "reaped_failures=1" "dead tree finally reaps as crash"
assert_eq "failed" "$(singular_json_field "$SINGULAR_LEASES_DIR/$tid.json" status)" "lease failed after true crash"

# --- 3. Refusal-park: 3 refusals park the task (exit 3) ----------------------
repo="$tmp/parkrepo"
mkdir -p "$repo/docs/orchestration/tasks" "$repo/docs/orchestration/prompts" "$repo/.singular-state"
git -C "$repo" init -q
git -C "$repo" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$repo/docs/orchestration/prompts/" 2>/dev/null || true
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$repo/docs/orchestration/prompts/" 2>/dev/null || true
git -C "$repo" add . && git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m init

cat >"$repo/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Park fixture

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-park`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Fixture task for refusal-park.

## Scope

Owned files:

- `internal/widget/parser.go`

## Acceptance Criteria

- The gate command passes.
EOF

# Pre-existing worktree dir + accepted lease -> every dispatch refuses (exit 2).
mkdir -p "$repo/.worktrees/TASK-0001"
mkdir -p "$repo/.singular-state/leases"
printf '%s\n' '{"taskId":"TASK-0001","status":"accepted","branch":"agent/widget/TASK-0001-park"}' \
  >"$repo/.singular-state/leases/TASK-0001.json"

park_env() {
  SINGULAR_ROOT="$repo" \
  SINGULAR_STATE_DIR="$repo/.singular-state" \
  SINGULAR_ORCH_DIR="$repo/docs/orchestration" \
  SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
  SINGULAR_LEASES_DIR="$repo/.singular-state/leases" \
  SINGULAR_DISPATCH_DIR="$repo/.singular-state/dispatch" \
  SINGULAR_RUNS_DIR="$repo/.singular-state/runs" \
  SINGULAR_WORKTREES_DIR="$repo/.worktrees" \
  SINGULAR_EVENTS_FILE="$repo/.singular-state/events.ndjson" \
  SINGULAR_TARGET_BRANCH=target \
  SINGULAR_AUTO_ACCEPT_EXISTING=0 \
  "$@"
}

rc=0; park_env bash "$SCRIPT_DIR/l1-drive.sh" TASK-0001 >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "first refusal exits 2"
rc=0; park_env bash "$SCRIPT_DIR/l1-drive.sh" TASK-0001 >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "second refusal exits 2"
rc=0; park_env bash "$SCRIPT_DIR/l1-drive.sh" TASK-0001 >/dev/null 2>&1 || rc=$?
assert_eq "3" "$rc" "third refusal parks (exit 3)"
assert_eq "blocked" "$(park_env bash -c "source '$SCRIPT_DIR/lib.sh'; singular_task_field '$repo/docs/orchestration/tasks/TASK-0001.md' status")" \
  "parked task file is blocked"
assert_contains "$(cat "$repo/.singular-state/events.ndjson")" '"type":"l1.refusal_parked"' "park event emitted"

echo "PASS: test-reap-classification"
