#!/usr/bin/env bash
set -euo pipefail

# Require bash >= 4 (mapfile). macOS /bin/bash is 3.2; re-exec under Homebrew bash.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "l1-drive.sh requires bash >= 4 (mapfile); install via 'brew install bash'" >&2
  exit 1
fi

# L1 Area Orchestrator driver (AI-native, self-healing).
#
# Drives ONE ready task: worktree + lease + L2 worker + scope + gate + commit +
# auditor. On any failure it consults the autonomous decider (decide.sh) instead
# of stopping for a human: it auto-fixes and retries (bounded by maxRetries),
# accepts-with-waiver, or records a terminal/parked outcome and moves on. A
# secret-scan guards every commit. An EXIT trap reclassifies a stranded lease.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Worker/auditor runner. Defaults to the codex runner; set GLUERUN_RUNNER to a
# drop-in (e.g. claude-run.sh) to dispatch a different CLI. Same flag surface
# and same --output-last-message contract is required of any runner.
GLUERUN_RUNNER_BIN="${GLUERUN_RUNNER:-$SCRIPT_DIR/codex-run.sh}"

task_id=""
dry_run="no"
reset="no"
require_audit="${GLUERUN_REQUIRE_AUDIT:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run="yes"; shift ;;
    --reset) reset="yes"; shift ;;
    --no-audit) require_audit="0"; shift ;;
    --task) task_id="$2"; shift 2 ;;
    TASK-*) task_id="$1"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$task_id" ]]; then
  echo "usage: $0 TASK-XXXX [--dry-run] [--reset] [--no-audit]" >&2
  exit 2
fi

gluerun_ensure_state_dirs
gluerun_require_target_branch

# Honor the kill switch at the dispatch entry point, not only in the loop
# wrappers, so a manual `make orch-drive` cannot dispatch a worker while frozen.
if gluerun_stop_requested; then
  gluerun_append_event "l1.frozen" "STOP sentinel present; refusing to dispatch" "{\"taskId\":\"$task_id\"}"
  echo "frozen (STOP sentinel present; $GLUERUN_STOP_FILE); refusing to dispatch $task_id"
  exit 0
fi

task_file="$GLUERUN_TASKS_DIR/$task_id.md"
if [[ ! -f "$task_file" ]]; then
  echo "task file not found: $task_file" >&2
  exit 2
fi

