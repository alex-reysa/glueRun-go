#!/usr/bin/env bash
# ctx-rehydrate-subgraph-arm.sh — the per-arm rehydration-MODE decider for the
# executable DAG node `subgraph-rehydrate` (stage S6-graph, layer engine_runtime).
# The subgraph toolchain is fully integrated — selection
# (singular_ctx_rehydrate_subgraph_select), resolution
# (singular_ctx_rehydrate_subgraph_sources), and the order-preserving assembler
# (singular_ctx_rehydrate_subgraph_assemble) — but nothing yet CHOOSES it per arm;
# flat is still the only rehydration mode any call site selects. This file adds
# the single deterministic decision leaf that a later ctx-route.sh selection and
# l1-drive.sh subgraph-packet injection will consult to swap the flat assembler
# for the subgraph assembler on the treatment arm. Those wire-ins touch existing
# driver files and are SEPARATE later tasks, OUT OF SCOPE here.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines a new
# function ONLY; NO existing engine/CLI/driver path invokes it and the knob
# defaults OFF, so with this file present-but-uncalled the engine is
# byte-identical to prior behavior and the decider returns `flat` for every id
# (OFF-parity: today flat is the only rehydration mode).
#
# Knob: SINGULAR_CTX_SUBGRAPH_REHYDRATE (default 0). Only "1" can enable subgraph
# mode; any other value (unset, 0, junk) keeps every id on flat.
#
# Evidence invariance / advocate-skeptic line: the decider is a PURE READ — it
# chooses a rendering mode only. It appends no events, writes/renames/deletes
# nothing, confers NO independence, and does not alter taint; the `rehydrate`
# strategy stays tainted per singular_ctx_route_strategy_tainted regardless of
# which mode is chosen.
#
# Public function:
#   singular_ctx_rehydrate_subgraph_arm_mode <task_id> [graphDir]
#     Prints exactly `subgraph` or `flat`. Selects `subgraph` ONLY when ALL
#     fail-closed conditions hold, else `flat`:
#       (1) SINGULAR_CTX_SUBGRAPH_REHYDRATE=1 (the dedicated feature knob);
#       (2) the task's deterministic A/B arm — via the integrated
#           singular_ctx_ab_arm_for (engine/ctx-ab.sh) — is the designated
#           TREATMENT arm B (control arm A stays flat), so a given id yields the
#           same mode across processes and machines;
#       (3) the graph corpus at graphDir (default
#           ${SINGULAR_CTX_GRAPH_DIR:-.singular-state/graph}) exists and is
#           non-empty — a present, non-empty <graphDir>/nodes.jsonl — so
#           singular_ctx_rehydrate_subgraph_assemble could actually render a
#           packet.
#     Any failing precondition yields `flat`.

singular_ctx_rehydrate_subgraph_arm_mode() {
  # The designated treatment arm. singular_ctx_ab_arm_for maps each id to {A,B};
  # by the integrated convention A is control (stays flat) and B is treatment.
  local treatment_arm="B"
  local task_id="$1"
  local graph_dir="${2:-${SINGULAR_CTX_GRAPH_DIR:-.singular-state/graph}}"

  # (1) Feature knob. Default OFF; only an explicit "1" can enable subgraph mode.
  if [[ "${SINGULAR_CTX_SUBGRAPH_REHYDRATE:-0}" != "1" ]]; then
    printf 'flat\n'
    return 0
  fi

  # (2) Deterministic per-task arm. Control arm A stays flat. Compose the
  # integrated assignment reader — a pure, machine-independent content hash — so
  # a given id yields the same mode across processes and machines.
  if [[ "$(singular_ctx_ab_arm_for "$task_id")" != "$treatment_arm" ]]; then
    printf 'flat\n'
    return 0
  fi

  # (3) Fail-closed on the corpus: the graph dir must exist and carry a
  # non-empty nodes.jsonl, so the subgraph assembler could actually render a
  # packet. A missing dir or an empty/absent corpus falls back to flat.
  if [[ ! -d "$graph_dir" || ! -s "$graph_dir/nodes.jsonl" ]]; then
    printf 'flat\n'
    return 0
  fi

  printf 'subgraph\n'
  return 0
}
