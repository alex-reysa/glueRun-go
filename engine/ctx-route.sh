#!/usr/bin/env bash
# ctx-route.sh — the composed orchestrator spine of the routing-module node: the
# leaf-before-orchestrator step this node deferred to last, exactly as
# engine/ctx-plan-revise-loop.sh (TASK-0023) composed its leaves after they were
# integrated. It WRAPS (does not rewrite) the two baseline resume deciders and
# frames their `resume`/`fresh` verdict as one of the five routing strategies,
# adding the taint/independence pin and the three fail-closed resume gates on top.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines a new
# function only; NO existing engine path invokes it, so with GLUERUN_CTX_ROUTING
# OFF (default 0) and the file present-but-uncalled the engine is byte-identical
# to the legacy decide paths. The l1-drive.sh second-wave hook and the
# ctx-metrics.sh strategy/outcome split are later slices and are OUT OF SCOPE.
#
#   gluerun_ctx_route <role> <step> <meta> <key> <run_id> <runner> <prompt_sha> \
#                     <worktree> <lineage_head> <transcript> <lease_key> \
#                     <base_sha> [role-relevant-paths...]
#
# Prints EXACTLY one line `<strategy> <arg-or-reason>` where <strategy> is one of
# continue|resume|fork|fresh|rehydrate, every decision carrying its reason (or,
# for resume, the session id). Never exits non-zero. `fork` and `continue`/
# `rehydrate` are reserved in the alphabet; the wrapped deciders only ever emit
# `resume`/`fresh`, so this spine emits `resume` or `fresh` this stage.
#
# Argument roles:
#   <role>          task role (implementer/reviewer/advocate/skeptic/…) or planner
#   <step>          the step being routed (final-audit/paired-audit are pinned)
#   <meta>          session-meta path handed to the wrapped decider
#   <key>           task role -> taskId; planner role -> node
#   <run_id>        task role -> runId; ignored for planner
#   <runner>        runner basename (decider gate)
#   <prompt_sha>    task-role prompt sha (decider gate); ignored for planner
#   <worktree>      worktree for the lineage / diff gates
#   <lineage_head>  current target-branch head (decider lineage + diff-gate head)
#   <transcript>    provider session transcript path (window gate)
#   <lease_key>     generalized session-lease key (lease gate)
#   <base_sha>      headShaAtCreate for the diff gate (churn base; head=lineage_head)
#   [paths...]      role-relevant pathspec scoping the diff gate
#
# Composition when GLUERUN_CTX_ROUTING=1 (fail-closed, first refusal wins):
#   1. Independence pin FIRST (gluerun_ctx_route_independence_admit): an
#      independence-required step (final-audit, paired-audit) is PINNED to fresh —
#      a would-be resume/rehydrate is refused as `fresh tainted`, structurally,
#      with no knob able to reroute it.
#   2. Otherwise delegate the baseline resume/fresh decision to the role's wrapped
#      decider, and on a would-be `resume` apply the additional resume gates, each
#      downgrading to `fresh <reason>`: a live generalized session lease
#      (`fresh session-lease`), window pressure (`fresh window-pressure`), diff
#      volume (`fresh diff-volume`).
# Routing is composed boolean gates plus the wrapped decider, never a numeric
# score. The gates only ADD refusals; none can turn a fresh-required decision into
# a resumable one.
gluerun_ctx_route() {
  local role="$1" step="$2" meta="$3" key="$4" run_id="$5" runner="$6" \
        prompt_sha="$7" worktree="$8" lineage_head="$9"
  shift 9 || true
  local transcript="${1:-}" lease_key="${2:-}" base_sha="${3:-}"
  shift 3 2>/dev/null || true
  # Remaining "$@" is the role-relevant pathspec for the diff gate (may be empty).

  # --- Baseline resume/fresh decision from the role's WRAPPED decider ----------
  # The router adds only the lease/window/diff gates and the strategy/taint
  # framing; the baseline resume/fresh gates come entirely from these functions.
  local baseline strategy
  case "$role" in
    planner)
      baseline="$(gluerun_planner_resume_decide "$meta" "$key" "$runner" "$worktree" "$lineage_head")"
      ;;
    *)
      baseline="$(gluerun_session_resume_decide "$meta" "$role" "$key" "$run_id" "$runner" "$prompt_sha" "$worktree" "$lineage_head")"
      ;;
  esac
  strategy="${baseline%% *}"

  # --- OFF-parity: byte-identical to the legacy decide path --------------------
  # With the flag unset or != 1 the router emits the decider's line VERBATIM — no
  # gate, no independence pin, no strategy outside {resume,fresh}.
  if [[ "${GLUERUN_CTX_ROUTING:-0}" != "1" ]]; then
    printf '%s\n' "$baseline"
    return 0
  fi

  # --- 1. Independence pin FIRST (structural; no knob reroutes it) -------------
  local admit
  admit="$(gluerun_ctx_route_independence_admit "$strategy" "$role" "$step")"
  case "$admit" in
    admit)
      : # step admissible for this strategy; fall through to the resume gates
      ;;
    "refuse tainted")
      # A would-be resume/rehydrate at an independence-required step.
      printf 'fresh tainted\n'; return 0
      ;;
    *)
      # `refuse pinned-fresh` (or any unrecognized refusal) — fail closed to fresh.
      printf 'fresh pinned-fresh\n'; return 0
      ;;
  esac

  # --- 2. Only a would-be `resume` is subject to the additional gates ----------
  # Any other baseline strategy (fresh, and the reserved continue/fork/rehydrate)
  # passes through with its reason intact — the gates only refuse resume.
  if [[ "$strategy" != "resume" ]]; then
    printf '%s\n' "$baseline"
    return 0
  fi

  # --- Resume gates, fail-closed, first refusal wins ---------------------------
  # Each refusal is a refused-resume lineage-continuation step: emit its reason
  # through the rehydrate wire-in, which upgrades `fresh <reason>` to `rehydrate
  # <reason>` only behind GLUERUN_REHYDRATE=1 with a non-empty run_dir packet and
  # otherwise stays byte-identical to the bare `fresh <reason>` line.
  # (a) live generalized session lease: another fanout is using the role's session.
  local lease_path
  lease_path="$(gluerun_ctx_route_session_lease_path "$role" "$lease_key")"
  if [[ -n "$lease_path" ]] && gluerun_ctx_route_session_lease_live "$lease_path"; then
    _gluerun_ctx_route_refuse_resume session-lease "$role" "$step" "$meta" "$key"; return 0
  fi
  # (b) window pressure: the session transcript is over the usage threshold.
  if [[ "$(gluerun_ctx_route_window_gate "$role" "$transcript")" != "pass" ]]; then
    _gluerun_ctx_route_refuse_resume window-pressure "$role" "$step" "$meta" "$key"; return 0
  fi
  # (c) diff volume: role-relevant churn since headShaAtCreate is over the limit.
  if [[ "$(gluerun_ctx_route_diff_gate "$role" "$worktree" "$base_sha" "$lineage_head" "$@")" != "pass" ]]; then
    _gluerun_ctx_route_refuse_resume diff-volume "$role" "$step" "$meta" "$key"; return 0
  fi

  # Every gate passed -> the wrapped decider's `resume <id>` stands, verbatim.
  printf '%s\n' "$baseline"
  return 0
}

