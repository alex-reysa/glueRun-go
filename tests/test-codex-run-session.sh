#!/usr/bin/env bash
set -euo pipefail

# Deterministic contract tests for codex-run.sh session affinity (T-E5). A mock
# `codex` on PATH stands in for the real CLI (offline, free, CI-safe), emitting
# JSONL on stdout that includes a session-id event, and honoring -o by writing
# the final message there (as the real codex does). These assert:
#   (a) default invocation (no --session-meta) is byte-identical to HEAD behavior
#       — no tee artifacts, no session-meta written;
#   (b) with --session-meta: the session id is parsed from the JSONL, the meta is
#       written, and PIPESTATUS exit propagation is correct (mock exit code wins);
#   (c) --resume-session puts `exec resume <id>` in the recorded codex argv;
#   (d) model/effort mismatch vs an existing meta -> exit 86 (resume-refused),
#       and the model is NOT invoked.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
CODEX_RUN="$SCRIPT_DIR/codex-run.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/gluerun-codex-test.XXXXXX")"
bindir="$workroot/bin"
mkdir -p "$bindir"
cleanup() { rm -rf "$workroot"; }
trap cleanup EXIT

# --- Mock codex ----------------------------------------------------------------
# Records argv to MOCK_ARGS_OUT, consumes stdin, emits JSONL (one of the lines is
# a session-id event), writes the final message to the file named after -o, and
# exits with MOCK_EXIT (default 0). MOCK_SESSION_ID defaults to a fixed id; set it
# empty to simulate a parse miss. MOCK_RESULT controls the written last-message.
cat >"$bindir/codex" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${MOCK_ARGS_OUT:-}" ]] && printf '%s\n' "$*" > "$MOCK_ARGS_OUT"
cat >/dev/null 2>&1 || true   # consume the piped prompt

# Find the -o/--output-last-message target in argv (codex writes the final msg there).
out_file=""
prev=""
for a in "$@"; do
  case "$prev" in
    -o|--output-last-message) out_file="$a" ;;
  esac
  prev="$a"
done

sid="${MOCK_SESSION_ID-mock-codex-session-123}"
# Emit JSONL events. MOCK_SHAPE=thread reproduces the REAL current codex CLI
# (`{"type":"thread.started","thread_id":"<uuid>"}`); the default synthetic shape
# carries the id under .msg.session_id to also exercise the defensive nested scan.
if [[ "${MOCK_SHAPE:-msg}" == "thread" ]]; then
  if [[ -n "$sid" ]]; then
    printf '{"type":"thread.started","thread_id":"%s"}\n' "$sid"
  else
    printf '%s\n' '{"type":"thread.started"}'
  fi
else
  printf '%s\n' '{"type":"thread.started"}'
  if [[ -n "$sid" ]]; then
    printf '{"type":"session.created","msg":{"session_id":"%s"}}\n' "$sid"
  fi
fi
printf '%s\n' '{"type":"item.completed"}'

result="${MOCK_RESULT:-}"
[[ -z "$result" ]] && result='{"verdict":"accepted"}'
if [[ -n "$out_file" ]]; then
  printf '%s\n' "$result" > "$out_file"
fi
exit "${MOCK_EXIT:-0}"
MOCK
chmod +x "$bindir/codex"

export PATH="$bindir:$PATH"
export GLUERUN_TARGET_BRANCH="test-target"

new_repo() {
  local d="$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && printf '.gluerun-state/\n' > .gitignore && git add .gitignore && git commit -qm init \
      && git branch "$GLUERUN_TARGET_BRANCH" )
}

run_codex_run() {
  local repo="$1"; shift
  ( cd "$repo" && GLUERUN_ROOT="$repo" GLUERUN_STATE_DIR="$repo/.gluerun-state" "$CODEX_RUN" "$@" )
}

field() { # read a top-level field from a JSON file
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"
}

i=0; out() { i=$((i+1)); echo "$workroot/out-$i.json"; }

# --- Case a: default invocation (no --session-meta) — no meta, no tee artifacts -
r="$workroot/a"; new_repo "$r"; o="$(out)"; args="$workroot/a.args"
MOCK_RESULT='{"status":"needs-review"}' MOCK_ARGS_OUT="$args" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" >/dev/null 2>&1
[[ -f "$o" ]] || fail "a: output not written"
[[ "$(field "$o" status)" == "needs-review" ]] || fail "a: status not captured"
# The fresh argv must be the HEAD form: `exec` immediately (no `resume`), `--json`.
grep -q -- "exec -m " "$args" || fail "a: default argv not in HEAD `exec -m` form (got: $(cat "$args"))"
grep -q -- "resume" "$args" && fail "a: default argv unexpectedly contains 'resume'"
# No stray tee artifact under the workroot.
[[ -z "$(find "$workroot" -name 'gluerun-codex-jsonl.*' 2>/dev/null)" ]] || fail "a: tee artifact leaked"
pass "a default invocation byte-identical: no resume, no meta, no tee artifact"

