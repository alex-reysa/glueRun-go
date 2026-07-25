#!/usr/bin/env bash
set -euo pipefail

# E5 (0.5.0): a dispatch against an `accepted` lease whose packet never reached
# the inbox auto-heals via accept-existing-packet (exit 0, packet enqueued)
# instead of refusing forever (0.4.0: infinite exit-2 loop -> breaker).

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-dispatch-auto-accept.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

root="$tmp/repo"
mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/packets/imported" \
  "$root/schemas/orchestration" "$root/.gluerun-state/leases" "$root/.gluerun-state/inbox" \
  "$root/.gluerun-state/runs" "$root/docs/orchestration/prompts"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/schemas/state-packet.v0.schema.json" "$root/schemas/orchestration/"
cp "$ENGINE_HOME/schemas/audit-verdict.v0.schema.json" "$root/schemas/orchestration/"
cp "$ENGINE_HOME/schemas/audit-verdict.v1.schema.json" "$root/schemas/orchestration/"
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$root/docs/orchestration/prompts/"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/"
cat >"$root/gluerun.config.json" <<'JSON'
{"schemaVersion":"v2","targetBranch":"target","gateCommand":"true"}
JSON
mkdir -p "$root/internal/artifact"
echo "package artifact" >"$root/internal/artifact/doc.go"
git -C "$root" add . && git -C "$root" -c user.name=t -c user.email=t@t commit -q -m init

export GLUERUN_ROOT="$root"
export GLUERUN_ORCH_DIR="$root/docs/orchestration"
export GLUERUN_TASKS_DIR="$GLUERUN_ORCH_DIR/tasks"
export GLUERUN_STATE_DIR="$root/.gluerun-state"
export GLUERUN_LEASES_DIR="$GLUERUN_STATE_DIR/leases"
export GLUERUN_INBOX_DIR="$GLUERUN_STATE_DIR/inbox"
export GLUERUN_RUNS_DIR="$GLUERUN_STATE_DIR/runs"
export GLUERUN_DISPATCH_DIR="$GLUERUN_STATE_DIR/dispatch"
export GLUERUN_EVENTS_FILE="$GLUERUN_STATE_DIR/events.ndjson"
export GLUERUN_WORKTREES_DIR="$root/.worktrees"
export GLUERUN_AUDIT_SCHEMA="$root/schemas/orchestration/audit-verdict.v0.schema.json"
export GLUERUN_TARGET_BRANCH="target"

cat >"$GLUERUN_TASKS_DIR/TASK-9001.md" <<'EOF'
# TASK-9001: Auto-accept fixture

Status: accepted
Area: artifact
Target branch: `target`
Worker branch: `agent/artifact/TASK-9001-test`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Heal a stranded accepted packet.

## Scope

Owned files:

- `internal/artifact/a.go`
- `internal/artifact/a_test.go`

Forbidden files:

- `internal/artifact/doc.go`

## Acceptance Criteria

- Pass.
EOF

run_id="RUN-HEAL-9001"
branch="agent/artifact/TASK-9001-test"
base="$(git -C "$root" rev-parse target)"
# The worktree at l1-drive's own derived path triggers the accepted-lease arm.
worktree="$GLUERUN_WORKTREES_DIR/TASK-9001"
mkdir -p "$GLUERUN_WORKTREES_DIR"
git -C "$root" branch "$branch" target
git -C "$root" worktree add -q "$worktree" "$branch"
echo "package artifact" >"$worktree/internal/artifact/a.go"
printf 'package artifact\n\nimport "testing"\n\nfunc TestFixture(t *testing.T) {}\n' \
  >"$worktree/internal/artifact/a_test.go"
mkdir -p "$worktree/.gluerun-evidence"
echo red >"$worktree/.gluerun-evidence/red.log"
echo green >"$worktree/.gluerun-evidence/green.log"
echo regression >"$worktree/.gluerun-evidence/regression.log"
git -C "$worktree" add internal/artifact/a.go internal/artifact/a_test.go
git -C "$worktree" -c user.name=t -c user.email=t@t commit -q -m "TASK-9001 worker"
head="$(git -C "$worktree" rev-parse HEAD)"

