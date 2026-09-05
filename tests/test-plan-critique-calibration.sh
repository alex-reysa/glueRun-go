#!/usr/bin/env bash
# Plan-critique calibration (0.21.0). In the field the critic returned `revise`
# on 113 of 140 critiques and every node parked on revision-budget exhaustion,
# while its findings were never shown to the implementer. Three host-side
# rules fix the shape without touching the advocate/skeptic line:
#   (a) a `revise` verdict that carries no `blocking` finding is downgraded to
#       `approve` by the host (SINGULAR_PLAN_CRITIQUE_REQUIRE_BLOCKING=0 restores
#       verdict-as-written), recorded as plan.critique_downgraded;
#   (b) a repository with no prompts/plan-critic.md gets the engine template
#       instead of a blind critic, recorded as ctx.plan_critic_prompt_fallback;
#   (c) an approved batch carries its non-blocking findings into every
#       candidate as `## Plan critique (advisory)`, which singular_task_json
#       parses into planCritique and the worker/auditor prompts render.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state" "$tmp/orch/prompts" "$tmp/worktree"
printf '# Plan Critic Prompt\nREPO-COPY-MARKER\n' >"$tmp/orch/prompts/plan-critic.md"

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
export SINGULAR_ORCH_DIR="$tmp/orch"
export SINGULAR_EVENTS_FILE="$tmp/events.ndjson"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"
[[ "$(type -t singular_ctx_plan_critic_run)" == "function" ]] || fail "critic driver missing"
[[ "$(type -t singular_plan_critique_annotate_candidates)" == "function" ]] \
  || fail "singular_plan_critique_annotate_candidates missing"

STUB="$tmp/stub-runner.sh"
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
out=""
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  [[ "${args[$i]}" == "--output-last-message" ]] && out="${args[$((i + 1))]}"
  i=$((i + 1))
done
[[ -n "$out" ]] || exit 0
cat >"$out" <<JSON
{
  "schema": "singular.orchestration.plan-critique.v0",
  "node": "n",
  "runId": "r",
  "batchTaskIds": ["TASK-0007"],
  "verdict": "${STUB_VERDICT:-revise}",
  "findings": ${STUB_FINDINGS:-[]},
  "assumptionsChallenged": [],
  "rationale": "stub rationale"
}
JSON
STUBEOF
chmod +x "$STUB"
export SINGULAR_RUNNER="$STUB"

count_events() {
  [[ -f "$SINGULAR_EVENTS_FILE" ]] || { echo 0; return 0; }
  local c; c="$(grep -c "\"type\":\"$1\"" "$SINGULAR_EVENTS_FILE" 2>/dev/null)" || true
  echo "${c:-0}"
}
make_stage_dir() {
  local d="$tmp/stage/$1"
  mkdir -p "$d"
  cat >"$d/TASK-0007.candidate.md" <<'MD'
# TASK-0007: Add the widget parser

Status: ready
Area: widget
DAG node: n1
Depends on: []

## Objective

Parse widgets.

## Scope

Owned files:
- src/widget.sh
- tests/test-widget.sh

## Acceptance criteria

- Parses a widget.
MD
  printf 'existing task summary\n' >"$d/existing-tasks.md"
  printf '%s' "$d"
}
verdict_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$1"; }
rationale_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rationale"])' "$1"; }

SHOULD_FIX='[{"id":"f-000000000001","severity":"should-fix","claim":"Timestamp parsing has no failure code","evidence":"src/widget.sh","suggestedChange":"return E_TIME"},{"id":"f-000000000002","severity":"note","claim":"Consider a table-driven test","evidence":"tests/test-widget.sh"}]'
BLOCKING='[{"id":"f-000000000003","severity":"blocking","claim":"Owned files collide with TASK-0004","evidence":"docs/orchestration/tasks/TASK-0004.md"}]'

# (a) revise with only should-fix/note findings -> approve, downgraded event,
#     every finding retained, rationale explains the host decision.
: >"$SINGULAR_EVENTS_FILE"
sd="$(make_stage_dir a)"
STUB_VERDICT=revise STUB_FINDINGS="$SHOULD_FIX" \
  singular_ctx_plan_critic_run n1 RUN-A "$sd" "$tmp/worktree" || fail "a: driver crashed"
