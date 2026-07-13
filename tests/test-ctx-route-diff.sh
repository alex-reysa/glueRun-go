#!/usr/bin/env bash
# Covers the diff-volume resume gate leaf brick engine/ctx-route-diff.sh:
# gluerun_ctx_route_diff_gate <role> <worktree> <head-sha-at-create> <lineage-head>
# [role-relevant-paths...] — the second of the two role-available resume
# tripwires the later engine/ctx-route.sh strategy dispatcher consults before it
# may ever return `resume`.
#
# Wall-clock age alone under-measures staleness; this is the churn axis. The gate
# measures churn (git numstat added+deleted) in the role's relevant files between
# headShaAtCreate and the current lineage head and refuses when it exceeds
# GLUERUN_SESSION_DIFF_MAX_LINES.
#
# Contract asserted here:
#   - Churn over threshold in the scoped paths -> exactly `refuse diff-volume`.
#   - Churn at/under threshold -> exactly `pass`.
#   - Role-relevant paths scope the measurement: churn outside the supplied
#     pathspec does not count.
#   - Empty/absent shas or ANY git error -> exactly `refuse diff-volume`
#     (fail closed).
#   - Monotonic-refuse output alphabet: only `pass` or `refuse diff-volume`.
#   - Additive documented knob GLUERUN_SESSION_DIFF_MAX_LINES with a default;
#     never exits non-zero.
# The gate is defined only; NO existing engine path invokes it, so with the file
# present-but-uncalled the engine is byte-identical to prior behavior.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_D="$ENGINE_HOME/engine/ctx-route-diff.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { # <got> <want> <label>
  [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"
}
pass() { echo "ok: $*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GLUERUN_ROOT="$tmp"
export GLUERUN_STATE_DIR="$tmp/state"
mkdir -p "$GLUERUN_STATE_DIR"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

[[ -f "$CTX_D" ]] || fail "engine not present yet: $CTX_D"
# shellcheck disable=SC1090
source "$CTX_D" || fail "sourcing $CTX_D failed"
[[ "$(type -t gluerun_ctx_route_diff_gate)" == "function" ]] \
  || fail "gluerun_ctx_route_diff_gate not defined by $CTX_D"

ROLE="implementer"
export GLUERUN_SESSION_DIFF_MAX_LINES=10

# --- Fixture worktree with a known churn profile -----------------------------
wt="$tmp/worktree"; mkdir -p "$wt/src" "$wt/other"
git -C "$wt" init -q
git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
printf 'a\nb\nc\nd\ne\n' > "$wt/src/a"          # 5 lines
python3 -c 'open("'"$wt"'/other/big","w").write("l\n"*100)'   # 100 lines
git -C "$wt" add .; git -C "$wt" commit -qm c0
HEAD0="$(git -C "$wt" rev-parse HEAD)"

# c1: +3 lines in src/a, +50 lines in other/big.
printf 'a\nb\nc\nd\ne\nf\ng\nh\n' > "$wt/src/a"  # 8 lines (+3)
python3 -c 'open("'"$wt"'/other/big","w").write("l\n"*150)'   # 150 lines (+50)
git -C "$wt" add .; git -C "$wt" commit -qm c1
HEAD1="$(git -C "$wt" rev-parse HEAD)"

# c2: +20 more lines in src/a (pushes scoped src/a churn over threshold).
python3 -c 'open("'"$wt"'/src/a","w").write("x\n"*28)'   # 28 lines (+20 vs c1)
git -C "$wt" add .; git -C "$wt" commit -qm c2
HEAD2="$(git -C "$wt" rev-parse HEAD)"

# c3: +500 lines in other/big — a churn large enough to exceed even the default
# GLUERUN_SESSION_DIFF_MAX_LINES (used only by the default-knob assertion below).
python3 -c 'open("'"$wt"'/other/big","w").write("l\n"*650)'   # 650 lines (+500 vs c1)
git -C "$wt" add .; git -C "$wt" commit -qm c3
HEAD3="$(git -C "$wt" rev-parse HEAD)"

# --- Scoped churn at/under threshold -> pass ---------------------------------
# HEAD0..HEAD1 in src/a = 3 added <= 10.
out="$(gluerun_ctx_route_diff_gate "$ROLE" "$wt" "$HEAD0" "$HEAD1" -- src)"
assert_eq "$out" "pass" "scoped churn under threshold passes"
pass "gate: churn in role-relevant paths at/under threshold -> pass"

# --- Scoping proof: the 50-line churn in other/big is excluded ---------------
# Same range, whole tree = 3 + 50 = 53 added > 10 -> refuse. Scoping to src is
# what made the previous assertion pass, so the pathspec genuinely scopes.
out="$(gluerun_ctx_route_diff_gate "$ROLE" "$wt" "$HEAD0" "$HEAD1")"
assert_eq "$out" "refuse diff-volume" "unscoped whole-tree churn exceeds threshold"
pass "gate: role-relevant pathspec scopes the measurement (unscoped 53 lines refuses; scoped 3 lines passed)"

# --- Scoped churn over threshold -> refuse diff-volume -----------------------
# HEAD0..HEAD2 in src/a = 3 + (churn of the 20-line rewrite) > 10 -> refuse.
out="$(gluerun_ctx_route_diff_gate "$ROLE" "$wt" "$HEAD0" "$HEAD2" -- src)"
assert_eq "$out" "refuse diff-volume" "scoped churn over threshold refuses"
pass "gate: churn in role-relevant paths over GLUERUN_SESSION_DIFF_MAX_LINES -> refuse diff-volume"

# --- Fail closed: empty / absent shas ----------------------------------------
out="$(gluerun_ctx_route_diff_gate "$ROLE" "$wt" "" "$HEAD1" -- src)"
assert_eq "$out" "refuse diff-volume" "empty head-sha-at-create fails closed"
out="$(gluerun_ctx_route_diff_gate "$ROLE" "$wt" "$HEAD0" "" -- src)"
assert_eq "$out" "refuse diff-volume" "empty lineage head fails closed"
out="$(gluerun_ctx_route_diff_gate "$ROLE" "$wt" "" "" -- src)"
assert_eq "$out" "refuse diff-volume" "both shas empty fails closed"
pass "gate: empty/absent shas -> refuse diff-volume (fail closed)"

# --- Fail closed: git cannot compute the diff --------------------------------
out="$(gluerun_ctx_route_diff_gate "$ROLE" "$wt" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$HEAD1" -- src)"
assert_eq "$out" "refuse diff-volume" "nonexistent sha fails closed"
out="$(gluerun_ctx_route_diff_gate "$ROLE" "$tmp/not-a-repo" "$HEAD0" "$HEAD1" -- src)"
assert_eq "$out" "refuse diff-volume" "non-repo worktree fails closed"
pass "gate: any git error -> refuse diff-volume (fail closed)"

