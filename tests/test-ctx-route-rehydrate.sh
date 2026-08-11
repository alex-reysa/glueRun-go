#!/usr/bin/env bash
# Covers the rehydrate-vs-fresh routing decision leaf engine/ctx-route-rehydrate.sh:
#   singular_ctx_route_rehydrate_decide <refusal-reason> <role> <step> <manifest-json>
#
# The seam: in the later engine/ctx-route.sh spine a would-be `resume` that is
# refused by a resume gate is emitted as `fresh session-lease`, `fresh
# window-pressure`, or `fresh diff-volume`. On exactly those refused-resume
# lineage-continuation steps, and only behind SINGULAR_REHYDRATE=1, this leaf
# upgrades the bare `fresh <reason>` to `rehydrate <reason>` (fresh session +
# injected durable context), carrying the ORIGINAL refusal reason forward.
#
# Contract asserted here:
#   - OFF-parity: SINGULAR_REHYDRATE unset (or =0) -> ALWAYS `fresh <reason>`,
#     byte-identical to the reason line ctx-route.sh emits today, for every one of
#     the three refusal reasons and every step (pinned or not, empty or not).
#   - ON upgrade: SINGULAR_REHYDRATE=1, a non-pinned lineage-continuation step, and
#     a manifest with >=1 surviving source -> `rehydrate <reason>` for each reason.
#   - Independence guard (evidence invariance): SINGULAR_REHYDRATE=1 with a non-empty
#     manifest still yields `fresh <reason>` for step=final-audit and
#     step=paired-audit; it NEVER rehydrates a pinned step, reusing
#     singular_ctx_route_independence_admit so the independence set stays single-sourced.
#   - Empty-packet guard: SINGULAR_REHYDRATE=1, a non-pinned step, and a manifest
#     whose `sources` array is empty -> `fresh <reason>` (nothing to inject).
#   - Purity / evidence invariance: appends no events, writes/renames/deletes no
#     files, exits 0 on well-formed input, and grants no independence (the
#     `rehydrate` strategy stays tainted per singular_ctx_route_strategy_tainted).
# The predicate is defined only; NO existing engine path invokes it, so with the
# file present-but-uncalled the engine is byte-identical to prior behavior.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_R="$ENGINE_HOME/engine/ctx-route-rehydrate.sh"
CTX_T="$ENGINE_HOME/engine/ctx-route-taint.sh"

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

[[ -f "$CTX_R" ]] || fail "engine not present yet: $CTX_R"
# shellcheck disable=SC1090
source "$CTX_R" || fail "sourcing $CTX_R failed"
# shellcheck disable=SC1090
source "$CTX_T" || fail "sourcing $CTX_T failed"
[[ "$(type -t singular_ctx_route_rehydrate_decide)" == "function" ]] \
  || fail "singular_ctx_route_rehydrate_decide not defined by $CTX_R"

# Manifests: one carrying a surviving source, one whose sources array is empty.
FULL='{"schema":"singular.orchestration.ctx-rehydrate-manifest.v0","sources":[{"id":"task-packet","sha256":"deadbeef"}]}'
EMPTY='{"schema":"singular.orchestration.ctx-rehydrate-manifest.v0","sources":[]}'

REASONS=(session-lease window-pressure diff-volume)

# --- OFF-parity: SINGULAR_REHYDRATE unset/0 -> always `fresh <reason>` ----------
unset SINGULAR_REHYDRATE
for reason in "${REASONS[@]}"; do
  assert_eq "$(singular_ctx_route_rehydrate_decide "$reason" implementer retry-resume "$FULL")" \
    "fresh $reason" "OFF (unset) non-pinned full manifest -> fresh [$reason]"
  # Even a would-be-upgradable case is byte-identical to today when OFF.
  assert_eq "$(singular_ctx_route_rehydrate_decide "$reason" worker retry "$FULL")" \
    "fresh $reason" "OFF (unset) worker retry full manifest -> fresh [$reason]"
done
export SINGULAR_REHYDRATE=0
for reason in "${REASONS[@]}"; do
  assert_eq "$(singular_ctx_route_rehydrate_decide "$reason" implementer retry-resume "$FULL")" \
    "fresh $reason" "OFF (=0) non-pinned full manifest -> fresh [$reason]"
  assert_eq "$(singular_ctx_route_rehydrate_decide "$reason" implementer retry-resume "$EMPTY")" \
    "fresh $reason" "OFF (=0) empty manifest -> fresh [$reason]"
  assert_eq "$(singular_ctx_route_rehydrate_decide "$reason" auditor final-audit "$FULL")" \
    "fresh $reason" "OFF (=0) pinned step -> fresh [$reason]"
