#!/usr/bin/env bash
# ctx-experiment-armaudit.sh — deterministic, STRICTLY READ-ONLY CONSUMER that
# audits per-arm knob-state INTEGRITY across the runs corpus for the
# `experiment-run` executable DAG node (layer evaluation). TASK-0095's
# l1-drive.sh hook now durably writes per-run knob-state provenance to
# arm-knob-state.json under each run directory (conforming to
# gluerun.orchestration.ctx-experiment-armstate.v0, carrying an activeCount and a
# per-knob active flag), but NOTHING reads it — the provenance is write-only.
# requiredCompletion defines the arms by their knob-state (control = M0
# knob-state; treatment = critique + revision + packets + routing), and the
# escape-rate / cost / bias comparison is only valid if each arm actually ran
# with the expected knob-state: a contaminated control run (continuity knobs
# active) or a treatment run that ran as M0 silently invalidates the experiment.
# This file ships the consumer that audits that integrity across the corpus.
#
# It uses the GENERIC arm boundary ONLY — control expects activeCount 0;
# treatment expects activeCount greater than 0 — and does NOT prescribe the
# operator's exact treatment knob-set, keeping engine/ project-agnostic.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# intrinsic, mirroring the sibling engine/ctx-experiment-*.sh idiom). It does NOT
# edit engine/l1-drive.sh, the emitter engine/ctx-experiment-armstate.sh, or any
# other pre-existing file.
#
# STRICTLY READ-ONLY: every function reads ONLY the runs directory (each run's
# arm-knob-state.json provenance and its attempts index runs/<runId>/attempts/
# index.json for the taskId) plus the events log (events.ndjson) for
# `ctx.arm_assigned` {taskId, arm in A|B}. It creates, moves, or mutates NOTHING
# — no run artifact, index, event, lease, or task file. This is measurement code
# the operator's experiment-report.md references at merge; it neither declares
# nor gates node completion, does NOT run the paired-audited A/B experiment, and
# records no per-knob default decisions (all operator authority).
#
# Classification (the generic arm boundary):
#   * control-arm (A) run: consistent iff activeCount is 0 (the M0 knob-state),
#     else `contaminated` with the active knobs listed.
#   * treatment-arm (B) run: consistent iff activeCount is greater than 0, else
#     flagged `misconfigured-as-M0`.
#   * a run with no arm-knob-state.json is counted `unrecorded` for its arm
#     (fail-safe, not an error).
#   * a run whose taskId joins no arm (no ctx.arm_assigned) contributes to
#     neither arm (mirrors the sibling ctx-experiment-attempts.sh arm join).
#
# Evidence invariance / advocate-skeptic line: the audit only MEASURES arm
# integrity and reclassifies nothing — consistent + inconsistent + unrecorded
# partition each arm's joined runs exactly.
#
# Fail-safe: missing / empty inputs yield a well-formed ZEROED audit and a zero
# exit, never a nonzero exit or partial output.
#
# Public entry points:
#   gluerun_ctx_experiment_armaudit_runstate [runs_dir]
#     Prints {<runId>:{recorded, activeCount, activeKnobs}, ...} — per-run
#     knob-state read from arm-knob-state.json (a missing file -> recorded false).
#   gluerun_ctx_experiment_armaudit_classify [runs_dir] [events_file]
#     Prints {"A":SLICE,"B":SLICE} where SLICE = {arm, expectation, runsRecorded,
#     runsUnrecorded, consistent, inconsistent, inconsistentRuns[]}.
#   gluerun_ctx_experiment_armaudit_json [runs_dir] [events_file]
#     Emits ONE deterministic, sorted-key JSON object conforming to
#     gluerun.orchestration.ctx-experiment-armaudit.v0. Defaults:
#     runs_dir=$GLUERUN_RUNS_DIR, events_file=$GLUERUN_EVENTS_FILE.

