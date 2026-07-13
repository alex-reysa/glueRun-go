#!/usr/bin/env bash
# Covers the flat-vs-subgraph manifest SELECTOR engine/ctx-route-subgraph.sh:
#
#   gluerun_ctx_route_subgraph_manifest <reason> <role> <step> <meta> <key>
#
# and the engine/ctx-route.sh call-site hook that threads <key> into
# _gluerun_ctx_route_refuse_resume and delegates its manifest composition to the
# selector before handing the result to gluerun_ctx_route_rehydrate_decide.
#
# The selector prints the manifest the decision leaf will see:
#   - When GLUERUN_CTX_SUBGRAPH_REHYDRATE=1 AND the integrated arm decider
#     gluerun_ctx_rehydrate_subgraph_arm_mode <key> <graphDir> returns `subgraph`,
#     it resolves the task node id deterministically as
#       gluerun_graph_node_id( gluerun_graph_identity task <key> )
#     and prints gluerun_ctx_rehydrate_subgraph_assemble <graphDir> <node> manifest
#     (graphDir = ${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}).
#   - Otherwise it prints the FLAT manifest, BYTE-IDENTICAL to the existing
#     composition (gluerun_ctx_rehydrate_sources over dirname(meta) piped into
#     gluerun_ctx_rehydrate_manifest).
#
# Asserts:
#   (a) OFF-parity: with GLUERUN_CTX_SUBGRAPH_REHYDRATE unset/0 the selector's
#       output is byte-identical to the flat manifest for a treatment id + a
#       present non-empty corpus.
#   (b) knob=1 + treatment arm + present non-empty corpus -> selector delegates to
#       the subgraph assembler at the DETERMINISTIC task node id.
#   (c) Control arm, or knob off, or absent/empty corpus -> flat manifest.
#   (d) _gluerun_ctx_route_refuse_resume: with GLUERUN_REHYDRATE!=1 emits the bare
#       `fresh <reason>` (no manifest work); with GLUERUN_REHYDRATE=1 + a non-empty
#       flat run_dir emits `rehydrate <reason>`; OFF-parity of the subgraph knob
#       leaves that line byte-identical to before the wire-in.
#   (e) Spine one-line / no-event / taint contract: exactly one line, appends no
#       events, writes nothing, exits 0; rehydrate stays tainted.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
SEL="$ENGINE_HOME/engine/ctx-route-subgraph.sh"
ROUTE="$ENGINE_HOME/engine/ctx-route.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

export GLUERUN_ROOT="$tmp"
export GLUERUN_STATE_DIR="$tmp/state"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

[[ -f "$SEL" ]] || fail "engine not present yet: $SEL"
# shellcheck disable=SC1090
source "$SEL" || fail "sourcing $SEL failed"
[[ "$(type -t gluerun_ctx_route_subgraph_manifest)" == "function" ]] \
  || fail "gluerun_ctx_route_subgraph_manifest is not defined by $SEL"
# Integrated pieces the selector composes must be available (compose, not reimpl).
for fn in gluerun_ctx_rehydrate_subgraph_arm_mode \
          gluerun_ctx_rehydrate_subgraph_assemble \
          gluerun_graph_node_id gluerun_graph_identity \
          gluerun_ctx_rehydrate_sources gluerun_ctx_rehydrate_manifest \
          gluerun_ctx_route_rehydrate_decide _gluerun_ctx_route_refuse_resume; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn not available"
done

export GLUERUN_EVENTS_FILE="$tmp/events.ndjson"
: > "$GLUERUN_EVENTS_FILE"
count_events() {
  [[ -f "$GLUERUN_EVENTS_FILE" ]] || { echo 0; return 0; }
  local c
  c="$(grep -c '"type":' "$GLUERUN_EVENTS_FILE" 2>/dev/null)" || true
  echo "${c:-0}"
}

# --- Pick a known treatment (B) id and control (A) id at runtime -------------
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

