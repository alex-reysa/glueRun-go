#!/usr/bin/env bash
set -euo pipefail

# Contract tests for openrouter-run.sh. OpenRouter has no CLI of its own, so the
# adapter dispatches OpenRouter models through the OpenCode CLI; a mock
# `opencode` emits the same `--format json` event stream the real one does, so
# these run offline.
#
# What is asserted here is what makes OpenRouter a PROVIDER rather than a model
# string: the namespace is enforced before anything is dispatched (an unset or
# foreign ref would answer from OpenCode's own default model under OpenRouter's
# name), the model reaches the CLI as configured, and the provider recorded in
# the runner result, the session meta and the failure contract is `openrouter` --
# because that is the name every quota window, backoff and evidence query is
# keyed by. The shared OpenCode behavior (text reassembly, the read-only agent,
# timeouts, the guard) is covered once in tests/test-opencode-run.sh.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ENGINE_HOME/engine/openrouter-run.sh"
MODEL="openrouter/anthropic/claude-sonnet-4.5"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-openrouter-test.XXXXXX")"
bindir="$workroot/bin"
mkdir -p "$bindir"
trap 'rm -rf "$workroot"' EXIT

cat >"$bindir/opencode" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${MOCK_ARGS_OUT:-}" ]] && printf '%s\n' "$*" > "$MOCK_ARGS_OUT"
[[ -n "${MOCK_ENV_OUT:-}" ]] && env > "$MOCK_ENV_OUT"
cat >/dev/null 2>&1 || true
python3 - <<PY
import json, os
res = os.environ.get("MOCK_RESULT", '{"verdict":"accepted"}')
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
      && printf '.singular-state/\n' > .gitignore && git add .gitignore \
      && git commit -qm init && git branch "$SINGULAR_TARGET_BRANCH" )
}

prompt() { local p="$workroot/prompt.md"; printf 'do the thing\n' > "$p"; echo "$p"; }

run_openrouter() {
  local repo="$1"; shift
  ( cd "$repo" && PATH="$bindir:$PATH" SINGULAR_ROOT="$repo" \
      SINGULAR_STATE_DIR="$repo/.singular-state" "$RUN" "$@" )
}

extract() { python3 - "$1" "$2" <<'PY'
import json,sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data.get(sys.argv[2], ""))
PY
}

i=0; out() { i=$((i+1)); echo "$workroot/out-$i.json"; }

# --- Case 1: the configured OpenRouter ref reaches the CLI ----------------------
r="$workroot/c1"; new_repo "$r"; o="$(out)"; p="$(prompt)"; args="$workroot/c1.args"; ec=0
MOCK_RESULT='{"status":"needs-review"}' MOCK_ARGS_OUT="$args" \
  SINGULAR_OPENROUTER_MODEL="$MODEL" \
  run_openrouter "$r" --level l2 -C "$r" --prompt-file "$p" --output-last-message "$o" \
  >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 0 ]] || fail "c1: happy path should exit 0 (got $ec)"
grep -q -- "-m $MODEL" "$args" || fail "c1: model not passed (got: $(cat "$args"))"
grep -q "needs-review" "$o" || fail "c1: assistant text not captured"
pass "c1 configured openrouter/ ref is dispatched and its answer captured"

# --- Case 2: the namespace is required ------------------------------------------
# Without it the CLI would answer from ITS default model, and the run would be
# recorded, billed and rate-limited as OpenRouter regardless.
r="$workroot/c2"; new_repo "$r"; o="$(out)"; args="$workroot/c2.args"; ec=0
run_openrouter "$r" --level l2 -C "$r" --prompt-file "$(prompt)" --output-last-message "$o" \
  >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 2 ]] || fail "c2: an unset model must exit 2 (got $ec)"
[[ ! -f "$args" ]] || fail "c2: the provider must not be invoked without a model"
pass "c2 unset SINGULAR_OPENROUTER_MODEL -> exit 2, provider never invoked"

r="$workroot/c2b"; new_repo "$r"; o="$(out)"; args="$workroot/c2b.args"; ec=0
MOCK_ARGS_OUT="$args" SINGULAR_OPENROUTER_MODEL="anthropic/claude-sonnet-4.5" \
  run_openrouter "$r" --level l2 -C "$r" --prompt-file "$(prompt)" --output-last-message "$o" \
  >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 2 ]] || fail "c2b: a foreign model ref must exit 2 (got $ec)"
[[ ! -f "$args" ]] || fail "c2b: the provider must not be invoked with a foreign ref"
pass "c2b a non-openrouter model ref -> exit 2, provider never invoked"

