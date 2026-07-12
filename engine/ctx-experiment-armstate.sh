#!/usr/bin/env bash
# ctx-experiment-armstate.sh — deterministic, STRICTLY READ-ONLY emitter of the
# OBSERVED continuity knob-state for the `experiment-run` executable DAG node
# (layer evaluation). The whole output side is integrated — the raw-metric
# aggregators, the summary merge, the arm-delta, the renderer, the end-to-end
# guard, and the `gluerun experiment-report` CLI all attribute escape-rate / cost
# / bias to arm A vs arm B — yet nothing records WHICH continuity features were
# actually active for a run. requiredCompletion defines the arms by knob-state
# (control = M0 knob-state; treatment = critique + revision + packets + routing);
# this file ships the auditable per-run evidence for that attribution.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# intrinsic, mirroring the sibling engine/ctx-experiment-*.sh idiom). It does NOT
# edit the sibling ctx-experiment-*.sh files or any pre-existing file.
#
# STRICTLY READ-ONLY: every function reads ONLY the process environment (the
# engine's own GLUERUN_* continuity knobs). It creates, moves, or mutates NOTHING
# — no run artifact, index, event, lease, or task file — appends NO event and
# writes no file (a per-run recorder wired into l1-drive.sh would own a driver
# file and is a separable out-of-scope slice). It neither declares nor gates node
# completion; the operator still runs the paired-audited A/B experiment across
# both arms and records per-knob default decisions in docs/orchestration/decisions.md.
#
# Knob-state definitions (the canonical GLUERUN_* names the engine itself defines,
# each with the engine's own documented default and active interpretation):
#   * truthy : set, non-empty, and not "0"  — GLUERUN_CTX_PACKET, GLUERUN_CTX_ARTIFACT_SCAN
#              (mirrors l1-drive.sh assumptions_ctx_enabled / the artifact-scan gate).
#   * flag1  : exactly "1"                   — GLUERUN_CTX_ROUTING, GLUERUN_REHYDRATE,
#              GLUERUN_CTX_MANIFEST (mirrors ctx-route.sh / ctx-rehydrate-authored-config.sh).
#   * pct    : a positive-integer percentage — GLUERUN_PAIRED_AUDIT_PCT,
#              GLUERUN_CRITIC_RECHECK_PCT (mirrors ctx-paired-audit.sh /
#              ctx-critic-recheck-resume.sh: unset / 0 / non-numeric garbage = OFF).
# With NO continuity knobs set the snapshot IS the M0 control knob-state (every
# knob inactive); with the treatment knobs set it is the treatment knob-state —
# one emitter documents either arm by reading the environment.
#
# Fail-safe: a partial or non-enabling value (non-numeric percent, empty string)
# is reported verbatim with active=false where it does not enable the feature,
# never a nonzero exit or partial output.
#
# Public entry points:
#   gluerun_ctx_experiment_armstate_read <knob>
#     Prints {"knob","value","active"} for one canonical continuity knob, reading
#     its environment value with the knob's documented default. Deterministic.
#   gluerun_ctx_experiment_armstate_snapshot
#     Prints {<knob>:{"knob","value","active"}, ...} — the record for EVERY
#     continuity feature knob that distinguishes treatment from the M0 control.
#   gluerun_ctx_experiment_armstate_json
#     Emits ONE deterministic, sorted-key JSON object conforming to
#     gluerun.orchestration.ctx-experiment-armstate.v0, composing the snapshot
#     with the schema tag and an active-knob count.

# --- shared read-only knob spec ----------------------------------------------
# Emits Python that defines the canonical continuity-knob table plus read_knob()
# and snapshot(). Reads ONLY os.environ; pure and deterministic for a fixed env.
_gluerun_ctx_experiment_armstate_py() {
  cat <<'PY'
import json, os, re

# Canonical continuity knobs distinguishing treatment from the M0 control
# baseline: (env name, documented default, active interpretation). Order is the
# discovery order; the emitter sorts keys for deterministic output.
KNOBS = (
    ("GLUERUN_CTX_PACKET", "0", "truthy"),
    ("GLUERUN_CTX_ROUTING", "0", "flag1"),
    ("GLUERUN_REHYDRATE", "0", "flag1"),
    ("GLUERUN_PAIRED_AUDIT_PCT", "0", "pct"),
    ("GLUERUN_CRITIC_RECHECK_PCT", "0", "pct"),
    ("GLUERUN_CTX_ARTIFACT_SCAN", "0", "truthy"),
    ("GLUERUN_CTX_MANIFEST", "0", "flag1"),
)
SPEC = {name: (default, mode) for (name, default, mode) in KNOBS}


def _active(value, mode):
    # The engine's own enabling interpretation for each knob family.
    if mode == "flag1":
        return value == "1"
    if mode == "pct":
        # Positive integer percent enables; unset / 0 / non-numeric = OFF.
        return bool(re.fullmatch(r"[0-9]+", value)) and int(value) > 0
    # truthy: set-and-enabling versus unset / 0 / empty.
    return value != "" and value != "0"


def read_knob(knob):
    default, mode = SPEC.get(knob, ("0", "truthy"))
    # os.environ.get carries a set-but-empty value verbatim (never the default),
    # so a partial / non-enabling value is reported as-is with active=false.
    value = os.environ.get(knob, default)
    return {"knob": knob, "value": value, "active": _active(value, mode)}


def snapshot():
    return {name: read_knob(name) for (name, _default, _mode) in KNOBS}
PY
}

# One canonical continuity knob's {knob,value,active} record. Read-only, fail-safe.
gluerun_ctx_experiment_armstate_read() {
  local knob="${1:-}"
  python3 - "$knob" <<PY || true
import json, sys
$(_gluerun_ctx_experiment_armstate_py)

json.dump(read_knob(sys.argv[1]), sys.stdout, sort_keys=True)
PY
  return 0
}

# Every continuity knob's record, keyed by canonical name. Read-only, fail-safe.
gluerun_ctx_experiment_armstate_snapshot() {
  python3 - <<PY || true
import json, sys
$(_gluerun_ctx_experiment_armstate_py)

json.dump(snapshot(), sys.stdout, sort_keys=True)
PY
  return 0
}

# Composed knob-state artifact: ONE deterministic sorted-key JSON object. With no
# continuity knobs set it is the M0 control knob-state (activeCount 0); with the
# treatment knobs set it is the treatment knob-state. Read-only, fail-safe.
gluerun_ctx_experiment_armstate_json() {
  python3 - <<PY || true
import json, sys
$(_gluerun_ctx_experiment_armstate_py)

knobs = snapshot()
artifact = {
    "schema": "gluerun.orchestration.ctx-experiment-armstate.v0",
    "knobs": knobs,
    "activeCount": sum(1 for record in knobs.values() if record["active"]),
}
json.dump(artifact, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
  return 0
}
