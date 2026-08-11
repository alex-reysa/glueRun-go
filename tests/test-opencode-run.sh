#!/usr/bin/env bash
set -euo pipefail

# Deterministic contract tests for opencode-run.sh (0.9.0 providers). A mock
# `opencode` binary emits a canned `--format json` event stream (the flat
# {"type":...} NDJSON events opencode prints) so these run offline and in CI. They
# assert the drop-in contract: the assistant text is reassembled from text-part
# events into --output-last-message (and the echoed user prompt is dropped),
# missing-binary -> 127, the read-only restore guard, wall-clock timeout (-> 124),
# the model flag omitted when SINGULAR_OPENCODE_MODEL is unset and present when set,
# and an error event -> exit 4.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
RUN="$SCRIPT_DIR/opencode-run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-opencode-test.XXXXXX")"
bindir="$workroot/bin"
mkdir -p "$bindir"
cleanup() { rm -rf "$workroot"; }
trap cleanup EXIT

# --- Mock opencode -------------------------------------------------------------
#   MOCK_RESULT   -> string placed in the assistant text part
#   MOCK_WRITE    -> if set, mock overwrites this path (simulates a mutating agent)
#   MOCK_IS_ERROR -> "1" emits a {"type":"error",...} event
#   MOCK_ARGS_OUT -> records the argv the runner assembled
#   MOCK_SLEEP/MOCK_MARKER -> slow run + marker touched only if not killed
cat >"$bindir/opencode" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${MOCK_ARGS_OUT:-}" ]] && printf '%s\n' "$*" > "$MOCK_ARGS_OUT"
cat >/dev/null 2>&1 || true   # consume the piped prompt (stdin)
if [[ -n "${MOCK_WRITE:-}" ]]; then printf 'MUTATED\n' > "$MOCK_WRITE"; fi
if [[ -n "${MOCK_SLEEP:-}" ]]; then sleep "$MOCK_SLEEP"; [[ -n "${MOCK_MARKER:-}" ]] && touch "$MOCK_MARKER"; fi
python3 - <<PY
import json, os
if os.environ.get("MOCK_IS_ERROR") == "1":
    print(json.dumps({"type":"error","timestamp":1,"sessionID":"ses_x",
                      "error":{"name":"UnknownError","data":{"message":"boom"}}}))
else:
    res = os.environ.get("MOCK_RESULT", '{"verdict":"accepted"}')
    # Echoed user message (must be dropped by role filtering).
    print(json.dumps({"type":"message.updated","sessionID":"ses_x","info":{"id":"msg_u","role":"user"}}))
    print(json.dumps({"type":"message.part.updated","sessionID":"ses_x",
                      "part":{"id":"prt_0","messageID":"msg_u","type":"text","text":"do the thing"}}))
    # Assistant reply, streamed as an in-place text part (last update wins).
    print(json.dumps({"type":"message.updated","sessionID":"ses_x","info":{"id":"msg_a","role":"assistant"}}))
    print(json.dumps({"type":"message.part.updated","sessionID":"ses_x",
                      "part":{"id":"prt_1","messageID":"msg_a","type":"text","text":res}}))
    print(json.dumps({"type":"session.idle","sessionID":"ses_x"}))
PY
MOCK
chmod +x "$bindir/opencode"

export SINGULAR_TARGET_BRANCH="test-target"

new_repo() {
  local d="$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && printf '.singular-state/\n' > .gitignore && git add .gitignore && git commit -qm init \
      && git branch "$SINGULAR_TARGET_BRANCH" )
}

prompt() { local p="$workroot/prompt.md"; printf 'do the thing\n' > "$p"; echo "$p"; }

run_oc_run() {
  local repo="$1"; shift
  ( cd "$repo" && PATH="$bindir:$PATH" SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" "$RUN" "$@" )
}

extract() { python3 - "$1" "$2" <<'PY'
import json,sys
text=open(sys.argv[1]).read()
try: o=json.loads(text)
except Exception:
    i=text.find("{"); o=json.loads(text[i:text.rfind("}")+1])
print(o.get(sys.argv[2],""))
PY
}

i=0; out() { i=$((i+1)); echo "$workroot/out-$i.json"; }

# --- Case 1: L2 happy path -> assistant text captured (user echo dropped) -------
r="$workroot/c1"; new_repo "$r"; o="$(out)"; p="$(prompt)"; ec=0
MOCK_RESULT='{"status":"needs-review","summary":"ok"}' \
  run_oc_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 0 ]] || fail "c1: happy path should exit 0 (got $ec)"
[[ -f "$o" ]] || fail "c1: output file not written"
[[ "$(extract "$o" status)" == "needs-review" ]] || fail "c1: status not extracted"
grep -q "do the thing" "$o" && fail "c1: user-echo text leaked into assistant output"
pass "c1 L2 happy path: assistant text reassembled, user echo dropped"