# --- Case 3: missing host CLI -> 127 --------------------------------------------
r="$workroot/c3"; new_repo "$r"; o="$(out)"; ec=0
( cd "$r" && PATH="/usr/bin:/bin" SINGULAR_ROOT="$r" SINGULAR_STATE_DIR="$r/.singular-state" \
    SINGULAR_OPENROUTER_MODEL="$MODEL" \
    "$RUN" --level l2 -C "$r" --prompt-file "$(prompt)" --output-last-message "$o" ) \
  >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 127 ]] || fail "c3: a missing host CLI should exit 127 (got $ec)"
pass "c3 missing host CLI -> 127"

# --- Case 4: every record says openrouter, not the CLI it rode in on ------------
r="$workroot/c4"; new_repo "$r"; o="$(out)"; meta="$workroot/c4-meta.json"
result="$workroot/c4-result.json"
SINGULAR_OPENROUTER_MODEL="$MODEL" \
  run_openrouter "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" --session-meta "$meta" --role implementer \
  --result-file "$result" >/dev/null 2>&1 || true
[[ -f "$meta" ]] || fail "c4: session meta not written"
[[ "$(extract "$meta" provider)" == "openrouter" ]] \
  || fail "c4: session meta provider is not openrouter"
[[ "$(extract "$meta" model)" == "$MODEL" ]] || fail "c4: session meta model mismatch"
[[ -f "$result" ]] || fail "c4: runner result not written"
python3 - "$result" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema"] == "singular.orchestration.runner-result.v0", data
assert data["provider"] == "openrouter", data
assert data["role"] == "implementer", data
assert data["outcome"] == "succeeded", data
PY
pass "c4 session meta and runner result are recorded as provider openrouter"

# --- Case 5: the contract probe, and its own env family -------------------------
contract="$("$RUN" --describe-contract)"
python3 - "$contract" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["schema"] == "singular.runner-contract.v1", doc
assert doc["provider"] == "openrouter", doc
for arg in ("--worktree", "--prompt-file", "--session-meta", "--resume-session",
            "--role", "--capability-profile", "--result-file"):
    assert arg in doc["arguments"], arg
PY
r="$workroot/c5"; new_repo "$r"; o="$(out)"; args="$workroot/c5.args"
MOCK_ARGS_OUT="$args" SINGULAR_OPENROUTER_MODEL="$MODEL" \
  SINGULAR_OPENROUTER_EXTRA_ARGS="--print-logs" \
  run_openrouter "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1 || true
grep -q -- "--print-logs" "$args" \
  || fail "c5: SINGULAR_OPENROUTER_EXTRA_ARGS not honored (got: $(cat "$args"))"
pass "c5 contract v1 advertised as openrouter; SINGULAR_OPENROUTER_* env family honored"

# --- Case 6: read-only maps to the host's read-only agent -----------------------
r="$workroot/c6"; new_repo "$r"; o="$(out)"; args="$workroot/c6.args"
MOCK_ARGS_OUT="$args" SINGULAR_OPENROUTER_MODEL="$MODEL" \
  run_openrouter "$r" --level readonly -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" >/dev/null 2>&1 || true
grep -q -- "--agent plan" "$args" \
  || fail "c6: readonly should select the read-only agent (got: $(cat "$args"))"
args="$workroot/c6b.args"
MOCK_ARGS_OUT="$args" SINGULAR_OPENROUTER_MODEL="$MODEL" \
  run_openrouter "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$(out)" >/dev/null 2>&1 || true
grep -q -- "--agent" "$args" && fail "c6b: l2 must not select the read-only agent"
pass "c6 readonly -> --agent plan; l2 unconstrained"

# --- Case 7: resume is refused with the fresh-run fallback code -----------------
r="$workroot/c7"; new_repo "$r"; o="$(out)"; args="$workroot/c7.args"; ec=0
MOCK_ARGS_OUT="$args" SINGULAR_OPENROUTER_MODEL="$MODEL" \
  run_openrouter "$r" --level l2 -C "$r" --prompt-file "$(prompt)" \
  --output-last-message "$o" --resume-session "sess-x" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 86 ]] || fail "c7: --resume-session should exit 86 (got $ec)"
[[ ! -f "$args" ]] || fail "c7: resume refusal must not invoke the provider"
pass "c7 --resume-session -> exit 86 (refused, no model run)"

echo "ALL OPENROUTER-RUN CONTRACT TESTS PASSED"
