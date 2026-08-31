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
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpectedly found '$2'"; }
manifest_identity() {
  python3 - "$1" <<'PY'
import hashlib, json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
raw = json.dumps(doc["lineage"], sort_keys=True, separators=(",", ":"), ensure_ascii=False)
print(hashlib.sha256(raw.encode("utf-8")).hexdigest())
PY
}

NODE="plan-revision-loop"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
REPO="$tmp/repo"
mkdir -p "$REPO/docs/orchestration/prompts" "$REPO/docs/orchestration/tasks" \
  "$REPO/docs/orchestration/gates" "$REPO/schemas/orchestration" \
  "$REPO/.singular-state" "$REPO/engine"
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
      "id": "dependency-input",
      "stage": "S2-dependency",
      "area": "plancritic",
      "layer": "engine_runtime",
      "kind": "runtime",
      "dependsOn": [],
      "requiredCompletion": "dependency_input"
    },
    {
      "id": "plan-revision-loop",
      "stage": "S3-plan-revision",
      "area": "plancritic",
      "layer": "engine_runtime",
      "kind": "runtime",
      "dependsOn": ["dependency-input"],
      "requiredCompletion": "plan_revision_loop_wired"
    }
  ]
}
EOF
printf 'dependency fixture\n' > "$REPO/engine/dependency.txt"
cat > "$REPO/docs/orchestration/gates/dependency-input.gate-result.json" <<'EOF'
{
  "schema": "singular.orchestration.gate-result.v0",
  "node": "dependency-input",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "fixture-v1",
  "evidence": [
    {"kind": "source-path", "ref": "engine/dependency.txt", "description": "fixture"}
  ],
  "decidedBy": "fixture",
  "recordedAt": "2026-08-30T00:00:00Z"
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
export SINGULAR_AREA_PATHS="plancritic=engine/"

# --- STUB planner (SINGULAR_L1_PLANNER) ---------------------------------------
# Stands in for generate-tasks.sh staged mode: writes one *.candidate.md into the
# node's --stage-dir and exits 0 (the existing staging-success precondition).
PLANNER="$tmp/stub-planner.sh"
cat > "$PLANNER" <<'PEOF'
#!/usr/bin/env bash
set -uo pipefail
[[ -n "${PLANNER_MARKER:-}" ]] && printf 'call\n' >> "$PLANNER_MARKER"
[[ "${PLANNER_FAIL:-0}" != "1" ]] || exit 7
if [[ -n "${PLANNER_TASKS_SNAPSHOT:-}" ]]; then
  : > "$PLANNER_TASKS_SNAPSHOT"
  for task in "${SINGULAR_TASKS_DIR:-}"/TASK-*.md; do
    [[ -f "$task" ]] || continue
    printf '%s\n' "$(basename "$task")" >> "$PLANNER_TASKS_SNAPSHOT"
    sed -n '1,12p' "$task" >> "$PLANNER_TASKS_SNAPSHOT"
  done
fi
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
    SINGULAR_AREA_PATHS="$SINGULAR_AREA_PATHS" \
    SINGULAR_L1_PLANNER="$PLANNER" SINGULAR_PLAN_REVISE_MAX=1 \
    "$@" "$SCRIPT_DIR/l1-plan-node.sh" \
      --node "$NODE" --run-id RUN-hook --stage-dir "$sdir" 2>/dev/null)" || RC=$?
}

commit_fixture() {
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=test -c user.email=test@example.local \
    commit -q -m "$1"
}

assert_relevant_lineage_reopens() {
  local label="$1" stage marker snapshot
  stage="$tmp/stage-lineage-$label"
  marker="$tmp/planner-lineage-$label"
  snapshot="$tmp/tasks-lineage-$label"
  rm -f "$SINGULAR_L1_LEASES_DIR/$NODE.json"
  run_plan_node "$stage" SINGULAR_PLAN_CRITIQUE=1 SINGULAR_RUNNER="$CRITIC" \
    PLANNER_MARKER="$marker" PLANNER_TASKS_SNAPSHOT="$snapshot" \
    CRITIC_VERDICT=park SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-park
  [[ "$RC" -ne 0 ]] || fail "$label: critic park must remain non-zero"
  [[ -e "$marker" ]] || fail "$label: relevant input change did not open a new lineage"
  LAST_LINEAGE_STAGE="$stage"
  LAST_TASKS_SNAPSHOT="$snapshot"
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
  CRITIC_MARKER="$marker_imp" CRITIC_VERDICT=approve SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-approve
assert_eq "$RC" "0" "import: approve routes to import, exit 0"
assert_eq "$OUT" "planned:$NODE" "import: prints planned:<node>"
assert_eq "$(lease_status)" "active" "import: node lease left active for L0"
[[ -e "$marker_imp" ]] || fail "import: orchestrator (critic) was never invoked under the flag"
stable_identity="$(python3 - "$sd_imp/.plan-attempt-identity.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["identity"])
PY
)"
manifest_identity="$(manifest_identity "$sd_imp/plan-attempt-input.json")"
assert_eq "$stable_identity" "$manifest_identity" \
  "import: stable lineage must be the pre-provider manifest identity"