done
pass "OFF-parity: SINGULAR_REHYDRATE unset/0 yields fresh <reason> verbatim for all reasons"

# --- ON upgrade: non-pinned step + surviving source -> `rehydrate <reason>` ----
export SINGULAR_REHYDRATE=1
for reason in "${REASONS[@]}"; do
  assert_eq "$(singular_ctx_route_rehydrate_decide "$reason" implementer retry-resume "$FULL")" \
    "rehydrate $reason" "ON non-pinned lineage step full manifest -> rehydrate [$reason]"
  assert_eq "$(singular_ctx_route_rehydrate_decide "$reason" worker retry "$FULL")" \
    "rehydrate $reason" "ON worker retry full manifest -> rehydrate [$reason]"
  assert_eq "$(singular_ctx_route_rehydrate_decide "$reason" planner revise "$FULL")" \
    "rehydrate $reason" "ON planner revise full manifest -> rehydrate [$reason]"
done
pass "ON upgrade: non-pinned lineage-continuation + surviving source -> rehydrate <reason>"

# --- Independence guard: pinned steps never rehydrate -------------------------
for reason in "${REASONS[@]}"; do
  assert_eq "$(singular_ctx_route_rehydrate_decide "$reason" auditor final-audit "$FULL")" \
    "fresh $reason" "ON pinned final-audit full manifest -> fresh [$reason]"
  assert_eq "$(singular_ctx_route_rehydrate_decide "$reason" auditor paired-audit "$FULL")" \
    "fresh $reason" "ON pinned paired-audit full manifest -> fresh [$reason]"
done
# The guard is single-sourced from the independence classifier: for these steps
# singular_ctx_route_independence_admit rehydrate <role> <step> must NOT admit.
for step in final-audit paired-audit; do
  verdict="$(singular_ctx_route_independence_admit rehydrate auditor "$step")"
  [[ "$verdict" != "admit" ]] \
    || fail "independence classifier unexpectedly admitted rehydrate for [$step]"
done
pass "independence guard: final-audit/paired-audit never rehydrate (single-sourced)"

# --- Empty-packet guard: no surviving source -> `fresh <reason>` --------------
for reason in "${REASONS[@]}"; do
  assert_eq "$(singular_ctx_route_rehydrate_decide "$reason" implementer retry-resume "$EMPTY")" \
    "fresh $reason" "ON non-pinned empty manifest -> fresh [$reason]"
done
pass "empty-packet guard: empty sources array -> fresh <reason>"

# --- rehydrate stays tainted: the leaf confers no independence ----------------
assert_eq "$(singular_ctx_route_strategy_tainted rehydrate)" "1" \
  "rehydrate strategy remains tainted"
pass "no independence conferred: rehydrate is tainted per singular_ctx_route_strategy_tainted"

# --- Pure predicate: one line, exit 0, writes no files ------------------------
export SINGULAR_REHYDRATE=1
before="$(find "$SINGULAR_STATE_DIR" -type f | sort)"
# rows: reason|role|step|manifest across ON/pinned/empty branches
rows=(
  "session-lease|implementer|retry-resume|$FULL"
  "window-pressure|auditor|final-audit|$FULL"
  "diff-volume|implementer|retry-resume|$EMPTY"
)
for row in "${rows[@]}"; do
  IFS='|' read -r r ro st mf <<<"$row"
  rc=0; line="$(singular_ctx_route_rehydrate_decide "$r" "$ro" "$st" "$mf")" || rc=$?
  assert_eq "$rc" "0" "decide exit 0 for [$r/$ro/$st]"
  [[ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" == "1" ]] \
    || fail "decide printed more than one line for [$r/$ro/$st]"
  case "$line" in
    "rehydrate $r"|"fresh $r") ;;
    *) fail "decide printed unexpected token [$line] for [$r/$ro/$st]" ;;
  esac
done
after="$(find "$SINGULAR_STATE_DIR" -type f | sort)"
assert_eq "$after" "$before" "predicate writes no files"
pass "contract: pure predicate prints one {rehydrate,fresh} <reason> line, exit 0, writes no files"

echo "ctx-route-rehydrate tests passed"
