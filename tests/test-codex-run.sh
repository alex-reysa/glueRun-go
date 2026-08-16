#!/usr/bin/env bash
set -euo pipefail

# Contract tests for codex-run.sh -- the engine's default runner, and until now
# the only adapter without one. test-codex-run-session.sh covers session meta and
# resume; test-codex-run-timeout.sh covers the wall-clock, idle and
# completion-grace guards. This file covers the drop-in contract every sibling
# adapter has pinned for releases: the argv codex is actually handed (model,
# reasoning effort, sandbox per level), the last-message capture, missing binary
# -> 127, argument and level rejection, the scope check on l0/l1, the normalized
# runner result, and the contract probe itself.
#
# A mock `codex` stands in for the CLI: it records its argv, honours -o by
# writing the final message, and emits the JSONL event stream codex --json
# produces. Offline, deterministic, no network.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ENGINE_HOME/engine/codex-run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-codex-test.XXXXXX")"
bindir="$workroot/bin"
mkdir -p "$bindir"
trap 'rm -rf "$workroot"' EXIT

# --- Mock codex ----------------------------------------------------------------
#   MOCK_ARGS_OUT -> records the argv the runner assembled
#   MOCK_RESULT   -> JSON written to the -o path (the final assistant message)
#   MOCK_WRITE    -> path the "agent" mutates (for the scope check)
#   MOCK_EXIT     -> exit code
#   MOCK_FAILED   -> emit a terminal failure event instead of turn.completed
cat >"$bindir/codex" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${MOCK_ARGS_OUT:-}" ]] && printf '%s\n' "$*" > "$MOCK_ARGS_OUT"
out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then out="$arg"; fi
  prev="$arg"
done
cat >/dev/null 2>&1 || true
if [[ -n "${MOCK_WRITE:-}" ]]; then printf 'MUTATED\n' > "$MOCK_WRITE"; fi
printf '%s\n' '{"type":"thread.started","thread_id":"th-1"}'
if [[ "${MOCK_FAILED:-0}" == "1" ]]; then
  printf '%s\n' '{"type":"turn.failed","error":{"message":"boom"}}'
else
  printf '%s\n' '{"type":"turn.completed"}'
fi
if [[ -n "$out" ]]; then printf '%s\n' "${MOCK_RESULT:-{\"ok\":true\}}" > "$out"; fi
exit "${MOCK_EXIT:-0}"
MOCK
chmod +x "$bindir/codex"

export SINGULAR_TARGET_BRANCH="test-target"

new_repo() {
  local d="$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && printf '.singular-state/\n' > .gitignore && git add .gitignore \
      && git commit -qm init && git branch "$SINGULAR_TARGET_BRANCH" )
}

prompt() { local p="$workroot/prompt.md"; printf 'do the thing\n' > "$p"; echo "$p"; }

run_codex() {
  local repo="$1"; shift
  ( cd "$repo" && PATH="$bindir:$PATH" SINGULAR_ROOT="$repo" \
      SINGULAR_STATE_DIR="$repo/.singular-state" "$RUN" "$@" )
}

i=0; out() { i=$((i+1)); echo "$workroot/out-$i.json"; }

# --- Case 1: L2 happy path -> final message captured, exit 0 --------------------
r="$workroot/c1"; new_repo "$r"; o="$(out)"; p="$(prompt)"; ec=0
MOCK_RESULT='{"status":"needs-review"}' \
  run_codex "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" \
  >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 0 ]] || fail "c1: happy path should exit 0 (got $ec)"
[[ -f "$o" ]] || fail "c1: last message not captured"
grep -q "needs-review" "$o" || fail "c1: captured message is not the provider's"
pass "c1 L2 happy path: final message captured + exit 0"

