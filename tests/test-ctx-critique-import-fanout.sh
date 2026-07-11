#!/usr/bin/env bash
set -uo pipefail

# Covers the critique-aware L1 import fanout orchestrator
# engine/ctx-critique-import-fanout.sh: a drop-in vehicle mirroring the shape of
# gluerun_l1_fanout (same two args, same l1_planner_failures= / l1_import_rejections=
# summary lines) that composes the integrated pieces so the import path can honor
# the plan critic verdict WITHOUT modifying engine/lib.sh.
#
#   - It reuses gluerun_select_l1_frontier, the planner driver, the integrated
#     plan-critic context assembler + critic driver, the integrated critique-import
#     gate DISPOSITION, and the integrated gluerun_l1_import_staged importer.
#   - Observe-only (GLUERUN_PLAN_CRITIQUE=0/unset): every staged node is imported
#     (imported set == plain fanout) while each node still gets a persisted
#     plan-critique.json + a plan.critiqued event.
#   - ON (GLUERUN_PLAN_CRITIQUE=1): approve -> imported; revise / park -> withheld,
#     each recording exactly one origin.l1_import_rejected event with reason
#     plan-critique and setting the node lease to failed.
#   - Withheld nodes are counted in the l1_import_rejections= summary line.
#   - present-but-uncalled: no existing engine path invokes the new function and
#     engine/reconcile.sh still calls gluerun_l1_fanout.
#
# Pure bash + fixtures; NO real runner (the planner driver and the default critic
# runner are stubbed). Modelled on tests/test-l1-parallel.sh's real-DAG fixture.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-critique-import-fanout.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
CTX_FANOUT="$SCRIPT_DIR/ctx-critique-import-fanout.sh"

# Hermetic guard: source lib.sh against a pristine empty root so no docked
# consumer config leaks into test sandboxes; each test exports its own root.
export GLUERUN_ROOT="$(mktemp -d)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

# --- RED gate: the engine file must exist and define the orchestrator ---------
[[ -f "$CTX_FANOUT" ]] || fail "engine not present yet: $CTX_FANOUT"
# lib.sh auto-sources it; source again defensively.
# shellcheck source=/dev/null
source "$CTX_FANOUT" || fail "sourcing $CTX_FANOUT failed"
[[ "$(type -t gluerun_ctx_critique_import_fanout)" == "function" ]] \
  || fail "gluerun_ctx_critique_import_fanout not defined by $CTX_FANOUT"
# The orchestrator MUST compose the already-integrated pieces, never re-derive them.
for fn in gluerun_select_l1_frontier gluerun_l1_import_staged \
          gluerun_ctx_plan_critic_context gluerun_ctx_plan_critic_run \
          gluerun_ctx_critique_import_gate; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "integrated dependency $fn not available"
