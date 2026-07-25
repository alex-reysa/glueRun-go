#!/usr/bin/env bash
set -euo pipefail

# Deterministic contract tests for cursor-run.sh (0.9.0 providers). A mock
# `cursor-agent` binary emits the single result envelope cursor prints under
# --output-format json ({"type":"result","result":"...","is_error":bool,...}), so
# these run offline and in CI. They assert the drop-in contract: .result captured
# into --output-last-message, missing-binary -> 127, the read-only restore guard,
# wall-clock timeout (-> 124), the model flag omitted when GLUERUN_CURSOR_MODEL is
# unset and present when set, readonly -> `--mode ask` (not -f), and is_error -> 4.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
RUN="$SCRIPT_DIR/cursor-run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/gluerun-cursor-test.XXXXXX")"
bindir="$workroot/bin"
mkdir -p "$bindir"
cleanup() { rm -rf "$workroot"; }
trap cleanup EXIT

# --- Mock cursor-agent ---------------------------------------------------------
#   MOCK_RESULT   -> string placed in the envelope .result
#   MOCK_WRITE    -> if set, mock overwrites this path (simulates a mutating agent)
#   MOCK_IS_ERROR -> "1" sets is_error=true (error envelope)
#   MOCK_ARGS_OUT -> records the argv the runner assembled
#   MOCK_SLEEP/MOCK_MARKER -> slow run + marker touched only if not killed
cat >"$bindir/cursor-agent" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${MOCK_ARGS_OUT:-}" ]] && printf '%s\n' "$*" > "$MOCK_ARGS_OUT"
cat >/dev/null 2>&1 || true   # consume the piped prompt (stdin)
if [[ -n "${MOCK_WRITE:-}" ]]; then printf 'MUTATED\n' > "$MOCK_WRITE"; fi
if [[ -n "${MOCK_SLEEP:-}" ]]; then sleep "$MOCK_SLEEP"; [[ -n "${MOCK_MARKER:-}" ]] && touch "$MOCK_MARKER"; fi
python3 - <<PY
import json, os
err = os.environ.get("MOCK_IS_ERROR") == "1"
print(json.dumps({"type": "result", "subtype": "error" if err else "success",
                  "is_error": err,
                  "result": os.environ.get("MOCK_RESULT", '{"verdict":"accepted"}'),
                  "session_id": "csess"}))
PY
MOCK
chmod +x "$bindir/cursor-agent"

export GLUERUN_TARGET_BRANCH="test-target"

new_repo() {
  local d="$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && printf '.gluerun-state/\n' > .gitignore && git add .gitignore && git commit -qm init \
      && git branch "$GLUERUN_TARGET_BRANCH" )
}

prompt() { local p="$workroot/prompt.md"; printf 'do the thing\n' > "$p"; echo "$p"; }

run_cursor_run() {
  local repo="$1"; shift
  ( cd "$repo" && PATH="$bindir:$PATH" GLUERUN_ROOT="$repo" GLUERUN_STATE_DIR="$repo/.gluerun-state" "$RUN" "$@" )
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

# --- Case 1: L2 happy path -> .result captured + extractable + exit 0 -----------
r="$workroot/c1"; new_repo "$r"; o="$(out)"; p="$(prompt)"; ec=0
MOCK_RESULT='{"status":"needs-review","summary":"ok"}' \
  run_cursor_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 0 ]] || fail "c1: happy path should exit 0 (got $ec)"
[[ -f "$o" ]] || fail "c1: output file not written"
[[ "$(extract "$o" status)" == "needs-review" ]] || fail "c1: status not extracted"
pass "c1 L2 happy path: .result captured + exit 0"

