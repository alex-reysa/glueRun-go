#!/usr/bin/env bash
# Covers the generalized session-lease read helpers leaf brick
# engine/ctx-route-lease.sh:
#   singular_ctx_route_session_lease_path <role> <key>
#   singular_ctx_route_session_lease_live <lease-path>
#
# These generalize the Stage-1 planner-only lease discipline
# (singular_planner_resume_lease_path / _live, hard-coded to
# sessions/planner/<node>.lease) to every persisted session of any role, so a
# router of any role can refuse resume while another fanout holds the session.
#
# Contract asserted here:
#   - _path prints the canonical role-generic lease path
#     <state-dir>/sessions/<role>/<key>.lease with state-dir
#     ${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}. Empty role OR empty key
#     -> empty string (caller decides).
#   - _live is fail-closed: no file -> not-live (free); a live PID -> live (held);
#     a dead PID -> not-live (free; a crashed holder is not concurrency); a lease
#     with no parseable PID -> live (held; cannot prove free -> fail closed).
#     Liveness is reported by RETURN STATUS; the helper never exits the shell
#     non-zero abnormally.
#   - It reproduces the integrated planner lease helper's verdicts for the
#     planner role/key.
# The helpers are defined only; NO existing engine path invokes them, so with the
# file present-but-uncalled the engine is byte-identical to prior behavior.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_L="$ENGINE_HOME/engine/ctx-route-lease.sh"
CTX_PLANNER="$ENGINE_HOME/engine/ctx-planner-resume.sh"

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

[[ -f "$CTX_L" ]] || fail "engine not present yet: $CTX_L"
# shellcheck disable=SC1090
source "$CTX_L" || fail "sourcing $CTX_L failed"
[[ "$(type -t singular_ctx_route_session_lease_path)" == "function" ]] \
  || fail "singular_ctx_route_session_lease_path not defined by $CTX_L"
[[ "$(type -t singular_ctx_route_session_lease_live)" == "function" ]] \
  || fail "singular_ctx_route_session_lease_live not defined by $CTX_L"

# --- _path: canonical role-generic lease path --------------------------------
out="$(singular_ctx_route_session_lease_path "implementer" "some-node")"
assert_eq "$out" "$SINGULAR_STATE_DIR/sessions/implementer/some-node.lease" \
  "path is <state-dir>/sessions/<role>/<key>.lease"
out="$(singular_ctx_route_session_lease_path "planner" "node-1")"
assert_eq "$out" "$SINGULAR_STATE_DIR/sessions/planner/node-1.lease" \
  "path for planner role"

# --- _path: default state-dir when SINGULAR_STATE_DIR unset --------------------
out="$(env -u SINGULAR_STATE_DIR bash -c '
  source "'"$LIB"'"; source "'"$CTX_L"'"
  singular_ctx_route_session_lease_path "auditor" "n2"')"
assert_eq "$out" "$SINGULAR_ROOT/.singular-state/sessions/auditor/n2.lease" \
  "path defaults state-dir to \$SINGULAR_ROOT/.singular-state"

# --- _path: empty role OR empty key -> empty string ---------------------------
assert_eq "$(singular_ctx_route_session_lease_path "" "k")" "" "empty role -> empty"
assert_eq "$(singular_ctx_route_session_lease_path "r" "")" "" "empty key -> empty"
assert_eq "$(singular_ctx_route_session_lease_path "" "")" "" "both empty -> empty"
pass "path: canonical role-generic path; empty role/key -> empty"

# --- _live: no file -> not-live (free) ---------------------------------------
rc=0; singular_ctx_route_session_lease_live "$tmp/nope.lease" || rc=$?
assert_eq "$rc" "1" "missing lease file -> not-live (free)"
rc=0; singular_ctx_route_session_lease_live "" || rc=$?
assert_eq "$rc" "1" "empty lease path -> not-live (free)"

# --- _live: live PID -> live (held) ------------------------------------------
lp="$SINGULAR_STATE_DIR/sessions/implementer/live.lease"
mkdir -p "$(dirname "$lp")"
printf '{"pid": %s}\n' "$$" >"$lp"   # our own PID is definitely alive
rc=0; singular_ctx_route_session_lease_live "$lp" || rc=$?
assert_eq "$rc" "0" "live PID -> live (held)"

# --- _live: dead PID -> not-live (free) --------------------------------------
# Find a PID that is not running: spawn a shell and let it exit.
deadpid="$(bash -c 'echo $$')"
# Loop until we are confident it is reaped (best-effort; PID reuse is unlikely).
lp="$SINGULAR_STATE_DIR/sessions/implementer/dead.lease"
printf '{"pid": %s}\n' "$deadpid" >"$lp"
rc=0; singular_ctx_route_session_lease_live "$lp" || rc=$?
assert_eq "$rc" "1" "dead PID -> not-live (free; a crashed holder is not concurrency)"

# --- _live: no parseable PID -> live (held; fail closed) ----------------------
lp="$SINGULAR_STATE_DIR/sessions/implementer/nopid.lease"
printf 'no digits here\n' >"$lp"
rc=0; singular_ctx_route_session_lease_live "$lp" || rc=$?
assert_eq "$rc" "0" "unparseable lease (no PID) -> live (held; fail closed)"
pass "live: fail-closed liveness table (no file/dead -> free; live/unparseable -> held)"

# --- _live: never exits the shell non-zero abnormally ------------------------
# Under set -e the helper must still return cleanly (a return status, not abort).
( set -e
  source "$LIB"; source "$CTX_L"
  singular_ctx_route_session_lease_live "$tmp/nope.lease" || true
  singular_ctx_route_session_lease_live "$lp" || true
) || fail "live helper aborted the shell under set -e"
pass "live: never aborts the shell (reports by return status only)"

# --- Parity: reproduces the integrated planner lease helper's verdicts --------
# Same physical planner lease path & same fixtures must agree between the generic
# helper and singular_planner_resume_lease_path / _live.
source "$CTX_PLANNER" || fail "sourcing $CTX_PLANNER failed"
node="planner-node-x"
generic_path="$(singular_ctx_route_session_lease_path "planner" "$node")"
planner_path="$(singular_planner_resume_lease_path "$node")"
assert_eq "$generic_path" "$planner_path" "generic path == planner path for planner role/key"

mkdir -p "$(dirname "$planner_path")"
# live holder
printf '{"pid": %s}\n' "$$" >"$planner_path"
g=0; singular_ctx_route_session_lease_live "$generic_path" || g=$?
p=0; singular_planner_resume_lease_live "$planner_path" || p=$?
assert_eq "$g" "$p" "parity: live holder verdict matches planner helper"
# dead holder
printf '{"pid": %s}\n' "$deadpid" >"$planner_path"
g=0; singular_ctx_route_session_lease_live "$generic_path" || g=$?
p=0; singular_planner_resume_lease_live "$planner_path" || p=$?
assert_eq "$g" "$p" "parity: dead holder verdict matches planner helper"
# unparseable
printf 'garbage\n' >"$planner_path"
g=0; singular_ctx_route_session_lease_live "$generic_path" || g=$?
p=0; singular_planner_resume_lease_live "$planner_path" || p=$?
assert_eq "$g" "$p" "parity: unparseable verdict matches planner helper"
# missing
rm -f "$planner_path"
g=0; singular_ctx_route_session_lease_live "$generic_path" || g=$?
p=0; singular_planner_resume_lease_live "$planner_path" || p=$?
assert_eq "$g" "$p" "parity: missing-file verdict matches planner helper"
pass "parity: generic lease helpers reproduce planner helper verdicts for planner role/key"

echo "ctx-route-lease tests passed"
