#!/usr/bin/env bash
# ctx-graph-project.sh — first source-record projection mappers for the context
# provenance graph (schemas/context-graph.v0.schema.json).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions ONLY; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior
# (OFF-parity when SINGULAR_CTX_GRAPH is unset or 0). The mappers write NO file:
# each prints a mixed node+edge JSONL stream to stdout (one schema-valid line
# each; every line self-identifies via `kind`).
#
# These compose the integrated primitives — the slice-1 identity convention here
# plus engine/ctx-graph.sh's singular_graph_node_id / singular_graph_emit_node /
# singular_graph_emit_edge — into the graph-projector's inner layer. A later
# `singular graph rebuild` entry point (behind SINGULAR_CTX_GRAPH, default 0)
# partitions the stream by `kind` and hands the node/edge streams to the
# integrated corpus writer singular_graph_write_corpus (engine/ctx-graph-corpus.sh).
#
# Public functions:
#   singular_graph_identity <type> <key...>
#       -> canonical source-record identity STRING for a node type. Pure and
#          deterministic: identical inputs yield byte-identical strings; distinct
#          source records (including distinct types) yield distinct strings. This
#          is the keystone every mapper reuses so ids minted via
#          singular_graph_node_id(identity) AGREE across mappers and cross-family
#          edges connect (e.g. an attempt `implements` the same `task` node a
#          gate-result `verifies`).
#   singular_graph_project_attempts <attemptsIndexPath>
#       -> reads an attempts/index.json (singular.orchestration.attempts-index.v0:
#          runId, taskId, attempts[] rows keyed by n) and emits one `attempt`
#          node (evidenceClass claim) per row plus one `implements` edge from
#          each attempt node to its task node id.
#   singular_graph_project_gate_results <gateRecordPath>
#       -> reads a singular.orchestration.gate-result.v0 record and emits one
#          `gate-result` node (evidenceClass authoritative — the source is a
#          host-verified record) for every status, plus a `verifies` edge on
#          status `passed` and an `invalidates` edge on status `failed` from the
#          gate-result node to the decided target's node id.

# --- Slice 1: identity convention --------------------------------------------

# Build the canonical identity STRING for a source-record node type: the type
# token followed by its key parts, joined with US (0x1f) — the same separator
# byte singular_graph_edge_id uses, chosen because it cannot appear in these
# tokens, so the join is unambiguous and the identity is collision-free across
# types. Pure and deterministic.
singular_graph_identity() {
  local ntype="$1"; shift
  local out="$ntype" part
  for part in "$@"; do
    out+=$'\037'"$part"
  done
  printf '%s' "$out"
}

# --- Slice 2: attempts mapper ------------------------------------------------

# Emit one `attempt` node + one `implements` edge (attempt -> task) per attempts
# index row. Deterministic and idempotent: the same source emits byte-identical
# lines. Pure stdout — writes no file.
singular_graph_project_attempts() {
  local index_path="$1"
  local run_id task_id
  run_id="$(SINGULAR_GP_PATH="$index_path" python3 -c '
import json, os
d = json.load(open(os.environ["SINGULAR_GP_PATH"]))
print(d["runId"])' )" || return 1
  task_id="$(SINGULAR_GP_PATH="$index_path" python3 -c '
import json, os
d = json.load(open(os.environ["SINGULAR_GP_PATH"]))
print(d["taskId"])' )" || return 1

  local task_node
  task_node="$(singular_graph_node_id "$(singular_graph_identity task "$task_id")")"

  local n content_b64 content attempt_ident attempt_node
  while IFS=$'\t' read -r n content_b64; do
    [[ -n "$n" ]] || continue
    content="$(printf '%s' "$content_b64" | base64 --decode)"
    attempt_ident="$(singular_graph_identity attempt "$run_id" "$n")"
    attempt_node="$(singular_graph_node_id "$attempt_ident")"
    singular_graph_emit_node attempt "$attempt_ident" "$index_path" "$content"
    singular_graph_emit_edge implements "$attempt_node" "$task_node" "$index_path" "$content"
  done < <(SINGULAR_GP_PATH="$index_path" python3 -c '
import json, os, base64
d = json.load(open(os.environ["SINGULAR_GP_PATH"]))
for row in d.get("attempts", []):
    content = json.dumps(row, sort_keys=True, separators=(",", ":"))
    b = base64.b64encode(content.encode()).decode()
    print(str(row["n"]) + "\t" + b)
')
}

# --- Slice 3: gate-result mapper ---------------------------------------------

# Emit one `gate-result` node (authoritative — host-verified source) for every
# status, plus a `verifies` edge on `passed` and an `invalidates` edge on
# `failed`, from the gate-result node to the decided target's node id. `proposed`
# and `blocked` emit the node with no verify/invalidate edge. Deterministic and
# idempotent; pure stdout — writes no file.
singular_graph_project_gate_results() {
  local record_path="$1"
  local node gate_status decided_by recorded_at content_b64
  # Newline-delimited fields; the base64 content is a single line (no newlines).
  { read -r node
    read -r gate_status
    read -r decided_by
    read -r recorded_at
    read -r content_b64
  } < <(SINGULAR_GP_PATH="$record_path" python3 -c '
import json, os, base64
d = json.load(open(os.environ["SINGULAR_GP_PATH"]))
content = json.dumps(d, sort_keys=True, separators=(",", ":"))
print(d["node"])
print(d["status"])
print(d.get("decidedBy", ""))
print(d.get("recordedAt", ""))
print(base64.b64encode(content.encode()).decode())
') || return 1

  local content
  content="$(printf '%s' "$content_b64" | base64 --decode)"

  local gate_ident gate_node target_node
  gate_ident="$(singular_graph_identity gate-result "$node" "$decided_by" "$recorded_at")"
  gate_node="$(singular_graph_node_id "$gate_ident")"
  target_node="$(singular_graph_node_id "$(singular_graph_identity task "$node")")"

  singular_graph_emit_node gate-result "$gate_ident" "$record_path" "$content"
  case "$gate_status" in
    passed|passed-with-acknowledged-baseline)
      singular_graph_emit_edge verifies "$gate_node" "$target_node" "$record_path" "$content"
      ;;
    failed) singular_graph_emit_edge invalidates "$gate_node" "$target_node" "$record_path" "$content" ;;
  esac
}
