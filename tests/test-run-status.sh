#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$tmp" init -q repo

env_base=(
  GLUERUN_ROOT="$repo"
  GLUERUN_STATE_DIR="$repo/.gluerun-state"
  GLUERUN_RUNS_DIR="$repo/.gluerun-state/runs"
)

env "${env_base[@]}" GLUERUN_NOW="2026-07-24T10:00:00Z" \
  "$ROOT/engine/run-status.sh" write \
  --run-id RUN-1 --task-id TASK-0001 --phase implementing --state active \
  --activity "editing owned files" --safe-cancel false --next-action "run gate" \
  --process-type worker --pid 123 --pgid 123 >/dev/null

env "${env_base[@]}" GLUERUN_NOW="2026-07-24T10:01:00Z" \
  "$ROOT/engine/run-status.sh" write \
  --run-id RUN-1 --task-id TASK-0001 --phase auditing --state active \
  --activity "verifying evidence" --safe-cancel true --next-action "record verdict" \
  --process-type auditor --pid 456 --pgid 456 >/dev/null

status="$repo/.gluerun-state/runs/RUN-1/run-status.json"
python3 - "$status" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["schema"] == "gluerun.orchestration.run-status.v0"
assert data["phase"] == "auditing"
assert data["state"] == "active"
assert data["process"]["type"] == "auditor"
assert data["process"]["pid"] == 456
assert data["phaseStartedAt"] == "2026-07-24T10:01:00Z"
assert data["lastProgressAt"] == "2026-07-24T10:01:00Z"
assert data["safeCancel"] is True
PY

if env "${env_base[@]}" "$ROOT/engine/run-status.sh" write \
  --run-id RUN-1 --phase made-up --state active --activity x \
  --safe-cancel true --next-action x >/dev/null 2>&1; then
  echo "invalid phase should fail" >&2
  exit 1
fi

echo "run status tests passed"
