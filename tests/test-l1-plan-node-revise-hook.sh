#!/usr/bin/env bash
# Covers the single sanctioned call-site of the plan-revision-loop node
# (stage S3-plan-revision, area plancritic, layer engine_runtime): the default-OFF
# SINGULAR_PLAN_CRITIQUE=1 hook in engine/l1-plan-node.sh that, in the EXISTING
# staging-success branch, delegates to the integrated bounded revise -> (resume|
# fresh) -> re-critique -> approve/park orchestrator singular_plan_revise_loop
# and routes its single terminal outcome:
#   import       -> today's behavior (candidates left staged, node lease left
#                   active, print planned:<node>, exit 0, so L0 stays the sole
#                   importer);
#   park <reason> -> node lease set failed + plan-failed printed + non-zero exit,
#                   so unapproved candidates never reach L0.
#
# Cases:
#   (OFF)  flag unset / =0 -> the orchestrator is NEVER invoked (no critic run,
#          no plan-critique.json, no revision events) and the driver output /
#          exit code / lease status are byte-identical to the pre-hook staging-
#          success path (planned:<node>, exit 0, lease active).
#   (import) flag ON + orchestrator returns import (approve verdict) ->
#          planned:<node>, exit 0, lease active, and the orchestrator WAS invoked
#          (critic marker present).
#   (park) flag ON + orchestrator returns park (explicit park verdict) ->
#          lease set failed, plan-failed printed, non-zero exit, candidates NOT
#          imported (L0 never sees them; the driver leaves the global tasks dir
#          untouched here as always).
#
# Fully hermetic: a STUB planner via SINGULAR_L1_PLANNER stages a candidate, and a
# STUB critic via SINGULAR_RUNNER (consumed by the integrated critic driver the
# orchestrator calls) fixes the verdict, so no real runner is ever invoked.
# Everything runs in an isolated SINGULAR_ROOT/SINGULAR_STATE_DIR.
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-l1-plan-node-revise-hook.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Hermetic guard: scrub any inherited SINGULAR_* env so a leaked runner/root from
# a real drive cannot poison the sandbox.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

NODE="plan-revision-loop"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
REPO="$tmp/repo"
mkdir -p "$REPO/docs/orchestration/prompts" "$REPO/docs/orchestration/tasks" \
  "$REPO/schemas/orchestration" "$REPO/.singular-state"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$REPO/docs/orchestration/prompts/l1-planner.md"
# Base plan-critic prompt the integrated critic driver hands to its runner.
printf '# Plan Critic Prompt\n' > "$REPO/docs/orchestration/prompts/plan-critic.md"
cp "$ENGINE_HOME/schemas/task-batch.v0.schema.json" "$REPO/schemas/orchestration/task-batch.v0.schema.json"
cp "$ENGINE_HOME/schemas/dag.v0.schema.json" "$REPO/schemas/orchestration/dag.v0.schema.json"
cp "$ENGINE_HOME/schemas/l1-lease.v0.schema.json" "$REPO/schemas/orchestration/l1-lease.v0.schema.json"
cp "$ENGINE_HOME/schemas/gate-result.v0.schema.json" "$REPO/schemas/orchestration/gate-result.v0.schema.json"
cat >"$REPO/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "singular.orchestration.dag.v0",
  "layers": ["engine_runtime"],
  "kinds": ["runtime"],
  "nodes": [
    {
      "id": "plan-revision-loop",
      "stage": "S3-plan-revision",
      "area": "plancritic",
      "layer": "engine_runtime",
      "kind": "runtime",
      "dependsOn": [],
      "requiredCompletion": "plan_revision_loop_wired"
    }
  ]
}
EOF
git -C "$REPO" add .
git -C "$REPO" -c user.name=test -c user.email=test@example.local commit -q -m init

export SINGULAR_ROOT="$REPO"
export SINGULAR_STATE_DIR="$REPO/.singular-state"
export SINGULAR_ORCH_DIR="$REPO/docs/orchestration"
export SINGULAR_TARGET_BRANCH="target"
export SINGULAR_L1_LEASES_DIR="$SINGULAR_STATE_DIR/l1-leases"
export SINGULAR_PLAN_REVISE_MAX=1