[[ "$(verdict_of "$sd/plan-critique.json")" == "approve" ]] \
  || fail "a: revise without blocking findings must be downgraded to approve"
[[ "$(rationale_of "$sd/plan-critique.json")" == "[host] revise downgraded"* ]] \
  || fail "a: rationale must record the host downgrade"
[[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["findings"]))' "$sd/plan-critique.json")" == 2 ]] \
  || fail "a: findings must be retained through the downgrade"
[[ "$(count_events plan.critique_downgraded)" -eq 1 ]] || fail "a: plan.critique_downgraded event missing"
grep -q '"verdict":"approve"' "$SINGULAR_EVENTS_FILE" || fail "a: plan.critiqued must carry the effective verdict"

# (a2) a blocking finding keeps revise; (a3) the knob restores verdict-as-written.
: >"$SINGULAR_EVENTS_FILE"
sd="$(make_stage_dir a2)"
STUB_VERDICT=revise STUB_FINDINGS="$BLOCKING" \
  singular_ctx_plan_critic_run n2 RUN-A2 "$sd" "$tmp/worktree" || fail "a2: driver crashed"
[[ "$(verdict_of "$sd/plan-critique.json")" == "revise" ]] || fail "a2: blocking finding must keep revise"
[[ "$(count_events plan.critique_downgraded)" -eq 0 ]] || fail "a2: no downgrade with a blocking finding"
: >"$SINGULAR_EVENTS_FILE"
sd="$(make_stage_dir a3)"
STUB_VERDICT=revise STUB_FINDINGS="$SHOULD_FIX" SINGULAR_PLAN_CRITIQUE_REQUIRE_BLOCKING=0 \
  singular_ctx_plan_critic_run n3 RUN-A3 "$sd" "$tmp/worktree" || fail "a3: driver crashed"
[[ "$(verdict_of "$sd/plan-critique.json")" == "revise" ]] || fail "a3: knob off must keep verdict as written"
[[ "$(count_events plan.critique_downgraded)" -eq 0 ]] || fail "a3: knob off must not downgrade"
# park is never touched by the gate.
sd="$(make_stage_dir a4)"
STUB_VERDICT=park STUB_FINDINGS="$SHOULD_FIX" \
  singular_ctx_plan_critic_run n4 RUN-A4 "$sd" "$tmp/worktree" || fail "a4: driver crashed"
[[ "$(verdict_of "$sd/plan-critique.json")" == "park" ]] || fail "a4: park must pass through untouched"
echo "PASS: (a) host severity gate"

# (b) missing repo prompt -> engine template, fallback event, template text in
#     the content-bound prompt; a present repo copy is still preferred.
: >"$SINGULAR_EVENTS_FILE"
sd="$(make_stage_dir b)"
STUB_VERDICT=approve SINGULAR_ORCH_DIR="$tmp/orch-empty" \
  singular_ctx_plan_critic_run n5 RUN-B "$sd" "$tmp/worktree" || fail "b: driver crashed"
[[ "$(count_events ctx.plan_critic_prompt_fallback)" -eq 1 ]] || fail "b: fallback event missing"
grep -q 'Severity — what each level means' "$sd/plan-critic-input.md" \
  || fail "b: engine template policy missing from the content-bound prompt"
[[ "$(verdict_of "$sd/plan-critique.json")" == "approve" ]] || fail "b: fallback run did not record a verdict"
: >"$SINGULAR_EVENTS_FILE"
sd="$(make_stage_dir b2)"
STUB_VERDICT=approve singular_ctx_plan_critic_run n6 RUN-B2 "$sd" "$tmp/worktree" || fail "b2: driver crashed"
[[ "$(count_events ctx.plan_critic_prompt_fallback)" -eq 0 ]] || fail "b2: repo copy present must not fall back"
grep -q 'REPO-COPY-MARKER' "$sd/plan-critic-input.md" || fail "b2: repo copy not used"
echo "PASS: (b) prompt template fallback"

# (c) advisory carry-forward: annotate, parse, render; idempotent; knob off.
sd="$(make_stage_dir c)"
STUB_VERDICT=revise STUB_FINDINGS="$SHOULD_FIX" \
  singular_ctx_plan_critic_run n7 RUN-C "$sd" "$tmp/worktree" || fail "c: driver crashed"
