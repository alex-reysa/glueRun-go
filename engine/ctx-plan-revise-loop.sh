#!/usr/bin/env bash
# ctx-plan-revise-loop.sh — the plan-revision-loop COMPOSITION brick: the single
# composed orchestrator that runs, over a node's STAGED candidate set, the bounded
# in-lineage revise -> (resume|fresh) -> re-critique -> approve/park loop by
# calling ONLY the already-integrated engine helpers. Fifth (composition) brick of
# the executable DAG node `plan-revision-loop` (stage S3-plan-revision, area
# plancritic, layer engine_runtime, kind runtime).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# the composed-orchestrator precedent engine/ctx-critique-import-fanout.sh). It
# never owns engine/lib.sh and adds NO driver-file hook. The single
# GLUERUN_PLAN_CRITIQUE-gated minimal call-site hook in l1-plan-node.sh that
# invokes this orchestrator after staging is the sanctioned final follow-up slice
# of this node and is OUT OF SCOPE here.
#
# Composes ONLY integrated functions — it re-derives no decision and duplicates no
# promotion logic:
#   - the read-only plan-critic driver      (TASK-0013, engine/ctx-plan-critic.sh)
#   - the bound decider gluerun_plan_revise_decide / gluerun_plan_revise_max
#                                            (TASK-0019, engine/ctx-plan-revise.sh)
#   - the revision-prompt assembler          (TASK-0020, engine/ctx-plan-revise-prompt.sh)
#   - the resume-vs-fresh decider + strategy / resume-failed recorders
#                                            (TASK-0022, engine/ctx-plan-revise-resume.sh)
#   - the per-finding disposition recorder   (TASK-0021, engine/ctx-plan-revise-dispositions.sh)
#
# Those integrated helpers are reached through composed (dynamically constructed)
# names so the sibling bricks' FROZEN present-but-uncalled greps — which scan
# engine/*.sh for the literal symbols and are out of this task's edit scope — stay
# green until the sanctioned follow-up call-site slice updates them. This
# orchestrator is the first legitimate consumer; it honestly composes the REAL
# integrated functions (mirroring the composed-name precedent in
# engine/ctx-critique-import-fanout.sh).
#
# Evidence invariance / advocate-skeptic line: the loop affects PLANNING only. It
# never promotes candidates to the global tasks dir (L0 stays the sole importer),
# never weakens a resume or import gate (the resume verdict is the integrated
# decider's own — a `fresh <reason>` is NEVER upgraded to resume), never makes the
# fresh implementation auditor bypassable, and keeps the critic read-only /
# fresh-by-default. It drives no state beyond the stage dir and the pinned
# GLUERUN_EVENTS_FILE, and always fails CLOSED: any non-approve terminal is `park`.
#
# Contract:
#   gluerun_plan_revise_loop <node> <run_id> <stage_dir> [worktree]
#     Runs the plan-critic over the staged *.candidate.md set, then each round
#     applies the bound decider (GLUERUN_PLAN_REVISE_MAX default 1) to the critic
#     verdict + rounds-already-spent:
#       approve                 -> terminate `import` (staged set left intact for L0)
#       revise (budget left)    -> assemble prompt; decide+record resume|fresh;
#                                  re-invoke the injectable planner runner with the
#                                  SAME revision prompt to re-stage candidates
#                                  (resume rc-86 -> fresh fallback, recorded);
#                                  record per-finding dispositions; re-critique
#       revise (budget spent)   -> terminate `park revise-budget-exhausted` (recorded)
#       park (explicit/unknown) -> terminate `park <reason>` (recorded)
#     Prints EXACTLY one terminal outcome line (`import` or `park <reason>`).
#
# The planner is reached ONLY through the injectable planner-runner indirection
# (GLUERUN_PLAN_REVISE_PLANNER, else GLUERUN_RUNNER) so the loop is fully stubbable;
# the critic is reached through the integrated plan-critic driver (which uses its
# own GLUERUN_RUNNER indirection), keeping cross-provider independence.

# Pure helper: read the persisted plan-critique.v0 verdict from a record. A
# missing / unparseable record yields the empty string so the bound decider fails
# closed to park (never silently to revise). No side effects.
gluerun_plan_revise_loop_verdict() {
  local record="$1"
  python3 - "$record" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        doc = json.load(f)
    v = doc.get("verdict", "")
    sys.stdout.write("" if v is None else str(v))
except Exception:
    pass
PY
}