# --- Additive knob default: a finite, working default threshold --------------
# With the knob unset, defaults apply. A churn well above the default refuses...
out="$(env -u GLUERUN_SESSION_DIFF_MAX_LINES bash -c '
         source "'"$LIB"'"; source "'"$CTX_D"'"
         gluerun_ctx_route_diff_gate '"$ROLE"' "'"$wt"'" "'"$HEAD0"'" "'"$HEAD3"'"')"
assert_eq "$out" "refuse diff-volume" "default threshold refuses a >500-line whole-tree churn"
# ...and a tiny scoped churn passes under the same default.
out="$(env -u GLUERUN_SESSION_DIFF_MAX_LINES bash -c '
         source "'"$LIB"'"; source "'"$CTX_D"'"
         gluerun_ctx_route_diff_gate '"$ROLE"' "'"$wt"'" "'"$HEAD0"'" "'"$HEAD1"'" -- src')"
assert_eq "$out" "pass" "default threshold passes a 3-line scoped churn"
pass "gate: GLUERUN_SESSION_DIFF_MAX_LINES defaults to a finite working value"

# --- Monotonic-refuse output alphabet: only pass|refuse diff-volume ----------
for args in \
  "$ROLE $wt $HEAD0 $HEAD1 -- src" \
  "$ROLE $wt $HEAD0 $HEAD1" \
  "$ROLE $wt  $HEAD1 -- src" \
  "$ROLE $tmp/not-a-repo $HEAD0 $HEAD1 -- src"; do
  # shellcheck disable=SC2086
  out="$(gluerun_ctx_route_diff_gate $args)"
  case "$out" in
    pass|"refuse diff-volume") : ;;
    *) fail "output alphabet violated: [$out]" ;;
  esac
done
pass "gate: output alphabet is exactly {pass, refuse diff-volume} (monotonic-refuse)"

# --- Contract: exactly one line, never exits non-zero ------------------------
rc=0
lines="$(gluerun_ctx_route_diff_gate "$ROLE" "$wt" "$HEAD0" "$HEAD2" -- src)" || rc=$?
assert_eq "$rc" "0" "gate exit code is 0 on refuse"
[[ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" == "1" ]] || fail "gate printed more than one line"
rc=0
lines="$(gluerun_ctx_route_diff_gate "$ROLE" "$wt" "$HEAD0" "$HEAD1" -- src)" || rc=$?
assert_eq "$rc" "0" "gate exit code is 0 on pass"
[[ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" == "1" ]] || fail "gate printed more than one line"
rc=0
gluerun_ctx_route_diff_gate "$ROLE" "$wt" "" "$HEAD1" -- src >/dev/null || rc=$?
assert_eq "$rc" "0" "gate exit code is 0 on fail-closed refuse"
pass "contract: prints exactly one line, never exits non-zero"

echo "ctx-route-diff tests passed"
