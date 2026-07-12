#!/usr/bin/env bash
# ctx-graph-query.sh — the graph-projector `query` read API for the context
# provenance graph (schemas/context-graph.v0.schema.json): the third and final
# requiredCompletion verb alongside the integrated `rebuild` (ctx-graph-rebuild.sh)
# and `sync` (ctx-graph-sync.sh).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions ONLY; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior
# (OFF-parity when GLUERUN_CTX_GRAPH is unset or 0). The eventual `cli/gluerun
# graph query` call site is a later task.
#
# Every function here is a READ-ONLY, deterministic reader over the materialized
# canonical corpus <graphDir>/nodes.jsonl + <graphDir>/edges.jsonl (dedup by id +
# sorted by id, as gluerun_graph_write_corpus produces). Each reads ONLY those two
# files, writes NOTHING, and emits byte-identical output for a given corpus. A
# missing or empty corpus yields a well-formed EMPTY result with a zero exit
# (fail-safe) rather than an error. <graphDir> defaults to
# ${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph} when not supplied.
#
# Public functions:
#   gluerun_graph_query_neighbors <graphDir> <nodeId>
#       Print every edge record incident to <nodeId> (as `from` or `to`) sorted by
#       edge id, followed by the adjacent node records (the distinct other-end
#       nodes, excluding <nodeId> itself) sorted by node id. Records are emitted
#       verbatim (canonical JSONL) so each carries its `kind` (node|edge). An
#       unknown node id yields an empty result with a zero exit.
#   gluerun_graph_query_lineage <graphDir> <startNodeId>
#       Print the provenance lineage reachable from <startNodeId> by following the
#       provenance-edge taxonomy (implements / derived_from / revises / critiques /
#       accepts_observation / rejects_observation / verifies) as an undirected
#       reachability walk — the task -> attempt -> plan-version -> critique ->
#       finding -> disposition chain regardless of each edge's stored direction.
#       Emits the node record for every reachable node present in the corpus,
#       sorted by node id, with a visited-set guard so cycles terminate.
#   gluerun_graph_query_open_contradictions <graphDir>
#       Print exactly the `contradicts`/`invalidates` edge records whose
#       contradicted/invalidated node (the edge's `to`) is NOT resolved by any
#       `supersedes` edge (i.e. no `supersedes` edge targets that node), sorted by
#       edge id. A contradiction whose target has been superseded is excluded.

# --- shared corpus reader ----------------------------------------------------
# The three query modes differ only in the projection they compute over the same
# two corpus files; each is a small self-contained python3 reader that opens
# nodes.jsonl + edges.jsonl read-only (missing files -> empty streams) and prints
# the deterministic result. No function writes any path.

# gluerun_graph_query_neighbors <graphDir> <nodeId>
gluerun_graph_query_neighbors() {
  local graph_dir="${1:-${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}}"
  local node_id="${2:-}"
  GLUERUN_GQ_DIR="$graph_dir" GLUERUN_GQ_NODE="$node_id" python3 -c '
import json, os

graph_dir = os.environ["GLUERUN_GQ_DIR"]
target = os.environ["GLUERUN_GQ_NODE"]

def read_lines(name):
    path = os.path.join(graph_dir, name)
    try:
        with open(path, encoding="utf-8") as fh:
            return [ln.rstrip("\n") for ln in fh if ln.strip()]
    except FileNotFoundError:
        return []

edge_lines = read_lines("edges.jsonl")
node_lines = read_lines("nodes.jsonl")

nodes_by_id = {}
for ln in node_lines:
    nodes_by_id[json.loads(ln)["id"]] = ln

incident = []      # (edge id, verbatim line)
adjacent = set()   # distinct other-end node ids
for ln in edge_lines:
    e = json.loads(ln)
    if e.get("from") == target or e.get("to") == target:
        incident.append((e["id"], ln))
        for side in ("from", "to"):
            v = e.get(side)
            if v is not None and v != target:
                adjacent.add(v)

for _id, ln in sorted(incident, key=lambda t: t[0]):
    print(ln)
for nid in sorted(adjacent):
    if nid in nodes_by_id:
        print(nodes_by_id[nid])
'
}

# gluerun_graph_query_lineage <graphDir> <startNodeId>
gluerun_graph_query_lineage() {
  local graph_dir="${1:-${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}}"
  local start="${2:-}"
  GLUERUN_GQ_DIR="$graph_dir" GLUERUN_GQ_START="$start" python3 -c '
import json, os
from collections import deque

graph_dir = os.environ["GLUERUN_GQ_DIR"]
start = os.environ["GLUERUN_GQ_START"]

# The general provenance-edge taxonomy (context-graph.v0). The lineage walk is
# defined over these relations, not the subset today’s mappers emit.
PROVENANCE = {
    "implements",
    "derived_from",
    "revises",
    "critiques",
    "accepts_observation",
    "rejects_observation",
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
node_lines = read_lines("nodes.jsonl")

nodes_by_id = {}
for ln in node_lines:
    nodes_by_id[json.loads(ln)["id"]] = ln

# Undirected adjacency over the provenance subgraph: lineage follows the chain
# regardless of each edge’s stored direction.
adj = {}
for ln in edge_lines:
    e = json.loads(ln)
    if e.get("type") in PROVENANCE:
        a, b = e.get("from"), e.get("to")
        adj.setdefault(a, set()).add(b)
        adj.setdefault(b, set()).add(a)

# BFS with a visited-set guard so cycles terminate.
visited = {start}
queue = deque([start])
while queue:
    cur = queue.popleft()
    for nb in adj.get(cur, ()):
        if nb not in visited:
            visited.add(nb)
            queue.append(nb)

for nid in sorted(visited):
    if nid in nodes_by_id:
        print(nodes_by_id[nid])
'
}

# gluerun_graph_query_open_contradictions <graphDir>
gluerun_graph_query_open_contradictions() {
  local graph_dir="${1:-${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}}"
  GLUERUN_GQ_DIR="$graph_dir" python3 -c '
import json, os

graph_dir = os.environ["GLUERUN_GQ_DIR"]

CONTRADICTION = {"contradicts", "invalidates"}

def read_lines(name):
    path = os.path.join(graph_dir, name)
    try:
        with open(path, encoding="utf-8") as fh:
            return [ln.rstrip("\n") for ln in fh if ln.strip()]
    except FileNotFoundError:
        return []

edge_lines = read_lines("edges.jsonl")
edges = [(ln, json.loads(ln)) for ln in edge_lines]

# Nodes whose contradiction/invalidation is resolved: some `supersedes` edge
# targets them (the contradicted/invalidated node has been superseded).
superseded = {e.get("to") for _ln, e in edges if e.get("type") == "supersedes"}

open_edges = [
    (e["id"], ln)
    for ln, e in edges
    if e.get("type") in CONTRADICTION and e.get("to") not in superseded
]
for _id, ln in sorted(open_edges, key=lambda t: t[0]):
    print(ln)
'
}
