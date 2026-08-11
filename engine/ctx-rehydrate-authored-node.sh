#!/usr/bin/env bash
# ctx-rehydrate-authored-node.sh — pure, read-only authored-knowledge NODE
# resolver (stage S5-routing, executable DAG node `rehydrate-path`, layer
# engine_runtime). Sourced exactly once by the context-evolution loader block in
# lib.sh (it matches the ctx-*.sh glob). This file DEFINES a new function only and
# is present-but-uncalled by every existing engine/CLI/driver path, so with it
# sourced the engine stays byte-identical to prior behavior.
#
# This is the first, PURE half of closing a gap the authored-knowledge track
# designed for but left inert. TASK-0064's pure builder
# singular_ctx_rehydrate_authored_triggers <role> <step> [node] [task] accepts an
# optional [node] slot, but its two live consumers wired in by TASK-0065 — the
# injection at engine/l1-drive.sh and the manifest-record at
# engine/ctx-rehydrate-event.sh — both pass only `implementer implement "$task_id"`,
# omitting the node dimension because a run's DAG node is not readily in scope at
# either site (TASK-0065 explicitly deferred it). Consequently any authored entry
# whose `load-when` targets a node/stage (e.g. `["rehydrate-path"]`) can never
# become eligible, and the builder's [node] parameter is dead.
#
#   singular_ctx_rehydrate_authored_node <task_id> [worktree]
#
# Deterministically resolves the executable DAG node that owns <task_id> from the
# durable task->node association in the control-state event log (SINGULAR_EVENTS_FILE)
# — the same durable convention TASK-0032's locator reads: planner.staged /
# planner.generated events carrying data.taskId + data.node. It prints the node id
# when it is present and UNAMBIGUOUS (exactly one distinct non-empty node across all
# events carrying this taskId), and prints NOTHING (fail-safe) when the association
# is absent or ambiguous (the same task recorded against two different nodes), so an
# empty node token contributes nothing to a later trigger set (consistent with
# TASK-0064's rule that absent optional arguments contribute nothing).
#
# Pure, READ-ONLY, deterministic: it reads the event log only; it writes, renames,
# and deletes nothing, appends no events, and never exits non-zero on well-formed OR
# malformed input (fail-soft — malformed event lines are skipped, not fatal).
# Identical event-log bytes and task id yield byte-identical output.
#
# Node-scoped authored `load-when` matching becomes FUNCTIONAL only once the
# follow-up wire-in lands: a separate task threads this resolver's output into the
# [node] slot of singular_ctx_rehydrate_authored_triggers at BOTH call sites
# (engine/l1-drive.sh, engine/ctx-rehydrate-event.sh). That wire-in is OUT OF SCOPE
# here; this leaf by itself changes no injected packet and no recorded manifest, is
# NOT part of the `rehydrate-path` node's requiredCompletion, and does NOT gate the
# node.

# Resolve the executable DAG node owning <task_id> from the durable control-state
# event log. Pure/read-only; prints the node when unambiguous, else empty. Never
# exits non-zero. See header for the contract.
#   singular_ctx_rehydrate_authored_node <task_id> [worktree]
singular_ctx_rehydrate_authored_node() {
  local task_id="${1:-}" worktree="${2:-.}"
  # Indeterminate/empty task -> empty output (fail-safe).
  [[ -n "$task_id" ]] || { printf '%s' ""; return 0; }
  local events_file="${SINGULAR_EVENTS_FILE:-}"
  [[ -n "$events_file" && -f "$events_file" ]] || { printf '%s' ""; return 0; }

  # Scan the NDJSON control-state log read-only. Collect the DISTINCT non-empty node
  # values across every event carrying data.taskId == <task_id>. Exactly one distinct
  # node -> that node; zero or more-than-one (ambiguous) -> empty. A parse failure on
  # any single line is skipped (never fatal). Prints nothing but the resolved node.
  python3 - "$events_file" "$task_id" <<'PY' 2>/dev/null || true
import json, sys
path, task_id = sys.argv[1], sys.argv[2]
nodes = set()
try:
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if not isinstance(ev, dict):
                continue
            data = ev.get("data")
            if not isinstance(data, dict):
                continue
            if str(data.get("taskId", "")) != task_id:
                continue
            node = data.get("node", "")
            if isinstance(node, str) and node:
                nodes.add(node)
except Exception:
    nodes = set()
# Fail safe: only an unambiguous single association resolves.
if len(nodes) == 1:
    sys.stdout.write(next(iter(nodes)))
PY
  return 0
}
