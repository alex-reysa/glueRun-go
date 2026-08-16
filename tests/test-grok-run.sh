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

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-grok-test.XXXXXX")"
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
# The prompt reaches grok via --prompt-file; nothing is ever piped to this mock.
# The old bare `cat` therefore drained an INHERITED stdin instead, and blocked
# for as long as that fd stayed open -- wedging the suite whenever the harness
# was started from a live pipe or tty rather than from CI's /dev/null.
cat >/dev/null 2>&1 </dev/null || true
if [[ -n "${MOCK_WRITE:-}" ]]; then printf 'MUTATED\n' > "$MOCK_WRITE"; fi
if [[ -n "${MOCK_SLEEP:-}" ]]; then
  bash -c 'sleep "$1"; [[ -n "${2:-}" ]] && touch "$2"' _ "$MOCK_SLEEP" "${MOCK_MARKER:-}"
fi
# QUOTED delimiter, and it must stay quoted. Unquoted, bash expands this body,
# so a backtick or $(...) anywhere in it -- even inside a Python comment -- is
# executed by the mock. A backticked `grok ...` in a comment here resolved back
# through PATH to this same mock and fork-bombed the host.
python3 - <<'PY'
import json, os
status = os.environ.get("MOCK_HTTP_STATUS")
if status:
    # Shape taken from a real grok terminal error envelope: the provider-controlled
    # HTTP status lives under .error, which is what lib.sh classifies on.
    print(json.dumps({"type": "error", "error": {
        "status": int(status),
        "code": os.environ.get("MOCK_ERR_CODE", "error"),
        "message": os.environ.get("MOCK_ERR_MESSAGE", "provider error")}}))
elif os.environ.get("MOCK_ERROR") == "1":
    print(json.dumps({"type": "error", "message": "boom"}))
elif os.environ.get("MOCK_MALFORMED") == "1":
    print("not json at all {{{")
else:
    # A real grok --output-format json success envelope carries NO "type" and
    # does carry sessionId/usage. Case 1 keeps the old shape; this is the live one.
    print(json.dumps({
        "text": os.environ.get("MOCK_TEXT", '{"verdict":"accepted"}'),
        "stopReason": "end_turn",
        "sessionId": os.environ.get("MOCK_SESSION_ID", "01a00b22-5757-7751-af67-d3fb8c61e607"),
        "usage": {"input_tokens": 14192, "cache_read_input_tokens": 11520,
                  "output_tokens": 37, "total_tokens": 25749},
        "num_turns": 1}))
PY
MOCK
chmod +x "$bindir/grok"

export SINGULAR_TARGET_BRANCH="test-target"

new_repo() {
  local d="$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && printf '.singular-state/\n' > .gitignore && git add .gitignore && git commit -qm init \
      && git branch "$SINGULAR_TARGET_BRANCH" )
}

prompt() { local p="$workroot/prompt.md"; printf 'do the thing\n' > "$p"; echo "$p"; }
out() { local o="$workroot/out.$RANDOM.json"; echo "$o"; }

