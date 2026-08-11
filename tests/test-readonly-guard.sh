#!/usr/bin/env bash
# Covers engine/readonly_guard.py and the lib.sh wrappers around it.
#
# Every case below is one of the ways the path-diff guard this replaces got the
# wrong answer. The old guard captured two lists of PATHS before a read-only run
# and diffed them after; the cases it could not express are the ones where the
# path is unchanged but the bytes are not (c1, c10, c12), where the pre-run
# bytes are not in git at all (c1, c5), where git's default output is not a
# usable pathspec (c7, c8), where the mutation lives in the index (c3, c10), or
# where a path appeared during the window and the guard guessed wrong about who
# created it (c9, c17).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ENGINE_HOME/engine/readonly_guard.py"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# A fresh repo per case: these tests mutate indexes and working trees, and a
# leaked state between cases would be indistinguishable from a guard defect.
new_repo() {
  local dir="$tmp/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.email guard@test
  git -C "$dir" config user.name guard
  git -C "$dir" config commit.gpgsign false
  # Every singular repo ignores its state directory, and the fixture has to as
  # well: the guard writes its journal, quarantine and result there, so without
  # this the porcelain comparison below reports the guard's own bookkeeping as
  # a change the guard failed to clean up.
  printf '.singular-state/\n' >"$dir/.gitignore"
  printf 'tracked-clean\n' >"$dir/clean.txt"
  printf 'tracked-dirty\n' >"$dir/dirty.txt"
  mkdir -p "$dir/docs/orchestration/tasks"
  printf 'placeholder\n' >"$dir/docs/orchestration/tasks/.keep"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
  printf '%s\n' "$dir"
}

capture() { python3 "$GUARD" capture --worktree "$1" --journal "$2" "${@:3}"; }
restore() { python3 "$GUARD" restore --journal "$1" "${@:2}"; }

outcome_of() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("outcome",""))' <<<"$1"
}
count_of() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("counts",{}).get(sys.argv[1],0))' \
    "$2" <<<"$1"
}
# The pre-run porcelain is the whole contract: after restore, `git status` must
# read exactly as it did before the run. Comparing the full porcelain rather
# than individual files catches index damage the file contents would hide.
status_of() { git -C "$1" status --porcelain=v1 -uall | LC_ALL=C sort; }

# --- c1: an agent's overwrite of an already-dirty file ------------------------
# The old guard put this path in its "before" list, so the diff saw no change
# and the agent's write survived — the exact thing the guard exists to prevent.
r="$(new_repo c1)"
printf 'OPERATOR-WORK\n' >"$r/dirty.txt"
before="$(status_of "$r")"
capture "$r" "$tmp/j1" >/dev/null
printf 'AGENT-CLOBBER\n' >"$r/dirty.txt"
out="$(restore "$tmp/j1")"
[[ "$(outcome_of "$out")" == "restored" ]] || fail "c1: outcome $(outcome_of "$out")"
[[ "$(cat "$r/dirty.txt")" == "OPERATOR-WORK" ]] \
  || fail "c1: agent write survived on an already-dirty file"
[[ "$(status_of "$r")" == "$before" ]] || fail "c1: status not restored"
# The bytes the restore overwrote have to survive too. Nothing distinguishes an
# agent's write from a concurrent operator's, so the guard is not allowed to be
# destructive about either: it wins the argument by moving, not by deleting.
[[ "$(cat "$tmp/j1/quarantine/dirty.txt")" == "AGENT-CLOBBER" ]] \
  || fail "c1: overwritten bytes are not recoverable from quarantine"

# --- c2: an ordinary mutation of a clean tracked file -------------------------
r="$(new_repo c2)"
before="$(status_of "$r")"
capture "$r" "$tmp/j2" >/dev/null
printf 'AGENT\n' >"$r/clean.txt"
restore "$tmp/j2" >/dev/null
[[ "$(cat "$r/clean.txt")" == "tracked-clean" ]] || fail "c2: clean file not reverted"
[[ "$(status_of "$r")" == "$before" ]] || fail "c2: status not restored"