task_json="$(gluerun_task_json "$task_file")"
tf() { printf '%s' "$task_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d[sys.argv[1]]; print(json.dumps(v) if isinstance(v,(list,dict)) else v)' "$1"; }

area="$(tf area)"
worker_branch="$(tf workerBranch)"
target_branch="$(tf targetBranch)"
test_policy="$(tf testPolicy)"
gate_cmd="$(tf gateCommand)"
[[ -n "$gate_cmd" ]] || gate_cmd="$GLUERUN_DEFAULT_GATE_CMD"
[[ -n "$target_branch" ]] || target_branch="$GLUERUN_TARGET_BRANCH"
dispatch_batch_id="${GLUERUN_DISPATCH_BATCH_ID:-}"
dispatch_base_sha="${GLUERUN_DISPATCH_BASE_SHA:-}"
branch_base="${dispatch_base_sha:-$target_branch}"
packet_base_ref="${dispatch_base_sha:-$target_branch}"

mapfile -t owned_files < <(printf '%s' "$task_json" | python3 -c 'import json,sys; [print(x) for x in json.load(sys.stdin)["ownedFiles"]]')
mapfile -t forbidden_files < <(printf '%s' "$task_json" | python3 -c 'import json,sys; [print(x) for x in json.load(sys.stdin)["forbiddenFiles"] if "/" in x and " " not in x]')

# ---- Host-only task preflight (fail closed BEFORE run_id/lease/worktree) ----
# Absorbs the historical ad-hoc refusals (empty gate command [fail closed: a
# task with no gate command would otherwise run `bash -c ""`, which exits 0 and
# silently passes the regression check], empty owned files) plus the structural
# checks gluerun_task_preflight enforces. Dry-run keeps its historical exemption
# from the empty-gate refusal only.
preflight_require_gate=1
[[ "$dry_run" == "yes" ]] && preflight_require_gate=0
if ! preflight_reasons="$(gluerun_task_preflight "$task_json" "$gate_cmd" "$target_branch" "$preflight_require_gate")"; then
  echo "refusing to dispatch $task_id: task preflight failed:" >&2
  printf '%s\n' "$preflight_reasons" >&2
  if [[ "$dry_run" == "yes" ]]; then
    echo "DRY RUN - task would be parked (preflight); no state mutated."
    exit 3
  fi
  preflight_joined="$(printf '%s' "$preflight_reasons" | python3 -c 'import sys; print("; ".join(l.strip() for l in sys.stdin if l.strip()))')"
  gluerun_task_set_status "$task_file" "blocked" || true
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "escalate-parked" \
    --rationale "task preflight failed: $preflight_joined" --run "preflight" \
    --branch "$worker_branch" --authority l1 || true
  preflight_event="$(printf '%s\n' "$preflight_reasons" | python3 -c 'import json,sys
print(json.dumps({"taskId": sys.argv[1], "reasons": [l.strip() for l in sys.stdin if l.strip()]}, separators=(",", ":")))' "$task_id")"
  gluerun_append_event "l1.preflight_failed" "task preflight failed" "$preflight_event"
  exit 3
fi

run_id="$(gluerun_worker_run_id)"
run_dir="$(gluerun_run_dir "$run_id")"
mkdir -p "$run_dir"
worktree="$GLUERUN_WORKTREES_DIR/$task_id"
max_retries="${GLUERUN_MAX_RETRIES:-3}"

echo "L1 drive: $task_id (area=$area, policy=$test_policy)"
echo "  worker_branch=$worker_branch  target=$target_branch  base=$branch_base  run=$run_id"
[[ -n "$dispatch_batch_id" ]] && echo "  batch=$dispatch_batch_id"
echo "  owned_files=${owned_files[*]}"
[[ ${#forbidden_files[@]} -gt 0 ]] && echo "  forbidden_files=${forbidden_files[*]}"
echo "  gate_cmd=$gate_cmd  max_retries=$max_retries"

# ---- L2 base prompt assembly ----
# A project module may append extra worker-contract obligations (generic: none).
export GLUERUN_WORKER_CONTRACT_EXTRA="$(gluerun_worker_contract_extra "$task_file" "$task_id" 2>/dev/null || true)"
# A project module may redirect the red-evidence log to a task-specific artifact
# (generic: empty -> the prompt keeps its default red log path).
export GLUERUN_WORKER_RED_LOG="$(gluerun_worker_red_log "$task_file" "$task_id" 2>/dev/null || true)"
l2_prompt="$run_dir/l2-prompt.md"
python3 - "$GLUERUN_ORCH_DIR/prompts/l2-test-first-developer.md" "$l2_prompt" "$task_json" "$run_id" "$packet_base_ref" <<'PY'
import json
import sys

template_path, out_path, task_raw, run_id, base_ref = sys.argv[1:6]
t = json.loads(task_raw)
with open(template_path, "r", encoding="utf-8") as f:
    tmpl = f.read()
import os
owned = t["ownedFiles"]; forbidden = t["forbiddenFiles"]; accept = t["acceptanceCriteria"]
red_log = os.environ.get("GLUERUN_WORKER_RED_LOG") or ".gluerun-evidence/red.log"
# Extra obligations contributed by an enabled project module (generic: empty).
extra_module_contract = os.environ.get("GLUERUN_WORKER_CONTRACT_EXTRA", "")
if extra_module_contract and not extra_module_contract.endswith("\n"):
    extra_module_contract += "\n"
subs = {
    "[TASK-ID]": t["taskId"], "[BRANCH]": t["workerBranch"], "[TARGET]": t["targetBranch"],
    "[OWNED FILES]": ", ".join(owned) if owned else "(none)",
    "[FORBIDDEN FILES]": "; ".join(forbidden) if forbidden else "(none)",
    "[OBJECTIVE]": t["objective"],
    "[ACCEPTANCE CRITERIA]": "\n".join(f"- {c}" for c in accept) if accept else "(none)",
}
for k, v in subs.items():
    tmpl = tmpl.replace(k, v)
contract = f"""

---

## Execution Contract For This Run (authoritative)

You run non-interactively in a Codex sandbox selected by L0 for this task. Your
working directory is the worktree for this task.

- Edit ONLY these owned files: {", ".join(owned)}. Out-of-scope edits are rejected.
- Test-first: write `{red_log}` (failing test before impl),
  `.gluerun-evidence/green.log` (passing after impl), `.gluerun-evidence/regression.log`
  (`{t['gateCommand'] or '(your gate command)'}`).
{extra_module_contract}- Do NOT run git. Leave changes uncommitted; the L1 driver commits.
- Do NOT broaden architecture beyond the objective.

Your FINAL message MUST be a single JSON object matching the state packet schema
reference `schemas/orchestration/state-packet.v0.schema.json`. Set
schema exactly to "gluerun.orchestration.state-packet.v0" and include: packetId,
runId "{run_id}", taskId "{t['taskId']}", area "{t['area']}", role "l2-developer",
status "needs-review", baseRef "{base_ref}", branch "{t['workerBranch']}",
headSha "uncommitted", workspace (abs worktree path), ownedFiles {json.dumps(owned)},
changedFiles, commands[{{cmd,exitCode,logRef}}], tests[{{name,phase,status,logRef}}]
with red+green phases, evidence[{{kind,ref}}], blockers[], nextAction, createdAt.
No additional top-level fields are permitted. Do not emit `risks`; put any
unresolved blocking condition in blockers[] and any non-blocking note in
nextAction. Emit ONLY that JSON object.
"""
with open(out_path, "w", encoding="utf-8") as f:
    f.write(tmpl + contract)
PY

# ---- Auditor prompt assembly ----
audit_prompt="$run_dir/auditor-prompt.md"
python3 - "$GLUERUN_ORCH_DIR/prompts/auditor.md" "$audit_prompt" "$task_json" "$run_id" "$run_dir" <<'PY'
import json
import sys
template_path, out_path, task_raw, run_id, run_dir = sys.argv[1:6]
t = json.loads(task_raw)
with open(template_path, "r", encoding="utf-8") as f:
    tmpl = f.read().replace("[TASK-ID]", t["taskId"])
forbidden = ", ".join(t["forbiddenFiles"]) if t["forbiddenFiles"] else "(none)"
contract = f"""

---

## Audit Context For This Run (authoritative)

- Task: {t['taskId']} ({t['area']}); worker branch {t['workerBranch']} (committed)
- Owned files: {", ".join(t['ownedFiles'])}
- Forbidden files (must NOT be modified): {forbidden}
- State packet: {run_dir}/packet.json ; gate result: {run_dir}/gate-check.json
- Worker evidence: {run_dir}/worker-evidence/

Read-only. Verify the committed diff stays within owned files, touches no
forbidden file, has red/green evidence, gate exit 0, and meets acceptance
criteria. Do NOT approve without evidence.

Your FINAL message MUST be a single JSON object matching
`schemas/orchestration/audit-verdict.v0.schema.json`: schema, taskId "{t['taskId']}",
runId "{run_id}", branch "{t['workerBranch']}", verdict
(accepted|needs-fix|blocked|needs-human), evidenceReviewed[], commandsRun[],
findings[], requiredFixes[], rationale. Emit ONLY that JSON object.
"""
with open(out_path, "w", encoding="utf-8") as f:
    f.write(tmpl + contract)
PY

if [[ "$dry_run" == "yes" ]]; then
  echo ""
  echo "DRY RUN — no worktree, no codex, no commit. Prompts assembled at $run_dir."
  gluerun_append_event "l1.dry_run" "l1 drive dry run" "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}"
  exit 0
fi

# ---- Outcome tracking + EXIT trap ----
_l1_outcome="incomplete"
_l1_lease_written="no"
l1_on_exit() {
  local code=$?
  if [[ "$_l1_outcome" == "incomplete" && "$_l1_lease_written" == "yes" ]]; then
    gluerun_lease_set_status "$task_id" "failed" 2>/dev/null || true
    gluerun_record_recovery "l1-drive exited before a terminal outcome (code $code)" \
      "$task_id" "$worker_branch" "rebuild-context" "origin" "rerun or decide" "origin" || true
    gluerun_append_event "l1.aborted" "l1 drive aborted" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"code\":$code}" || true
  fi
}
trap l1_on_exit EXIT

# ---- Worktree lifecycle: reset / orphan auto-recovery ----
remove_worktree() {
  gluerun_git_lock_acquire
  if gluerun_worktree_registered "$worktree"; then
    git -C "$GLUERUN_ROOT" worktree remove --force "$worktree" 2>/dev/null || true
  fi
  rm -rf "$worktree"
  git -C "$GLUERUN_ROOT" worktree prune 2>/dev/null || true
  gluerun_git_lock_release
}

if [[ "$reset" == "yes" ]]; then
  remove_worktree
  gluerun_with_git_lock git -C "$GLUERUN_ROOT" branch -D "$worker_branch" 2>/dev/null || true
fi

if gluerun_worktree_registered "$worktree" || [[ -e "$worktree" ]]; then
  existing_lease="$(gluerun_lease_status "$task_id" 2>/dev/null || echo none)"
  case "$existing_lease" in
    running|planned|needs-review|accepted|integrated)
      echo "active/accepted worktree for $task_id (lease: $existing_lease); refusing (use --reset)" >&2
      exit 2 ;;
    *)
      echo "auto-recovering orphaned worktree for $task_id (lease: $existing_lease)"
      remove_worktree
      gluerun_with_git_lock git -C "$GLUERUN_ROOT" branch -D "$worker_branch" 2>/dev/null || true
      gluerun_append_event "l1.orphan_recovered" "reclaimed orphaned worktree" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"priorLease\":\"$existing_lease\"}" ;;
  esac
fi

# ---- Lease + branch + worktree ----
owned_json="$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
forbidden_json="$(printf '%s\n' "${forbidden_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
gluerun_lease_write "$task_id" "$worker_branch" "$area" "l2-developer" "${owned_files[*]}" \
  "running" "$run_id" "$worktree" "$packet_base_ref" "$dispatch_batch_id" "$owned_json" "$forbidden_json"
_l1_lease_written="yes"
gluerun_append_event "l1.dispatch_started" "l1 dispatch started" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"branch\":\"$worker_branch\",\"baseSha\":\"$packet_base_ref\",\"batchId\":\"$dispatch_batch_id\"}"
gluerun_git_lock_acquire
git_ec=0
set +e
if ! git -C "$GLUERUN_ROOT" rev-parse --verify --quiet "$worker_branch" >/dev/null; then
  git -C "$GLUERUN_ROOT" branch "$worker_branch" "$branch_base"
  git_ec=$?
fi
if [[ "$git_ec" -eq 0 ]]; then
  mkdir -p "$GLUERUN_WORKTREES_DIR"
  git -C "$GLUERUN_ROOT" worktree add "$worktree" "$worker_branch"
  git_ec=$?
fi
set -e
gluerun_git_lock_release
if [[ "$git_ec" -ne 0 ]]; then
  echo "failed to create worker branch/worktree for $task_id from $branch_base" >&2
  exit "$git_ec"
fi
gluerun_append_event "l1.worktree_created" "worker worktree created" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"worktree\":\"$worktree\"}"
if [[ -n "${GLUERUN_PREWARM_CMD:-}" ]]; then
  ( cd "$worktree" && eval "$GLUERUN_PREWARM_CMD" ) >"$run_dir/prewarm.log" 2>&1 \
    || echo "  warning: prewarm command failed (exit $?); continuing" >&2
fi

# ---- One attempt: worker -> scope -> gate -> commit -> stamp -> audit ----
# Sets globals: attempt_failure (class), attempt_ctx (file). worker_rc/audit_rc
# hold the raw runner exit codes of the latest attempt (captured, not yet acted
# on — later waves branch on timeout/resume codes such as 124/86).
head_sha=""
packet="$run_dir/packet.json"
audit_record="$(gluerun_audit_record_path "$run_id")"
verdict="unknown"
attempt_failure=""
attempt_ctx=""
worker_rc=0
audit_rc=0

# Session affinity (T-E5): per-role meta FILES (separate paths) make cross-role
# session reuse structurally impossible. Strategy globals are recorded per attempt
# for the archive index (additive fields).
session_meta_implementer="$run_dir/session-implementer.json"
session_meta_reviewer="$run_dir/session-reviewer.json"
worker_strategy="fresh"
worker_strategy_reason="init"
reviewer_strategy="fresh"
reviewer_strategy_reason="init"

# Worker-runner selection (gluerun_select_l2_runner): generic engine returns the
# default runner; an enabled module may route specific tasks to an alternate
# runner (3rd arg). An explicit GLUERUN_RUNNER override always wins.
l2_runner="$(gluerun_select_l2_runner "$task_file" "$GLUERUN_RUNNER_BIN" "$SCRIPT_DIR/claude-run.sh")"
if [[ "$l2_runner" != "$GLUERUN_RUNNER_BIN" ]]; then
  echo "  module-routed L2 worker -> $(basename "$l2_runner")"
  gluerun_append_event "l1.worker_runner_selected" "worker routed to alternate runner" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"runner\":\"$(basename "$l2_runner")\"}"
fi

# ---- One attempt = three phases, called in order by the retry loop ----------
# prepare_worker_prompt <n> / run_worker_phase <n> / run_audit_phase <n>, where
# <n> is the 1-based attempt number. Globals carried between phases: fix_hints
# (in), attempt_failure/attempt_ctx (failure class + context file), head_sha,
# verdict, worker_rc/audit_rc. Failure semantics match the historical single
# run_attempt exactly: any worker-phase failure (scope/gate/commit/packet)
# aborts before the audit phase runs.

# Assemble the active worker prompt for attempt <n>: base prompt + prior-attempt
# fix hints. Later waves swap in a dedicated fix-prompt rendering here.
prepare_worker_prompt() {
  local n="$1"
  local active_prompt="$run_dir/l2-active-prompt.md"
  # Attempt 1 is always a plain copy of the base prompt (byte-identical invariant).
  if [[ "$n" -le 1 ]]; then
    cp "$l2_prompt" "$active_prompt"
    return 0
  fi
  # Structured fix prompt (T-E3): authoritative findings + scoped evidence. On a
  # renderer failure, fall back to the legacy fix_hints path verbatim. The
  # fix_hints global keeps being set in the retry loop so the legacy path (and
  # GLUERUN_FIX_PROMPT_STRUCTURED=0) stays byte-identical to today.
  if [[ "${GLUERUN_FIX_PROMPT_STRUCTURED:-1}" == "1" ]]; then
    local cur_owned_json cur_forbidden_json
    cur_owned_json="$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
    cur_forbidden_json="$(printf '%s\n' "${forbidden_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
    if gluerun_render_fix_prompt "$active_prompt" "$l2_prompt" "$run_dir" "$n" \
         "${prev_failure_class:-unknown}" "${prev_attempt_ctx:-/dev/null}" \
         "$cur_owned_json" "$cur_forbidden_json" 2>/dev/null; then
      return 0
    fi
    gluerun_append_event "l1.fix_prompt_fallback" "structured fix prompt render failed; using legacy hints" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true
  fi
  cp "$l2_prompt" "$active_prompt"
  if [[ -n "$fix_hints" ]]; then
    { echo ""; echo "---"; echo "## Previous attempt feedback (fix these, stay in scope)"; echo ""; echo "$fix_hints"; } >>"$active_prompt"
  fi
}

# Worker invocation through scope/gate/commit/packet stamping + validation.
# Sets head_sha, attempt_failure, attempt_ctx, worker_rc. Returns 0 when a
# validated packet exists on a committed branch, 1 otherwise.
run_worker_phase() {
  local n="$1"
  local active_prompt="$run_dir/l2-active-prompt.md"

  # ---- Worker runner with bounded infra-retry (T-E6) ------------------------
  # A worker "infra failure" is the runner itself failing/timing out — rc 124
  # (claude-run kills the tree on GLUERUN_CLAUDE_TIMEOUT_SEC), or rc!=0 with a truly
  # empty/missing last-message file. That is distinct from worker-no-packet (the
  # model ran fine and emitted prose: output EXISTS but carries no packet) — which
  # the packet-validation path below already classifies. We re-run ONLY the worker
  # up to GLUERUN_WORKER_INFRA_MAX extra times; this never bumps the lease retryCount.
  # QUOTA GUARD: gluerun_planner_failure_class returns "quota" (priority over timeout/
  # empty) when the log carries a usage/rate-limit marker; we must NOT swallow that
  # as worker-infra, so a quota classification falls through to the normal path
  # (the breaker/quota-backoff machinery owns it).
  local worker_infra_max="${GLUERUN_WORKER_INFRA_MAX:-1}"
  [[ "$worker_infra_max" =~ ^[0-9]+$ ]] || worker_infra_max=1
  local worker_try worker_fc

  # ---- Session affinity (T-E5): resume decision (first try only) ------------
  # Reuse the implementer's prior runtime session iff every gate passes; else go
  # fresh. Lineage head = the worktree's current HEAD. The decision is computed
  # ONCE per attempt; infra retries (try>0) always run FRESH (no --resume-session).
  local l2_runner_basename worker_prompt_sha worker_resume_id="" worker_decision
  l2_runner_basename="$(basename "$l2_runner")"
  worker_prompt_sha="$(gluerun_prompt_sha "$l2_prompt" 2>/dev/null || true)"
  local worktree_head; worktree_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)"
  worker_decision="$(gluerun_session_resume_decide "$session_meta_implementer" implementer \
    "$task_id" "$run_id" "$l2_runner_basename" "$worker_prompt_sha" "$worktree" "$worktree_head" 2>/dev/null || echo "fresh decide-error")"
  worker_strategy="${worker_decision%% *}"
  worker_strategy_reason="${worker_decision#* }"
  if [[ "$worker_strategy" == "resume" ]]; then
    worker_resume_id="$worker_strategy_reason"; worker_strategy_reason="resume"
    gluerun_append_event "context.strategy_selected" "session resume strategy selected" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"implementer\",\"attempt\":$n,\"strategy\":\"resume\",\"reason\":\"resume\",\"sessionId\":\"$worker_resume_id\"}" || true
  else
    gluerun_append_event "context.strategy_selected" "fresh-run strategy selected" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"implementer\",\"attempt\":$n,\"strategy\":\"fresh\",\"reason\":\"$worker_strategy_reason\"}" || true
  fi

  local worker_resume_failed="no"
  for ((worker_try=0; worker_try<=worker_infra_max; worker_try++)); do
    if [[ "$worker_try" -gt 0 ]]; then
      gluerun_append_event "worker.infra_retry" "worker infra failure; re-running worker only" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$worker_try,\"reason\":\"$worker_fc\"}"
      echo "  worker infra retry $worker_try/$worker_infra_max ($worker_fc)..."
    fi
    # Resume only on the FIRST try; infra retries are always fresh.
    local worker_run_args=(--level l2 -C "$worktree" --run-id "$run_id" \
      --prompt-file "$active_prompt" --output-last-message "$run_dir/last-message.json" \
      --session-meta "$session_meta_implementer")
    if [[ "$worker_try" -eq 0 && -n "$worker_resume_id" && "$worker_resume_failed" == "no" ]]; then
      echo "  running L2 worker via $l2_runner_basename (resume $worker_resume_id)..."
      worker_run_args+=(--resume-session "$worker_resume_id")
    else
      echo "  running L2 worker via $l2_runner_basename..."
    fi
    worker_rc=0
    "$l2_runner" "${worker_run_args[@]}" >"$run_dir/worker-codex.log" 2>&1 || worker_rc=$?

    # Resume-refused (86) or resume-failure (86): the runner could not reuse the
    # session. Fall back to FRESH within the SAME try (don't consume an infra/main
    # retry on a resume miss). This is a pure optimization miss; the task outcome
    # is unchanged.
    if [[ "$worker_rc" -eq 86 && -n "$worker_resume_id" && "$worker_resume_failed" == "no" ]]; then
      worker_resume_failed="yes"
      gluerun_append_event "context.resume_failed" "implementer resume failed; re-running fresh" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"implementer\",\"attempt\":$n,\"sessionId\":\"$worker_resume_id\"}" || true
      worker_strategy="fresh"; worker_strategy_reason="resume-failed"
      echo "  worker resume failed; falling back to fresh run..."
      worker_rc=0
      "$l2_runner" --level l2 -C "$worktree" --run-id "$run_id" \
        --prompt-file "$active_prompt" --output-last-message "$run_dir/last-message.json" \
        --session-meta "$session_meta_implementer" >"$run_dir/worker-codex.log" 2>&1 || worker_rc=$?
    fi

    # Classify infra-vs-not. quota -> NOT infra (let the normal/breaker path own
    # it). timeout(rc 124)/empty-output(rc!=0, empty file) -> infra: retry the
    # worker only. invalid-output (output exists, rc 0) -> NOT infra; that is a
    # potential worker-no-packet handled by packet validation below.
    worker_fc="$(gluerun_planner_failure_class "$run_dir/worker-codex.log" "$worker_rc" "$run_dir/last-message.json")"
    # "empty-output" only counts as infra when the runner itself failed (rc!=0);
    # a rc-0 run that emitted an empty file is a clean run with no packet (prose),
    # which is worker-no-packet, owned by the packet-validation path — NOT infra.
    [[ "$worker_fc" == "empty-output" && "$worker_rc" -eq 0 ]] && worker_fc="invalid-output"
    case "$worker_fc" in
      timeout|empty-output) : ;;          # infra: loop to re-run the worker
      *) break ;;                         # quota / codex-exit-with-output / clean: stop retrying
    esac
  done
  gluerun_append_event "l1.worker_completed" "l2 worker completed" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}"
  # Persisted worker infra failure (still timeout/empty after the retry budget):
  # surface worker-infra so the fast-path decider parks it; retryCount untouched.
  if [[ "$worker_fc" == "timeout" || "$worker_fc" == "empty-output" ]]; then
    attempt_failure="worker-infra"; attempt_ctx="$run_dir/worker-codex.log"
    return 1
  fi

  local worker_packet_log="$run_dir/worker-packet-validation.log"
  local worker_packet_ec=0
  gluerun_l1_prepare_worker_packet "$run_dir/last-message.json" "$run_dir/last-message.json" "$worker_packet_log" \
    || worker_packet_ec=$?
  if [[ "$worker_packet_ec" -ne 0 ]]; then
    case "$worker_packet_ec" in
      10|11)
        attempt_failure="worker-no-packet"; attempt_ctx="$run_dir/worker-codex.log" ;;
      *)
        attempt_failure="packet-invalid"; attempt_ctx="$worker_packet_log" ;;
    esac
    return 1
  fi

  if [[ -d "$worktree/.gluerun-evidence" ]]; then
    rm -rf "$run_dir/worker-evidence"; cp -R "$worktree/.gluerun-evidence" "$run_dir/worker-evidence"
  fi
  local storage_guard_log="$run_dir/module-packet-guard.log"
  if ! gluerun_packet_module_guard "$run_dir/last-message.json" "$task_file" "$worktree" "$run_dir" >"$storage_guard_log" 2>&1; then
    attempt_failure="packet-invalid"; attempt_ctx="$storage_guard_log"; return 1
  fi

  # Scope (owned allow + forbidden deny).
  local scope_args=(--worktree "$worktree")
  local f
  for f in "${owned_files[@]}"; do scope_args+=(--allow-prefix "$f"); done
  for f in "${forbidden_files[@]}"; do scope_args+=(--forbid-prefix "$f"); done
  if ! "$SCRIPT_DIR/scope-check.sh" "${scope_args[@]}" >"$run_dir/scope-check.log" 2>&1; then
    attempt_failure="scope-violation"; attempt_ctx="$run_dir/scope-check.log"; return 1
  fi
  if gluerun_strict_proof_skip_detected "$task_file" "$worktree" "${owned_files[@]}"; then
    {
      echo "strict proof task introduced a skipped proof path"
      echo "task=$task_id"
      echo "owned_files=${owned_files[*]}"
      echo "acceptance forbids silent or skipped proof paths"
    } >"$run_dir/proof-skip-check.log"
    attempt_failure="proof-skip-detected"; attempt_ctx="$run_dir/proof-skip-check.log"; return 1
  fi

  # Regression gate.
  local gate_exit=0
  ( cd "$worktree" && GLUERUN_ROOT="$GLUERUN_ROOT" GLUERUN_STATE_DIR="$GLUERUN_STATE_DIR" \
      "$SCRIPT_DIR/gate-check.sh" "$run_id" -- bash -c "$gate_cmd" ) || gate_exit=$?
  if [[ "$gate_exit" -ne 0 ]]; then
    attempt_failure="gate-red"; attempt_ctx="$run_dir/gate-check.log"; return 1
  fi
  gluerun_append_event "l1.gate_passed" "regression gate passed" "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}"

  # Secret-scan staged-to-be content (working changes), then stage owned + commit.
  for f in "${owned_files[@]}"; do [[ -e "$worktree/$f" ]] && git -C "$worktree" add -- "$f"; done
  if git -C "$worktree" diff --cached --quiet; then
    attempt_failure="no-changes"; attempt_ctx="$run_dir/worker-codex.log"; return 1
  fi
  if ! "$SCRIPT_DIR/secret-scan.sh" --worktree "$worktree" --staged >"$run_dir/secret-scan.log" 2>&1; then
    git -C "$worktree" reset -q
    attempt_failure="secret-detected"; attempt_ctx="$run_dir/secret-scan.log"; return 1
  fi
  gluerun_git_lock_acquire
  local commit_ec=0
  set +e
  git -C "$worktree" -c user.name="$GLUERUN_GIT_L1_NAME" -c user.email="$GLUERUN_GIT_L1_EMAIL" \
    commit -q -m "$task_id: ${test_policy} worker output (run $run_id)" \
    -m "Driven by L1 from $packet_base_ref. Owned: ${owned_files[*]}."
  commit_ec=$?
  set -e
  gluerun_git_lock_release
  if [[ "$commit_ec" -ne 0 ]]; then
    attempt_failure="commit-failed"; attempt_ctx="$run_dir/worker-codex.log"; return 1
  fi
  head_sha="$(git -C "$worktree" rev-parse HEAD)"
  gluerun_append_event "l1.committed" "worker branch committed" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"headSha\":\"$head_sha\"}"

  mapfile -t changed_files < <(git -C "$worktree" diff --name-only "$target_branch"...HEAD)
  python3 - "$run_dir/last-message.json" "$packet" "$run_id" "$task_id" "$area" \
    "$worker_branch" "$packet_base_ref" "$head_sha" "$worktree" \
    "$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')" \
    "$(printf '%s\n' "${changed_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')" <<'PY'
import json, sys
(src,dst,run_id,task_id,area,branch,base_ref,head_sha,workspace,owned_json,changed_json)=sys.argv[1:12]
with open(src) as f: p=json.load(f)
p["schema"]="gluerun.orchestration.state-packet.v0"; p["runId"]=run_id; p["taskId"]=task_id
p["area"]=area; p["role"]=p.get("role") or "l2-developer"; p["baseRef"]=base_ref
p["branch"]=branch; p["headSha"]=head_sha; p["workspace"]=workspace
p["ownedFiles"]=json.loads(owned_json)
changed=json.loads(changed_json)
if changed: p["changedFiles"]=changed
p.setdefault("packetId",f"{run_id}-packet"); p.setdefault("changedFiles",[])
for k in ("commands","tests","evidence","blockers"): p.setdefault(k,[])
p.setdefault("nextAction","await auditor verdict"); p.setdefault("status","needs-review")
p["evidence"].append({"kind":"gate-check","ref":f"runs/{run_id}/gate-check.json"})
with open(dst,"w") as f: json.dump(p,f,indent=2); f.write("\n")
PY
  gluerun_validate_packet_basic "$packet" >/dev/null 2>&1 || { attempt_failure="packet-invalid"; attempt_ctx="$packet"; return 1; }

  # Implementer context capsule (additive observability; never aborts the
  # drive). Scope arrays are the CURRENT post-amend scope, not the packet's.
  local capsule_owned capsule_forbidden
  capsule_owned="$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  capsule_forbidden="$(printf '%s\n' "${forbidden_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  gluerun_capsule_write_implementer "$run_dir" "$n" "$packet" "$head_sha" "$capsule_owned" "$capsule_forbidden" >/dev/null 2>&1 \
    || gluerun_append_event "l1.capsule_write_failed" "implementer capsule write failed (non-fatal)" \
         "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"implementer\",\"attempt\":$n}" || true

  # Session affinity (T-E5): merge host-authority fields into the runner-written
  # implementer meta so the NEXT attempt can resume it. headShaAtCreate = the
  # committed head (the lineage anchor the resume decider checks). Never fatal.
  gluerun_session_meta_finalize "$session_meta_implementer" implementer "$task_id" "$run_id" \
    "$l2_runner_basename" "$worker_prompt_sha" "$head_sha" "$n" >/dev/null 2>&1 || true
  return 0
}

# Auditor invocation through verdict extraction + packet evidence append.
# Sets verdict, attempt_failure, attempt_ctx, audit_rc. Returns 0 when the
# attempt is acceptable (verdict accepted, or audits disabled), 1 otherwise.
run_audit_phase() {
  local n="$1"

  # Re-audit delta prompt (T-E4). prior_head is the existing reviewer capsule's
  # auditedHeadSha (read BEFORE the capsule is overwritten this attempt) — the
  # SHA the auditor last reviewed. Render to a NEW per-attempt file and pass THAT
  # to the runner; on attempt 1 / no capsule / empty prior_head the renderer is a
  # plain copy (byte-identical to the base audit prompt). Renderer failure ->
  # warning event + fall back to the base audit prompt.
  local prior_head active_audit_prompt="$run_dir/auditor-active-prompt.md"
  prior_head="$(gluerun_json_field "$run_dir/reviewer-capsule.json" auditedHeadSha 2>/dev/null || true)"
  if gluerun_render_reaudit_prompt "$active_audit_prompt" "$audit_prompt" "$run_dir" "$n" \
       "$prior_head" "$head_sha" "$worktree" 2>/dev/null; then
    :
  else
    gluerun_append_event "l1.reaudit_prompt_fallback" "re-audit prompt render failed; using base audit prompt" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true
    cp "$audit_prompt" "$active_audit_prompt" 2>/dev/null || active_audit_prompt="$audit_prompt"
  fi

  # ---- Auditor runner with bounded infra-retry (T-E6) -----------------------
  # An auditor "infra failure" is the runner itself timing out (rc 124) / refusing
  # (later-wave rc 86), the record file never appearing, or output that carries no
  # parseable JSON verdict (broken/empty model output, the l1.audit_unparseable
  # path) — distinct from a real needs-fix verdict. We re-run ONLY the auditor,
  # fresh (no session reuse), up to GLUERUN_AUDIT_INFRA_MAX extra times. This never
  # bumps the lease retryCount and never re-runs the worker. If a parseable verdict
  # appears on any try, we proceed to the normal ledger/capsule/verdict handling;
  # if exhausted, the attempt fails as audit-infra and the (fast-path) decider parks it.
  local audit_infra_max="${GLUERUN_AUDIT_INFRA_MAX:-2}"
  [[ "$audit_infra_max" =~ ^[0-9]+$ ]] || audit_infra_max=2
  verdict="unknown"

  # ---- Session affinity (T-E5): reviewer resume decision (first try only) ----
  # The auditor runs on GLUERUN_RUNNER_BIN (cross-model independence preserved). It
  # uses a SEPARATE per-role meta file + role gate, so the reviewer can NEVER be
  # offered the implementer's session. Lineage head = head_sha (the audited head).
  # prompt_sha is the BASE auditor prompt (the active prompt is per-attempt delta).
  local audit_runner_basename reviewer_prompt_sha reviewer_resume_id="" reviewer_decision
  audit_runner_basename="$(basename "$GLUERUN_RUNNER_BIN")"
  reviewer_prompt_sha="$(gluerun_prompt_sha "$audit_prompt" 2>/dev/null || true)"
  reviewer_decision="$(gluerun_session_resume_decide "$session_meta_reviewer" reviewer \
    "$task_id" "$run_id" "$audit_runner_basename" "$reviewer_prompt_sha" "$worktree" "$head_sha" 2>/dev/null || echo "fresh decide-error")"
  reviewer_strategy="${reviewer_decision%% *}"
  reviewer_strategy_reason="${reviewer_decision#* }"
  if [[ "$reviewer_strategy" == "resume" ]]; then
    reviewer_resume_id="$reviewer_strategy_reason"; reviewer_strategy_reason="resume"
    gluerun_append_event "context.strategy_selected" "session resume strategy selected" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"reviewer\",\"attempt\":$n,\"strategy\":\"resume\",\"reason\":\"resume\",\"sessionId\":\"$reviewer_resume_id\"}" || true
  else
    gluerun_append_event "context.strategy_selected" "fresh-run strategy selected" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"reviewer\",\"attempt\":$n,\"strategy\":\"fresh\",\"reason\":\"$reviewer_strategy_reason\"}" || true
  fi
  local reviewer_resume_failed="no"

  local audit_parsed="no" audit_try infra_reason
  for ((audit_try=0; audit_try<=audit_infra_max; audit_try++)); do
    if [[ "$audit_try" -gt 0 ]]; then
      gluerun_append_event "audit.infra_retry" "auditor infra failure; re-running auditor only" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$audit_try,\"reason\":\"$infra_reason\"}"
      echo "  auditor infra retry $audit_try/$audit_infra_max ($infra_reason)..."
    fi
    # Resume only on the FIRST try; wave-4 audit-infra retries stay FRESH.
    local audit_run_args=(--level readonly -C "$worktree" --run-id "$run_id" \
      --prompt-file "$active_audit_prompt" --output-last-message "$audit_record" \
      --session-meta "$session_meta_reviewer")
    if [[ "$audit_try" -eq 0 && -n "$reviewer_resume_id" && "$reviewer_resume_failed" == "no" ]]; then
      echo "  running auditor via $audit_runner_basename (read-only, resume $reviewer_resume_id)..."
      audit_run_args+=(--resume-session "$reviewer_resume_id")
    else
      echo "  running auditor via $audit_runner_basename (read-only)..."
    fi
    audit_rc=0
    "$GLUERUN_RUNNER_BIN" "${audit_run_args[@]}" >/dev/null 2>&1 || audit_rc=$?

    # Resume-refused/failure (86): fall back to FRESH within the SAME try (don't
    # consume an infra retry on a resume miss). Pure optimization miss.
    if [[ "$audit_rc" -eq 86 && -n "$reviewer_resume_id" && "$reviewer_resume_failed" == "no" ]]; then
      reviewer_resume_failed="yes"
      gluerun_append_event "context.resume_failed" "reviewer resume failed; re-running fresh" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"reviewer\",\"attempt\":$n,\"sessionId\":\"$reviewer_resume_id\"}" || true
      reviewer_strategy="fresh"; reviewer_strategy_reason="resume-failed"
      echo "  auditor resume failed; falling back to fresh run..."
      audit_rc=0
      "$GLUERUN_RUNNER_BIN" --level readonly -C "$worktree" --run-id "$run_id" \
        --prompt-file "$active_audit_prompt" --output-last-message "$audit_record" \
        --session-meta "$session_meta_reviewer" >/dev/null 2>&1 || audit_rc=$?
    fi
    # Classify this try. rc 124 = runner timeout (claude-run kills the tree).
    if [[ "$audit_rc" -eq 124 ]]; then
      infra_reason="timeout"
    elif [[ ! -f "$audit_record" ]]; then
      infra_reason="no-record"
    elif ! gluerun_extract_json "$audit_record" "$audit_record" 2>/dev/null; then
      # No parseable JSON verdict (prose-only, refusal, or truncated output). Keep
      # the existing l1.audit_unparseable signal firing per infra try.
      infra_reason="unparseable"
      gluerun_append_event "l1.audit_unparseable" "auditor produced no parseable JSON verdict" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}"
    else
      audit_parsed="yes"
      break
    fi
  done
  if [[ "$audit_parsed" == "yes" ]]; then
    {
      verdict="$(gluerun_json_field "$audit_record" verdict 2>/dev/null || echo unknown)"
      # Findings ledger + reviewer capsule on every parseable verdict (additive
      # observability; never aborts the drive). prior_head is the previous
      # attempt's auditedHeadSha when a reviewer capsule already exists.
      local ledger_out ledger_event
      ledger_out="$(gluerun_findings_ledger_update "$run_dir" "$n" "$audit_record" 2>/dev/null)" \
        || { ledger_out=""; gluerun_append_event "l1.findings_ledger_failed" "findings ledger update failed (non-fatal)" \
               "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true; }
      if [[ -n "$ledger_out" ]]; then
        ledger_event="$(python3 -c 'import json,sys
parts = dict(kv.split("=", 1) for kv in sys.argv[3].split() if "=" in kv)
print(json.dumps({"taskId": sys.argv[1], "runId": sys.argv[2], "attempt": int(sys.argv[4]),
                  "open": int(parts.get("open", 0)), "resolved": int(parts.get("resolved", 0)),
                  "new": int(parts.get("new", 0))}, separators=(",", ":")))' \
          "$task_id" "$run_id" "$ledger_out" "$n" 2>/dev/null || true)"
        [[ -n "$ledger_event" ]] && { gluerun_append_event "findings.ledger_updated" "findings ledger updated" "$ledger_event" || true; }
      fi
      # prior_head was captured at the top of run_audit_phase (before this
      # attempt overwrites the reviewer capsule); reuse it for the diffRange.
      gluerun_capsule_write_reviewer "$run_dir" "$n" "$audit_record" "$prior_head" "$head_sha" >/dev/null 2>&1 \
        || gluerun_append_event "l1.capsule_write_failed" "reviewer capsule write failed (non-fatal)" \
             "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"reviewer\",\"attempt\":$n}" || true
      # Session affinity (T-E5): merge host-authority fields into the reviewer meta
      # so a later audit try (this run) can resume it. headShaAtCreate = head_sha
      # (the audited head). Never fatal.
      gluerun_session_meta_finalize "$session_meta_reviewer" reviewer "$task_id" "$run_id" \
        "$audit_runner_basename" "$reviewer_prompt_sha" "$head_sha" "$n" >/dev/null 2>&1 || true
    }
  else
    # Auditor infra failure persisted across GLUERUN_AUDIT_INFRA_MAX fresh re-runs:
    # a model decider cannot fix broken/empty auditor output. Surface as
    # audit-infra so the (fast-path) decider parks it; retryCount stays untouched.
    gluerun_append_event "l1.audit_completed" "auditor completed (infra failure)" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"verdict\":\"infra\"}"
    attempt_failure="audit-infra"; attempt_ctx="$run_dir/worker-codex.log"
    [[ -f "$audit_record" ]] && attempt_ctx="$audit_record"
    return 1
  fi
  echo "  auditor verdict=$verdict"
  gluerun_append_event "l1.audit_completed" "auditor completed" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"verdict\":\"$verdict\"}"
  python3 - "$packet" "$run_id" <<'PY'
import json,sys
packet,run_id=sys.argv[1],sys.argv[2]
with open(packet) as f: p=json.load(f)
ref=f"runs/{run_id}/audit.json"
if not any(e.get("kind")=="audit" and e.get("ref")==ref for e in p["evidence"]):
    p["evidence"].append({"kind":"audit","ref":ref})
with open(packet,"w") as f: json.dump(p,f,indent=2); f.write("\n")
PY

  if [[ "$require_audit" == "1" && "$verdict" != "accepted" ]]; then
    attempt_failure="audit-$verdict"; attempt_ctx="$audit_record"; return 1
  fi
  return 0
}

# Archive one attempt's artifacts (T-E1): wraps gluerun_attempt_archive with the
# driver's globals; a failure here NEVER aborts the drive.
# args: n failure_class decider_action authority
archive_attempt() {
  GLUERUN_ATTEMPT_TASK_ID="$task_id" GLUERUN_ATTEMPT_STARTED_AT="$attempt_started_at" \
    GLUERUN_ATTEMPT_WORKER_STRATEGY="${worker_strategy:-}" \
    GLUERUN_ATTEMPT_REVIEWER_STRATEGY="${reviewer_strategy:-}" \
    gluerun_attempt_archive "$run_dir" "$1" "$2" "$verdict" "$head_sha" "$3" "$4" >/dev/null 2>&1 \
    || { gluerun_append_event "l1.attempt_archive_failed" "attempt archive failed (non-fatal)" \
           "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"n\":$1}" 2>/dev/null || true; }
}

# ---- Decider-driven retry loop ----
# prev_failure_class/prev_attempt_ctx carry the PRIOR attempt's failure into the
# next prepare_worker_prompt (the per-iteration reset clears attempt_failure
# before the structured fix prompt is rendered); they mirror fix_hints.
accepted="no"; waiver="no"; fix_hints=""; prev_failure_class=""; prev_attempt_ctx=""; terminal_action=""
terminal_authority="decider"
terminal_rationale=""
attempt_started_at=""
for ((attempt=0; attempt<=max_retries; attempt++)); do
  [[ "$attempt" -gt 0 ]] && echo "  retry attempt $attempt/$max_retries (last: $attempt_failure)"
  n=$((attempt + 1))
  attempt_started_at="$(gluerun_timestamp)"
  attempt_failure=""; attempt_ctx=""
  verdict="unknown"; head_sha=""
  attempt_ok="no"
  prepare_worker_prompt "$n"
  if run_worker_phase "$n"; then
    if run_audit_phase "$n"; then attempt_ok="yes"; fi
  fi
  if [[ "$attempt_ok" == "yes" ]]; then
    accepted="yes"
    archive_attempt "$n" "" "accept" "l1"
    break
  fi

  blocker_rationale="$(gluerun_terminal_blocker_rationale "$attempt_failure" "${attempt_ctx:-/dev/null}" 2>/dev/null || true)"
  if [[ -n "$blocker_rationale" ]]; then
    terminal_action="escalate-parked"
    terminal_authority="l1"
    terminal_rationale="$blocker_rationale"
    echo "  $attempt_failure: parking (project blocker)"
    archive_attempt "$n" "$attempt_failure" "escalate-parked" "l1"
    break
  fi

  # Failure -> decider. Try the policy fast-path first (T-F1): for clear-cut
  # classes with retry budget it resolves the action WITHOUT a model round-trip,
  # records provenance as authority=policy, and skips decide.sh. budget accounting
  # mirrors the loop's own retry-vs-park test below ($attempt vs max_retries), so
  # "retries left" is computed identically. An empty fast action falls through to
  # the model decider unchanged (authority=decider).
  decider_authority="decider"
  action=""
  fast_action="$(gluerun_decider_fast_action "$attempt_failure" "$attempt" "$max_retries" "$prev_failure_class")"
  if [[ -n "$fast_action" ]]; then
    action="$fast_action"
    decider_authority="policy"
    echo "  failure: $attempt_failure -> fast-path: $action"
    "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "decide:$action" \
      --rationale "fast-path: $attempt_failure -> $action" --run "$run_id" \
      --branch "$worker_branch" --authority policy >/dev/null 2>&1 || true
    gluerun_append_event "decider.fast_path" "decider fast-path resolved a failure" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"failureClass\":\"$attempt_failure\",\"action\":\"$action\",\"retryCount\":$attempt}"
  else
    # Failure -> consult the autonomous decider.
    echo "  failure: $attempt_failure -> consulting decider..."
    dec_out="$("$SCRIPT_DIR/decide.sh" --task "$task_id" --failure-class "$attempt_failure" \
      --branch "$worker_branch" --run "$run_id" --context-file "${attempt_ctx:-/dev/null}" \
      --worktree "$worktree" 2>/dev/null || true)"
    action="$(printf '%s\n' "$dec_out" | sed -n 's/^action=//p' | tail -1)"
    [[ -n "$action" ]] || action="escalate-parked"
    echo "  decider: $action"
  fi

  case "$action" in
    retry|rerun-tests|rebuild-context|revalidate-evidence|amend-scope)
      if [[ "$attempt" -ge "$max_retries" ]]; then
        terminal_action="escalate-parked"
        archive_attempt "$n" "$attempt_failure" "escalate-parked" "l1"
        break
      fi
      gluerun_lease_bump_retry "$task_id" >/dev/null 2>&1 || true
      # Feed the failure context back to the worker as fix hints. prev_* mirror
      # this for the structured fix prompt (read after the per-iteration reset).
      fix_hints="The previous attempt failed with: $attempt_failure. Address it. Findings:"$'\n'"$(tail -c 3000 "${attempt_ctx:-/dev/null}" 2>/dev/null || true)"
      prev_failure_class="$attempt_failure"
      prev_attempt_ctx="${attempt_ctx:-/dev/null}"
      if [[ "$action" == "amend-scope" && "$attempt_failure" == "scope-violation" ]]; then
        # Minimally widen owned files with the disallowed (not forbidden) paths.
        while IFS= read -r p; do
          p="$(echo "$p" | sed 's/^ *//')"
          [[ -n "$p" ]] || continue
          if ! gluerun_scope_amendment_path_allowed "$p"; then
            echo "  amend-scope: ignored generated/local path $p"
            continue
          fi
          already_owned="no"
          for owned in "${owned_files[@]}"; do
            [[ "$owned" == "$p" ]] && already_owned="yes" && break
          done
          [[ "$already_owned" == "no" ]] && owned_files+=("$p")
        done < <(sed -n '/disallowed paths:/,/allowed prefixes:/p' "$run_dir/scope-check.log" 2>/dev/null | grep -E '^  ' | grep -v 'prefixes:' || true)
        echo "  amend-scope: owned files now ${owned_files[*]}"
        # Persist the widened scope to the lease so the parallel-L1 scheduler's
        # scope-overlap guard (which reads lease.ownedFiles) cannot dispatch a
        # concurrent task that collides with a path this drive just took ownership of.
        amended_owned_json="$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
        gluerun_lease_update_owned "$task_id" "$amended_owned_json" 2>/dev/null || true
      fi
      archive_attempt "$n" "$attempt_failure" "$action" "$decider_authority"
      continue ;;
    accept-waiver)
      accepted="yes"; waiver="yes"
      archive_attempt "$n" "$attempt_failure" "accept-waiver" "$decider_authority"
      break ;;
    *)
      terminal_action="$action"
      terminal_authority="$decider_authority"
      archive_attempt "$n" "$attempt_failure" "$action" "$decider_authority"
      break ;;
  esac