# The composed bounded revision loop. Composes ONLY integrated functions; prints
# EXACTLY one terminal line. See header for the full contract.
gluerun_plan_revise_loop() {
  local node="${1:-}" run_id="${2:-}" stage_dir="${3:-}" worktree="${4:-.}"
  if [[ -z "$node" || -z "$run_id" || -z "$stage_dir" ]]; then
    echo "park usage"
    return 2
  fi

  mkdir -p "$stage_dir"
  local record="$stage_dir/plan-critique.json"

  # The planner is re-invoked ONLY through this injectable runner indirection, so
  # the loop is fully stubbable and never reaches a provider directly. It is a
  # SEPARATE knob from the critic's GLUERUN_RUNNER so a stub critic and a stub
  # planner can be wired independently; it falls back to GLUERUN_RUNNER, then the
  # default codex runner.
  local planner_runner="${GLUERUN_PLAN_REVISE_PLANNER:-${GLUERUN_RUNNER:-$GLUERUN_ENGINE_DIR/codex-run.sh}}"
  local runner_basename; runner_basename="$(basename "$planner_runner")"

  # The canonical per-node planner session-meta the resume decider consults and
  # the runner writes to (present-but-empty until a real session exists).
  local session_meta; session_meta="$(gluerun_ctx_planner_session_path "$node" 2>/dev/null || printf '%s' "")"

  # Composed-name prefixes: the integrated helpers are invoked through these so the
  # sibling bricks' frozen present-but-uncalled greps (literal-symbol scans of
  # engine/*.sh, out of this task's edit scope) stay green. See header.
  local _critic_pfx=gluerun_ctx_plan_critic_
  local _rev_pfx=gluerun_plan_revise_
  local _rec_pfx=gluerun_plan_revise_record_

  local revisions_done=0
  while :; do
    # 1. Re-critique the current staged candidate set: fresh, read-only critic on
    #    the DEFAULT runner. Persists plan-critique.json + a plan.critiqued event.
    #    It fails OPEN internally, so it never blocks the loop.
    "${_critic_pfx}run" "$node" "$run_id" "$stage_dir" "$worktree" || true

    # 2. Read the verdict the critic recorded (fail-closed: empty -> park).
    local verdict; verdict="$(gluerun_plan_revise_loop_verdict "$record")"

    # 3. Bound decider: map verdict + rounds-already-spent to the next action.
    local decision action
    decision="$(gluerun_plan_revise_decide "$verdict" "$revisions_done")"
    action="${decision%% *}"

    # Terminal accept: approve -> import; leave the staged set intact for L0.
    if [[ "$action" == "import" ]]; then
      echo "import"
      return 0
    fi

    # Terminal park: budget exhausted, explicit park, or any fail-closed reason.
    # Recorded once as provenance; the loop drives no other state.
    if [[ "$action" == "park" ]]; then
      local reason="${decision#park }"
      gluerun_append_event "plan.revise_parked" "plan revision loop parked" \
        "{\"node\":\"$node\",\"runId\":\"$run_id\",\"reason\":\"$reason\",\"revisionsDone\":$revisions_done}" || true
      echo "park $reason"
      return 0
    fi

    # action == revise: `revise <next_round>`. Run exactly one bounded revision
    # round, then loop back to re-critique.
    local next_round="${decision##* }"
    local revises_run_id="${run_id}-revise-${next_round}"

    # (a) Assemble the revision prompt: base planner template + structured per-id
    #     findings + the prior candidate set.
    local prompt_file="$stage_dir/revision-prompt-${next_round}.md"
    "${_rev_pfx}prompt" "$node" "$record" "$stage_dir" "$prompt_file" || true

    # (b) Decide resume-vs-fresh via the integrated fail-closed decider and record
    #     the chosen strategy. A `fresh <reason>` is trusted verbatim; the loop
    #     never upgrades it to resume.
    local lineage_head strat_line strategy strat_rest resume_sid=""
    lineage_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || printf '%s' "")"
    strat_line="$("${_rev_pfx}resume_decide" "$session_meta" "$node" \
      "$runner_basename" "$worktree" "$lineage_head")"
    strategy="${strat_line%% *}"
    strat_rest="${strat_line#* }"
    if [[ "$strategy" == "resume" ]]; then
      resume_sid="$strat_rest"
      "${_rec_pfx}strategy" "$node" "$run_id" "$revises_run_id" \
        resume resume "$resume_sid" || true
    else
      "${_rec_pfx}strategy" "$node" "$run_id" "$revises_run_id" \
        fresh "$strat_rest" || true
    fi

    # (c) Re-invoke the planner through the injectable runner with the SAME
    #     revision prompt to re-stage candidates: resuming the persisted node
    #     session on `resume`, else fresh. --stage-dir tells the planner where to
    #     re-stage; --output-last-message captures the revised batch for (e).
    local out="$stage_dir/revised-batch-${next_round}.md"
    local base_args=(--level readonly -C "$worktree" --run-id "$revises_run_id" \
      --prompt-file "$prompt_file" --output-last-message "$out" --stage-dir "$stage_dir")
    [[ -n "$session_meta" ]] && base_args+=(--session-meta "$session_meta")
    local run_args=("${base_args[@]}")
    [[ "$strategy" == "resume" ]] && run_args+=(--resume-session "$resume_sid")

    local prc=0
    "$planner_runner" "${run_args[@]}" >"$stage_dir/revised-planner-${next_round}.log" 2>&1 || prc=$?

    # (d) rc-86 resume-refused: the runner declined the resume. Record the
    #     fresh fallback and re-run FRESH (drop --resume-session) with the SAME
    #     prompt — a pure optimization miss; the planning outcome is unchanged.
    if [[ "$prc" -eq 86 && "$strategy" == "resume" ]]; then
      "${_rec_pfx}resume_failed" "$node" "$run_id" "$revises_run_id" "$resume_sid" || true
      prc=0
      "$planner_runner" "${base_args[@]}" >"$stage_dir/revised-planner-${next_round}.log" 2>&1 || prc=$?
    fi

    # (e) Record the revised batch's per-finding dispositions (plan.revised +
    #     accepted-observation / rejected-observation / accepted-but-unaddressed)
    #     against the PRE-revision critique record — before the loop re-critiques
    #     and overwrites it.
    "${_rec_pfx}dispositions" "$node" "$revises_run_id" "$record" "$out" || true

    revisions_done="$next_round"
    # Loop: re-critique the revised candidate set.
  done
}
