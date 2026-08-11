#!/usr/bin/env bash
set -euo pipefail

# P2 (0.5.0): task_satisfied tolerates terminal predecessors — a superseded
# task whose supersededBy chain reaches an integrated task, or a blocked task
# whose owned files are covered by an integrated same-node task, no longer
# blocks gate promotion (0.4.0: node-tasks-not-integrated forever).

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tasks/superseded" "$tmp/state"

# args: file id status node owned [extra-header]
write_task() {
  local file="$1" id="$2" status="$3" node="$4" owned="$5" extra="${6:-}"
  {
    echo "# $id: fixture $id"
    echo
    echo "Status: $status"
    echo "Area: core"
    echo "DAG node: $node"
    [[ -n "$extra" ]] && echo "$extra"
    echo
    echo "## Objective"
    echo
    echo "Fixture objective $id."
    echo
    echo "## Scope"
    echo
    echo "Owned files:"
    echo
    echo "- \`$owned\`"
  } >"$file"
}

# Slice the real task_integrated/task_satisfied definitions out of the
# promoter (it executes main logic on source, so we can't source it whole).
fns="$tmp/promoter-fns.sh"
awk '/^task_integrated\(\) \{/,/^\}$/' "$ENGINE_HOME/singular-ext/promote-gate.sh" >"$fns"
awk '/^task_satisfied\(\) \{/,/^\}$/' "$ENGINE_HOME/singular-ext/promote-gate.sh" >>"$fns"
grep -q "task_satisfied()" "$fns" || fail "could not extract task_satisfied from the promoter"

check() {
  # args: task_id -> rc of task_satisfied
  SINGULAR_ROOT="$tmp" SINGULAR_STATE_DIR="$tmp/state" SINGULAR_TASKS_DIR="$tmp/tasks" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  bash -c "source '$ENGINE_HOME/engine/lib.sh'; source '$fns'; task_satisfied '$1'"
}

# Fixture node: TASK-0001 superseded -> TASK-0002 superseded -> TASK-0003 integrated.
write_task "$tmp/tasks/superseded/TASK-0001.md" TASK-0001 superseded node-a src/a.ts "Superseded by: TASK-0002"
write_task "$tmp/tasks/superseded/TASK-0002.md" TASK-0002 superseded node-a src/a.ts "Superseded by: TASK-0003"
write_task "$tmp/tasks/TASK-0003.md" TASK-0003 integrated node-a src/a.ts
# TASK-0004 blocked; TASK-0005 integrated covering its files.
write_task "$tmp/tasks/TASK-0004.md" TASK-0004 blocked node-a src/b.ts
write_task "$tmp/tasks/TASK-0005.md" TASK-0005 integrated node-a src/b.ts
# TASK-0006 blocked orphan (nothing covers src/c.ts).
write_task "$tmp/tasks/TASK-0006.md" TASK-0006 blocked node-a src/c.ts

check TASK-0003 || fail "integrated task is satisfied"
check TASK-0001 || fail "superseded chain to integrated successor is satisfied"
check TASK-0002 || fail "direct superseded-by-integrated is satisfied"
check TASK-0004 || fail "blocked task with integrated owned-files cover is satisfied"
check TASK-0006 && fail "blocked orphan must NOT be satisfied"

# Strict mode restores integrated-only.
SINGULAR_PROMOTE_TOLERATE_TERMINAL=0 check TASK-0001 2>/dev/null \
  && fail "tolerance off must refuse superseded predecessors"

echo "PASS: test-promote-gate-terminal-predecessors"
