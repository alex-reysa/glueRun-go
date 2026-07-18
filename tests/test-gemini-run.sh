#!/usr/bin/env bash
set -euo pipefail

# Deterministic contract tests for gemini-run.sh (0.9.0 providers). A mock `gemini`
# binary stands in for the real CLI so these run offline, for free, and in CI. They
# assert the drop-in contract: final-message capture from the `-o json` envelope
# (.response) into --output-last-message, missing-binary -> 127, the read-only
# restore guard, the wall-clock timeout (-> 124), the model flag being omitted when
# GLUERUN_GEMINI_MODEL is unset and present when set, and error-envelope -> exit 4.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
RUN="$SCRIPT_DIR/gemini-run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/gluerun-gemini-test.XXXXXX")"
bindir="$workroot/bin"
mkdir -p "$bindir"
cleanup() { rm -rf "$workroot"; }
trap cleanup EXIT

# --- Mock gemini ---------------------------------------------------------------
#   MOCK_RESULT    -> string placed in the envelope .response
#   MOCK_WRITE     -> if set, mock overwrites this path (simulates a mutating agent)
#   MOCK_IS_ERROR  -> "1" emits a {"error": {...}} envelope
#   MOCK_ARGS_OUT  -> records the argv the runner assembled
#   MOCK_SLEEP/MOCK_MARKER -> slow run + marker touched only if not killed
cat >"$bindir/gemini" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${MOCK_ARGS_OUT:-}" ]] && printf '%s\n' "$*" > "$MOCK_ARGS_OUT"
cat >/dev/null 2>&1 || true   # consume the piped prompt
if [[ -n "${MOCK_WRITE:-}" ]]; then printf 'MUTATED\n' > "$MOCK_WRITE"; fi
if [[ -n "${MOCK_SLEEP:-}" ]]; then sleep "$MOCK_SLEEP"; [[ -n "${MOCK_MARKER:-}" ]] && touch "$MOCK_MARKER"; fi
envjson="$(python3 - <<PY
import json, os
if os.environ.get("MOCK_IS_ERROR") == "1":
    print(json.dumps({"session_id": "gsess", "error": {"type": "Error", "message": "boom"}}))
else:
    print(json.dumps({"session_id": "gsess",
                      "response": os.environ.get("MOCK_RESULT", '{"verdict":"accepted"}'),
                      "stats": {"tokens": 1}}))
PY
)"
if [[ -n "${MOCK_STDERR_ENVELOPE:-}" ]]; then
  # gemini 0.42.x behavior: warning line + JSON envelope on stderr, stdout empty
  echo 'Approval mode overridden to "default" because the current folder is not trusted.' >&2
  printf '%s\n' "$envjson" >&2
else
  printf '%s\n' "$envjson"
fi
MOCK
chmod +x "$bindir/gemini"

export GLUERUN_TARGET_BRANCH="test-target"

new_repo() {
  local d="$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && printf '.gluerun-state/\n' > .gitignore && git add .gitignore && git commit -qm init \
      && git branch "$GLUERUN_TARGET_BRANCH" )
}

prompt() { local p="$workroot/prompt.md"; printf 'do the thing\n' > "$p"; echo "$p"; }

run_gemini_run() { # repo, then runner args (mock gemini on PATH)
  local repo="$1"; shift
  ( cd "$repo" && PATH="$bindir:$PATH" GLUERUN_ROOT="$repo" GLUERUN_STATE_DIR="$repo/.gluerun-state" "$RUN" "$@" )
}

extract() { python3 - "$1" "$2" <<'PY'
import json,sys
o=json.load(open(sys.argv[1])) if False else None
text=open(sys.argv[1]).read()
try: o=json.loads(text)
except Exception:
    i=text.find("{"); o=json.loads(text[i:text.rfind("}")+1])
print(o.get(sys.argv[2],""))
PY
}

i=0; out() { i=$((i+1)); echo "$workroot/out-$i.json"; }

# --- Case 1: L2 happy path -> output-last-message written + extractable + exit 0 -
r="$workroot/c1"; new_repo "$r"; o="$(out)"; p="$(prompt)"; ec=0
MOCK_RESULT='{"status":"needs-review","summary":"ok"}' \
  run_gemini_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 0 ]] || fail "c1: happy path should exit 0 (got $ec)"
[[ -f "$o" ]] || fail "c1: output file not written"
[[ "$(extract "$o" status)" == "needs-review" ]] || fail "c1: status not extracted"
pass "c1 L2 happy path: final message captured + exit 0"