printf '\ncosmetic post-plan candidate change\n' >> "$sd_imp/TASK-0001.candidate.md"
manifest_after_candidate_change="$(manifest_identity "$sd_imp/plan-attempt-input.json")"
assert_eq "$manifest_after_candidate_change" "$stable_identity" \
  "import: generated candidate bytes must not change the stable attempt identity"
echo "PASS: (import) approve -> planned:<node>, exit 0, lease active"

rm -f "$SINGULAR_L1_LEASES_DIR/$NODE.json"
sd_import_reentry="$tmp/stage-import-reentry"
planner_import_reentry="$tmp/planner-import-reentry"
critic_import_reentry="$tmp/critic-import-reentry"
run_plan_node "$sd_import_reentry" SINGULAR_PLAN_CRITIQUE=1 SINGULAR_RUNNER="$CRITIC" \
  PLANNER_MARKER="$planner_import_reentry" CRITIC_MARKER="$critic_import_reentry" \
  CRITIC_VERDICT=approve SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-approve
[[ "$RC" -eq 0 ]] || fail "import reentry: exact approved candidates should replay idempotently"
assert_eq "$OUT" "planned:$NODE" "import reentry: approved snapshot was not restaged"
[[ ! -e "$planner_import_reentry" ]] \
  || fail "import reentry: fresh planner ran for an already-completed stable lineage"
[[ ! -e "$critic_import_reentry" ]] \
  || fail "import reentry: critic ran before exact approved replay"
[[ -f "$sd_import_reentry/TASK-0001.candidate.md" ]] \
  || fail "import reentry: approved candidate snapshot was not restored"
echo "PASS: completed lineage replays exact approved snapshot without provider work"

# ---------------------------------------------------------------------------
# (park) flag ON + park verdict -> lease failed, plan-failed, non-zero exit.
# ---------------------------------------------------------------------------
rm -f "$SINGULAR_L1_LEASES_DIR/$NODE.json"
sd_park="$tmp/stage-park"
marker_park="$tmp/critic-park"
run_plan_node "$sd_park" SINGULAR_PLAN_CRITIQUE=1 SINGULAR_RUNNER="$CRITIC" \
  CRITIC_MARKER="$marker_park" CRITIC_VERDICT=park SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-park
[[ "$RC" -ne 0 ]] || fail "park: a non-approve terminal must exit non-zero"
assert_contains "$OUT" "plan-failed:$NODE" "park: prints plan-failed:<node>"
assert_eq "$(lease_status)" "failed" "park: node lease set failed"
[[ -e "$marker_park" ]] || fail "park: orchestrator was never invoked under the flag"
echo "PASS: (park) park -> lease failed, plan-failed, non-zero exit"

# The terminal is keyed by stable pre-provider inputs, not generated candidate
# bytes. A restart with a fresh stage dir must be suppressed before either model
# runner is called. An explicit operator override token creates a new lineage.
rm -f "$SINGULAR_L1_LEASES_DIR/$NODE.json"
sd_reentry="$tmp/stage-park-reentry"
planner_reentry="$tmp/planner-reentry"
critic_reentry="$tmp/critic-reentry"
run_plan_node "$sd_reentry" SINGULAR_PLAN_CRITIQUE=1 SINGULAR_RUNNER="$CRITIC" \
  PLANNER_MARKER="$planner_reentry" CRITIC_MARKER="$critic_reentry" \
  CRITIC_VERDICT=park SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-park
[[ "$RC" -ne 0 ]] || fail "reentry: terminal lineage must stay suppressed"
assert_contains "$OUT" "terminal-lineage" "reentry: durable terminal not reported"
[[ ! -e "$planner_reentry" ]] || fail "reentry: fresh planner ran for a terminal stable lineage"
[[ ! -e "$critic_reentry" ]] || fail "reentry: critic ran for a terminal stable lineage"
echo "PASS: terminal stable lineage suppresses fresh planner/critic before provider work"

# Commits that only import/update a sibling task, change dependency timestamps,
# or touch unrelated paths must not mint a new budget for this parked node.
mkdir -p "$REPO/docs/unrelated"
cat > "$REPO/docs/orchestration/tasks/TASK-7777.md" <<'EOF'
# TASK-7777: unrelated sibling import

