#!/usr/bin/env bash
set -euo pipefail

# E8 (0.5.0): a schema-valid EMPTY planner batch ({"tasks": []}) is a
# legitimate no-op — planner.no_tasks event, exit 0, no backoff, no planner
# failure, and the importer releases the node lease without a rejection.
# 0.4.0 classified it invalid-output, feeding the false-quota chokepoint.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-generate-tasks-empty-batch.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

export GLUERUN_ROOT="$(mktemp -d)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$GLUERUN_ROOT"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/gates" "$root/docs/orchestration/prompts" \
  "$root/docs/orchestration/tasks" "$root/schemas/orchestration" "$root/.gluerun-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$root/docs/orchestration/prompts/"
cp "$ENGINE_HOME/schemas/task-batch.v0.schema.json" "$root/schemas/orchestration/"
cp "$ENGINE_HOME/schemas/dag.v0.schema.json" "$root/schemas/orchestration/"
cp "$ENGINE_HOME/schemas/gate-result.v0.schema.json" "$root/schemas/orchestration/"
cp "$ENGINE_HOME/schemas/l1-lease.v0.schema.json" "$root/schemas/orchestration/"
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "gluerun.orchestration.dag.v0",
  "nodes": [
    { "id": "S0.base", "stage": "S0", "area": "storage", "layer": "substrate", "kind": "substrate", "dependsOn": [], "requiredCompletion": "ready" }
  ]
}
EOF
git -C "$root" add . && git -C "$root" -c user.name=t -c user.email=t@t commit -q -m init

export GLUERUN_ROOT="$root"
export GLUERUN_ORCH_DIR="$root/docs/orchestration"
export GLUERUN_TASKS_DIR="$GLUERUN_ORCH_DIR/tasks"
export GLUERUN_STATE_DIR="$root/.gluerun-state"
export GLUERUN_RUNS_DIR="$GLUERUN_STATE_DIR/runs"
export GLUERUN_LEASES_DIR="$GLUERUN_STATE_DIR/leases"
export GLUERUN_L1_LEASES_DIR="$GLUERUN_STATE_DIR/l1-leases"
export GLUERUN_EVENTS_FILE="$GLUERUN_STATE_DIR/events.ndjson"
export GLUERUN_TARGET_BRANCH=target
export GLUERUN_TASKBATCH_SCHEMA="$root/schemas/orchestration/task-batch.v0.schema.json"

# Fake codex emitting a schema-valid empty batch.
stub="$tmp/codex-empty.sh"
cat >"$stub" <<'SH'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in --output-last-message) out="$2"; shift 2 ;; *) shift ;; esac
done
body='{"schema":"gluerun.orchestration.task-batch.v0","tasks":[]}'
[[ -n "$out" ]] && printf '%s\n' "$body" >"$out"
printf '%s\n' "$body"
SH
chmod +x "$stub"

# 1. Staged mode: rc 0, NO-TASKS marker, planner.no_tasks event, no failure.
sdir="$GLUERUN_STATE_DIR/runs/RUN-E/l1-staging/S0.base"
rc=0
out="$(GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --node S0.base --stage-dir "$sdir" --count 2 2>&1)" || rc=$?
assert_contains "$out" "planner-no-tasks" "no-tasks reported ($out)"
[[ "$rc" -eq 0 ]] || fail "empty batch must exit 0 (rc=$rc)"
[[ -f "$sdir/NO-TASKS" ]] || fail "NO-TASKS marker missing"
events="$(cat "$GLUERUN_EVENTS_FILE" 2>/dev/null || true; cat "$sdir/planner-events.ndjson" 2>/dev/null || true)"
assert_contains "$out$events" "no_tasks" "no_tasks event/marker present"
assert_not_contains "$out" "planner-failed" "must not be a planner failure"
[[ -f "$GLUERUN_STATE_DIR/planner-backoff.json" ]] && fail "empty batch must not arm a backoff"

# 2. Importer over the NO-TASKS node: lease released, no rejection.
gluerun_l1_lease_write S0.base storage S0 substrate active RUN-E "$(git -C "$root" rev-parse target)" target
out="$(gluerun_l1_import_staged RUN-E S0.base 2>&1)"
assert_contains "$out" "no-tasks:S0.base" "importer reports no-tasks"
assert_contains "$out" "l1_import_rejections=0" "no rejection counted"
[[ -f "$GLUERUN_L1_LEASES_DIR/S0.base.json" ]] && fail "node lease must be released"
assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"type":"origin.l1_no_tasks"' "importer event"

# 3. Regression: a batch with a malformed item still fails as invalid-output.
cat >"$stub" <<'SH'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in --output-last-message) out="$2"; shift 2 ;; *) shift ;; esac
done
body='{"schema":"gluerun.orchestration.task-batch.v0","tasks":[{"bogus":true}]}'
[[ -n "$out" ]] && printf '%s\n' "$body" >"$out"
printf '%s\n' "$body"
SH
chmod +x "$stub"
rc=0
out="$(GLUERUN_CODEX_RUNNER="$stub" "$SCRIPT_DIR/generate-tasks.sh" --node S0.base --stage-dir "$GLUERUN_STATE_DIR/runs/RUN-F/l1-staging/S0.base" --count 2 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "malformed batch must still fail"
assert_contains "$out" "planner-failed" "malformed batch reported as failure"

echo "PASS: test-generate-tasks-empty-batch"