# --- Case 2: missing binary -> 127 ----------------------------------------------
r="$workroot/c2"; new_repo "$r"; o="$(out)"; p="$(prompt)"; ec=0
( cd "$r" && PATH="/usr/bin:/bin" SINGULAR_ROOT="$r" SINGULAR_STATE_DIR="$r/.singular-state" \
    "$RUN" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" ) \
  >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 127 ]] || fail "c2: missing codex should exit 127 (got $ec)"
pass "c2 missing binary -> 127"

# --- Case 3: --describe-contract is the contract doctor probes ------------------
contract="$(run_codex "$workroot" --describe-contract)"
python3 - "$contract" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["schema"] == "singular.runner-contract.v1", data
assert data["provider"] == "codex", data
required = {
    "--worktree", "--prompt-file", "--level", "--run-id", "--output-schema",
    "--output-last-message", "--no-output-capture", "--allow-prefix",
    "--session-meta", "--resume-session", "--role", "--capability-profile",
    "--result-file", "--describe-contract",
}
missing = required - set(data["arguments"])
assert not missing, missing
assert data["structuredResult"] == "singular.orchestration.runner-result.v0"
assert data["structuredProviderError"] == "singular.orchestration.provider-error.v0"
PY
pass "c3 --describe-contract advertises contract v1 for codex"

# --- Case 4: level -> sandbox mapping, and the L2 override is validated ---------
r="$workroot/c4"; new_repo "$r"; p="$(prompt)"
for pair in "l2:workspace-write" "l1:workspace-write" "readonly:read-only"; do
  level="${pair%%:*}"; want="${pair##*:}"; o="$(out)"; args="$workroot/c4-$level.args"
  MOCK_ARGS_OUT="$args" run_codex "$r" --level "$level" -C "$r" --prompt-file "$p" \
    --output-last-message "$o" >/dev/null 2>&1 || true
  grep -q -- "--sandbox $want" "$args" \
    || fail "c4: level $level should map to --sandbox $want (got: $(cat "$args"))"
done
o="$(out)"; ec=0
SINGULAR_L2_SANDBOX="wide-open" run_codex "$r" --level l2 -C "$r" --prompt-file "$p" \
  --output-last-message "$o" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 2 ]] || fail "c4: an invalid SINGULAR_L2_SANDBOX must exit 2 (got $ec)"
pass "c4 level -> sandbox mapping (l2/l1 workspace-write, readonly read-only); bad override -> 2"

# --- Case 5: model comes from the spec default, effort is role-keyed ------------
r="$workroot/c5"; new_repo "$r"; p="$(prompt)"
spec_default="$(python3 - "$ENGINE_HOME" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/engine")
import provider_spec
print(provider_spec.model_env()["codex"][1])
PY
)"
o="$(out)"; args="$workroot/c5.args"
MOCK_ARGS_OUT="$args" run_codex "$r" --level l2 -C "$r" --prompt-file "$p" \
  --output-last-message "$o" >/dev/null 2>&1 || true
grep -q -- "-m $spec_default" "$args" \
  || fail "c5: unset model must fall back to the spec default $spec_default (got: $(cat "$args"))"
grep -q 'model_reasoning_effort="medium"' "$args" \
  || fail "c5: l2 defaults to medium effort (got: $(cat "$args"))"
o="$(out)"; args="$workroot/c5b.args"
MOCK_ARGS_OUT="$args" SINGULAR_CODEX_MODEL="gpt-test-9" \
  run_codex "$r" --level readonly -C "$r" --prompt-file "$p" \
  --output-last-message "$o" >/dev/null 2>&1 || true
grep -q -- "-m gpt-test-9" "$args" \
  || fail "c5: SINGULAR_CODEX_MODEL must win (got: $(cat "$args"))"
grep -q 'model_reasoning_effort="high"' "$args" \
  || fail "c5: readonly defaults to high effort (got: $(cat "$args"))"
pass "c5 model default comes from the spec; SINGULAR_CODEX_MODEL wins; effort is role-keyed"

# --- Case 6: unknown option and unknown level are refused before dispatch -------
r="$workroot/c6"; new_repo "$r"; p="$(prompt)"; args="$workroot/c6.args"; ec=0
MOCK_ARGS_OUT="$args" run_codex "$r" --level l2 -C "$r" --prompt-file "$p" --nope \
  >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 2 ]] || fail "c6: unknown option should exit 2 (got $ec)"