Status: completed
DAG node: `sibling-node`
Area: other

## Objective

This imported sibling must not enter the plan-revision-loop prompt.
EOF
printf 'unrelated target commit\n' > "$REPO/docs/unrelated/churn.md"
python3 - "$REPO/docs/orchestration/gates/dependency-input.gate-result.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["recordedAt"] = "2026-08-30T01:00:00Z"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(doc, stream, indent=2, sort_keys=True); stream.write("\n")
PY
commit_fixture "unrelated sibling lifecycle churn"
rm -f "$SINGULAR_L1_LEASES_DIR/$NODE.json"
sd_unrelated="$tmp/stage-lineage-unrelated"
planner_unrelated="$tmp/planner-lineage-unrelated"
critic_unrelated="$tmp/critic-lineage-unrelated"
run_plan_node "$sd_unrelated" SINGULAR_PLAN_CRITIQUE=1 SINGULAR_RUNNER="$CRITIC" \
  PLANNER_MARKER="$planner_unrelated" CRITIC_MARKER="$critic_unrelated" \
  CRITIC_VERDICT=park SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-park
[[ "$RC" -ne 0 ]] || fail "unrelated churn: terminal lineage must remain parked"
assert_contains "$OUT" "terminal-lineage" "unrelated churn: durable terminal not retained"
[[ ! -e "$planner_unrelated" ]] || fail "unrelated churn: sibling import reset planner budget"
[[ ! -e "$critic_unrelated" ]] || fail "unrelated churn: sibling import reran critic"
echo "PASS: sibling imports, timestamps, and unrelated target commits retain terminal park"

# Every input below is semantically relevant to this node and must open exactly
# a new lineage rather than inheriting the prior terminal.
python3 - "$REPO/docs/orchestration/gates/dependency-input.gate-result.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["evidenceClass"] = "fixture-v2"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(doc, stream, indent=2, sort_keys=True); stream.write("\n")
PY
commit_fixture "change direct dependency evidence"
assert_relevant_lineage_reopens dependency
assert_not_contains "$(cat "$LAST_TASKS_SNAPSHOT")" "TASK-7777" \
  "dependency: scoped planner task input leaked a sibling"

printf 'relevant source change\n' >> "$REPO/engine/dependency.txt"
commit_fixture "change area source"
assert_relevant_lineage_reopens source

printf '\nPlanner policy revision.\n' >> "$REPO/docs/orchestration/prompts/l1-planner.md"
commit_fixture "change planner prompt"
assert_relevant_lineage_reopens prompt

python3 - "$REPO/docs/orchestration/dag.v0.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
for node in doc["nodes"]:
    if node["id"] == "plan-revision-loop":
        node["authority"] = "agent-review-allowed"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(doc, stream, indent=2); stream.write("\n")
PY
commit_fixture "change node authority"
assert_relevant_lineage_reopens authority

cat > "$REPO/docs/orchestration/tasks/TASK-8888.md" <<'EOF'
# TASK-8888: relevant current-node task

Status: ready
DAG node: `plan-revision-loop`
Area: plancritic

## Objective

This task must enter the scoped planner input.
EOF
commit_fixture "add current node task"
assert_relevant_lineage_reopens current-task
assert_contains "$(cat "$LAST_TASKS_SNAPSHOT")" "TASK-8888" \
  "current task: scoped planner input omitted relevant node task"
assert_not_contains "$(cat "$LAST_TASKS_SNAPSHOT")" "TASK-7777" \
  "current task: scoped planner input leaked sibling task"
echo "PASS: dependency, source, prompt, authority, and current-task changes reopen planning"

# Corrupt durable state is preserved and replaced by an explicit terminal
# tombstone. It must never be treated as a fresh zero-attempt record.
corrupt_identity="$(manifest_identity "$LAST_LINEAGE_STAGE/plan-attempt-input.json")"
corrupt_record="$(find "$SINGULAR_STATE_DIR/planning-attempts" -path "*/$corrupt_identity/attempt.json" -print -quit)"
[[ -f "$corrupt_record" ]] || fail "corrupt state: terminal record not found"
printf '{ definitely-not-json' > "$corrupt_record"
rm -f "$SINGULAR_L1_LEASES_DIR/$NODE.json"
sd_corrupt="$tmp/stage-lineage-corrupt"
planner_corrupt="$tmp/planner-lineage-corrupt"
critic_corrupt="$tmp/critic-lineage-corrupt"
run_plan_node "$sd_corrupt" SINGULAR_PLAN_CRITIQUE=1 SINGULAR_RUNNER="$CRITIC" \
  PLANNER_MARKER="$planner_corrupt" CRITIC_MARKER="$critic_corrupt" \
  CRITIC_VERDICT=park SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-park
