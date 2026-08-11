#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg (missing: $needle)"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state" "$tmp/tasks"

run_lib() {
  SINGULAR_ROOT="$tmp" \
  SINGULAR_STATE_DIR="$tmp/state" \
  SINGULAR_TASKS_DIR="$tmp/tasks" \
  bash -c "source '$ENGINE_HOME/engine/lib.sh'; $1"
}

# args: file id status node owned title [extra-header]
write_task() {
  local file="$1" id="$2" status="$3" node="$4" owned="$5" title="$6" extra="${7:-}"
  {
    echo "# $id: $title"
    echo
    echo "Status: $status"
    echo "Area: core"
    [[ -n "$node" ]] && echo "DAG node: $node"
    [[ -n "$extra" ]] && echo "$extra"
    echo "Dispatch mode: canonical"
    echo "Depends on: []"
    echo
    echo "## Objective"
    echo
    echo "Objective for $title."
    echo
    echo "## Scope"
    echo
    echo "Owned files:"
    echo
    echo "- \`$owned\`"
  } >"$file"
}

# 1. A BLOCKED task with the same node + owned files never blocks a candidate
#    (the 0.4.0 deadlock: a parked task froze its node forever).
write_task "$tmp/tasks/TASK-0001.md" TASK-0001 blocked node-a src/a.ts "first attempt"
write_task "$tmp/cand.md" TASK-0002 ready node-a src/a.ts "second attempt"
run_lib "singular_find_duplicate_task_signature '$tmp/cand.md' node-a" >/dev/null 2>&1 \
  && fail "blocked predecessor must not block a successor candidate"

# Same for superseded/failed/cancelled.
for st in superseded failed cancelled; do
  write_task "$tmp/tasks/TASK-0001.md" TASK-0001 "$st" node-a src/a.ts "first attempt"
  run_lib "singular_find_duplicate_task_signature '$tmp/cand.md' node-a" >/dev/null 2>&1 \
    && fail "$st predecessor must not block a successor candidate"
done

# 2. An OPEN twin (running) with the same DAG node + owned files IS a duplicate.
write_task "$tmp/tasks/TASK-0001.md" TASK-0001 running node-a src/a.ts "first attempt"
dup="$(run_lib "singular_find_duplicate_task_signature '$tmp/cand.md' node-a" 2>/dev/null)" \
  || fail "running twin must be a duplicate"
assert_contains "$dup" '"existingTaskId":"TASK-0001"' "duplicate names the twin"

# 3. Same owned files under DIFFERENT DAG nodes are not duplicates.
write_task "$tmp/tasks/TASK-0001.md" TASK-0001 running node-b src/a.ts "other node work"
run_lib "singular_find_duplicate_task_signature '$tmp/cand.md' node-a" >/dev/null 2>&1 \
  && fail "different DAG nodes with same owned files must not match"

# 4. Unknown nodes on both sides: only a FULL signature matches (0.4.0 treated
#    empty node as a wildcard and matched on owned files alone).
write_task "$tmp/tasks/TASK-0001.md" TASK-0001 ready "" src/a.ts "identical title"
write_task "$tmp/cand.md" TASK-0002 ready "" src/a.ts "identical title"
# same title but different objective text -> the objectives embed the title, so
# make them literally identical for the positive case:
python3 - "$tmp/tasks/TASK-0001.md" "$tmp/cand.md" <<'PY'
import re, sys
a, b = sys.argv[1], sys.argv[2]
tb = open(b).read()
tb = re.sub(r"# TASK-0002: .*", "# TASK-0002: identical title", tb)
open(b, "w").write(tb)
PY
run_lib "singular_find_duplicate_task_signature '$tmp/cand.md' ''" >/dev/null 2>&1 \
  || fail "full-signature nodeless twin must match"
write_task "$tmp/cand.md" TASK-0002 ready "" src/a.ts "a different title entirely"
run_lib "singular_find_duplicate_task_signature '$tmp/cand.md' ''" >/dev/null 2>&1 \
  && fail "nodeless owned-files-only overlap must NOT match"

# 5. Supersedes bypass: candidate explicitly replacing an OPEN twin passes.
write_task "$tmp/tasks/TASK-0001.md" TASK-0001 running node-a src/a.ts "first attempt"
write_task "$tmp/cand.md" TASK-0002 ready node-a src/a.ts "replacement attempt" "Supersedes: TASK-0001"
run_lib "singular_find_duplicate_task_signature '$tmp/cand.md' node-a" >/dev/null 2>&1 \
  && fail "Supersedes header must bypass the guard"

# 6. Parser: dagNode + supersedes fields surface in task JSON.
json="$(run_lib "singular_task_json '$tmp/cand.md'")"
assert_contains "$json" '"dagNode":"node-a"' "dagNode parsed"
assert_contains "$json" '"supersedes":["TASK-0001"]' "supersedes parsed"

# 7. Frontier list_ready (dispatch mode): a ready twin of an INTEGRATED task is
#    suppressed; a ready twin of a BLOCKED task is dispatchable.
rm -f "$tmp/cand.md"
write_task "$tmp/tasks/TASK-0001.md" TASK-0001 integrated node-a src/a.ts "landed work"
write_task "$tmp/tasks/TASK-0002.md" TASK-0002 ready node-a src/a.ts "accidental twin"
out="$(run_lib singular_list_ready_tasks)"
[[ "$out" == *TASK-0002* ]] && fail "ready twin of integrated work must be suppressed"
write_task "$tmp/tasks/TASK-0001.md" TASK-0001 blocked node-a src/a.ts "parked work"
out="$(run_lib singular_list_ready_tasks)"
[[ "$out" == *TASK-0002* ]] || fail "ready successor of a blocked task must be dispatchable"

echo "PASS: test-duplicate-guard"