# --- c3: the agent stages its mutation ----------------------------------------
# `git checkout -- <path>` restores from the INDEX, so the old guard handed the
# agent a one-line bypass: edit, then `git add`.
r="$(new_repo c3)"
before="$(status_of "$r")"
capture "$r" "$tmp/j3" >/dev/null
printf 'AGENT\n' >"$r/clean.txt"
git -C "$r" add clean.txt
restore "$tmp/j3" >/dev/null
[[ "$(cat "$r/clean.txt")" == "tracked-clean" ]] || fail "c3: staged mutation survived"
[[ "$(status_of "$r")" == "$before" ]] || fail "c3: index not reverted"

# --- c4: a new file is removed but never destroyed ----------------------------
r="$(new_repo c4)"
capture "$r" "$tmp/j4" >/dev/null
printf 'AGENT-NEW\n' >"$r/new.txt"
out="$(restore "$tmp/j4")"
[[ ! -e "$r/new.txt" ]] || fail "c4: agent-created file not removed"
[[ "$(count_of "$out" quarantined-new)" == "1" ]] || fail "c4: no quarantine recorded"
[[ "$(cat "$tmp/j4/quarantine/new.txt")" == "AGENT-NEW" ]] \
  || fail "c4: removed bytes are not recoverable from quarantine"

# --- c5: a pre-existing untracked file the agent deleted ----------------------
# Not in HEAD and not in the index, so HEAD-based restore had nothing to offer.
r="$(new_repo c5)"
printf 'OPERATOR-SCRATCH\n' >"$r/scratch.txt"
before="$(status_of "$r")"
capture "$r" "$tmp/j5" >/dev/null
rm "$r/scratch.txt"
restore "$tmp/j5" >/dev/null
[[ "$(cat "$r/scratch.txt" 2>/dev/null)" == "OPERATOR-SCRATCH" ]] \
  || fail "c5: deleted untracked file not restored"
[[ "$(status_of "$r")" == "$before" ]] || fail "c5: status not restored"

# --- c6: a clean tracked file the agent deleted -------------------------------
r="$(new_repo c6)"
before="$(status_of "$r")"
capture "$r" "$tmp/j6" >/dev/null
rm "$r/clean.txt"
restore "$tmp/j6" >/dev/null
[[ "$(cat "$r/clean.txt" 2>/dev/null)" == "tracked-clean" ]] \
  || fail "c6: deleted tracked file not restored"
[[ "$(status_of "$r")" == "$before" ]] || fail "c6: status not restored"

# --- c7: a non-ASCII path -----------------------------------------------------
# git quotes these in its default output, so the old guard fed `checkout --` a
# path that did not exist, and `|| true` swallowed the error: a silent no-op.
# This engine runs localization programs; such paths are the normal case there.
r="$(new_repo c7)"
printf 'acentuado\n' >"$r/café.txt"
git -C "$r" add -A && git -C "$r" commit -qm accents
before="$(status_of "$r")"
capture "$r" "$tmp/j7" >/dev/null
printf 'AGENT\n' >"$r/café.txt"
restore "$tmp/j7" >/dev/null
[[ "$(cat "$r/café.txt")" == "acentuado" ]] || fail "c7: non-ASCII path not reverted"
[[ "$(status_of "$r")" == "$before" ]] || fail "c7: status not restored"

# --- c8: pathspec metacharacters in a real filename ---------------------------
# The damage here is not to the odd filename — git happily matches that one
# either way — but to its neighbours. A pathspec built without :(literal) is a
# GLOB, so restoring `a[1]*.txt` also reverts every file the glob happens to
# match. The bystander below is dirty operator work that the run never touched.
r="$(new_repo c8)"
printf 'globby\n' >"$r/a[1]*.txt"
printf 'bystander\n' >"$r/a1x.txt"
git -C "$r" add -A && git -C "$r" commit -qm globby
printf 'OPERATOR-WORK\n' >"$r/a1x.txt"
before="$(status_of "$r")"
capture "$r" "$tmp/j8" >/dev/null
printf 'AGENT\n' >"$r/a[1]*.txt"
restore "$tmp/j8" >/dev/null
[[ "$(cat "$r/a[1]*.txt")" == "globby" ]] || fail "c8: glob-metachar path not reverted"
[[ "$(cat "$r/a1x.txt")" == "OPERATOR-WORK" ]] \
  || fail "c8: a glob pathspec reverted a file the run never touched"
