#!/usr/bin/env bash
# ctx-experiment-strategy.sh — read-only SECONDARY raw-metrics extractor for the
# `experiment-run` executable DAG node (layer evaluation). Complements (does NOT
# duplicate) engine/ctx-experiment-report.sh: that brick ships the primary
# escape-rate / per-arm cost / bias measurements; this one ships the routing-
# derived resume/rehydrate hit rates and their gate-refusal reason mix.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior
# (OFF-parity intrinsic, mirroring the engine/ctx-metrics.sh and
# engine/ctx-experiment-report.sh idiom). It does NOT edit
# engine/ctx-experiment-report.sh or any other pre-existing file.
#
# STRICTLY READ-ONLY: every function reads only an events log (events.ndjson,
# whose relevant records are `context.strategy_selected` {taskId, role in
# implementer|reviewer|planner, attempt, strategy in resume|rehydrate|fresh,
# reason (the routing gate outcome / refusal reason)}, `context.resume_failed`
# {taskId, ...} (resume was chosen then mechanically failed and fell back to
# fresh), and `ctx.arm_assigned` {taskId, arm in A|B} for per-arm grouping). It
# creates, moves, or mutates NOTHING — no run artifact, index, event, lease, or
# task file. This is measurement code the operator's experiment-report.md
# references at merge; it neither declares nor gates node completion.
#
# Measurement definitions:
#   * Strategy selection: one `context.strategy_selected` event = one routing
#     decision. The hit-rate denominator is routing decisions, NEVER accepted
#     tasks.
#   * Resume hit rate  = resume    selections / total selections (in the slice).
#   * Rehydrate hit rate = rehydrate selections / total selections (in the slice).
#     Slices: overall, per arm (A/B, joined to `ctx.arm_assigned` via taskId;
#     A = control / M0 knob-state, B = treatment), and per role.
#   * Gate-refusal reason mix: the `reason` values carried on NON-resume
#     (`fresh` + `rehydrate`) selections — the routing-gate reasons that declined
#     resume — tallied into a stable, sorted reason-to-count map. A missing/empty
#     reason buckets under a stable `unspecified` key, never dropped.
#   * resumeFailed: a distinct count of `context.resume_failed` events (resume
#     chosen then mechanically failed).
#
# Evidence invariance / advocate-skeptic line: the aggregator only MEASURES
# routing outcomes; it confers no independence and NEVER reclassifies a tainted
# resume/rehydrate selection as fresh or vice versa. Tallies partition selections
# exactly by their recorded `strategy`.
#
# Fail-safe: missing / empty inputs yield a well-formed ZEROED result and a zero
# exit, never an error or partial output.
#
# Public entry points:
#   gluerun_ctx_experiment_hit_rates [events_file]
#     Prints {"overall":SLICE, "byArm":{"A":SLICE,"B":SLICE},
#             "byRole":{"implementer":SLICE,"planner":SLICE,"reviewer":SLICE}}
#     where SLICE = {total, resume, rehydrate, resumeHitRate, rehydrateHitRate}.
#   gluerun_ctx_experiment_refusal_mix [events_file]
#     Prints {"reasonMix":{<reason>:count,...}, "resumeFailed":int}.
#   gluerun_ctx_experiment_strategy_json [events_file]
#     Emits ONE deterministic, sorted-key JSON object conforming to
#     gluerun.orchestration.ctx-experiment-strategy.v0, merging the per-arm and
#     per-role hit rates with the gate-refusal reason mix. Default:
#     events_file=$GLUERUN_EVENTS_FILE.

