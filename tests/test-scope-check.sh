#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp=""
cleanup() {
  [[ -z "${tmp:-}" ]] || rm -rf "$tmp"
}
trap cleanup EXIT

make_repo() {
  local root="$1"
  mkdir -p "$root/internal/dispatch" "$root/.gluerun-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  printf 'package dispatch\n' >"$root/internal/dispatch/runtime.go"
  git -C "$root" add internal/dispatch/runtime.go
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  cleanup
  tmp="$(mktemp -d)"
  make_repo "$tmp/repo"
  export GLUERUN_ROOT="$tmp/repo"
  export GLUERUN_STATE_DIR="$GLUERUN_ROOT/.gluerun-state"
  export GLUERUN_TARGET_BRANCH="target"
}

test_empty_forbid_prefixes_are_safe_under_system_bash() {
  with_fixture
  printf '\nconst started = true\n' >>"$GLUERUN_ROOT/internal/dispatch/runtime.go"
  local out rc=0
  out="$(/bin/bash "$SCRIPT_DIR/scope-check.sh" --worktree "$GLUERUN_ROOT" --allow-prefix internal/dispatch/runtime.go 2>&1)" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "scope check with no forbidden prefixes should pass: $out"
  assert_contains "$out" "all allowed" "empty forbidden prefix result"
}

test_forbidden_prefix_still_fails_under_system_bash() {
  with_fixture
  printf '\nconst started = true\n' >>"$GLUERUN_ROOT/internal/dispatch/runtime.go"
  local out rc=0
  out="$(/bin/bash "$SCRIPT_DIR/scope-check.sh" --worktree "$GLUERUN_ROOT" --allow-prefix internal/dispatch/runtime.go --forbid-prefix internal/dispatch/runtime.go 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "forbidden prefix should fail"
  assert_contains "$out" "forbidden paths touched" "forbidden prefix failure"
}

test_empty_forbid_prefixes_are_safe_under_system_bash
test_forbidden_prefix_still_fails_under_system_bash

echo "test-scope-check.sh: ok"
