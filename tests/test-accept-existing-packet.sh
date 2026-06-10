#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
path, dotted = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    value = json.load(f)
for part in dotted.split("."):
    value = value[part]
if isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
PY
}

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/tasks" \
    "$root/docs/orchestration/packets/imported" \
    "$root/docs/orchestration/decisions" \
    "$root/schemas/orchestration" \
    "$root/.gluerun-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/schemas/state-packet.v0.schema.json" "$root/schemas/orchestration/state-packet.v0.schema.json"
  cp "$ENGINE_HOME/schemas/audit-verdict.v0.schema.json" "$root/schemas/orchestration/audit-verdict.v0.schema.json"
  mkdir -p "$root/internal/artifact"
  echo "package artifact" >"$root/internal/artifact/doc.go"
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  make_repo "$tmp/repo"
  export GLUERUN_ROOT="$tmp/repo"
  export GLUERUN_ORCH_DIR="$GLUERUN_ROOT/docs/orchestration"
  export GLUERUN_TASKS_DIR="$GLUERUN_ORCH_DIR/tasks"
  export GLUERUN_STATE_DIR="$GLUERUN_ROOT/.gluerun-state"
  export GLUERUN_LEASES_DIR="$GLUERUN_STATE_DIR/leases"
  export GLUERUN_INBOX_DIR="$GLUERUN_STATE_DIR/inbox"
  export GLUERUN_RUNS_DIR="$GLUERUN_STATE_DIR/runs"
  export GLUERUN_EVENTS_FILE="$GLUERUN_STATE_DIR/events.ndjson"
  export GLUERUN_AUDIT_SCHEMA="$GLUERUN_ROOT/schemas/orchestration/audit-verdict.v0.schema.json"
  export GLUERUN_TARGET_BRANCH="target"
  export GLUERUN_MODULES="storage-proof"
  export GLUERUN_PROOF_LAYERS="storage_proof"
}

write_task() {
  cat >"$GLUERUN_TASKS_DIR/TASK-9001.md" <<'EOF'
# TASK-9001: Existing packet acceptance fixture

Status: blocked
Area: artifact
Target branch: `target`
Worker branch: `agent/artifact/TASK-9001-test`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Accept an already-built packet.

## Scope

Owned files:

- `internal/artifact/a.go`
- `internal/artifact/a_test.go`

Forbidden files:

- `internal/artifact/doc.go`

## Acceptance Criteria

- Pass.
EOF
}

write_storage_proof_task() {
  cat >"$GLUERUN_TASKS_DIR/TASK-9001.md" <<'EOF'
# TASK-9001: Durable storage proof existing packet fixture

Status: blocked
Area: artifact
Target branch: `target`
Worker branch: `agent/artifact/TASK-9001-test`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Implement a bounded `D1.storage_proof` / `storage_proof` repository conformance round-trip proof.

## Scope

Owned files:

- `internal/artifact/a.go`
- `internal/artifact/a_test.go`

Forbidden files:

- `internal/artifact/doc.go`

## Acceptance Criteria

- Include marked nonzero red evidence for the storage-stripped real-store proof path.

## Required Evidence

- Failing targeted test output, including a marked nonzero `*-skip-guard-red` storage-proof command log.
EOF
}

