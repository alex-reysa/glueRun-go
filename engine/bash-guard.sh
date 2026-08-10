#!/usr/bin/env bash
# engine/bash-guard.sh — the one shared Bash >= 4 interpreter guard.
#
# CONTRACT
#   Source this from EXECUTED scripts only:
#
#       _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#       . "$_dir/../engine/bash-guard.sh"
#
#   It re-execs "$0" with "$@", so a *sourced-only* library must never use it
#   (it would re-exec its caller's caller). Source it as early as possible —
#   after `set -euo pipefail`, before anything that needs Bash >= 4.
#
#   Sourcing it is a no-op (zero forks, zero definitions, positional
#   parameters untouched) on the common path: Bash >= 4 with no explicit
#   GLUERUN_BASH_BIN pin. No `return` is used, so this body is also valid
#   inline — cli/gluerun embeds a verbatim copy because the CLI must be able
#   to fix its own interpreter before it can resolve an engine home.
#   *** keep in sync with cli/gluerun ***
#
# ORDER
#   1. no-op when already Bash >= 4 and no pin is set;
#   2. GLUERUN_BASH_BOOTSTRAPPED=1 yet still < 4 -> the re-exec target lied;
#   3. GLUERUN_BASH_BIN (bootstrap-only, explicit operator selection):
#      absolute + executable + probed >= 4, then re-exec exactly once;
#   4. otherwise probe the usual Homebrew/PATH candidates and re-exec;
#   5. terminal GLUERUN_BASH_UNSUPPORTED block on stderr, exit 2.
#
#   Every failure prints the same four-line block so operators learn one
#   shape; the specific cause is the single indented `detail:` line.
#
# PORTABILITY
#   Every line must PARSE under Bash 3.2 (`/bin/bash -n` clean) — that is the
#   interpreter this file exists to rescue. No associative arrays, no
#   ${var,,}, no mapfile, and no heredoc inside $( ).

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 || -n "${GLUERUN_BASH_BIN:-}" ]]; then

  # Terminal diagnosis: fixed block, optional one-line detail, exit 2.
  gluerun_bash_guard__fail() {
    {
      echo "GLUERUN_BASH_UNSUPPORTED"
      echo "Found: ${BASH:-bash} ${BASH_VERSION%%(*}"
      echo "Required: Bash >= 4"
      echo "Recovery: brew install bash && GLUERUN_BASH_BIN=/opt/homebrew/bin/bash gluerun setup"
      if [[ -n "${1:-}" ]]; then echo "  detail: $1"; fi
    } >&2
    exit 2
  }

  # An executable bit is not proof of a version: ask the candidate itself.
  gluerun_bash_guard__probe() {
    [[ -n "${1:-}" && "$1" == /* && -x "$1" ]] || return 1
    "$1" -c '[[ "${BASH_VERSINFO[0]}" -ge 4 ]]' >/dev/null 2>&1 || return 1
    return 0
  }

  # (2) Loop guard: we already re-exec'd and are still < 4. Never exec again.
  if [[ "${GLUERUN_BASH_BOOTSTRAPPED:-0}" == "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    gluerun_bash_guard__fail "re-exec target did not provide Bash >= 4: ${GLUERUN_BASH_BIN:-<unset>}"
  fi

  # (3) Explicit pin wins over the running interpreter, exactly once. PATH is
  # deliberately not modified: provider resolution must not shift.
  if [[ -n "${GLUERUN_BASH_BIN:-}" && "${GLUERUN_BASH_BOOTSTRAPPED:-0}" != "1" ]]; then
    if [[ "$GLUERUN_BASH_BIN" != /* || ! -x "$GLUERUN_BASH_BIN" ]]; then
      gluerun_bash_guard__fail "GLUERUN_BASH_BIN must be an absolute executable path: $GLUERUN_BASH_BIN"
    fi
    if ! gluerun_bash_guard__probe "$GLUERUN_BASH_BIN"; then
      gluerun_bash_guard__fail "GLUERUN_BASH_BIN must provide Bash >= 4: $GLUERUN_BASH_BIN"
    fi
    export GLUERUN_BASH_BOOTSTRAPPED=1
    exec "$GLUERUN_BASH_BIN" "$0" "$@"
  fi

  # (4) No pin and still < 4: the bare-invocation case. Probe before exec so a
  # broken candidate cannot swallow the diagnosis.
  if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    gluerun_bash_guard__path="$(command -v bash 2>/dev/null || true)"
    if [[ "$gluerun_bash_guard__path" == "${BASH:-}" ]]; then gluerun_bash_guard__path=""; fi
    for gluerun_bash_guard__cand in /opt/homebrew/bin/bash /usr/local/bin/bash "$gluerun_bash_guard__path"; do
      if gluerun_bash_guard__probe "$gluerun_bash_guard__cand"; then
        export GLUERUN_BASH_BOOTSTRAPPED=1
        exec "$gluerun_bash_guard__cand" "$0" "$@"
      fi
    done
    gluerun_bash_guard__fail "no Bash >= 4 found (checked /opt/homebrew/bin/bash, /usr/local/bin/bash, PATH)"
  fi

  # Reached only when the pin was already honored: leave no residue behind.
  unset -f gluerun_bash_guard__fail gluerun_bash_guard__probe
  unset gluerun_bash_guard__path gluerun_bash_guard__cand 2>/dev/null || true
fi