# --- STUB planner (SINGULAR_L1_PLANNER) ---------------------------------------
# Stands in for generate-tasks.sh staged mode: writes one *.candidate.md into the
# node's --stage-dir and exits 0 (the existing staging-success precondition).
PLANNER="$tmp/stub-planner.sh"
cat > "$PLANNER" <<'PEOF'
#!/usr/bin/env bash
set -uo pipefail
stage=""; args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in --stage-dir) stage="${args[$((i + 1))]}" ;; esac
  i=$((i + 1))
done
[[ -n "$stage" ]] || exit 2
mkdir -p "$stage"
cat > "$stage/TASK-0001.candidate.md" <<'MD'
# TASK-0001: staged candidate

Status: ready
Area: plancritic
Target branch: `target`
Worker branch: `agent/plancritic/TASK-0001-staged`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Staged stub.

## Scope

Owned files:

- `engine/staged.sh`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Pass.
MD
exit 0
PEOF
chmod +x "$PLANNER"
export SINGULAR_L1_PLANNER="$PLANNER"

# --- STUB critic (SINGULAR_RUNNER) --------------------------------------------
# The integrated critic driver the orchestrator invokes reaches its runner via
# SINGULAR_RUNNER. This stub records that it ran (CRITIC_MARKER) and writes a
# plan-critique.v0 record fixing the verdict to CRITIC_VERDICT.
CRITIC="$tmp/stub-critic.sh"
cat > "$CRITIC" <<'CEOF'
#!/usr/bin/env bash
set -uo pipefail
[[ -n "${CRITIC_MARKER:-}" ]] && : > "$CRITIC_MARKER"
out=""; args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  [[ "${args[$i]}" == "--output-last-message" ]] && out="${args[$((i + 1))]}"
  i=$((i + 1))
done
[[ -n "$out" ]] || exit 0
cat > "$out" <<JSON
Here is my critique:
{
  "schema": "singular.orchestration.plan-critique.v0",
  "node": "STUB",
  "runId": "STUB",
  "batchTaskIds": ["TASK-9999"],
  "verdict": "${CRITIC_VERDICT:-approve}",
  "findings": [
    {"severity": "blocking", "claim": "finding one", "evidence": "ev-one"}
  ],
  "assumptionsChallenged": [],
  "rationale": "stub critic rationale"
}
JSON
exit 0
CEOF
chmod +x "$CRITIC"

# --- helpers -----------------------------------------------------------------
lease_status() {
  local lease="$SINGULAR_L1_LEASES_DIR/$NODE.json"
  [[ -f "$lease" ]] || { echo ""; return 0; }
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status",""))' "$lease"
}

# Drive the REAL l1-plan-node.sh in a subprocess. Leading VAR=val args go to its
# environment; prints the driver stdout, sets RC.
run_plan_node() {
  local sdir="$1"; shift
  RC=0
  OUT="$(env SINGULAR_ROOT="$REPO" SINGULAR_STATE_DIR="$SINGULAR_STATE_DIR" \
    SINGULAR_ORCH_DIR="$SINGULAR_ORCH_DIR" SINGULAR_TARGET_BRANCH=target \
    SINGULAR_L1_LEASES_DIR="$SINGULAR_L1_LEASES_DIR" \
    SINGULAR_L1_PLANNER="$PLANNER" SINGULAR_PLAN_REVISE_MAX=1 \
    "$@" "$SCRIPT_DIR/l1-plan-node.sh" \
      --node "$NODE" --run-id RUN-hook --stage-dir "$sdir" 2>/dev/null)" || RC=$?
}

