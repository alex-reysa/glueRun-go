#!/usr/bin/env bash
# ctx-plan-revise.sh — the plan-revision-loop BOUND AUTHORITY: a pure,
# deterministic decider mapping a plan-critic verdict plus the number of revision
# rounds already spent to the next loop action, bounded by SINGULAR_PLAN_REVISE_MAX
# (default 1).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-planner-resume.sh and engine/ctx-critique-import.sh). It never owns
# engine/lib.sh and adds no driver-file hook.
#
# This is the fail-closed authority the later planner-re-invocation slice consults
# for whether to revise, park, or import. It implements the requiredCompletion
# predicate "bounded by SINGULAR_PLAN_REVISE_MAX (default 1) ... exhausted budget
# with a still-non-approve verdict park". The SINGULAR_PLAN_CRITIQUE-gated planner
# re-invocation resuming the persisted node session, the rc-86 fresh-fallback
# record, the per-finding disposition events (plan.revised with revisesRunId),
# and the generate-tasks.sh / l1-plan-node.sh driver hooks are the sanctioned
# follow-up slices of this node and are OUT OF SCOPE here.
#
# Public entry points (pure; no side effects, no events, no state writes):
#   singular_plan_revise_max
#     Print the effective revision-round bound. Reads SINGULAR_PLAN_REVISE_MAX,
#     defaulting to 1 when unset or empty. A set-but-invalid value is printed
#     verbatim so the decider can reject it fail-closed (it never silently
#     coerces a bad bound into the default).
#   singular_plan_revise_decide <verdict> <revisions_done>
#     Print EXACTLY one line and ALWAYS exit 0:
#       verdict=approve                          -> `import`
#       verdict=revise,  revisions_done < max    -> `revise <revisions_done+1>`
#       verdict=revise,  revisions_done >= max   -> `park revise-budget-exhausted`
#       verdict=park (explicit terminal)         -> `park park`
#       empty / unknown verdict                  -> `park <reason>`
#       non-integer / negative revisions_done    -> `park <reason>`
#       non-integer / negative effective max     -> `park <reason>`
#     Fail-closed (evidence invariance): the function NEVER resolves ambiguity to
#     `revise`, so no unbounded revision path can exist.

# Pure helper centralizing the default-1 bound. Empty or unset -> 1. A set value
# (even an invalid one) is echoed verbatim; the decider validates it and fails
# closed to `park` rather than coercing a bad bound into a silent default.
singular_plan_revise_max() {
  local raw="${SINGULAR_PLAN_REVISE_MAX:-}"
  if [[ -z "$raw" ]]; then
    printf '1'
  else
    printf '%s' "$raw"
  fi
}

# The plan-revision-loop decider. Pure: reads only its two arguments and the
# SINGULAR_PLAN_REVISE_MAX knob; prints one line; always exits 0. See header for
# the full contract.
singular_plan_revise_decide() {
  local verdict="${1-}"
  local revisions_done="${2-}"

  # approve is the terminal accept: the loop stops and the batch proceeds to
  # import, independent of the round count.
  if [[ "$verdict" == "approve" ]]; then
    printf 'import\n'
    return 0
  fi

  # revise is the only branch that can request another round, and only within
  # the bound. Everything here fails CLOSED to `park` — never to `revise`.
  if [[ "$verdict" == "revise" ]]; then
    # A non-integer or negative round count is indeterminate budget -> park.
    if [[ ! "$revisions_done" =~ ^[0-9]+$ ]]; then
      printf 'park bad-revisions\n'
      return 0
    fi
    # A non-integer or negative effective bound is an untrustworthy limit -> park.
    local max; max="$(singular_plan_revise_max)"
    if [[ ! "$max" =~ ^[0-9]+$ ]]; then
      printf 'park bad-max\n'
      return 0
    fi
    # Budget remaining -> revise the next round; else the budget is exhausted and
    # a still-non-approve verdict with no budget left parks (never another revise).
    if (( revisions_done < max )); then
      printf 'revise %d\n' "$(( revisions_done + 1 ))"
    else
      printf 'park revise-budget-exhausted\n'
    fi
    return 0
  fi

  # An explicit terminal park verdict parks under its own token.
  if [[ "$verdict" == "park" ]]; then
    printf 'park park\n'
    return 0
  fi

  # Fail-closed: an empty or unknown verdict resolves to park under a stable
  # reason — never to revise.
  if [[ -z "$verdict" ]]; then
    printf 'park empty-verdict\n'
  else
    printf 'park unknown-verdict\n'
  fi
  return 0
}
