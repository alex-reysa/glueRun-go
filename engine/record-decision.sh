#!/usr/bin/env bash
set -euo pipefail

# Append a structured bootstrap decision to docs/orchestration/decisions.md and
# emit an event. This is the bootstrap stand-in for first-party kernel Decision
# records (operating model section 12 / migration table).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

task_id=""
decision=""
rationale=""
run_id=""
branch=""
authority="origin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task_id="$2"; shift 2 ;;
    --decision) decision="$2"; shift 2 ;;
    --rationale) rationale="$2"; shift 2 ;;
    --run) run_id="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --authority) authority="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$task_id" || -z "$decision" ]]; then
  echo "usage: $0 --task TASK --decision accept|reject|hold|supersede [--rationale R] [--run RUN] [--branch B] [--authority A]" >&2
  exit 2
fi

decisions_file="$GLUERUN_ORCH_DIR/decisions.md"
ts="$(gluerun_timestamp)"

python3 - "$decisions_file" "$ts" "$task_id" "$decision" "$rationale" "$run_id" "$branch" "$authority" <<'PY'
import os
import sys

(path, ts, task_id, decision, rationale, run_id, branch, authority) = sys.argv[1:9]
header = "## Decision Log"
block_lines = [
    f"### {ts} — {task_id} — {decision}",
    "",
    f"- Run: `{run_id or 'n/a'}`",
    f"- Branch: `{branch or 'n/a'}`",
    f"- Authority: {authority}",
    f"- Rationale: {rationale or 'n/a'}",
    "",
]
block = "\n".join(block_lines)

text = ""
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

if header in text:
    head, rest = text.split(header, 1)
    # Insert the newest entry directly under the Decision Log header.
    rest = rest.lstrip("\n")
    new = head + header + "\n\n" + block + "\n" + rest
else:
    new = text.rstrip() + "\n\n" + header + "\n\n" + block + "\n"

with open(path, "w", encoding="utf-8") as f:
    f.write(new)
PY

gluerun_append_event "decision.recorded" "bootstrap decision recorded" \
  "{\"taskId\":\"$task_id\",\"decision\":\"$decision\",\"runId\":\"$run_id\",\"branch\":\"$branch\",\"authority\":\"$authority\"}"

echo "decision recorded: $task_id -> $decision"
