#!/usr/bin/env bash
# ctx-experiment-pipeline.sh — read-only END-TO-END entry for the `experiment-run`
# executable DAG node (layer evaluation). This brick ships NO metric of its own:
# it is the single explicit-corpus operator entry that composes the two already
# integrated capstones — it DELEGATES to gluerun_ctx_experiment_summary_json to
# build the raw-metrics bundle from explicit corpus paths, then to
# gluerun_ctx_experiment_render_md to render that in-memory bundle into the full
# report-metrics markdown tables the operator drops into experiment-report.md (the
# exit gate requires the report merged with raw metrics artifacts referenced).
#
# The five per-family bricks each render/aggregate one slice and are unit-tested
# in isolation; the render capstone accepts a pre-built bundle source or env
# defaults, not positional runs/events args. This entry closes that gap: it takes
# explicit runs/events/metrics corpus paths and walks them all the way to the
# rendered tables in one call.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines a NEW
# function only; NO existing engine path invokes it, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# intrinsic, mirroring the sibling engine/ctx-experiment-*.sh idiom). It does NOT
# edit the five sibling ctx-experiment-*.sh files, engine/ctx-metrics.sh, or any
# other pre-existing file.
#
# STRICTLY READ-ONLY / STDOUT-ONLY: it reads the corpus ONLY THROUGH the two
# capstones (which themselves read only the runs directory, events log, and
# optional per-task metrics file), threads the bundle to the renderer through the
# renderer's in-memory bundle source (stdin), and writes NO temp file. It computes
# no metric, reclassifies nothing, and creates, moves, or mutates NOTHING — no run
# artifact, index, event, lease, or task file, and never
# docs/context-build-plan/experiment-report.md. Because delegation is verbatim and
# loss-preserving, the emitted markdown is byte-identical to feeding the same
# corpus through gluerun_ctx_experiment_summary_json and
# gluerun_ctx_experiment_render_md directly. This is measurement code the
# operator's experiment-report.md references at merge; it neither declares nor
# gates node completion.
#
# Fail-safe: an empty corpus (no runs, empty events) yields well-formed ZEROED
# tables and a zero exit, never an error or partial output (each capstone is
# itself fail-safe).
#
# Public entry point:
#   gluerun_ctx_experiment_pipeline_md [runs_dir] [events_file] [metrics_file]
#     Builds the bundle via gluerun_ctx_experiment_summary_json over the explicit
#     corpus paths, renders it via gluerun_ctx_experiment_render_md (fed the
#     in-memory bundle on stdin, no file written), and emits ONE deterministic
#     report-metrics markdown fragment to stdout. Defaults:
#     runs_dir=$GLUERUN_RUNS_DIR, events_file=$GLUERUN_EVENTS_FILE,
#     metrics_file=$GLUERUN_CTX_EXPERIMENT_METRICS_FILE.

# Explicit-corpus end-to-end pipeline. Delegates bundle build then render; threads
# the bundle in memory. Fail-safe / always exit 0.
gluerun_ctx_experiment_pipeline_md() {
  local runs_dir="${1:-${GLUERUN_RUNS_DIR:-}}"
  local events_file="${2:-${GLUERUN_EVENTS_FILE:-}}"
  local metrics_file="${3:-${GLUERUN_CTX_EXPERIMENT_METRICS_FILE:-}}"

  # 1. Thread the explicit corpus through the summary capstone to obtain the
  #    raw-metrics bundle (itself fail-safe on missing/empty inputs).
  local bundle
  bundle="$(gluerun_ctx_experiment_summary_json "$runs_dir" "$events_file" "$metrics_file")"

  # 2. Render the in-memory bundle through the render capstone via its stdin
  #    ("-") bundle source. No temp file is written; the bundle never touches disk.
  printf '%s' "$bundle" | gluerun_ctx_experiment_render_md -
  return 0
}
