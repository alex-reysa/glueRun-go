#!/usr/bin/env bash
# Canonical full-walk test for the plan-revision-loop composition brick
# engine/ctx-plan-revise-loop.sh (stage S3-plan-revision, area plancritic, layer
# engine_runtime, kind runtime). This is the requiredCompletion-cited node test.
#
# gluerun_plan_revise_loop <node> <run_id> <stage_dir> [worktree] composes ONLY
# the already-integrated engine helpers into the bounded in-lineage
#   critique -> decide(revise|import|park) -> [assemble prompt -> resume|fresh ->
#   re-stage via injectable planner runner (rc-86 -> fresh fallback) ->
#   record dispositions] -> re-critique
# loop, printing EXACTLY one terminal outcome line (`import` or `park <reason>`)
# and driving no state beyond the stage dir + the pinned event log.
#
# Fully hermetic: STUB critic runner (via GLUERUN_RUNNER, consumed by the
# integrated gluerun_ctx_plan_critic_run) and STUB planner runner (via
# GLUERUN_PLAN_REVISE_PLANNER). Pins GLUERUN_EVENTS_FILE, the stage dir,
# GLUERUN_PLAN_CRITIQUE=1, and GLUERUN_PLAN_REVISE_MAX.
#
# Exercises the full walk:
#   (A) critique -> revise -> approve -> import, resume path (strategy=resume,
#       no rc-86), with every disposition (accepted-observation,
#       rejected-observation, accepted-but-unaddressed) + plan.revised + strategy
#       events observable;
#   (B) the rc-86 resume-refused fresh-fallback path (context.resume_failed
#       recorded, fresh re-run re-stages, then approve -> import);
#   (C) budget exhaustion -> park revise-budget-exhausted (recorded), fresh
#       strategy path;
#   (D) approve at round 0 -> import with NO revision attempted;
#   (E) present-but-uncalled: no existing engine path invokes the new function.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-plan-revise-loop.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

REPO="$tmp/repo"
mkdir -p "$REPO/docs/orchestration/prompts"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$REPO/docs/orchestration/prompts/l1-planner.md"
# Base plan-critic prompt the integrated critic driver passes to its runner.
printf '# Plan Critic Prompt\n' > "$REPO/docs/orchestration/prompts/plan-critic.md"
git -C "$REPO" add .
git -C "$REPO" -c user.name=test -c user.email=test@example.local commit -q -m init

export GLUERUN_ROOT="$REPO"
export GLUERUN_STATE_DIR="$REPO/.gluerun-state"
export GLUERUN_ORCH_DIR="$REPO/docs/orchestration"
export GLUERUN_EVENTS_FILE="$tmp/events.ndjson"
export GLUERUN_PLAN_CRITIQUE=1
export GLUERUN_PLAN_REVISE_MAX=1
: > "$GLUERUN_EVENTS_FILE"

# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the composition function (RED before impl).
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
# shellcheck disable=SC1090
source "$CTX" || fail "sourcing $CTX failed"
[[ "$(type -t gluerun_plan_revise_loop)" == "function" ]] \
  || fail "gluerun_plan_revise_loop not defined by $CTX"

NODE="plan-revision-loop"
HEAD="$(git -C "$REPO" rev-parse target)"
TPL_SHA="$(gluerun_sha256_file "$REPO/docs/orchestration/prompts/l1-planner.md")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
META="$GLUERUN_STATE_DIR/sessions/planner/$NODE.json"

# --- STUB critic runner (GLUERUN_RUNNER) -------------------------------------
# Pops the next verdict from a per-scenario sequence file and writes a critique
# with three findings (three distinct sha-derived ids), so the disposition
# classifier sees a full findings set. Ignores the prompt content.
CRITIC="$tmp/stub-critic.sh"
cat > "$CRITIC" <<'CEOF'
#!/usr/bin/env bash
set -uo pipefail
out=""; args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  [[ "${args[$i]}" == "--output-last-message" ]] && out="${args[$((i + 1))]}"
  i=$((i + 1))