# --- shared read-only parser -------------------------------------------------
# Emits Python that, when included, defines load_events(path) returning:
#   selections : list of {"taskId","role","strategy","reason"} (one per
#                context.strategy_selected event, in file order)
#   arm_of     : taskId -> "A"/"B" (last assignment wins deterministically)
#   resume_failed : int count of context.resume_failed events
# plus the ROLES / ARMS / STRATEGIES constants and the slice_of() helper. Pure.
_gluerun_ctx_experiment_strategy_py() {
  cat <<'PY'
import json

ARMS = ("A", "B")
ROLES = ("implementer", "planner", "reviewer")
UNSPECIFIED = "unspecified"


def load_events(events_file):
    selections = []      # list of {taskId, role, strategy, reason}
    arm_of = {}          # taskId -> "A"/"B"
    resume_failed = 0
    if not events_file:
        return selections, arm_of, resume_failed
    try:
        f = open(events_file, "r", encoding="utf-8")
    except OSError:
        return selections, arm_of, resume_failed
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
            if typ == "ctx.arm_assigned":
                tid = str(data.get("taskId", ""))
                arm = str(data.get("arm", ""))
                if tid and arm in ARMS:
                    arm_of[tid] = arm
            elif typ == "context.strategy_selected":
                selections.append({
                    "taskId": str(data.get("taskId", "")),
                    "role": str(data.get("role", "")),
                    "strategy": str(data.get("strategy", "")),
                    "reason": data.get("reason", ""),
                })
            elif typ == "context.resume_failed":
                resume_failed += 1
    return selections, arm_of, resume_failed


def slice_of(sels):
    # sels: iterable of selection dicts. Denominator is routing decisions.
    total = resume = rehydrate = 0
    for s in sels:
        total += 1
        strat = s.get("strategy")
        if strat == "resume":
            resume += 1
        elif strat == "rehydrate":
            rehydrate += 1
    return {
        "total": total,
        "resume": resume,
        "rehydrate": rehydrate,
        "resumeHitRate": (resume / total) if total else 0.0,
        "rehydrateHitRate": (rehydrate / total) if total else 0.0,
    }


def hit_rates(selections, arm_of):
    by_arm = {arm: slice_of([s for s in selections if arm_of.get(s["taskId"]) == arm])
              for arm in ARMS}
    by_role = {role: slice_of([s for s in selections if s["role"] == role])
               for role in ROLES}
    return {
        "overall": slice_of(selections),
        "byArm": by_arm,
        "byRole": by_role,
    }


def refusal_mix(selections, resume_failed):
    reason_mix = {}
    for s in selections:
        if s.get("strategy") == "resume":
            continue  # only NON-resume selections carry gate-refusal reasons
        reason = s.get("reason", "")
        key = str(reason).strip() if reason is not None else ""
        if not key:
            key = UNSPECIFIED
        reason_mix[key] = reason_mix.get(key, 0) + 1
    return {"reasonMix": reason_mix, "resumeFailed": resume_failed}
PY
}

# Resume / rehydrate hit rates, sliced overall + per arm + per role. Fail-safe.
gluerun_ctx_experiment_hit_rates() {
  local events_file="${1:-${GLUERUN_EVENTS_FILE:-}}"
  python3 - "$events_file" <<PY || true
import json, sys
$(_gluerun_ctx_experiment_strategy_py)

selections, arm_of, _ = load_events(sys.argv[1])
json.dump(hit_rates(selections, arm_of), sys.stdout, sort_keys=True)
PY
  return 0
}

# Gate-refusal reason mix + distinct resume_failed count. Fail-safe.
gluerun_ctx_experiment_refusal_mix() {
  local events_file="${1:-${GLUERUN_EVENTS_FILE:-}}"
  python3 - "$events_file" <<PY || true
import json, sys
$(_gluerun_ctx_experiment_strategy_py)

selections, _, resume_failed = load_events(sys.argv[1])
json.dump(refusal_mix(selections, resume_failed), sys.stdout, sort_keys=True)
PY
  return 0
}

# Composed secondary-metrics artifact. Merges the per-arm and per-role hit rates
# with the gate-refusal reason mix into one deterministic sorted-key JSON object.
# Fail-safe.
gluerun_ctx_experiment_strategy_json() {
  local events_file="${1:-${GLUERUN_EVENTS_FILE:-}}"
  python3 - "$events_file" <<PY || true
import json, sys
$(_gluerun_ctx_experiment_strategy_py)

selections, arm_of, resume_failed = load_events(sys.argv[1])
artifact = {
    "schema": "gluerun.orchestration.ctx-experiment-strategy.v0",
    "hitRates": hit_rates(selections, arm_of),
    "refusalMix": refusal_mix(selections, resume_failed),
}
json.dump(artifact, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
  return 0
}