done

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/gates" \
    "$root/docs/orchestration/prompts" \
    "$root/docs/orchestration/tasks" \
    "$root/schemas/orchestration" \
    "$root/.gluerun-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$root/docs/orchestration/prompts/l1-planner.md"
  cp "$ENGINE_HOME/templates/prompts/plan-critic.md" "$root/docs/orchestration/prompts/plan-critic.md"
  cp "$ENGINE_HOME/schemas/task-batch.v0.schema.json" "$root/schemas/orchestration/task-batch.v0.schema.json"
  cp "$ENGINE_HOME/schemas/dag.v0.schema.json" "$root/schemas/orchestration/dag.v0.schema.json"
  cp "$ENGINE_HOME/schemas/gate-result.v0.schema.json" "$root/schemas/orchestration/gate-result.v0.schema.json"
  cp "$ENGINE_HOME/schemas/l1-lease.v0.schema.json" "$root/schemas/orchestration/l1-lease.v0.schema.json"
  cp "$ENGINE_HOME/schemas/plan-critique.v0.schema.json" "$root/schemas/orchestration/plan-critique.v0.schema.json"
  # Two independent ready nodes (disjoint areas): D1.contract (artifact) and
  # S0.substrate_base (storage). D1.proof is NOT ready.
  cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "gluerun.orchestration.dag.v0",
  "nodes": [
    { "id": "D0.contract", "stage": "D0", "area": "kernel", "layer": "contract", "kind": "contract", "dependsOn": [], "requiredCompletion": "contract_complete" },
    { "id": "D1.contract", "stage": "D1", "area": "artifact", "layer": "contract", "kind": "contract", "dependsOn": ["D0.contract"], "requiredCompletion": "contract_complete" },
    { "id": "S0.substrate_base", "stage": "S0", "area": "storage", "layer": "substrate_base", "kind": "substrate", "dependsOn": ["D0.contract"], "requiredCompletion": "substrate_ready" },
    { "id": "D1.proof", "stage": "D1", "area": "artifact", "layer": "proof", "kind": "storage", "dependsOn": ["D1.contract", "S0.substrate_base"], "requiredCompletion": "proof_complete" }
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
  "evidence": [ { "kind": "source-path", "ref": "internal/kernel", "description": "test gate" } ],
  "decidedBy": "test",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
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
  export GLUERUN_RUNS_DIR="$GLUERUN_STATE_DIR/runs"
  export GLUERUN_LEASES_DIR="$GLUERUN_STATE_DIR/leases"
  export GLUERUN_EVENTS_FILE="$GLUERUN_STATE_DIR/events.ndjson"
  export GLUERUN_STOP_FILE="$GLUERUN_STATE_DIR/STOP"
  export GLUERUN_TARGET_BRANCH="target"
  export GLUERUN_L1_LEASES_DIR="$GLUERUN_STATE_DIR/l1-leases"
  export GLUERUN_L1_LEASE_SCHEMA="$GLUERUN_ROOT/schemas/orchestration/l1-lease.v0.schema.json"
  export GLUERUN_GATE_SCHEMA="$GLUERUN_ROOT/schemas/orchestration/gate-result.v0.schema.json"
  export GLUERUN_PLAN_CRITIQUE_SCHEMA="$GLUERUN_ROOT/schemas/orchestration/plan-critique.v0.schema.json"
  export GLUERUN_REAL_SCRIPT_DIR="$SCRIPT_DIR"
  export GLUERUN_MAX_L1_CONCURRENT=2
  export GLUERUN_L1_TASKS_PER_NODE=1
  export GLUERUN_MIN_DISK_GB=0
  # Per-node critic verdicts live in this dir (keyed by node name); the critic
  # stub reads <node> from the stage-dir path it is pointed at.
  export GLUERUN_TEST_VERDICT_DIR="$GLUERUN_STATE_DIR/verdicts"
  mkdir -p "$GLUERUN_TEST_VERDICT_DIR"
  # The critic stub appends every *.candidate.md it sees mid-flight (after staging,
  # before import) so the test can prove staging paths directly.
  export GLUERUN_TEST_STAGE_OBSERVE="$GLUERUN_STATE_DIR/stage-observed.txt"
  : > "$GLUERUN_TEST_STAGE_OBSERVE"
  unset GLUERUN_PLAN_CRITIQUE GLUERUN_L1_PLAN_NODE GLUERUN_RUNNER GLUERUN_TEST_FAIL_NODE 2>/dev/null || true
}

# A drop-in l1-plan-node stub: creates the node's active lease (real DAG area) and
# stages one valid canonical candidate (mirrors tests/test-l1-parallel.sh).
make_plan_stub() {
  cat >"$1" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
source "$GLUERUN_REAL_SCRIPT_DIR/lib.sh"
node=""; run_id=""; stage_dir=""; base_sha=""; count=1
while [[ $# -gt 0 ]]; do case "$1" in
  --node) node="$2"; shift 2;; --run-id) run_id="$2"; shift 2;;
  --stage-dir) stage_dir="$2"; shift 2;; --base-sha) base_sha="$2"; shift 2;;
  --count) count="$2"; shift 2;; *) shift;; esac; done