done
[[ -n "$out" ]] || exit 0
verdict="approve"
if [[ -n "${CRITIC_SEQ_FILE:-}" && -s "${CRITIC_SEQ_FILE}" ]]; then
  verdict="$(sed -n '1p' "$CRITIC_SEQ_FILE")"
  sed -i.bak '1d' "$CRITIC_SEQ_FILE" && rm -f "$CRITIC_SEQ_FILE.bak"
fi
cat > "$out" <<JSON
Here is my critique:
{
  "schema": "gluerun.orchestration.plan-critique.v0",
  "node": "STUB",
  "runId": "STUB",
  "batchTaskIds": ["TASK-9999"],
  "verdict": "$verdict",
  "findings": [
    {"severity": "blocking", "claim": "finding claim one", "evidence": "ev-one"},
    {"severity": "should-fix", "claim": "finding claim two", "evidence": "ev-two"},
    {"severity": "note", "claim": "finding claim three", "evidence": "ev-three"}
  ],
  "assumptionsChallenged": [],
  "rationale": "stub critic rationale"
}
JSON
exit 0
CEOF
chmod +x "$CRITIC"
export GLUERUN_RUNNER="$CRITIC"

# --- STUB planner runner (GLUERUN_PLAN_REVISE_PLANNER) ------------------------
# Re-stages a candidate into --stage-dir, reads the finding ids from the revision
# --prompt-file, and writes a task-batch.v0 to --output-last-message that ADDRESSES
# the first id, REJECTS the second, and leaves the third unaddressed (so all three
# dispositions appear). When PLANNER_FAIL_ON_RESUME=1 and --resume-session is
# present, exits 86 (resume-refused) to drive the fresh-fallback path.
PLANNER="$tmp/stub-planner.sh"
cat > "$PLANNER" <<'PEOF'
#!/usr/bin/env bash
set -uo pipefail
out=""; prompt=""; stage=""; has_resume=0; args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    --output-last-message) out="${args[$((i + 1))]}" ;;
    --prompt-file) prompt="${args[$((i + 1))]}" ;;
    --stage-dir) stage="${args[$((i + 1))]}" ;;
    --resume-session) has_resume=1 ;;
  esac
  i=$((i + 1))
done
if [[ "${PLANNER_FAIL_ON_RESUME:-0}" == "1" && "$has_resume" == "1" ]]; then
  exit 86
fi
touch "${PLANNER_INVOKED_FILE:-/dev/null}"
[[ -n "$stage" ]] && printf '# revised candidate\n' > "$stage/TASK-0100.candidate.md"
[[ -n "$out" ]] || exit 0
python3 - "$out" "$prompt" <<'PY'
import re, json, sys
out, prompt = sys.argv[1], sys.argv[2]
ids = []
try:
    with open(prompt, "r", encoding="utf-8") as f:
        text = f.read()
    ids = sorted(set(re.findall(r"f-[0-9a-f]{12}", text)))
except Exception:
    ids = []
tasks = []
if len(ids) >= 1:
    tasks.append({"taskId": "TASK-0100", "markdown": "addresses %s per critique" % ids[0]})
if len(ids) >= 2:
    tasks.append({"taskId": "TASK-0101", "markdown": "reject %s: out of scope" % ids[1]})
# ids[2:] deliberately unaddressed (accepted-but-unaddressed)
doc = {"schema": "gluerun.orchestration.task-batch.v0", "tasks": tasks}
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f)
PY
exit 0
PEOF
chmod +x "$PLANNER"
export GLUERUN_PLAN_REVISE_PLANNER="$PLANNER"

# --- helpers -----------------------------------------------------------------
ev_count() { # <type>
  [[ -f "$GLUERUN_EVENTS_FILE" ]] || { echo 0; return; }
  local n; n="$(grep -c "\"type\":\"$1\"" "$GLUERUN_EVENTS_FILE" 2>/dev/null || true)"
  echo "${n:-0}"
}

