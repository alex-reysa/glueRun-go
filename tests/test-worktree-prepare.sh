#!/usr/bin/env bash
set -uo pipefail

# gluerun_worktree_prepare — the single path by which a worktree becomes
# runnable.
#
# Three sites used to build worktrees three different ways, and the differences
# decided outcomes. The auditor re-runs the gate whose result accepts or rejects
# the work, in the one worktree that never received `prewarm`; the worker that
# produced the green result did receive it. accept-existing-packet got neither
# prewarm nor the dependency copies. An environment difference between those
# worktrees is indistinguishable, from the outside, from the work being wrong —
# which is how a 26-node run produced 1 integrated task.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

root="$tmp/repo"
mkdir -p "$root"
git -C "$root" init -q
git -C "$root" config user.email t@t
git -C "$root" config user.name t
printf '.gluerun-state/\nnode_modules/\napps/web/node_modules/\n' >"$root/.gitignore"
printf 'source\n' >"$root/app.txt"
git -C "$root" add -A
git -C "$root" commit -qm init

export GLUERUN_ROOT="$root"
export GLUERUN_STATE_DIR="$root/.gluerun-state"
export GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson"
export GLUERUN_ENGINE_HOME="$ENGINE_HOME"
export GLUERUN_TARGET_BRANCH="main"
mkdir -p "$GLUERUN_STATE_DIR"
# shellcheck disable=SC1091
source "$ENGINE_HOME/engine/lib.sh"

# --- c1: copy paths EXTEND the default, they do not replace it ----------------
# The default used to be a fallback: setting the knob for a nested path dropped
# the root node_modules entirely, so a monorepo trying to fix its audit worktree
# got one that was strictly worse than before.
[[ "$(GLUERUN_WORKTREE_COPY_PATHS_JSON='[]' gluerun_worktree_copy_paths_json)" \
   == '["node_modules"]' ]] || fail "c1: default is not node_modules"
got="$(GLUERUN_WORKTREE_COPY_PATHS_JSON='["apps/web/node_modules"]' gluerun_worktree_copy_paths_json)"
[[ "$got" == '["node_modules","apps/web/node_modules"]' ]] \
  || fail "c1: a declared path replaced the default instead of extending it (got: $got)"
pass "c1 declared copy paths extend the node_modules default"

# The env-only knob keeps working, but the config key is the documented one.
[[ "$(GLUERUN_AUDIT_VERIFY_COPY_PATHS_JSON='["vendor"]' gluerun_worktree_copy_paths_json)" \
   == '["node_modules","vendor"]' ]] || fail "c1: legacy env knob ignored"

# Escapes are still refused.
for bad in '["/abs"]' '["../up"]' '[".."]' '"notalist"'; do
  GLUERUN_WORKTREE_COPY_PATHS_JSON="$bad" gluerun_worktree_copy_paths_json >/dev/null 2>&1 \
    && fail "c1: accepted an unsafe copy path: $bad"
done
pass "c1 unsafe copy paths are refused"

# --- c2: a declared path that is absent is REPORTED, not silently skipped -----
# "I did not copy what you asked for" is precisely the information missing when
# an audit worktree fails a gate the worker passed.
mkdir -p "$root/node_modules/pkg"
printf 'dep\n' >"$root/node_modules/pkg/index.js"
target="$tmp/target"; mkdir -p "$target"
: >"$GLUERUN_EVENTS_FILE"
GLUERUN_WORKTREE_COPY_PATHS_JSON='["apps/web/node_modules"]' \
  gluerun_worktree_copy_paths "$root" "$target" 2>"$tmp/copy.err"
grep -q "declared path is absent" "$tmp/copy.err" \
  || fail "c2: absent declared path was skipped in silence"
grep -q '"type":"worktree.copy_path_absent"' "$GLUERUN_EVENTS_FILE" \
  || fail "c2: absent declared path left no event"
[[ -f "$target/node_modules/pkg/index.js" ]] \
  || fail "c2: the implicit default was not copied"
pass "c2 an absent declared copy path is reported, and the default still copies"