run_dir="$GLUERUN_RUNS_DIR/$run_id"
mkdir -p "$run_dir"
cat >"$run_dir/packet.json" <<EOF
{
  "schema": "gluerun.orchestration.state-packet.v0",
  "packetId": "TASK-9001-$run_id",
  "runId": "$run_id",
  "taskId": "TASK-9001",
  "area": "artifact",
  "role": "l2-developer",
  "status": "needs-review",
  "baseRef": "$base",
  "branch": "$branch",
  "headSha": "$head",
  "workspace": "$worktree",
  "ownedFiles": ["internal/artifact/a.go", "internal/artifact/a_test.go"],
  "changedFiles": ["internal/artifact/a.go", "internal/artifact/a_test.go"],
  "commands": [
    {"cmd": "test -f internal/artifact/a.go", "exitCode": 0, "logRef": ".gluerun-evidence/green.log"}
  ],
  "tests": [
    {"name": "fixture red", "phase": "red", "status": "failed-as-expected", "logRef": ".gluerun-evidence/red.log"},
    {"name": "fixture green", "phase": "green", "status": "passed", "logRef": ".gluerun-evidence/green.log"},
    {"name": "fixture regression", "phase": "regression", "status": "passed", "logRef": ".gluerun-evidence/regression.log"}
  ],
  "evidence": [
    {"kind": "red-log", "ref": ".gluerun-evidence/red.log"},
    {"kind": "green-log", "ref": ".gluerun-evidence/green.log"},
    {"kind": "regression-log", "ref": ".gluerun-evidence/regression.log"}
  ],
  "blockers": [],
  "nextAction": "await review",
  "createdAt": "2026-06-03T00:00:00Z"
}
EOF

cat >"$GLUERUN_LEASES_DIR/TASK-9001.json" <<EOF
{
  "taskId": "TASK-9001",
  "branch": "$branch",
  "area": "artifact",
  "owner": "l2-developer",
  "fileScope": "internal/artifact/a.go internal/artifact/a_test.go",
  "ownedFiles": ["internal/artifact/a.go", "internal/artifact/a_test.go"],
  "forbiddenFiles": ["internal/artifact/doc.go"],
  "baseSha": "$base",
  "status": "accepted",
  "runId": "$run_id",
  "worktree": "$worktree",
  "retryCount": 0,
  "createdAt": "2026-06-03T00:00:00Z",
  "updatedAt": "2026-06-03T00:00:00Z"
}
EOF

# 1. Dispatch heals: exit 0, packet enqueued, event emitted.
rc=0
out="$(bash "$SCRIPT_DIR/l1-drive.sh" TASK-9001 2>&1)" || rc=$?
assert_eq "0" "$rc" "auto-heal dispatch exits 0 (out: $out)"
assert_contains "$out" "auto-accepted stranded packet" "heal reported"
[[ -f "$GLUERUN_INBOX_DIR/$run_id.json" ]] || fail "packet must be enqueued to inbox"
assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"type":"l1.auto_accepted_existing"' "heal event"
assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"type":"packet.accepted_existing"' "deterministic acceptance ran"
assert_eq "gluerun.orchestration.audit-verdict.v1" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schema"])' "$run_dir/audit.json")" \
  "v2 deterministic acceptance writes audit-verdict.v1"

# 2. Re-dispatch while queued: no-op exit 0 (work is in flight, no refusal churn).
rc=0
out="$(bash "$SCRIPT_DIR/l1-drive.sh" TASK-9001 2>&1)" || rc=$?
assert_eq "0" "$rc" "queued packet makes dispatch a no-op"
assert_contains "$out" "already queued/imported" "no-op reported"

# 3. Broken packet (headSha moved) falls back to refusal exit 2.
rm -f "$GLUERUN_INBOX_DIR/$run_id.json"
python3 - "$run_dir/packet.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["headSha"] = "0" * 40
json.dump(p, open(sys.argv[1], "w"), indent=2)
PY
# Reset packet status so the earlier acceptance doesn't short-circuit.
python3 - "$run_dir/packet.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["status"] = "needs-review"
json.dump(p, open(sys.argv[1], "w"), indent=2)
PY
rm -rf "$GLUERUN_ORCH_DIR/packets/imported/TASK-9001"
rc=0
bash "$SCRIPT_DIR/l1-drive.sh" TASK-9001 >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc" "invalid packet falls back to refusal"

echo "PASS: test-dispatch-auto-accept"
