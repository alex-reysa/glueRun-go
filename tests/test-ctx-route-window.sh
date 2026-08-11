#!/usr/bin/env bash
# Covers the window-pressure resume gate leaf brick engine/ctx-route-window.sh:
# singular_ctx_route_window_gate <role> <session-transcript-path> — the first of
# the two role-available resume tripwires the later engine/ctx-route.sh strategy
# dispatcher consults before it may ever return `resume`.
#
# Contract asserted here:
#   - Deterministic token estimate from the provider session transcript
#     (byte count / SINGULAR_SESSION_WINDOW_CHARS_PER_TOKEN, floored). The estimate
#     is compared against SINGULAR_SESSION_WINDOW_MAX_PCT of the window size
#     SINGULAR_SESSION_WINDOW_TOKENS.
#   - Over threshold -> exactly `refuse window-pressure`.
#   - At/under threshold -> exactly `pass`.
#   - Missing / unreadable / empty-path / indeterminate transcript -> exactly
#     `refuse window-pressure` (fail closed).
#   - Monotonic-refuse output alphabet: the ONLY lines a gate ever prints are
#     `pass` or `refuse window-pressure`. There is no input that turns a
#     would-be-fresh decision into a resumable one.
#   - Additive documented knobs with defaults; never exits non-zero.
# The gate is defined only; NO existing engine path invokes it, so with the file
# present-but-uncalled the engine is byte-identical to prior behavior.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_W="$ENGINE_HOME/engine/ctx-route-window.sh"

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

# lib.sh auto-sources engine/ctx-*.sh; source again defensively (RED before it is
# written -> this fails, which is the intended red).
[[ -f "$CTX_W" ]] || fail "engine not present yet: $CTX_W"
# shellcheck disable=SC1090
source "$CTX_W" || fail "sourcing $CTX_W failed"
[[ "$(type -t singular_ctx_route_window_gate)" == "function" ]] \
  || fail "singular_ctx_route_window_gate not defined by $CTX_W"

ROLE="implementer"

# Build a transcript file of an EXACT byte size for a reproducible estimate.
mk_transcript() { # <path> <bytes>
  python3 - "$1" "$2" <<'PY'
import sys
path, n = sys.argv[1], int(sys.argv[2])
with open(path, "wb") as f:
    f.write(b"x" * n)
PY
}

# Estimate divisor is fixed & documented (chars-per-token). Pin it here so the
# arithmetic below is reproducible regardless of the default.
export SINGULAR_SESSION_WINDOW_CHARS_PER_TOKEN=4
# Small window so the fixtures are tiny: threshold = 1000 * 70% = 700 tokens =
# 2800 bytes at 4 bytes/token.
export SINGULAR_SESSION_WINDOW_TOKENS=1000
export SINGULAR_SESSION_WINDOW_MAX_PCT=70

# --- At threshold -> pass ----------------------------------------------------
t="$tmp/at.jsonl"; mk_transcript "$t" 2800   # est = 700 == threshold
out="$(singular_ctx_route_window_gate "$ROLE" "$t")"
assert_eq "$out" "pass" "estimate exactly at threshold"

# --- Under threshold -> pass -------------------------------------------------
t="$tmp/under.jsonl"; mk_transcript "$t" 1200   # est = 300 < 700
out="$(singular_ctx_route_window_gate "$ROLE" "$t")"
assert_eq "$out" "pass" "estimate under threshold"
pass "gate: estimate at/under SINGULAR_SESSION_WINDOW_MAX_PCT of window -> pass"

# --- Just over threshold -> refuse window-pressure ---------------------------
t="$tmp/over1.jsonl"; mk_transcript "$t" 2804   # est = 701 > 700
out="$(singular_ctx_route_window_gate "$ROLE" "$t")"
assert_eq "$out" "refuse window-pressure" "estimate just over threshold"

# --- Far over threshold -> refuse window-pressure ----------------------------
t="$tmp/over2.jsonl"; mk_transcript "$t" 40000  # est = 10000 >> 700
out="$(singular_ctx_route_window_gate "$ROLE" "$t")"
assert_eq "$out" "refuse window-pressure" "estimate far over threshold"
pass "gate: estimate over threshold -> refuse window-pressure"

# --- Fail closed: missing / unreadable / empty-path transcript ---------------
out="$(singular_ctx_route_window_gate "$ROLE" "$tmp/does-not-exist.jsonl")"
assert_eq "$out" "refuse window-pressure" "missing transcript fails closed"
out="$(singular_ctx_route_window_gate "$ROLE" "")"
assert_eq "$out" "refuse window-pressure" "empty transcript path fails closed"
# A directory is not a readable transcript file.
mkdir -p "$tmp/adir"
out="$(singular_ctx_route_window_gate "$ROLE" "$tmp/adir")"
assert_eq "$out" "refuse window-pressure" "directory path fails closed"
pass "gate: missing/unreadable/empty transcript -> refuse window-pressure (fail closed)"

# --- Additive knobs have working defaults ------------------------------------
# With the window knobs unset, defaults apply; a tiny transcript is well under
# the default window and passes.
t="$tmp/default.jsonl"; mk_transcript "$t" 1200
out="$(env -u SINGULAR_SESSION_WINDOW_TOKENS -u SINGULAR_SESSION_WINDOW_MAX_PCT \
       -u SINGULAR_SESSION_WINDOW_CHARS_PER_TOKEN bash -c '
         source "'"$LIB"'"; source "'"$CTX_W"'"
         singular_ctx_route_window_gate '"$ROLE"' "'"$t"'"')"
assert_eq "$out" "pass" "defaults: tiny transcript passes with default window"
pass "gate: SINGULAR_SESSION_WINDOW_TOKENS / _MAX_PCT default to working values"

# --- Monotonic-refuse output alphabet: only pass|refuse window-pressure -------
for t in "$tmp/at.jsonl" "$tmp/over1.jsonl" "$tmp/does-not-exist.jsonl" ""; do
  out="$(singular_ctx_route_window_gate "$ROLE" "$t")"
  case "$out" in
    pass|"refuse window-pressure") : ;;
    *) fail "output alphabet violated: [$out]" ;;
  esac
done
pass "gate: output alphabet is exactly {pass, refuse window-pressure} (monotonic-refuse)"

# --- Contract: exactly one line, never exits non-zero ------------------------
rc=0
lines="$(singular_ctx_route_window_gate "$ROLE" "$tmp/over1.jsonl")" || rc=$?
assert_eq "$rc" "0" "gate exit code is 0 on refuse"
[[ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" == "1" ]] || fail "gate printed more than one line"
rc=0
lines="$(singular_ctx_route_window_gate "$ROLE" "$tmp/at.jsonl")" || rc=$?
assert_eq "$rc" "0" "gate exit code is 0 on pass"
[[ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" == "1" ]] || fail "gate printed more than one line"
rc=0
singular_ctx_route_window_gate "$ROLE" "$tmp/does-not-exist.jsonl" >/dev/null || rc=$?
assert_eq "$rc" "0" "gate exit code is 0 on fail-closed refuse"
pass "contract: prints exactly one line, never exits non-zero"

echo "ctx-route-window tests passed"
