#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/state" "$tmp/docs/orchestration/tasks/superseded" \
  "$tmp/docs/orchestration/packets/imported" "$tmp/state/leases" \
  "$tmp/state/dispatch" "$tmp/worktrees"

git -C "$tmp" init -q
git -C "$tmp" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$tmp" branch "agent/core/TASK-0021-fixture"

# Durable surfaces carrying task ids the 0.4.0 allocator was blind to.
: >"$tmp/docs/orchestration/tasks/TASK-0007.md"
: >"$tmp/docs/orchestration/tasks/superseded/TASK-0012.md"
printf '%s\n' '{"taskId":"TASK-0015","status":"superseded"}' >"$tmp/state/leases/TASK-0015.json"
printf '%s\n' '{"taskId":"TASK-0009","state":"reaped"}' >"$tmp/state/dispatch/TASK-0009.json"
mkdir -p "$tmp/worktrees/TASK-0018"
mkdir -p "$tmp/docs/orchestration/packets/imported/TASK-0016"

run_lib() {
  SINGULAR_ROOT="$tmp" \
  SINGULAR_STATE_DIR="$tmp/state" \
  SINGULAR_ORCH_DIR="$tmp/docs/orchestration" \
  SINGULAR_TASKS_DIR="$tmp/docs/orchestration/tasks" \
  SINGULAR_LEASES_DIR="$tmp/state/leases" \
  SINGULAR_DISPATCH_DIR="$tmp/state/dispatch" \
  SINGULAR_WORKTREES_DIR="$tmp/worktrees" \
  bash -c "source '$ENGINE_HOME/engine/lib.sh'; $1"
}

# 1. Scan max sees every surface: files, superseded/, lease, dispatch,
#    worktree, imported packet dir, branch.
max="$(run_lib singular_task_id_scan_max)"
[[ "$max" == "21" ]] || fail "scan max should be 21 (branch), got $max"

# 2. First allocation continues past the branch id.
next="$(run_lib 'singular_task_id_next 1')"
[[ "$next" == "TASK-0022" ]] || fail "expected TASK-0022, got $next"

# 3. Counter persists past artifact deletion (monotonic even when history is
#    erased) and batch allocation is sequential.
rm -rf "$tmp/docs/orchestration/tasks" "$tmp/state/leases" "$tmp/state/dispatch" "$tmp/worktrees"
mkdir -p "$tmp/docs/orchestration/tasks" "$tmp/state/leases" "$tmp/state/dispatch" "$tmp/worktrees"
git -C "$tmp" branch -D "agent/core/TASK-0021-fixture" >/dev/null
batch="$(run_lib 'singular_task_id_next 3')"
[[ "$batch" == $'TASK-0023\nTASK-0024\nTASK-0025' ]] || fail "expected 0023..0025, got: $batch"

# 4. Counter behind reality self-heals from the scan.
printf '5\n' >"$tmp/state/task-id-counter"
: >"$tmp/docs/orchestration/tasks/TASK-0040.md"
healed="$(run_lib 'singular_task_id_next 1')"
[[ "$healed" == "TASK-0041" ]] || fail "counter should self-heal to 41, got $healed"

# 5. Corrupt counter treated as 0 and re-seeded from the scan (which sees the
#    TASK-0040 file; the un-materialized 0041 allocation is lost — acceptable,
#    the scan is the durable floor).
printf 'garbage\n' >"$tmp/state/task-id-counter"
after="$(run_lib 'singular_task_id_next 1')"
[[ "$after" == "TASK-0041" ]] || fail "corrupt counter should re-seed from scan to 41, got $after"

echo "PASS: test-task-id-counter"
