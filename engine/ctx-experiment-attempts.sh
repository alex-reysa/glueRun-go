#!/usr/bin/env bash
# ctx-experiment-attempts.sh — read-only SECONDARY raw-metrics extractor for the
# `experiment-run` executable DAG node (layer evaluation). Completes (does NOT
# duplicate) the secondary set: engine/ctx-experiment-report.sh ships the primary
# escape-rate / per-arm cost / bias measurements; engine/ctx-experiment-strategy.sh
# ships the resume/rehydrate hit rates and gate-refusal reason mix; this one ships
# the LAST remaining stage-7 secondaries — per-arm attempts-to-accept and
# findings-per-attempt.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior
# (OFF-parity intrinsic, mirroring the engine/ctx-metrics.sh and sibling
# engine/ctx-experiment-*.sh idiom). It does NOT edit engine/ctx-metrics.sh,
# engine/ctx-experiment-report.sh, engine/ctx-experiment-strategy.sh, or any
# other pre-existing file.
#
# STRICTLY READ-ONLY: every function reads only the runs directory attempts
# indexes (runs/<runId>/attempts/index.json, each carrying taskId and a list of
# attempts, every attempt with a per-attempt ordinal `n`, a `failureClass`, and a
# `findings` array) plus the events log (events.ndjson) for `ctx.arm_assigned`
# {taskId, arm in A|B} to group by arm. It creates, moves, or mutates NOTHING —
# no run artifact, index, event, lease, or task file. This is measurement code
# the operator's experiment-report.md references at merge; it neither declares
# nor gates node completion.
#
# Measurement definitions:
#   * Acceptance: reuses the ctx-metrics.sh convention VERBATIM — an attempt is
#     accepted when its failureClass is one of "" / "accepted" / "none". So
#     attempts-to-accept agrees with the primary metrics.
#   * Attempts-to-accept: for each accepted task (a task with >=1 accepted
#     attempt) the ordinal `n` of its FIRST accepted attempt (attempts scanned in
#     `n` order). Per arm: acceptedTasks (count), attemptsToAcceptSum,
#     attemptsToAcceptMean = sum / acceptedTasks (0 when none).
#   * Findings-per-attempt: per arm, attempts (count of attempt entries),
#     findingsTotal (sum over attempts of the per-attempt `findings` array length,
#     an absent/empty findings counted as 0), findingsPerAttemptMean =
#     findingsTotal / attempts (0 when the arm has no attempts, never a divide
#     error).
#   * Arm join: a task's arm comes from `ctx.arm_assigned` (last assignment wins
#     deterministically). Tasks with no arm assignment contribute to neither arm.
#
# Evidence invariance / advocate-skeptic line: the aggregator only MEASURES; it
# confers no independence and reclassifies no attempt's acceptance or
# failureClass. Tallies partition tasks/attempts exactly by their recorded arm
# and failureClass.
#
# Fail-safe: missing / empty inputs yield a well-formed ZEROED result and a zero
# exit, never an error, divide error, or partial output.
#
# Public entry points:
#   singular_ctx_experiment_attempts_to_accept [runs_dir] [events_file]
#     Prints {"A":SLICE,"B":SLICE} where
#       SLICE = {acceptedTasks, attemptsToAcceptSum, attemptsToAcceptMean}.
#   singular_ctx_experiment_findings_per_attempt [runs_dir] [events_file]
#     Prints {"A":SLICE,"B":SLICE} where
#       SLICE = {attempts, findingsTotal, findingsPerAttemptMean}.
#   singular_ctx_experiment_attempts_json [runs_dir] [events_file]
#     Emits ONE deterministic, sorted-key JSON object conforming to
#     singular.orchestration.ctx-experiment-attempts.v0, merging both per-arm
#     rollups. Defaults: runs_dir=$SINGULAR_RUNS_DIR, events_file=$SINGULAR_EVENTS_FILE.