# --- A present, non-empty graph corpus (so the arm decider can pick subgraph) -
export GLUERUN_CTX_GRAPH_DIR="$tmp/graph-full"
mkdir -p "$GLUERUN_CTX_GRAPH_DIR"
printf '%s\n' '{"id":"n1","type":"task"}' > "$GLUERUN_CTX_GRAPH_DIR/nodes.jsonl"
printf '%s\n' '{"from":"n1","to":"n2","type":"derived_from"}' > "$GLUERUN_CTX_GRAPH_DIR/edges.jsonl"

# --- A flat run_dir with at least one durable source (non-empty flat manifest) -
run_dir="$tmp/run"
mkdir -p "$run_dir"
meta="$run_dir/session-meta.json"
printf '%s\n' '{"schema":"task-packet","taskId":"'"$treat_id"'"}' > "$run_dir/packet.json"
: > "$meta"

# Helper: compute the flat manifest exactly as the legacy composition did.
flat_manifest() {
  local rd="$1"
  local -a specs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && specs+=("$line")
  done < <(gluerun_ctx_rehydrate_sources "$rd")
  gluerun_ctx_rehydrate_manifest ${specs[@]+"${specs[@]}"}
}

expected_flat="$(flat_manifest "$run_dir")"
# Sanity: the flat manifest for our run_dir is non-empty (has a source).
_gluerun_ctx_route_rehydrate_has_source "$expected_flat" \
  || fail "setup: flat manifest unexpectedly has no source"

before_ev="$(count_events)"

# ---------------------------------------------------------------------------
# (a) OFF-parity: knob unset/0 -> selector == flat manifest, byte-identical.
# ---------------------------------------------------------------------------
unset GLUERUN_CTX_SUBGRAPH_REHYDRATE
got="$(gluerun_ctx_route_subgraph_manifest diff-volume implementer some-step "$meta" "$treat_id")" \
  || fail "OFF(unset): selector exited non-zero"
[[ "$got" == "$expected_flat" ]] \
  || fail "OFF(unset): selector not byte-identical to flat manifest"

GLUERUN_CTX_SUBGRAPH_REHYDRATE=0
got="$(gluerun_ctx_route_subgraph_manifest diff-volume implementer some-step "$meta" "$treat_id")" \
  || fail "OFF(=0): selector exited non-zero"
[[ "$got" == "$expected_flat" ]] || fail "OFF(=0): selector not byte-identical to flat"
unset GLUERUN_CTX_SUBGRAPH_REHYDRATE

# ---------------------------------------------------------------------------
# (b) knob=1 + treatment arm + non-empty corpus -> subgraph assembler at the
#     deterministic task node id.
# ---------------------------------------------------------------------------
export GLUERUN_CTX_SUBGRAPH_REHYDRATE=1
node="$(gluerun_graph_node_id "$(gluerun_graph_identity task "$treat_id")")"
expected_sub="$(gluerun_ctx_rehydrate_subgraph_assemble "$GLUERUN_CTX_GRAPH_DIR" "$node" manifest)"
got="$(gluerun_ctx_route_subgraph_manifest diff-volume implementer some-step "$meta" "$treat_id")" \
  || fail "ON+treat+corpus: selector exited non-zero"
[[ "$got" == "$expected_sub" ]] \
  || fail "ON+treat+corpus: selector did not delegate to subgraph assembler at node $node"
# And it must NOT be the flat manifest (the branch actually diverged).
[[ "$got" != "$expected_flat" ]] \
  || fail "ON+treat+corpus: selector still returned the flat manifest"

# ---------------------------------------------------------------------------
# (c) Control arm -> flat; absent/empty corpus -> flat (fail-closed via decider).
# ---------------------------------------------------------------------------
got="$(gluerun_ctx_route_subgraph_manifest diff-volume implementer some-step "$meta" "$ctrl_id")" \
  || fail "ON+control: selector exited non-zero"
expected_flat_ctrl="$(flat_manifest "$run_dir")"
[[ "$got" == "$expected_flat_ctrl" ]] || fail "ON+control arm: expected flat manifest"