done

# ---- Terminal (non-accept) handling — never blocks on a human ----
if [[ "$accepted" != "yes" ]]; then
  _l1_outcome="terminal"
  [[ -n "$terminal_action" ]] || terminal_action="escalate-parked"
  [[ -n "$terminal_rationale" ]] || terminal_rationale="decider terminal action after $attempt_failure"
  case "$terminal_action" in
    supersede) gluerun_lease_set_status "$task_id" "superseded" 2>/dev/null || true; gluerun_task_set_status "$task_file" "superseded" || true ;;
    cancel)    gluerun_lease_set_status "$task_id" "cancelled"  2>/dev/null || true; gluerun_task_set_status "$task_file" "cancelled"  || true ;;
    split-task|fork) gluerun_lease_set_status "$task_id" "blocked" 2>/dev/null || true; gluerun_task_set_status "$task_file" "blocked" || true ;;
    *)         gluerun_lease_set_status "$task_id" "blocked" 2>/dev/null || true; gluerun_task_set_status "$task_file" "blocked" || true ;;
  esac
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "$terminal_action" \
    --rationale "$terminal_rationale" --run "$run_id" --branch "$worker_branch" --authority "$terminal_authority" || true
  gluerun_append_event "l1.task_terminal" "l1 task ended without acceptance" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"action\":\"$terminal_action\",\"lastFailure\":\"$attempt_failure\"}"
  echo ""
  echo "NOT ACCEPTED ($terminal_action): $task_id — recorded and parked; loop continues elsewhere."
  echo "  packet: $packet  audit: $audit_record  worktree: $worktree"
  exit 3
