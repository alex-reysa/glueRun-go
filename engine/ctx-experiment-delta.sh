#!/usr/bin/env bash
# ctx-experiment-delta.sh — read-only treatment-vs-control CONTRAST for the
# `experiment-run` executable DAG node (layer evaluation). Every integrated
# per-arm aggregator reports ABSOLUTE per-arm values; NONE computes the A-vs-B
# delta the `per-knob default decisions` clause reads. This brick ships that
# delta: arm B (treatment) minus arm A (control / M0 knob state) for each
# headline metric.
#
# It ships NO base metric of its own: it reads ONLY the summary bundle (obtained
# by delegating to gluerun_ctx_experiment_summary_json, or from a supplied bundle
# source) and DIFFERENCES the already-computed per-arm values — re-deriving no
# base metric (single upstream definition site) and creating, moving, or mutating
# NOTHING.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# intrinsic, mirroring the sibling engine/ctx-experiment-*.sh idiom). It does NOT
# edit the six sibling ctx-experiment-*.sh files, engine/ctx-metrics.sh, or any
# other pre-existing file.
#
# It emits NO better/worse or knob-flip judgment and NO per-knob attribution —
# only numeric deltas and a NEUTRAL direction label. Which knobs flip, the
# mapping of metrics to knobs, experiment-report.md, and the recorded per-knob
# default decisions all remain OPERATOR authority. This delta only MEASURES the
# contrast and reclassifies nothing (evidence invariance / advocate-skeptic line
# preserved). It neither declares nor gates node completion.
#
# Fail-safe: missing or empty inputs yield well-formed ZEROED deltas and a zero
# exit, never an error or partial output.
#
# Three chained slices (all here):
#   1. gluerun_ctx_experiment_delta_record  — pure helper: two arm sub-objects +
#      a value path -> {a, b, delta = b - a, direction in {lower,higher,equal}};
#      a missing arm value is treated as zero.
#   2. gluerun_ctx_experiment_delta_metrics — applies the helper across the
#      headline metric set read from the summary bundle.
#   3. gluerun_ctx_experiment_delta_json [runs_dir] [events_file] [metrics_file]
#      — public entry: obtain the summary bundle and emit ONE deterministic
#      sorted-key JSON object under gluerun.orchestration.ctx-experiment-delta.v0.

# Single-site pure-helper definition (slice 1 logic), shared by the record
# wrapper and the metric-set consumer so the delta is computed one way only.
# delta_record(arm_a, arm_b, path) -> {a, b, delta, direction}; missing / non-
# numeric arm values collapse to 0.
_GLUERUN_CTX_EXPERIMENT_DELTA_PY="$(cat <<'PY'
def _num(obj, path):
    cur = obj
    for k in path:
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return 0
    if isinstance(cur, bool) or not isinstance(cur, (int, float)):
        return 0
    return cur

def delta_record(arm_a, arm_b, path):
    a = _num(arm_a, path)
    b = _num(arm_b, path)
    d = b - a
    if d > 0:
        direction = "higher"
    elif d < 0:
        direction = "lower"
    else:
        direction = "equal"
    return {"a": a, "b": b, "delta": d, "direction": direction}
PY
)"

# Slice 1 — pure helper exposed as a shell function. Given arm-A JSON, arm-B JSON
# and a value path (one component per remaining arg), emit a compact
# {a, b, delta, direction} record. Deterministic; missing value treated as zero.
gluerun_ctx_experiment_delta_record() {
  local arm_a="${1:-}" arm_b="${2:-}"
  shift 2 2>/dev/null || true
  GLUERUN_DELTA_A="$arm_a" GLUERUN_DELTA_B="$arm_b" python3 - "$@" <<PY || true
$_GLUERUN_CTX_EXPERIMENT_DELTA_PY
import json, os, sys

def load(s):
    try:
        return json.loads(s)
    except Exception:
        return {}

arm_a = load(os.environ.get("GLUERUN_DELTA_A", "{}"))
arm_b = load(os.environ.get("GLUERUN_DELTA_B", "{}"))
rec = delta_record(arm_a, arm_b, sys.argv[1:])
json.dump(rec, sys.stdout, sort_keys=True)
sys.stdout.write(chr(10))
PY
}

