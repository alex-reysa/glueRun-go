#!/usr/bin/env bash
set -euo pipefail

# P3 (0.5.0): a node whose tasks are all integrated but whose gate is
# unpublished is NOT re-planned (planner-suppressed, exit 0, no failure);
# with the knob off, planning proceeds. 0.4.0 kept minting duplicate tasks
# for such nodes until an operator manually promoted the gate.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-planner-suppression.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/gates" "$root/docs/orchestration/prompts" \
  "$root/docs/orchestration/tasks" "$root/schemas/orchestration" "$root/.gluerun-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$root/docs/orchestration/prompts/"
cp "$ENGINE_HOME/schemas/task-batch.v0.schema.json" "$root/schemas/orchestration/"
cp "$ENGINE_HOME/schemas/dag.v0.schema.json" "$root/schemas/orchestration/"
cp "$ENGINE_HOME/schemas/gate-result.v0.schema.json" "$root/schemas/orchestration/"
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "gluerun.orchestration.dag.v0",
  "nodes": [
    { "id": "S0.base", "stage": "S0", "area": "storage", "layer": "substrate", "kind": "substrate", "dependsOn": [], "requiredCompletion": "ready" }
  ]
}
EOF
# One INTEGRATED task attributed to the node; no gate file -> pending promotion.
cat >"$root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: done work

Status: integrated
Area: storage
DAG node: S0.base
Dispatch mode: canonical
Depends on: []

## Objective

Landed substrate work.

## Scope

Owned files:

- `internal/storage/base.go`
EOF
git -C "$root" add . && git -C "$root" -c user.name=t -c user.email=t@t commit -q -m init

# Stub codex: MUST NOT be called when suppressed.
stub="$tmp/codex-marker.sh"
marker="$tmp/codex-called"
cat >"$stub" <<SH
#!/usr/bin/env bash
touch "$marker"
echo '{"schema":"gluerun.orchestration.task-batch.v0","tasks":[]}'
SH
chmod +x "$stub"

gen_env() {
  env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
    GLUERUN_ORCH_DIR="$root/docs/orchestration" GLUERUN_TASKS_DIR="$root/docs/orchestration/tasks" \
    GLUERUN_RUNS_DIR="$root/.gluerun-state/runs" \
    GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson" \
    GLUERUN_TARGET_BRANCH=target \
    GLUERUN_TASKBATCH_SCHEMA="$root/schemas/orchestration/task-batch.v0.schema.json" \
    GLUERUN_CODEX_RUNNER="$stub" "$@"
}

# 1. Suppressed: exit 0, no codex call, distinct event.
rc=0
out="$(gen_env "$SCRIPT_DIR/generate-tasks.sh" --node S0.base --count 1 2>&1)" || rc=$?
assert_contains "$out" "planner-suppressed (pending-promotion node=S0.base)" "suppression reported ($out)"
[[ "$rc" -eq 0 ]] || fail "suppression must exit 0 (rc=$rc)"
[[ -f "$marker" ]] && fail "codex must not be called for a pending-promotion node"
assert_contains "$(cat "$root/.gluerun-state/events.ndjson")" '"type":"planner.suppressed_pending_promotion"' "suppression event"
assert_not_contains "$out" "planner-failed" "not a failure"

# 2. A published FAILED gate means promotion was attempted and refused: the
#    node needs more work and must be plannable again (suppressing here would
#    deadlock an all-integrated node behind a red gate).
cat >"$root/docs/orchestration/gates/S0.base.gate-result.json" <<'EOF'
{"schema":"gluerun.orchestration.gate-result.v0","node":"S0.base","status":"failed","authoritative":true,"evidenceClass":"grandfathered","evidence":[{"kind":"source-path","ref":"internal/storage","description":"t"}],"decidedBy":"test","recordedAt":"2026-06-01T00:00:00Z"}
EOF
rc=0
out="$(gen_env "$SCRIPT_DIR/generate-tasks.sh" --node S0.base --count 1 2>&1)" || rc=$?
[[ -f "$marker" ]] || fail "planner must run once a failed gate is published ($out)"
rm -f "$marker" "$root/docs/orchestration/gates/S0.base.gate-result.json"

# 3. Knob off: planning proceeds even while pending promotion.
rc=0
out="$(gen_env env GLUERUN_SUPPRESS_UNPROMOTED_REPLAN=0 "$SCRIPT_DIR/generate-tasks.sh" --node S0.base --count 1 2>&1)" || rc=$?
[[ -f "$marker" ]] || fail "knob off must restore planning ($out)"

echo "PASS: test-planner-suppression"