[[ "$(status_of "$r")" == "$before" ]] || fail "c8: status not restored"

# --- c9: a concurrent engine write inside an excluded directory ---------------
# Read-only runs execute against $SINGULAR_ROOT for up to 1200s while the rest of
# the engine keeps importing task files into it. The old guard classified those
# as agent output and rm -rf'd them: the engine deleting its own control state.
r="$(new_repo c9)"
capture "$r" "$tmp/j9" --exclude docs/orchestration >/dev/null
printf '# TASK-0042\n' >"$r/docs/orchestration/tasks/TASK-0042.md"
printf 'AGENT\n' >"$r/clean.txt"
restore "$tmp/j9" >/dev/null
[[ -f "$r/docs/orchestration/tasks/TASK-0042.md" ]] \
  || fail "c9: guard deleted a concurrently imported task file"
[[ "$(cat "$r/clean.txt")" == "tracked-clean" ]] \
  || fail "c9: exclusion must not disarm the rest of the guard"

# --- c10: a staged-new file the agent then modified ---------------------------
# Its pre-run bytes exist nowhere in git history, and its index entry must
# survive the restore or the operator loses the staging they had done.
r="$(new_repo c10)"
printf 'STAGED-PRE\n' >"$r/staged.txt"
git -C "$r" add staged.txt
before="$(status_of "$r")"
capture "$r" "$tmp/j10" >/dev/null
printf 'AGENT\n' >"$r/staged.txt"
restore "$tmp/j10" >/dev/null
[[ "$(cat "$r/staged.txt")" == "STAGED-PRE" ]] || fail "c10: staged-new content lost"
[[ "$(status_of "$r")" == "$before" ]] || fail "c10: staging state not preserved"

# --- c10b: an already-dirty file that the agent then stages -------------------
# The only shape that reaches the index-restore path: a file whose pre-run
# INDEX entry differs from its post-run one while both differ from HEAD. c3
# cannot reach it (its file was clean at capture, so HEAD-checkout covers both
# index and worktree) and neither can c10 (the agent left its index alone).
r="$(new_repo c10b)"
printf 'OPERATOR-WORK\n' >"$r/dirty.txt"
before="$(status_of "$r")"
capture "$r" "$tmp/j10b" >/dev/null
printf 'AGENT\n' >"$r/dirty.txt"
git -C "$r" add dirty.txt
out="$(restore "$tmp/j10b")"
[[ "$(count_of "$out" restored-index)" == "1" ]] || fail "c10b: index not restored"
[[ "$(cat "$r/dirty.txt")" == "OPERATOR-WORK" ]] || fail "c10b: content not restored"
[[ "$(status_of "$r")" == "$before" ]] \
  || fail "c10b: staging the mutation left the index ahead of its pre-run state"

# --- c11: a retargeted symlink ------------------------------------------------
r="$(new_repo c11)"
ln -s clean.txt "$r/link"
git -C "$r" add -A && git -C "$r" commit -qm link
before="$(status_of "$r")"
capture "$r" "$tmp/j11" >/dev/null
ln -sf dirty.txt "$r/link"
restore "$tmp/j11" >/dev/null
[[ "$(readlink "$r/link")" == "clean.txt" ]] || fail "c11: symlink target not restored"
[[ "$(status_of "$r")" == "$before" ]] || fail "c11: status not restored"

