#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
wrapper_dir="$tmp/chosen bash"
mkdir -p "$wrapper_dir"
wrapper="$wrapper_dir/bash"
marker="$tmp/bash-invocations"
path_marker="$tmp/observed-path"
cat >"$wrapper" <<'EOF'
#!/bin/sh
printf 'called\n' >>"$SINGULAR_TEST_BASH_MARKER"
printf '%s\n' "$PATH" >"$SINGULAR_TEST_PATH_MARKER"
exec "$SINGULAR_TEST_REAL_BASH" "$@"
EOF
chmod +x "$wrapper"

original_path="$PATH"
out="$(
  SINGULAR_BASH_BIN="$wrapper" \
  SINGULAR_TEST_BASH_MARKER="$marker" \
  SINGULAR_TEST_PATH_MARKER="$path_marker" \
  SINGULAR_TEST_REAL_BASH="$BASH" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  "$BASH" "$ENGINE_HOME/cli/singular" status
)"
assert_contains "$out" "singular orchestration status" "CLI reaches the engine under the selected Bash"
[[ -f "$marker" ]] || fail "selected Bash wrapper was not invoked"
calls="$(wc -l <"$marker" | tr -d ' ')"
[[ "$calls" -ge 2 ]] || fail "CLI and engine entrypoint did not both use selected Bash (calls=$calls)"
[[ "$(cat "$path_marker")" == "$original_path" ]] || fail "Bash selection changed PATH"

rc=0
out="$(SINGULAR_BASH_BIN=bash "$BASH" "$ENGINE_HOME/cli/singular" version 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "relative SINGULAR_BASH_BIN must be rejected"
assert_contains "$out" "must be an absolute executable path" "invalid Bash pin has a clear error"

echo "PASS: test-executable-resolution"
