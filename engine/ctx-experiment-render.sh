#!/usr/bin/env bash
# ctx-experiment-render.sh — read-only PRESENTATION capstone for the
# `experiment-run` executable DAG node (layer evaluation). This brick ships NO
# metric of its own: it RENDERS the already-computed values of the integrated
# summary bundle (singular.orchestration.ctx-experiment-summary.v0, produced by
# engine/ctx-experiment-summary.sh) into the deterministic markdown metrics
# tables the operator drops into experiment-report.md (the exit gate requires the
# report merged with raw metrics artifacts referenced).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# intrinsic, mirroring the sibling engine/ctx-experiment-*.sh idiom). It does NOT
# edit the four sibling ctx-experiment-*.sh files, engine/ctx-metrics.sh, or any
# other pre-existing file.
#
# STRICTLY STDOUT-ONLY / READ-ONLY: it consumes a summary-bundle JSON source (a
# file path, or `-` for stdin); when no source is supplied it obtains the bundle
# by delegating to singular_ctx_experiment_summary_json with the standard env
# defaults. It formats the bundle's already-computed values VERBATIM (no
# recomputation, no reclassification) and emits markdown to STDOUT ONLY. It
# creates, moves, or mutates NOTHING — no run artifact, index, event, lease, or
# task file, and never writes docs/context-build-plan/experiment-report.md (an
# operator-owned concept). It neither declares nor gates node completion.
#
# It produces METRICS TABLES ONLY — no experiment narrative, no bias
# interpretation, no per-knob default decisions (operator authority). Evidence
# invariance / advocate-skeptic line preserved: it only formats measured values
# and reclassifies nothing.
#
# Fail-safe: a zeroed/empty bundle renders well-formed tables with zero values
# and a zero exit, never an error or partial output.
#
# Public entry point:
#   singular_ctx_experiment_render_md [summary_source]
#     summary_source is a bundle JSON file path, or `-` for stdin. When omitted,
#     the bundle is obtained by delegating to singular_ctx_experiment_summary_json
#     (standard env defaults). Emits ONE deterministic markdown fragment to
#     stdout: the per-arm primary table, the bias table, the resume/rehydrate
#     hit-rate table (by arm and by role), and the gate-refusal reason-mix table.

# --- Slice 1: per-arm PRIMARY table renderer ---------------------------------
# Renders escape rate, cost (tokens + wall-clock per accepted task),
# attempts-to-accept (mean), and findings-per-attempt (mean) for arms A and B,
# reading each value verbatim from the bundle on stdin. Emits to stdout.
singular_ctx_experiment_render_primary() {
  python3 - <<'PY' || true
import json, os, sys

def fmt(x):
    if isinstance(x, bool):
        return str(x)
    if isinstance(x, int):
        return str(x)
    if isinstance(x, float):
        return str(int(x)) if x.is_integer() else str(x)
    return str(x)

b = json.loads(os.environ.get("SINGULAR_RENDER_BUNDLE", ""))
arms = b["report"]["arms"]
A, B = arms["A"], arms["B"]
att = b["attempts"]

rows = [
    ("Escape rate", A["escapeRate"], B["escapeRate"]),
    ("Tokens per accepted task", A["cost"]["tokensPerTask"], B["cost"]["tokensPerTask"]),
    ("Wall-clock ms per accepted task", A["cost"]["wallClockMsPerTask"], B["cost"]["wallClockMsPerTask"]),
    ("Attempts-to-accept (mean)", att["attemptsToAccept"]["A"]["attemptsToAcceptMean"], att["attemptsToAccept"]["B"]["attemptsToAcceptMean"]),
    ("Findings-per-attempt (mean)", att["findingsPerAttempt"]["A"]["findingsPerAttemptMean"], att["findingsPerAttempt"]["B"]["findingsPerAttemptMean"]),
]
out = []
out.append("### Per-arm summary")
out.append("")
out.append("| Metric | Arm A (control) | Arm B (treatment) |")
out.append("| --- | --- | --- |")
for label, a, bb in rows:
    out.append("| %s | %s | %s |" % (label, fmt(a), fmt(bb)))
sys.stdout.write("\n".join(out) + "\n")
PY
}

