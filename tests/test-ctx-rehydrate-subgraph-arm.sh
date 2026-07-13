#!/usr/bin/env bash
# Covers the deterministic rehydration-mode decider engine/ctx-rehydrate-subgraph-arm.sh:
#
#   gluerun_ctx_rehydrate_subgraph_arm_mode <task_id> [graphDir]
#
# prints exactly `subgraph` or `flat`. It picks `subgraph` ONLY when ALL
# fail-closed preconditions hold, else `flat`:
#   (1) the dedicated feature knob GLUERUN_CTX_SUBGRAPH_REHYDRATE=1 (default 0);
#   (2) the task's deterministic A/B arm (via gluerun_ctx_ab_arm_for) is the
#       designated TREATMENT arm B — control arm A stays flat;
#   (3) the graph corpus at graphDir (default ${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph})
#       exists and is non-empty, so the subgraph assembler could render a packet.
#
# Asserts:
#   (a) Default OFF (knob unset AND =0) -> `flat` even for a treatment id with a
#       present, non-empty corpus; and no events / no filesystem mutation.
#   (b) knob=1 + treatment arm (B) + present non-empty corpus -> `subgraph`.
#   (c) Fail-closed: knob=1 + treatment arm but corpus MISSING or EMPTY -> `flat`.
#   (d) Control arm (A) stays flat even with knob=1 + non-empty corpus.
#   (e) Pure + non-fatal: prints EXACTLY the mode token (one line, nothing else),
#       exits 0, appends no events, and writes/renames/deletes nothing.
#   (f) Determinism / machine-independence: same id -> same mode across repeated
#       calls and across a separate bash process.
#   (g) Evidence invariance: a mode choice never confers independence and never
#       alters taint — gluerun_ctx_route_strategy_tainted rehydrate stays 1.
#   (h) OFF-parity: with the file sourced but the decider uncalled and the knob at
#       its default, sourcing emits nothing and defines only the one new function.
# The events log is pinned to an isolated temp file so the suite never mutates
# real run state.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
ARM="$ENGINE_HOME/engine/ctx-rehydrate-subgraph-arm.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

export GLUERUN_ROOT="$tmp"
export GLUERUN_STATE_DIR="$tmp/state"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the decider (RED before it is written).
# lib.sh's ctx-loader auto-sources it; source again defensively so a failure here
# is unambiguous.
[[ -f "$ARM" ]] || fail "engine not present yet: $ARM"
# shellcheck disable=SC1090
source "$ARM" || fail "sourcing $ARM failed"
[[ "$(type -t gluerun_ctx_rehydrate_subgraph_arm_mode)" == "function" ]] \
  || fail "gluerun_ctx_rehydrate_subgraph_arm_mode is not defined by $ARM"
# The integrated arm-assignment reader must be available (compose, not reimpl).
[[ "$(type -t gluerun_ctx_ab_arm_for)" == "function" ]] \
  || fail "gluerun_ctx_ab_arm_for (engine/ctx-ab.sh) not available"

# Point the events log at an isolated temp file (lib.sh sets it at source time).
export GLUERUN_EVENTS_FILE="$tmp/events.ndjson"
: > "$GLUERUN_EVENTS_FILE"

count_events() {
  [[ -f "$GLUERUN_EVENTS_FILE" ]] || { echo 0; return 0; }
  local c
  c="$(grep -c '"type":' "$GLUERUN_EVENTS_FILE" 2>/dev/null)" || true
  echo "${c:-0}"
}

# --- Pick a known treatment (B) id and a known control (A) id at runtime, so
#     the test tracks the integrated hash rather than hardcoding a mapping. ----
treat_id=""
ctrl_id=""
for id in TASK-0001 TASK-0002 TASK-0003 TASK-0004 TASK-0005 TASK-0006 \
          TASK-0007 TASK-0008 TASK-0009 TASK-0010 TASK-0011 TASK-0012; do
  arm="$(gluerun_ctx_ab_arm_for "$id")"
  [[ -z "$treat_id" && "$arm" == "B" ]] && treat_id="$id"
  [[ -z "$ctrl_id" && "$arm" == "A" ]] && ctrl_id="$id"
