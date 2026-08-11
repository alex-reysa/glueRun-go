#!/usr/bin/env bash
# ctx-route-metrics.sh — read-only per-role strategy/outcome split extractor.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines a new
# function only; NO existing engine path invokes it, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior. The
# `singular metrics` / ctx-metrics.sh merge is a later hook and OUT OF SCOPE here.
#
# STRICTLY READ-ONLY: it reads each run's attempts index
# (runs/<runId>/attempts/index.json, schema singular.orchestration.attempts-index.v0)
# and (for signature parity with ctx-metrics.sh) an events log, then emits JSON on
# stdout. It appends no events, writes no files, and mutates no run artifact. It
# never exits non-zero on malformed or absent inputs — it degrades to empty splits.
#
# Where ctx-metrics.sh reports the MARGINAL per-role strategy counts, this reports
# the JOINT: for each role and each strategy value, how the per-attempt outcomes
# split into accepted vs rejected. That joint is what lets the routing / A-B
# learning loop tell whether a `resume` decision pays off against a `fresh` one.
#
# Public entry point:
#   singular_ctx_route_metrics_json [runs_dir] [events_file]
#     runs_dir     defaults to ${SINGULAR_RUNS_DIR:-}
#     events_file  defaults to ${SINGULAR_EVENTS_FILE:-}
#   Missing/empty inputs are NOT an error: they yield empty per-role splits.
#
# Output shape (stable; keys sorted; deterministic for a given input set):
#   {
#     "schema": "singular.orchestration.ctx-route-metrics.v0",
#     "roleStrategyOutcomeSplits": {
#       "worker":   { <strategy>: {"accepted": <int>, "rejected": <int>}, ... },
#       "reviewer": { <strategy>: {"accepted": <int>, "rejected": <int>}, ... }
#     }
#   }
# An attempt counts as "accepted" when its failureClass is "" / "accepted" /
# "none" (the SAME definition ctx-metrics.sh uses), else "rejected". Absent
# strategy fields are not counted. JSON is emitted with sorted keys and a trailing
# newline so downstream consumers and tests can pin the exact bytes.

singular_ctx_route_metrics_json() {
  local runs_dir="${1:-${SINGULAR_RUNS_DIR:-}}"
  local events_file="${2:-${SINGULAR_EVENTS_FILE:-}}"
  python3 - "$runs_dir" "$events_file" <<'PY'
import json
import os
import sys

runs_dir, events_file = sys.argv[1], sys.argv[2]

# Same accepted definition as engine/ctx-metrics.sh.
ACCEPTED_CLASSES = {"", "accepted", "none"}

ROLE_FIELD = (("worker", "workerStrategy"), ("reviewer", "reviewerStrategy"))


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def bump(splits, role, strategy, outcome):
    role_map = splits[role]
    cell = role_map.get(strategy)
    if cell is None:
        cell = {"accepted": 0, "rejected": 0}
        role_map[strategy] = cell
    cell[outcome] += 1


splits = {"worker": {}, "reviewer": {}}

if runs_dir and os.path.isdir(runs_dir):
    for run in sorted(os.listdir(runs_dir)):
        idx_path = os.path.join(runs_dir, run, "attempts", "index.json")
        if not os.path.isfile(idx_path):
            continue
        index = read_json(idx_path)
        if not isinstance(index, dict):
            continue
        attempts = index.get("attempts")
        if not isinstance(attempts, list):
            continue
        for a in attempts:
            if not isinstance(a, dict):
                continue
            fc = str(a.get("failureClass", ""))
            outcome = "accepted" if fc in ACCEPTED_CLASSES else "rejected"
            for role, field in ROLE_FIELD:
                if field in a and a.get(field):
                    bump(splits, role, str(a[field]), outcome)

metrics = {
    "schema": "singular.orchestration.ctx-route-metrics.v0",
    "roleStrategyOutcomeSplits": splits,
}
json.dump(metrics, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
}
