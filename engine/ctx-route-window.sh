#!/usr/bin/env bash
# ctx-route-window.sh — the window-pressure resume gate, the first of the two
# role-available tripwires the later engine/ctx-route.sh strategy dispatcher will
# consult before it ever returns `resume`.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines a new
# function only; NO existing engine path invokes it, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# by construction, mirroring engine/ctx-planner-resume.sh). The
# GLUERUN_CTX_ROUTING wire-in and the engine/ctx-route.sh spine that composes this
# gate with gluerun_session_resume_decide / gluerun_planner_resume_decide are
# later slices of the routing-module node and are OUT OF SCOPE here.
#
# gluerun_ctx_route_window_gate <role> <session-transcript-path>
#
# Estimates session tokens from the provider session transcript via a documented
# deterministic estimate — byte_count / GLUERUN_SESSION_WINDOW_CHARS_PER_TOKEN,
# floored — and compares the estimate against GLUERUN_SESSION_WINDOW_MAX_PCT of
# the window size GLUERUN_SESSION_WINDOW_TOKENS:
#
#   estimate * 100 > GLUERUN_SESSION_WINDOW_TOKENS * GLUERUN_SESSION_WINDOW_MAX_PCT
#       -> refuse window-pressure   (over threshold)
#   otherwise                                            -> pass
#
# The estimate is deterministic and reproducible over a fixed fixture (pure byte
# count; no timestamps, randomness, or provider tokenizer). <role> is accepted so
# the later dispatcher can consult the gate per role; the window budget is not
# role-specific in this slice, so the argument is currently unused by the
# arithmetic (it pins the call shape, not the threshold).
#
# Fail closed (evidence invariance): a missing, empty-path, unreadable, or
# otherwise indeterminate transcript resolves to `refuse window-pressure`, NEVER
# to `pass`. This gate is monotonic-refuse — its ONLY outputs are `pass` and
# `refuse window-pressure`; there is no input under which it turns a
# would-be-fresh decision into a resumable one. Prints EXACTLY one line and never
# exits non-zero.
#
# Additive documented knobs (defaults live here):
#   GLUERUN_SESSION_WINDOW_TOKENS          200000  context-window size in tokens
#   GLUERUN_SESSION_WINDOW_MAX_PCT         70      refuse-resume usage percentage
#   GLUERUN_SESSION_WINDOW_CHARS_PER_TOKEN 4       deterministic estimate divisor
gluerun_ctx_route_window_gate() {
  local role="$1" transcript="$2"
  : "$role"  # accepted for per-role dispatch; not consulted by the budget here

  # Fail closed: empty path or non-readable-regular-file transcript.
  if [[ -z "$transcript" || ! -f "$transcript" || ! -r "$transcript" ]]; then
    printf 'refuse window-pressure\n'; return 0
  fi

  local window="${GLUERUN_SESSION_WINDOW_TOKENS:-200000}"
  local max_pct="${GLUERUN_SESSION_WINDOW_MAX_PCT:-70}"
  local cpt="${GLUERUN_SESSION_WINDOW_CHARS_PER_TOKEN:-4}"

  # Compute the deterministic estimate and the verdict in one python pass. Any
  # arithmetic ambiguity (non-integer knob, unreadable size, cpt<=0) fails closed
  # to REFUSE. Output is exactly REFUSE or PASS.
  local verdict
  verdict="$(python3 - "$transcript" "$window" "$max_pct" "$cpt" <<'PY' 2>/dev/null || true
import os, sys
transcript = sys.argv[1]
def as_int(s, lo=None):
    try:
        v = int(str(s).strip())
    except Exception:
        return None
    if lo is not None and v < lo:
        return None
    return v
window = as_int(sys.argv[2], lo=0)
max_pct = as_int(sys.argv[3], lo=0)
cpt = as_int(sys.argv[4], lo=1)   # chars-per-token must be >= 1
if window is None or max_pct is None or cpt is None:
    print("REFUSE"); sys.exit(0)
try:
    nbytes = os.path.getsize(transcript)
except Exception:
    print("REFUSE"); sys.exit(0)
est = nbytes // cpt                       # deterministic, floored token estimate
# est / window > max_pct / 100  <=>  est * 100 > window * max_pct  (integer-safe)
print("REFUSE" if est * 100 > window * max_pct else "PASS")
PY
)"

  if [[ "$verdict" == "PASS" ]]; then
    printf 'pass\n'
  else
    printf 'refuse window-pressure\n'
  fi
  return 0
}
