#!/usr/bin/env bash
# Covers the pure, read-only authored-knowledge NODE resolver
# engine/ctx-rehydrate-authored-node.sh: the leaf primitive that resolves the
# executable DAG node owning a task from the durable task->node association in the
# control-state event log (stage S5-routing, node `rehydrate-path`, layer
# engine_runtime).
#
# Context: TASK-0064's pure builder gluerun_ctx_rehydrate_authored_triggers
# <role> <step> [node] [task] accepts an optional [node] slot, but its two live
# consumers wired in by TASK-0065 (engine/l1-drive.sh, engine/ctx-rehydrate-event.sh)
# both pass only `implementer implement "$task_id"`, omitting the node dimension
# because a run's DAG node is not readily in scope at either site. Consequently any
# authored entry whose `load-when` targets a node/stage can never become eligible and
# the builder's [node] parameter is dead. This slice is the first, PURE half of
# closing that gap: a read-only resolver that deterministically resolves the node
# owning <task_id> from the same durable event-log convention TASK-0032's locator
# reads. The follow-up wire-in that threads this resolver's output into the [node]
# slot at BOTH call sites is OUT OF SCOPE here.
#
# The file DEFINES a new function only and is invoked by NO existing engine path, so
# with it present-but-uncalled (auto-sourced by lib.sh's ctx-*.sh loader) the engine
# is byte-identical to prior behavior (test-engine-clean.sh green).
#
# Asserts:
#   (a) present-but-uncalled: lib.sh auto-sources it (engine/ctx-*.sh) and it defines
#       the NEW public function; no existing engine path invokes it.
#   (b) resolution: given a fixture event log in which <task_id> is associated with
#       exactly one distinct non-empty node, prints exactly that node id (rc 0).
#   (c) fail-safe on ambiguity: same task mapped to two+ distinct nodes -> empty
#       output, rc 0 (never a fabricated or arbitrarily first-matched node).
#   (d) fail-safe on absence: no association / missing / empty log -> empty, rc 0.
#   (e) determinism: identical bytes + task id -> byte-identical output.
#   (f) pure/read-only: appends no event, writes no state, never exits non-zero on
#       well-formed OR malformed input (malformed lines skipped, not fatal).
# The events log is pinned to an isolated GLUERUN_EVENTS_FILE and all inputs to tmp so
# the suite never mutates real run state.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-rehydrate-authored-node.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

export GLUERUN_ROOT="$tmp"
export GLUERUN_STATE_DIR="$tmp/state"
export GLUERUN_EVENTS_FILE="$tmp/state/events.ndjson"
: > "$GLUERUN_EVENTS_FILE"

# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# (a) The engine file must exist and be auto-sourced by lib.sh's ctx-loader; it
#     defines the NEW function (RED before impl).
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
[[ "$(type -t gluerun_ctx_rehydrate_authored_node)" == "function" ]] \
  || fail "gluerun_ctx_rehydrate_authored_node not defined (auto-source failed?)"

# A helper to append a raw control-state association event (as generate-tasks.sh /
# the l1 importer do): {ts,type,message,data:{taskId,node,...}} NDJSON lines. We write
# the fixture directly so the resolver's purity is measured against a fixed log.
emit_assoc() { # <type> <task_id> <node>
  printf '{"ts":"2026-07-11T00:00:00Z","type":"%s","message":"m","data":{"taskId":"%s","runId":"RUN-X","node":"%s"}}\n' \
    "$1" "$2" "$3" >> "$GLUERUN_EVENTS_FILE"
}

# ---------------------------------------------------------------------------
# (b) node resolution from a recorded (durable) task->node association.
# ---------------------------------------------------------------------------
emit_assoc "planner.staged" "TASK-0007" "rehydrate-path"
# An unrelated task/node pair must not leak into the answer.
emit_assoc "planner.staged" "TASK-0099" "some-other-node"

# Purity fingerprint of the event log + state dir before the read-only call.
events_ck_before="$(cksum < "$GLUERUN_EVENTS_FILE")"
state_fp_before="$(cd "$GLUERUN_STATE_DIR" && find . | sort | cksum)"

node_out="$(gluerun_ctx_rehydrate_authored_node "TASK-0007")" \
  || fail "resolver must exit 0"
[[ "$node_out" == "rehydrate-path" ]] \
  || fail "resolver must resolve the recorded node (got: '$node_out')"

# (e) determinism: identical bytes + task id -> byte-identical output.
node_out2="$(gluerun_ctx_rehydrate_authored_node "TASK-0007")" \
  || fail "resolver must exit 0 on repeat"
[[ "$node_out2" == "$node_out" ]] \
  || fail "resolver must be deterministic (got '$node_out2' vs '$node_out')"

