#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
CLI="$ENGINE_HOME/cli/gluerun"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }
assert_file() { [[ -f "$1" ]] || fail "$2: missing file $1"; }
assert_dir() { [[ -d "$1" ]] || fail "$2: missing dir $1"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

json_file_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
path, field = sys.argv[1:3]
with open(path, encoding="utf-8") as f:
    value = json.load(f)
for part in field.split("."):
    value = value[part]
print(value)
PY
}

new_git_repo() {
  local root="$1"
  mkdir -p "$root"
  git -C "$root" init -q
  git -C "$root" checkout -q -b main
  printf 'seed\n' >"$root/README.md"
  git -C "$root" add README.md
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

test_init_scaffolds_fresh_repo_and_reconcile_apply_is_noop_safe() {
  local tmp repo out rc
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"

  out="$(cd "$repo" && GLUERUN_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" init 2>&1)"
  assert_contains "$out" "gluerun init ->" "init reports target repo"

  assert_dir "$repo/docs/orchestration/packets/imported" "init packet import scaffold"
  assert_dir "$repo/docs/orchestration/areas/core" "init starter area scaffold"
  assert_file "$repo/docs/orchestration/decisions.md" "init decisions log"
  assert_file "$repo/docs/orchestration/project-state.md" "init project snapshot"
  assert_file "$repo/docs/orchestration/tasks/TEMPLATE.md" "init task template"
  assert_file "$repo/docs/orchestration/planner-contract.md" "init planner contract"
  for schema in audit-verdict decider-verdict gate-result state-packet task-batch dag l1-lease; do
    assert_file "$repo/schemas/orchestration/$schema.v0.schema.json" "init schema mirror $schema"
  done
  for entry in ".gluerun-state/" ".worktrees/" ".gluerun-evidence/" ".gluerun-cache/"; do
    grep -qxF "$entry" "$repo/.gitignore" || fail "init gitignore missing $entry"
  done

  git -C "$repo" checkout -q -b agent/integration
  set +e
  out="$(cd "$repo" && GLUERUN_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" reconcile --apply 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" "0" "fresh reconcile --apply"
  assert_contains "$out" "gluerun origin reconcile (apply)" "fresh reconcile prints summary"
  assert_contains "$(cat "$repo/docs/orchestration/project-state.md")" "Latest Reconcile Snapshot" "fresh reconcile writes project snapshot"
}

test_v0_to_v1_migration_backfills_scaffold_and_rebrands_pmgo_namespace() {
  local tmp repo out
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"
  cat >"$repo/gluerun.config.json" <<'JSON'
{
  "schemaVersion": "v0",
  "engineVersion": "0.3.0",
  "targetBranch": "agent/integration",
  "gateCommand": "true",
  "areas": {},
  "env": {
    "PMGO_COMPAT_MARKER": "pmgo.orchestration.decider-verdict.v0"
  }
}
JSON
  mkdir -p "$repo/docs/orchestration/prompts"
  printf 'legacy schema pmgo.orchestration.state-packet.v0\n' >"$repo/docs/orchestration/prompts/legacy.md"
  git -C "$repo" add gluerun.config.json docs/orchestration/prompts/legacy.md
  git -C "$repo" -c user.name=test -c user.email=test@example.local commit -q -m orchestration-v0

  out="$(cd "$repo" && GLUERUN_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" migrate 2>&1)"
  assert_contains "$out" "run   v0-to-v1.sh (v0 -> v1)" "migration announces v1 step"
  assert_eq "$(json_file_field "$repo/gluerun.config.json" schemaVersion)" "v1" "migration advances schemaVersion"
  grep -q 'gluerun.orchestration.decider-verdict.v0' "$repo/gluerun.config.json" || fail "migration did not rebrand config namespace"
  grep -q 'gluerun.orchestration.state-packet.v0' "$repo/docs/orchestration/prompts/legacy.md" || fail "migration did not rebrand orchestration namespace"
  assert_file "$repo/docs/orchestration/project-state.md" "migration project-state scaffold"
  assert_dir "$repo/docs/orchestration/packets/imported" "migration packet import scaffold"

  out="$(cd "$repo" && GLUERUN_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" migrate 2>&1)"
  assert_contains "$out" "up to date, nothing to do" "migration is idempotent after v1"
}

