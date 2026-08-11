#!/usr/bin/env bash
# Covers the FIRST strict-test-first brick of the executable DAG node
# `subgraph-rehydrate` (stage S6-graph, layer engine_runtime): a NEW pure,
# read-only, deterministic SUBGRAPH SELECTION reader in
# engine/ctx-rehydrate-subgraph.sh.
#
#   singular_ctx_rehydrate_subgraph_select <graphDir> <taskNodeId>
#       Walk the provenance lineage of <taskNodeId> and emit the DETERMINISTIC,
#       ORDERED set of SELECTED node records, where
#         (1) rejected observations — nodes reached ONLY across a
#             `rejects_observation` edge — are EXCLUDED, and
#         (2) contradiction-flagged nodes (targets of an OPEN
#             `contradicts`/`invalidates` edge with no superseding resolution)
#             are surfaced FIRST, then the remaining selected lineage nodes in a
#             deterministic (by node id) order.
#
# It COMPOSES the integrated graph read API — singular_graph_query_lineage and
# singular_graph_query_open_contradictions in engine/ctx-graph-query.sh — over the
# materialized corpus <graphDir>/nodes.jsonl + edges.jsonl. It SELECTS only: it
# does NOT resolve node records to durable artifact paths, assemble a packet,
# touch section caps, or record any manifest.
#
# Because a raw lineage walk follows the provenance taxonomy that INCLUDES
# `rejects_observation`, the selector must post-filter nodes reached only through
# a `rejects_observation` edge so rejected observations never enter the selection
# — while a node reached ALSO by a non-rejecting provenance edge is RETAINED.
#
# Asserts: the selected set is exactly the task's provenance lineage minus the
# rejected-only observations; a rejected-only observation is excluded while a
# node that is both rejected AND independently derived is retained; open
# contradiction targets within the selection are emitted first, then the rest by
# id; off-lineage nodes (joined only by a non-provenance edge) are never
# selected; the read is byte-identical on repeat and leaves the corpus untouched
# (no manifest, no files); a missing/empty corpus yields a well-formed empty
# result with a zero exit; and OFF-parity — sourcing the file defines the
# function, invokes nothing, and writes nothing.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRAPH="$ENGINE_HOME/engine/ctx-graph.sh"
CORPUS="$ENGINE_HOME/engine/ctx-graph-corpus.sh"
QUERY="$ENGINE_HOME/engine/ctx-graph-query.sh"
SUBGRAPH="$ENGINE_HOME/engine/ctx-rehydrate-subgraph.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- strict-test-first RED precondition: fail closed with no impl present -----
[[ -f "$GRAPH" ]]  || fail "missing projection primitives: $GRAPH"
[[ -f "$CORPUS" ]] || fail "missing corpus writer: $CORPUS"
[[ -f "$QUERY" ]]  || fail "missing graph read API: $QUERY"
[[ -f "$SUBGRAPH" ]] || fail "impl not present yet: $SUBGRAPH (strict-test-first RED)"

work_root="$(mktemp -d)"
snap_dir="$(mktemp -d)"
trap 'rm -rf "$work_root" "$snap_dir"' EXIT

# --- OFF-parity / no-writes on source: sourcing invokes nothing, writes nothing.
before="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
unset SINGULAR_CTX_GRAPH 2>/dev/null || true
# shellcheck disable=SC1090
( cd "$snap_dir" && source "$GRAPH" && source "$CORPUS" && source "$QUERY" && source "$SUBGRAPH" ) \
  || fail "sourcing $SUBGRAPH failed"
after="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail "sourcing $SUBGRAPH created filesystem artifacts (OFF-parity)"

# shellcheck disable=SC1090
source "$GRAPH"    || fail "sourcing $GRAPH failed"
# shellcheck disable=SC1090
source "$CORPUS"   || fail "sourcing $CORPUS failed"
# shellcheck disable=SC1090
source "$QUERY"    || fail "sourcing $QUERY failed"
# shellcheck disable=SC1090
source "$SUBGRAPH" || fail "sourcing $SUBGRAPH failed"

[[ "$(type -t singular_ctx_rehydrate_subgraph_select)" == "function" ]] \
  || fail "singular_ctx_rehydrate_subgraph_select is not defined by $SUBGRAPH"