# Slice 2 — headline metric-set consumer. Given the summary bundle JSON, apply
# the shared helper across every headline metric and emit the sorted-key `deltas`
# map (metricKey -> record). Each metric routes the helper to the correct per-arm
# sub-objects and value path within the bundle.
gluerun_ctx_experiment_delta_metrics() {
  local bundle="${1:-}"
  GLUERUN_DELTA_BUNDLE="$bundle" python3 - <<PY || true
$_GLUERUN_CTX_EXPERIMENT_DELTA_PY
import json, os, sys

def load(s):
    try:
        return json.loads(s)
    except Exception:
        return {}

bundle = load(os.environ.get("GLUERUN_DELTA_BUNDLE", "{}"))
if not isinstance(bundle, dict):
    bundle = {}

def sub(path):
    cur = bundle
    for k in path:
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return {}
    return cur if isinstance(cur, dict) else {}

# metricKey -> (arm-A sub-object path, arm-B sub-object path, value path).
# The bias directional-disagreement rate is a single cross-arm aggregate, so
# both arms read the same sub-object and value: a == b, delta 0, no attribution.
METRICS = {
    "escapeRate": (["report", "arms", "A"], ["report", "arms", "B"], ["escapeRate"]),
    "costTokensPerTask": (["report", "arms", "A", "cost"], ["report", "arms", "B", "cost"], ["tokensPerTask"]),
    "costWallClockMsPerTask": (["report", "arms", "A", "cost"], ["report", "arms", "B", "cost"], ["wallClockMsPerTask"]),
    "attemptsToAcceptMean": (["attempts", "attemptsToAccept", "A"], ["attempts", "attemptsToAccept", "B"], ["attemptsToAcceptMean"]),
    "findingsPerAttemptMean": (["attempts", "findingsPerAttempt", "A"], ["attempts", "findingsPerAttempt", "B"], ["findingsPerAttemptMean"]),
    "biasDirectionalDisagreementRate": (["report", "bias"], ["report", "bias"], ["directionalDisagreementRate"]),
    "resumeHitRate": (["strategy", "hitRates", "byArm", "A"], ["strategy", "hitRates", "byArm", "B"], ["resumeHitRate"]),
    "rehydrateHitRate": (["strategy", "hitRates", "byArm", "A"], ["strategy", "hitRates", "byArm", "B"], ["rehydrateHitRate"]),
}

deltas = {}
for key, (pa, pb, vpath) in METRICS.items():
    deltas[key] = delta_record(sub(pa), sub(pb), vpath)

json.dump(deltas, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write(chr(10))
PY
}

# Slice 3 — composed public entry. Obtain the summary bundle (from a supplied
# bundle source file via GLUERUN_CTX_EXPERIMENT_DELTA_BUNDLE, else by threading
# the explicit corpus args through gluerun_ctx_experiment_summary_json), compute
# the per-metric treatment-effect deltas, and emit ONE deterministic sorted-key
# JSON object conforming to gluerun.orchestration.ctx-experiment-delta.v0.
# Fail-safe / always exit 0.
gluerun_ctx_experiment_delta_json() {
  local runs_dir="${1:-${GLUERUN_RUNS_DIR:-}}"
  local events_file="${2:-${GLUERUN_EVENTS_FILE:-}}"
  local metrics_file="${3:-${GLUERUN_CTX_EXPERIMENT_METRICS_FILE:-}}"

  # Obtain the summary bundle: a supplied bundle source wins; otherwise delegate
  # to the summary composer with the threaded corpus args. Either way, an
  # unreadable / empty / invalid bundle degrades to zeroed deltas downstream.
  local bundle bundle_src="${GLUERUN_CTX_EXPERIMENT_DELTA_BUNDLE:-}"
  if [[ -n "$bundle_src" ]]; then
    bundle="$(cat "$bundle_src" 2>/dev/null || true)"
  else
    bundle="$(gluerun_ctx_experiment_summary_json "$runs_dir" "$events_file" "$metrics_file")"
  fi

  local deltas
  deltas="$(gluerun_ctx_experiment_delta_metrics "$bundle")"

  GLUERUN_DELTA_DELTAS="$deltas" python3 - <<'PY' || true
import json, os, sys

def load(s):
    try:
        return json.loads(s)
    except Exception:
        return {}

artifact = {
    "schema": "gluerun.orchestration.ctx-experiment-delta.v0",
    "deltas": load(os.environ.get("GLUERUN_DELTA_DELTAS", "{}")),
}
json.dump(artifact, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write(chr(10))
PY
  return 0
}
