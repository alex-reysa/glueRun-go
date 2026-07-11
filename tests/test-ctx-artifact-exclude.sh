#!/usr/bin/env bash
# Covers Slice B of artifact-secret-scan containment: the exclusion filter.
# `engine/ctx-artifact-exclude.sh` ships a PURE, read-only, present-but-uncalled
# helper
#   gluerun_ctx_artifact_exclude [path...]        # or paths on stdin
# that, given a set of candidate artifact paths, drops every quarantined entry —
#   * any path ending in `.quarantined`, and
#   * any original path whose `.quarantined` sibling exists on disk —
# and emits only the surviving safe paths on stdout, order-stable, so a
# quarantined artifact can never reach a rendered prompt or rehydration packet.
#
#   - Drops the `.quarantined` file itself.
#   - Drops an original whose `.quarantined` sibling exists.
#   - Keeps ordinary safe originals, preserving input order.
#   - Pure / read-only: it mutates nothing on disk and reads paths only.
#   - Accepts candidates as positional args OR one-per-line on stdin (identical
#     survivors either way).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_dir="$tmp/run-state/RUN-EXCLUDE"
mkdir -p "$run_dir"

# --- Fixtures on disk -------------------------------------------------------
# safe.json          : ordinary safe artifact, no quarantined sibling -> KEEP
# clean-extra.json   : another safe artifact                          -> KEEP
# dirty.json         : original whose .quarantined sibling exists      -> DROP
# dirty.json.quarantined : the quarantined evidence file itself        -> DROP
printf '{"ok":true}\n'      >"$run_dir/safe.json"
printf '{"ok":true}\n'      >"$run_dir/clean-extra.json"
printf '{"leak":"x"}\n'     >"$run_dir/dirty.json.quarantined"
# dirty.json's original is gone (renamed away by quarantine); only the sibling
# remains. The filter must still drop the ORIGINAL candidate path by sibling
# existence, and also drop the .quarantined path outright.

# Snapshot the tree so we can prove the filter is read-only.
before_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"

exclude() {
  GLUERUN_ROOT="$tmp" bash -c '
    source "'"$LIB"'"
    if [[ "$1" == "--stdin" ]]; then
      shift
      printf "%s\n" "$@" | gluerun_ctx_artifact_exclude
    else
      gluerun_ctx_artifact_exclude "$@"
    fi
  ' _ "$@"
}

# --- Case 1: positional args, order-stable ----------------------------------
# Deliberately interleave keep/drop and end on a quarantined path to lock order.
cand=(
  "$run_dir/safe.json"
  "$run_dir/dirty.json"
  "$run_dir/clean-extra.json"
  "$run_dir/dirty.json.quarantined"
)
out="$(exclude "${cand[@]}")" || fail "case1: exclude exited non-zero"
expected="$(printf '%s\n%s\n' "$run_dir/safe.json" "$run_dir/clean-extra.json")"
[[ "$out" == "$expected" ]] \
  || fail "case1: survivors/order wrong. got:[$out] want:[$expected]"

# --- Case 2: stdin form yields identical survivors --------------------------
out_stdin="$(exclude --stdin "${cand[@]}")" || fail "case2: exclude(stdin) exited non-zero"
[[ "$out_stdin" == "$expected" ]] \
  || fail "case2: stdin survivors differ. got:[$out_stdin] want:[$expected]"

# --- Case 3: a quarantined path is dropped even with no sibling on disk ------
# A bare `<x>.quarantined` candidate (no original alongside) is still dropped by
# the suffix rule alone.
out3="$(exclude "$run_dir/safe.json" "$tmp/ghost.json.quarantined")" \
  || fail "case3: exclude exited non-zero"
[[ "$out3" == "$run_dir/safe.json" ]] \
  || fail "case3: bare .quarantined not dropped. got:[$out3]"

# --- Case 4: all-safe input passes through unchanged, order preserved --------
out4="$(exclude "$run_dir/clean-extra.json" "$run_dir/safe.json")" \
  || fail "case4: exclude exited non-zero"
[[ "$out4" == "$(printf '%s\n%s\n' "$run_dir/clean-extra.json" "$run_dir/safe.json")" ]] \
  || fail "case4: safe passthrough/order wrong. got:[$out4]"

# --- Read-only: the filter mutated nothing on disk --------------------------
after_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]] || fail "exclude filter mutated the tree"

echo "ctx-artifact-exclude tests passed"
