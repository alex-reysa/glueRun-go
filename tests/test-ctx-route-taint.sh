#!/usr/bin/env bash
# Covers the taint / independence-pin leaf brick engine/ctx-route-taint.sh:
#   singular_ctx_route_strategy_tainted <strategy>
#   singular_ctx_route_independence_admit <strategy> <role> <step>
#
# The structural guarantee that resumed/rehydrated sessions can never satisfy an
# independence-required step (final audit, paired audit). Both are pure
# predicates: they print exactly one line, append no events, write no files, and
# never exit non-zero.
#
# Contract asserted here:
#   - _tainted prints 1 for resume/rehydrate, 0 for continue/fork/fresh, and 1
#     for any unknown or empty strategy (fail closed).
#   - _independence_admit, for an independence-required step (final-audit,
#     paired-audit): admit only when strategy is fresh; `refuse tainted` for
#     resume/rehydrate; `refuse pinned-fresh` for any other non-fresh strategy.
#     For any non-independence-required step: admit.
#   - No SINGULAR_* env knob relaxes an independence-required step: with routing
#     knobs set to any values, resume/rehydrate at final-audit/paired-audit still
#     print `refuse tainted`.
# The predicates are defined only; NO existing engine path invokes them, so with
# the file present-but-uncalled the engine is byte-identical to prior behavior.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_T="$ENGINE_HOME/engine/ctx-route-taint.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { # <got> <want> <label>
  [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"
}
pass() { echo "ok: $*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

[[ -f "$CTX_T" ]] || fail "engine not present yet: $CTX_T"
# shellcheck disable=SC1090
source "$CTX_T" || fail "sourcing $CTX_T failed"
[[ "$(type -t singular_ctx_route_strategy_tainted)" == "function" ]] \
  || fail "singular_ctx_route_strategy_tainted not defined by $CTX_T"
[[ "$(type -t singular_ctx_route_independence_admit)" == "function" ]] \
  || fail "singular_ctx_route_independence_admit not defined by $CTX_T"

# --- _tainted classification -------------------------------------------------
assert_eq "$(singular_ctx_route_strategy_tainted resume)"    "1" "resume -> tainted"
assert_eq "$(singular_ctx_route_strategy_tainted rehydrate)" "1" "rehydrate -> tainted"
assert_eq "$(singular_ctx_route_strategy_tainted continue)"  "0" "continue -> untainted"
assert_eq "$(singular_ctx_route_strategy_tainted fork)"      "0" "fork -> untainted"
assert_eq "$(singular_ctx_route_strategy_tainted fresh)"     "0" "fresh -> untainted"
# Fail closed: unknown/empty -> tainted so it cannot slip past the pin.
assert_eq "$(singular_ctx_route_strategy_tainted bogus)"     "1" "unknown strategy -> tainted (fail closed)"
assert_eq "$(singular_ctx_route_strategy_tainted '')"        "1" "empty strategy -> tainted (fail closed)"
pass "tainted: resume/rehydrate/unknown/empty -> 1; continue/fork/fresh -> 0"

# --- _independence_admit on independence-required steps ----------------------
for step in final-audit paired-audit; do
  for role in advocate skeptic auditor implementer; do
    assert_eq "$(singular_ctx_route_independence_admit fresh "$role" "$step")" \
      "admit" "fresh admitted at $step ($role)"
    assert_eq "$(singular_ctx_route_independence_admit resume "$role" "$step")" \
      "refuse tainted" "resume refused at $step ($role)"
    assert_eq "$(singular_ctx_route_independence_admit rehydrate "$role" "$step")" \
      "refuse tainted" "rehydrate refused at $step ($role)"
    # Any other non-fresh strategy -> refuse pinned-fresh (pinned to fresh).
    assert_eq "$(singular_ctx_route_independence_admit continue "$role" "$step")" \
      "refuse pinned-fresh" "continue refused pinned-fresh at $step ($role)"
    assert_eq "$(singular_ctx_route_independence_admit fork "$role" "$step")" \
      "refuse pinned-fresh" "fork refused pinned-fresh at $step ($role)"
    assert_eq "$(singular_ctx_route_independence_admit bogus "$role" "$step")" \
      "refuse pinned-fresh" "unknown refused pinned-fresh at $step ($role)"
  done
done
pass "admit: independence steps admit only fresh; resume/rehydrate->refuse tainted; else->refuse pinned-fresh"

# --- _independence_admit on non-independence steps -> always admit ------------
for step in implement review diff-check window-check some-other-step; do
  for strat in fresh continue fork resume rehydrate bogus ''; do
    assert_eq "$(singular_ctx_route_independence_admit "$strat" auditor "$step")" \
      "admit" "non-independence step $step admits strategy [$strat]"
  done
done
pass "admit: non-independence-required steps always admit"

# --- Structural pin: no SINGULAR_* knob relaxes an independence step -----------
# Set a wide spread of routing knobs to permissive-looking values and re-assert.
knob_out="$(env \
    SINGULAR_CTX_ROUTING=1 \
    SINGULAR_PLANNER_SESSION=1 \
    SINGULAR_SESSION_RESUME=1 \
    SINGULAR_ROUTE_ALLOW_TAINTED=1 \
    SINGULAR_ROUTE_INDEPENDENCE=0 \
    SINGULAR_ROUTE_FORCE=resume \
    SINGULAR_SESSION_WINDOW_MAX_PCT=100 \
    bash -c '
      source "'"$LIB"'"; source "'"$CTX_T"'"
      for step in final-audit paired-audit; do
        singular_ctx_route_independence_admit resume auditor "$step"
        singular_ctx_route_independence_admit rehydrate auditor "$step"
      done')"
expected=$'refuse tainted\nrefuse tainted\nrefuse tainted\nrefuse tainted'
assert_eq "$knob_out" "$expected" "no knob relaxes resume/rehydrate at independence steps"
pass "pin is structural: resume/rehydrate at final-audit/paired-audit refuse tainted under any knobs"

# --- Taint gate only ADDS refusals; never converts a refuse into an admit -----
# On an independence step, every strategy that _tainted marks tainted (1) is
# refused; nothing tainted becomes admit.
for strat in resume rehydrate bogus ''; do
  t="$(singular_ctx_route_strategy_tainted "$strat")"
  a="$(singular_ctx_route_independence_admit "$strat" auditor final-audit)"
  if [[ "$t" == "1" ]]; then
    [[ "$a" != "admit" ]] || fail "tainted strategy [$strat] wrongly admitted at final-audit"
  fi
done
pass "taint gate only adds refusals; never turns a would-be-refused decision into admit"

# --- Pure predicates: exactly one line, never exits non-zero, no files --------
before="$(find "$SINGULAR_STATE_DIR" -type f | sort)"
rc=0; line="$(singular_ctx_route_strategy_tainted resume)" || rc=$?
assert_eq "$rc" "0" "_tainted exit 0"
[[ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" == "1" ]] || fail "_tainted printed more than one line"
rc=0; line="$(singular_ctx_route_independence_admit resume auditor final-audit)" || rc=$?
assert_eq "$rc" "0" "_admit exit 0"
[[ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" == "1" ]] || fail "_admit printed more than one line"
after="$(find "$SINGULAR_STATE_DIR" -type f | sort)"
assert_eq "$after" "$before" "predicates write no files"
pass "contract: pure predicates print one line, exit 0, write no files"

echo "ctx-route-taint tests passed"
