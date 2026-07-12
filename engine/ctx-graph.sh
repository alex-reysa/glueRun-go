#!/usr/bin/env bash
# ctx-graph.sh — deterministic pure-projection primitives for the context
# provenance graph (schemas/context-graph.v0.schema.json).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions ONLY; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior
# (OFF-parity when GLUERUN_CTX_GRAPH is unset or 0). Nothing here writes to the
# filesystem: the emitters print a single JSONL line to stdout and touch no file.
#
# These are the atoms every later graph-projector capability
# (gluerun graph rebuild/sync/query, behind GLUERUN_CTX_GRAPH, default 0)
# composes. Pure and deterministic: identical input yields byte-identical
# output; distinct source identities yield distinct ids.
#
# Public functions:
#   gluerun_graph_content_hash <content>
#       -> sha256:<64-hex> of the source record's canonical content.
#   gluerun_graph_node_id <identity>
#       -> n-<12-hex> stable id for a source-record identity string.
#   gluerun_graph_edge_id <fromId> <edgeType> <toId>
#       -> e-<12-hex> stable id for the directed identity triple.
#   gluerun_graph_emit_node <type> <identity> <sourcePath> <content> [label] [attributesJson]
#       -> one nodes.jsonl line valid vs the schema. evidenceClass is fail-closed:
#          authoritative ONLY for the host-verified types (commit, gate-result);
#          claim for every other type (including audit — the auditor is a model).
#   gluerun_graph_emit_edge <edgeType> <fromId> <toId> <sourcePath> <content> [attributesJson]
#       -> one edges.jsonl line valid vs the schema, id = edge_id(from,type,to),
#          directed from -> to.

# --- Slice 1: deterministic identity primitives ------------------------------

# Hash the exact bytes of the argument (no trailing newline) so identical content
# always maps to the same digest, independent of shell quoting.
_gluerun_graph_sha256() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

gluerun_graph_content_hash() {
  printf 'sha256:%s' "$(_gluerun_graph_sha256 "$1")"
}

gluerun_graph_node_id() {
  local h
  h="$(_gluerun_graph_sha256 "$1")"
  printf 'n-%s' "${h:0:12}"
}

gluerun_graph_edge_id() {
  # Canonical identity triple joined with US (0x1f) — a byte that cannot appear
  # in a node id or edge-type token, so the join is unambiguous and
  # direction-sensitive.
  local h
  h="$(_gluerun_graph_sha256 "$(printf '%s\037%s\037%s' "$1" "$2" "$3")")"
  printf 'e-%s' "${h:0:12}"
}

# --- Slices 2 & 3: pure-stdout JSONL emitters --------------------------------

gluerun_graph_emit_node() {
  local ntype="$1" identity="$2" source_path="$3" content="$4"
  local label="${5:-}" attributes="${6:-}"
  local ev
  case "$ntype" in
    commit|gate-result) ev="authoritative" ;;   # host-verified records only
    *)                  ev="claim" ;;            # every model-authored type
  esac
  GLUERUN_G_KIND="node" \
  GLUERUN_G_ID="$(gluerun_graph_node_id "$identity")" \
  GLUERUN_G_TYPE="$ntype" \
  GLUERUN_G_EV="$ev" \
  GLUERUN_G_SP="$source_path" \
  GLUERUN_G_CH="$(gluerun_graph_content_hash "$content")" \
  GLUERUN_G_LABEL="$label" \
  GLUERUN_G_ATTR="$attributes" \
  python3 -c '
import json, os
o = {
    "schema": "gluerun.orchestration.context-graph.v0",
    "kind": "node",
    "id": os.environ["GLUERUN_G_ID"],
    "type": os.environ["GLUERUN_G_TYPE"],
    "evidenceClass": os.environ["GLUERUN_G_EV"],
    "provenance": {
        "sourcePath": os.environ["GLUERUN_G_SP"],
        "contentHash": os.environ["GLUERUN_G_CH"],
    },
}
label = os.environ.get("GLUERUN_G_LABEL", "")
if label:
    o["label"] = label
attr = os.environ.get("GLUERUN_G_ATTR", "")
if attr:
    o["attributes"] = json.loads(attr)
print(json.dumps(o, separators=(",", ":"), sort_keys=True))
'
}

gluerun_graph_emit_edge() {
  local etype="$1" from_id="$2" to_id="$3" source_path="$4" content="$5"
  local attributes="${6:-}"
  GLUERUN_G_ID="$(gluerun_graph_edge_id "$from_id" "$etype" "$to_id")" \
  GLUERUN_G_TYPE="$etype" \
  GLUERUN_G_FROM="$from_id" \
  GLUERUN_G_TO="$to_id" \
  GLUERUN_G_SP="$source_path" \
  GLUERUN_G_CH="$(gluerun_graph_content_hash "$content")" \
  GLUERUN_G_ATTR="$attributes" \
  python3 -c '
import json, os
o = {
    "schema": "gluerun.orchestration.context-graph.v0",
    "kind": "edge",
    "id": os.environ["GLUERUN_G_ID"],
    "type": os.environ["GLUERUN_G_TYPE"],
    "from": os.environ["GLUERUN_G_FROM"],
    "to": os.environ["GLUERUN_G_TO"],
    "provenance": {
        "sourcePath": os.environ["GLUERUN_G_SP"],
        "contentHash": os.environ["GLUERUN_G_CH"],
    },
}
attr = os.environ.get("GLUERUN_G_ATTR", "")
if attr:
    o["attributes"] = json.loads(attr)
print(json.dumps(o, separators=(",", ":"), sort_keys=True))
'
}
