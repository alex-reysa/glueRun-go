#!/usr/bin/env bash
# ctx-route-window.sh — the window-pressure resume gate, the first of the two
# role-available tripwires the later engine/ctx-route.sh strategy dispatcher will
# consult before it ever returns `resume`.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines a new
# function only; NO existing engine path invokes it, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# by construction, mirroring engine/ctx-planner-resume.sh). The
# SINGULAR_CTX_ROUTING wire-in and the engine/ctx-route.sh spine that composes this
# gate with singular_session_resume_decide / singular_planner_resume_decide are
# later slices of the routing-module node and are OUT OF SCOPE here.
#
# singular_ctx_route_window_gate <role> <session-transcript-path>
#
# Estimates session tokens from the provider session transcript via a documented
# deterministic estimate — byte_count / SINGULAR_SESSION_WINDOW_CHARS_PER_TOKEN,
# floored — and compares the estimate against SINGULAR_SESSION_WINDOW_MAX_PCT of
# the window size SINGULAR_SESSION_WINDOW_TOKENS:
#
#   estimate * 100 > SINGULAR_SESSION_WINDOW_TOKENS * SINGULAR_SESSION_WINDOW_MAX_PCT
#       -> refuse window-pressure   (over threshold)
#   otherwise                                            -> pass
#
# The estimate is deterministic and reproducible over a fixed fixture (pure byte
# count; no timestamps, randomness, or provider tokenizer). <role> is accepted so
# the dispatcher can consult the gate per role; the budget is resolved from the
# PROVIDER (below), not the role, so the argument pins the call shape.
#
# WINDOW RESOLUTION (derived, not configured). The optional <runner> argument is
# the runner basename or path the call site already holds. It resolves to a
# provider through singular_runner_provider_identity -- the engine's ONLY
# path->provider mapping -- and that provider's `contextWindowTokens` is read from
# engine/providers.json, which is authoritative for provider facts and already
# pinned by the providers conformance test. Precedence:
#
#   1. SINGULAR_SESSION_WINDOW_TOKENS   explicit operator override (escape hatch)
#   2. providers.json contextWindowTokens for the resolved provider
#   3. 200000                            conservative fallback
#
# There is NO new env knob: a deployment that changes provider changes its budget
# automatically. An unresolvable runner (empty, unknown adapter, or a path outside
# the engine dir) falls through to the conservative fallback rather than guessing.
#
# The shipped per-provider values are a CONSERVATIVE ENGINE BUDGET, not a vendor
# specification. They are seeded uniformly at the 200000 this gate already
# assumed, so no deployment's behavior changes when this resolution lands. Raising
# one is a deliberate act for a deployment that has verified the window of the
# model it actually runs: guessing HIGH is the UNSAFE direction (it permits a
# resume that is genuinely over budget), while guessing low only costs a fresh
# run. Note also that several providers (opencode, openrouter, cursor) proxy an
# arbitrary operator-selected model, so for those the window is not a property of
# the provider at all and a conservative floor is the only honest value.
#
# UNMEASURED OVERHEAD. bytes/CHARS_PER_TOKEN estimates the transcript FILE. The
# provider's real context occupancy also carries the system prompt, tool schemas,
# and any injected packet -- none of which appear in the transcript. The estimate
# therefore adds a fixed _SINGULAR_WINDOW_OVERHEAD_TOKENS before comparing. It is
# hard-wired rather than exposed as a knob: it is a property of how the engine
# assembles prompts, not a deployment preference, and a knob defaulted to 0 would
# reintroduce exactly the assume-overhead-is-zero error it exists to correct.
#
# Fail closed (evidence invariance): a missing, empty-path, unreadable, or
# otherwise indeterminate transcript resolves to `refuse window-pressure`, NEVER
# to `pass`. This gate is monotonic-refuse — its ONLY outputs are `pass` and
# `refuse window-pressure`; there is no input under which it turns a
# would-be-fresh decision into a resumable one. Prints EXACTLY one line and never
# exits non-zero.
#
# Additive documented knobs (defaults live here):
#   SINGULAR_SESSION_WINDOW_TOKENS          (unset) explicit window override; when
#                                           unset the window is RESOLVED from the
#                                           provider (see WINDOW RESOLUTION above)
#   SINGULAR_SESSION_WINDOW_MAX_PCT         70      refuse-resume usage percentage
#   SINGULAR_SESSION_WINDOW_CHARS_PER_TOKEN 4       deterministic estimate divisor