write_worker_branch_and_packet() {
  local run_id="RUN-TEST-9001"
  local branch="agent/artifact/TASK-9001-test"
  local base head worktree run_dir
  base="$(git -C "$GLUERUN_ROOT" rev-parse target)"
  worktree="$(dirname "$GLUERUN_ROOT")/wt-TASK-9001"
  git -C "$GLUERUN_ROOT" branch "$branch" target
  git -C "$GLUERUN_ROOT" worktree add -q "$worktree" "$branch"
  echo "package artifact" >"$worktree/internal/artifact/a.go"
  cat >"$worktree/internal/artifact/a_test.go" <<'EOF'
package artifact

import "testing"

func TestFixture(t *testing.T) {}
EOF
  mkdir -p "$worktree/.gluerun-evidence"
  echo "red failed as expected" >"$worktree/.gluerun-evidence/red.log"
  echo "green passed" >"$worktree/.gluerun-evidence/green.log"
  echo "regression passed" >"$worktree/.gluerun-evidence/regression.log"
  git -C "$worktree" add internal/artifact/a.go internal/artifact/a_test.go
  git -C "$worktree" -c user.name=test -c user.email=test@example.local commit -q -m "TASK-9001 worker"
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
  "ownedFiles": [
    "internal/artifact/a.go",
    "internal/artifact/a_test.go"
  ],
  "changedFiles": [
    "internal/artifact/a.go",
    "internal/artifact/a_test.go"
  ],
  "commands": [
    {"cmd": "false", "exitCode": 1, "logRef": ".gluerun-evidence/red.log"},
    {"cmd": "test -f internal/artifact/a.go", "exitCode": 0, "logRef": ".gluerun-evidence/green.log"},
    {"cmd": "test -f internal/artifact/a_test.go", "exitCode": 0, "logRef": ".gluerun-evidence/regression.log"}
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
  mkdir -p "$GLUERUN_LEASES_DIR"
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
  "runId": "$run_id",
  "worktree": "$worktree",
  "status": "blocked",
  "createdAt": "2026-06-03T00:00:00Z",
  "updatedAt": "2026-06-03T00:00:00Z"
}
EOF
}

write_accept_waiver_records() {
  local run_id="RUN-TEST-9001"
  python3 - "$GLUERUN_RUNS_DIR/$run_id/packet.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    packet = json.load(f)
packet["status"] = "accepted"
packet["nextAction"] = "import into control state and reconcile"
packet.setdefault("evidence", []).append({"kind": "waiver", "ref": "decider:accept-waiver"})
with open(path, "w", encoding="utf-8") as f:
    json.dump(packet, f, indent=2)
    f.write("\n")
PY
  cat >"$GLUERUN_RUNS_DIR/$run_id/audit.json" <<'EOF'
{
  "schema": "gluerun.orchestration.audit-verdict.v0",
  "taskId": "TASK-9001",
  "runId": "RUN-TEST-9001",
  "branch": "agent/artifact/TASK-9001-test",
  "verdict": "needs-fix",
  "evidenceReviewed": [],
  "commandsRun": [],
  "findings": ["red evidence passed because behavior already existed"],
  "requiredFixes": ["record an explicit waiver"],
  "rationale": "needs waiver"
}
EOF
  cat >"$GLUERUN_RUNS_DIR/$run_id/decision-audit-needs-fix.json" <<'EOF'
{
  "schema": "gluerun.orchestration.decider-verdict.v0",
  "failureClass": "audit-needs-fix",
  "taskId": "TASK-9001",
  "action": "accept-waiver",
  "rationale": "Accept already-built coverage with explicit waiver.",
  "params": {
    "waiverType": "non_failing_red_evidence"
  },
  "nextOwner": "l1",
  "confidence": 0.8
}
EOF
  cat >"$GLUERUN_ORCH_DIR/decisions.md" <<'EOF'
# Decisions

### 2026-06-04T00:00:00Z — TASK-9001 — accept

- Run: `RUN-TEST-9001`
- Branch: `agent/artifact/TASK-9001-test`
- Authority: origin
- Rationale: accepted via decider waiver (auditor: needs-fix); gate green

### 2026-06-04T00:00:00Z — TASK-9001 — decide:accept-waiver

- Run: `RUN-TEST-9001`
- Branch: `agent/artifact/TASK-9001-test`
- Authority: decider
- Rationale: audit-needs-fix -> accept-waiver
EOF
}

test_accepts_existing_packet_and_imports_afterward() {
  with_fixture
  write_task
  write_worker_branch_and_packet

  "$SCRIPT_DIR/accept-existing-packet.sh" "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" >/tmp/accept-existing-packet.out
  assert_eq "accepted" "$(json_field "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" status)" "packet is accepted"
  assert_eq "accepted" "$(json_field "$GLUERUN_RUNS_DIR/RUN-TEST-9001/audit.json" verdict)" "audit verdict"
  assert_contains "$(sed -n '1,8p' "$GLUERUN_TASKS_DIR/TASK-9001.md")" "Status: accepted" "task status updated"
  assert_eq "accepted" "$(json_field "$GLUERUN_LEASES_DIR/TASK-9001.json" status)" "lease status updated"

  "$SCRIPT_DIR/import-packet.sh" "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" >/tmp/import-existing-packet.out
  [[ -f "$GLUERUN_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json" ]] || fail "packet imported"
  [[ -f "$GLUERUN_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.audit.json" ]] || fail "audit sidecar imported"
}