# --- Case b: --session-meta parses the session id + PIPESTATUS exit propagation -
r="$workroot/b"; new_repo "$r"; o="$(out)"; meta="$workroot/b-meta.json"
MOCK_RESULT='{"status":"x"}' MOCK_SESSION_ID="mock-codex-session-123" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1
[[ -f "$meta" ]] || fail "b: session-meta not written"
[[ "$(field "$meta" sessionId)" == "mock-codex-session-123" ]] || fail "b: sessionId not parsed (got: $(field "$meta" sessionId))"
[[ "$(field "$meta" provider)" == "codex" ]] || fail "b: provider not codex"

# PIPESTATUS: mock exit code (not tee's) must win.
r="$workroot/b2"; new_repo "$r"; o="$(out)"; meta="$workroot/b2-meta.json"; ec=0
MOCK_RESULT='{"status":"x"}' MOCK_EXIT=7 \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 7 ]] || fail "b2: PIPESTATUS exit propagation wrong (want 7 got $ec)"
pass "b --session-meta parses session id + PIPESTATUS propagates the model's rc"

# --- Case b3: parse miss (empty session id) -> empty sessionId in meta ----------
r="$workroot/b3"; new_repo "$r"; o="$(out)"; meta="$workroot/b3-meta.json"
MOCK_RESULT='{"status":"x"}' MOCK_SESSION_ID="" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1
[[ -f "$meta" ]] || fail "b3: meta not written on parse miss"
[[ -z "$(field "$meta" sessionId)" ]] || fail "b3: sessionId should be empty on parse miss (got: $(field "$meta" sessionId))"
pass "b3 parse miss -> empty sessionId (caller goes fresh)"

# --- Case b4: REAL codex shape — thread.started/thread_id is parsed -------------
# Locks the production key confirmed by the live smoke test (codex emits the
# resumable id as thread_id on a thread.started event, not session_id).
r="$workroot/b4"; new_repo "$r"; o="$(out)"; meta="$workroot/b4-meta.json"
MOCK_RESULT='{"status":"x"}' MOCK_SHAPE="thread" MOCK_SESSION_ID="019eae91-2e20-71c1-9f8a-c30d1f7e851e" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" --session-meta "$meta" >/dev/null 2>&1
[[ "$(field "$meta" sessionId)" == "019eae91-2e20-71c1-9f8a-c30d1f7e851e" ]] \
  || fail "b4: thread_id from thread.started not parsed (got: $(field "$meta" sessionId))"
pass "b4 real codex thread.started/thread_id is captured as the session id"

# --- Case c: --resume-session puts `exec resume <id>` in the codex argv ---------
r="$workroot/c"; new_repo "$r"; o="$(out)"; args="$workroot/c.args"; meta="$workroot/c-meta.json"
# No prior meta file -> no refusal; just verify the resume argv form.
MOCK_RESULT='{"status":"x"}' MOCK_SESSION_ID="s" MOCK_ARGS_OUT="$args" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" \
  --session-meta "$meta" --resume-session "resume-xyz" >/dev/null 2>&1
grep -q -- "exec resume resume-xyz" "$args" || fail "c: 'exec resume <id>' not in argv (got: $(cat "$args"))"
grep -q -- "--json" "$args" || fail "c: --json missing in resume argv"
pass "c --resume-session yields 'exec resume <id>' in the codex argv"

# --- Case d: model mismatch vs existing meta -> exit 86, model NOT invoked ------
r="$workroot/d"; new_repo "$r"; o="$(out)"; args="$workroot/d.args"; ec=0
meta="$workroot/d-meta.json"
cat >"$meta" <<JSON
{"schema":"gluerun.orchestration.session-meta.v0","provider":"codex","sessionId":"s","model":"gpt-OTHER","effort":"medium","cwd":"$r","exitCode":0,"createdAt":"2026-01-01T00:00:00Z"}
JSON
MOCK_RESULT='{"status":"x"}' MOCK_ARGS_OUT="$args" \
  run_codex_run "$r" --level l2 -C "$r" --output-last-message "$o" \
  --session-meta "$meta" --resume-session "s" >/dev/null 2>&1 || ec=$?
[[ "$ec" -eq 86 ]] || fail "d: model mismatch should exit 86 (got $ec)"
[[ ! -f "$args" ]] || fail "d: codex should not have been invoked on refusal"
pass "d model mismatch -> exit 86 (resume-refused, model not invoked)"

echo "ALL CODEX-RUN SESSION CONTRACT TESTS PASSED"
