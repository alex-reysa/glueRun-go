#!/usr/bin/env bash
# ctx-route-rehydrate.sh — the pure rehydrate-vs-fresh routing decision leaf
# (stage S5-routing, node `rehydrate-path`, layer engine_runtime). Auto-sourced
# once by the ctx-loader block in lib.sh (it matches the engine/ctx-*.sh glob).
# This file DEFINES a new function only and is present-but-uncalled by every
# existing engine/CLI/driver path, so with it sourced the engine stays
# byte-identical to current behavior (OFF-parity by construction, mirroring
# engine/ctx-route-window.sh / ctx-route-taint.sh / ctx-route-strategy.sh).
#
# The seam it models: in the later engine/ctx-route.sh spine a would-be `resume`
# refused by a resume gate is emitted as `fresh session-lease`, `fresh
# window-pressure`, or `fresh diff-volume`. On exactly those refused-resume
# lineage-continuation steps, and only behind GLUERUN_REHYDRATE=1, this decision
# upgrades the bare `fresh <reason>` to `rehydrate <reason>` (fresh session +
# injected durable context). The engine/ctx-route.sh spine wire-in (calling this
# leaf on a resume-gate refusal and stamping the packet manifest into the
# strategy event) and the l1-drive.sh packet-injection hook are SEPARATE later
# slices and are OUT OF SCOPE here.
#
# gluerun_ctx_route_rehydrate_decide <refusal-reason> <role> <step> <manifest-json>
#
# Prints EXACTLY one line — `rehydrate <refusal-reason>` or `fresh
# <refusal-reason>` — carrying the ORIGINAL refusal reason forward. A PURE
# predicate: appends no events, writes/renames/deletes no files, and never exits
# non-zero on well-formed input.
#
#   - OFF-parity: when GLUERUN_REHYDRATE is unset or != 1, it ALWAYS prints
#     `fresh <refusal-reason>` — byte-identical to the reason line
#     engine/ctx-route.sh emits today.
#   - Independence guard (evidence invariance): for an independence-pinned step
#     (final-audit, paired-audit) it NEVER prints `rehydrate`; it falls back to
#     `fresh <refusal-reason>`, reusing gluerun_ctx_route_independence_admit
#     rehydrate <role> <step> (any non-`admit` verdict => no rehydrate) so the
#     independence set stays single-sourced.
#   - Empty-packet guard: when the supplied manifest carries zero surviving
#     sources (an empty `sources` array, or an unparseable/absent one), it prints
#     `fresh <refusal-reason>` — there is nothing to inject.
#   - Otherwise (GLUERUN_REHYDRATE=1, a non-pinned lineage-continuation step, and
#     a manifest with at least one surviving source) it prints `rehydrate
#     <refusal-reason>`.
#
# GLUERUN_REHYDRATE (default 0) gates ONLY this decision's upgrade; the leaf
# confers no independence — `rehydrate` remains tainted per
# gluerun_ctx_route_strategy_tainted.
gluerun_ctx_route_rehydrate_decide() {
  local reason="$1" role="$2" step="$3" manifest="$4"

  # OFF-parity: only GLUERUN_REHYDRATE=1 arms the upgrade; anything else (unset,
  # 0, or any other value) stays byte-identical to the bare `fresh <reason>` line.
  if [[ "${GLUERUN_REHYDRATE:-0}" != "1" ]]; then
    printf 'fresh %s\n' "$reason"; return 0
  fi

  # Independence guard: reuse the integrated classifier so the pinned set stays
  # single-sourced. Any verdict other than `admit` (i.e. an independence-required
  # step) forbids rehydrate and falls back to fresh.
  if [[ "$(gluerun_ctx_route_independence_admit rehydrate "$role" "$step")" != "admit" ]]; then
    printf 'fresh %s\n' "$reason"; return 0
  fi

  # Empty-packet guard: with nothing surviving to inject, rehydrate degrades to a
  # bare fresh. A malformed/absent manifest also fails closed here to fresh.
  if ! _gluerun_ctx_route_rehydrate_has_source "$manifest"; then
    printf 'fresh %s\n' "$reason"; return 0
  fi

  printf 'rehydrate %s\n' "$reason"
  return 0
}

# Internal: true iff the manifest JSON carries at least one entry in its `sources`
# array. Read-only; an unparseable or absent manifest yields false (fail closed).
_gluerun_ctx_route_rehydrate_has_source() {
  local manifest="$1"
  [[ -n "$manifest" ]] || return 1
  python3 - "$manifest" <<'PY' 2>/dev/null
import json, sys
try:
    obj = json.loads(sys.argv[1])
    srcs = obj.get("sources")
    sys.exit(0 if isinstance(srcs, list) and len(srcs) > 0 else 1)
except Exception:
    sys.exit(1)
PY
}