# Forge a resumable planner meta (all 11 planner resume gates pass) so the loop's
# resume-vs-fresh decision yields `resume`, mirroring test-ctx-plan-revise-resume.
forge_meta() {
  mkdir -p "$(dirname "$META")"
  python3 - "$META" "$REPO" "$NOW" "$NODE" "$TPL_SHA" "$HEAD" "$(basename "$PLANNER")" <<'PY'
import json, sys
path, cwd, now, node, tpl, head, runner = sys.argv[1:8]
doc = {
    "schema": "gluerun.orchestration.session-meta.v0",
    "provider": "codex", "sessionId": "SID-PLANNER", "model": "m", "effort": "e",
    "cwd": cwd, "exitCode": 0, "createdAt": now,
    "role": "planner", "node": node, "runner": runner,
    "promptSha256": tpl, "headShaAtCreate": head, "lastUsedAttempt": 1,
}
json.dump(doc, open(path, "w"), indent=2)
PY
}

# dispositions[] recorded by the last plan.revised event (id -> disposition set).
plan_revised_dispositions() {
  python3 - "$GLUERUN_EVENTS_FILE" <<'PY'
import json, sys
last = None
try:
    for line in open(sys.argv[1]):
        line = line.strip()
        if not line: continue
        e = json.loads(line)
        if e.get("type") == "plan.revised": last = e
except FileNotFoundError:
    pass
if last is None:
    sys.exit(0)
for d in last.get("data", {}).get("dispositions", []):
    print(d.get("disposition", ""))
PY
}

new_stage() { # <label> -> prints a fresh stage dir
  local d="$tmp/stage/$1"; mkdir -p "$d"; printf '%s' "$d"
}

# =============================================================================
# (A) critique -> revise -> approve -> import, RESUME path, all dispositions.
# =============================================================================
export GLUERUN_PLANNER_SESSION=1
forge_meta
: > "$GLUERUN_EVENTS_FILE"
export CRITIC_SEQ_FILE="$tmp/seqA"; printf 'revise\napprove\n' > "$CRITIC_SEQ_FILE"
export PLANNER_FAIL_ON_RESUME=0
export PLANNER_INVOKED_FILE="$tmp/planner-A"
sdA="$(new_stage A)"
outA="$(gluerun_plan_revise_loop "$NODE" "RUN-A" "$sdA" "$REPO")" \
  || fail "A: loop must exit 0 on the happy walk"
[[ "$outA" == "import" ]] || fail "A: terminal outcome must be exactly 'import' (got '$outA')"
[[ "$(printf '%s\n' "$outA" | grep -c .)" -eq 1 ]] || fail "A: must print exactly one terminal line"
[[ -e "$PLANNER_INVOKED_FILE" ]] || fail "A: planner runner was never invoked for the revision round"
[[ "$(ev_count context.strategy_selected)" -ge 1 ]] || fail "A: no context.strategy_selected event"
# Resume path: the selected strategy is resume and there is NO resume-failure.
grep -q '"strategy":"resume"' "$GLUERUN_EVENTS_FILE" || fail "A: expected a resume strategy event"
[[ "$(ev_count context.resume_failed)" -eq 0 ]] || fail "A: resume succeeded; must be NO context.resume_failed"
[[ "$(ev_count plan.revised)" -ge 1 ]] || fail "A: no plan.revised disposition event"
[[ "$(ev_count plan.critiqued)" -ge 2 ]] || fail "A: expected re-critique (>=2 plan.critiqued)"
[[ "$(ev_count plan.revise_parked)" -eq 0 ]] || fail "A: import walk must not park"
# Every disposition class is event-visible.
disps="$(plan_revised_dispositions | sort -u)"
for d in accepted-observation rejected-observation accepted-but-unaddressed; do
  printf '%s\n' "$disps" | grep -qx "$d" || fail "A: disposition '$d' not recorded (got: $(echo $disps))"
done