# --- small parsing helpers ----------------------------------------------------
# Print the `id` of each JSONL record on stdin whose `kind` matches $1 (or all
# records when $1 is empty), one per line, preserving INPUT ORDER (so ordering
# assertions are meaningful).
kind_ids_in_order() {
  local want="${1:-}"
  SINGULAR_TQ_KIND="$want" python3 -c '
import json, os, sys
want = os.environ["SINGULAR_TQ_KIND"]
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        continue
    o = json.loads(line)
    if not want or o.get("kind") == want:
        print(o["id"])
'
}
sorted_lines() { LC_ALL=C sort; }
expect_eq() { # <label> <actual> <expected>
  [[ "$2" == "$3" ]] || fail "$1: got [$2] want [$3]"
}

# =============================================================================
# CORPUS — the task's provenance lineage, plus the two post-filter cases and an
# open contradiction.
#
# Provenance chain: task T -> attempt A -> plan-version P -> critique C, with an
# open assumption AS derived from P, an accepted finding F, a disposition D.
#   - RO  (finding): reached ONLY via `D rejects_observation RO`  -> EXCLUDED.
#   - F2  (finding): reached via `C derived_from F2` AND `D rejects_observation
#                    F2` -> RETAINED (not reached ONLY through a rejection).
#   - AS  (assumption): target of an OPEN `contradicts` edge (G contradicts AS,
#                    never superseded) -> SURFACED FIRST.
#   - G   (plan-version): the contradiction source, joined to the lineage ONLY by
#                    a non-provenance (`contradicts`) edge -> NEVER selected.
#   - D -> T (revises): closes a cycle so the visited-set guard is exercised.
# =============================================================================
GDIR="$work_root/graph"
NODES_IN="$work_root/nodes.in"
EDGES_IN="$work_root/edges.in"

T="$(singular_graph_node_id 'task:T')"
A="$(singular_graph_node_id 'attempt:A')"
P="$(singular_graph_node_id 'pv:P')"
C="$(singular_graph_node_id 'crit:C')"
AS="$(singular_graph_node_id 'assume:AS')"
F="$(singular_graph_node_id 'find:F')"
F2="$(singular_graph_node_id 'find:F2')"
RO="$(singular_graph_node_id 'find:RO')"
D="$(singular_graph_node_id 'disp:D')"
G="$(singular_graph_node_id 'pv:G')"

{
  singular_graph_emit_node task         'task:T'     'src/T'  'cT'
  singular_graph_emit_node attempt      'attempt:A'  'src/A'  'cA'
  singular_graph_emit_node plan-version 'pv:P'       'src/P'  'cP'
  singular_graph_emit_node critique     'crit:C'     'src/C'  'cC'
  singular_graph_emit_node assumption   'assume:AS'  'src/AS' 'cAS'
  singular_graph_emit_node finding      'find:F'     'src/F'  'cF'
  singular_graph_emit_node finding      'find:F2'    'src/F2' 'cF2'
  singular_graph_emit_node finding      'find:RO'    'src/RO' 'cRO'
  singular_graph_emit_node decision     'disp:D'     'src/D'  'cD'
  singular_graph_emit_node plan-version 'pv:G'       'src/G'  'cG'
} > "$NODES_IN"

{
  singular_graph_emit_edge implements          "$A" "$T"  'src/e1'  'c1'
  singular_graph_emit_edge derived_from        "$P" "$A"  'src/e2'  'c2'
  singular_graph_emit_edge critiques           "$C" "$P"  'src/e3'  'c3'
  singular_graph_emit_edge derived_from        "$AS" "$P" 'src/e4'  'c4'
  singular_graph_emit_edge derived_from        "$F" "$C"  'src/e5'  'c5'
  singular_graph_emit_edge accepts_observation "$D" "$F"  'src/e6'  'c6'
  singular_graph_emit_edge derived_from        "$F2" "$C" 'src/e7'  'c7'
  singular_graph_emit_edge rejects_observation "$D" "$F2" 'src/e8'  'c8'
  singular_graph_emit_edge rejects_observation "$D" "$RO" 'src/e9'  'c9'
  singular_graph_emit_edge revises             "$D" "$T"  'src/e10' 'c10'
  singular_graph_emit_edge contradicts         "$G" "$AS" 'src/e11' 'c11'
} > "$EDGES_IN"

singular_graph_write_corpus "$GDIR" "$NODES_IN" "$EDGES_IN" || fail "write_corpus failed"

# --- Selection from T ---------------------------------------------------------
sel="$(singular_ctx_rehydrate_subgraph_select "$GDIR" "$T")" \
  || fail "subgraph_select(T) nonzero exit"

# Only node records are emitted (SELECTS only — no edges, no manifest lines).
non_nodes="$(printf '%s\n' "$sel" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        continue
    o = json.loads(line)
    if o.get("kind") != "node":
        print(o.get("kind"))
')"
[[ -z "$non_nodes" ]] || fail "selection emitted non-node records: [$non_nodes]"

