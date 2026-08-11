#!/usr/bin/env bash
set -uo pipefail

# engine/lib.sh's singular_resolve_codex_bin and engine/provider_resolver.py must
# answer identically. Bash stays authoritative for the runtime hot path (one
# resolve per provider invocation in codex-run.sh); python serves doctor and the
# console. Nothing at runtime forces them to agree, so this test does.
#
# The invariant that matters most: an explicitly configured but broken
# SINGULAR_CODEX_BIN NEVER falls back to a working PATH candidate. The console
# violated exactly that, and reported a Codex the orchestration was not running.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Each case replaces PATH wholesale to control what `command -v codex` can see,
# which also hides the interpreter and bash itself. Resolve both now.
PY3="$(command -v python3)" || fail "python3 not found"
BASH_BIN="$(command -v bash)" || fail "bash not found"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A working codex on a fake PATH. Every "broken override" case below keeps this
# on PATH, so a fallback bug shows up as a parity mismatch rather than silence.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho codex 1.0\n' >"$tmp/bin/codex"
chmod +x "$tmp/bin/codex"

mkdir -p "$tmp/pinned"
printf '#!/bin/sh\necho pinned 1.0\n' >"$tmp/pinned/codex"
chmod +x "$tmp/pinned/codex"

printf '#!/bin/sh\necho nope\n' >"$tmp/not-exec"
chmod 0644 "$tmp/not-exec"

mkdir -p "$tmp/noexec-path"
printf '#!/bin/sh\necho nope\n' >"$tmp/noexec-path/codex"
chmod 0644 "$tmp/noexec-path/codex"

# lib.sh runs python3/git/etc at source time, so the bash side needs a usable
# PATH — it cannot be the bare fixture dir. /usr/bin:/bin carries no codex on a
# normal macOS or Linux box (the real one lives in a homebrew/fnm prefix), so
# appending it keeps `command -v codex` answering only from the fixture while
# both implementations still see a byte-identical PATH.
SYS_PATH="/usr/bin:/bin"
command -v codex >/dev/null 2>&1 && {
  PATH="$SYS_PATH" command -v codex >/dev/null 2>&1 \
    && fail "a codex on $SYS_PATH would make these fixtures ambiguous"
}

# Each case: <name> <SINGULAR_CODEX_BIN> <fixture PATH prefix>
run_case() {
  local name="$1" codex_bin="$2" path_val="$3:$SYS_PATH"

  local bash_out bash_rc bash_err
  bash_err="$tmp/bash.err"
  bash_out="$(SINGULAR_CODEX_BIN="$codex_bin" PATH="$path_val" \
    "$BASH_BIN" -c 'source "$1/engine/lib.sh" >/dev/null 2>&1; singular_resolve_codex_bin' \
      _ "$ENGINE_HOME" 2>"$bash_err")"
  bash_rc=$?
  bash_err="$(head -1 "$tmp/bash.err")"

  local py_out
  py_out="$(SINGULAR_CODEX_BIN="$codex_bin" PATH="$path_val" \
    "$PY3" - "$ENGINE_HOME" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "engine"))
from provider_resolver import resolve_codex_bin
# Mirror lib.sh: an unset override is an absent key, not an empty string.
env = dict(os.environ)
if not env.get("SINGULAR_CODEX_BIN"):
    env.pop("SINGULAR_CODEX_BIN", None)
r = resolve_codex_bin(env)
# One field per line: a tab-separated form would collapse the leading empty
# `path` field, because bash treats tab as IFS whitespace.
print(r.path or "")
print(r.exit_code)
print(r.message)
PY
)"
  local py_path py_rc py_msg
  { IFS= read -r py_path; IFS= read -r py_rc; IFS= read -r py_msg; } <<<"$py_out"

  [[ "$bash_out" == "$py_path" ]] \
    || fail "$name: path mismatch — bash='$bash_out' python='$py_path'"
  [[ "$bash_rc" == "$py_rc" ]] \
    || fail "$name: exit-code mismatch — bash=$bash_rc python=$py_rc"
  [[ "$bash_err" == "$py_msg" ]] \
    || fail "$name: message mismatch — bash='$bash_err' python='$py_msg'"
  echo "  ok  $name (rc=$bash_rc path='${bash_out:-—}')"
}

echo "provider resolver parity:"

# 1. No override, a working codex on PATH.
run_case "path-ok" "" "$tmp/bin"

# 2. No override, empty PATH.
run_case "path-missing" "" "$tmp/empty"

# 3. No override, PATH entry exists but is not executable.
run_case "path-not-executable" "" "$tmp/noexec-path"

# 4. Absolute, executable override — must win over the PATH candidate.
run_case "override-ok" "$tmp/pinned/codex" "$tmp/bin"

# 5. Relative override — rejected, rc 2, never falls back.
run_case "override-relative" "pinned/codex" "$tmp/bin"

# 6. Absolute but non-executable override — rejected, rc 127, never falls back
#    even though a perfectly good codex sits on PATH. The reported defect.
run_case "override-not-executable" "$tmp/not-exec" "$tmp/bin"

# 7. Absolute override pointing at nothing at all.
run_case "override-absent" "$tmp/does-not-exist" "$tmp/bin"

# The override must be codex-scoped: a codex pin must not steer another
# provider's resolution.
other="$(SINGULAR_CODEX_BIN="$tmp/pinned/codex" PATH="$tmp/bin:$SYS_PATH" \
  "$PY3" - "$ENGINE_HOME" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "engine"))
from provider_resolver import resolve_provider_bin
r = resolve_provider_bin("claude", "claude", dict(os.environ))
print(r.outcome, r.configured or "-", sep="\t")
PY
)"
[[ "$other" == "not-on-path	-" ]] \
  || fail "codex override leaked into a non-codex provider: $other"
echo "  ok  override is codex-scoped"

echo "PASS: test-provider-resolver-parity"
