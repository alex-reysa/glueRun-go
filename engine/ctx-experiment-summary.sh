#!/usr/bin/env bash
# ctx-experiment-summary.sh — read-only CAPSTONE record-merge for the
# `experiment-run` executable DAG node (layer evaluation). This brick ships NO
# metric of its own: it DELEGATES to the three integrated per-family composers and
# nests their outputs VERBATIM into ONE referenceable raw-metrics bundle — the
# single merged artifact the operator's experiment-report.md points at (the exit
# gate requires the report merged with raw metrics artifacts referenced).
#
#   * engine/ctx-experiment-report.sh   — per-arm escape rate, cost rollup, bias
#   * engine/ctx-experiment-strategy.sh — resume/rehydrate hit rates + refusal mix
#   * engine/ctx-experiment-attempts.sh — per-arm attempts-to-accept + findings
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines a NEW
# function only; NO existing engine path invokes it, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# intrinsic, mirroring the sibling engine/ctx-experiment-*.sh idiom). It does NOT
# edit the three sibling aggregators, engine/ctx-metrics.sh, or any other
# pre-existing file.
#
# STRICTLY READ-ONLY: it reads ONLY the runs directory (attempts indexes), the
# events log (events.ndjson), and an optional precomputed ctx-metrics JSON, and it
# reads them ONLY THROUGH the three sibling composers — routing each input to the
# correct sub-composer per that function's EXISTING signature (the composers take
# DIFFERENT parameter lists). It computes no metric of its own and creates, moves,
# or mutates NOTHING — no run artifact, index, event, lease, or task file. This is
# measurement code the operator's experiment-report.md references at merge; it
# neither declares nor gates node completion.
#
# Merge semantics: assembles ONE deterministic sorted-key JSON object carrying a
# `schema` field and the three sub-artifacts nested VERBATIM under stable keys
# (report, strategy, attempts) — loss-preserving, so no nested value is dropped or
# reshaped. Because delegation is verbatim, the bundle only MEASURES; it confers
# no independence and reclassifies nothing (evidence invariance / advocate-skeptic
# line preserved).
#
# Fail-safe: when an input is missing or empty, each composer emits its own
# well-formed ZEROED sub-object, so the corresponding sub-object is present and
# zeroed rather than absent or an error, and the overall exit is zero.
#
# Public entry point:
#   gluerun_ctx_experiment_summary_json [runs_dir] [events_file] [metrics_file]
#     Emits ONE deterministic, sorted-key JSON object conforming to
#     gluerun.orchestration.ctx-experiment-summary.v0, nesting the report,
#     strategy, and attempts composer outputs verbatim. Defaults:
#     runs_dir=$GLUERUN_RUNS_DIR, events_file=$GLUERUN_EVENTS_FILE,
#     metrics_file=$GLUERUN_CTX_EXPERIMENT_METRICS_FILE.

# Composed capstone bundle. Delegates to the three integrated per-family composers
# and nests their JSON outputs verbatim. Fail-safe / always exit 0.
gluerun_ctx_experiment_summary_json() {
  local runs_dir="${1:-${GLUERUN_RUNS_DIR:-}}"
  local events_file="${2:-${GLUERUN_EVENTS_FILE:-}}"
  local metrics_file="${3:-${GLUERUN_CTX_EXPERIMENT_METRICS_FILE:-}}"

  # Route each input to the correct sub-composer per its EXISTING signature and
  # capture each composer's JSON output. Each composer is itself fail-safe.
  local report strategy attempts
  report="$(gluerun_ctx_experiment_report_json "$events_file" "$metrics_file")"
  strategy="$(gluerun_ctx_experiment_strategy_json "$events_file")"
  attempts="$(gluerun_ctx_experiment_attempts_json "$runs_dir" "$events_file")"

  # Merge + emit. Sub-artifacts pass through the environment (arbitrary JSON,
  # never re-parsed by the shell) and are nested verbatim under stable keys.
  GLUERUN_SUMMARY_REPORT="$report" \
  GLUERUN_SUMMARY_STRATEGY="$strategy" \
  GLUERUN_SUMMARY_ATTEMPTS="$attempts" \
  python3 - <<'PY' || true
import json, os, sys

artifact = {
    "schema": "gluerun.orchestration.ctx-experiment-summary.v0",
    "report": json.loads(os.environ["GLUERUN_SUMMARY_REPORT"]),
    "strategy": json.loads(os.environ["GLUERUN_SUMMARY_STRATEGY"]),
    "attempts": json.loads(os.environ["GLUERUN_SUMMARY_ATTEMPTS"]),
}
json.dump(artifact, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
  return 0
}
