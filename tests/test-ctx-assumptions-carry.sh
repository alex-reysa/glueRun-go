#!/usr/bin/env bash
# Covers the pure per-attempt carry brick of the per-run assumption ledger
# (stage S4-context-packets, node assumption-ledger). `engine/ctx-assumptions-carry.sh`
# ships a PURE, present-but-uncalled helper
#   singular_ctx_assumptions_carry <prior-ledger-json> <seed-ledger-json>
# that merges the prior attempt's ledger into the current attempt's fresh seed so a
# host-observed `violated` status carries forward across retries — like an open finding
# that persists until addressed — while the current seed stays the STRUCTURAL AUTHORITY.
# It reads BOTH JSON arguments (no file I/O, no events) and prints a ledger JSON on
# stdout whose `schema` const is `singular.orchestration.ctx-assumptions.v0` with an
# `assumptions` array in `id` order.
#
#   - STRUCTURAL AUTHORITY = the seed: the output has EXACTLY the seed's assumption ids,
#     each carrying the seed's `claim` and `basis`; ids present only in the prior ledger
#     are NOT resurrected, and ids new in the seed keep their seed `status`.
#   - STICKY VIOLATION: for a seed entry whose id appears in the prior ledger with
#     `status` `violated`, the output status is `violated`; otherwise it is the seed's
#     status.
#   - FIRST ATTEMPT / EMPTY PRIOR: an empty, absent, or `{}` prior yields the seed
#     unchanged (carry is identity on the seed).
#   - Deterministic + read-only: identical inputs yield byte-identical output; re-carrying
#     an already-carried ledger against the same prior is stable; neither input is mutated.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Invoke the real engine helper in an isolated subshell so lib.sh's `set -e` and the
# sourced ctx-*.sh files never contaminate this test process. SINGULAR_ROOT is a scratch
# dir; the function must NOT touch it (it is a pure JSON->JSON transform). JSON is passed
# as positional args to avoid any quoting surprises.
carry() {
  local prior="$1" seed="$2"
  SINGULAR_ROOT="$tmp" bash -c '
    source "'"$LIB"'"
    singular_ctx_assumptions_carry "$1" "$2"
  ' _ "$prior" "$seed"
}

json_eq() { # $1 = actual stdout, $2 = expected json literal
  python3 - "$1" "$2" <<'PY'
import json, sys
a = json.loads(sys.argv[1])
b = json.loads(sys.argv[2])
sys.exit(0 if a == b else 1)
PY
}

# --- Fixtures ---------------------------------------------------------------

# A fresh seed exactly in the shape singular_ctx_assumptions_seed emits for the current
# attempt. This is the per-run structural authority and is unchanged between attempts.
SEED='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A1","status":"open","claim":"runtime is node 20","basis":"package.json engines field"},
  {"id":"A2","status":"validated","claim":"db schema already migrated","basis":"verified in db.ts"},
  {"id":"A3","status":"open","claim":"the cache is warm","basis":"cold-start trace"}
]}'

# --- Case 1: sticky violation carries forward across the retry ---------------
# The prior attempt observed A2 violated (host-derived). A fresh seed re-seeds A2 as
# `validated`, but the violation must carry forward like an open finding until addressed.
PRIOR_A2_VIOLATED='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A1","status":"open","claim":"runtime is node 20","basis":"package.json engines field"},
  {"id":"A2","status":"violated","claim":"db schema already migrated","basis":"verified in db.ts"},
  {"id":"A3","status":"open","claim":"the cache is warm","basis":"cold-start trace"}
]}'
out1="$(carry "$PRIOR_A2_VIOLATED" "$SEED")" || fail "case1: carry exited non-zero"
expected1='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A1","status":"open","claim":"runtime is node 20","basis":"package.json engines field"},
  {"id":"A2","status":"violated","claim":"db schema already migrated","basis":"verified in db.ts"},
  {"id":"A3","status":"open","claim":"the cache is warm","basis":"cold-start trace"}
]}'
json_eq "$out1" "$expected1" || fail "case1: sticky violation not carried; got [$out1]"
assert_contains "$out1" '"singular.orchestration.ctx-assumptions.v0"' "case1: schema const present"
assert_contains "$out1" '"assumptions"' "case1: assumptions array present"

# --- Case 2: seed stays the structural authority for claim/basis ------------
# The prior ledger carries a DIFFERENT claim/basis for A2 (stale from a prior packet).
# Carry keeps A2 violated (sticky) but claim/basis MUST come from the current seed.
PRIOR_STALE='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A2","status":"violated","claim":"STALE CLAIM","basis":"STALE BASIS"}
]}'
out2="$(carry "$PRIOR_STALE" "$SEED")" || fail "case2: carry exited non-zero"
json_eq "$out2" "$expected1" || fail "case2: seed not structural authority; got [$out2]"

