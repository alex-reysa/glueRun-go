#!/usr/bin/env bash
set -euo pipefail

# 0.10.0: ask.sh answers one operator question with a read-only runner pass over
# the shared digest. The question is read from question.md and rendered into
# ask-prompt.md — it NEVER transits a runner argv (proven below by dumping argv).
# ask.json advances pending -> running -> done|timeout; a trailing fenced
# ```json proposedSettings block in the answer is parsed into ask.json. The run
# dir is a session dir (ask-prompt.md / assistant-codex.log /
# session-assistant.json / answer-raw.json / answer.md / question.md / ask.json).

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ask.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/prompts" "$root/docs/orchestration/tasks" \
  "$root/docs/orchestration/gates" "$root/.gluerun-state/leases" \
  "$root/.gluerun-state/runs" "$root/.gluerun-state/inbox" "$root/.worktrees"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/supervisor-ask.md" "$root/docs/orchestration/prompts/supervisor-ask.md"
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{"schema":"gluerun.orchestration.dag.v0","layers":["scaffold"],"kinds":["build"],
 "nodes":[{"id":"M0.core","stage":"M0","area":"core","layer":"scaffold","kind":"build","dependsOn":[],"requiredCompletion":"scaffold_complete"}]}
EOF
printf '# gluerun Autonomous Status\n\nIteration: 5\n' >"$root/.gluerun-state/STATUS.md"
git -C "$root" add .
git -C "$root" -c user.name=t -c user.email=t@t commit -q -m init

SECRET="QZXSECRET42TOKEN"   # a distinctive marker we track through the pipeline

# Runner stub: records its full argv (to prove the question is never passed), then
# emits a prose answer with a trailing fenced proposedSettings block (or sleeps to
# exercise the watchdog timeout).
stub="$root/runner.sh"
cat >"$stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$ARGV_DUMP"
out="" meta=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) out="$2"; shift 2 ;;
    --session-meta) meta="$2"; shift 2 ;;
    --level|-C|--run-id|--prompt-file|--resume-session) shift 2 ;;
    *) shift ;;
  esac
done
echo "assistant runner chatter"
[[ -n "$meta" ]] && printf '{"schema":"gluerun.orchestration.session-meta.v0","provider":"fake","model":"fake-1","effort":"low","exitCode":0}\n' >"$meta"
case "${STUB_MODE:-answer}" in
  answer)
    cat >"$out" <<'ANS'
The loop is healthy and making progress on the core area.

```json
{"proposedSettings": {"GLUERUN_MAX_CONCURRENT": "4"}}
```
ANS
    ;;
  sleep) sleep 30 ;;
esac
SH
chmod +x "$stub"

run_env() {
  env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
    GLUERUN_ORCH_DIR="$root/docs/orchestration" GLUERUN_TASKS_DIR="$root/docs/orchestration/tasks" \
    GLUERUN_LEASES_DIR="$root/.gluerun-state/leases" GLUERUN_RUNS_DIR="$root/.gluerun-state/runs" \
    GLUERUN_INBOX_DIR="$root/.gluerun-state/inbox" GLUERUN_WORKTREES_DIR="$root/.worktrees" \
    GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson" GLUERUN_TARGET_BRANCH=target \
    GLUERUN_RUNNER="$stub" ARGV_DUMP="$root/argv.dump" "$@"
}

# --- 1. direct ask.sh: staged question -> answered + parsed proposal --------
ask_id="ASK-test-one"
mkdir -p "$root/.gluerun-state/runs/$ask_id"
printf '%s\n' "what is the status $SECRET" >"$root/.gluerun-state/runs/$ask_id/question.md"
out="$(run_env bash "$SCRIPT_DIR/ask.sh" --run-id "$ask_id" 2>&1)"
assert_contains "$out" "state=done" "answered"
run_dir="$root/.gluerun-state/runs/$ask_id"

[[ -f "$run_dir/answer.md" ]] || fail "answer.md missing"
[[ -f "$run_dir/answer-raw.json" ]] || fail "answer-raw.json missing"
[[ -f "$run_dir/ask-prompt.md" ]] || fail "ask-prompt.md missing"
[[ -f "$run_dir/assistant-codex.log" ]] || fail "assistant-codex.log missing"
[[ -f "$run_dir/session-assistant.json" ]] || fail "session-assistant.json missing"
grep -q "healthy and making progress" "$run_dir/answer.md" || fail "answer.md content"
grep -q "assistant runner chatter" "$run_dir/assistant-codex.log" || fail "runner log not captured"

python3 - "$run_dir/ask.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["state"] == "done", d
assert d["proposedSettings"] == {"GLUERUN_MAX_CONCURRENT": "4"}, d
assert d["runId"] == "ASK-test-one", d
assert d.get("answeredAt"), d
PY
python3 - "$run_dir/session-assistant.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["role"] == "assistant", d
assert d["runId"] == "ASK-test-one", d
PY

# The question IS in the rendered prompt file...
grep -q "$SECRET" "$run_dir/ask-prompt.md" || fail "question must be rendered into ask-prompt.md"
# ...and is NEVER in a runner argv.
grep -q "$SECRET" "$root/argv.dump" && fail "question text leaked into runner argv"

evts="$(cat "$root/.gluerun-state/events.ndjson")"
assert_contains "$evts" '"type":"supervisor.ask_started"' "ask_started event"
assert_contains "$evts" '"type":"supervisor.ask_answered"' "ask_answered event"

# --- 2. timeout: sleeping stub + short budget -> state timeout --------------
ask_id2="ASK-test-two"
mkdir -p "$root/.gluerun-state/runs/$ask_id2"
printf '%s\n' "slow question" >"$root/.gluerun-state/runs/$ask_id2/question.md"
out="$(run_env STUB_MODE=sleep GLUERUN_ASK_TIMEOUT_SEC=2 bash "$SCRIPT_DIR/ask.sh" --run-id "$ask_id2" 2>&1)"
assert_contains "$out" "state=timeout" "timeout state"
python3 - "$root/.gluerun-state/runs/$ask_id2/ask.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["state"] == "timeout"
PY
assert_contains "$(cat "$root/.gluerun-state/events.ndjson")" '"reason":"timeout"' "ask timeout event"

# --- 3. bad run-id rejected --------------------------------------------------
rc=0
run_env bash "$SCRIPT_DIR/ask.sh" --run-id "NOTASK-1" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "invalid run-id must be rejected (rc=$rc)"

# --- 4. ops.sh ask --wait mints an id and completes -------------------------
out="$(run_env bash "$SCRIPT_DIR/ops.sh" ask "where are we $SECRET" --wait 2>&1)"
assert_contains "$out" "runId=ASK-" "ops ask prints a runId"
ops_id="$(sed -n 's/^runId=//p' <<<"$out" | tail -1)"
[[ -d "$root/.gluerun-state/runs/$ops_id" ]] || fail "ops ask did not create the run dir"
python3 - "$root/.gluerun-state/runs/$ops_id/ask.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["state"] == "done"
PY
grep -q "$SECRET" "$root/argv.dump" && fail "ops-ask question leaked into runner argv"

echo "PASS: test-ask"