# --- c12: an executable bit flip ----------------------------------------------
r="$(new_repo c12)"
before="$(status_of "$r")"
capture "$r" "$tmp/j12" >/dev/null
chmod +x "$r/clean.txt"
restore "$tmp/j12" >/dev/null
[[ ! -x "$r/clean.txt" ]] || fail "c12: mode change not reverted"
[[ "$(status_of "$r")" == "$before" ]] || fail "c12: status not restored"

# --- c13: a well-behaved run costs nothing ------------------------------------
r="$(new_repo c13)"
printf 'OPERATOR\n' >"$r/dirty.txt"
before="$(status_of "$r")"
capture "$r" "$tmp/j13" >/dev/null
cat "$r/clean.txt" >/dev/null
out="$(restore "$tmp/j13")"
[[ "$(outcome_of "$out")" == "clean" ]] \
  || fail "c13: a read-only run that changed nothing reported $(outcome_of "$out")"
[[ "$(status_of "$r")" == "$before" ]] || fail "c13: clean run perturbed the tree"

# --- c14: report mode observes and changes nothing ----------------------------
r="$(new_repo c14)"
capture "$r" "$tmp/j14" >/dev/null
printf 'AGENT\n' >"$r/clean.txt"
printf 'AGENT-NEW\n' >"$r/new.txt"
out="$(restore "$tmp/j14" --mode report)"
[[ "$(outcome_of "$out")" == "reported" ]] || fail "c14: outcome $(outcome_of "$out")"
[[ "$(cat "$r/clean.txt")" == "AGENT" ]] || fail "c14: report mode mutated the tree"
[[ -f "$r/new.txt" ]] || fail "c14: report mode removed a file"
[[ "$(count_of "$out" would-revert-to-head)" == "1" ]] || fail "c14: missing would-revert"
[[ "$(count_of "$out" would-quarantine-new)" == "1" ]] || fail "c14: missing would-quarantine"

# --- c15: a second restore is a no-op -----------------------------------------
# The runners call restore from an EXIT trap that can fire after an explicit
# call on the success path; a double restore must not re-apply a stale journal.
r="$(new_repo c15)"
capture "$r" "$tmp/j15" >/dev/null
printf 'AGENT\n' >"$r/clean.txt"
restore "$tmp/j15" --consume >/dev/null
printf 'LATER-OPERATOR-WORK\n' >"$r/clean.txt"
out="$(restore "$tmp/j15" --consume)"
[[ "$(outcome_of "$out")" == "no-journal" ]] || fail "c15: outcome $(outcome_of "$out")"
[[ "$(cat "$r/clean.txt")" == "LATER-OPERATOR-WORK" ]] \
  || fail "c15: a consumed journal was replayed over later work"

# --- c16: sweep finishes the restore a SIGKILLed run could not --------------
r="$(new_repo c16)"
before="$(status_of "$r")"
mkdir -p "$tmp/sweeproot"
capture "$r" "$tmp/sweeproot/killed" --owner-pid 999999 >/dev/null
printf 'AGENT\n' >"$r/clean.txt"
printf 'AGENT-NEW\n' >"$r/orphan.txt"
python3 "$GUARD" sweep --root "$tmp/sweeproot" >/dev/null
[[ "$(cat "$r/clean.txt")" == "tracked-clean" ]] || fail "c16: sweep did not restore"
[[ ! -e "$r/orphan.txt" ]] || fail "c16: sweep left an agent-created file"
[[ "$(status_of "$r")" == "$before" ]] || fail "c16: sweep did not fully restore"

# A journal whose owner is still alive belongs to a run in flight; sweeping it
# would restore the tree out from under a working agent.
r="$(new_repo c16b)"
capture "$r" "$tmp/sweeproot/live" --owner-pid "$$" >/dev/null
printf 'AGENT\n' >"$r/clean.txt"
python3 "$GUARD" sweep --root "$tmp/sweeproot" >/dev/null
[[ "$(cat "$r/clean.txt")" == "AGENT" ]] || fail "c16b: sweep touched a live run's journal"

