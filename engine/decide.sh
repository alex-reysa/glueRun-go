#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "decide.sh requires bash >= 4" >&2; exit 1
fi

# Autonomous Decider invocation. Given a decision point that would otherwise need
# a human, run a read-only Codex decider that returns one action from the
# recovery vocabulary. This script DECIDES + RECORDS; the CALLER executes the
# returned action. It prints `action=<x>` and `verdict=<path>` on stdout.
#
# If the decider cannot be run or returns nothing parseable, it falls back to
# `escalate-parked` (park, never spin).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Decider runner. Defaults to the codex runner; set GLUERUN_RUNNER to a drop-in
# (e.g. claude-run.sh) to dispatch a different CLI under the same contract.
GLUERUN_RUNNER_BIN="${GLUERUN_RUNNER:-$SCRIPT_DIR/codex-run.sh}"

task_id=""
failure_class=""
branch=""
run_id=""
context_file=""
worktree="$GLUERUN_ROOT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task_id="$2"; shift 2 ;;
    --failure-class) failure_class="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --run) run_id="$2"; shift 2 ;;
    --context-file) context_file="$2"; shift 2 ;;
    --worktree) worktree="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$failure_class" ]] || { echo "decide.sh: --failure-class required" >&2; exit 2; }
[[ -n "$run_id" ]] || run_id="$(gluerun_worker_run_id)"
[[ -d "$worktree" ]] || worktree="$GLUERUN_ROOT"
gluerun_ensure_state_dirs
run_dir="$(gluerun_run_dir "$run_id")"
mkdir -p "$run_dir"

retry_count="$(gluerun_lease_field "$task_id" retryCount 2>/dev/null || echo 0)"
max_retries="$(gluerun_lease_field "$task_id" maxRetries 2>/dev/null || echo "$GLUERUN_MAX_RETRIES")"
[[ -n "$retry_count" ]] || retry_count=0
[[ -n "$max_retries" ]] || max_retries="$GLUERUN_MAX_RETRIES"
[[ "$retry_count" =~ ^[0-9]+$ ]] || retry_count=0
[[ "$max_retries" =~ ^[0-9]+$ ]] || max_retries="$GLUERUN_MAX_RETRIES"
[[ "$max_retries" =~ ^[0-9]+$ ]] || max_retries=0

context_body="(none provided)"
if [[ -n "$context_file" && -f "$context_file" ]]; then
  context_body="$(tail -c 8000 "$context_file")"
fi

# Assemble the decider prompt.
prompt_file="$run_dir/decider-prompt-$failure_class.md"
python3 - "$GLUERUN_ORCH_DIR/prompts/decider.md" "$prompt_file" \
  "$task_id" "$failure_class" "$branch" "$run_id" "$retry_count" "$max_retries" "$context_body" <<'PY'
import sys
tmpl_path, out_path, task_id, fc, branch, run_id, rc, mr, ctx = sys.argv[1:10]
with open(tmpl_path, "r", encoding="utf-8") as f:
    tmpl = f.read().replace("[TASK-ID]", task_id or "(n/a)").replace("[FAILURE CLASS]", fc)
ctx_block = f"""

---

## Context for this decision (authoritative)

- taskId: {task_id or '(n/a)'}
- branch: {branch or '(n/a)'}
- runId: {run_id}
- retries used: {rc} of {mr}

### Failure / findings / logs

```
{ctx}
```

Decide now. Emit ONLY the decider-verdict JSON object.
"""
with open(out_path, "w", encoding="utf-8") as f:
    f.write(tmpl + ctx_block)
PY

verdict="$run_dir/decision-$failure_class.json"
invalid_verdict="$run_dir/decision-$failure_class.invalid.json"
action="escalate-parked"
rationale="decider unavailable; parked by fallback"
timed_out="no"
decider_timeout_sec="${GLUERUN_DECIDER_TIMEOUT_SEC:-1200}"
if ! [[ "$decider_timeout_sec" =~ ^[0-9]+$ && "$decider_timeout_sec" -gt 0 ]]; then
  decider_timeout_sec=1200
fi

gluerun_decider_kill_tree() {
  local pid="$1" child
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    gluerun_decider_kill_tree "$child"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  kill -TERM "$pid" 2>/dev/null || true
}

gluerun_decider_timeout_action() {
  if [[ "$failure_class" == "audit-needs-fix" && "$retry_count" -lt "$max_retries" ]]; then
    action="retry"
    rationale="readonly decider timed out after ${decider_timeout_sec}s; audit-needs-fix is buildable and retry budget remains (${retry_count}/${max_retries})"
  else
    action="escalate-parked"
    rationale="readonly decider timed out after ${decider_timeout_sec}s; parked by fallback"
  fi
}

