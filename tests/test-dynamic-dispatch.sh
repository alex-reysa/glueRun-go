#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local want="$1" got="$2" msg="$3"
  [[ "$got" == "$want" ]] || fail "$msg: want '$want', got '$got'"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg: missing '$needle' in: $haystack"
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$msg: unexpectedly found '$needle' in: $haystack"
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
value = data
for part in sys.argv[2].split("."):
    value = value[part]
if isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
PY
}

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/packets/imported" \
    "$root/docs/orchestration/areas/artifact" \
    "$root/docs/orchestration/gates" \
    "$root/docs/orchestration/prompts" "$root/schemas/orchestration" "$root/.gluerun-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$root/docs/orchestration/prompts/l1-planner.md"
  cp "$ENGINE_HOME/schemas/state-packet.v0.schema.json" "$root/schemas/orchestration/state-packet.v0.schema.json"
  cp "$ENGINE_HOME/schemas/audit-verdict.v0.schema.json" "$root/schemas/orchestration/audit-verdict.v0.schema.json"
  cp "$ENGINE_HOME/schemas/decider-verdict.v0.schema.json" "$root/schemas/orchestration/decider-verdict.v0.schema.json"
  cp "$ENGINE_HOME/schemas/task-batch.v0.schema.json" "$root/schemas/orchestration/task-batch.v0.schema.json"
  cp "$ENGINE_HOME/schemas/dag.v0.schema.json" "$root/schemas/orchestration/dag.v0.schema.json"
  cp "$ENGINE_HOME/schemas/gate-result.v0.schema.json" "$root/schemas/orchestration/gate-result.v0.schema.json"
  cat >"$root/docs/orchestration/project-state.md" <<'EOF'
# Project State
EOF
  cat >"$root/docs/orchestration/areas/artifact/state.md" <<'EOF'
# Area State: Artifact

Current status: active
EOF
  cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "gluerun.orchestration.dag.v0",
  "nodes": [
    {
      "id": "D0.contract",
      "stage": "D0",
      "area": "kernel",
      "layer": "contract",
      "kind": "contract",
      "dependsOn": [],
      "requiredCompletion": "contract_complete"
    },
    {
      "id": "D1.contract",
      "stage": "D1",
      "area": "artifact",
      "layer": "contract",
      "kind": "contract",
      "dependsOn": ["D0.contract"],
      "requiredCompletion": "contract_complete"
    },
    {
      "id": "S0.storage_substrate_base",
      "stage": "S0",
      "area": "storage",
      "layer": "storage_substrate_base",
      "kind": "substrate",
      "dependsOn": ["D0.contract"],
      "requiredCompletion": "storage_substrate_ready"
    },
    {
      "id": "D1.storage_proof",
      "stage": "D1",
      "area": "artifact",
      "layer": "storage_proof",
      "kind": "storage",
      "dependsOn": ["D1.contract", "S0.storage_substrate_base"],
      "requiredCompletion": "storage_proof_complete"
    }
  ]
}
EOF
  cat >"$root/docs/orchestration/gates/D0.contract.gate-result.json" <<'EOF'
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "D0.contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "grandfathered",
  "evidence": [
    {
      "kind": "source-path",
      "ref": "internal/kernel",
      "description": "Existing D0 kernel contract package."
    }
  ],
  "decidedBy": "bootstrap",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