# _gluerun_ctx_route_refuse_resume <reason> <role> <step> <meta> <key>
#
# The rehydrate wire-in for a refused-resume lineage step. Prints exactly one
# line: `rehydrate <reason>` when GLUERUN_REHYDRATE=1 and the manifest chosen for
# this step yields at least one surviving rehydration source, otherwise the byte-
# identical `fresh <reason>` this spine emitted before the wire-in. The
# manifest composition is guarded behind GLUERUN_REHYDRATE so the OFF path spawns
# no extra work; the decision leaf (which independently re-checks OFF-parity, the
# independence pin, and the empty-packet guard) makes the final call.
#
# WHICH manifest the leaf sees is delegated to the flat-vs-subgraph selector
# gluerun_ctx_route_subgraph_manifest (engine/ctx-route-subgraph.sh): with
# GLUERUN_CTX_SUBGRAPH_REHYDRATE default 0 it returns the flat manifest and this
# path is byte-identical to today; only with the subgraph knob on, the treatment
# arm, and a present non-empty graph corpus does it hand the leaf the graph-
# selected packet instead of the flat capsule. <key> is the taskId the route
# contract already carries for task roles and is threaded here so the selector can
# resolve the deterministic task node id.
#
# Appends no events and never exits non-zero — the spine keeps its one-line,
# no-event contract, and `rehydrate` stays tainted.
_gluerun_ctx_route_refuse_resume() {
  local reason="$1" role="$2" step="$3" meta="$4" key="${5:-}"

  # OFF-parity: with the knob unset or != 1, stay byte-identical to `fresh
  # <reason>` and do NO resolver/manifest work at all.
  if [[ "${GLUERUN_REHYDRATE:-0}" != "1" ]]; then
    printf 'fresh %s\n' "$reason"; return 0
  fi

  # Select the manifest (flat by default; graph-selected only under the subgraph
  # knob + treatment arm + present corpus) and let the decision leaf render the
  # verdict.
  local manifest
  manifest="$(gluerun_ctx_route_subgraph_manifest "$reason" "$role" "$step" "$meta" "$key")"

  gluerun_ctx_route_rehydrate_decide "$reason" "$role" "$step" "$manifest"
  return 0
}