# --- shared read-only parser -------------------------------------------------
# Emits Python that, when included, defines:
#   load_arms(events_file)  -> taskId -> "A"/"B" (last assignment wins)
#   load_runs(runs_dir)     -> list of {runId, taskId, recorded, activeCount,
#                              activeKnobs} in sorted runId order
#   classify(runs, arm_of)  -> {"A":SLICE,"B":SLICE}
# plus the ARMS constant. Pure; reads only the given paths; no writes.
_gluerun_ctx_experiment_armaudit_py() {
  cat <<'PY'
import json
import os

ARMS = ("A", "B")


def _read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def load_arms(events_file):
    arm_of = {}  # taskId -> "A"/"B"
    if not events_file:
        return arm_of
    try:
        f = open(events_file, "r", encoding="utf-8")
    except OSError:
        return arm_of
    with f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(ev, dict):
                continue
            if ev.get("type") != "ctx.arm_assigned":
                continue
            data = ev.get("data")
            if not isinstance(data, dict):
                continue
            tid = str(data.get("taskId", ""))
            arm = str(data.get("arm", ""))
            if tid and arm in ARMS:
                arm_of[tid] = arm
    return arm_of


def _knobstate(run_path):
    # Read this run's arm-knob-state.json (a ctx-experiment-armstate.v0 artifact).
    # Returns (recorded, activeCount, activeKnobs). A missing / unparseable file is
    # classified unrecorded (fail-safe, not an error).
    state = _read_json(os.path.join(run_path, "arm-knob-state.json"))
    if not isinstance(state, dict):
        return False, None, []
    knobs = state.get("knobs")
    active = []
    if isinstance(knobs, dict):
        for name, rec in knobs.items():
            if isinstance(rec, dict) and rec.get("active") is True:
                active.append(str(name))
    active.sort()
    ac = state.get("activeCount")
    # Generic boundary is on activeCount; fall back to the derived active-knob
    # count if the recorded field is absent or not a plain integer.
    if isinstance(ac, bool) or not isinstance(ac, int):
        ac = len(active)
    return True, ac, active


def load_runs(runs_dir):
    runs = []  # {runId, taskId, recorded, activeCount, activeKnobs}
    if not runs_dir or not os.path.isdir(runs_dir):
        return runs
    for run in sorted(os.listdir(runs_dir)):
        run_path = os.path.join(runs_dir, run)
        if not os.path.isdir(run_path):
            continue
        index = _read_json(os.path.join(run_path, "attempts", "index.json"))
        tid = str(index.get("taskId", "")) if isinstance(index, dict) else ""
        recorded, active_count, active_knobs = _knobstate(run_path)
        runs.append({
            "runId": run,
            "taskId": tid,
            "recorded": recorded,
            "activeCount": active_count,
            "activeKnobs": active_knobs,
        })
    return runs


def classify(runs, arm_of):
    out = {}
    for arm in ARMS:
        recorded = unrecorded = consistent = inconsistent = 0
        inconsistent_runs = []
        for r in runs:
            if arm_of.get(r["taskId"]) != arm:
                continue
            if not r["recorded"]:
                unrecorded += 1
                continue
            recorded += 1
            active_count = r["activeCount"]
            if arm == "A":
                # control expects the M0 knob-state (activeCount 0)
                ok = (active_count == 0)
                classification = "contaminated"
            else:
                # treatment expects activeCount greater than 0
                ok = (active_count > 0)
                classification = "misconfigured-as-M0"
            if ok:
                consistent += 1
            else:
                inconsistent += 1
                inconsistent_runs.append({
                    "runId": r["runId"],
                    "classification": classification,
                    "activeCount": active_count,
                    "activeKnobs": r["activeKnobs"],
                })
        inconsistent_runs.sort(key=lambda x: x["runId"])
        out[arm] = {
            "arm": arm,
            "expectation": "activeCount==0" if arm == "A" else "activeCount>0",
            "runsRecorded": recorded,
            "runsUnrecorded": unrecorded,
            "consistent": consistent,
            "inconsistent": inconsistent,
            "inconsistentRuns": inconsistent_runs,
        }
    return out
PY
}

# Per-run knob-state read from each run's arm-knob-state.json. Read-only, fail-safe.
gluerun_ctx_experiment_armaudit_runstate() {
  local runs_dir="${1:-${GLUERUN_RUNS_DIR:-}}"
  python3 - "$runs_dir" <<PY || true
import json, sys
$(_gluerun_ctx_experiment_armaudit_py)

runs = load_runs(sys.argv[1])
out = {
    r["runId"]: {
        "recorded": r["recorded"],
        "activeCount": r["activeCount"],
        "activeKnobs": r["activeKnobs"],
    }
    for r in runs
}
json.dump(out, sys.stdout, sort_keys=True)
PY
  return 0
}

# Per-arm join + classification. Read-only, fail-safe.
gluerun_ctx_experiment_armaudit_classify() {
  local runs_dir="${1:-${GLUERUN_RUNS_DIR:-}}"
  local events_file="${2:-${GLUERUN_EVENTS_FILE:-}}"
  python3 - "$runs_dir" "$events_file" <<PY || true
import json, sys
$(_gluerun_ctx_experiment_armaudit_py)

runs_dir, events_file = sys.argv[1], sys.argv[2]
arm_of = load_arms(events_file)
runs = load_runs(runs_dir)
json.dump(classify(runs, arm_of), sys.stdout, sort_keys=True)
PY
  return 0
}

# Composed audit artifact: ONE deterministic sorted-key JSON object conforming to
# gluerun.orchestration.ctx-experiment-armaudit.v0. Read-only, fail-safe.
gluerun_ctx_experiment_armaudit_json() {
  local runs_dir="${1:-${GLUERUN_RUNS_DIR:-}}"
  local events_file="${2:-${GLUERUN_EVENTS_FILE:-}}"
  python3 - "$runs_dir" "$events_file" <<PY || true
import json, sys
$(_gluerun_ctx_experiment_armaudit_py)

runs_dir, events_file = sys.argv[1], sys.argv[2]
arm_of = load_arms(events_file)
runs = load_runs(runs_dir)
artifact = {
    "schema": "gluerun.orchestration.ctx-experiment-armaudit.v0",
    "arms": classify(runs, arm_of),
}
json.dump(artifact, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
  return 0
}