ec=0
MOCK_ARGS_OUT="$args" run_codex "$r" --level l7 -C "$r" --prompt-file "$p" \
  >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 2 ]] || fail "c6: unknown level should exit 2 (got $ec)"
[[ ! -f "$args" ]] || fail "c6: codex must not run when arguments are refused"
pass "c6 unknown option / unknown level -> exit 2, provider never invoked"

# --- Case 7: the normalized runner result is written ----------------------------
r="$workroot/c7"; new_repo "$r"; o="$(out)"; p="$(prompt)"; result="$workroot/c7-result.json"
run_codex "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" \
  --role implementer --capability-profile default --result-file "$result" \
  >/dev/null 2>&1 || true
[[ -f "$result" ]] || fail "c7: runner result not written"
python3 - "$result" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema"] == "singular.orchestration.runner-result.v0", data
assert data["provider"] == "codex", data
assert data["role"] == "implementer", data
assert data["outcome"] == "succeeded", data
assert data["exitCode"] == 0, data
PY
pass "c7 normalized runner result written (provider codex, outcome succeeded)"

# --- Case 8: a terminal provider failure event does not report success ----------
# The mock exits 0: the verdict has to come from the terminal event in the
# stream, which is the signal a provider that dies mid-turn actually leaves.
r="$workroot/c8"; new_repo "$r"; o="$(out)"; p="$(prompt)"; result="$workroot/c8-result.json"; ec=0
MOCK_FAILED=1 \
  run_codex "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" \
  --result-file "$result" >/dev/null 2>&1 || ec=$?
[[ "$ec" -ne 0 ]] || fail "c8: a terminal failure event must not exit 0"
[[ -f "$result" ]] || fail "c8: runner result not written on failure"
python3 - "$result" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["provider"] == "codex", data
assert data["outcome"] != "succeeded", data
PY
pass "c8 terminal provider failure -> nonzero exit + non-succeeded result"

# --- Case 9: l1 scope check -- both directions ----------------------------------
# Both halves matter: a check that rejects everything would pass the negative
# case while making l1 unusable, so the compliant write is asserted too.
r="$workroot/c9-in"; new_repo "$r"; mkdir -p "$r/docs/orchestration"; o="$(out)"; p="$(prompt)"; ec=0
MOCK_WRITE="$r/docs/orchestration/plan.md" \
  run_codex "$r" --level l1 -C "$r" --prompt-file "$p" --output-last-message "$o" \
  --allow-prefix "docs/orchestration" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 0 ]] || fail "c9: an l1 write inside the allowed prefix must pass (got $ec)"
r="$workroot/c9-out"; new_repo "$r"; o="$(out)"; ec=0
MOCK_WRITE="$r/outside.txt" \
  run_codex "$r" --level l1 -C "$r" --prompt-file "$p" --output-last-message "$o" \
  --allow-prefix "docs/orchestration" >/dev/null 2>&1 || ec=$?
[[ "$ec" -ne 0 ]] || fail "c9: an l1 write outside the allowed prefix must fail the run"
pass "c9 l1 scope check admits the allowed prefix and rejects everything else"

# --- Case 10: --no-output-capture leaves -o off the argv ------------------------
r="$workroot/c10"; new_repo "$r"; p="$(prompt)"; args="$workroot/c10.args"
MOCK_ARGS_OUT="$args" run_codex "$r" --level l2 -C "$r" --prompt-file "$p" \
  --no-output-capture >/dev/null 2>&1 || true
[[ -f "$args" ]] || fail "c10: codex was never invoked"
! grep -qE -- '(^| )-o( |$)' "$args" \
  || fail "c10: --no-output-capture must not pass -o (got: $(cat "$args"))"
pass "c10 --no-output-capture omits the provider's output flag"

echo "ALL CODEX-RUN CONTRACT TESTS PASSED"