# --- c17: two read-only runs sharing one root ---------------------------------
# Up to SINGULAR_MAX_L1_CONCURRENT planners run against $SINGULAR_ROOT at once.
# Each must undo its own damage and leave the other's in-flight state alone.
r="$(new_repo c17)"
before="$(status_of "$r")"
capture "$r" "$tmp/j17a" >/dev/null
printf 'A-WORK\n' >"$r/a.txt"
capture "$r" "$tmp/j17b" >/dev/null
printf 'B-WORK\n' >"$r/b.txt"
restore "$tmp/j17b" >/dev/null
[[ ! -e "$r/b.txt" ]] || fail "c17: run B did not clean up after itself"
[[ "$(cat "$r/a.txt" 2>/dev/null)" == "A-WORK" ]] \
  || fail "c17: run B destroyed run A's in-flight file"
restore "$tmp/j17a" >/dev/null
[[ ! -e "$r/a.txt" ]] || fail "c17: run A did not clean up after itself"
[[ "$(status_of "$r")" == "$before" ]] || fail "c17: root not fully restored"

# --- c18: an oversized dirty set degrades loudly instead of guessing ----------
r="$(new_repo c18)"
for i in 1 2 3 4 5; do printf 'x\n' >"$r/big$i.txt"; done
out="$(capture "$r" "$tmp/j18" --max-files 2)"
[[ "$(outcome_of "$out")" == "degraded" ]] || fail "c18: oversized capture not degraded"
printf 'AGENT\n' >"$r/clean.txt"
out="$(restore "$tmp/j18")"
[[ "$(outcome_of "$out")" == "degraded" ]] || fail "c18: degraded journal acted anyway"
[[ "$(cat "$r/clean.txt")" == "AGENT" ]] \
  || fail "c18: a degraded guard must not act on a partial picture"

# --- c19: an unmerged path is left strictly alone -----------------------------
r="$(new_repo c19)"
git -C "$r" checkout -q -b other
printf 'theirs\n' >"$r/conflict.txt"
git -C "$r" add -A && git -C "$r" commit -qm theirs
git -C "$r" checkout -q -
printf 'ours\n' >"$r/conflict.txt"
git -C "$r" add -A && git -C "$r" commit -qm ours
git -C "$r" merge -q other >/dev/null 2>&1 || true
capture "$r" "$tmp/j19" >/dev/null
out="$(restore "$tmp/j19")"
[[ "$(count_of "$out" skipped-unmerged)" -ge 1 ]] || fail "c19: unmerged path not skipped"
grep -q '<<<<<<<' "$r/conflict.txt" || fail "c19: guard rewrote a conflicted file"

# --- c20: the lib.sh wrappers -------------------------------------------------
r="$(new_repo c20)"
export SINGULAR_ROOT="$r"
export SINGULAR_STATE_DIR="$r/.singular-state"
export SINGULAR_EVENTS_FILE="$r/.singular-state/events.ndjson"
export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
# shellcheck disable=SC1091
source "$ENGINE_HOME/engine/lib.sh"

# The wrapper must exclude the engine's own directories by default: the whole
# point of c9 is worthless if callers have to remember to ask for it.
before="$(status_of "$r")"
journal="$(singular_readonly_guard_capture "$r" wrapper)"
[[ -n "$journal" && -d "$journal" ]] || fail "c20: wrapper produced no journal"
printf '# TASK-0043\n' >"$r/docs/orchestration/tasks/TASK-0043.md"
printf 'AGENT\n' >"$r/clean.txt"
singular_readonly_guard_restore "$journal" 2>/dev/null
[[ -f "$r/docs/orchestration/tasks/TASK-0043.md" ]] \
  || fail "c20: wrapper did not exclude the orchestration directory by default"
[[ "$(cat "$r/clean.txt")" == "tracked-clean" ]] || fail "c20: wrapper did not restore"
grep -q '"type":"readonly_guard.restored"' "$SINGULAR_EVENTS_FILE" \
  || fail "c20: a containment failure must leave an event"

