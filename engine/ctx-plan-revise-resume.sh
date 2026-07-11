#!/usr/bin/env bash
# ctx-plan-revise-resume.sh — the plan-revision-loop RESUME/FRESH strategy brick.
# Fourth brick of the executable DAG node `plan-revision-loop` (stage
# S3-plan-revision, area plancritic, layer engine_runtime, kind runtime).
#
# Implements the still-untouched requiredCompletion spine "revise verdict resumes
# the node planner with structured findings ... fresh fallback recorded": the
# engine-side revision-round strategy that decides whether a revise round RESUMES
# the persisted planner node session or runs FRESH, and records both the chosen
# strategy and the resume-refused (rc-86) fresh fallback.
#
# It reuses the integrated fail-closed planner-role decider
# gluerun_planner_resume_decide (TASK-0009) VERBATIM so a revision round resumes
# ONLY the same persisted node session those ordered gates already trust, and it
# mirrors the strategy-event convention the integrated generate-tasks.sh
# planner-resume consult hook (TASK-0011) established: a role=planner
# `context.strategy_selected` event on resume/fresh and a `context.resume_failed`
# event on the rc-86 fresh fallback. Both events additionally carry `revisesRunId`,
# marking this as the revision round (so ctx-metrics.sh can distinguish revision
# routing from the initial planning round).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-plan-revise.sh): no events, no state writes. It never owns
# engine/lib.sh, adds NO driver-file hook, and invokes NO runner.
#
# Evidence invariance / advocate-skeptic line: these functions decide and record
# only. They invoke no runner, promote or quarantine no candidate, never weaken a
# resume gate (the decision is the integrated decider's verbatim verdict — a
# `fresh <reason>` or decide-error is NEVER upgraded to `resume`), and never make
# the fresh implementation auditor bypassable. Events land only in the pinned
# GLUERUN_EVENTS_FILE.
#
# The single GLUERUN_PLAN_CRITIQUE-gated generate-tasks.sh / l1-plan-node.sh
# driver hook that wires the bounded revise -> (resume|fresh) -> re-critique ->
# approve -> import loop over a stub runner, and the test-ctx-plan-revision.sh
# full-walk, are the sanctioned final follow-up slice of this node and are OUT OF
# SCOPE here.

# The revision round's resume-vs-fresh decision. Delegates VERBATIM to the
# integrated fail-closed planner decider: same ordered gates, same single-line
# `resume <sessionId>` / `fresh <reason>` contract. Because the verdict is the
# delegate's own output, a `fresh <reason>` (or any decide-error) is NEVER
# upgraded to `resume` — a revision round resumes ONLY the same persisted planner
# node session the gates already trust. Prints EXACTLY one line; never exits
# non-zero (the delegate is fail-closed and always returns 0).
#   gluerun_plan_revise_resume_decide <session_meta> <node> <runner_basename> \
#                                     <worktree> <lineage_head>
gluerun_plan_revise_resume_decide() {
  gluerun_planner_resume_decide "$@"
}

# Records ONLY. Emits EXACTLY ONE role=planner `context.strategy_selected` event
# through gluerun_append_event carrying node, runId, `revisesRunId` (= the
# critique run being revised, marking this as the revision round), strategy
# (`resume` or `fresh`), the exact `reason`, and `sessionId` on resume. No lease
# change, no runner, no outcome mutation.
#   gluerun_plan_revise_record_strategy <node> <run_id> <revises_run_id> \
#                                       <strategy> <reason> [session_id]
gluerun_plan_revise_record_strategy() {
  local node="${1:-}" run_id="${2:-}" revises_run_id="${3:-}" \
        strategy="${4:-}" reason="${5:-}" session_id="${6:-}"

  local event_json message
  event_json="$(python3 - "$node" "$run_id" "$revises_run_id" "$strategy" "$reason" "$session_id" <<'PY'
import json, sys
node, run_id, revises_run_id, strategy, reason, session_id = sys.argv[1:7]
data = {
    "node": node,
    "runId": run_id,
    "revisesRunId": revises_run_id,
    "role": "planner",
    "strategy": strategy,
    "reason": reason,
}
# sessionId is carried only on resume (fresh has no resumed session).
if strategy == "resume":
    data["sessionId"] = session_id
print(json.dumps(data, separators=(",", ":")))
PY
)"

  if [[ "$strategy" == "resume" ]]; then
    message="plan-revision session resume strategy selected"
  else
    message="plan-revision fresh-run strategy selected"
  fi
  gluerun_append_event "context.strategy_selected" "$message" "$event_json"
  return 0
}

# Records ONLY. Emits the rc-86 fresh-fallback record: EXACTLY ONE role=planner
# `context.resume_failed` event carrying node, runId, revisesRunId, and the
# refused sessionId, so the resume-refused -> fresh transition of a revision round
# is observable to ctx-metrics.sh. This is the "fresh fallback recorded" predicate
# of the node requiredCompletion. No lease change, no runner, no outcome mutation.
#   gluerun_plan_revise_record_resume_failed <node> <run_id> <revises_run_id> \
#                                            <session_id>
gluerun_plan_revise_record_resume_failed() {
  local node="${1:-}" run_id="${2:-}" revises_run_id="${3:-}" session_id="${4:-}"

  local event_json
  event_json="$(python3 - "$node" "$run_id" "$revises_run_id" "$session_id" <<'PY'
import json, sys
node, run_id, revises_run_id, session_id = sys.argv[1:5]
print(json.dumps({
    "node": node,
    "runId": run_id,
    "revisesRunId": revises_run_id,
    "role": "planner",
    "sessionId": session_id,
}, separators=(",", ":")))
PY
)"

  gluerun_append_event "context.resume_failed" "plan-revision planner resume failed; re-running fresh" "$event_json"
  return 0
}