# --- Case 3: ids only in the prior are NOT resurrected ----------------------
# A9 exists (violated) only in the prior; the seed never declares it. Output has exactly
# the seed's ids A1,A2,A3 — A9 is dropped.
PRIOR_EXTRA='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A9","status":"violated","claim":"gone next attempt","basis":"removed from packet"}
]}'
out3="$(carry "$PRIOR_EXTRA" "$SEED")" || fail "case3: carry exited non-zero"
json_eq "$out3" "$SEED" || fail "case3: prior-only id resurrected; got [$out3]"
python3 - "$out3" <<'PY' || fail "case3: A9 leaked into output"
import json, sys
o = json.loads(sys.argv[1])
ids = [a["id"] for a in o["assumptions"]]
sys.exit(0 if ids == ["A1", "A2", "A3"] and "A9" not in ids else 1)
PY

# --- Case 4: non-violated prior status does NOT override the seed status -----
# A1 was `validated` in the prior but is `open` in the fresh seed. Only `violated` is
# sticky; every other prior status is discarded in favor of the seed's status.
PRIOR_NONVIOLATED='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A1","status":"validated","claim":"runtime is node 20","basis":"package.json engines field"}
]}'
out4="$(carry "$PRIOR_NONVIOLATED" "$SEED")" || fail "case4: carry exited non-zero"
json_eq "$out4" "$SEED" || fail "case4: non-violated prior status leaked; got [$out4]"

# --- Case 5: first attempt / empty prior -> seed unchanged (identity) --------
out5a="$(carry '' "$SEED")" || fail "case5a: carry exited non-zero"
json_eq "$out5a" "$SEED" || fail "case5a: empty-string prior not identity; got [$out5a]"
out5b="$(carry '{}' "$SEED")" || fail "case5b: carry exited non-zero"
json_eq "$out5b" "$SEED" || fail "case5b: {} prior not identity; got [$out5b]"
EMPTY_LEDGER='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[]}'
out5c="$(carry "$EMPTY_LEDGER" "$SEED")" || fail "case5c: carry exited non-zero"
json_eq "$out5c" "$SEED" || fail "case5c: empty-assumptions prior not identity; got [$out5c]"

# --- Case 6: new-in-seed ids keep their seed status -------------------------
# The prior only knows A1 (violated). A2/A3 are new in the seed and keep seed status.
PRIOR_A1='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A1","status":"violated","claim":"runtime is node 20","basis":"package.json engines field"}
]}'
out6="$(carry "$PRIOR_A1" "$SEED")" || fail "case6: carry exited non-zero"
expected6='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A1","status":"violated","claim":"runtime is node 20","basis":"package.json engines field"},
  {"id":"A2","status":"validated","claim":"db schema already migrated","basis":"verified in db.ts"},
  {"id":"A3","status":"open","claim":"the cache is warm","basis":"cold-start trace"}
]}'
json_eq "$out6" "$expected6" || fail "case6: new-in-seed status not preserved; got [$out6]"

# --- Case 7: deterministic + id-ordered across repeated runs ----------------
out1b="$(carry "$PRIOR_A2_VIOLATED" "$SEED")" || fail "case7: carry exited non-zero"
[[ "$out1" == "$out1b" ]] || fail "case7: output not deterministic; [$out1] != [$out1b]"
python3 - "$out1" <<'PY' || fail "case7: assumptions not in id order"
import json, sys
o = json.loads(sys.argv[1])
ids = [a["id"] for a in o["assumptions"]]
sys.exit(0 if ids == ["A1", "A2", "A3"] else 1)
PY

# --- Case 8: re-carrying an already-carried ledger is stable ----------------
# Carry(prior, carry(prior, seed)) == carry(prior, seed): carry is a fixed point when
# the seed already reflects the prior's sticky violations.
out8="$(carry "$PRIOR_A2_VIOLATED" "$out1")" || fail "case8: carry exited non-zero"
[[ "$out8" == "$out1" ]] || fail "case8: re-carry not stable; [$out8] != [$out1]"

# --- Case 9: empty seed -> stable empty ledger ------------------------------
out9="$(carry "$PRIOR_A2_VIOLATED" "$EMPTY_LEDGER")" || fail "case9: carry exited non-zero"
json_eq "$out9" "$EMPTY_LEDGER" || fail "case9: empty-seed carry mismatch; got [$out9]"

# --- Case 10: pure -> writes nothing to the filesystem ----------------------
# Run with SINGULAR_ROOT pointing at an empty scratch dir and assert it stays empty:
# the function performs no file I/O and emits no events.
pure="$tmp/pure"
mkdir -p "$pure"
SINGULAR_ROOT="$pure" bash -c '
  source "'"$LIB"'"
  singular_ctx_assumptions_carry "$1" "$2"
' _ "$PRIOR_A2_VIOLATED" "$SEED" >/dev/null 2>&1 || fail "case10: carry exited non-zero"
n="$(find "$pure" -type f | wc -l | tr -d ' ')"
[[ "$n" -eq 0 ]] || fail "case10: carry wrote $n file(s); must be a pure transform"

echo "ctx-assumptions-carry tests passed"
