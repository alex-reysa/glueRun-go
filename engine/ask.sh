#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "ask.sh requires bash >= 4" >&2; exit 1
fi

# Supervisor ask (0.10.0). Answer one operator question with a read-only runner
# pass over the shared situational digest. Read-only: NEVER edits code, git,
# tasks, leases, or settings. The model MAY *propose* whitelisted settings in a
# trailing fenced JSON block; the human applies them by hand (POST /api/settings).
#
# The question is read from question.md and rendered into ask-prompt.md — it NEVER
# transits a runner argv. ask.json advances pending -> running(pid) -> done |
# error | timeout so the console can poll it.
#
# Run dir is shaped like a normal session dir so the console discovers it:
#   runs/ASK-<utc>-<token>/{question.md, ask-prompt.md, assistant-codex.log,
#                           session-assistant.json, answer-raw.json, answer.md,
#                           ask.json}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

GLUERUN_RUNNER_BIN="${GLUERUN_RUNNER:-$SCRIPT_DIR/codex-run.sh}"

run_id=""
question_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) run_id="$2"; shift 2 ;;
    --question) question_arg="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$run_id" ]] || { echo "ask.sh: --run-id required" >&2; exit 2; }
[[ "$run_id" =~ ^ASK-[A-Za-z0-9-]+$ ]] || { echo "ask.sh: invalid --run-id: $run_id" >&2; exit 2; }

timeout_sec="${GLUERUN_ASK_TIMEOUT_SEC:-600}"
[[ "$timeout_sec" =~ ^[0-9]+$ && "$timeout_sec" -gt 0 ]] || timeout_sec=600

gluerun_ensure_state_dirs
run_dir="$(gluerun_run_dir "$run_id")"
mkdir -p "$run_dir"

q_file="$run_dir/question.md"
ask_json="$run_dir/ask.json"

# --question is a direct-invocation convenience: write question.md only if the
# caller (ops_ask / the server) has not already staged it. The staged file is
# always authoritative.
if [[ -n "$question_arg" && ! -f "$q_file" ]]; then
  python3 - "$q_file" "$question_arg" <<'PY'
import os, sys
path, q = sys.argv[1], sys.argv[2]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(q)
os.replace(tmp, path)
PY
fi
[[ -f "$q_file" ]] || { echo "ask.sh: no question staged (missing question.md, no --question)" >&2; exit 2; }

# Atomic ask.json state writer: merges the requested state (and optional pid)
# into the existing doc, refreshing timestamps. Terminal states get answeredAt.
ask_write() {
  local state="$1" pid="${2:-}"
  python3 - "$ask_json" "$run_id" "$q_file" "$state" "$pid" <<'PY'
import json, os, sys
from datetime import datetime, timezone
ask_path, run_id, q_file, state, pid = sys.argv[1:6]
doc = {}
try:
    with open(ask_path, "r", encoding="utf-8") as f:
        loaded = json.load(f)
    if isinstance(loaded, dict):
        doc = loaded
except Exception:
    doc = {}
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
doc.setdefault("schema", "gluerun.orchestration.ask.v0")
doc["runId"] = run_id
doc.setdefault("createdAt", now)
try:
    with open(q_file, "r", encoding="utf-8") as f:
        doc["question"] = f.read().strip()[:280]
except Exception:
    doc.setdefault("question", "")
doc["state"] = state
if pid:
    try:
        doc["pid"] = int(pid)
    except ValueError:
        pass
doc["updatedAt"] = now
if state in ("done", "error", "timeout"):
    doc["answeredAt"] = now
tmp = ask_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
os.replace(tmp, ask_path)
PY
}

ask_event() {
  local type="$1" message="$2" reason="${3:-}"
  gluerun_append_event "$type" "$message" \
    "$(python3 - "$run_id" "$reason" <<'PY'
import json, sys
run_id, reason = sys.argv[1:3]
data = {"runId": run_id}
if reason:
    data["reason"] = reason
print(json.dumps(data, separators=(",", ":")))
PY
)"
}

# pending -> (render) -> running(pid) -> spawn.
ask_write pending

digest_file="$run_dir/digest.txt"
gluerun_supervisor_digest "$digest_file"