# off disarms the guard entirely, and must do so without leaving a journal
# behind for sweep to apply later.
SINGULAR_READONLY_GUARD_MODE=off
journal="$(singular_readonly_guard_capture "$r" wrapper-off)"
[[ -z "$journal" ]] || fail "c20: mode=off still armed the guard"
printf 'AGENT-OFF\n' >"$r/clean.txt"
singular_readonly_guard_restore "" 2>/dev/null
[[ "$(cat "$r/clean.txt")" == "AGENT-OFF" ]] || fail "c20: mode=off still restored"
SINGULAR_READONLY_GUARD_MODE=restore
git -C "$r" checkout -- clean.txt

# A restore is safe to call with an argument that never became a journal.
singular_readonly_guard_restore "$r/nope" 2>/dev/null \
  || fail "c20: restore of a missing journal must not fail the run"

# --- c21: a grace period lets the killed runner run its EXIT trap -------------
# The guard lives in that trap. ask/supervise/decide used a bare SIGKILL on
# timeout, which executes no handler — so every mutation a timed-out read-only
# run had made stayed in $SINGULAR_ROOT, and the guard's own journal was left for
# `sweep` to find later. The grace period is what closes that.
cat >"$tmp/trapped.sh" <<'SH'
#!/usr/bin/env bash
cleanup() { printf 'cleaned\n' >"$1"; exit 143; }
trap 'cleanup "$1"' TERM
sleep 30 & child=$!
wait "$child"
SH
chmod +x "$tmp/trapped.sh"

"$tmp/trapped.sh" "$tmp/graceful.marker" & graceful_pid=$!
sleep 1
singular_kill_tree "$graceful_pid" 5
wait "$graceful_pid" 2>/dev/null || true
[[ -f "$tmp/graceful.marker" ]] \
  || fail "c21: a graceful kill must let the EXIT trap run"

# Default 0 keeps the old immediate-SIGKILL behaviour for callers with nothing
# to clean up; asserting it here is what makes the case above mean something.
"$tmp/trapped.sh" "$tmp/hard.marker" & hard_pid=$!
sleep 1
singular_kill_tree "$hard_pid"
# Polled rather than waited on: `wait` makes bash announce the SIGKILL as
# "Killed: 9" on stderr, which reads like a test failure in a passing run.
for _ in 1 2 3 4 5; do kill -0 "$hard_pid" 2>/dev/null || break; sleep 1; done
kill -0 "$hard_pid" 2>/dev/null && fail "c21: a bare kill must actually kill"
[[ ! -f "$tmp/hard.marker" ]] || fail "c21: a bare kill must not run handlers"

# --- c22: reconcile applies the journals a SIGKILLed run left behind ---------
r="$(new_repo c22)"
export SINGULAR_ROOT="$r"
export SINGULAR_STATE_DIR="$r/.singular-state"
export SINGULAR_EVENTS_FILE="$r/.singular-state/events.ndjson"
before="$(status_of "$r")"
# Captured through the wrapper, so this exercises the real journal location and
# the real default excludes; then the owner is rewritten to a dead pid to stand
# in for the SIGKILL that would have left it behind.
journal="$(singular_readonly_guard_capture "$r" killed-run)"
[[ -n "$journal" ]] || fail "c22: wrapper produced no journal"
python3 - "$journal/journal.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["ownerPid"] = 999999
json.dump(data, open(path, "w"))
PY
printf 'AGENT\n' >"$r/clean.txt"
printf 'AGENT-NEW\n' >"$r/orphan.txt"
singular_readonly_guard_sweep
[[ "$(cat "$r/clean.txt")" == "tracked-clean" ]] \
  || fail "c22: the sweep did not apply an orphaned journal"
[[ ! -e "$r/orphan.txt" ]] || fail "c22: the sweep left an agent-created file"
[[ "$(status_of "$r")" == "$before" ]] || fail "c22: the sweep did not fully restore"

echo "readonly guard tests passed"