done
[[ -n "$treat_id" ]] || fail "setup: no treatment (B) id found in fixture set"
[[ -n "$ctrl_id"  ]] || fail "setup: no control (A) id found in fixture set"

# --- A present, non-empty graph corpus at an isolated graphDir ----------------
graph_full="$tmp/graph-full"
mkdir -p "$graph_full"
printf '%s\n' '{"id":"n1","type":"task"}' > "$graph_full/nodes.jsonl"
printf '%s\n' '{"from":"n1","to":"n2","type":"derived_from"}' > "$graph_full/edges.jsonl"

# A missing corpus (directory does not exist) and an empty one (dir, no content).
graph_missing="$tmp/graph-missing"   # never created
graph_empty="$tmp/graph-empty"
mkdir -p "$graph_empty"
: > "$graph_empty/nodes.jsonl"        # present but zero bytes

# ---------------------------------------------------------------------------
# (a) Default OFF -> flat, even with a treatment id + non-empty corpus.
# ---------------------------------------------------------------------------
unset GLUERUN_CTX_SUBGRAPH_REHYDRATE
before_ev="$(count_events)"
before_hash="$(find "$graph_full" -type f -exec shasum {} \; | shasum | awk '{print $1}')"
mode="$(gluerun_ctx_rehydrate_subgraph_arm_mode "$treat_id" "$graph_full")" \
  || fail "OFF(unset): decider exited non-zero"
[[ "$mode" == "flat" ]] || fail "OFF(unset): expected flat, got [$mode]"

GLUERUN_CTX_SUBGRAPH_REHYDRATE=0
mode="$(gluerun_ctx_rehydrate_subgraph_arm_mode "$treat_id" "$graph_full")" \
  || fail "OFF(=0): decider exited non-zero"
[[ "$mode" == "flat" ]] || fail "OFF(=0): expected flat, got [$mode]"
unset GLUERUN_CTX_SUBGRAPH_REHYDRATE

# ---------------------------------------------------------------------------
# (b) knob=1 + treatment arm + present non-empty corpus -> subgraph.
# ---------------------------------------------------------------------------
export GLUERUN_CTX_SUBGRAPH_REHYDRATE=1
mode="$(gluerun_ctx_rehydrate_subgraph_arm_mode "$treat_id" "$graph_full")" \
  || fail "ON+treat+corpus: decider exited non-zero"
[[ "$mode" == "subgraph" ]] || fail "ON+treat+corpus: expected subgraph, got [$mode]"

# Exactly the token — no trailing/extra lines.
raw="$(gluerun_ctx_rehydrate_subgraph_arm_mode "$treat_id" "$graph_full")"
[[ "$(printf '%s' "$raw" | wc -l | tr -d ' ')" == "0" || \
   "$(printf '%s\n' "$raw" | wc -l | tr -d ' ')" == "1" ]] \
  || fail "output has extra lines: [$raw]"
[[ "$raw" == "subgraph" ]] || fail "output not exactly 'subgraph': [$raw]"

# ---------------------------------------------------------------------------
# (c) Fail-closed to flat: knob=1 + treatment arm but corpus missing or empty.
# ---------------------------------------------------------------------------
mode="$(gluerun_ctx_rehydrate_subgraph_arm_mode "$treat_id" "$graph_missing")" \
  || fail "ON+treat+missing: decider exited non-zero"
[[ "$mode" == "flat" ]] || fail "ON+treat+missing corpus: expected flat, got [$mode]"

mode="$(gluerun_ctx_rehydrate_subgraph_arm_mode "$treat_id" "$graph_empty")" \
  || fail "ON+treat+empty: decider exited non-zero"
[[ "$mode" == "flat" ]] || fail "ON+treat+empty corpus: expected flat, got [$mode]"

