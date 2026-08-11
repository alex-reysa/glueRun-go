#!/usr/bin/env bash
# ctx-route-drive.sh — the driver-facing routing adapter: the minimal seam the
# running engine/l1-drive.sh delegates its two live session-resume decisions into
# (the implementer site at l1-drive.sh:436 and the reviewer/auditor site at :675).
# It is the second-wave l1-drive.sh hook the routing-module node owns (stage-5, the
# routing hook chaining behind the paired-audit hook), wiring the integrated
# singular_ctx_route strategy dispatcher (engine/ctx-route.sh, composing the
# window-pressure and diff-volume gates, the generalized session lease, and the
# taint independence pin) into the driver behind SINGULAR_CTX_ROUTING (default 0).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). It adds NO new
# decision logic: the OFF/ON gating and the wrapped legacy decider already live
# inside singular_ctx_route. Its ONLY job is to assemble, from what each call-site
# already holds, the per-role routing context the spine needs — the session
# transcript path (window gate), the generalized session-lease key (lease gate),
# and the diff base sha (diff gate) — and delegate. So with SINGULAR_CTX_ROUTING
# unset or != 1 (default 0) it returns the legacy decider's line verbatim and the
# driver is byte-identical to before this wire-in at both decision sites.
#
# singular_ctx_route_decide <role> <step> <meta> <key> <run_id> <runner> \
#                          <prompt_sha> <worktree> <lineage_head>
#
# The <role>/<key>/<run_id>/<runner>/<prompt_sha>/<worktree>/<lineage_head>
# arguments are exactly what the legacy call-site handed singular_session_resume_decide
# (key == taskId for the task roles), so the OFF path is a pure rename. <step> is
# the routing step (implement at the implementer site; final-audit at the reviewer
# site) that the independence pin consults. Prints EXACTLY one line
# `<strategy> <arg-or-reason>` and never exits non-zero (delegated from the spine).
#
# Assembled routing context (all derived, nothing new asked of the call-site):
#   transcript  <run_dir>/worker-codex.log for implementer, <run_dir>/audit-codex.log
#               for reviewer, <run_dir>/<role>-codex.log otherwise — the persisted
#               provider-run log is the deterministic session-size proxy the window
#               gate estimates from; run_dir = dirname(meta). A missing/empty log
#               fails the window gate closed (fresh), matching the safe default.
#   lease_key   the role's session-lease key == <key> (taskId for the task roles);
#               the generalized lease path is <state>/sessions/<role>/<key>.lease.
#   base_sha    headShaAtCreate read from the meta — the churn base for the diff
#               gate (head = lineage_head). Empty when the meta is absent/unreadable,
#               which fails the diff gate closed (fresh); at that point the wrapped
#               decider has already gone fresh anyway (no-session), so OFF-parity and
#               the ON path agree.
# No role-relevant pathspec is supplied, so the diff gate measures the whole tree.
singular_ctx_route_decide() {
  local role="$1" step="$2" meta="$3" key="$4" run_id="$5" runner="$6" \
        prompt_sha="$7" worktree="$8" lineage_head="$9"

  local run_dir transcript lease_key base_sha
  run_dir="$(dirname "$meta")"
  case "$role" in
    implementer) transcript="$run_dir/worker-codex.log" ;;
    reviewer)    transcript="$run_dir/audit-codex.log" ;;
    *)           transcript="$run_dir/${role}-codex.log" ;;
  esac
  lease_key="$key"
  base_sha="$(singular_json_field "$meta" headShaAtCreate 2>/dev/null || true)"

  singular_ctx_route "$role" "$step" "$meta" "$key" "$run_id" "$runner" \
    "$prompt_sha" "$worktree" "$lineage_head" "$transcript" "$lease_key" "$base_sha"
}
