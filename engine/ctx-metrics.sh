#!/usr/bin/env bash
# ctx-metrics.sh — read-only orchestration metrics extractor.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior.
#
# STRICTLY READ-ONLY: it reads each run's attempts index
# (runs/<runId>/attempts/index.json, schema gluerun.orchestration.attempts-index.v0)
# and an events log (events.ndjson) and emits metrics as JSON on stdout. It never
# creates, modifies, or deletes any run artifact, index, or event.
#
# Public entry point:
#   gluerun_ctx_metrics_json [runs_dir] [events_file]
#     runs_dir     defaults to ${GLUERUN_RUNS_DIR:-}
#     events_file  defaults to ${GLUERUN_EVENTS_FILE:-}
#   Missing/empty inputs are NOT an error: they yield a well-formed metrics
#   object with zeroed counts (fail safe).
#
# Output shape (stable; keys sorted; deterministic for a given input set):
#   {
#     "schema": "gluerun.orchestration.ctx-metrics.v0",
#     "perTask": [                      # one entry per runs/<runId>/attempts/index.json,
#                                       # sorted by (taskId, runId)
#       {
#         "runId": <str>,
#         "taskId": <str>,
#         "attemptsTotal": <int>,       # number of attempt entries in the index
#         "attemptsToAccept": <int|null>,   # n of the first accepted attempt, else null
#         "accepted": <bool>,           # whether any attempt was accepted
#         "failureClassCounts": { <class>: <int> },      # "" -> "accepted"
#         "auditVerdictCounts": { <verdict>: <int> },    # "" -> "none"
#         "workerStrategyCounts": { <strategy>: <int> }, # absent field not counted
#         "reviewerStrategyCounts": { <strategy>: <int> },
#         "deciderAuthorityCounts": { <authority>: <int> }  # "" -> "none"
#       }, ...
#     ],
#     "aggregate": {                    # totals/distributions across all runs
#       "runsTotal": <int>,
#       "attemptsTotal": <int>,
#       "acceptedRuns": <int>,
#       "failureClassCounts": { <class>: <int> },
#       "auditVerdictCounts": { <verdict>: <int> },
#       "workerStrategyCounts": { <strategy>: <int> },
#       "reviewerStrategyCounts": { <strategy>: <int> },
#       "deciderAuthorityCounts": { <authority>: <int> },
#       "strategySelectedReasonCounts": { <reason>: <int> }  # from events log:
#           # data.reason of every context.strategy_selected event
#     }
#   }
# An attempt is "accepted" when its failureClass is "" / "accepted" / "none".
# JSON is emitted with sorted keys and a trailing newline so downstream consumers
# and tests can pin the exact bytes.

gluerun_ctx_metrics_json() {
  local runs_dir="${1:-${GLUERUN_RUNS_DIR:-}}"
  local events_file="${2:-${GLUERUN_EVENTS_FILE:-}}"
  python3 - "$runs_dir" "$events_file" <<'PY'
import json
import os
import sys

runs_dir, events_file = sys.argv[1], sys.argv[2]

ACCEPTED_CLASSES = {"", "accepted", "none"}


def bump(counter, key):
    counter[key] = counter.get(key, 0) + 1


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def per_task(index):
    attempts = index.get("attempts")
    if not isinstance(attempts, list):
        attempts = []
    attempts = [a for a in attempts if isinstance(a, dict)]

    failure = {}
    verdict = {}
    worker = {}
    reviewer = {}
    authority = {}
    accepted_to = None
    for a in sorted(attempts, key=lambda x: x.get("n", 0)):
        fc = str(a.get("failureClass", ""))
        fc_key = "accepted" if fc in ACCEPTED_CLASSES else fc
        bump(failure, fc_key)
        bump(verdict, str(a.get("auditVerdict", "")) or "none")
        bump(authority, str(a.get("deciderAuthority", "")) or "none")
        if "workerStrategy" in a and a.get("workerStrategy"):
            bump(worker, str(a["workerStrategy"]))
        if "reviewerStrategy" in a and a.get("reviewerStrategy"):
            bump(reviewer, str(a["reviewerStrategy"]))
        if fc in ACCEPTED_CLASSES and accepted_to is None:
            try:
                accepted_to = int(a.get("n"))
            except (TypeError, ValueError):
                accepted_to = None
    return {
        "runId": str(index.get("runId", "")),
        "taskId": str(index.get("taskId", "")),
        "attemptsTotal": len(attempts),
        "attemptsToAccept": accepted_to,
        "accepted": accepted_to is not None,
        "failureClassCounts": failure,
        "auditVerdictCounts": verdict,
        "workerStrategyCounts": worker,
        "reviewerStrategyCounts": reviewer,
        "deciderAuthorityCounts": authority,
    }


per_task_list = []
if runs_dir and os.path.isdir(runs_dir):
    for run in sorted(os.listdir(runs_dir)):
        idx_path = os.path.join(runs_dir, run, "attempts", "index.json")
        if not os.path.isfile(idx_path):
            continue
        index = read_json(idx_path)
        if not isinstance(index, dict):
            continue
        if not index.get("runId"):
            index["runId"] = run
        per_task_list.append(per_task(index))

per_task_list.sort(key=lambda t: (t["taskId"], t["runId"]))

# Aggregate distributions across all runs.
agg_failure = {}
agg_verdict = {}
agg_worker = {}
agg_reviewer = {}
agg_authority = {}
attempts_total = 0
accepted_runs = 0
for t in per_task_list:
    attempts_total += t["attemptsTotal"]
    if t["accepted"]:
        accepted_runs += 1
    for src, dst in (
        (t["failureClassCounts"], agg_failure),
        (t["auditVerdictCounts"], agg_verdict),
        (t["workerStrategyCounts"], agg_worker),
        (t["reviewerStrategyCounts"], agg_reviewer),
        (t["deciderAuthorityCounts"], agg_authority),
    ):
        for k, v in src.items():
            dst[k] = dst.get(k, 0) + v

# Strategy-selected reason counts from the events log.
reason_counts = {}
if events_file and os.path.isfile(events_file):
    try:
        with open(events_file, "r", encoding="utf-8") as f:
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
                if ev.get("type") != "context.strategy_selected":
                    continue
                data = ev.get("data")
                if not isinstance(data, dict):
                    continue
                bump(reason_counts, str(data.get("reason", "")) or "none")
    except OSError:
        pass

metrics = {
    "schema": "gluerun.orchestration.ctx-metrics.v0",
    "perTask": per_task_list,
    "aggregate": {
        "runsTotal": len(per_task_list),
        "attemptsTotal": attempts_total,
        "acceptedRuns": accepted_runs,
        "failureClassCounts": agg_failure,
        "auditVerdictCounts": agg_verdict,
        "workerStrategyCounts": agg_worker,
        "reviewerStrategyCounts": agg_reviewer,
        "deciderAuthorityCounts": agg_authority,
        "strategySelectedReasonCounts": reason_counts,
    },
}
json.dump(metrics, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
}