# (f) Purity: no events appended, no state written by the read-only resolver.
[[ "$(cksum < "$GLUERUN_EVENTS_FILE")" == "$events_ck_before" ]] \
  || fail "resolver mutated the event log (must be read-only)"
[[ "$(cd "$GLUERUN_STATE_DIR" && find . | sort | cksum)" == "$state_fp_before" ]] \
  || fail "resolver mutated the state dir (must be read-only)"

# ---------------------------------------------------------------------------
# (d) fail-safe on absence.
# ---------------------------------------------------------------------------
# Missing association -> empty output, no crash.
miss="$(gluerun_ctx_rehydrate_authored_node "TASK-NONE")" \
  || fail "resolver on missing association must not crash"
[[ -z "$miss" ]] || fail "missing association must yield empty output (got: '$miss')"

# Empty task id -> empty output, no crash.
empty_tid="$(gluerun_ctx_rehydrate_authored_node "")" \
  || fail "resolver on empty task id must not crash"
[[ -z "$empty_tid" ]] || fail "empty task id must yield empty output (got: '$empty_tid')"

# ---------------------------------------------------------------------------
# (c) fail-safe on ambiguity: same task mapped to two DIFFERENT nodes -> empty.
# ---------------------------------------------------------------------------
emit_assoc "planner.generated" "TASK-0055" "node-alpha"
emit_assoc "planner.generated" "TASK-0055" "node-beta"
ambig="$(gluerun_ctx_rehydrate_authored_node "TASK-0055")" \
  || fail "resolver on ambiguous association must not crash"
[[ -z "$ambig" ]] || fail "ambiguous association must yield empty output (got: '$ambig')"

# A task mapped repeatedly to the SAME node is unambiguous -> resolves.
emit_assoc "planner.staged"    "TASK-0077" "node-gamma"
emit_assoc "planner.generated" "TASK-0077" "node-gamma"
same="$(gluerun_ctx_rehydrate_authored_node "TASK-0077")" \
  || fail "resolver on repeated same-node association must not crash"
[[ "$same" == "node-gamma" ]] \
  || fail "repeated same-node association must resolve (got: '$same')"

# ---------------------------------------------------------------------------
# (f) fail-soft on malformed input: bad lines skipped, never fatal.
# ---------------------------------------------------------------------------
printf 'not { valid json at all\n' >> "$GLUERUN_EVENTS_FILE"
printf '[]\n' >> "$GLUERUN_EVENTS_FILE"            # valid json, not an object
printf '{"data":"scalar"}\n' >> "$GLUERUN_EVENTS_FILE"  # data not an object
malformed="$(gluerun_ctx_rehydrate_authored_node "TASK-0007")" \
  || fail "resolver must not crash on malformed lines"
[[ "$malformed" == "rehydrate-path" ]] \
  || fail "malformed lines must be skipped, resolution intact (got: '$malformed')"

# Missing / empty event log -> empty output, no crash.
export GLUERUN_EVENTS_FILE="$tmp/state/no-such-events.ndjson"
noev="$(gluerun_ctx_rehydrate_authored_node "TASK-0007")" \
  || fail "resolver with absent event log must not crash"
[[ -z "$noev" ]] || fail "absent event log must yield empty output (got: '$noev')"
export GLUERUN_EVENTS_FILE="$tmp/state/events.ndjson"

# ---------------------------------------------------------------------------
# (a) wired-in at exactly the two expected consumer sites (TASK-0067). TASK-0066
#     shipped this resolver present-but-uncalled; TASK-0067's node-dimension
#     wire-in threads it into the builder's [node] slot at BOTH live consumers —
#     the injection (engine/l1-drive.sh) and the manifest-record
#     (engine/ctx-rehydrate-event.sh). No OTHER engine path may reference it, so
#     the resolver stays a leaf primitive delegated to only from those two sites.
# ---------------------------------------------------------------------------
callers="$(grep -rl "gluerun_ctx_rehydrate_authored_node" "$ENGINE_HOME/engine" 2>/dev/null \
  | grep -v '/ctx-rehydrate-authored-node.sh$' \
  | sed "s#^$ENGINE_HOME/##" | sort | tr '\n' ' ' | sed 's/ $//' || true)"
[[ "$callers" == "engine/ctx-rehydrate-event.sh engine/l1-drive.sh" ]] \
  || fail "gluerun_ctx_rehydrate_authored_node must be wired in at exactly the two node-dimension consumer sites (l1-drive.sh, ctx-rehydrate-event.sh); referenced by: $callers"

echo "ctx-rehydrate-authored-node tests passed"