write_missing_branch_fixture() {
  local repo="$1" packet_dir="$1/docs/orchestration/packets/imported/TASK-0001"
  mkdir -p "$repo/docs/orchestration/tasks" "$packet_dir" "$repo/.gluerun-state/leases"
  cat >"$repo/docs/orchestration/decisions.md" <<'EOF'
# Decisions

## Decision Log
EOF
  cat >"$repo/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Missing branch fixture

Status: accepted
Area: core
Target branch: `target`
Worker branch: `agent/missing/TASK-0001`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Exercise missing branch integration handling.

## Scope

Owned files:

- `README.md`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Pass.
EOF
  local head
  head="$(git -C "$repo" rev-parse HEAD)"
  python3 - "$packet_dir/RUN-MISSING.json" "$head" <<'PY'
import json
import sys
path, head = sys.argv[1:3]
packet = {
    "schema": "gluerun.orchestration.state-packet.v0",
    "packetId": "RUN-MISSING",
    "runId": "RUN-MISSING",
    "taskId": "TASK-0001",
    "area": "core",
    "role": "l2-developer",
    "status": "accepted",
    "baseRef": "target",
    "branch": "agent/missing/TASK-0001",
    "headSha": head,
    "workspace": "/tmp/missing",
    "ownedFiles": ["README.md"],
    "changedFiles": ["README.md"],
    "commands": [],
    "tests": [],
    "evidence": [],
    "blockers": [],
    "nextAction": "integrate",
    "createdAt": "2026-01-01T00:00:00Z",
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(packet, f, indent=2)
    f.write("\n")
PY
  python3 - "$packet_dir/RUN-MISSING.audit.json" <<'PY'
import json
import sys
audit = {
    "schema": "gluerun.orchestration.audit-verdict.v0",
    "taskId": "TASK-0001",
    "runId": "RUN-MISSING",
    "branch": "agent/missing/TASK-0001",
    "verdict": "accepted",
    "evidenceReviewed": [],
    "commandsRun": [],
    "findings": [],
    "requiredFixes": [],
    "rationale": "fixture accepted",
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(audit, f, indent=2)
    f.write("\n")
PY
  GLUERUN_ROOT="$repo" GLUERUN_ORCH_DIR="$repo/docs/orchestration" GLUERUN_STATE_DIR="$repo/.gluerun-state" \
    GLUERUN_LEASES_DIR="$repo/.gluerun-state/leases" GLUERUN_TARGET_BRANCH=target \
    bash -c 'source "$0/lib.sh"; gluerun_lease_write TASK-0001 agent/missing/TASK-0001 core l2 "README.md" accepted RUN-MISSING "" target "" "[\"README.md\"]" "[]"' "$SCRIPT_DIR"
}

test_integrate_parks_missing_branch_once_then_skips_blocked_history() {
  local tmp repo out out2 out3
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"
  git -C "$repo" checkout -q -b target
  write_missing_branch_fixture "$repo"

  out="$(GLUERUN_ROOT="$repo" GLUERUN_ORCH_DIR="$repo/docs/orchestration" GLUERUN_STATE_DIR="$repo/.gluerun-state" \
    GLUERUN_LEASES_DIR="$repo/.gluerun-state/leases" GLUERUN_TASKS_DIR="$repo/docs/orchestration/tasks" \
    GLUERUN_TARGET_BRANCH=target GLUERUN_DEFAULT_GATE_CMD=true bash "$SCRIPT_DIR/integrate.sh" --run-id RUN-MISSING-INTEG 2>&1)"
  assert_contains "$out" "skip TASK-0001: branch missing" "first integrate reports missing branch"
  assert_eq "$(json_file_field "$repo/.gluerun-state/leases/TASK-0001.json" status)" "blocked" "missing branch blocks lease"
  grep -q '^Status: blocked$' "$repo/docs/orchestration/tasks/TASK-0001.md" || fail "missing branch blocks task"
  assert_contains "$(cat "$repo/docs/orchestration/decisions.md")" "decide:escalate-parked" "missing branch records parked decision"

  out2="$(GLUERUN_ROOT="$repo" GLUERUN_ORCH_DIR="$repo/docs/orchestration" GLUERUN_STATE_DIR="$repo/.gluerun-state" \
    GLUERUN_LEASES_DIR="$repo/.gluerun-state/leases" GLUERUN_TASKS_DIR="$repo/docs/orchestration/tasks" \
    GLUERUN_TARGET_BRANCH=target GLUERUN_DEFAULT_GATE_CMD=true bash "$SCRIPT_DIR/integrate.sh" --run-id RUN-MISSING-INTEG2 2>&1)"
  assert_not_contains "$out2" "branch missing" "blocked missing branch is not rescanned in normal cycle"

  out3="$(GLUERUN_ROOT="$repo" GLUERUN_ORCH_DIR="$repo/docs/orchestration" GLUERUN_STATE_DIR="$repo/.gluerun-state" \
    GLUERUN_LEASES_DIR="$repo/.gluerun-state/leases" GLUERUN_TASKS_DIR="$repo/docs/orchestration/tasks" \
    GLUERUN_TARGET_BRANCH=target GLUERUN_DEFAULT_GATE_CMD=true bash "$SCRIPT_DIR/integrate.sh" --task TASK-0001 --dry-run 2>&1)"
  assert_contains "$out3" "skip TASK-0001: branch missing" "explicit task rechecks missing branch"
}

test_l1_drive_provisions_gitignored_files_and_allowlisted_env() {
  local tmp repo runner out rc
  tmp="$(mktemp -d)"
  repo="$tmp/repo"
  new_git_repo "$repo"
  git -C "$repo" checkout -q -b target
  mkdir -p "$repo/docs/orchestration/prompts" "$repo/docs/orchestration/tasks" "$repo/src"
  cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$repo/docs/orchestration/prompts/l2-test-first-developer.md"
  cp "$ENGINE_HOME/templates/prompts/auditor.md" "$repo/docs/orchestration/prompts/auditor.md"
  cp "$ENGINE_HOME/templates/prompts/decider.md" "$repo/docs/orchestration/prompts/decider.md"
  printf '.gluerun-state/\n.worktrees/\n.gluerun-evidence/\n.env.local\n' >"$repo/.gitignore"
  cat >"$repo/.env.local" <<'EOF'
LOCAL_ONLY=present
EOF
  cat >"$repo/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Provisioning fixture

Status: ready
Area: core
Target branch: `target`
Worker branch: `agent/core/TASK-0001-provisioning`
Test policy: `strict_test_first`
Gate command: `test -f .env.local && test -f "$GLUERUN_WORKTREE_ENV_FILE" && . "$GLUERUN_WORKTREE_ENV_FILE" && test "${PUBLIC_ALLOWED:-}" = ok && test -z "${SECRET_DENIED:-}"`
Dispatch mode: canonical
Depends on: []

## Objective

Write the generated fixture file.

## Scope

Owned files:

- `src/generated.txt`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Gate can read provisioned file and allowlisted env.
EOF
  git -C "$repo" add .gitignore docs/orchestration src
  git -C "$repo" -c user.name=test -c user.email=test@example.local commit -q -m target-setup
  cat >"$repo/gluerun.config.json" <<JSON
{
  "schemaVersion": "v1",
  "targetBranch": "target",
  "gateCommand": "true",
  "provisionFiles": [
    {"source": ".env.local", "target": ".env.local", "required": true}
  ],
  "envAllowlist": ["PUBLIC_*"]
}
JSON
  runner="$tmp/runner.sh"
  cat >"$runner" <<'SH'
#!/usr/bin/env bash
level=""; out=""; chdir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="$2"; shift 2 ;;
    -C|--worktree) chdir="$2"; shift 2 ;;
    --output-last-message) out="$2"; shift 2 ;;
    --prompt-file|--run-id|--session-meta|--resume-session) shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$level" == "l2" ]]; then
  mkdir -p "$chdir/src" "$chdir/.gluerun-evidence"
  printf 'generated\n' >"$chdir/src/generated.txt"
  printf 'red\n' >"$chdir/.gluerun-evidence/red.log"
  printf 'green\n' >"$chdir/.gluerun-evidence/green.log"
  printf 'regression\n' >"$chdir/.gluerun-evidence/regression.log"
  python3 - "$out" <<'PY'