singular_plan_critique_annotate_candidates "$sd/plan-critique.json" "$sd" || fail "c: annotate failed"
# Publication goes through the immutable generation pointer, never in place.
cand="$(singular_task_batch_candidate_dir "$sd")/TASK-0007.candidate.md"
[[ -f "$sd/.candidate-current.json" ]] || fail "c: annotation must publish a hash-bound generation"
grep -q '^## Plan critique (advisory)$' "$cand" || fail "c: advisory section missing"
grep -q '^\- \[should-fix\] f-' "$cand" || fail "c: should-fix finding not rendered"
grep -q 'Suggested: return E_TIME' "$cand" || fail "c: suggestedChange not rendered"
grep -q '^\- \[note\] f-' "$cand" || fail "c: note finding not rendered"
singular_plan_critique_annotate_candidates "$sd/plan-critique.json" "$sd" || fail "c: re-annotate failed"
cand="$(singular_task_batch_candidate_dir "$sd")/TASK-0007.candidate.md"
[[ "$(grep -c '^## Plan critique (advisory)$' "$cand")" -eq 1 ]] || fail "c: annotation must be idempotent"
# Headers and scope are untouched; the parser exposes the advisory list.
python3 - "$(singular_task_json "$cand")" <<'PY' || fail "c: task json did not expose planCritique"
import json, sys
t = json.loads(sys.argv[1])
assert t["taskId"] == "TASK-0007", t
assert t["ownedFiles"] == ["src/widget.sh", "tests/test-widget.sh"], t
assert t["acceptanceCriteria"] == ["Parses a widget."], t
assert len(t["planCritique"]) == 2, t["planCritique"]
# Finding ids are re-minted from claim text by the driver, so only the shape
# and the claim are stable.
assert t["planCritique"][0].startswith("[should-fix] f-"), t["planCritique"]
assert "Timestamp parsing has no failure code" in t["planCritique"][0], t["planCritique"]
assert t["planCritique"][1].startswith("[note] f-"), t["planCritique"]
print("ok")
PY
sd2="$(make_stage_dir c2)"
cp "$sd/plan-critique.json" "$sd2/plan-critique.json"
SINGULAR_PLAN_CRITIQUE_ADVISORY=0 singular_plan_critique_annotate_candidates "$sd2/plan-critique.json" "$sd2" \
  || fail "c2: annotate (off) failed"
grep -q 'Plan critique (advisory)' "$(singular_task_batch_candidate_dir "$sd2")/TASK-0007.candidate.md" && fail "c2: knob off must not annotate"
# A blocking-free record with zero findings annotates nothing.
sd3="$(make_stage_dir c3)"
printf '{"schema":"singular.orchestration.plan-critique.v0","node":"n","runId":"r","batchTaskIds":["TASK-0007"],"verdict":"approve","findings":[],"assumptionsChallenged":[],"rationale":"x"}\n' \
  >"$sd3/plan-critique.json"
singular_plan_critique_annotate_candidates "$sd3/plan-critique.json" "$sd3" || fail "c3: annotate failed"
grep -q 'Plan critique (advisory)' "$(singular_task_batch_candidate_dir "$sd3")/TASK-0007.candidate.md" && fail "c3: no findings must mean no section"
[[ ! -e "$sd3/.candidate-current.json" ]] || fail "c3: no findings must publish nothing"
echo "PASS: (c) advisory carry-forward"

# (d) the revise loop annotates on its import terminal, before the snapshot.
[[ "$(type -t singular_plan_revise_loop)" == "function" ]] || fail "d: revise loop missing"
grep -n 'singular_plan_critique_annotate_candidates "$record" "$stage_dir"' \
  "$ENGINE_HOME/engine/ctx-plan-revise-loop.sh" >/dev/null \
  || fail "d: revise loop does not call the annotator on import"
echo "PASS: (d) loop wiring"

# (e) the prompts render the advisory block for the worker and the auditor.
grep -q 'Plan critique (advisory, recorded before dispatch)' "$ENGINE_HOME/engine/l1-drive.sh" \
  || fail "e: prompt assembly does not render advisory findings"
[[ "$(grep -c 'Plan critique (advisory, recorded before dispatch)' "$ENGINE_HOME/engine/l1-drive.sh")" -ge 2 ]] \
  || fail "e: both the worker and the auditor prompt must render the advisory block"
echo "PASS: (e) prompt rendering"
echo "PASS: test-plan-critique-calibration"
