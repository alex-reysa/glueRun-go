#!/usr/bin/env bash
# Covers the host-derived status-transition brick of the per-run assumption ledger
# (stage S4-context-packets, node assumption-ledger). `engine/ctx-assumptions-transition.sh`
# ships a PURE, present-but-uncalled helper
#   singular_ctx_assumptions_transition <ledger-json> <findings-json>
# that is a ledger->ledger transform: it reads BOTH JSON arguments (no file I/O, no
# events) and prints an updated ledger JSON on stdout whose `schema` const is
# `singular.orchestration.ctx-assumptions.v0` with an `assumptions` array plus an
# additive, non-authoritative top-level `claims` array.
#
#   - HOST-DERIVED: for every finding whose `assumptionId` matches a ledger entry
#     `id`, that entry's `status` becomes `violated` AUTHORITATIVELY, regardless of
#     any model-asserted status on the finding. Entries referenced by no resolvable
#     finding keep their seeded `status`, `claim`, `basis` unchanged.
#   - HOST/MODEL BOUNDARY: a finding whose `assumptionId` is missing or does not
#     resolve to a ledger `id` NEVER mutates `assumptions`; it is recorded in the
#     additive `claims` array, each entry marked model-sourced (`source":"model"`).
#   - Empty findings ([]) leave `assumptions` unchanged with an empty `claims`.
#   - Idempotent + deterministic: applying twice, or passing several findings that
#     reference the same id, yields byte-identical output; `assumptions` stay in id
#     order (A1, A2, ...).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Invoke the real engine helper in an isolated subshell so lib.sh's `set -e` and the
# sourced ctx-*.sh files never contaminate this test process. SINGULAR_ROOT is a
# scratch dir; the function must NOT touch it (it is a pure JSON->JSON transform).
# JSON is passed as positional args to avoid any quoting surprises.
transition() {
  local ledger="$1" findings="$2"
  SINGULAR_ROOT="$tmp" bash -c '
    source "'"$LIB"'"
    singular_ctx_assumptions_transition "$1" "$2"
  ' _ "$ledger" "$findings"
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

# A seeded ledger exactly in the shape singular_ctx_assumptions_seed emits.
SEED='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A1","status":"open","claim":"runtime is node 20","basis":"package.json engines field"},
  {"id":"A2","status":"validated","claim":"db schema already migrated","basis":"verified in db.ts"},
  {"id":"A3","status":"open","claim":"the cache is warm","basis":"cold-start trace"}
]}'

# --- Case 1: host-derived flip -> matched id becomes violated ----------------
FIND_A2='[{"assumptionId":"A2","detail":"auditor saw a stale row"}]'
out1="$(transition "$SEED" "$FIND_A2")" || fail "case1: transition exited non-zero"
expected1='{"schema":"singular.orchestration.ctx-assumptions.v0","claims":[],"assumptions":[
  {"id":"A1","status":"open","claim":"runtime is node 20","basis":"package.json engines field"},
  {"id":"A2","status":"violated","claim":"db schema already migrated","basis":"verified in db.ts"},
  {"id":"A3","status":"open","claim":"the cache is warm","basis":"cold-start trace"}
]}'
json_eq "$out1" "$expected1" || fail "case1: ledger mismatch; got [$out1]"
assert_contains "$out1" '"singular.orchestration.ctx-assumptions.v0"' "case1: schema const present"
assert_contains "$out1" '"assumptions"' "case1: assumptions array present"
assert_contains "$out1" '"claims"' "case1: additive claims array present"

# --- Case 2: host authority overrides any model-asserted status -------------
# The finding asserts status "validated"; the host MUST flip A1 to violated anyway.
FIND_A1_LIE='[{"assumptionId":"A1","status":"validated","detail":"model insists it holds"}]'
out2="$(transition "$SEED" "$FIND_A1_LIE")" || fail "case2: transition exited non-zero"
expected2='{"schema":"singular.orchestration.ctx-assumptions.v0","claims":[],"assumptions":[
  {"id":"A1","status":"violated","claim":"runtime is node 20","basis":"package.json engines field"},
  {"id":"A2","status":"validated","claim":"db schema already migrated","basis":"verified in db.ts"},
  {"id":"A3","status":"open","claim":"the cache is warm","basis":"cold-start trace"}
]}'
json_eq "$out2" "$expected2" || fail "case2: host authority not enforced; got [$out2]"

