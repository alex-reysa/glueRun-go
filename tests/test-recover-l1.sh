#!/usr/bin/env bash
set -euo pipefail

# P7 (0.5.0): recover reclassifies stale L1 planning leases to failed
# (GLUERUN_RECOVER_L1=1 default) so their nodes re-enter the frontier;
# =0 restores report-only. Orphaned worktrees are reported once.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-recover-l1.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/.gluerun-state/l1-leases" "$root/.gluerun-state/leases" \
  "$root/docs/orchestration/tasks" "$root/.worktrees/TASK-0042"
git -C "$root" init -q
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# Stale active L1 lease (old updatedAt) + a fresh one.
cat >"$root/.gluerun-state/l1-leases/node-old.json" <<'EOF'
{"schema":"gluerun.orchestration.l1-lease.v0","node":"node-old","area":"core","stage":"S0","layer":"x","status":"active","runId":"RUN-x","baseSha":"abcdef1","targetBranch":"target","allowedWriteScopes":["internal/core/"],"startedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
EOF
python3 - "$root/.gluerun-state/l1-leases/node-fresh.json" <<'PY'
import json, sys
from datetime import datetime, timezone
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
json.dump({"schema": "gluerun.orchestration.l1-lease.v0", "node": "node-fresh",
           "area": "aux", "stage": "S0", "layer": "x", "status": "active",
           "runId": "RUN-y", "baseSha": "abcdef1", "targetBranch": "target",
           "allowedWriteScopes": ["internal/aux/"], "startedAt": now, "updatedAt": now},
          open(sys.argv[1], "w"), indent=2)
PY
# Orphaned worktree: superseded lease.
printf '%s\n' '{"taskId":"TASK-0042","status":"superseded"}' >"$root/.gluerun-state/leases/TASK-0042.json"

rec() {
  env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
    GLUERUN_ORCH_DIR="$root/docs/orchestration" GLUERUN_TASKS_DIR="$root/docs/orchestration/tasks" \
    GLUERUN_LEASES_DIR="$root/.gluerun-state/leases" \
    GLUERUN_L1_LEASES_DIR="$root/.gluerun-state/l1-leases" \
    GLUERUN_WORKTREES_DIR="$root/.worktrees" GLUERUN_INBOX_DIR="$root/.gluerun-state/inbox" \
    GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson" "$@" \
    bash "$SCRIPT_DIR/recover.sh" --scan 2>&1
}

# 1. Stale L1 lease reclaimed; fresh one untouched; orphan reported.
out="$(rec env)"
assert_contains "$out" "reclaimed stale l1 lease node-old" "stale L1 reclaimed"
assert_contains "$out" "orphaned worktree" "orphan reported first time"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$root/.gluerun-state/l1-leases/node-old.json")" == "failed" ]] \
  || fail "stale lease -> failed"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$root/.gluerun-state/l1-leases/node-fresh.json")" == "active" ]] \
  || fail "fresh lease untouched"
assert_contains "$(cat "$root/.gluerun-state/events.ndjson")" '"type":"recover.l1_lease_reclaimed"' "reclaim event"

# 2. Report-once: second scan does not repeat the orphan line.
out="$(rec env)"
assert_not_contains "$out" "orphaned worktree $root/.worktrees/TASK-0042" "orphan not re-reported"
assert_contains "$out" "known orphaned worktree" "summary counter shown"

# 3. Opt-out restores report-only for L1 leases.
cat >"$root/.gluerun-state/l1-leases/node-old2.json" <<'EOF'
{"schema":"gluerun.orchestration.l1-lease.v0","node":"node-old2","area":"core","stage":"S0","layer":"x","status":"planning","runId":"RUN-z","baseSha":"abcdef1","targetBranch":"target","allowedWriteScopes":["internal/core/"],"startedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
EOF
out="$(rec env GLUERUN_RECOVER_L1=0)"
assert_contains "$out" "report-only" "opt-out reports"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$root/.gluerun-state/l1-leases/node-old2.json")" == "planning" ]] \
  || fail "opt-out must not mutate"

echo "PASS: test-recover-l1"
