#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg (missing: $needle)"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/state/leases" "$tmp/docs/orchestration/tasks" "$tmp/worktrees"

cat >"$tmp/fake-decider.sh" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "TASK-0004" ]]; then
    echo "fake decider should not run for terminal TASK-0004" >&2
    exit 1
  fi
done
echo action=revalidate-evidence
SH
chmod +x "$tmp/fake-decider.sh"

cat >"$tmp/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: stale running fixture

Status: planned
EOF

cat >"$tmp/docs/orchestration/tasks/TASK-0004.md" <<'EOF'
# TASK-0004: already integrated fixture

Status: integrated
EOF
mkdir -p "$tmp/docs/orchestration/packets/imported/TASK-0004"
printf '%s\n' '{}' >"$tmp/docs/orchestration/packets/imported/TASK-0004/RUN-FIXTURE.json"

printf '%s\n' '{"taskId":"TASK-0001","status":"running","retryCount":1,"maxRetries":2,"productPassStarted":true,"productPassStartedRunId":"RUN-ORIGINAL","runId":"RUN-ORIGINAL","branch":"agent/core/TASK-0001","baseSha":"base-original","batchId":"batch-original","ownedFiles":["src/core.ts"]}' >"$tmp/state/leases/TASK-0001.json"
printf '%s\n' '{"taskId":"TASK-0002","status":"planned","retryCount":0,"productPassStarted":false,"runId":"RUN-PLANNED"}' >"$tmp/state/leases/TASK-0002.json"
printf '%s\n' '{"taskId":"TASK-0003","status":"needs-review","retryCount":2,"productPassStarted":true,"runId":"RUN-REVIEW"}' >"$tmp/state/leases/TASK-0003.json"
printf '%s\n' '{"status":"running"}' >"$tmp/state/leases/TASK-0004.json"
printf '%s\n' '{not-json' >"$tmp/state/leases/TASK-0005.json"

out="$(
  SINGULAR_ROOT="$tmp" \
  SINGULAR_STATE_DIR="$tmp/state" \
  SINGULAR_ORCH_DIR="$tmp/docs/orchestration" \
  SINGULAR_TASKS_DIR="$tmp/docs/orchestration/tasks" \
  SINGULAR_LEASES_DIR="$tmp/state/leases" \
  SINGULAR_WORKTREES_DIR="$tmp/worktrees" \
  SINGULAR_STALE_MINUTES=0 \
  SINGULAR_RECOVERY_DECIDER="$tmp/fake-decider.sh" \
  "$SCRIPT_DIR/recover.sh" --scan
)"

assert_contains "$out" "recover: preserved stale lease TASK-0001 as failed/recoverable" "running lease should become recoverable without deletion"
assert_contains "$out" "recover: preserved stale lease TASK-0002 as failed/recoverable" "planned lease should become recoverable without deletion"
assert_contains "$out" "recover: preserved stale lease TASK-0003 as failed/recoverable" "needs-review lease should become recoverable without deletion"
assert_contains "$out" "recover: closed stale lease TASK-0004 from task status integrated" "terminal task status should close an active lease instead of requeueing"
assert_contains "$out" "recover: quarantined unreadable lease TASK-0005.json" "invalid lease JSON should be preserved outside active lease scans"
assert_contains "$out" "recover (scan): 5 action(s)" "all stale active lease files and invalid lease residue should be handled"

for task in TASK-0001 TASK-0002 TASK-0003; do
  [[ -e "$tmp/state/leases/$task.json" ]] || fail "$task lease should be preserved"
  grep -q '"status": "failed"' "$tmp/state/leases/$task.json" \
    || fail "$task lease should be failed/recoverable"
done
python3 - "$tmp/state/leases/TASK-0001.json" <<'PY'
import json
import sys

lease = json.load(open(sys.argv[1], encoding="utf-8"))
assert lease["retryCount"] == 1, lease
assert lease["maxRetries"] == 2, lease
assert lease["productPassStarted"] is True, lease
assert lease["productPassStartedRunId"] == "RUN-ORIGINAL", lease
assert lease["runId"] == "RUN-ORIGINAL", lease
assert lease["branch"] == "agent/core/TASK-0001", lease
assert lease["baseSha"] == "base-original", lease
assert lease["batchId"] == "batch-original", lease
assert lease["ownedFiles"] == ["src/core.ts"], lease
PY
[[ ! -e "$tmp/state/leases/TASK-0005.json" ]] || fail "TASK-0005 invalid lease should be quarantined"
[[ -e "$tmp/state/leases/superseded/TASK-0005.json" ]] || fail "TASK-0005 invalid lease should be preserved under superseded"
grep -q '"status": "integrated"' "$tmp/state/leases/TASK-0004.json" || fail "TASK-0004 lease should be terminalized"
grep -q '^Status: ready$' "$tmp/docs/orchestration/tasks/TASK-0001.md" || fail "task file should be requeued ready"
assert_contains "$(cat "$tmp/state/events.ndjson")" '"productBudgetPreserved":true' \
  "stale retry should record preservation of durable product budget"

echo "ok"