# --- Case 3: host/model boundary -> unresolvable findings become claims ------
# A99 is unknown; the second finding has no assumptionId. Neither may mutate a
# status; both land in the non-authoritative, model-sourced claims array.
FIND_MODEL='[{"assumptionId":"A99","status":"violated"},{"status":"open","detail":"free assertion"}]'
out3="$(transition "$SEED" "$FIND_MODEL")" || fail "case3: transition exited non-zero"
expected3='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A1","status":"open","claim":"runtime is node 20","basis":"package.json engines field"},
  {"id":"A2","status":"validated","claim":"db schema already migrated","basis":"verified in db.ts"},
  {"id":"A3","status":"open","claim":"the cache is warm","basis":"cold-start trace"}
],"claims":[
  {"assumptionId":"A99","status":"violated","source":"model"},
  {"assumptionId":null,"status":"open","source":"model"}
]}'
json_eq "$out3" "$expected3" || fail "case3: model boundary mismatch; got [$out3]"
assert_contains "$out3" '"source": "model"' "case3: claims marked model-sourced"

# --- Case 4: empty findings -> assumptions unchanged, empty claims -----------
out4="$(transition "$SEED" '[]')" || fail "case4: transition exited non-zero"
expected4='{"schema":"singular.orchestration.ctx-assumptions.v0","claims":[],"assumptions":[
  {"id":"A1","status":"open","claim":"runtime is node 20","basis":"package.json engines field"},
  {"id":"A2","status":"validated","claim":"db schema already migrated","basis":"verified in db.ts"},
  {"id":"A3","status":"open","claim":"the cache is warm","basis":"cold-start trace"}
]}'
json_eq "$out4" "$expected4" || fail "case4: empty findings altered ledger; got [$out4]"

# --- Case 5: idempotent under re-application (host authority is a set) -------
out1b="$(transition "$out1" "$FIND_A2")" || fail "case5: re-application exited non-zero"
[[ "$out1" == "$out1b" ]] || fail "case5: transform not idempotent; [$out1] != [$out1b]"

# --- Case 6: several findings on the same id collapse to one violated flip ---
FIND_A2_TWICE='[{"assumptionId":"A2","detail":"first"},{"assumptionId":"A2","detail":"second"}]'
out6="$(transition "$SEED" "$FIND_A2_TWICE")" || fail "case6: transition exited non-zero"
[[ "$out6" == "$out1" ]] || fail "case6: duplicate ids not deterministic; [$out6] != [$out1]"

# --- Case 7: deterministic + id-ordered across repeated runs -----------------
out1c="$(transition "$SEED" "$FIND_A2")" || fail "case7: transition exited non-zero"
[[ "$out1" == "$out1c" ]] || fail "case7: output not deterministic across runs"
# Assumptions appear in id order A1, A2, A3.
python3 - "$out1" <<'PY' || fail "case7: assumptions not in id order"
import json, sys
o = json.loads(sys.argv[1])
ids = [a["id"] for a in o["assumptions"]]
sys.exit(0 if ids == ["A1", "A2", "A3"] else 1)
PY

# --- Case 8: empty ledger -> stable empty ledger, findings still segregate ----
EMPTY='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[]}'
out8="$(transition "$EMPTY" "$FIND_A2")" || fail "case8: transition exited non-zero"
expected8='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[],"claims":[
  {"assumptionId":"A2","status":null,"source":"model"}
]}'
json_eq "$out8" "$expected8" || fail "case8: empty-ledger transition mismatch; got [$out8]"

# --- Case 9: pure -> writes nothing to the filesystem -----------------------
# Run with SINGULAR_ROOT pointing at an empty scratch dir and assert it stays empty:
# the function performs no file I/O and emits no events.
pure="$tmp/pure"
mkdir -p "$pure"
SINGULAR_ROOT="$pure" bash -c '
  source "'"$LIB"'"
  singular_ctx_assumptions_transition "$1" "$2"
' _ "$SEED" "$FIND_A2" >/dev/null 2>&1 || fail "case9: transition exited non-zero"
n="$(find "$pure" -type f | wc -l | tr -d ' ')"
[[ "$n" -eq 0 ]] || fail "case9: transition wrote $n file(s); must be a pure transform"

echo "ctx-assumptions-transition tests passed"
