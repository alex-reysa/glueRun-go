#!/usr/bin/env bash
set -euo pipefail

# Deterministic contract tests for grok-run.sh. A mock `grok` binary emits the
# headless envelope grok prints under --output-format json ({"text": ...}), so
# these run offline and in CI.
#
# grok shipped with no tests at all: its read-only guard, its --sandbox
# read-only flag and its timeout path had never been exercised. Its timeout
# also used a bare `kill -9` on the direct child, so grok's own descendants
# survived it — a bug no suite could have caught because no suite ran.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
RUN="$SCRIPT_DIR/grok-run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/gluerun-grok-test.XXXXXX")"
bindir="$workroot/bin"
mkdir -p "$bindir"
cleanup() { rm -rf "$workroot"; }
trap cleanup EXIT

# --- Mock grok -----------------------------------------------------------------
#   MOCK_TEXT     -> string placed in the envelope .text
#   MOCK_WRITE    -> if set, mock overwrites this path (simulates a mutating agent)
#   MOCK_ERROR    -> "1" emits an error envelope
#   MOCK_ARGS_OUT -> records the argv the runner assembled
#   MOCK_SLEEP/MOCK_MARKER -> slow run + marker touched only if it was NOT killed.
#     The sleep is a grandchild on purpose: it is what a bare `kill -9` on the
#     direct child leaves running.
cat >"$bindir/grok" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${MOCK_ARGS_OUT:-}" ]] && printf '%s\n' "$*" > "$MOCK_ARGS_OUT"
cat >/dev/null 2>&1 || true   # consume the piped prompt (stdin)
if [[ -n "${MOCK_WRITE:-}" ]]; then printf 'MUTATED\n' > "$MOCK_WRITE"; fi
if [[ -n "${MOCK_SLEEP:-}" ]]; then
  bash -c 'sleep "$1"; [[ -n "${2:-}" ]] && touch "$2"' _ "$MOCK_SLEEP" "${MOCK_MARKER:-}"
fi
python3 - <<PY
import json, os
if os.environ.get("MOCK_ERROR") == "1":
    print(json.dumps({"type": "error", "message": "boom"}))
else:
    print(json.dumps({"type": "result",
                      "text": os.environ.get("MOCK_TEXT", '{"verdict":"accepted"}')}))
PY
MOCK
chmod +x "$bindir/grok"

export GLUERUN_TARGET_BRANCH="test-target"

new_repo() {
  local d="$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && printf '.gluerun-state/\n' > .gitignore && git add .gitignore && git commit -qm init \
      && git branch "$GLUERUN_TARGET_BRANCH" )
}

prompt() { local p="$workroot/prompt.md"; printf 'do the thing\n' > "$p"; echo "$p"; }
out() { local o="$workroot/out.$RANDOM.json"; echo "$o"; }

run_grok() {
  local repo="$1"; shift
  ( cd "$repo" && PATH="$bindir:$PATH" GLUERUN_ROOT="$repo" \
      GLUERUN_STATE_DIR="$repo/.gluerun-state" "$RUN" "$@" )
}

# --- Case 1: the envelope's .text reaches --output-last-message ----------------
r="$workroot/c1"; new_repo "$r"; o="$(out)"
MOCK_TEXT='{"verdict":"accepted","note":"ok"}' \
  run_grok "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1
[[ -s "$o" ]] || fail "c1: no output captured"
grep -q '"verdict"' "$o" || fail "c1: envelope .text not captured (got: $(cat "$o"))"
pass "c1 envelope .text captured into --output-last-message"

# --- Case 2: an L2 write persists (the guard must be level-gated) -------------
r="$workroot/c2"; new_repo "$r"; o="$(out)"
MOCK_TEXT='{"ok":true}' MOCK_WRITE="$r/l2-write.txt" \
  run_grok "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1
[[ -f "$r/l2-write.txt" ]] || fail "c2: L2 write was reverted; the guard is not level-gated"
pass "c2 L2 write persists"

# --- Case 3: readonly removes a file the run created --------------------------
r="$workroot/c3"; new_repo "$r"; o="$(out)"
MOCK_TEXT='{"verdict":"accepted"}' MOCK_WRITE="$r/agent-new.txt" \
  run_grok "$r" --level readonly -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1
[[ ! -e "$r/agent-new.txt" ]] || fail "c3: readonly run left a created file behind"
pass "c3 readonly removes a run-created untracked file"

# --- Case 4: readonly reverts a tracked modification --------------------------
r="$workroot/c4"; new_repo "$r"; o="$(out)"
printf 'original\n' >"$r/tracked.txt"
( cd "$r" && git add tracked.txt && git commit -qm add )
MOCK_TEXT='{"ok":true}' MOCK_WRITE="$r/tracked.txt" \
  run_grok "$r" --level readonly -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1
[[ "$(cat "$r/tracked.txt")" == "original" ]] || fail "c4: tracked modification not reverted"
pass "c4 readonly reverts a tracked modification"

# --- Case 5: a pre-existing untracked file survives ---------------------------
r="$workroot/c5"; new_repo "$r"; o="$(out)"
printf 'evidence\n' >"$r/pre-existing.txt"
MOCK_TEXT='{"ok":true}' \
  run_grok "$r" --level readonly -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1