decider_event_data() {
  python3 - "$task_id" "$run_id" "$failure_class" "$action" "${1:-}" <<'PY'
import json
import sys
task_id, run_id, failure_class, action, reason = sys.argv[1:6]
data = {"taskId": task_id, "runId": run_id, "failureClass": failure_class, "action": action}
if reason:
    data["reason"] = reason[:500]
print(json.dumps(data, separators=(",", ":")))
PY
}

run_ec=0
# Decider runner output + session-meta are durable (0.6.0): the console
# streams the log as a labeled pane; previously both went to /dev/null.
decider_log="$run_dir/decider-codex.log"
decider_meta="$run_dir/session-decider.json"
(
  "$GLUERUN_RUNNER_BIN" --level readonly -C "$worktree" \
    --run-id "$run_id" \
    --prompt-file "$prompt_file" \
    --output-last-message "$verdict" \
    --session-meta "$decider_meta"
) >>"$decider_log" 2>&1 &
decider_pid=$!
deadline=$((SECONDS + decider_timeout_sec))
while kill -0 "$decider_pid" 2>/dev/null; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    timed_out="yes"
    gluerun_decider_kill_tree "$decider_pid"
    wait "$decider_pid" 2>/dev/null || true
    run_ec=124
    break
  fi
  sleep 1
done
if [[ "$timed_out" != "yes" ]]; then
  wait "$decider_pid" || run_ec=$?
fi
gluerun_session_meta_finalize "$decider_meta" "decider" "$task_id" "$run_id" \
  "$(basename "$GLUERUN_RUNNER_BIN")" "$(gluerun_prompt_sha "$prompt_file")" "" 1 || true

if [[ "$timed_out" == "yes" ]]; then
  gluerun_decider_timeout_action
  owner="human"; [[ "$action" == "retry" ]] && owner="l1"
  gluerun_write_decider_verdict "$verdict" "$task_id" "$failure_class" "$action" "$rationale" "$owner"
  gluerun_append_event "decider.timeout" "readonly decider timed out" \
    "$(python3 - "$task_id" "$run_id" "$failure_class" "$action" "$decider_timeout_sec" <<'PY'
import json, sys
task_id, run_id, failure_class, action, timeout_sec = sys.argv[1:6]
print(json.dumps({"taskId": task_id, "runId": run_id, "failureClass": failure_class, "timeoutSec": int(timeout_sec), "action": action}, separators=(",", ":")))
PY
)"
elif [[ -f "$verdict" ]] && gluerun_extract_json "$verdict" "$verdict" 2>/dev/null; then
  validation_log="$run_dir/decision-$failure_class.validation.log"
  if gluerun_validate_decider_verdict "$verdict" "$failure_class" "$task_id" >"$validation_log" 2>&1; then
    a="$(gluerun_json_field "$verdict" action 2>/dev/null || echo "")"
    r="$(gluerun_json_field "$verdict" rationale 2>/dev/null || echo "")"
    if [[ -n "$a" ]]; then action="$a"; fi
    if [[ -n "$r" ]]; then rationale="$r"; fi
  else
    cp "$verdict" "$invalid_verdict" 2>/dev/null || true
    invalid_reason="$(cat "$validation_log" 2>/dev/null || echo "schema validation failed")"
    action="escalate-parked"
    rationale="invalid decider verdict; parked by fallback: $invalid_reason"
    gluerun_write_decider_verdict "$verdict" "$task_id" "$failure_class" "$action" "$rationale" "human"
    gluerun_append_event "decider.invalid_verdict" "decider verdict failed validation; using fallback" \
      "$(decider_event_data "$invalid_reason")"
  fi
else
  # Decider produced no parseable JSON action (prose-only, refusal, or truncated).
  # Falls back to the escalate-parked default, but record WHY so a prose stall is
  # visible rather than indistinguishable from a deliberate human-park decision.
  [[ -f "$verdict" ]] && cp "$verdict" "$invalid_verdict" 2>/dev/null || true
  gluerun_write_decider_verdict "$verdict" "$task_id" "$failure_class" "$action" "$rationale" "human"
  gluerun_append_event "decider.unparseable" "decider produced no parseable JSON action; using fallback" \
    "$(decider_event_data "unparseable")"
fi

# Record the decision durably.
"$SCRIPT_DIR/record-decision.sh" --task "${task_id:-UNKNOWN}" --decision "decide:$action" \
  --rationale "$failure_class -> $action: $rationale" --run "$run_id" --branch "$branch" \
  --authority decider >/dev/null 2>&1 || true

if [[ "$action" == "escalate-parked" ]]; then
  gluerun_append_event "decider.parked" "decision parked for human review" \
    "$(decider_event_data "$rationale")"
else
  gluerun_append_event "decider.verdict" "decider chose an action" \
    "$(decider_event_data)"
fi

echo "verdict=$verdict"
echo "action=$action"