# ---------------------------------------------------------------------------
# (d) Control arm (A) stays flat even with knob=1 + non-empty corpus.
# ---------------------------------------------------------------------------
mode="$(gluerun_ctx_rehydrate_subgraph_arm_mode "$ctrl_id" "$graph_full")" \
  || fail "ON+control+corpus: decider exited non-zero"
[[ "$mode" == "flat" ]] || fail "ON+control arm: expected flat, got [$mode]"

# ---------------------------------------------------------------------------
# (e) Pure + non-fatal: no events appended, no filesystem mutation of the corpus
#     across every call above.
# ---------------------------------------------------------------------------
after_ev="$(count_events)"
[[ "$after_ev" -eq "$before_ev" ]] \
  || fail "decider appended events ($before_ev -> $after_ev)"
after_hash="$(find "$graph_full" -type f -exec shasum {} \; | shasum | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]] || fail "decider mutated the graph corpus"
# The isolated state dir must gain nothing from a pure read.
[[ -z "$(ls -A "$tmp/state" 2>/dev/null)" ]] || fail "decider wrote into the state dir"

# ---------------------------------------------------------------------------
# (f) Determinism / machine-independence: same id -> same mode across repeated
#     calls and a separate bash process.
# ---------------------------------------------------------------------------
m1="$(gluerun_ctx_rehydrate_subgraph_arm_mode "$treat_id" "$graph_full")"
m2="$(gluerun_ctx_rehydrate_subgraph_arm_mode "$treat_id" "$graph_full")"
[[ "$m1" == "$m2" ]] || fail "determinism: repeated calls differ ($m1 vs $m2)"
m3="$(GLUERUN_CTX_SUBGRAPH_REHYDRATE=1 bash -c \
      'source "'"$ENGINE_HOME/engine/ctx-ab.sh"'"; source "'"$ARM"'"; \
       gluerun_ctx_rehydrate_subgraph_arm_mode "'"$treat_id"'" "'"$graph_full"'"')" \
  || fail "determinism: subprocess invocation failed"
[[ "$m1" == "$m3" ]] || fail "determinism: cross-process mode differs ($m1 vs $m3)"

# ---------------------------------------------------------------------------
# (g) Evidence invariance: the mode choice never alters taint. The rehydrate
#     strategy stays tainted regardless of which mode was chosen.
# ---------------------------------------------------------------------------
taint_before="$(gluerun_ctx_route_strategy_tainted rehydrate)"
gluerun_ctx_rehydrate_subgraph_arm_mode "$treat_id" "$graph_full" >/dev/null
gluerun_ctx_rehydrate_subgraph_arm_mode "$ctrl_id" "$graph_full" >/dev/null
taint_after="$(gluerun_ctx_route_strategy_tainted rehydrate)"
[[ "$taint_before" == "1" ]] || fail "precondition: rehydrate not tainted"
[[ "$taint_before" == "$taint_after" ]] \
  || fail "evidence invariance: taint changed ($taint_before -> $taint_after)"
unset GLUERUN_CTX_SUBGRAPH_REHYDRATE

# ---------------------------------------------------------------------------
# (h) OFF-parity: sourcing the file in a clean subshell with the knob at default
#     emits nothing on stdout/stderr and defines the decider.
# ---------------------------------------------------------------------------
src_out="$(bash -c 'source "'"$ENGINE_HOME/engine/ctx-ab.sh"'"; source "'"$ARM"'"; \
                    type -t gluerun_ctx_rehydrate_subgraph_arm_mode' 2>&1)"
[[ "$src_out" == "function" ]] \
  || fail "OFF-parity: sourcing emitted output or failed to define the fn: [$src_out]"
# Default-off: every fixture id maps to flat when the knob is unset.
for id in "$treat_id" "$ctrl_id" TASK-0001 TASK-0002 TASK-0003; do
  m="$(gluerun_ctx_rehydrate_subgraph_arm_mode "$id" "$graph_full")"
  [[ "$m" == "flat" ]] || fail "OFF-parity: id $id did not map to flat ([$m])"
done

echo "ctx-rehydrate-subgraph-arm tests passed"