write_task() {
  local id="$1" status="$2" owned="$3" depends="${4:-[]}" forbidden="${5:-}"
  local title="${6:-Task $id}"
  [[ -n "$forbidden" ]] || forbidden="Any file outside the owned scope unless an L1 scope amendment is recorded."
  cat >"$GLUERUN_TASKS_DIR/$id.md" <<EOF
# $id: $title

Status: $status
Area: artifact
Target branch: \`target\`
Worker branch: \`agent/artifact/$id-test\`
Test policy: \`strict_test_first\`
Gate command: \`true\`
Dispatch mode: canonical
Depends on: $depends

## Objective

Exercise $id.

## Scope

Owned files:

- \`$owned\`

Forbidden files:

- \`$forbidden\`

## Prerequisites

- Human-readable prerequisite text.

## Acceptance Criteria

- Pass.
EOF
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
  export GLUERUN_WORKTREES_DIR="$GLUERUN_ROOT/.worktrees"
  export GLUERUN_ORIGIN_STATE_FILE="$GLUERUN_STATE_DIR/origin-state.json"
  export GLUERUN_GIT_LOCK_DIR="$GLUERUN_STATE_DIR/locks/git-op.lock"
  export GLUERUN_PACKET_SCHEMA="$GLUERUN_ROOT/schemas/orchestration/state-packet.v0.schema.json"
  export GLUERUN_AUDIT_SCHEMA="$GLUERUN_ROOT/schemas/orchestration/audit-verdict.v0.schema.json"
  export GLUERUN_DECIDER_SCHEMA="$GLUERUN_ROOT/schemas/orchestration/decider-verdict.v0.schema.json"
  export GLUERUN_STOP_FILE="$GLUERUN_STATE_DIR/STOP"
  export GLUERUN_STATUS_FILE="$GLUERUN_STATE_DIR/STATUS.md"
  export GLUERUN_BREAKER_FILE="$GLUERUN_STATE_DIR/circuit.json"
  export GLUERUN_TARGET_BRANCH="target"
  export GLUERUN_MODULES="storage-proof"
  export GLUERUN_PROOF_LAYERS="storage_proof"
  source "$SCRIPT_DIR/lib.sh"
}

test_task_parser_metadata() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "TASK-0007, TASK-0008"
  local json
  json="$(gluerun_task_json "$GLUERUN_TASKS_DIR/TASK-0001.md")"
  assert_eq "canonical" "$(json_field "$json" dispatchMode)" "dispatch mode parsed"
  assert_eq '["TASK-0007","TASK-0008"]' "$(json_field "$json" dependsOn)" "dependsOn parsed"
}

test_frontier_selection() {
  with_fixture
  write_task TASK-0001 integrated internal/artifact/kind.go "[]"
  write_task TASK-0002 ready internal/artifact/schema.go "[]"
  write_task TASK-0003 ready internal/artifact/version.go "TASK-0001"
  write_task TASK-0004 ready internal/artifact/schema.go "[]"
  write_task TASK-0005 ready internal/artifact/dependent.go "TASK-9999"
  gluerun_lease_write TASK-0006 agent/artifact/TASK-0006 artifact l2 "internal/artifact/active.go" running RUN-LEASE "$GLUERUN_WORKTREES_DIR/TASK-0006" target-sha "" '["internal/artifact/active.go"]' "[]"
  write_task TASK-0006 ready internal/artifact/active.go "[]"

  local selected ids
  selected="$(gluerun_select_dispatch_frontier 3)"
  ids="$(printf '%s\n' "$selected" | xargs -n1 basename | sed 's/\.md$//' | paste -sd ' ' -)"
  assert_eq "TASK-0002 TASK-0003" "$ids" "frontier selects only dependency-ready, file-disjoint, lease-free tasks"
}

test_frontier_selection_allows_shared_forbidden_files() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/schema.go "[]" internal/artifact/doc.go
  write_task TASK-0002 ready internal/artifact/version.go "[]" internal/artifact/doc.go

  local selected ids
  selected="$(gluerun_select_dispatch_frontier 2)"
  ids="$(printf '%s\n' "$selected" | xargs -n1 basename | sed 's/\.md$//' | paste -sd ' ' -)"
  assert_eq "TASK-0001 TASK-0002" "$ids" "frontier allows disjoint owned files with shared forbidden files"
}

test_frontier_selection_allows_shared_forbidden_file_with_active_lease() {
  with_fixture
  gluerun_lease_write TASK-0001 agent/artifact/TASK-0001 artifact l2 "internal/artifact/active.go" running RUN-LEASE "$GLUERUN_WORKTREES_DIR/TASK-0001" target-sha "" '["internal/artifact/active.go"]' '["internal/artifact/doc.go"]'
  write_task TASK-0002 ready internal/artifact/version.go "[]" internal/artifact/doc.go

  local selected ids
  selected="$(gluerun_select_dispatch_frontier 2)"
  ids="$(printf '%s\n' "$selected" | xargs -n1 basename | sed 's/\.md$//' | paste -sd ' ' -)"
  assert_eq "TASK-0002" "$ids" "frontier ignores active lease forbidden files when owned files are disjoint"
}

test_frontier_selection_allows_requeued_task_with_failed_lease() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/requeued.go "[]"
  gluerun_lease_write TASK-0001 agent/artifact/TASK-0001 artifact l2 "internal/artifact/requeued.go" failed RUN-LEASE "$GLUERUN_WORKTREES_DIR/TASK-0001" target-sha "" '["internal/artifact/requeued.go"]' "[]"

  local selected ids
  selected="$(gluerun_select_dispatch_frontier 1)"
  ids="$(printf '%s\n' "$selected" | xargs -n1 basename | sed 's/\.md$//' | paste -sd ' ' -)"
  assert_eq "TASK-0001" "$ids" "frontier allows an explicitly requeued ready task with a terminal failed lease"
}

make_parallel_stub() {
  local stub="$1"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tid="$1"
mkdir -p "$GLUERUN_STATE_DIR"
echo "$tid base=${GLUERUN_DISPATCH_BASE_SHA:-} batch=${GLUERUN_DISPATCH_BATCH_ID:-}" >>"$GLUERUN_STATE_DIR/dispatch.log"
touch "$GLUERUN_STATE_DIR/$tid.start"
case "$tid" in
  TASK-0001) other=TASK-0002 ;;
  TASK-0002) other=TASK-0001 ;;
  *) other="" ;;
esac
if [[ -n "$other" ]]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f "$GLUERUN_STATE_DIR/$other.start" ]] && exit 0
    sleep 0.2
  done
  echo "$tid did not overlap with $other" >&2
  exit 7
fi
exit 0
EOF
  chmod +x "$stub"
}

test_reconcile_parallel_batch_with_stub() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  write_task TASK-0002 ready internal/artifact/b.go "[]"
  local stub="$GLUERUN_ROOT/stub-l1.sh"
  make_parallel_stub "$stub"

  local out
  out="$(GLUERUN_L1_DRIVER="$stub" GLUERUN_GENERATE=0 GLUERUN_AUTO_INTEGRATE=0 GLUERUN_MAX_CONCURRENT=2 GLUERUN_MAX_DISPATCH=2 GLUERUN_DETACHED_DISPATCH=0 \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)"
  assert_contains "$out" "dispatched_this_run=2" "parallel reconcile dispatched both tasks"
  assert_contains "$out" "failed_dispatches=0" "parallel reconcile had no dispatch failures"
  assert_contains "$(cat "$GLUERUN_STATE_DIR/dispatch.log")" "TASK-0001 base=" "TASK-0001 received dispatch metadata"
  assert_contains "$(cat "$GLUERUN_STATE_DIR/dispatch.log")" "TASK-0002 base=" "TASK-0002 received dispatch metadata"
}

test_reconcile_parallel_batch_with_shared_forbidden_file() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]" internal/artifact/doc.go
  write_task TASK-0002 ready internal/artifact/b.go "[]" internal/artifact/doc.go
  local stub="$GLUERUN_ROOT/stub-l1.sh"
  make_parallel_stub "$stub"

  local out
  out="$(GLUERUN_L1_DRIVER="$stub" GLUERUN_GENERATE=0 GLUERUN_AUTO_INTEGRATE=0 GLUERUN_MAX_CONCURRENT=2 GLUERUN_MAX_DISPATCH=2 GLUERUN_DETACHED_DISPATCH=0 \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)"
  assert_contains "$out" "dispatched_this_run=2" "parallel reconcile dispatched both tasks sharing a forbidden file"
  assert_contains "$out" "failed_dispatches=0" "parallel reconcile shared-forbidden batch had no dispatch failures"
}

test_reconcile_counts_failed_child() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/a.go "[]"
  write_task TASK-0002 ready internal/artifact/b.go "[]"
  local stub="$GLUERUN_ROOT/stub-l1-fail.sh"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$1" >>"$GLUERUN_STATE_DIR/dispatch.log"
[[ "$1" == "TASK-0002" ]] && exit 9
exit 0
EOF
  chmod +x "$stub"

  local out
  out="$(GLUERUN_L1_DRIVER="$stub" GLUERUN_GENERATE=0 GLUERUN_AUTO_INTEGRATE=0 GLUERUN_MAX_CONCURRENT=2 GLUERUN_MAX_DISPATCH=2 GLUERUN_DETACHED_DISPATCH=0 \
    "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
  assert_contains "$out" "dispatched_this_run=2" "failed-child reconcile still counted both dispatch attempts"
  assert_contains "$out" "failed_dispatches=1" "failed-child reconcile counted one failure"
}

make_codex_arg_stub() {
  local dir="$GLUERUN_STATE_DIR/fake-bin"
  mkdir -p "$dir"
  cat >"$dir/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$GLUERUN_STATE_DIR/codex-args.log"
exit 0
EOF
  chmod +x "$dir/codex"
  export PATH="$dir:$PATH"
}

test_codex_run_l2_defaults_to_workspace_write_sandbox() {
  with_fixture
  make_codex_arg_stub

  "$SCRIPT_DIR/codex-run.sh" --level l2 --no-output-capture -C "$GLUERUN_ROOT" >/dev/null 2>&1

  assert_contains "$(cat "$GLUERUN_STATE_DIR/codex-args.log")" "--sandbox workspace-write" "l2 codex-run defaults to workspace-write"
}

test_codex_run_l2_uses_medium_reasoning_without_service_tier() {
  with_fixture
  make_codex_arg_stub

  "$SCRIPT_DIR/codex-run.sh" --level l2 --no-output-capture -C "$GLUERUN_ROOT" >/dev/null 2>&1

  local args
  args="$(cat "$GLUERUN_STATE_DIR/codex-args.log")"
  assert_contains "$args" "-m gpt-5.5" "l2 codex-run pins the worker model"
  assert_contains "$args" "model_reasoning_effort=\"medium\"" "l2 codex-run uses medium reasoning"
  assert_not_contains "$args" "service_tier=" "l2 codex-run leaves service tier at the API default"
  assert_not_contains "$args" "service_tier=\"fast\"" "l2 codex-run does not request fast service tier"
}

test_codex_run_readonly_planner_uses_xhigh_reasoning() {
  with_fixture
  make_codex_arg_stub
  local prompt="$GLUERUN_STATE_DIR/planner-prompt.md"
  printf 'plan\n' >"$prompt"

  "$SCRIPT_DIR/codex-run.sh" --level readonly --prompt-file "$prompt" -C "$GLUERUN_ROOT" >/dev/null 2>&1

  local args
  args="$(cat "$GLUERUN_STATE_DIR/codex-args.log")"
  assert_contains "$args" "--sandbox read-only" "planner codex-run uses readonly sandbox"
  assert_contains "$args" "-m gpt-5.5" "planner codex-run pins the model"
  assert_contains "$args" "model_reasoning_effort=\"xhigh\"" "planner codex-run uses xhigh reasoning"
  assert_not_contains "$args" "service_tier=" "planner codex-run leaves service tier at the API default"
}

test_codex_run_readonly_auditor_uses_high_reasoning() {
  with_fixture
  make_codex_arg_stub
  local prompt="$GLUERUN_STATE_DIR/auditor-prompt.md"
  printf 'audit\n' >"$prompt"

  "$SCRIPT_DIR/codex-run.sh" --level readonly --prompt-file "$prompt" -C "$GLUERUN_ROOT" >/dev/null 2>&1

  local args
  args="$(cat "$GLUERUN_STATE_DIR/codex-args.log")"
  assert_contains "$args" "--sandbox read-only" "auditor codex-run uses readonly sandbox"
  assert_contains "$args" "-m gpt-5.5" "auditor codex-run pins the model"
  assert_contains "$args" "model_reasoning_effort=\"high\"" "auditor codex-run uses high reasoning"
  assert_not_contains "$args" "service_tier=" "auditor codex-run leaves service tier at the API default"
}

test_codex_run_l2_allows_explicit_sandbox_override() {
  with_fixture
  make_codex_arg_stub

  GLUERUN_L2_SANDBOX=danger-full-access "$SCRIPT_DIR/codex-run.sh" --level l2 --no-output-capture -C "$GLUERUN_ROOT" >/dev/null 2>&1

  assert_contains "$(cat "$GLUERUN_STATE_DIR/codex-args.log")" "--sandbox danger-full-access" "l2 codex-run honors explicit sandbox override"
}

test_codex_run_l2_rejects_invalid_sandbox_override() {
  with_fixture
  make_codex_arg_stub

  local out
  out="$(GLUERUN_L2_SANDBOX=bogus "$SCRIPT_DIR/codex-run.sh" --level l2 --no-output-capture -C "$GLUERUN_ROOT" 2>&1 || true)"

  assert_contains "$out" "invalid GLUERUN_L2_SANDBOX" "invalid l2 sandbox override is rejected"
}

test_gate_red_external_proof_env_blocker_detected() {
  with_fixture
  local log="$GLUERUN_STATE_DIR/gate-red.log"
  cat >"$log" <<'EOF'
--- FAIL: TestArtifactStorageRepositoryDurableRoundTripProvesPostgresAndBlobImmutability (0.00s)
    storage_repository_test.go:30: GLUERUN_STORAGE_PROOF_DATABASE_URL or GLUERUN_DATABASE_URL must point at a real PostgreSQL database; the storage proof must not silently skip or use an in-memory/SQLite substitute
FAIL
EOF
  unset GLUERUN_STORAGE_PROOF_DATABASE_URL GLUERUN_DATABASE_URL
  gluerun_gate_red_external_proof_env_blocker "$log" \
    || fail "missing real PostgreSQL env gate-red must be treated as an external proof-env blocker"
}

test_gate_red_external_proof_env_blocker_ignored_when_env_present() {
  with_fixture
  local log="$GLUERUN_STATE_DIR/gate-red.log"
  cat >"$log" <<'EOF'
storage_repository_test.go:30: GLUERUN_STORAGE_PROOF_DATABASE_URL or GLUERUN_DATABASE_URL must point at a real PostgreSQL database; the storage proof must not silently skip or use an in-memory/SQLite substitute
EOF
  if GLUERUN_STORAGE_PROOF_DATABASE_URL="postgres://gluerun:gluerun@127.0.0.1:5432/gluerun" \
    gluerun_gate_red_external_proof_env_blocker "$log"; then
    fail "present real PostgreSQL env should leave gate-red eligible for rerun-tests"
  fi
}

test_strict_proof_skip_detected() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/storage_repository_test.go "[]"
  cat >>"$GLUERUN_TASKS_DIR/TASK-0001.md" <<'EOF'

The strict first test uses a real PostgreSQL-backed metadata store and no silent skip of the real-store proof.
EOF
  mkdir -p "$GLUERUN_ROOT/internal/artifact"
  cat >"$GLUERUN_ROOT/internal/artifact/storage_repository_test.go" <<'EOF'
package artifact

import "testing"

func TestProof(t *testing.T) {
	t.Skipf("missing PostgreSQL")
}
EOF
  gluerun_strict_proof_skip_detected "$GLUERUN_TASKS_DIR/TASK-0001.md" "$GLUERUN_ROOT" "internal/artifact/storage_repository_test.go" \
    || fail "strict proof task must reject t.Skipf in owned proof tests"
}

test_strict_proof_skip_ignored_for_nonproof_task() {
  with_fixture
  write_task TASK-0001 ready internal/artifact/storage_repository_test.go "[]"
  mkdir -p "$GLUERUN_ROOT/internal/artifact"
  cat >"$GLUERUN_ROOT/internal/artifact/storage_repository_test.go" <<'EOF'
package artifact

import "testing"

func TestFixture(t *testing.T) {
	t.Skip("fixture")
}
EOF
  if gluerun_strict_proof_skip_detected "$GLUERUN_TASKS_DIR/TASK-0001.md" "$GLUERUN_ROOT" "internal/artifact/storage_repository_test.go"; then
    fail "ordinary tasks are not strict proof tasks just because a test contains t.Skip"
  fi
}

make_planner_stub() {
  local stub="$1" mode="$2"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
mode="__MODE__"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message|-o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 2
python3 - "$out" "$mode" <<'PY'
import json
import sys

out, mode = sys.argv[1:3]

def markdown(task_id, title, owned, depends):
    return f"""# {task_id}: {title}

Status: ready
Area: artifact
Target branch: `target`
Worker branch: `agent/artifact/{task_id}-{title.lower()}`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: {depends}

## Objective

{title}.

## Scope

Owned files:

- `{owned}`

Forbidden files:

- Any file outside the owned scope unless an L1 scope amendment is recorded.

## Prerequisites

- D0.

## Acceptance Criteria

- Pass.
"""

first_dep = "TASK-0002" if mode == "internal_dep" else "[]"
data = {
    "schema": "gluerun.orchestration.task-batch.v0",
    "tasks": [
        {"taskId": "TASK-0001", "markdown": markdown("TASK-0001", "First", "internal/artifact/first.go", first_dep)},
        {"taskId": "TASK-0002", "markdown": markdown("TASK-0002", "Second", "internal/artifact/second.go", "[]")},
    ],
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
EOF
  python3 - "$stub" "$mode" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
path.write_text(path.read_text().replace("__MODE__", mode))
PY
  chmod +x "$stub"
}

test_generate_tasks_accepts_valid_batch() {
  with_fixture
  local stub="$GLUERUN_ROOT/planner-valid.sh"
  make_planner_stub "$stub" valid
  local out
  out="$(GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --count 2 2>&1)"
  assert_contains "$out" "generated:TASK-0001" "planner generated first task"
  assert_contains "$out" "generated:TASK-0002" "planner generated second task"
  [[ -f "$GLUERUN_TASKS_DIR/TASK-0001.md" && -f "$GLUERUN_TASKS_DIR/TASK-0002.md" ]] || fail "planner did not write batch task files"
}

test_generate_tasks_rejects_internal_dependency() {
  with_fixture
  local stub="$GLUERUN_ROOT/planner-internal-dep.sh"
  make_planner_stub "$stub" internal_dep
  local out
  out="$(GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --count 2 2>&1 || true)"
  assert_contains "$out" "planner-failed" "planner rejected internal dependency batch"
  [[ ! -f "$GLUERUN_TASKS_DIR/TASK-0001.md" ]] || fail "planner wrote invalid internal dependency batch"
}

test_scope_amendment_rejects_generated_cache_paths() {
  with_fixture
  local accepted=()
  local p
  while IFS= read -r p; do
    if gluerun_scope_amendment_path_allowed "$p"; then
      accepted+=("$p")
    fi
  done <<'EOF'
internal/artifact/real.go
.gluerun-cache/go-build/aa/cache-a
.gluerun-cache/go-build/testexpire.txt
.gluerun-state/runs/RUN/file.log
.gluerun-evidence/red.log
EOF
  assert_eq "internal/artifact/real.go" "${accepted[*]}" "scope amendment filters generated local cache/state/evidence paths"
}

write_minimal_worker_packet() {
  local path="$1" schema="$2"
  cat >"$path" <<EOF
{
  "schema": "$schema",
  "packetId": "RUN-PACKET",
  "runId": "RUN-PACKET",
  "taskId": "TASK-0001",
  "area": "artifact",
  "role": "l2-developer",
  "status": "needs-review",
  "baseRef": "target",
  "branch": "agent/artifact/TASK-0001-test",
  "headSha": "uncommitted",
  "workspace": "$GLUERUN_ROOT/.worktrees/TASK-0001",
  "ownedFiles": ["internal/artifact/a.go"],
  "changedFiles": ["internal/artifact/a.go"],
  "commands": [{"cmd": "true", "exitCode": 0, "logRef": "log"}],
  "tests": [{"name": "fixture", "phase": "green", "status": "passed", "logRef": "log"}],
  "evidence": [{"kind": "test", "ref": "log"}],
  "blockers": [],
  "nextAction": "await auditor verdict",
  "createdAt": "2026-06-02T00:00:00Z"
}
EOF
}

write_storage_proof_guard_task() {
  mkdir -p "$GLUERUN_TASKS_DIR"
  cat >"$GLUERUN_TASKS_DIR/TASK-0001.md" <<'EOF'
# TASK-0001: Durable storage proof fixture

Status: ready
Area: artifact
Target branch: `target`
Worker branch: `agent/artifact/TASK-0001-test`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Implement a bounded `D1.storage_proof` / `storage_proof` repository conformance round-trip proof.

## Scope

Owned files:

- `internal/artifact/a.go`

Forbidden files:

- `internal/artifact/doc.go`

## Acceptance Criteria

- Include marked nonzero red evidence for the storage-stripped real-store proof path.

## Required Evidence

- Failing targeted test output, including a marked nonzero `*-skip-guard-red` storage-proof command log.
EOF
}

mark_minimal_packet_with_storage_proof_guard() {
  local packet="$1"
  python3 - "$packet" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
ref = ".gluerun-evidence/TASK-0001-skip-guard-red"
data["commands"][0] = {
    "cmd": "env -u GLUERUN_STORAGE_PROOF_DATABASE_URL -u GLUERUN_DATABASE_URL go test ./internal/artifact -run TestStorageProof -count=1",
    "exitCode": 1,
    "logRef": ref,
}
data["tests"][0] = {
    "name": "storage proof env stripped",
    "phase": "red",
    "status": "failed-as-expected",
    "logRef": ref,
}
data["evidence"][0] = {"kind": "red-log", "ref": ref}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

test_l1_worker_packet_preflight_normalizes_legacy_schema_path() {
  with_fixture
  local msg="$GLUERUN_STATE_DIR/legacy-last-message.json"
  local packet="$GLUERUN_STATE_DIR/prepared-packet.json"
  local validation_log="$GLUERUN_STATE_DIR/preflight-validation.log"
  write_minimal_worker_packet "$msg" "schemas/orchestration/state-packet.v0.schema.json"

  gluerun_l1_prepare_worker_packet "$msg" "$packet" "$validation_log" \
    || fail "legacy schema-path packet should pass L1 worker preflight"

  assert_eq "gluerun.orchestration.state-packet.v0" \
    "$(json_field "$(cat "$packet")" schema)" \
    "L1 worker preflight normalizes legacy schema path"
  assert_contains "$(gluerun_validate_packet_basic "$packet")" "ok" \
    "normalized packet validates with strict import validator"
}

test_l1_worker_packet_preflight_reports_validation_errors() {
  with_fixture
  local msg="$GLUERUN_STATE_DIR/bad-schema-last-message.json"
  local packet="$GLUERUN_STATE_DIR/bad-schema-packet.json"
  local validation_log="$GLUERUN_STATE_DIR/bad-schema-validation.log"
  local rc=0
  write_minimal_worker_packet "$msg" "wrong-schema"

  gluerun_l1_prepare_worker_packet "$msg" "$packet" "$validation_log" || rc=$?

  assert_eq "12" "$rc" "invalid worker packet is classified as packet-invalid preflight"
  assert_contains "$(cat "$validation_log")" "unsupported schema: wrong-schema" \
    "invalid worker packet preserves validator error"
}

test_l1_worker_packet_preflight_reports_unknown_fields() {
  with_fixture
  local msg="$GLUERUN_STATE_DIR/unknown-field-last-message.json"
  local packet="$GLUERUN_STATE_DIR/unknown-field-packet.json"
  local validation_log="$GLUERUN_STATE_DIR/unknown-field-validation.log"
  local rc=0
  write_minimal_worker_packet "$msg" "gluerun.orchestration.state-packet.v0"
  python3 - "$msg" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["risks"] = ["non-schema worker note"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

  gluerun_l1_prepare_worker_packet "$msg" "$packet" "$validation_log" || rc=$?

  assert_eq "12" "$rc" "unknown top-level worker packet field is packet-invalid"
  assert_contains "$(cat "$validation_log")" "unknown fields: risks" \
    "unknown field worker packet preserves validator error"
}

test_storage_proof_packet_guard_rejects_unmarked_red_log() {
  with_fixture
  write_storage_proof_guard_task
  local packet="$GLUERUN_STATE_DIR/storage-proof-unmarked-packet.json"
  local worktree="$GLUERUN_ROOT/.worktrees/TASK-0001"
  local out rc=0
  write_minimal_worker_packet "$packet" "gluerun.orchestration.state-packet.v0"
  mkdir -p "$worktree/.gluerun-evidence"
  printf 'red failed\n' >"$worktree/.gluerun-evidence/red.log"

  out="$(gluerun_packet_module_guard "$packet" "$GLUERUN_TASKS_DIR/TASK-0001.md" "$worktree" "$GLUERUN_STATE_DIR/runs/RUN-PACKET" 2>&1)" || rc=$?

  [[ "$rc" -ne 0 ]] || fail "storage proof packet without marked red guard must be rejected"
  assert_contains "$out" "logRef ending in -skip-guard-red" \
    "storage proof guard explains missing marked red command"
}

test_storage_proof_packet_guard_accepts_marked_env_unset_red_log() {
  with_fixture
  write_storage_proof_guard_task
  local packet="$GLUERUN_STATE_DIR/storage-proof-marked-packet.json"
  local worktree="$GLUERUN_ROOT/.worktrees/TASK-0001"
  local ref=".gluerun-evidence/TASK-0001-skip-guard-red"
  write_minimal_worker_packet "$packet" "gluerun.orchestration.state-packet.v0"
  mark_minimal_packet_with_storage_proof_guard "$packet"
  mkdir -p "$worktree/.gluerun-evidence"
  printf 'real storage stripped failed\n' >"$worktree/$ref"

  gluerun_packet_module_guard "$packet" "$GLUERUN_TASKS_DIR/TASK-0001.md" "$worktree" "$GLUERUN_STATE_DIR/runs/RUN-PACKET" >/dev/null \
    || fail "storage proof packet with marked env-unset red guard should pass"
}

test_l2_worker_prompt_matches_state_packet_schema_fields() {
  local prompt
  prompt="$(cat "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md")"

  assert_not_contains "$prompt" "test evidence, risks," \
    "L2 worker prompt must not request non-schema top-level risks field"
  assert_contains "$prompt" "test evidence, blockers," \
    "L2 worker prompt names schema-supported packet fields"
  assert_contains "$prompt" "and next action. Do not add top-level fields outside the packet schema." \
    "L2 worker prompt forbids schema-extra top-level fields"
}

test_integrate_push_logs_sanitize_branch_names() {
  with_fixture
  git -C "$GLUERUN_ROOT" branch -m codex/gluerun-bootstrap-target
  export GLUERUN_TARGET_BRANCH="codex/gluerun-bootstrap-target"

  local origin="$GLUERUN_ROOT/../origin.git"
  git init --bare -q "$origin"
  git -C "$GLUERUN_ROOT" remote add origin "$origin"
  git -C "$GLUERUN_ROOT" push -q -u origin "$GLUERUN_TARGET_BRANCH"

  local branch="agent/artifact/TASK-0100-push-log"
  git -C "$GLUERUN_ROOT" checkout -q -b "$branch"
  mkdir -p "$GLUERUN_ROOT/internal/artifact"
  cat >"$GLUERUN_ROOT/internal/artifact/push_log_fixture.go" <<'EOF'
package artifact

const PushLogFixture = "ok"
EOF
  git -C "$GLUERUN_ROOT" add internal/artifact/push_log_fixture.go
  git -C "$GLUERUN_ROOT" -c user.name=test -c user.email=test@example.local commit -q -m "TASK-0100: push log fixture"
  local head
  head="$(git -C "$GLUERUN_ROOT" rev-parse HEAD)"
  git -C "$GLUERUN_ROOT" checkout -q "$GLUERUN_TARGET_BRANCH"

  local packet_dir="$GLUERUN_ORCH_DIR/packets/imported/TASK-0100"
  mkdir -p "$packet_dir"
  cat >"$packet_dir/RUN-PUSHLOG.json" <<EOF
{
  "schema": "gluerun.orchestration.state-packet.v0",
  "packetId": "RUN-PUSHLOG",
  "runId": "RUN-PUSHLOG",
  "taskId": "TASK-0100",
  "area": "artifact",
  "role": "l2",
  "status": "accepted",
  "baseRef": "$GLUERUN_TARGET_BRANCH",
  "branch": "$branch",
  "headSha": "$head",
  "workspace": "$GLUERUN_ROOT",
  "ownedFiles": ["internal/artifact/push_log_fixture.go"],
  "changedFiles": ["internal/artifact/push_log_fixture.go"],
  "commands": [{"cmd": "true", "exitCode": 0}],
  "tests": [{"name": "fixture", "phase": "regression", "status": "passed"}],
  "evidence": [{"kind": "test", "ref": "fixture"}],
  "blockers": [],
  "nextAction": "integrate",
  "createdAt": "2026-05-29T00:00:00Z"
}
EOF
  cat >"$packet_dir/RUN-PUSHLOG.audit.json" <<EOF
{
  "schema": "gluerun.orchestration.audit-verdict.v0",
  "taskId": "TASK-0100",
  "runId": "RUN-PUSHLOG",
  "branch": "$branch",
  "verdict": "accepted",
  "evidenceReviewed": ["fixture"],
  "commandsRun": ["true"],
  "findings": [],
  "requiredFixes": [],
  "rationale": "fixture accepted"
}
EOF

  local out run_dir
  out="$(GLUERUN_DEFAULT_GATE_CMD=true GLUERUN_PUSH=1 "$SCRIPT_DIR/integrate.sh" --task TASK-0100 --run-id RUN-PUSHLOG 2>&1)"
  assert_contains "$out" "pushed codex/gluerun-bootstrap-target -> origin" "target branch pushed with slash name"
  assert_contains "$out" "pushed agent/artifact/TASK-0100-push-log -> origin" "worker branch pushed with slash name"

  run_dir="$GLUERUN_RUNS_DIR/RUN-PUSHLOG"
  [[ -f "$run_dir/secret-scan-push-codex__gluerun-bootstrap-target.log" ]] || fail "missing sanitized target push scan log"
  [[ -f "$run_dir/secret-scan-push-agent__artifact__TASK-0100-push-log.log" ]] || fail "missing sanitized worker push scan log"
  [[ ! -d "$run_dir/secret-scan-push-codex" ]] || fail "target push scan log used branch slash as directory"
  [[ ! -d "$run_dir/secret-scan-push-agent" ]] || fail "worker push scan log used branch slash as directory"
}

test_task_parser_metadata
test_frontier_selection
test_frontier_selection_allows_shared_forbidden_files
test_frontier_selection_allows_shared_forbidden_file_with_active_lease
test_frontier_selection_allows_requeued_task_with_failed_lease
test_reconcile_parallel_batch_with_stub
test_reconcile_parallel_batch_with_shared_forbidden_file
test_reconcile_counts_failed_child
test_codex_run_l2_defaults_to_workspace_write_sandbox
test_codex_run_l2_uses_medium_reasoning_without_service_tier
test_codex_run_readonly_planner_uses_xhigh_reasoning
test_codex_run_readonly_auditor_uses_high_reasoning
test_codex_run_l2_allows_explicit_sandbox_override
test_codex_run_l2_rejects_invalid_sandbox_override
test_gate_red_external_proof_env_blocker_detected
test_gate_red_external_proof_env_blocker_ignored_when_env_present
test_strict_proof_skip_detected
test_strict_proof_skip_ignored_for_nonproof_task
test_generate_tasks_accepts_valid_batch
test_generate_tasks_rejects_internal_dependency
test_scope_amendment_rejects_generated_cache_paths
test_l1_worker_packet_preflight_normalizes_legacy_schema_path
test_l1_worker_packet_preflight_reports_validation_errors
test_l1_worker_packet_preflight_reports_unknown_fields
test_storage_proof_packet_guard_rejects_unmarked_red_log
test_storage_proof_packet_guard_accepts_marked_env_unset_red_log
test_l2_worker_prompt_matches_state_packet_schema_fields
test_integrate_push_logs_sanitize_branch_names

echo "dynamic dispatch tests passed"