run_grok() {
  local repo="$1"; shift
  ( cd "$repo" && PATH="$bindir:$PATH" SINGULAR_ROOT="$repo" \
      SINGULAR_STATE_DIR="$repo/.singular-state" "$RUN" "$@" )
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
( cd "$r" && PATH="/usr/bin:/bin" SINGULAR_ROOT="$r" SINGULAR_STATE_DIR="$r/.singular-state" \
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
MOCK_SLEEP=6 MOCK_MARKER="$marker" SINGULAR_GROK_TIMEOUT_SEC=2 \
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
    MOCK_SLEEP=20 SINGULAR_GROK_TIMEOUT_SEC=0 SINGULAR_ROOT="$r" \
    SINGULAR_STATE_DIR="$r/.singular-state" \
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

# --- Case 12: deterministic argv for the installed Grok 1.0.4 -----------------
# Every flag here is one the installed CLI actually accepts. The old adapter
# asked for `--model grok-build`, a product name that is not a model id at all:
# `grok models` serves grok-4.6 (default) and grok-4.5.
r="$workroot/c12"; new_repo "$r"; o="$(out)"; args="$workroot/c12.args"
MOCK_TEXT='{"ok":true}' MOCK_ARGS_OUT="$args" \
  run_grok "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1
a="$(cat "$args")"
grep -q -- "--no-auto-update" <<<"$a" \
  || fail "c12: --no-auto-update missing; the bootstrap can swap the binary mid-run"
grep -q -- "--model grok-4.6" <<<"$a" || fail "c12: wrong default model (got: $a)"
grep -qv -- "grok-build" <<<"$a" || fail "c12: still asking for the nonexistent grok-build model"
grep -q -- "--output-format json" <<<"$a" || fail "c12: missing --output-format json"
grep -q -- "--cwd $r" <<<"$a" || fail "c12: --cwd not pinned to the worktree"
grep -q -- "--prompt-file" <<<"$a" || fail "c12: --prompt-file dropped"
grep -q -- "--sandbox workspace" <<<"$a" || fail "c12: l2 lost its sandbox"
pass "c12 argv matches the installed Grok 1.0.4 surface (no-auto-update, grok-4.6)"

# --- Case 13: a structured 429 is quota, and is read from the envelope --------
r="$workroot/c13"; new_repo "$r"; o="$(out)"; rf="$workroot/c13.result.json"; ec=0
MOCK_HTTP_STATUS=429 MOCK_ERR_CODE=rate_limit_exceeded \
  MOCK_ERR_MESSAGE="rate limit reached for grok-4.6" \
  run_grok "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --result-file "$rf" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -ne 0 ]] || fail "c13: a 429 envelope must not exit 0"
[[ -s "$rf" ]] || fail "c13: no runner result written"
python3 - "$rf" <<'PY' || fail "c13: 429 not classified as quota/usage-limit"
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("provider") == "grok", d.get("provider")
assert d.get("failureClass") == "quota", d.get("failureClass")
PY
pass "c13 structured 429 -> failureClass=quota, provider=grok"

# --- Case 14: 503/529 is overload, kept DISTINCT from quota -------------------
# Conflating them buys a 30-minute quota nap for a blip that clears in seconds.
for st in 503 529; do
  r="$workroot/c14-$st"; new_repo "$r"; o="$(out)"; rf="$workroot/c14-$st.result.json"; ec=0
  MOCK_HTTP_STATUS="$st" MOCK_ERR_CODE=overloaded MOCK_ERR_MESSAGE="service overloaded" \
    run_grok "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
    --result-file "$rf" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
  [[ "$ec" -ne 0 ]] || fail "c14: a $st envelope must not exit 0"
  python3 - "$rf" "$st" <<'PY' || fail "c14: $st not classified as provider-overloaded"
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("failureClass") == "provider-overloaded", (sys.argv[2], d.get("failureClass"))
assert d.get("failureClass") != "quota"
PY
done
pass "c14 503/529 -> failureClass=provider-overloaded, never quota"

# --- Case 15: malformed provider JSON fails loudly ----------------------------
r="$workroot/c15"; new_repo "$r"; o="$(out)"; ec=0
MOCK_MALFORMED=1 run_grok "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -ne 0 ]] || fail "c15: unparseable envelope should not exit 0"
pass "c15 malformed envelope -> nonzero exit"

# --- Case 16: the host's session args are accepted, not fatal -----------------
# describe-contract advertises --session-meta/--resume-session for every runner.
# grok-run rejected both with "unknown option" (exit 2), so every host call site
# that passes them died before reaching the provider.
r="$workroot/c16"; new_repo "$r"; o="$(out)"; sm="$workroot/c16.meta.json"
MOCK_TEXT='{"ok":true}' MOCK_SESSION_ID="01a00b22-dead-beef-af67-d3fb8c61e607" \
  run_grok "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --session-meta "$sm" --output-last-message "$o" >/dev/null 2>&1
[[ -s "$sm" ]] || fail "c16: --session-meta accepted but nothing written"
grep -q "01a00b22-dead-beef" "$sm" \
  || fail "c16: envelope sessionId not carried into session-meta (got: $(cat "$sm"))"
ec=0
run_grok "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --resume-session "some-id" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 86 ]] || fail "c16: --resume-session should signal resume-refusal 86 (got $ec)"
pass "c16 --session-meta writes the real sessionId; --resume-session refuses with 86"

echo "ALL GROK-RUN CONTRACT TESTS PASSED"