sel_ids_ordered="$(printf '%s\n' "$sel" | kind_ids_in_order node)"
sel_ids_sorted="$(printf '%s\n' "$sel_ids_ordered" | sorted_lines)"

# Selected set == lineage {T,A,P,C,AS,F,F2,D} minus the rejected-only RO.
want_selected="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
  "$T" "$A" "$P" "$C" "$AS" "$F" "$F2" "$D" | sorted_lines)"
expect_eq "selected set" "$sel_ids_sorted" "$want_selected"

# (1) Rejected-only observation RO is EXCLUDED.
printf '%s\n' "$sel_ids_ordered" | grep -qx "$RO" \
  && fail "selection must exclude the rejected-only observation RO"
# A node reached ALSO by a non-rejecting edge (F2) is RETAINED.
printf '%s\n' "$sel_ids_ordered" | grep -qx "$F2" \
  || fail "selection must retain F2 (rejected but also independently derived)"
# Off-lineage contradiction source G (joined only by a non-provenance edge) is
# NEVER selected.
printf '%s\n' "$sel_ids_ordered" | grep -qx "$G" \
  && fail "selection must exclude off-lineage node G"

# (2) The open contradiction target AS is surfaced FIRST. Only AS is flagged, so
# it must be the very first emitted record, ahead of every non-flagged node.
first_id="$(printf '%s\n' "$sel_ids_ordered" | head -n1)"
expect_eq "contradiction-flagged node emitted first" "$first_id" "$AS"

# After the single flagged node, the remaining records are the rest of the
# selection in deterministic (by id) order.
rest_ordered="$(printf '%s\n' "$sel_ids_ordered" | tail -n +2)"
want_rest="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
  "$T" "$A" "$P" "$C" "$F" "$F2" "$D" | sorted_lines)"
expect_eq "remaining selection sorted by id" "$rest_ordered" "$want_rest"

# --- Determinism: byte-identical on repeat.
sel2="$(singular_ctx_rehydrate_subgraph_select "$GDIR" "$T")" \
  || fail "subgraph_select(T) repeat nonzero exit"
[[ "$sel" == "$sel2" ]] || fail "subgraph_select(T) not byte-identical on repeat"

# --- Read-only: the corpus is byte-identical and no files were created.
snap_before="$(cd "$GDIR" && find . | LC_ALL=C sort)"
sum_before="$(cat "$GDIR/nodes.jsonl" "$GDIR/edges.jsonl" | shasum | awk '{print $1}')"
singular_ctx_rehydrate_subgraph_select "$GDIR" "$T" >/dev/null \
  || fail "read-only selection failed"
snap_after="$(cd "$GDIR" && find . | LC_ALL=C sort)"
sum_after="$(cat "$GDIR/nodes.jsonl" "$GDIR/edges.jsonl" | shasum | awk '{print $1}')"
[[ "$snap_before" == "$snap_after" ]] || fail "selection created/removed files under <graphDir> (must be read-only)"
[[ "$sum_before" == "$sum_after" ]] || fail "selection mutated the corpus (must be read-only)"

# --- Unknown task node -> empty result, zero exit (fail-safe).
unknown="n-000000000000"
u_sel="$(singular_ctx_rehydrate_subgraph_select "$GDIR" "$unknown")" \
  || fail "subgraph_select(unknown) must exit zero (fail-safe)"
[[ -z "$u_sel" ]] || fail "subgraph_select(unknown) must be empty, got [$u_sel]"

# --- Missing corpus -> well-formed empty result, zero exit; nothing created.
GDIR_MISSING="$work_root/graph-missing"
m_sel="$(singular_ctx_rehydrate_subgraph_select "$GDIR_MISSING" "$T")" \
  || fail "subgraph_select on missing corpus must exit zero"
[[ -z "$m_sel" ]] || fail "subgraph_select on missing corpus must be empty"
[[ ! -e "$GDIR_MISSING" ]] || fail "querying a missing corpus created <graphDir> (must be read-only)"

# --- Empty corpus -> well-formed empty result, zero exit.
GDIR_EMPTY="$work_root/graph-empty"
mkdir -p "$GDIR_EMPTY"
: > "$GDIR_EMPTY/nodes.jsonl"
: > "$GDIR_EMPTY/edges.jsonl"
e_sel="$(singular_ctx_rehydrate_subgraph_select "$GDIR_EMPTY" "$T")" \
  || fail "subgraph_select on empty corpus must exit zero"
[[ -z "$e_sel" ]] || fail "subgraph_select on empty corpus must be empty"

echo "test-ctx-rehydrate-subgraph: all assertions passed"