# --- Slice 2: BIAS + STRATEGY table renderer ---------------------------------
# Renders the bias table (flagged findings, directional disagreements,
# directional-disagreement rate), the resume/rehydrate hit-rate table (by arm and
# by role), and the gate-refusal reason-mix table. Reads the bundle on stdin;
# emits to stdout. Values are formatted verbatim.
singular_ctx_experiment_render_bias_strategy() {
  python3 - <<'PY' || true
import json, os, sys

def fmt(x):
    if isinstance(x, bool):
        return str(x)
    if isinstance(x, int):
        return str(x)
    if isinstance(x, float):
        return str(int(x)) if x.is_integer() else str(x)
    return str(x)

b = json.loads(os.environ.get("SINGULAR_RENDER_BUNDLE", ""))
bias = b["report"]["bias"]
hit = b["strategy"]["hitRates"]
refusal = b["strategy"]["refusalMix"]
out = []

out.append("### Bias")
out.append("")
out.append("| Metric | Value |")
out.append("| --- | --- |")
out.append("| Flagged findings | %s |" % fmt(bias["flaggedFindings"]))
out.append("| Directional disagreements | %s |" % fmt(bias["directionalDisagreements"]))
out.append("| Directional-disagreement rate | %s |" % fmt(bias["directionalDisagreementRate"]))
out.append("")

out.append("### Resume / rehydrate hit rates")
out.append("")
out.append("| Scope | Resume hit rate | Rehydrate hit rate |")
out.append("| --- | --- | --- |")
byArm = hit["byArm"]
out.append("| Arm A | %s | %s |" % (fmt(byArm["A"]["resumeHitRate"]), fmt(byArm["A"]["rehydrateHitRate"])))
out.append("| Arm B | %s | %s |" % (fmt(byArm["B"]["resumeHitRate"]), fmt(byArm["B"]["rehydrateHitRate"])))
byRole = hit["byRole"]
for role in ("implementer", "planner", "reviewer"):
    r = byRole[role]
    out.append("| Role: %s | %s | %s |" % (role, fmt(r["resumeHitRate"]), fmt(r["rehydrateHitRate"])))
out.append("")

out.append("### Gate-refusal reason mix")
out.append("")
out.append("| Reason | Count |")
out.append("| --- | --- |")
for reason in sorted(refusal.get("reasonMix", {})):
    out.append("| %s | %s |" % (reason, fmt(refusal["reasonMix"][reason])))
out.append("| resume_failed | %s |" % fmt(refusal["resumeFailed"]))
sys.stdout.write("\n".join(out) + "\n")
PY
}

# --- Slice 3: composed public entry ------------------------------------------
# Obtains the bundle (from the file/stdin arg, else by delegating to
# singular_ctx_experiment_summary_json), then renders all sections in a stable
# order to stdout as ONE markdown fragment. Fail-safe / always exit 0.
singular_ctx_experiment_render_md() {
  local source="${1-}"
  local bundle

  if [[ -z "$source" ]]; then
    # No source supplied: delegate to the summary composer (standard env
    # defaults). The composer is itself fail-safe and emits a zeroed bundle when
    # its inputs are missing.
    bundle="$(singular_ctx_experiment_summary_json)"
  elif [[ "$source" == "-" ]]; then
    bundle="$(cat)"
  else
    bundle="$(cat "$source" 2>/dev/null)"
  fi

  # Render all sections in a stable order. Each slice reads the bundle from the
  # environment (arbitrary JSON, never re-parsed by the shell).
  printf '## Experiment metrics\n\n'
  SINGULAR_RENDER_BUNDLE="$bundle" singular_ctx_experiment_render_primary
  printf '\n'
  SINGULAR_RENDER_BUNDLE="$bundle" singular_ctx_experiment_render_bias_strategy
  return 0
}
