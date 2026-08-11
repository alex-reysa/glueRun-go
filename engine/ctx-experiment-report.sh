#!/usr/bin/env bash
# ctx-experiment-report.sh — read-only raw-metrics extractor for the
# `experiment-run` executable DAG node (layer evaluation).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior
# (OFF-parity intrinsic, mirroring the engine/ctx-metrics.sh idiom).
#
# STRICTLY READ-ONLY: every function reads only an events log (events.ndjson,
# whose relevant records are `ctx.arm_assigned` {taskId, arm}, `ctx.paired_audit`
# {taskId, verdict, findingsCount, disagreement, ...} and `ctx.critic_recheck`
# {taskId, dispositions:[{id, disposition}]}) plus an existing per-task metrics
# file. It creates, moves, or mutates NOTHING — no run artifact, index, event,
# lease, or task file. This is the measurement code the operator's
# experiment-report.md references at merge; it neither declares nor gates node
# completion.
#
# Measurement definitions:
#   * Accepted-and-audited task: a task carrying a post-acceptance
#     `ctx.paired_audit` event (paired audit runs strictly after acceptance, so
#     its presence proves the task was accepted). Its arm comes from that task's
#     `ctx.arm_assigned` event (A = control / M0 knob-state, B = treatment).
#   * Escape (flag): a `ctx.paired_audit` disagreement — paired verdict not
#     "accepted" OR non-empty paired findings. Per-arm escape rate = flagged /
#     accepted for that arm.
#   * Bias directional-disagreement rate: over the findings on tasks a FRESH
#     paired audit flagged, the fraction the context-aware `ctx.critic_recheck`
#     dispositioned addressed|obsolete rather than survives. The aggregator only
#     MEASURES this divergence; a context-aware "addressed" NEVER removes a fresh
#     paired-audit flag from the escape/flag set (evidence invariance;
#     advocate/skeptic line preserved).
#
# Fail-safe: missing / empty inputs yield a well-formed ZEROED result and a zero
# exit, never an error or partial output.
#
# Public entry points:
#   singular_ctx_experiment_escape_rates [events_file]
#     Prints {"A":{accepted,flagged,escapeRate}, "B":{...}} (events only).
#   singular_ctx_experiment_bias_rate [events_file]
#     Prints {flaggedFindings,directionalDisagreements,directionalDisagreementRate}.
#   singular_ctx_experiment_report_json [events_file] [metrics_file]
#     Emits ONE deterministic, sorted-key JSON object conforming to
#     singular.orchestration.ctx-experiment-report.v0, merging both arms' escape
#     rates, a per-arm cost rollup (tokens + wall-clock per accepted task), and
#     the bias rate. Defaults: events_file=$SINGULAR_EVENTS_FILE,
#     metrics_file=$SINGULAR_CTX_EXPERIMENT_METRICS_FILE.

# --- shared read-only parser -------------------------------------------------
# Prints, on stdout, a compact JSON object with the two arm keys A/B each mapping
# to {accepted, flagged, auditedTasks:[taskId,...]} plus the bias tallies. Pure.
_singular_ctx_experiment_events_py() {
  cat <<'PY'
import json

ARMS = ("A", "B")


def flagged_of(d):
    # Prefer the explicit disagreement flag; else derive it from verdict/findings.
    if isinstance(d.get("disagreement"), bool):
        return d["disagreement"]
    verdict = str(d.get("verdict", "")) or "accepted"
    try:
        count = int(d.get("findingsCount", 0) or 0)
    except (TypeError, ValueError):
        count = 0
    return (verdict != "accepted") or (count > 0)


def load_events(events_file):
    arm_of = {}          # taskId -> "A"/"B" (last assignment wins deterministically)
    audited = {}         # taskId -> flagged(bool); True if ANY paired audit disagreed
    rechecks = {}        # taskId -> list of dispositions (strings)
    if not events_file:
        return arm_of, audited, rechecks
    try:
        f = open(events_file, "r", encoding="utf-8")
    except OSError:
        return arm_of, audited, rechecks
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
            typ = ev.get("type")
            data = ev.get("data")
            if not isinstance(data, dict):
                continue
            tid = str(data.get("taskId", ""))
            if not tid:
                continue
            if typ == "ctx.arm_assigned":
                arm = str(data.get("arm", ""))
                if arm in ARMS:
                    arm_of[tid] = arm
            elif typ == "ctx.paired_audit":
                audited[tid] = audited.get(tid, False) or bool(flagged_of(data))
            elif typ == "ctx.critic_recheck":
                disps = data.get("dispositions")
                if isinstance(disps, list):
                    bucket = rechecks.setdefault(tid, [])
                    for it in disps:
                        if isinstance(it, dict):
                            st = str(it.get("disposition", ""))
                            if st:
                                bucket.append(st)
    return arm_of, audited, rechecks
PY
}

