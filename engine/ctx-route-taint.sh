#!/usr/bin/env bash
# ctx-route-taint.sh — the taint / independence pin: the structural guarantee
# that resumed/rehydrated sessions can never satisfy an independence-required
# step (final audit, paired audit). Honors the advocate/skeptic line and evidence
# invariance (planner-contract rule 8): no knob may reroute an independence step.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# by construction, mirroring engine/ctx-route-window.sh). The engine/ctx-route.sh
# spine that stamps `tainted=1` into the strategy event and composes this pin is a
# later slice of the routing-module node and is OUT OF SCOPE here.
#
# Both functions are PURE predicates: they print exactly one line, append no
# events, write no files, and never exit non-zero.

# gluerun_ctx_route_strategy_tainted <strategy>
#
# Classifies a resume strategy for the tainted=1 flag the spine will stamp:
#   resume, rehydrate           -> 1 (tainted; carries prior-session state)
#   continue, fork, fresh       -> 0 (untainted)
#   anything else (incl. empty) -> 1 (fail closed; an unrecognized strategy is
#                                     treated as tainted so it cannot slip past
#                                     the independence pin)
gluerun_ctx_route_strategy_tainted() {
  case "$1" in
    resume|rehydrate)     printf '1\n' ;;
    continue|fork|fresh)  printf '0\n' ;;
    *)                    printf '1\n' ;;
  esac
  return 0
}

# gluerun_ctx_route_independence_admit <strategy> <role> <step>
#
# Pins the independence-required steps (the fixed documented set: final-audit,
# paired-audit) to `fresh`. For those steps:
#   fresh                -> admit
#   resume | rehydrate   -> refuse tainted
#   any other non-fresh  -> refuse pinned-fresh
# For any non-independence-required step -> admit. The <role> is accepted for the
# call shape and future per-role pins; the current independence set is role-generic.
gluerun_ctx_route_independence_admit() {
  local strategy="$1" role="$2" step="$3"
  : "$role"  # accepted for call shape; the documented independence set is role-generic

  case "$step" in
    final-audit|paired-audit) ;;
    *) printf 'admit\n'; return 0 ;;
  esac

  # Independence-required step: only `fresh` is admissible. resume/rehydrate are
  # tainted; everything else is refused because the step is pinned to fresh. No
  # GLUERUN_* knob is consulted here — the pin is structural.
  case "$strategy" in
    fresh)              printf 'admit\n' ;;
    resume|rehydrate)   printf 'refuse tainted\n' ;;
    *)                  printf 'refuse pinned-fresh\n' ;;
  esac
  return 0
}