# --- Case 2: missing binary -> 127 ---------------------------------------------
r="$workroot/c2"; new_repo "$r"; o="$(out)"; p="$(prompt)"; ec=0
( cd "$r" && PATH="/usr/bin:/bin" SINGULAR_ROOT="$r" SINGULAR_STATE_DIR="$r/.singular-state" \
    "$RUN" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" ) >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 127 ]] || fail "c2: missing opencode should exit 127 (got $ec)"
pass "c2 missing binary -> 127"

# --- Case 3: readonly restore-guard reverts a run-created untracked file --------
r="$workroot/c3"; new_repo "$r"; o="$(out)"; p="$(prompt)"
MOCK_RESULT='{"verdict":"accepted"}' MOCK_WRITE="$r/sneaky.txt" \
  run_oc_run "$r" --level readonly -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
[[ ! -e "$r/sneaky.txt" ]] || fail "c3: readonly did not remove run-created untracked file"
[[ "$(extract "$o" verdict)" == "accepted" ]] || fail "c3: verdict not extracted"
pass "c3 readonly restore-guard removes run-created file + verdict captured"

# --- Case 4: readonly reverts a tracked-file modification ----------------------
r="$workroot/c4"; new_repo "$r"; o="$(out)"; p="$(prompt)"
printf 'ORIGINAL\n' > "$r/tracked.txt"; ( cd "$r" && git add tracked.txt && git commit -qm seed )
MOCK_RESULT='{"verdict":"needs-fix"}' MOCK_WRITE="$r/tracked.txt" \
  run_oc_run "$r" --level readonly -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
[[ "$(cat "$r/tracked.txt")" == "ORIGINAL" ]] || fail "c4: readonly did not revert tracked mod"
pass "c4 readonly reverts tracked modification"

# --- Case 5: wall-clock timeout -> 124, kills the child tree --------------------
r="$workroot/c5"; new_repo "$r"; o="$(out)"; p="$(prompt)"; marker="$r/completed.marker"; ec=0
start=$SECONDS
MOCK_SLEEP=6 MOCK_MARKER="$marker" SINGULAR_OPENCODE_TIMEOUT_SEC=2 \
  run_oc_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
elapsed=$((SECONDS - start))
[[ "$ec" -eq 124 ]] || fail "c5: timeout should exit 124 (got $ec)"
[[ "$elapsed" -lt 10 ]] || fail "c5: timeout path exceeded bounded runner startup + kill budget (took ${elapsed}s)"
sleep 6
[[ ! -e "$marker" ]] || fail "c5: child survived the timeout kill (marker created)"
pass "c5 wall-clock timeout exits 124 and kills the child tree"

# --- Case 6: model flag omitted when unset, present when set (provider/model) ---
r="$workroot/c6"; new_repo "$r"; o="$(out)"; p="$(prompt)"; args="$workroot/c6.args"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args" \
  run_oc_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
grep -q -- "-m " "$args" && fail "c6: -m present when SINGULAR_OPENCODE_MODEL unset (got: $(cat "$args"))"
grep -q -- "run --format json" "$args" || fail "c6: expected 'run --format json' (got: $(cat "$args"))"
args2="$workroot/c6b.args"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args2" SINGULAR_OPENCODE_MODEL="anthropic/claude-sonnet-4-5" \
  run_oc_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
grep -q -- "-m anthropic/claude-sonnet-4-5" "$args2" || fail "c6: -m missing when model set (got: $(cat "$args2"))"
pass "c6 model flag omitted when unset, present when set"

# --- Case 7: error event -> exit 4 ---------------------------------------------
r="$workroot/c7"; new_repo "$r"; o="$(out)"; p="$(prompt)"; ec=0
MOCK_IS_ERROR=1 \
  run_oc_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 4 ]] || fail "c7: error event should exit 4 (got $ec)"
pass "c7 error event -> exit 4"

# --- Case 8: --session-meta written with provider opencode + empty sessionId ----
r="$workroot/c8"; new_repo "$r"; o="$(out)"; p="$(prompt)"; meta="$workroot/c8-meta.json"
MOCK_RESULT='{"ok":true}' \
  run_oc_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1
[[ -f "$meta" ]] || fail "c8: session-meta not written"
[[ "$(extract "$meta" provider)" == "opencode" ]] || fail "c8: provider not opencode"
[[ "$(extract "$meta" sessionId)" == "" ]] || fail "c8: sessionId should be empty (no affinity in v1)"
pass "c8 --session-meta written (provider opencode, empty sessionId)"

# --- Case 9: --resume-session refused with exit 86 (no model run) ---------------
r="$workroot/c9"; new_repo "$r"; o="$(out)"; p="$(prompt)"; args="$workroot/c9.args"; ec=0
MOCK_ARGS_OUT="$args" \
  run_oc_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" \
  --session-meta "$workroot/c9-meta.json" --resume-session "sess-x" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 86 ]] || fail "c9: --resume-session should exit 86 (got $ec)"
[[ ! -f "$args" ]] || fail "c9: runner should not have invoked opencode on resume refusal"
pass "c9 --resume-session -> exit 86 (refused, no model run)"

# --- Case 10: readonly asks opencode for its own restriction ------------------
# opencode was the only provider that passed NOTHING for a read-only run — its
# header said the post-run restore guard was the whole enforcement. A guard that
# runs afterwards cannot undo a `git commit` and does not run at all if the
# process is SIGKILLed, so cleanup alone was never enough.
r="$workroot/c10"; new_repo "$r"; o="$(out)"; p="$(prompt)"; args="$workroot/c10.args"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args" \
  run_oc_run "$r" --level readonly -C "$r" --prompt-file "$p" \
  --output-last-message "$o" >/dev/null 2>&1
grep -q -- "--agent plan" "$args" \
  || fail "c10: readonly did not select the read-only agent (got: $(cat "$args"))"
args2="$workroot/c10b.args"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args2" \
  run_oc_run "$r" --level l2 -C "$r" --prompt-file "$p" \
  --output-last-message "$o" >/dev/null 2>&1
grep -q -- "--agent" "$args2" && fail "c10: l2 must not be pinned to the read-only agent"
pass "c10 readonly selects the read-only agent; l2 does not"

echo "ALL OPENCODE-RUN CONTRACT TESTS PASSED"