# --- shared read-only parser -------------------------------------------------
# Emits Python that, when included, defines:
#   load_arms(events_file)  -> taskId -> "A"/"B" (last assignment wins)
#   load_tasks(runs_dir)    -> list of {"taskId", "attempts":[{n, findingsLen,
#                              accepted}, ...] in n order}
#   attempts_to_accept(tasks, arm_of) -> {"A":SLICE,"B":SLICE}
#   findings_per_attempt(tasks, arm_of) -> {"A":SLICE,"B":SLICE}
# plus the ARMS / ACCEPTED_CLASSES constants. Pure; no writes.
_singular_ctx_experiment_attempts_py() {
  cat <<'PY'
import json
import os

ARMS = ("A", "B")
ACCEPTED_CLASSES = {"", "accepted", "none"}


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


def _findings_len(a):
    fnd = a.get("findings")
    if isinstance(fnd, list):
        return len(fnd)
    return 0


def load_tasks(runs_dir):
    tasks = []  # {taskId, attempts:[{n, findingsLen, accepted}]}
    if not runs_dir or not os.path.isdir(runs_dir):
        return tasks
    for run in sorted(os.listdir(runs_dir)):
        idx_path = os.path.join(runs_dir, run, "attempts", "index.json")
        if not os.path.isfile(idx_path):
            continue
        index = _read_json(idx_path)
        if not isinstance(index, dict):
            continue
        tid = str(index.get("taskId", ""))
        if not tid:
            continue
        raw = index.get("attempts")
        raw = raw if isinstance(raw, list) else []
        raw = [a for a in raw if isinstance(a, dict)]
        attempts = []
        for a in sorted(raw, key=lambda x: x.get("n", 0)):
            fc = str(a.get("failureClass", ""))
            attempts.append({
                "n": a.get("n"),
                "findingsLen": _findings_len(a),
                "accepted": fc in ACCEPTED_CLASSES,
            })
        tasks.append({"taskId": tid, "attempts": attempts})
    return tasks


def _first_accepted_ordinal(attempts):
    # attempts already in n order; return the n of the first accepted attempt.
    for a in attempts:
        if a["accepted"]:
            try:
                return int(a["n"])
            except (TypeError, ValueError):
                return None
    return None


def attempts_to_accept(tasks, arm_of):
    out = {}
    for arm in ARMS:
        accepted_tasks = 0
        total = 0
        for t in tasks:
            if arm_of.get(t["taskId"]) != arm:
                continue
            ordinal = _first_accepted_ordinal(t["attempts"])
            if ordinal is None:
                continue
            accepted_tasks += 1
            total += ordinal
        out[arm] = {
            "acceptedTasks": accepted_tasks,
            "attemptsToAcceptSum": total,
            "attemptsToAcceptMean": (total / accepted_tasks) if accepted_tasks else 0.0,
        }
    return out


def findings_per_attempt(tasks, arm_of):
    out = {}
    for arm in ARMS:
        attempts = 0
        findings_total = 0
        for t in tasks:
            if arm_of.get(t["taskId"]) != arm:
                continue
            for a in t["attempts"]:
                attempts += 1
                findings_total += a["findingsLen"]
        out[arm] = {
            "attempts": attempts,
            "findingsTotal": findings_total,
            "findingsPerAttemptMean": (findings_total / attempts) if attempts else 0.0,
        }
    return out
PY
}

# Per-arm attempts-to-accept. Fail-safe.
singular_ctx_experiment_attempts_to_accept() {
  local runs_dir="${1:-${SINGULAR_RUNS_DIR:-}}"
  local events_file="${2:-${SINGULAR_EVENTS_FILE:-}}"
  python3 - "$runs_dir" "$events_file" <<PY || true
import json, sys
$(_singular_ctx_experiment_attempts_py)

runs_dir, events_file = sys.argv[1], sys.argv[2]
arm_of = load_arms(events_file)
tasks = load_tasks(runs_dir)
json.dump(attempts_to_accept(tasks, arm_of), sys.stdout, sort_keys=True)
PY
  return 0
}

# Per-arm findings-per-attempt. Fail-safe.
singular_ctx_experiment_findings_per_attempt() {
  local runs_dir="${1:-${SINGULAR_RUNS_DIR:-}}"
  local events_file="${2:-${SINGULAR_EVENTS_FILE:-}}"
  python3 - "$runs_dir" "$events_file" <<PY || true
import json, sys
$(_singular_ctx_experiment_attempts_py)

runs_dir, events_file = sys.argv[1], sys.argv[2]
arm_of = load_arms(events_file)
tasks = load_tasks(runs_dir)
json.dump(findings_per_attempt(tasks, arm_of), sys.stdout, sort_keys=True)
PY
  return 0
}

# Composed secondary-metrics artifact. Merges both per-arm rollups into one
# deterministic sorted-key JSON object. Fail-safe.
singular_ctx_experiment_attempts_json() {
  local runs_dir="${1:-${SINGULAR_RUNS_DIR:-}}"
  local events_file="${2:-${SINGULAR_EVENTS_FILE:-}}"
  python3 - "$runs_dir" "$events_file" <<PY || true
import json, sys
$(_singular_ctx_experiment_attempts_py)

runs_dir, events_file = sys.argv[1], sys.argv[2]
arm_of = load_arms(events_file)
tasks = load_tasks(runs_dir)
artifact = {
    "schema": "singular.orchestration.ctx-experiment-attempts.v0",
    "attemptsToAccept": attempts_to_accept(tasks, arm_of),
    "findingsPerAttempt": findings_per_attempt(tasks, arm_of),
}
json.dump(artifact, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
  return 0
}