# --- Case 2: missing binary -> 127 ---------------------------------------------
r="$workroot/c2"; new_repo "$r"; o="$(out)"; p="$(prompt)"; ec=0
( cd "$r" && PATH="/usr/bin:/bin" GLUERUN_ROOT="$r" GLUERUN_STATE_DIR="$r/.gluerun-state" \
    "$RUN" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" ) >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 127 ]] || fail "c2: missing gemini should exit 127 (got $ec)"
pass "c2 missing binary -> 127"

# --- Case 3: readonly restore-guard reverts a run-created untracked file --------
r="$workroot/c3"; new_repo "$r"; o="$(out)"; p="$(prompt)"
MOCK_RESULT='{"verdict":"accepted"}' MOCK_WRITE="$r/sneaky.txt" \
  run_gemini_run "$r" --level readonly -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
[[ ! -e "$r/sneaky.txt" ]] || fail "c3: readonly did not remove run-created untracked file"
[[ "$(extract "$o" verdict)" == "accepted" ]] || fail "c3: verdict not extracted"
pass "c3 readonly restore-guard removes run-created file + verdict captured"

# --- Case 4: readonly reverts a tracked-file modification ----------------------
r="$workroot/c4"; new_repo "$r"; o="$(out)"; p="$(prompt)"
printf 'ORIGINAL\n' > "$r/tracked.txt"; ( cd "$r" && git add tracked.txt && git commit -qm seed )
MOCK_RESULT='{"verdict":"needs-fix"}' MOCK_WRITE="$r/tracked.txt" \
  run_gemini_run "$r" --level readonly -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
[[ "$(cat "$r/tracked.txt")" == "ORIGINAL" ]] || fail "c4: readonly did not revert tracked mod"
pass "c4 readonly reverts tracked modification"

# --- Case 5: wall-clock timeout -> 124, kills the child tree --------------------
r="$workroot/c5"; new_repo "$r"; o="$(out)"; p="$(prompt)"; marker="$r/completed.marker"; ec=0
start=$SECONDS
MOCK_SLEEP=6 MOCK_MARKER="$marker" GLUERUN_GEMINI_TIMEOUT_SEC=2 \
  run_gemini_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
elapsed=$((SECONDS - start))
[[ "$ec" -eq 124 ]] || fail "c5: timeout should exit 124 (got $ec)"
[[ "$elapsed" -lt 6 ]] || fail "c5: should return before the mock's 6s sleep (took ${elapsed}s)"
sleep 6
[[ ! -e "$marker" ]] || fail "c5: child survived the timeout kill (marker created)"
pass "c5 wall-clock timeout exits 124 and kills the child tree"

# --- Case 6: model flag omitted when unset, present when set -------------------
r="$workroot/c6"; new_repo "$r"; o="$(out)"; p="$(prompt)"; args="$workroot/c6.args"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args" \
  run_gemini_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
grep -q -- "-m " "$args" && fail "c6: -m present when GLUERUN_GEMINI_MODEL unset (got: $(cat "$args"))"
grep -q -- "--yolo" "$args" || fail "c6: l2 should pass --yolo (got: $(cat "$args"))"
args2="$workroot/c6b.args"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args2" GLUERUN_GEMINI_MODEL="gemini-3-flash" \
  run_gemini_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
grep -q -- "-m gemini-3-flash" "$args2" || fail "c6: -m gemini-3-flash missing when model set (got: $(cat "$args2"))"
pass "c6 model flag omitted when unset, present when set"

# --- Case 6b: readonly maps to --approval-mode plan (not --yolo) ---------------
r="$workroot/c6c"; new_repo "$r"; o="$(out)"; p="$(prompt)"; args="$workroot/c6c.args"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args" \
  run_gemini_run "$r" --level readonly -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
grep -q -- "--approval-mode plan" "$args" || fail "c6b: readonly should pass --approval-mode plan (got: $(cat "$args"))"
grep -q -- "--yolo" "$args" && fail "c6b: readonly must not pass --yolo"
pass "c6b readonly -> --approval-mode plan"

# --- Case 7: error envelope -> exit 4 ------------------------------------------
r="$workroot/c7"; new_repo "$r"; o="$(out)"; p="$(prompt)"; ec=0
MOCK_IS_ERROR=1 \
  run_gemini_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 4 ]] || fail "c7: error envelope should exit 4 (got $ec)"
pass "c7 error envelope -> exit 4"

# --- Case 8: --session-meta written with provider gemini + empty sessionId -----
r="$workroot/c8"; new_repo "$r"; o="$(out)"; p="$(prompt)"; meta="$workroot/c8-meta.json"
MOCK_RESULT='{"ok":true}' \
  run_gemini_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1
[[ -f "$meta" ]] || fail "c8: session-meta not written"
[[ "$(extract "$meta" provider)" == "gemini" ]] || fail "c8: provider not gemini"
[[ "$(extract "$meta" sessionId)" == "" ]] || fail "c8: sessionId should be empty (no affinity in v1)"
pass "c8 --session-meta written (provider gemini, empty sessionId)"

# --- Case 9: --resume-session refused with exit 86 (no model run) ---------------
r="$workroot/c9"; new_repo "$r"; o="$(out)"; p="$(prompt)"; args="$workroot/c9.args"; ec=0
MOCK_ARGS_OUT="$args" \
  run_gemini_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" \
  --session-meta "$workroot/c9-meta.json" --resume-session "sess-x" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 86 ]] || fail "c9: --resume-session should exit 86 (got $ec)"
[[ ! -f "$args" ]] || fail "c9: runner should not have invoked gemini on resume refusal"
pass "c9 --resume-session -> exit 86 (refused, no model run)"

# --- Case 10: envelope on stderr (gemini 0.42.x) still captured, exit 0 ---------
r="$workroot/c10"; new_repo "$r"; o="$(out)"; p="$(prompt)"; ec=0
MOCK_STDERR_ENVELOPE=1 MOCK_RESULT='{"status":"ok-from-stderr"}' \
  run_gemini_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 0 ]] || fail "c10: stderr-envelope path should exit 0 (got $ec)"
[[ "$(extract "$o" status)" == "ok-from-stderr" ]] || fail "c10: message not captured from stderr envelope"
pass "c10 stderr envelope (0.42.x quirk) -> captured + exit 0"

echo "ALL GEMINI-RUN CONTRACT TESTS PASSED"
