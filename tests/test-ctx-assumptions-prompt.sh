#!/usr/bin/env bash
# Covers the pure prompt-render brick of the per-run assumption ledger
# (stage S4-context-packets, node assumption-ledger). `engine/ctx-assumptions-prompt.sh`
# ships two PURE, present-but-uncalled helpers
#   gluerun_ctx_assumptions_fix_section   <ledger-json>
#   gluerun_ctx_assumptions_audit_section <ledger-json>
# that are string->string transforms over the ledger argument: they read no files,
# consult no flag, emit no events, and print a rendered prompt section on stdout.
#
#   - FIX SECTION: given a ledger with at least one `violated` assumption, foregrounds
#     each violated assumption like an open finding (with its id and claim) and lists
#     the remaining (non-violated) assumptions for context, in id order (A1, A2, ...).
#   - AUDIT SECTION: instructs the auditor to verify the assumptions were not silently
#     violated and to raise a finding CITING the assumption's id for any violation, then
#     lists every assumption with its id (in id order) so the resulting finding carries
#     the assumptionId the host-derived transition consumes.
#   - EMPTY: a ledger with zero assumptions, or an absent/empty ledger, makes both
#     helpers render the empty string (a later wire-in then injects nothing).
#   - Pure + deterministic: identical ledger input yields byte-identical output across
#     runs; neither helper touches the filesystem or emits events.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected [$2] in [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Invoke the real engine helpers in an isolated subshell so lib.sh's `set -e` and the
# sourced ctx-*.sh files never contaminate this test process. GLUERUN_ROOT is a scratch
# dir the helpers must NOT touch (they are pure string->string transforms). The ledger
# JSON is passed as a positional arg to avoid quoting surprises.
fix_section() {
  local ledger="$1"
  GLUERUN_ROOT="$tmp" bash -c '
    source "'"$LIB"'"
    gluerun_ctx_assumptions_fix_section "$1"
  ' _ "$ledger"
}
audit_section() {
  local ledger="$1"
  GLUERUN_ROOT="$tmp" bash -c '
    source "'"$LIB"'"
    gluerun_ctx_assumptions_audit_section "$1"
  ' _ "$ledger"
}

# --- Fixtures ---------------------------------------------------------------

# A seeded/transitioned ledger with a mix of statuses; A2 is host-flipped `violated`.
LEDGER='{"schema":"gluerun.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A1","status":"open","claim":"runtime is node 20","basis":"package.json engines field"},
  {"id":"A2","status":"violated","claim":"db schema already migrated","basis":"verified in db.ts"},
  {"id":"A3","status":"open","claim":"the cache is warm","basis":"cold-start trace"}
]}'

# --- Case 1: fix section foregrounds violated assumptions like open findings ---
fix1="$(fix_section "$LEDGER")" || fail "case1: fix_section exited non-zero"
[[ -n "$fix1" ]] || fail "case1: fix section empty for a populated ledger"
assert_contains "$fix1" "A2" "case1: violated id present"
assert_contains "$fix1" "db schema already migrated" "case1: violated claim present"
# Non-violated assumptions appear for context.
assert_contains "$fix1" "A1" "case1: context id A1 present"
assert_contains "$fix1" "runtime is node 20" "case1: context claim present"
assert_contains "$fix1" "A3" "case1: context id A3 present"
# The violated assumption is foregrounded: A2 appears before the context ids A1/A3.
python3 - "$fix1" <<'PY' || fail "case1: violated assumption not foregrounded"
import sys
s = sys.argv[1]
# The violated id must appear before any non-violated context id.
i2 = s.index("A2")
i1 = s.index("A1")
i3 = s.index("A3")
sys.exit(0 if i2 < i1 and i2 < i3 else 1)
PY
# Context (non-violated) ids are listed in id order: A1 before A3.
python3 - "$fix1" <<'PY' || fail "case1: context ids not in id order"
import sys
s = sys.argv[1]
sys.exit(0 if s.index("A1") < s.index("A3") else 1)
PY

# --- Case 2: audit section instructs verify + cite id, lists every assumption --
aud1="$(audit_section "$LEDGER")" || fail "case2: audit_section exited non-zero"
[[ -n "$aud1" ]] || fail "case2: audit section empty for a populated ledger"
# Every assumption id is listed so an auditor finding can cite it.
assert_contains "$aud1" "A1" "case2: id A1 listed"
assert_contains "$aud1" "A2" "case2: id A2 listed"
assert_contains "$aud1" "A3" "case2: id A3 listed"
# Claims are shown alongside their ids.
assert_contains "$aud1" "runtime is node 20" "case2: claim A1 shown"
assert_contains "$aud1" "db schema already migrated" "case2: claim A2 shown"
# The auditor is instructed to verify no silent violation and to raise a finding.
assert_contains "$aud1" "violat" "case2: mentions violation"
assert_contains "$aud1" "finding" "case2: instructs raising a finding"
# The finding must cite the assumption id — the assumptionId key the transition consumes.
assert_contains "$aud1" "assumptionId" "case2: directs citing the assumptionId"
# Audit lists assumptions in id order A1, A2, A3.
python3 - "$aud1" <<'PY' || fail "case2: audit ids not in id order"
import sys
s = sys.argv[1]
sys.exit(0 if s.index("A1") < s.index("A2") < s.index("A3") else 1)
PY

# --- Case 3: empty / absent ledger -> both helpers render the empty string -----
for empty in '{"schema":"gluerun.orchestration.ctx-assumptions.v0","assumptions":[]}' '{}' '' 'not-json'; do
  ef="$(fix_section "$empty")" || fail "case3: fix_section exited non-zero for [$empty]"
  ea="$(audit_section "$empty")" || fail "case3: audit_section exited non-zero for [$empty]"
  [[ -z "$ef" ]] || fail "case3: fix section not empty for [$empty]; got [$ef]"
  [[ -z "$ea" ]] || fail "case3: audit section not empty for [$empty]; got [$ea]"
done

# --- Case 4: deterministic -> identical input yields byte-identical output ------
fix1b="$(fix_section "$LEDGER")" || fail "case4: fix_section exited non-zero"
aud1b="$(audit_section "$LEDGER")" || fail "case4: audit_section exited non-zero"
[[ "$fix1" == "$fix1b" ]] || fail "case4: fix section not deterministic"
[[ "$aud1" == "$aud1b" ]] || fail "case4: audit section not deterministic"

# --- Case 5: ledger with no violated -> fix still lists assumptions as context --
CLEAN='{"schema":"gluerun.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A1","status":"open","claim":"runtime is node 20","basis":"b1"},
  {"id":"A2","status":"validated","claim":"db schema already migrated","basis":"b2"}
]}'
fix5="$(fix_section "$CLEAN")" || fail "case5: fix_section exited non-zero"
assert_contains "$fix5" "A1" "case5: id A1 present with no violations"
assert_contains "$fix5" "A2" "case5: id A2 present with no violations"

# --- Case 6: pure -> writes nothing to the filesystem, emits no events ---------
pure="$tmp/pure"
mkdir -p "$pure"
GLUERUN_ROOT="$pure" bash -c '
  source "'"$LIB"'"
  gluerun_ctx_assumptions_fix_section "$1" >/dev/null
  gluerun_ctx_assumptions_audit_section "$1" >/dev/null
' _ "$LEDGER" || fail "case6: helpers exited non-zero"
n="$(find "$pure" -type f | wc -l | tr -d ' ')"
[[ "$n" -eq 0 ]] || fail "case6: helpers wrote $n file(s); must be pure transforms"

echo "ctx-assumptions-prompt tests passed"