# --- Case 2: missing binary -> 127 ---------------------------------------------
r="$workroot/c2"; new_repo "$r"; o="$(out)"; p="$(prompt)"; ec=0
( cd "$r" && PATH="/usr/bin:/bin" GLUERUN_ROOT="$r" GLUERUN_STATE_DIR="$r/.gluerun-state" \
    "$RUN" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" ) >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 127 ]] || fail "c2: missing cursor-agent should exit 127 (got $ec)"
pass "c2 missing binary -> 127"

# --- Case 3: readonly restore-guard reverts a run-created untracked file --------
r="$workroot/c3"; new_repo "$r"; o="$(out)"; p="$(prompt)"
MOCK_RESULT='{"verdict":"accepted"}' MOCK_WRITE="$r/sneaky.txt" \
  run_cursor_run "$r" --level readonly -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
[[ ! -e "$r/sneaky.txt" ]] || fail "c3: readonly did not remove run-created untracked file"
[[ "$(extract "$o" verdict)" == "accepted" ]] || fail "c3: verdict not extracted"
pass "c3 readonly restore-guard removes run-created file + verdict captured"

# --- Case 4: readonly reverts a tracked-file modification ----------------------
r="$workroot/c4"; new_repo "$r"; o="$(out)"; p="$(prompt)"
printf 'ORIGINAL\n' > "$r/tracked.txt"; ( cd "$r" && git add tracked.txt && git commit -qm seed )
MOCK_RESULT='{"verdict":"needs-fix"}' MOCK_WRITE="$r/tracked.txt" \
  run_cursor_run "$r" --level readonly -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
[[ "$(cat "$r/tracked.txt")" == "ORIGINAL" ]] || fail "c4: readonly did not revert tracked mod"
pass "c4 readonly reverts tracked modification"

# --- Case 5: wall-clock timeout -> 124, kills the child tree --------------------
r="$workroot/c5"; new_repo "$r"; o="$(out)"; p="$(prompt)"; marker="$r/completed.marker"; ec=0
start=$SECONDS
MOCK_SLEEP=6 MOCK_MARKER="$marker" GLUERUN_CURSOR_TIMEOUT_SEC=2 \
  run_cursor_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
elapsed=$((SECONDS - start))
[[ "$ec" -eq 124 ]] || fail "c5: timeout should exit 124 (got $ec)"
[[ "$elapsed" -lt 10 ]] || fail "c5: timeout path exceeded bounded runner startup + kill budget (took ${elapsed}s)"
sleep 6
[[ ! -e "$marker" ]] || fail "c5: child survived the timeout kill (marker created)"
pass "c5 wall-clock timeout exits 124 and kills the child tree"

# --- Case 6: model flag omitted when unset, present when set; l2 uses -f --------
r="$workroot/c6"; new_repo "$r"; o="$(out)"; p="$(prompt)"; args="$workroot/c6.args"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args" \
  run_cursor_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
grep -q -- "--model " "$args" && fail "c6: --model present when GLUERUN_CURSOR_MODEL unset (got: $(cat "$args"))"
grep -qw -- "-f" "$args" || fail "c6: l2 should pass -f (got: $(cat "$args"))"
args2="$workroot/c6b.args"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args2" GLUERUN_CURSOR_MODEL="auto" \
  run_cursor_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
grep -q -- "--model auto" "$args2" || fail "c6: --model auto missing when model set (got: $(cat "$args2"))"
pass "c6 model flag omitted when unset, present when set; l2 -> -f"

# --- Case 6b: readonly maps to `--mode ask` (not -f) ---------------------------
r="$workroot/c6c"; new_repo "$r"; o="$(out)"; p="$(prompt)"; args="$workroot/c6c.args"
MOCK_RESULT='{"ok":true}' MOCK_ARGS_OUT="$args" \
  run_cursor_run "$r" --level readonly -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1
grep -q -- "--mode ask" "$args" || fail "c6b: readonly should pass --mode ask (got: $(cat "$args"))"
grep -qw -- "-f" "$args" && fail "c6b: readonly must not pass -f"
pass "c6b readonly -> --mode ask (no -f)"

# --- Case 7: is_error envelope -> exit 4 ---------------------------------------
r="$workroot/c7"; new_repo "$r"; o="$(out)"; p="$(prompt)"; ec=0
MOCK_IS_ERROR=1 \
  run_cursor_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 4 ]] || fail "c7: is_error envelope should exit 4 (got $ec)"
pass "c7 is_error envelope -> exit 4"

# --- Case 8: --session-meta written with provider cursor + empty sessionId ------
r="$workroot/c8"; new_repo "$r"; o="$(out)"; p="$(prompt)"; meta="$workroot/c8-meta.json"
MOCK_RESULT='{"ok":true}' \
  run_cursor_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1
[[ -f "$meta" ]] || fail "c8: session-meta not written"
[[ "$(extract "$meta" provider)" == "cursor" ]] || fail "c8: provider not cursor"
[[ "$(extract "$meta" sessionId)" == "" ]] || fail "c8: sessionId should be empty (no affinity in v1)"
pass "c8 --session-meta written (provider cursor, empty sessionId)"

# --- Case 9: --resume-session refused with exit 86 (no model run) ---------------
r="$workroot/c9"; new_repo "$r"; o="$(out)"; p="$(prompt)"; args="$workroot/c9.args"; ec=0
MOCK_ARGS_OUT="$args" \
  run_cursor_run "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" \
  --session-meta "$workroot/c9-meta.json" --resume-session "sess-x" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 86 ]] || fail "c9: --resume-session should exit 86 (got $ec)"
[[ ! -f "$args" ]] || fail "c9: runner should not have invoked cursor-agent on resume refusal"
pass "c9 --resume-session -> exit 86 (refused, no model run)"

echo "ALL CURSOR-RUN CONTRACT TESTS PASSED"
