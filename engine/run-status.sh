#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  run-status.sh write --run-id ID --phase PHASE --state STATE
    --activity TEXT --safe-cancel true|false --next-action TEXT
    [--task-id TASK-NNNN] [--node NODE] [--process-type TYPE]
    [--pid PID] [--pgid PGID] [--outcome TEXT]
  run-status.sh show --run-id ID
EOF
  exit 2
}

cmd="${1:-}"
shift || true
case "$cmd" in write|show) ;; *) usage ;; esac

run_id=""
task_id=""
node=""
phase=""
state=""
activity=""
safe_cancel=""
next_action=""
process_type=""
pid=""
pgid=""
outcome=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) run_id="${2:-}"; shift 2 ;;
    --task-id) task_id="${2:-}"; shift 2 ;;
    --node) node="${2:-}"; shift 2 ;;
    --phase) phase="${2:-}"; shift 2 ;;
    --state) state="${2:-}"; shift 2 ;;
    --activity) activity="${2:-}"; shift 2 ;;
    --safe-cancel) safe_cancel="${2:-}"; shift 2 ;;
    --next-action) next_action="${2:-}"; shift 2 ;;
    --process-type) process_type="${2:-}"; shift 2 ;;
    --pid) pid="${2:-}"; shift 2 ;;
    --pgid) pgid="${2:-}"; shift 2 ;;
    --outcome) outcome="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$run_id" && "$run_id" != */* && "$run_id" != "." && "$run_id" != ".." ]] || usage
path="$GLUERUN_RUNS_DIR/$run_id/run-status.json"
if [[ "$cmd" == "show" ]]; then
  [[ -f "$path" ]] || exit 1
  exec cat "$path"
fi

case "$phase" in
  planning|implementing|gating|auditing|deciding|integrating|awaiting-human|terminal) ;;
  *) echo "run-status: invalid phase: $phase" >&2; exit 2 ;;
esac
case "$state" in
  active|waiting|completed|failed|stale|cancelled) ;;
  *) echo "run-status: invalid state: $state" >&2; exit 2 ;;
esac
case "$safe_cancel" in true|false) ;; *) echo "run-status: --safe-cancel must be true or false" >&2; exit 2 ;; esac
[[ -n "$activity" && -n "$next_action" ]] || usage
[[ -z "$pid" || "$pid" =~ ^[1-9][0-9]*$ ]] || usage
[[ -z "$pgid" || "$pgid" =~ ^[1-9][0-9]*$ ]] || usage

mkdir -p "$(dirname "$path")"
tmp="$path.tmp.$$"
now="${GLUERUN_NOW:-$(gluerun_timestamp)}"
python3 - "$path" "$tmp" "$run_id" "$task_id" "$node" "$phase" "$state" \
  "$activity" "$safe_cancel" "$next_action" "$process_type" "$pid" "$pgid" \
  "$outcome" "$now" <<'PY'
import json
import pathlib
import sys

(old_raw, out_raw, run_id, task_id, node, phase, state, activity,
 safe_cancel, next_action, process_type, pid, pgid, outcome, now) = sys.argv[1:16]
old_path = pathlib.Path(old_raw)
try:
    old = json.loads(old_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    old = {}

same_phase = old.get("phase") == phase
record = {
    "schema": "gluerun.orchestration.run-status.v0",
    "runId": run_id,
    "phase": phase,
    "state": state,
    "phaseStartedAt": old.get("phaseStartedAt") if same_phase else now,
    "lastProgressAt": now,
    "currentActivity": activity,
    "safeCancel": safe_cancel == "true",
    "nextAction": next_action,
    "updatedAt": now,
}
if task_id:
    record["taskId"] = task_id
elif old.get("taskId"):
    record["taskId"] = old["taskId"]
if node:
    record["node"] = node
elif old.get("node"):
    record["node"] = old["node"]
if outcome:
    record["outcome"] = outcome
if phase == "terminal" or state in {"completed", "failed", "cancelled"}:
    record["phaseFinishedAt"] = now
if process_type and pid:
    process = {
        "type": process_type,
        "pid": int(pid),
        "startedAt": (
            old.get("process", {}).get("startedAt")
            if same_phase and old.get("process", {}).get("pid") == int(pid)
            else now
        ),
    }
    if pgid:
        process["pgid"] = int(pgid)
    record["process"] = process
elif same_phase and isinstance(old.get("process"), dict):
    record["process"] = old["process"]

pathlib.Path(out_raw).write_text(
    json.dumps(record, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
mv "$tmp" "$path"
printf '%s\n' "$path"