# --- c3: prepare runs prewarm, in every worktree ------------------------------
# This is the equivalence bug itself. Only l1-drive ran prewarm; the auditor's
# worktree and accept-existing-packet's never did.
mkdir -p "$root/apps/web/node_modules/nested"
printf 'nested\n' >"$root/apps/web/node_modules/nested/index.js"
wt="$tmp/wt-prewarm"
git -C "$root" worktree add --detach -q "$wt" HEAD
export GLUERUN_PREWARM_CMD="printf warmed > prewarm.marker"
export GLUERUN_WORKTREE_COPY_PATHS_JSON='["apps/web/node_modules"]'
gluerun_worktree_prepare "$wt" "" "$root" "$tmp/prepare.log" \
  || fail "c3: prepare failed (stage=$GLUERUN_WORKTREE_PREPARE_STAGE): $(cat "$tmp/prepare.log")"
[[ "$(cat "$wt/prewarm.marker" 2>/dev/null)" == "warmed" ]] \
  || fail "c3: prewarm did not run in the prepared worktree"
[[ -f "$wt/node_modules/pkg/index.js" ]] || fail "c3: root node_modules not copied"
[[ -f "$wt/apps/web/node_modules/nested/index.js" ]] \
  || fail "c3: nested declared node_modules not copied"
[[ -z "$GLUERUN_WORKTREE_PREPARE_STAGE" ]] || fail "c3: stage not cleared on success"
pass "c3 prepare copies both trees and runs prewarm"

# --- c4: the failing stage is named ------------------------------------------
# Callers need it: bootstrap failure is fatal in the audit path and non-fatal in
# the worker path, and they cannot branch on an exit code alone.
wt2="$tmp/wt-bootstrap"
git -C "$root" worktree add --detach -q "$wt2" HEAD
export GLUERUN_BOOTSTRAP_JSON='{"required":true,"commands":[{"command":"exit 7"}]}'
GLUERUN_WORKTREE_PREPARE_BOOTSTRAP_FATAL=yes \
  gluerun_worktree_prepare "$wt2" "" "" "$tmp/prepare2.log" \
  && fail "c4: a fatal bootstrap failure should fail prepare"
[[ "$GLUERUN_WORKTREE_PREPARE_STAGE" == "bootstrap" ]] \
  || fail "c4: failing stage not named (got: $GLUERUN_WORKTREE_PREPARE_STAGE)"

# ...and the worker path continues past it, still reaching prewarm, because a
# missing dependency is worth an attempt that reports the real failure rather
# than a task that never starts.
wt3="$tmp/wt-nonfatal"
git -C "$root" worktree add --detach -q "$wt3" HEAD
GLUERUN_WORKTREE_PREPARE_BOOTSTRAP_FATAL=no \
  gluerun_worktree_prepare "$wt3" "" "" "$tmp/prepare3.log" \
  || fail "c4: a non-fatal bootstrap failure should not fail prepare"
[[ "$GLUERUN_WORKTREE_PREPARE_BOOTSTRAP_FAILED" == "yes" ]] \
  || fail "c4: non-fatal bootstrap failure was not reported"
[[ "$(cat "$wt3/prewarm.marker" 2>/dev/null)" == "warmed" ]] \
  || fail "c4: prewarm skipped after a non-fatal bootstrap failure"
pass "c4 the failing stage is named and bootstrap fatality is caller-controlled"

# --- c5: all three call sites go through it ----------------------------------
# The regression this whole file exists to prevent is one of them drifting back
# to building a worktree its own way.
for site in l1-drive audit-verify accept-existing-packet; do
  grep -q "gluerun_worktree_prepare" "$ENGINE_HOME/engine/$site.sh" \
    || fail "c5: $site.sh does not use the shared preparer"
  grep -q "bootstrap-worktree.sh" "$ENGINE_HOME/engine/$site.sh" \
    && fail "c5: $site.sh still bootstraps on its own"
done
pass "c5 all three worktree sites use the shared preparer"

echo "ALL WORKTREE-PREPARE TESTS PASSED"
