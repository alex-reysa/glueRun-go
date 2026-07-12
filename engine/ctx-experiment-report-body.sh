#!/usr/bin/env bash
# ctx-experiment-report-body.sh — read-only PRESENTATION CAPSTONE for the
# `experiment-run` executable DAG node (layer evaluation). Two corpus renderers
# are already integrated — gluerun_ctx_experiment_pipeline_md (TASK-0087: the
# per-arm escape/cost/bias, strategy, and attempts tables) and
# gluerun_ctx_experiment_render_result_md (TASK-0098: the treatment-effect delta
# and arm-integrity audit tables) — but to author experiment-report.md the
# operator must invoke BOTH separately and hand-order/concatenate their output.
# This brick composes them into ONE ordered report-body markdown the operator
# pipes into the report, in one command.
#
# It ships NO metric of its own: it only ORDERS and CONCATENATES the two rendered
# fragments VERBATIM (no recomputation, no reformatting of their table content)
# under stable section headers, and emits markdown to STDOUT ONLY. It composes the
# two integrated corpus renderers over the SAME resolved corpus args.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# intrinsic, mirroring the sibling engine/ctx-experiment-*.sh idiom). It does NOT
# edit the sibling ctx-experiment-*.sh renderers, cli/gluerun, or any other
# pre-existing file.
#
# STRICTLY STDOUT-ONLY / READ-ONLY: it reads the corpus ONLY THROUGH the two
# integrated renderers and creates, moves, or mutates NOTHING — no run artifact,
# index, event, lease, or task file, and never writes
# docs/context-build-plan/experiment-report.md (an operator-owned concept). It
# neither declares nor gates node completion, never runs the paired-audited A/B
# experiment, and records no per-knob default decisions (all operator authority).
#
# It produces METRICS TABLES ONLY — no experiment narrative, no bias
# interpretation, no per-knob default decisions. Evidence invariance /
# advocate-skeptic line preserved: it only orders and concatenates measured
# tables and reclassifies nothing.
#
# Fail-safe: an empty corpus renders a well-formed body with zeroed tables and a
# zero exit, never an error or partial output (each delegated renderer is itself
# fail-safe).
#
# Two chained slices (all here):
#   1. gluerun_ctx_experiment_report_body_compose <pipeline_md> <result_md>
#      — assemble the two rendered fragments under stable section headers in a
#        fixed order (per-arm metrics first, then treatment-effect + arm-integrity),
#        preserving each fragment's content verbatim.
#   2. gluerun_ctx_experiment_report_body_md [runs_dir] [events_file] [metrics_file]
#      — obtain both fragments by delegating to gluerun_ctx_experiment_pipeline_md
#        and gluerun_ctx_experiment_render_result_md over the SAME resolved corpus
#        args, compose them via the helper, and emit the complete body to stdout.

# --- Slice 1: section-composition helper -------------------------------------
# Assemble the two already-rendered fragments under stable section headers in a
# fixed order: the per-arm metrics fragment first, then the treatment-effect /
# arm-integrity fragment. Each fragment's content is preserved VERBATIM (only
# ordered and concatenated); nothing is recomputed or reformatted.
gluerun_ctx_experiment_report_body_compose() {
  local pipeline_md="${1-}"
  local result_md="${2-}"

  printf '# Experiment report body\n\n'
  printf '## Per-arm metrics\n\n'
  printf '%s\n' "$pipeline_md"
  printf '\n'
  printf '## Treatment effect and arm integrity\n\n'
  printf '%s\n' "$result_md"
  return 0
}

# --- Slice 2: composed public entry ------------------------------------------
# Obtain both rendered fragments by delegating to the two integrated corpus
# renderers over the SAME resolved corpus args (threaded verbatim so each renderer
# performs its own resolution / env-default fallback), compose them via the
# helper, and emit the complete report body to stdout. Deterministic; fail-safe /
# always exit 0.
gluerun_ctx_experiment_report_body_md() {
  local runs_dir="${1-}"
  local events_file="${2-}"
  local metrics_file="${3-}"
  local pipeline_md result_md

  # The per-arm metrics fragment (escape/cost/bias, strategy, attempts tables).
  pipeline_md="$(gluerun_ctx_experiment_pipeline_md "$runs_dir" "$events_file" "$metrics_file")"
  # The treatment-effect delta + arm-integrity audit fragment.
  result_md="$(gluerun_ctx_experiment_render_result_md "$runs_dir" "$events_file" "$metrics_file")"

  gluerun_ctx_experiment_report_body_compose "$pipeline_md" "$result_md"
  return 0
}