[[ "$(cat "$r/pre-existing.txt" 2>/dev/null)" == "evidence" ]] \
  || fail "c5: the guard destroyed a pre-existing untracked file"
pass "c5 readonly preserves a pre-existing untracked file"

# --- Case 6: an already-dirty tracked file keeps its uncommitted bytes --------
# The defect the path-diff guard could not express: this path was in its
# "before" list, so its diff saw no change and the agent's write survived.
r="$workroot/c6"; new_repo "$r"; o="$(out)"
printf 'committed\n' >"$r/wip.txt"
( cd "$r" && git add wip.txt && git commit -qm wip )
printf 'OPERATOR-WIP\n' >"$r/wip.txt"
MOCK_TEXT='{"ok":true}' MOCK_WRITE="$r/wip.txt" \
  run_grok "$r" --level readonly -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1
[[ "$(cat "$r/wip.txt")" == "OPERATOR-WIP" ]] \
  || fail "c6: readonly run overwrote uncommitted work (got: $(cat "$r/wip.txt"))"
pass "c6 readonly restores an already-dirty file to its pre-run bytes"

# --- Case 7: readonly asks grok for its own sandbox too -----------------------
# Cleanup is the backstop, not the only line of defence.
r="$workroot/c7"; new_repo "$r"; o="$(out)"; args="$workroot/c7.args"
MOCK_TEXT='{"ok":true}' MOCK_ARGS_OUT="$args" \
  run_grok "$r" --level readonly -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1
grep -q -- "--sandbox read-only" "$args" || fail "c7: readonly did not pass --sandbox read-only"
grep -q -- "--disallowed-tools" "$args" || fail "c7: readonly did not deny mutation tools"
pass "c7 readonly passes --sandbox read-only and denies mutation tools"

# --- Case 8: a missing binary is 127, not a crash -----------------------------
r="$workroot/c8"; new_repo "$r"; ec=0
( cd "$r" && PATH="/usr/bin:/bin" GLUERUN_ROOT="$r" GLUERUN_STATE_DIR="$r/.gluerun-state" \
    "$RUN" --level l2 -C "$r" --prompt-file "$(prompt)" ) >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 127 ]] || fail "c8: missing grok binary should exit 127 (got $ec)"
pass "c8 missing binary -> 127"

# --- Case 9: an error envelope propagates as a nonzero exit -------------------
r="$workroot/c9"; new_repo "$r"; o="$(out)"; ec=0
MOCK_ERROR=1 run_grok "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -ne 0 ]] || fail "c9: an error envelope should not exit 0"
pass "c9 error envelope -> nonzero exit"

# --- Case 10: the timeout kills grok AND its descendants ----------------------
# grok used `kill -9 "$grok_pid"`, which reaps the direct child and orphans
# everything below it. The mock's sleep is a grandchild for exactly this reason.
r="$workroot/c10"; new_repo "$r"; o="$(out)"; marker="$r/completed.marker"; ec=0
start=$SECONDS
MOCK_SLEEP=6 MOCK_MARKER="$marker" GLUERUN_GROK_TIMEOUT_SEC=2 \
  run_grok "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1 || ec=$?
elapsed=$((SECONDS - start))
[[ "$ec" -eq 124 ]] || fail "c10: timeout should exit 124 (got $ec)"
[[ "$elapsed" -lt 20 ]] || fail "c10: timeout path took ${elapsed}s"
sleep 6   # past the mock's sleep; the marker must NOT appear
[[ ! -e "$marker" ]] || fail "c10: a grandchild survived the timeout kill"
pass "c10 wall-clock timeout exits 124 and kills the whole child tree"

# --- Case 11: the guard runs when the runner is killed ------------------------
# ask/supervise/decide background this runner and kill it on timeout. The old
# guard was straight-line code after the run, so on that path it never ran.
r="$workroot/c11"; new_repo "$r"; o="$(out)"
printf 'committed\n' >"$r/killed.txt"
( cd "$r" && git add killed.txt && git commit -qm killed )
( cd "$r" && PATH="$bindir:$PATH" MOCK_TEXT='{"ok":true}' MOCK_WRITE="$r/killed.txt" \
    MOCK_SLEEP=20 GLUERUN_GROK_TIMEOUT_SEC=0 GLUERUN_ROOT="$r" \
    GLUERUN_STATE_DIR="$r/.gluerun-state" \
    exec "$RUN" --level readonly -C "$r" --prompt-file "$(prompt)" \
    --output-last-message "$o" ) >/dev/null 2>&1 &
kill_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ "$(cat "$r/killed.txt" 2>/dev/null)" == "MUTATED" ]] && break
  sleep 1
done
[[ "$(cat "$r/killed.txt")" == "MUTATED" ]] || fail "c11: mock never mutated the tree"
kill -TERM "$kill_pid" 2>/dev/null || true
wait "$kill_pid" 2>/dev/null || true
[[ "$(cat "$r/killed.txt")" == "committed" ]] \
  || fail "c11: a killed readonly run left its mutation behind (got: $(cat "$r/killed.txt"))"
pass "c11 readonly guard restores on SIGTERM, not only on a clean exit"

echo "ALL GROK-RUN CONTRACT TESTS PASSED"
