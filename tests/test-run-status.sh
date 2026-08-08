#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/.gluerun-state" "$repo/docs/orchestration/tasks"
git -C "$tmp" init -q repo
printf '%s\n' '{"schema":"gluerun.orchestration.dag.v0","nodes":[{"id":"health-fixture","stage":"S0","area":"test","layer":"test","kind":"contract","dependsOn":[],"requiredCompletion":"done"}]}' \
  >"$repo/docs/orchestration/dag.v0.json"

env_base=(
  GLUERUN_ROOT="$repo"
  GLUERUN_STATE_DIR="$repo/.gluerun-state"
  GLUERUN_RUNS_DIR="$repo/.gluerun-state/runs"
  GLUERUN_ORCH_DIR="$repo/docs/orchestration"
  GLUERUN_TASKS_DIR="$repo/docs/orchestration/tasks"
  GLUERUN_EVENTS_FILE="$repo/.gluerun-state/events.ndjson"
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

# Health reports PID liveness as alive/dead/unknown. The compatibility `alive`
# field remains a boolean for conclusive results and becomes null for unknown;
# it must never turn an inconclusive permission probe into false.
pidfile="$repo/.gluerun-state/autonomate.pid"
printf '%s\n' "$$" >"$pidfile"
health_alive="$(env "${env_base[@]}" "$ROOT/engine/ops.sh" health --json)"
python3 - "$health_alive" <<'PY'
import json
import sys

autonomate = json.loads(sys.argv[1])["autonomate"]
assert autonomate["state"] == "alive", autonomate
assert autonomate["alive"] is True, autonomate
PY

printf '%s\n' "99999999" >"$pidfile"
health_dead="$(env "${env_base[@]}" "$ROOT/engine/ops.sh" health --json)"
python3 - "$health_dead" <<'PY'
import json
import sys

doc = json.loads(sys.argv[1])
autonomate = doc["autonomate"]
assert autonomate["state"] == "dead", autonomate
assert autonomate["alive"] is False, autonomate
assert "autonomate not running" in doc["attention"], doc["attention"]
PY

# Numeric values beyond the platform pid_t range are stale, not unknown.
printf '%s\n' "99999999999999999999999999999999999999999999999999" >"$pidfile"
health_oversized="$(env "${env_base[@]}" "$ROOT/engine/ops.sh" health --json)"
python3 - "$health_oversized" <<'PY'
import json
import sys

autonomate = json.loads(sys.argv[1])["autonomate"]
assert autonomate["state"] == "dead", autonomate
assert autonomate["alive"] is False, autonomate
PY

# A lone inherited override, and an invalid gated override, both fall through
# to the real probe rather than affecting ordinary health output.
printf '%s\n' "$$" >"$pidfile"
health_lone_override="$(env "${env_base[@]}" GLUERUN_TEST_PID_PROBE_STATE=unknown \
  "$ROOT/engine/ops.sh" health --json)"
health_invalid_override="$(env "${env_base[@]}" GLUERUN_TEST_PID_PROBE=1 \
  GLUERUN_TEST_PID_PROBE_STATE=not-a-state "$ROOT/engine/ops.sh" health --json)"
python3 - "$health_lone_override" "$health_invalid_override" <<'PY'
import json
import sys

for raw in sys.argv[1:]:
    autonomate = json.loads(raw)["autonomate"]
    assert autonomate["state"] == "alive", autonomate
    assert autonomate["alive"] is True, autonomate
PY

printf '%s\n' "$$" >"$pidfile"
health_unknown="$(env "${env_base[@]}" GLUERUN_TEST_PID_PROBE=1 \
  GLUERUN_TEST_PID_PROBE_STATE=unknown "$ROOT/engine/ops.sh" health --json)"
python3 - "$health_unknown" <<'PY'
import json
import sys

doc = json.loads(sys.argv[1])
autonomate = doc["autonomate"]
assert autonomate["state"] == "unknown", autonomate
assert autonomate["alive"] is None, autonomate
attention = "\n".join(doc["attention"])
assert "liveness unknown" in attention, attention
assert "verify process ownership before starting another loop" in attention, attention
assert "autonomate not running" not in doc["attention"], doc["attention"]
PY

health_unknown_human="$(env "${env_base[@]}" GLUERUN_TEST_PID_PROBE=1 \
  GLUERUN_TEST_PID_PROBE_STATE=unknown "$ROOT/engine/ops.sh" health)"
[[ "$health_unknown_human" == *"state=unknown alive=unknown"* ]] || {
  echo "human health did not name unknown liveness" >&2
  exit 1
}
[[ "$health_unknown_human" != *"autonomate not running"* ]] || {
  echo "human health recommended a duplicate launch after an inconclusive probe" >&2
  exit 1
}

echo "run status tests passed"