fi

# ---- Accept: finalize status BEFORE inbox placement, then enqueue ----
python3 - "$packet" "$waiver" <<'PY'
import json, sys
packet, waiver = sys.argv[1], sys.argv[2]
with open(packet) as f: p=json.load(f)
p["status"]="accepted"
p["nextAction"]="import into control state and reconcile"
if waiver=="yes":
    p["evidence"].append({"kind":"waiver","ref":"decider:accept-waiver"})
with open(packet,"w") as f: json.dump(p,f,indent=2); f.write("\n")
PY

gluerun_lease_set_status "$task_id" "accepted"
gluerun_task_set_status "$task_file" "accepted"
dec_rationale="auditor accepted; regression gate green; scope clean"
[[ "$waiver" == "yes" ]] && dec_rationale="accepted via decider waiver (auditor: $verdict); gate green"
"$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "accept" \
  --rationale "$dec_rationale" --run "$run_id" --branch "$worker_branch"

inbox_packet="$GLUERUN_INBOX_DIR/$run_id.json"
cp "$packet" "$inbox_packet.tmp"
mv "$inbox_packet.tmp" "$inbox_packet"
_l1_outcome="accepted"
gluerun_append_event "l1.task_accepted" "l1 task accepted" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"branch\":\"$worker_branch\",\"headSha\":\"$head_sha\",\"waiver\":\"$waiver\"}"

echo ""
echo "ACCEPTED: $task_id @ $head_sha (waiver=$waiver)"
echo "  packet: $inbox_packet  audit: $audit_record (verdict: $verdict)"
echo "  next: 'make orch-reconcile' to import, or let L0 actuate."