# Fixed engine-side allowance (tokens) for the system prompt, tool schemas, and
# injected packet that occupy the provider context but never appear in the
# transcript file. Deliberately NOT a knob -- see UNMEASURED OVERHEAD above.
_SINGULAR_WINDOW_OVERHEAD_TOKENS=12000

# singular_ctx_route_window_budget [runner]
#
# Resolve the context-window budget in TOKENS for a runner. Prints exactly one
# integer and never fails: an unresolvable runner or an absent/invalid
# providers.json field yields the conservative 200000 fallback.
singular_ctx_route_window_budget() {
  local runner="${1:-}"

  # 1. Explicit operator override wins.
  if [[ -n "${SINGULAR_SESSION_WINDOW_TOKENS:-}" ]]; then
    printf '%s\n' "$SINGULAR_SESSION_WINDOW_TOKENS"; return 0
  fi

  # 2. Derive the provider from the runner, then read providers.json.
  #
  # The routing call sites hand the router a runner BASENAME (l1-drive.sh passes
  # `basename "$l2_runner"`), but singular_runner_provider_identity resolves its
  # argument as a PATH and compares it against <engine-dir>/<adapter> — and during
  # a run the process cwd is the worktree, not the engine dir. A bare basename is
  # therefore anchored to the engine dir here; a caller that already passes a path
  # is left untouched. Without this the lookup fails for every real call site and
  # the budget silently falls through to the constant, which is exactly the dead
  # seam this resolution exists to remove.
  local provider="" spec resolved runner_path=""
  if [[ -n "$runner" ]]; then
    if [[ "$runner" == */* ]]; then
      runner_path="$runner"
    else
      runner_path="${SINGULAR_ENGINE_DIR:-${SINGULAR_ROOT:-.}/engine}/$runner"
    fi
    provider="$(singular_runner_provider_identity "$runner_path" 2>/dev/null || true)"
  fi
  spec="${SINGULAR_ENGINE_DIR:-${SINGULAR_ROOT:-.}/engine}/providers.json"
  if [[ -n "$provider" && -r "$spec" ]]; then
    resolved="$(python3 - "$spec" "$provider" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        doc = json.load(f)
    v = int(doc["providers"][sys.argv[2]]["contextWindowTokens"])
    if v > 0:
        print(v)
except Exception:
    pass
PY
)"
    if [[ "$resolved" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$resolved"; return 0
    fi
  fi

  # 3. Conservative fallback.
  printf '200000\n'
}

singular_ctx_route_window_gate() {
  local role="$1" transcript="$2" runner="${3:-}"
  : "$role"  # accepted for per-role dispatch; the budget is per-PROVIDER

  # Fail closed: empty path or non-readable-regular-file transcript.
  if [[ -z "$transcript" || ! -f "$transcript" || ! -r "$transcript" ]]; then
    printf 'refuse window-pressure\n'; return 0
  fi

  local window; window="$(singular_ctx_route_window_budget "$runner")"
  local max_pct="${SINGULAR_SESSION_WINDOW_MAX_PCT:-70}"
  local cpt="${SINGULAR_SESSION_WINDOW_CHARS_PER_TOKEN:-4}"
  local overhead="${_SINGULAR_WINDOW_OVERHEAD_TOKENS:-12000}"

  # Compute the deterministic estimate and the verdict in one python pass. Any
  # arithmetic ambiguity (non-integer knob, unreadable size, cpt<=0) fails closed
  # to REFUSE. Output is exactly REFUSE or PASS.
  local verdict
  verdict="$(python3 - "$transcript" "$window" "$max_pct" "$cpt" "$overhead" <<'PY' 2>/dev/null || true
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
overhead = as_int(sys.argv[5], lo=0)
if window is None or max_pct is None or cpt is None or overhead is None:
    print("REFUSE"); sys.exit(0)
try:
    nbytes = os.path.getsize(transcript)
except Exception:
    print("REFUSE"); sys.exit(0)
# Deterministic, floored token estimate PLUS the fixed engine-side allowance for
# the system prompt / tool schemas / injected packet, which occupy the provider
# context but never appear in the transcript file.
est = nbytes // cpt + overhead
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
