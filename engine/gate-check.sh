#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

run_id="${1:-RUN-$(date -u +%Y%m%dT%H%M%SZ)}"
shift || true

if [[ $# -gt 0 && "${1:-}" == "--" ]]; then
  shift
fi

if [[ $# -eq 0 ]]; then
  set -- make check
fi

run_dir="$GLUERUN_STATE_DIR/runs/$run_id"
mkdir -p "$run_dir"
log="$run_dir/gate-check.log"
summary="$run_dir/gate-check.json"

set +e
"$@" >"$log" 2>&1
exit_code=$?
set -e

python3 - "$summary" "$run_id" "$exit_code" "$log" "$*" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, run_id, exit_code, log_ref, cmd = sys.argv[1:6]
data = {
    "runId": run_id,
    "cmd": cmd,
    "exitCode": int(exit_code),
    "logRef": log_ref,
    "createdAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

gluerun_append_event "gate_check.completed" "gate check completed" "{\"runId\":\"$run_id\",\"exitCode\":$exit_code,\"logRef\":\"$log\"}"
echo "gate check exit_code=$exit_code log=$log"
exit "$exit_code"