# Per-arm escape rate (events only). Fail-safe / always exit 0.
singular_ctx_experiment_escape_rates() {
  local events_file="${1:-${SINGULAR_EVENTS_FILE:-}}"
  python3 - "$events_file" <<PY || true
import json, sys
$(_singular_ctx_experiment_events_py)

events_file = sys.argv[1]
arm_of, audited, _ = load_events(events_file)

out = {}
for arm in ARMS:
    accepted = flagged = 0
    for tid, is_flagged in audited.items():
        if arm_of.get(tid) != arm:
            continue
        accepted += 1
        if is_flagged:
            flagged += 1
    rate = (flagged / accepted) if accepted else 0.0
    out[arm] = {"accepted": accepted, "flagged": flagged, "escapeRate": rate}

json.dump(out, sys.stdout, sort_keys=True)
PY
  return 0
}

# Bias directional-disagreement rate (events only). Fail-safe / always exit 0.
singular_ctx_experiment_bias_rate() {
  local events_file="${1:-${SINGULAR_EVENTS_FILE:-}}"
  python3 - "$events_file" <<PY || true
import json, sys
$(_singular_ctx_experiment_events_py)

events_file = sys.argv[1]
_, audited, rechecks = load_events(events_file)

DIRECTIONAL = {"addressed", "obsolete"}
flagged_findings = 0
directional = 0
for tid, is_flagged in audited.items():
    if not is_flagged:
        continue
    for disp in rechecks.get(tid, []):
        flagged_findings += 1
        if disp in DIRECTIONAL:
            directional += 1
rate = (directional / flagged_findings) if flagged_findings else 0.0

json.dump({
    "flaggedFindings": flagged_findings,
    "directionalDisagreements": directional,
    "directionalDisagreementRate": rate,
}, sys.stdout, sort_keys=True)
PY
  return 0
}

# Composed raw-metrics artifact. Merges escape rates, per-arm cost rollup, and
# the bias rate into one deterministic sorted-key JSON object. Fail-safe.
singular_ctx_experiment_report_json() {
  local events_file="${1:-${SINGULAR_EVENTS_FILE:-}}"
  local metrics_file="${2:-${SINGULAR_CTX_EXPERIMENT_METRICS_FILE:-}}"
  python3 - "$events_file" "$metrics_file" <<PY || true
import json, sys
$(_singular_ctx_experiment_events_py)

events_file, metrics_file = sys.argv[1], sys.argv[2]
arm_of, audited, rechecks = load_events(events_file)


def load_metrics(path):
    # taskId -> {"tokens": int, "wallClockMs": int}. Missing/unparseable -> {}.
    cost = {}
    if not path:
        return cost
    try:
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, json.JSONDecodeError):
        return cost
    if isinstance(doc, dict) and isinstance(doc.get("perTask"), list):
        rows = doc["perTask"]
    elif isinstance(doc, list):
        rows = doc
    else:
        rows = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        tid = str(row.get("taskId", ""))
        if not tid:
            continue

        def as_int(v):
            try:
                return int(v)
            except (TypeError, ValueError):
                return 0
        cost[tid] = {
            "tokens": as_int(row.get("tokens", 0)),
            "wallClockMs": as_int(row.get("wallClockMs", 0)),
        }
    return cost


metrics = load_metrics(metrics_file)

DIRECTIONAL = {"addressed", "obsolete"}
arms = {}
for arm in ARMS:
    accepted = flagged = 0
    tokens_total = wall_total = 0
    for tid, is_flagged in audited.items():
        if arm_of.get(tid) != arm:
            continue
        accepted += 1
        if is_flagged:
            flagged += 1
        m = metrics.get(tid, {})
        tokens_total += int(m.get("tokens", 0) or 0)
        wall_total += int(m.get("wallClockMs", 0) or 0)
    rate = (flagged / accepted) if accepted else 0.0
    arms[arm] = {
        "escapeRate": rate,
        "accepted": accepted,
        "flagged": flagged,
        "cost": {
            "tasks": accepted,
            "tokensTotal": tokens_total,
            "wallClockMsTotal": wall_total,
            "tokensPerTask": (tokens_total / accepted) if accepted else 0.0,
            "wallClockMsPerTask": (wall_total / accepted) if accepted else 0.0,
        },
    }

flagged_findings = directional = 0
for tid, is_flagged in audited.items():
    if not is_flagged:
        continue
    for disp in rechecks.get(tid, []):
        flagged_findings += 1
        if disp in DIRECTIONAL:
            directional += 1

artifact = {
    "schema": "singular.orchestration.ctx-experiment-report.v0",
    "arms": arms,
    "bias": {
        "flaggedFindings": flagged_findings,
        "directionalDisagreements": directional,
        "directionalDisagreementRate": (directional / flagged_findings) if flagged_findings else 0.0,
    },
}
json.dump(artifact, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
  return 0
}
