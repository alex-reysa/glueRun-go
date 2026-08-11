#!/usr/bin/env bash
# Covers the pure leaf of DAG node `rehydrate-path` (stage S5-routing, layer
# engine_runtime): the read-only decision-record extra-spec producer
# `engine/ctx-rehydrate-decision-source.sh`.
#
#   singular_ctx_rehydrate_decision_source [base_dir]
#
# Prints the single class-tagged extra spec
#   decision-record=<base_dir>/docs/orchestration/decisions.md
# when that durable orchestration decision log EXISTS under base_dir (default
# ${SINGULAR_ROOT:-.}), and prints nothing otherwise. It is deterministic,
# existence-gated, read-only (writes/renames/deletes nothing, appends no events),
# never exits non-zero, and performs NO quarantine filtering of its own (the
# assembler owns the single quarantine authority). It confers NO independence:
# `rehydrate` stays tainted.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

decision_source() {
  bash -c '
    source "'"$LIB"'"
    singular_ctx_rehydrate_decision_source "$@"
  ' _ "$@"
}

# --- Case 1: present decision log -> exactly one class-tagged spec -----------
base_dir="$tmp/repo"
mkdir -p "$base_dir/docs/orchestration"
printf '# Decisions\n- keep it deterministic\n' > "$base_dir/docs/orchestration/decisions.md"

before_hash="$(find "$base_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"

out="$(decision_source "$base_dir")" || fail "case1: leaf exited non-zero"
want="decision-record=$base_dir/docs/orchestration/decisions.md"
[[ "$out" == "$want" ]] || fail "case1: wrong spec.
got:   [$out]
want:  [$want]"

# --- Case 2: determinism ----------------------------------------------------
out2="$(decision_source "$base_dir")" || fail "case2: leaf(2) exited non-zero"
[[ "$out" == "$out2" ]] || fail "case2: leaf not deterministic"

# --- Case 3: absent decision log -> nothing, rc 0 ---------------------------
missing_base="$tmp/no-decisions"
mkdir -p "$missing_base/docs/orchestration"
empty="$(decision_source "$missing_base")" || fail "case3: leaf exited non-zero (absent)"
[[ -z "$empty" ]] || fail "case3: absent decision log yielded output: [$empty]"

# absent base_dir entirely -> nothing, rc 0
gone="$(decision_source "$tmp/does-not-exist")" || fail "case3: leaf exited non-zero (missing base)"
[[ -z "$gone" ]] || fail "case3: missing base_dir yielded output: [$gone]"

# --- Case 4: default base_dir from SINGULAR_ROOT -----------------------------
out_default="$(SINGULAR_ROOT="$base_dir" decision_source)" || fail "case4: leaf(default) exited non-zero"
[[ "$out_default" == "$want" ]] || fail "case4: default base_dir (SINGULAR_ROOT) wrong.
got:   [$out_default]
want:  [$want]"

# --- Case 5: no quarantine filtering of its own -----------------------------
# A `.quarantined` sibling of the decision log does NOT change the leaf's output:
# the leaf performs no quarantine filtering (the assembler owns that authority).
printf '{"leak":"q"}\n' > "$base_dir/docs/orchestration/decisions.md.quarantined"
out_q="$(decision_source "$base_dir")" || fail "case5: leaf(quarantine) exited non-zero"
[[ "$out_q" == "$want" ]] || fail "case5: leaf applied quarantine filtering of its own.
got:   [$out_q]
want:  [$want]"
rm -f "$base_dir/docs/orchestration/decisions.md.quarantined"

# --- Case 6: purity / read-only ---------------------------------------------
snap_before="$(find "$base_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
decision_source "$base_dir" >/dev/null 2>&1 || fail "case6: leaf exited non-zero"
snap_after="$(find "$base_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
[[ "$snap_before" == "$snap_after" ]] || fail "case6: leaf mutated the tree (not read-only)"
[[ "$before_hash" == "$snap_before" ]] || fail "case6: fixtures drifted before purity snapshot (harness bug)"

# --- Case 7: confers no independence ----------------------------------------
tainted="$(bash -c 'source "'"$LIB"'"; singular_ctx_route_strategy_tainted rehydrate')" \
  || fail "case7: taint query exited non-zero"
[[ "$tainted" == "1" ]] || fail "case7: rehydrate strategy no longer tainted (got [$tainted])"

echo "ctx-rehydrate-decision-source tests passed"