tmpl="$GLUERUN_ORCH_DIR/prompts/supervisor-ask.md"
[[ -f "$tmpl" ]] || tmpl="$GLUERUN_ENGINE_HOME/templates/prompts/supervisor-ask.md"
if [[ ! -f "$tmpl" ]]; then
  ask_write error
  ask_event "supervisor.ask_failed" "supervisor ask template not found" "no-template"
  echo "runId=$run_id"; echo "state=error"; exit 0
fi

prompt_file="$run_dir/ask-prompt.md"
gluerun_render_supervisor_prompt "$tmpl" "$digest_file" "$prompt_file" "$q_file"

raw="$run_dir/answer-raw.json"
answer_md="$run_dir/answer.md"
log="$run_dir/assistant-codex.log"
meta="$run_dir/session-assistant.json"

# Mark running under THIS process's pid (a crashed ask.sh leaves state=running
# with a dead pid, which the console converts to error after a staleness window).
ask_write running "$$"
ask_event "supervisor.ask_started" "supervisor ask started"

timed_out="no"
(
  "$GLUERUN_RUNNER_BIN" --level readonly -C "$GLUERUN_ROOT" \
    --run-id "$run_id" \
    --prompt-file "$prompt_file" \
    --output-last-message "$raw" \
    --session-meta "$meta"
) >>"$log" 2>&1 &
runner_pid=$!
deadline=$((SECONDS + timeout_sec))
while kill -0 "$runner_pid" 2>/dev/null; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    timed_out="yes"
    gluerun_kill_tree "$runner_pid"
    wait "$runner_pid" 2>/dev/null || true
    break
  fi
  sleep 1
done
if [[ "$timed_out" != "yes" ]]; then
  wait "$runner_pid" || true
fi

gluerun_session_meta_finalize "$meta" "assistant" "" "$run_id" \
  "$(basename "$GLUERUN_RUNNER_BIN")" "$(gluerun_prompt_sha "$prompt_file")" "" 1 || true

state="error"
if [[ "$timed_out" == "yes" ]]; then
  ask_write timeout
  ask_event "supervisor.ask_failed" "supervisor ask timed out after ${timeout_sec}s" "timeout"
  state="timeout"
elif [[ -s "$raw" ]]; then
  # Non-empty answer: persist answer.md (the prose), parse the LAST fenced
  # ```json proposedSettings block, and write ask.json done with the proposal.
  proposed_count="$(python3 - "$raw" "$answer_md" "$ask_json" "$run_id" "$q_file" <<'PY'
import json, os, re, sys
from datetime import datetime, timezone
raw_path, answer_md, ask_path, run_id, q_file = sys.argv[1:6]
try:
    with open(raw_path, "r", encoding="utf-8") as f:
        text = f.read()
except Exception:
    text = ""
with open(answer_md, "w", encoding="utf-8") as f:
    f.write(text)
proposed = {}
for block in reversed(re.findall(r"```json\s*(.*?)```", text, re.DOTALL | re.IGNORECASE)):
    try:
        obj = json.loads(block.strip())
    except Exception:
        continue
    ps = obj.get("proposedSettings") if isinstance(obj, dict) else None
    if isinstance(ps, dict):
        proposed = {str(k): str(v) for k, v in ps.items()}
        break
doc = {}
try:
    with open(ask_path, "r", encoding="utf-8") as f:
        loaded = json.load(f)
    if isinstance(loaded, dict):
        doc = loaded
except Exception:
    doc = {}
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
doc.setdefault("schema", "gluerun.orchestration.ask.v0")
doc["runId"] = run_id
doc.setdefault("createdAt", now)
try:
    with open(q_file, "r", encoding="utf-8") as f:
        doc["question"] = f.read().strip()[:280]
except Exception:
    doc.setdefault("question", "")
doc["state"] = "done"
doc["updatedAt"] = now
doc["answeredAt"] = now
doc["proposedSettings"] = proposed
tmp = ask_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
os.replace(tmp, ask_path)
sys.stdout.write(str(len(proposed)))
PY
)"
  ask_event "supervisor.ask_answered" "supervisor ask answered (${proposed_count} proposed setting(s))"
  state="done"
else
  ask_write error
  ask_event "supervisor.ask_failed" "supervisor ask produced no answer" "no-answer"
  state="error"
fi

echo "runId=$run_id"
echo "state=$state"