export GLUERUN_EVENTS_FILE="$stage_dir/planner-events.ndjson"
mkdir -p "$stage_dir"
fields="$("$GLUERUN_REAL_SCRIPT_DIR/dag.sh" node-fields "$node")" || { echo "plan-failed:$node"; exit 1; }
area="$(printf '%s\n' "$fields" | sed -n 's/^area=//p' | tail -1)"
stage="$(printf '%s\n' "$fields" | sed -n 's/^stage=//p' | tail -1)"
layer="$(printf '%s\n' "$fields" | sed -n 's/^layer=//p' | tail -1)"
[[ -n "$base_sha" ]] || base_sha="$(git -C "$GLUERUN_ROOT" rev-parse "$GLUERUN_TARGET_BRANCH")"
gluerun_l1_lease_write "$node" "$area" "$stage" "$layer" active "$run_id" "$base_sha" "$GLUERUN_TARGET_BRANCH"
if [[ "${GLUERUN_TEST_FAIL_NODE:-}" == "$node" ]]; then
  gluerun_l1_lease_set_status "$node" failed || true
  echo "plan-failed:$node"; exit 1
fi
safe="${node//[^A-Za-z0-9]/_}"
cat >"$stage_dir/TASK-0001.candidate.md" <<EOF
# TASK-0001: Staged fixture $node