# =============================================================================
# (B) rc-86 resume-refused -> fresh fallback recorded -> re-stage -> import.
# =============================================================================
forge_meta
: > "$GLUERUN_EVENTS_FILE"
export CRITIC_SEQ_FILE="$tmp/seqB"; printf 'revise\napprove\n' > "$CRITIC_SEQ_FILE"
export PLANNER_FAIL_ON_RESUME=1
export PLANNER_INVOKED_FILE="$tmp/planner-B"
sdB="$(new_stage B)"
outB="$(gluerun_plan_revise_loop "$NODE" "RUN-B" "$sdB" "$REPO")" \
  || fail "B: loop must exit 0 on the rc-86 fresh-fallback walk"
[[ "$outB" == "import" ]] || fail "B: terminal outcome must be 'import' (got '$outB')"
grep -q '"strategy":"resume"' "$GLUERUN_EVENTS_FILE" || fail "B: expected a resume strategy event before the refusal"
[[ "$(ev_count context.resume_failed)" -ge 1 ]] || fail "B: rc-86 must record a context.resume_failed event"
[[ "$(ev_count plan.revised)" -ge 1 ]] || fail "B: fresh fallback must still record dispositions"
[[ -e "$PLANNER_INVOKED_FILE" ]] || fail "B: fresh fallback re-run must invoke the planner runner"

# =============================================================================
# (C) budget exhaustion -> park revise-budget-exhausted (recorded), FRESH path.
# =============================================================================
unset GLUERUN_PLANNER_SESSION  # -> resume decider returns `fresh disabled`
: > "$GLUERUN_EVENTS_FILE"
export CRITIC_SEQ_FILE="$tmp/seqC"; printf 'revise\nrevise\n' > "$CRITIC_SEQ_FILE"
export PLANNER_FAIL_ON_RESUME=0
export PLANNER_INVOKED_FILE="$tmp/planner-C"
sdC="$(new_stage C)"
outC="$(gluerun_plan_revise_loop "$NODE" "RUN-C" "$sdC" "$REPO")" \
  || fail "C: loop must exit 0 on the budget-exhaustion walk"
[[ "$outC" == "park revise-budget-exhausted" ]] \
  || fail "C: terminal outcome must be 'park revise-budget-exhausted' (got '$outC')"
[[ "$(ev_count plan.revise_parked)" -ge 1 ]] || fail "C: budget-exhaustion park must be recorded"
grep -q '"strategy":"fresh"' "$GLUERUN_EVENTS_FILE" || fail "C: expected a fresh strategy event"
# Exactly one bounded revision round ran (GLUERUN_PLAN_REVISE_MAX=1).
[[ "$(ev_count plan.revised)" -eq 1 ]] || fail "C: exactly one bounded revision round expected"

# =============================================================================
# (D) approve at round 0 -> import with NO revision attempted.
# =============================================================================
: > "$GLUERUN_EVENTS_FILE"
export CRITIC_SEQ_FILE="$tmp/seqD"; printf 'approve\n' > "$CRITIC_SEQ_FILE"
export PLANNER_INVOKED_FILE="$tmp/planner-D"
sdD="$(new_stage D)"
outD="$(gluerun_plan_revise_loop "$NODE" "RUN-D" "$sdD" "$REPO")" \
  || fail "D: loop must exit 0 on an immediate approve"
[[ "$outD" == "import" ]] || fail "D: immediate approve must import (got '$outD')"
[[ "$(ev_count plan.revised)" -eq 0 ]] || fail "D: no revision must be attempted on an approve verdict"
[[ "$(ev_count context.strategy_selected)" -eq 0 ]] || fail "D: no strategy selected without a revision"
[[ ! -e "$PLANNER_INVOKED_FILE" ]] || fail "D: planner runner must NOT run on an immediate approve"

# =============================================================================
# (E) present-but-uncalled: no existing engine path invokes the new function.
# =============================================================================
callers="$(grep -rl "gluerun_plan_revise_loop" "$ENGINE_HOME/engine" 2>/dev/null \
  | grep -v '/ctx-plan-revise-loop.sh$' || true)"
[[ -z "$callers" ]] || fail "gluerun_plan_revise_loop must be present-but-uncalled; referenced by: $callers"

echo "ctx-plan-revision full-walk tests passed"
