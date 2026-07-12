#!/usr/bin/env bash
# ctx-graph-corpus.sh — deterministic corpus assembler for the context
# provenance graph (schemas/context-graph.v0.schema.json).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions ONLY; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior
# (OFF-parity when GLUERUN_CTX_GRAPH is unset or 0). The writer touches only the
# explicitly-provided <graphdir> and no other path.
#
# This is the determinism/idempotence keystone every later graph-projector
# capability (gluerun graph rebuild/sync, behind GLUERUN_CTX_GRAPH, default 0)
# funnels through: it turns the stream of projected JSONL lines emitted by
# engine/ctx-graph.sh's gluerun_graph_emit_node / gluerun_graph_emit_edge into
# the on-disk append-only corpus <graphdir>/nodes.jsonl + <graphdir>/edges.jsonl,
# so equal source sets yield a byte-identical graph.
#
# Public functions:
#   gluerun_graph_canonicalize
#       Read projected JSONL lines on stdin; print them deduplicated by `id`
#       (duplicate-id lines collapse to a single deterministic representative)
#       and sorted by `id` ascending. Pure stdin->stdout and permutation-
#       independent: any input ordering of the same line set yields byte-
#       identical output. This is what makes the projector deterministic and
#       idempotent.
#   gluerun_graph_write_corpus <graphdir> <nodesInput> <edgesInput>
#       Run each input stream through gluerun_graph_canonicalize and write
#       <graphdir>/nodes.jsonl and <graphdir>/edges.jsonl, first clearing any
#       prior graph files so no stale line survives a rebuild. <graphdir>
#       defaults to ${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph} when not
#       supplied. Idempotent: writing twice, or deleting <graphdir> and writing
#       again, reproduces a byte-identical corpus.

# --- Slice 1: canonicalizer --------------------------------------------------

# Dedup by `id`, sort by `id` ascending. Among lines sharing an id, keep the
# lexicographically smallest full line so the survivor is deterministic and
# independent of input ordering (identical lines trivially collapse to one).
# Blank/whitespace-only lines carry no record and are dropped; every surviving
# line is emitted verbatim.
gluerun_graph_canonicalize() {
  python3 -c '
import json, sys
best = {}
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        continue
    key = json.loads(line)["id"]
    if key not in best or line < best[key]:
        best[key] = line
for key in sorted(best):
    print(best[key])
'
}

# --- Slice 2: loss-free corpus writer ----------------------------------------

# Write <graphdir>/nodes.jsonl and <graphdir>/edges.jsonl from the two input
# streams, each run through gluerun_graph_canonicalize. Prior graph files are
# removed first so no stale line survives a rebuild; the corpus is deletable and
# rebuildable loss-free (equal inputs -> byte-identical corpus). Missing input
# paths are treated as empty streams.
gluerun_graph_write_corpus() {
  local graphdir="${1:-}" nodes_in="${2:-}" edges_in="${3:-}"
  [[ -n "$graphdir" ]] || graphdir="${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}"
  [[ -n "$nodes_in" && -e "$nodes_in" ]] || nodes_in=/dev/null
  [[ -n "$edges_in" && -e "$edges_in" ]] || edges_in=/dev/null

  mkdir -p "$graphdir" || return 1
  # Clear prior graph files so no stale line survives the rewrite.
  rm -f "$graphdir/nodes.jsonl" "$graphdir/edges.jsonl"

  gluerun_graph_canonicalize < "$nodes_in" > "$graphdir/nodes.jsonl" || return 1
  gluerun_graph_canonicalize < "$edges_in" > "$graphdir/edges.jsonl" || return 1
}