Status: ready
Area: $area
Target branch: \`$GLUERUN_TARGET_BRANCH\`
Worker branch: \`agent/$area/TASK-0001-staged-$safe\`
Test policy: \`strict_test_first\`
Gate command: \`true\`
Dispatch mode: canonical
Depends on: []

## Objective

Staged stub for $node.

## Scope

Owned files:

- \`internal/$area/staged_$safe.go\`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Pass.
EOF
echo "planned:$node"
STUB
  chmod +x "$1"
}

# A default-runner (critic) stub: writes a plan-critique-shaped JSON to the
# --output-last-message path with the per-node verdict, and records the staged
# candidate set it observes mid-flight.
make_critic_stub() {
  cat >"$1" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
out=""
while [[ $# -gt 0 ]]; do case "$1" in
  --output-last-message) out="$2"; shift 2;;
  *) shift;; esac; done
[[ -n "$out" ]] || exit 2
stage_dir="$(dirname "$out")"
node="$(basename "$stage_dir")"
# Prove staging paths: record every candidate present at critic time.
if [[ -n "${GLUERUN_TEST_STAGE_OBSERVE:-}" ]]; then
  for c in "$stage_dir"/*.candidate.md; do
    [[ -e "$c" ]] || continue
    printf '%s\n' "$c" >> "$GLUERUN_TEST_STAGE_OBSERVE"
  done
fi
verdict="approve"
vf="${GLUERUN_TEST_VERDICT_DIR:-}/$node"
[[ -n "${GLUERUN_TEST_VERDICT_DIR:-}" && -f "$vf" ]] && verdict="$(cat "$vf")"
cat >"$out" <<EOF
{"verdict":"$verdict","findings":[],"assumptionsChallenged":[],"rationale":"stub critic verdict for $node"}
EOF
exit 0
STUB
  chmod +x "$1"
}

task_count() { find "$GLUERUN_TASKS_DIR" -maxdepth 1 -name 'TASK-*.md' -type f 2>/dev/null | wc -l | tr -d ' '; }
events_count() { grep -c "$1" "$GLUERUN_EVENTS_FILE" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Staging parity + observe-only equivalence: every staged node imports, imported
# set equals a plain fanout, each node still gets plan-critique.json + a
# plan.critiqued event, and the summary lines match the caller contract.
# ---------------------------------------------------------------------------
test_observe_only_equivalent_to_plain_fanout() {
  with_fixture
  local plan="$GLUERUN_ROOT/plan-stub.sh"; make_plan_stub "$plan"
  local critic="$GLUERUN_ROOT/critic-stub.sh"; make_critic_stub "$critic"
  local base; base="$(git -C "$GLUERUN_ROOT" rev-parse target)"

  # Reference: plain fanout imports both nodes as TASK-0001 / TASK-0002.
  local ref
  ref="$(GLUERUN_L1_PLAN_NODE="$plan" gluerun_l1_fanout RUN-plain "$base" 2>&1)"
  assert_eq "$(printf '%s\n' "$ref" | grep -c '^generated:')" "2" "plain fanout imports both nodes"

  # Fresh fixture so ids restart from TASK-0001 for the orchestrator run.
  with_fixture
  make_plan_stub "$plan"; make_critic_stub "$critic"
  base="$(git -C "$GLUERUN_ROOT" rev-parse target)"

  local out
  # Observe-only (knob unset).
  out="$(GLUERUN_L1_PLAN_NODE="$plan" GLUERUN_RUNNER="$critic" \
        gluerun_ctx_critique_import_fanout RUN-obs "$base" 2>&1)"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^generated:')" "2" "observe-only imports both staged nodes (== plain fanout)"
  assert_eq "$(task_count)" "2" "observe-only imported set equals plain fanout (two tasks)"
  assert_contains "$out" "l1_planner_failures=0" "observe-only reports zero planner failures"
  assert_contains "$out" "l1_import_rejections=0" "observe-only reports zero import rejections"
  # Each node got a persisted critique record and a plan.critiqued event.
  local pr="$GLUERUN_RUNS_DIR/RUN-obs/l1-staging"
  [[ -f "$pr/D1.contract/plan-critique.json" ]] || fail "observe-only: D1.contract missing plan-critique.json"
  [[ -f "$pr/S0.substrate_base/plan-critique.json" ]] || fail "observe-only: S0.substrate_base missing plan-critique.json"
  assert_eq "$(events_count 'plan.critiqued')" "2" "observe-only: each node emits a plan.critiqued event"
  # The verdict is NOT enforced observe-only even when it is a reject verdict.
  assert_eq "$(events_count 'origin.l1_import_rejected')" "0" "observe-only records no rejection"
  # Staging parity: the orchestrator staged *.candidate.md into each node's
  # l1-staging/<node> dir (observed mid-flight by the critic), same paths as plain.
  local obs; obs="$(cat "$GLUERUN_TEST_STAGE_OBSERVE")"
  assert_contains "$obs" "/RUN-obs/l1-staging/D1.contract/TASK-0001.candidate.md" "staged D1.contract candidate at the expected path"
  assert_contains "$obs" "/RUN-obs/l1-staging/S0.substrate_base/TASK-0001.candidate.md" "staged S0.substrate_base candidate at the expected path"
}

# Observe-only must NOT enforce even a revise verdict (equivalent to today).
test_observe_only_ignores_reject_verdict() {
  with_fixture
  local plan="$GLUERUN_ROOT/plan-stub.sh"; make_plan_stub "$plan"
  local critic="$GLUERUN_ROOT/critic-stub.sh"; make_critic_stub "$critic"
  printf 'revise' > "$GLUERUN_TEST_VERDICT_DIR/D1.contract"
  printf 'park'   > "$GLUERUN_TEST_VERDICT_DIR/S0.substrate_base"
  local base; base="$(git -C "$GLUERUN_ROOT" rev-parse target)"
  local out
  # Explicit observe-only.
  out="$(GLUERUN_PLAN_CRITIQUE=0 GLUERUN_L1_PLAN_NODE="$plan" GLUERUN_RUNNER="$critic" \
        gluerun_ctx_critique_import_fanout RUN-obs2 "$base" 2>&1)"
  assert_eq "$(task_count)" "2" "observe-only imports both nodes despite revise/park verdicts"
  assert_contains "$out" "l1_import_rejections=0" "observe-only withholds nothing"
  assert_eq "$(events_count 'origin.l1_import_rejected')" "0" "observe-only records no rejection for reject verdicts"
}

# ---------------------------------------------------------------------------
# ON enforcement: approve imports, revise is withheld with exactly one
# origin.l1_import_rejected (reason plan-critique) and the lease set failed.
# ---------------------------------------------------------------------------
run_on_case() { # <reject_verdict: revise|park>
  local reject="$1"
  with_fixture
  local plan="$GLUERUN_ROOT/plan-stub.sh"; make_plan_stub "$plan"
  local critic="$GLUERUN_ROOT/critic-stub.sh"; make_critic_stub "$critic"
  # D1.contract approves and imports; S0.substrate_base is rejected and withheld.
  printf 'approve'  > "$GLUERUN_TEST_VERDICT_DIR/D1.contract"
  printf '%s' "$reject" > "$GLUERUN_TEST_VERDICT_DIR/S0.substrate_base"
  local base; base="$(git -C "$GLUERUN_ROOT" rev-parse target)"
  local out
  out="$(GLUERUN_PLAN_CRITIQUE=1 GLUERUN_L1_PLAN_NODE="$plan" GLUERUN_RUNNER="$critic" \
        gluerun_ctx_critique_import_fanout "RUN-on-$reject" "$base" 2>&1)"
  # The approved node imported (a real TASK id landed).
  assert_eq "$(printf '%s\n' "$out" | grep -c '^generated:')" "1" "ON/$reject: only the approved node imports"
  assert_eq "$(task_count)" "1" "ON/$reject: exactly one task imported (the approved node)"
  assert_contains "$(cat "$GLUERUN_TASKS_DIR"/TASK-*.md 2>/dev/null)" "D1.contract" "ON/$reject: the imported task is the approved node"
  # The rejected node was withheld: not imported, one rejection event, lease failed.
  assert_eq "$(events_count 'origin.l1_import_rejected')" "1" "ON/$reject: exactly one origin.l1_import_rejected event"
  local evt
  evt="$(grep 'origin.l1_import_rejected' "$GLUERUN_EVENTS_FILE" | tail -1)"
  python3 - "$evt" "S0.substrate_base" "$reject" <<'PY' || fail "ON/$reject: rejection event payload wrong"
import json, sys
evt = json.loads(sys.argv[1]); node, obs = sys.argv[2:4]
assert evt.get("type") == "origin.l1_import_rejected", evt
d = evt.get("data", {})
assert d.get("reason") == "plan-critique", d
assert d.get("node") == node, d
assert d.get("observed") == obs, d
PY
  assert_eq "$(gluerun_l1_lease_status S0.substrate_base)" "failed" "ON/$reject: withheld node lease set failed"
  assert_eq "$(gluerun_l1_lease_status D1.contract)" "released" "ON/$reject: approved node lease released after import"
  # Withheld node is counted as a rejection in the drop-in summary.
  assert_contains "$out" "l1_import_rejections=1" "ON/$reject: withheld node counted in l1_import_rejections="
  assert_contains "$out" "l1_planner_failures=0" "ON/$reject: no planner failures"
}

test_on_enforcement_revise() { run_on_case revise; }
test_on_enforcement_park()   { run_on_case park; }

# ---------------------------------------------------------------------------
# present-but-uncalled: no existing engine path invokes the orchestrator, and
# engine/reconcile.sh still calls gluerun_l1_fanout (byte-identical prior wiring).
# ---------------------------------------------------------------------------
test_present_but_uncalled() {
  local callers
  callers="$(grep -rl 'gluerun_ctx_critique_import_fanout' \
    "$SCRIPT_DIR" 2>/dev/null | grep -v '/ctx-critique-import-fanout.sh$' || true)"
  [[ -z "$callers" ]] || fail "orchestrator must be present-but-uncalled; referenced by: $callers"
  grep -q 'gluerun_l1_fanout' "$SCRIPT_DIR/reconcile.sh" \
    || fail "reconcile.sh must still call gluerun_l1_fanout (wiring is the follow-up slice)"
}

test_observe_only_equivalent_to_plain_fanout
test_observe_only_ignores_reject_verdict
test_on_enforcement_revise
test_on_enforcement_park
test_present_but_uncalled

echo "ctx-critique-import-fanout tests passed"