[[ "$RC" -ne 0 ]] || fail "corrupt state: quarantine must fail closed"
assert_contains "$OUT" "terminal-lineage attempt-state-corrupt" \
  "corrupt state: explicit terminal reason missing"
[[ ! -e "$planner_corrupt" ]] || fail "corrupt state: planner regained fresh budget"
[[ ! -e "$critic_corrupt" ]] || fail "corrupt state: critic ran after quarantine"
python3 - "$corrupt_record" "$sd_corrupt/planner-events.ndjson" <<'PY' \
  || fail "corrupt state: quarantine artifacts invalid"
import glob, json, os, sys
record, events = sys.argv[1:3]
doc = json.load(open(record, encoding="utf-8"))
assert doc["status"] == "park", doc
assert doc["terminalReason"] == "attempt-state-corrupt", doc
snapshots = glob.glob(os.path.join(os.path.dirname(record), "attempt.corrupt.*.json"))
assert len(snapshots) == 1, snapshots
assert open(snapshots[0], "rb").read() == b"{ definitely-not-json"
text = open(events, encoding="utf-8").read()
assert '"type":"plan.attempt_state_quarantined"' in text, text
assert '"reason":"attempt-state-corrupt"' in text, text
PY
echo "PASS: corrupt attempt state is quarantined and durably parked fail-closed"

rm -f "$SINGULAR_L1_LEASES_DIR/$NODE.json"
sd_override="$tmp/stage-park-override"
planner_override="$tmp/planner-override"
critic_override="$tmp/critic-override"
run_plan_node "$sd_override" SINGULAR_PLAN_CRITIQUE=1 SINGULAR_RUNNER="$CRITIC" \
  PLANNER_MARKER="$planner_override" CRITIC_MARKER="$critic_override" \
  CRITIC_VERDICT=park SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-park \
  SINGULAR_PLAN_ATTEMPT_OVERRIDE_TOKEN=operator-override-1
[[ "$RC" -ne 0 ]] || fail "override: explicit override still receives the critic's park"
[[ -e "$planner_override" ]] || fail "override: explicit token did not open a new planner lineage"
[[ -f "$sd_override/plan-critique.json" ]] \
  || fail "override: new lineage did not receive an identity-bound critique"
[[ ! -e "$critic_override" ]] \
  || fail "override: exact unchanged candidate paid for a duplicate semantic critic"
echo "PASS: explicit operator override opens a new lineage while exact critic proof is reused"

rm -f "$SINGULAR_L1_LEASES_DIR/$NODE.json"
sd_initial_infra="$tmp/stage-initial-infra"
planner_initial_infra="$tmp/planner-initial-infra"
critic_initial_infra="$tmp/critic-initial-infra"
run_plan_node "$sd_initial_infra" SINGULAR_PLAN_CRITIQUE=1 SINGULAR_RUNNER="$CRITIC" \
  PLANNER_MARKER="$planner_initial_infra" PLANNER_FAIL=1 \
  CRITIC_MARKER="$critic_initial_infra" CRITIC_VERDICT=approve \
  SINGULAR_PLAN_INITIAL_INFRA_MAX=99 \
  SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-initial-infra \
  SINGULAR_PLAN_ATTEMPT_OVERRIDE_TOKEN=initial-infra-case
[[ "$RC" -ne 0 ]] || fail "initial infra: exhausted planner retries must fail"
[[ "$(grep -c call "$planner_initial_infra")" -eq 2 ]] \
  || fail "initial infra: expected one call plus one bounded infrastructure retry"
[[ ! -e "$critic_initial_infra" ]] \
  || fail "initial infra: critic ran without a candidate"
python3 - "$SINGULAR_STATE_DIR" "$sd_initial_infra/plan-attempt-input.json" <<'PY' \
  || fail "initial infra: infrastructure retries contaminated product budgets"
import glob, hashlib, json, os, sys
state, manifest = sys.argv[1:3]
doc = json.load(open(manifest, encoding="utf-8"))
raw = json.dumps(doc["lineage"], sort_keys=True, separators=(",", ":"), ensure_ascii=False)
identity = hashlib.sha256(raw.encode("utf-8")).hexdigest()
paths = glob.glob(os.path.join(state, "planning-attempts", "*", identity, "attempt.json"))
assert len(paths) == 1, paths
doc = json.load(open(paths[0]))
assert doc["initialAttempts"] == 1, doc
assert doc["initialInfraAttempts"] == 2, doc
assert doc["revisionsDone"] == 0, doc
assert doc["status"] == "park", doc
PY
echo "PASS: initial planner infrastructure retry knob is hard-capped outside product budgets"

echo "l1-plan-node revise-hook tests passed"