test_imports_accept_waiver_packet_and_integrates_eligibly() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  write_accept_waiver_records

  "$SCRIPT_DIR/import-packet.sh" "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" >/tmp/import-waiver-packet.out
  [[ -f "$GLUERUN_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json" ]] || fail "waiver packet imported"
  [[ -f "$GLUERUN_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.audit.json" ]] || fail "waiver audit sidecar imported"
  assert_eq "needs-fix" "$(json_field "$GLUERUN_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.audit.json" verdict)" "waiver preserves original audit verdict"
  assert_contains "$(cat /tmp/import-waiver-packet.out)" "acceptance: accepted-waiver" "waiver import mode recorded"

  local out
  out="$(GLUERUN_DEFAULT_GATE_CMD=true "$SCRIPT_DIR/integrate.sh" --dry-run --task TASK-9001)"
  assert_contains "$out" "eligible: TASK-9001" "waiver packet is integration-eligible"
}

test_rejects_already_imported_task() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  mkdir -p "$GLUERUN_ORCH_DIR/packets/imported/TASK-9001"
  cp "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" "$GLUERUN_ORCH_DIR/packets/imported/TASK-9001/RUN-TEST-9001.json"
  local out rc=0
  out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "duplicate import must be rejected"
  assert_contains "$out" "already imported" "duplicate rejection reason"
}

test_rejects_head_mismatch() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  python3 - "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["headSha"] = "deadbeef"
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  local out rc=0
  out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "head mismatch must be rejected"
  assert_contains "$out" "does not match branch head" "head mismatch reason"
}

test_rejects_scope_violation() {
  with_fixture
  write_task
  write_worker_branch_and_packet
  worktree="$(json_field "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" workspace)"
  printf 'package artifact\n\nconst forbiddenFixture = true\n' >"$worktree/internal/artifact/doc.go"
  git -C "$worktree" add internal/artifact/doc.go
  git -C "$worktree" -c user.name=test -c user.email=test@example.local commit -q -m "scope violation"
  head="$(git -C "$worktree" rev-parse HEAD)"
  python3 - "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" "$head" <<'PY'
import json
import sys
path, head = sys.argv[1:3]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["headSha"] = head
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  local out rc=0
  out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "scope violation must be rejected"
  assert_contains "$out" "scope check failed" "scope failure reason"
}

test_accept_existing_rejects_storage_proof_without_marked_red_guard() {
  with_fixture
  write_storage_proof_task
  write_worker_branch_and_packet
  local out rc=0
  out="$("$SCRIPT_DIR/accept-existing-packet.sh" "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "storage proof existing packet without marked red guard must be rejected"
  assert_contains "$out" "logRef ending in -skip-guard-red" "storage proof guard rejection reason"
}

test_import_rejects_storage_proof_without_marked_red_guard() {
  with_fixture
  write_storage_proof_task
  write_worker_branch_and_packet
  write_accept_waiver_records
  local out rc=0
  out="$("$SCRIPT_DIR/import-packet.sh" "$GLUERUN_RUNS_DIR/RUN-TEST-9001/packet.json" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "storage proof import without marked red guard must be rejected"
  assert_contains "$out" "logRef ending in -skip-guard-red" "storage proof import guard rejection reason"
}

test_accepts_existing_packet_and_imports_afterward
test_imports_accept_waiver_packet_and_integrates_eligibly
test_rejects_already_imported_task
test_rejects_head_mismatch
test_rejects_scope_violation
test_accept_existing_rejects_storage_proof_without_marked_red_guard
test_import_rejects_storage_proof_without_marked_red_guard

echo "accept-existing-packet tests passed"