# Absent corpus: point the default graphDir at a nonexistent path.
GLUERUN_CTX_GRAPH_DIR="$tmp/graph-missing" \
  got="$(GLUERUN_CTX_GRAPH_DIR="$tmp/graph-missing" \
         gluerun_ctx_route_subgraph_manifest diff-volume implementer some-step "$meta" "$treat_id")" \
  || fail "ON+missing corpus: selector exited non-zero"
[[ "$got" == "$expected_flat" ]] || fail "ON+missing corpus: expected flat manifest"
export GLUERUN_CTX_GRAPH_DIR="$tmp/graph-full"

# ---------------------------------------------------------------------------
# (d) _gluerun_ctx_route_refuse_resume wire-in.
# ---------------------------------------------------------------------------
# GLUERUN_REHYDRATE != 1 -> bare `fresh <reason>`, no manifest work.
unset GLUERUN_REHYDRATE
line="$(_gluerun_ctx_route_refuse_resume diff-volume implementer some-step "$meta" "$treat_id")" \
  || fail "REHYDRATE off: refuse_resume exited non-zero"
[[ "$line" == "fresh diff-volume" ]] || fail "REHYDRATE off: expected 'fresh diff-volume', got [$line]"

# GLUERUN_REHYDRATE=1 + non-empty flat run_dir + subgraph knob OFF -> rehydrate,
# byte-identical to before the wire-in.
export GLUERUN_REHYDRATE=1
unset GLUERUN_CTX_SUBGRAPH_REHYDRATE
line="$(_gluerun_ctx_route_refuse_resume diff-volume implementer some-step "$meta" "$treat_id")" \
  || fail "REHYDRATE on (flat): refuse_resume exited non-zero"
[[ "$line" == "rehydrate diff-volume" ]] \
  || fail "REHYDRATE on (flat): expected 'rehydrate diff-volume', got [$line]"

# Same call, subgraph knob ON + treatment + corpus -> the wire-in only chooses
# WHICH manifest the leaf sees, then hands it to the SAME decision leaf. Its line
# must therefore equal what the leaf renders for the graph-selected manifest
# (verbatim composition, not a re-derivation), and stay a single spine line.
export GLUERUN_CTX_SUBGRAPH_REHYDRATE=1
expected_wire="$(gluerun_ctx_route_rehydrate_decide diff-volume implementer some-step "$expected_sub")"
line="$(_gluerun_ctx_route_refuse_resume diff-volume implementer some-step "$meta" "$treat_id")" \
  || fail "REHYDRATE on (subgraph): refuse_resume exited non-zero"
[[ "$line" == "$expected_wire" ]] \
  || fail "REHYDRATE on (subgraph): wire-in line [$line] != leaf-over-subgraph-manifest [$expected_wire]"
# Whatever the verdict, it is exactly one spine line whose strategy is in the
# alphabet {rehydrate,fresh} carrying its reason.
[[ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" == "1" ]] || fail "refuse_resume emitted != 1 line"
[[ "$line" == "rehydrate diff-volume" || "$line" == "fresh diff-volume" ]] \
  || fail "REHYDRATE on (subgraph): unexpected spine line [$line]"
unset GLUERUN_CTX_SUBGRAPH_REHYDRATE
unset GLUERUN_REHYDRATE

# ---------------------------------------------------------------------------
# (e) No events appended, no state written, taint unchanged.
# ---------------------------------------------------------------------------
after_ev="$(count_events)"
[[ "$after_ev" -eq "$before_ev" ]] || fail "selector/wire-in appended events ($before_ev -> $after_ev)"
[[ -z "$(ls -A "$tmp/state" 2>/dev/null)" ]] || fail "selector/wire-in wrote into the state dir"
[[ "$(gluerun_ctx_route_strategy_tainted rehydrate)" == "1" ]] \
  || fail "evidence invariance: rehydrate is no longer tainted"

echo "ctx-rehydrate-subgraph-route tests passed"
