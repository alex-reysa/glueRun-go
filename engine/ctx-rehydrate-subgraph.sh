#!/usr/bin/env bash
# ctx-rehydrate-subgraph.sh — the first, smallest strict-test-first brick of the
# executable DAG node `subgraph-rehydrate` (stage S6-graph, layer
# engine_runtime): a pure, read-only, deterministic SUBGRAPH SELECTION reader
# over the materialized context provenance corpus
# (schemas/context-graph.v0.schema.json).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines a new
# function ONLY; NO existing engine/CLI/driver path invokes it, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# when GLUERUN_CTX_GRAPH is unset or 0). The graph flag GLUERUN_CTX_GRAPH and the
# rehydrate arm knobs gate the LATER wire-in, not this pure reader.
#
# Evidence invariance / advocate-skeptic line: selection is a pure read — it
# never writes, never mutates taint, confers NO independence on a resumed or
# rehydrated session, and records nothing as `authoritative`. It only CHOOSES and
# ORDERS existing records over <graphDir>/nodes.jsonl + edges.jsonl, reading only
# those two files and emitting byte-identical output for a given corpus. A
# missing or empty corpus yields a well-formed EMPTY result with a zero exit
# (fail-safe). <graphDir> defaults to ${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}.
#
# This slice SELECTS only. It does NOT resolve selected nodes to durable artifact
# paths, assemble the packet, touch section caps, or record any manifest — the
# assembler that maps the selection onto gluerun_ctx_rehydrate_packet/_manifest
# (caps and manifest UNCHANGED) and the A/B arm wire-in are separate later slices.
#
# Public function:
#   gluerun_ctx_rehydrate_subgraph_select <graphDir> <taskNodeId>
#       Walk the provenance lineage of <taskNodeId> and emit the DETERMINISTIC,
#       ORDERED set of SELECTED node records (canonical JSONL, verbatim), where
#         (1) rejected observations — nodes reached ONLY across a
#             `rejects_observation` edge — are EXCLUDED, and
#         (2) contradiction-flagged nodes (targets of an OPEN
#             `contradicts`/`invalidates` edge with no superseding resolution)
#             are emitted FIRST, then the remaining selected lineage nodes in a
#             deterministic (by node id) order.
#       This replaces flat per-artifact concatenation with rule-based lineage
#       selection; there is NO relevance scoring (v0 rule). It COMPOSES the
#       integrated graph read API — gluerun_graph_query_lineage and
#       gluerun_graph_query_open_contradictions (engine/ctx-graph-query.sh).

# gluerun_ctx_rehydrate_subgraph_select <graphDir> <taskNodeId>
gluerun_ctx_rehydrate_subgraph_select() {
  local graph_dir="${1:-${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}}"
  local task_node="${2:-}"

  # Compose the integrated read API: the provenance lineage component (the
  # universe of candidate node records) and the open contradiction edges (whose
  # targets are surfaced first). Both are read-only, fail-safe on a missing or
  # empty corpus, and deterministic for a given corpus.
  local lineage_records contradiction_edges
  lineage_records="$(gluerun_graph_query_lineage "$graph_dir" "$task_node")" || return 1
  contradiction_edges="$(gluerun_graph_query_open_contradictions "$graph_dir")" || return 1

  GLUERUN_SG_DIR="$graph_dir" \
  GLUERUN_SG_TASK="$task_node" \
  GLUERUN_SG_LINEAGE="$lineage_records" \
  GLUERUN_SG_CONTRA="$contradiction_edges" \
  python3 -c '
import json, os
from collections import deque

graph_dir = os.environ["GLUERUN_SG_DIR"]
task = os.environ["GLUERUN_SG_TASK"]
lineage_lines = [ln for ln in os.environ["GLUERUN_SG_LINEAGE"].splitlines() if ln.strip()]
contra_lines = [ln for ln in os.environ["GLUERUN_SG_CONTRA"].splitlines() if ln.strip()]

# The provenance taxonomy the lineage walk follows (context-graph.v0), MINUS
# rejects_observation. A raw lineage walk INCLUDES rejects_observation, so a
# rejected observation is pulled into the component; a node reachable only across
# such an edge is a rejected observation and must never enter the selection. A
# node also reachable by a non-rejecting provenance edge is retained.
KEEP = {
    "implements",
    "derived_from",
    "revises",
    "critiques",
    "accepts_observation",
    "verifies",
}

def read_lines(name):
    path = os.path.join(graph_dir, name)
    try:
        with open(path, encoding="utf-8") as fh:
            return [ln.rstrip("\n") for ln in fh if ln.strip()]
    except FileNotFoundError:
        return []

edge_lines = read_lines("edges.jsonl")

# Undirected adjacency over the kept provenance subgraph (rejects excluded),
# mirroring the lineage walk direction-insensitively.
adj = {}
for ln in edge_lines:
    e = json.loads(ln)
    if e.get("type") in KEEP:
        a, b = e.get("from"), e.get("to")
        adj.setdefault(a, set()).add(b)
        adj.setdefault(b, set()).add(a)

# Nodes reachable from the task without ever crossing a rejects_observation edge,
# with a visited-set guard so cycles terminate.
kept = {task}
queue = deque([task])
while queue:
    cur = queue.popleft()
    for nb in adj.get(cur, ()):
        if nb not in kept:
            kept.add(nb)
            queue.append(nb)

# The composed lineage component is the candidate universe (verbatim records);
# intersecting with `kept` drops the rejected-only observations.
lineage_by_id = {}
for ln in lineage_lines:
    lineage_by_id[json.loads(ln)["id"]] = ln
selected = {nid: ln for nid, ln in lineage_by_id.items() if nid in kept}

# Contradiction-flagged nodes: the `to` (contradicted/invalidated) node of each
# open contradiction edge, restricted to the selection.
targets = set()
for ln in contra_lines:
    t = json.loads(ln).get("to")
    if t is not None:
        targets.add(t)

flagged = sorted(nid for nid in selected if nid in targets)
rest = sorted(nid for nid in selected if nid not in targets)
for nid in flagged:
    print(selected[nid])
for nid in rest:
    print(selected[nid])
'
}