import json
import sys
packet = {
    "schema": "gluerun.orchestration.state-packet.v0",
    "packetId": "p",
    "runId": "r",
    "taskId": "TASK-0001",
    "area": "core",
    "role": "l2-developer",
    "status": "needs-review",
    "baseRef": "target",
    "branch": "agent/core/TASK-0001-provisioning",
    "headSha": "uncommitted",
    "workspace": "/tmp",
    "ownedFiles": ["src/generated.txt"],
    "changedFiles": ["src/generated.txt"],
    "commands": [{"cmd": "true", "exitCode": 0}],
    "tests": [{"name": "fixture", "phase": "red", "status": "fail", "logRef": ".gluerun-evidence/red.log"},
              {"name": "fixture", "phase": "green", "status": "pass", "logRef": ".gluerun-evidence/green.log"}],
    "evidence": [{"kind": "red", "ref": ".gluerun-evidence/red.log"}],
    "blockers": [],
    "nextAction": "audit",
    "createdAt": "2026-01-01T00:00:00Z",
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(packet, f)
PY
  exit 0
fi
python3 - "$out" <<'PY'
import json
import sys
audit = {
    "schema": "gluerun.orchestration.audit-verdict.v0",
    "taskId": "TASK-0001",
    "runId": "r",
    "branch": "agent/core/TASK-0001-provisioning",
    "verdict": "accepted",
    "evidenceReviewed": [],
    "commandsRun": [],
    "findings": [],
    "requiredFixes": [],
    "rationale": "accepted",
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(audit, f)
PY
SH
  chmod +x "$runner"

  set +e
  out="$(PUBLIC_ALLOWED=ok SECRET_DENIED=bad GLUERUN_ROOT="$repo" GLUERUN_ORCH_DIR="$repo/docs/orchestration" \
    GLUERUN_STATE_DIR="$repo/.gluerun-state" GLUERUN_RUNS_DIR="$repo/.gluerun-state/runs" \
    GLUERUN_TASKS_DIR="$repo/docs/orchestration/tasks" GLUERUN_WORKTREES_DIR="$repo/.worktrees" \
    GLUERUN_TARGET_BRANCH=target GLUERUN_RUNNER="$runner" GLUERUN_MAX_RETRIES=0 \
    bash "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" "0" "provisioned l1-drive accepts ($out)"
  assert_contains "$out" "ACCEPTED: TASK-0001" "provisioned task accepted"
}

test_init_scaffolds_fresh_repo_and_reconcile_apply_is_noop_safe
test_v0_to_v1_migration_backfills_scaffold_and_rebrands_pmgo_namespace
test_integrate_parks_missing_branch_once_then_skips_blocked_history
test_l1_drive_provisions_gitignored_files_and_allowlisted_env

echo "fresh consumer tests passed"
