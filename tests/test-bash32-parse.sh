#!/usr/bin/env bash
# lib.sh is sourced by scripts that carry no bash>=4 guard of their own
# (scope-check.sh, the provider adapters, every ctx-*.sh it auto-sources), and
# several tests deliberately restrict PATH so that `bash` resolves to the
# system interpreter — on macOS, bash 3.2. That parser scans a heredoc inside a
# command substitution for quotes and backticks while looking for the closing
# paren, so a single apostrophe in a comment inside `$(python3 - <<'PY' ... PY)`
# makes every one of those scripts exit 2 before running. The 0.21.0 release
# candidate shipped exactly that and surfaced as eight unrelated adapter
# failures. This test names the cause directly: every file lib.sh sources must
# parse under the oldest bash on the machine. Skips (passes) where no bash 3.x
# is installed.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

old_bash=""
for candidate in /bin/bash /usr/bin/bash; do
  [[ -x "$candidate" ]] || continue
  major="$("$candidate" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null || true)"
  if [[ "$major" == "3" ]]; then old_bash="$candidate"; break; fi
done
if [[ -z "$old_bash" ]]; then
  echo "PASS: test-bash32-parse (no bash 3.x on this machine; nothing to prove here)"
  exit 0
fi

failures=0
checked=0
for f in "$ENGINE_HOME"/engine/lib.sh "$ENGINE_HOME"/engine/ctx-*.sh \
  "$ENGINE_HOME"/engine/bash-guard.sh "$ENGINE_HOME"/engine/git-preflight.sh \
  "$ENGINE_HOME"/engine/scope-check.sh "$ENGINE_HOME"/engine/gate-check.sh \
  "$ENGINE_HOME"/engine/secret-scan.sh "$ENGINE_HOME"/engine/*-run.sh \
  "$ENGINE_HOME"/tests/run.sh; do
  [[ -f "$f" ]] || continue
  checked=$((checked + 1))
  if ! err="$("$old_bash" -n "$f" 2>&1)"; then
    echo "bash 3.2 cannot parse ${f#"$ENGINE_HOME"/}: $(printf '%s' "$err" | head -1)" >&2
    failures=$((failures + 1))
  fi
done
[[ "$checked" -gt 0 ]] || fail "no files checked"
[[ "$failures" -eq 0 ]] || fail "$failures file(s) sourced by lib.sh do not parse under $old_bash"
echo "PASS: test-bash32-parse ($checked files parse under $old_bash)"
