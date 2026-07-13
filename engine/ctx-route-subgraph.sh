#!/usr/bin/env bash
# ctx-route-subgraph.sh — the flat-vs-subgraph manifest SELECTOR for the route
# spine's refused-resume rehydrate step (executable DAG node `subgraph-rehydrate`,
# stage S6-graph, layer engine_runtime). This is the wire-in that finally makes
# the integrated subgraph toolchain reachable from the route: the arm decider
# (gluerun_ctx_rehydrate_subgraph_arm_mode, TASK-0104), the identity primitives
# (gluerun_graph_identity / gluerun_graph_node_id, engine/ctx-graph*.sh), and the
# order-preserving assembler (gluerun_ctx_rehydrate_subgraph_assemble, TASK-0102)
# all EXIST and are integrated; nothing yet CHOSE them. This file adds the single
# selector _gluerun_ctx_route_refuse_resume now delegates to.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines a new
# function ONLY. The selector COMPOSES the pieces above and re-uses the existing
# flat composition verbatim on the OFF path, so with GLUERUN_CTX_SUBGRAPH_REHYDRATE
# at its default (0) it returns the FLAT manifest and the route stays byte-
# identical to today. The subgraph branch is reachable only with the knob on, the
# treatment arm, and a present, non-empty graph corpus — exactly the conditions
# the arm decider re-checks, so this selector does NOT duplicate them.
#
# Evidence invariance / advocate-skeptic line: this only chooses WHICH manifest
# the existing decision leaf (gluerun_ctx_route_rehydrate_decide) sees. It is a
# PURE READ — appends no events, writes/renames/deletes nothing, confers NO
# independence, and never exits non-zero; the `rehydrate` strategy stays tainted
# per gluerun_ctx_route_strategy_tainted regardless of which manifest is chosen.
#
# Public function:
#   gluerun_ctx_route_subgraph_manifest <reason> <role> <step> <meta> <key>
#     Prints the rehydration manifest for the route's decision leaf.
#       - When GLUERUN_CTX_SUBGRAPH_REHYDRATE=1 AND
#         gluerun_ctx_rehydrate_subgraph_arm_mode <key> <graphDir> == subgraph,
#         resolve the task node id as
#           gluerun_graph_node_id( gluerun_graph_identity task <key> )
#         and print the contradictions-first subgraph manifest via
#           gluerun_ctx_rehydrate_subgraph_assemble <graphDir> <node> manifest.
#         graphDir defaults to ${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}.
#       - Otherwise print the FLAT manifest, BYTE-IDENTICAL to the legacy
#         composition: gluerun_ctx_rehydrate_sources over run_dir = dirname(meta),
#         piped into gluerun_ctx_rehydrate_manifest.
#     <reason>/<role>/<step> are accepted for call-site symmetry with the decision
#     leaf; the manifest choice keys only on <meta> and <key>.
gluerun_ctx_route_subgraph_manifest() {
  local reason="$1" role="$2" step="$3" meta="$4" key="$5"

  local graph_dir="${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}"

  # Subgraph branch: only behind the dedicated knob AND the integrated arm
  # decider's `subgraph` verdict (which itself re-checks the knob, the treatment
  # arm, and a present non-empty corpus — do NOT duplicate those conditions).
  if [[ "${GLUERUN_CTX_SUBGRAPH_REHYDRATE:-0}" == "1" ]] \
     && [[ "$(gluerun_ctx_rehydrate_subgraph_arm_mode "$key" "$graph_dir")" == "subgraph" ]]; then
    # Deterministic task node id from the integrated identity primitives, so the
    # selected node agrees with every other graph mapper.
    local node
    node="$(gluerun_graph_node_id "$(gluerun_graph_identity task "$key")")"
    gluerun_ctx_rehydrate_subgraph_assemble "$graph_dir" "$node" manifest
    return 0
  fi

  # FLAT branch: byte-identical to the legacy composition the route used before
  # this wire-in — resolve durable sources over the run_dir and render a manifest.
  local run_dir; run_dir="$(dirname "$meta")"
  local -a specs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && specs+=("$line")
  done < <(gluerun_ctx_rehydrate_sources "$run_dir")

  gluerun_ctx_rehydrate_manifest ${specs[@]+"${specs[@]}"}
  return 0
}

# gluerun_ctx_route_subgraph_render <task_id> <packet|manifest>
#   The SHARED subgraph selector both the l1-drive.sh packet-injection site and the
#   ctx-rehydrate-event.sh manifest-record site key on, so the injected packet and
#   the recorded manifest carry the SAME subgraph sources BY CONSTRUCTION: both
#   pass the SAME task_id, the same arm-mode decider re-checks the same knob /
#   treatment arm / present non-empty corpus, and the SAME deterministic node id is
#   resolved.
#
#   When gluerun_ctx_rehydrate_subgraph_arm_mode <task_id> <graphDir> == subgraph
#   (graphDir = ${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}), resolve
#     node = gluerun_graph_node_id( gluerun_graph_identity task <task_id> )
#   and print gluerun_ctx_rehydrate_subgraph_assemble <graphDir> <node> <mode>,
#   returning 0. Otherwise print NOTHING and return non-zero, signalling the caller
#   to keep its existing FLAT composition. <mode> is `packet` or `manifest`.
#
#   Feature-flag discipline: the arm decider defaults GLUERUN_CTX_SUBGRAPH_REHYDRATE
#   OFF, so this always returns non-zero/empty by default and both sites use the
#   flat path — byte-identical to today. The subgraph branch is reachable only with
#   the knob on, the treatment arm, and a present non-empty corpus (all re-checked
#   by the arm decider — do NOT duplicate those conditions here).
#
#   Evidence invariance: a PURE READ — appends no events, writes/renames/deletes
#   nothing, confers NO independence; the `rehydrate` strategy stays tainted per
#   gluerun_ctx_route_strategy_tainted regardless of which path is chosen.
gluerun_ctx_route_subgraph_render() {
  local task_id="$1" mode="$2"

  local graph_dir="${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}"
  [[ "$(gluerun_ctx_rehydrate_subgraph_arm_mode "$task_id" "$graph_dir")" == "subgraph" ]] \
    || return 1

  local node
  node="$(gluerun_graph_node_id "$(gluerun_graph_identity task "$task_id")")"
  gluerun_ctx_rehydrate_subgraph_assemble "$graph_dir" "$node" "$mode"
  return 0
}