# ---------------------------------------------------------------------------
# (OFF) flag unset -> hook inert, byte-identical to the pre-hook success path.
# ---------------------------------------------------------------------------
sd_off="$tmp/stage-off"
marker_off="$tmp/critic-off"
# SINGULAR_PLAN_CRITIQUE explicit 0: as of 0.20.0 it defaults to 1, so an unset
# knob runs the critique/revise hook and this stops being the OFF path.
run_plan_node "$sd_off" SINGULAR_PLAN_CRITIQUE=0 SINGULAR_RUNNER="$CRITIC" CRITIC_MARKER="$marker_off" CRITIC_VERDICT=park
assert_eq "$RC" "0" "OFF: staging-success path exits 0"
assert_eq "$OUT" "planned:$NODE" "OFF: prints planned:<node>"
assert_eq "$(lease_status)" "active" "OFF: node lease left active"
[[ ! -e "$marker_off" ]] || fail "OFF: critic runner invoked (orchestrator must be inert)"
[[ ! -e "$sd_off/plan-critique.json" ]] || fail "OFF: plan-critique.json written while flag off"
if [[ -f "$sd_off/planner-events.ndjson" ]]; then
  ! grep -q '"type":"plan.critiqued"' "$sd_off/planner-events.ndjson" \
    || fail "OFF: a plan.critiqued revision event was emitted while flag off"
fi
echo "PASS: (OFF) hook inert, byte-identical staging-success path"

# Explicit =0 behaves identically.
sd_off0="$tmp/stage-off0"
marker_off0="$tmp/critic-off0"
run_plan_node "$sd_off0" SINGULAR_PLAN_CRITIQUE=0 SINGULAR_RUNNER="$CRITIC" \
  CRITIC_MARKER="$marker_off0" CRITIC_VERDICT=park
assert_eq "$RC" "0" "OFF(=0): exits 0"
assert_eq "$OUT" "planned:$NODE" "OFF(=0): prints planned:<node>"
assert_eq "$(lease_status)" "active" "OFF(=0): node lease left active"
[[ ! -e "$marker_off0" ]] || fail "OFF(=0): orchestrator invoked while flag =0"
echo "PASS: (OFF=0) hook inert"

# ---------------------------------------------------------------------------
# (import) flag ON + approve verdict -> planned:<node>, exit 0, lease active,
# orchestrator invoked.
# ---------------------------------------------------------------------------
rm -f "$SINGULAR_L1_LEASES_DIR/$NODE.json"
sd_imp="$tmp/stage-import"
marker_imp="$tmp/critic-import"
run_plan_node "$sd_imp" SINGULAR_PLAN_CRITIQUE=1 SINGULAR_RUNNER="$CRITIC" \
  CRITIC_MARKER="$marker_imp" CRITIC_VERDICT=approve
assert_eq "$RC" "0" "import: approve routes to import, exit 0"
assert_eq "$OUT" "planned:$NODE" "import: prints planned:<node>"
assert_eq "$(lease_status)" "active" "import: node lease left active for L0"
[[ -e "$marker_imp" ]] || fail "import: orchestrator (critic) was never invoked under the flag"
echo "PASS: (import) approve -> planned:<node>, exit 0, lease active"

# ---------------------------------------------------------------------------
# (park) flag ON + park verdict -> lease failed, plan-failed, non-zero exit.
# ---------------------------------------------------------------------------
rm -f "$SINGULAR_L1_LEASES_DIR/$NODE.json"
sd_park="$tmp/stage-park"
marker_park="$tmp/critic-park"
run_plan_node "$sd_park" SINGULAR_PLAN_CRITIQUE=1 SINGULAR_RUNNER="$CRITIC" \
  CRITIC_MARKER="$marker_park" CRITIC_VERDICT=park
[[ "$RC" -ne 0 ]] || fail "park: a non-approve terminal must exit non-zero"
assert_contains "$OUT" "plan-failed:$NODE" "park: prints plan-failed:<node>"
assert_eq "$(lease_status)" "failed" "park: node lease set failed"
[[ -e "$marker_park" ]] || fail "park: orchestrator was never invoked under the flag"
echo "PASS: (park) park -> lease failed, plan-failed, non-zero exit"

echo "l1-plan-node revise-hook tests passed"
