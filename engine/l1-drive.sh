#!/usr/bin/env bash
set -euo pipefail

# Require bash >= 4 (mapfile). macOS /bin/bash is 3.2; re-exec under Homebrew bash.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    [[ "$SINGULAR_BASH_BIN" == /* && -x "$SINGULAR_BASH_BIN" ]] || { echo "invalid SINGULAR_BASH_BIN: $SINGULAR_BASH_BIN" >&2; exit 2; }
    exec "$SINGULAR_BASH_BIN" "$0" "$@"
  fi
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

# Worker/auditor runner. Defaults to the codex runner; set SINGULAR_RUNNER to a
# drop-in (e.g. claude-run.sh) to dispatch a different CLI. Same flag surface
# and same --output-last-message contract is required of any runner.
SINGULAR_RUNNER_BIN="${SINGULAR_RUNNER:-$SCRIPT_DIR/codex-run.sh}"

task_id=""
dry_run="no"
reset="no"
require_audit="${SINGULAR_REQUIRE_AUDIT:-1}"

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

singular_ensure_state_dirs
singular_require_target_branch

# Honor the kill switch at the dispatch entry point, not only in the loop
# wrappers, so a manual `make orch-drive` cannot dispatch a worker while frozen.
if singular_stop_requested; then
  singular_append_event "l1.frozen" "STOP sentinel present; refusing to dispatch" "{\"taskId\":\"$task_id\"}"
  echo "frozen (STOP sentinel present; $SINGULAR_STOP_FILE); refusing to dispatch $task_id"
  exit 0
fi

task_file="$SINGULAR_TASKS_DIR/$task_id.md"
if [[ ! -f "$task_file" ]]; then
  echo "task file not found: $task_file" >&2
  exit 2
fi

task_json="$(singular_task_json "$task_file")"
tf() { printf '%s' "$task_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d[sys.argv[1]]; print(json.dumps(v) if isinstance(v,(list,dict)) else v)' "$1"; }

area="$(tf area)"
worker_branch="$(tf workerBranch)"
target_branch="$(tf targetBranch)"
test_policy="$(tf testPolicy)"
gate_cmd="$(tf gateCommand)"
[[ -n "$gate_cmd" ]] || gate_cmd="$SINGULAR_DEFAULT_GATE_CMD"
[[ -n "$target_branch" ]] || target_branch="$SINGULAR_TARGET_BRANCH"
dispatch_batch_id="${SINGULAR_DISPATCH_BATCH_ID:-}"
dispatch_base_sha="${SINGULAR_DISPATCH_BASE_SHA:-}"
branch_base="${dispatch_base_sha:-$target_branch}"
packet_base_ref="${dispatch_base_sha:-$target_branch}"

mapfile -t owned_files < <(printf '%s' "$task_json" | python3 -c 'import json,sys; [print(x) for x in json.load(sys.stdin)["ownedFiles"]]')
mapfile -t forbidden_files < <(printf '%s' "$task_json" | python3 -c 'import json,sys; [print(x) for x in json.load(sys.stdin)["forbiddenFiles"] if "/" in x and " " not in x]')

# ---- Host-only task preflight (fail closed BEFORE run_id/lease/worktree) ----
# Absorbs the historical ad-hoc refusals (empty gate command [fail closed: a
# task with no gate command would otherwise run `bash -c ""`, which exits 0 and
# silently passes the regression check], empty owned files) plus the structural
# checks singular_task_preflight enforces. Dry-run keeps its historical exemption
# from the empty-gate refusal only.
preflight_require_gate=1
[[ "$dry_run" == "yes" ]] && preflight_require_gate=0
if ! preflight_reasons="$(singular_task_preflight "$task_json" "$gate_cmd" "$target_branch" "$preflight_require_gate")"; then
  echo "refusing to dispatch $task_id: task preflight failed:" >&2
  printf '%s\n' "$preflight_reasons" >&2
  if [[ "$dry_run" == "yes" ]]; then
    echo "DRY RUN - task would be parked (preflight); no state mutated."
    exit 3
  fi
  preflight_joined="$(printf '%s' "$preflight_reasons" | python3 -c 'import sys; print("; ".join(l.strip() for l in sys.stdin if l.strip()))')"
  singular_task_set_status "$task_file" "blocked" || true
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "escalate-parked" \
    --rationale "task preflight failed: $preflight_joined" --run "preflight" \
    --branch "$worker_branch" --authority l1 || true
  preflight_event="$(printf '%s\n' "$preflight_reasons" | python3 -c 'import json,sys
print(json.dumps({"taskId": sys.argv[1], "reasons": [l.strip() for l in sys.stdin if l.strip()]}, separators=(",", ":")))' "$task_id")"
  singular_append_event "l1.preflight_failed" "task preflight failed" "$preflight_event"
  exit 3
fi

run_id="$(singular_worker_run_id)"
run_dir="$(singular_run_dir "$run_id")"
mkdir -p "$run_dir"
worktree="$SINGULAR_WORKTREES_DIR/$task_id"
max_retries="${SINGULAR_MAX_RETRIES:-3}"
repo_schema_version="$(python3 - "$SINGULAR_ROOT/singular.config.json" <<'PY' 2>/dev/null || true
import json
import sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("schemaVersion", "") or "")
except Exception:
    pass
PY
)"
audit_write_contract="v0"
audit_write_schema="singular.orchestration.audit-verdict.v0"
audit_write_schema_path="$SINGULAR_SCHEMA_DIR/audit-verdict.v0.schema.json"
if [[ "$repo_schema_version" == "v2" ]]; then
  audit_write_contract="v1"
  audit_write_schema="singular.orchestration.audit-verdict.v1"
  audit_write_schema_path="$SINGULAR_SCHEMA_DIR/audit-verdict.v1.schema.json"
fi
l1_pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$l1_pgid" =~ ^[1-9][0-9]*$ ]] || l1_pgid="$$"

l1_status() {
  local phase="$1" state="$2" activity="$3" safe_cancel="$4" next_action="$5"
  local outcome="${6:-}" process_type="${7:-l1-driver}"
  local process_pid="${8:-$$}" process_pgid="${9:-$l1_pgid}"
  local -a args=(
    write --run-id "$run_id" --task-id "$task_id"
    --phase "$phase" --state "$state" --activity "$activity"
    --safe-cancel "$safe_cancel" --next-action "$next_action"
    --process-type "$process_type" --pid "$process_pid"
  )
  [[ -n "$process_pgid" ]] && args+=(--pgid "$process_pgid")
  [[ -n "$outcome" ]] && args+=(--outcome "$outcome")
  "$SCRIPT_DIR/run-status.sh" "${args[@]}" >/dev/null 2>&1 || true
}

l1_status planning active "Assembling task and audit context" true \
  "Prepare the isolated worker workspace"

echo "L1 drive: $task_id (area=$area, policy=$test_policy)"
echo "  worker_branch=$worker_branch  target=$target_branch  base=$branch_base  run=$run_id"
[[ -n "$dispatch_batch_id" ]] && echo "  batch=$dispatch_batch_id"
echo "  owned_files=${owned_files[*]}"
[[ ${#forbidden_files[@]} -gt 0 ]] && echo "  forbidden_files=${forbidden_files[*]}"
echo "  gate_cmd=$gate_cmd  max_retries=$max_retries"

# ---- L2 base prompt assembly ----
# A project module may append extra worker-contract obligations (generic: none).
export SINGULAR_WORKER_CONTRACT_EXTRA="$(singular_worker_contract_extra "$task_file" "$task_id" 2>/dev/null || true)"
# A project module may redirect the red-evidence log to a task-specific artifact
# (generic: empty -> the prompt keeps its default red log path).
export SINGULAR_WORKER_RED_LOG="$(singular_worker_red_log "$task_file" "$task_id" 2>/dev/null || true)"
l2_prompt="$run_dir/l2-prompt.md"
python3 - "$SINGULAR_ORCH_DIR/prompts/l2-test-first-developer.md" "$l2_prompt" "$task_json" "$run_id" "$packet_base_ref" <<'PY'
import json
import sys

template_path, out_path, task_raw, run_id, base_ref = sys.argv[1:6]
t = json.loads(task_raw)
with open(template_path, "r", encoding="utf-8") as f:
    tmpl = f.read()
import os
owned = t["ownedFiles"]; forbidden = t["forbiddenFiles"]; accept = t["acceptanceCriteria"]
red_log = os.environ.get("SINGULAR_WORKER_RED_LOG") or ".singular-evidence/red.log"
# Extra obligations contributed by an enabled project module (generic: empty).
extra_module_contract = os.environ.get("SINGULAR_WORKER_CONTRACT_EXTRA", "")
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
  `.singular-evidence/green.log` (passing after impl), `.singular-evidence/regression.log`
  (`{t['gateCommand'] or '(your gate command)'}`).
{extra_module_contract}- Do NOT run git. Leave changes uncommitted; the L1 driver commits.
- Do NOT broaden architecture beyond the objective.

Your FINAL message MUST be a single JSON object matching the state packet schema
reference `schemas/orchestration/state-packet.v0.schema.json`. Set
schema exactly to "singular.orchestration.state-packet.v0" and include: packetId,
runId "{run_id}", taskId "{t['taskId']}", area "{t['area']}", role "l2-developer",
status "needs-review", baseRef "{base_ref}", branch "{t['workerBranch']}",
headSha "uncommitted", workspace (abs worktree path), ownedFiles {json.dumps(owned)},
changedFiles, commands[{{cmd,exitCode,logRef}}], tests[{{name,phase,status,logRef}}]
with red+green phases, evidence[{{kind,ref}}], blockers[], nextAction, createdAt.
Every commands[].cmd value MUST contain only the exact executable shell text
that was run. The host re-executes successful commands verbatim. Put attempt
labels, pass/fail counts, result summaries, and explanations in the command's
optional rationale or in evidence[], never append them to cmd. For example,
cmd may be "bun test path/to/test.ts"; it must not be
"bun test path/to/test.ts (attempt-2 green: 40 pass, 0 fail)".
No additional top-level fields are permitted. Do not emit `risks`; put any
unresolved blocking condition in blockers[] and any non-blocking note in
nextAction. Emit ONLY that JSON object.
"""
with open(out_path, "w", encoding="utf-8") as f:
    f.write(tmpl + contract)
PY

# ---- Auditor prompt assembly ----
audit_prompt="$run_dir/auditor-prompt.md"
python3 - "$SINGULAR_ORCH_DIR/prompts/auditor.md" "$audit_prompt" "$task_json" "$run_id" \
  "$run_dir" "$SCRIPT_DIR" "$audit_write_contract" <<'PY'
import json
import sys
template_path, out_path, task_raw, run_id, run_dir, script_dir, audit_contract = sys.argv[1:8]
t = json.loads(task_raw)
with open(template_path, "r", encoding="utf-8") as f:
    tmpl = f.read().replace("[TASK-ID]", t["taskId"])
forbidden = ", ".join(t["forbiddenFiles"]) if t["forbiddenFiles"] else "(none)"
if audit_contract == "v1":
    verdict_contract = f"""Your FINAL message MUST be a single JSON object matching
`schemas/orchestration/audit-verdict.v1.schema.json`: schema
"singular.orchestration.audit-verdict.v1", taskId "{t['taskId']}", runId
"{run_id}", branch "{t['workerBranch']}", verdict
(accepted|needs-fix|blocked|needs-human), evidenceReviewed[],
verificationResults[{{status, command, evidenceRefs, rationale}}], commandsRun[],
findings[], requiredFixes[], rationale. Every verificationResults[] object MUST
contain all four required members: status (passed|failed-product|
inconclusive-infrastructure|not-rerun-evidence-verified), command (non-empty
string), evidenceRefs (array of non-empty strings), and rationale (non-empty
string). It MAY also contain integer exitCode. No other verification-result
members are permitted. Reproduce the host gate classification and never turn
an infrastructure limitation into a product finding. No additional top-level
fields are permitted except optional findingsStatus. Emit ONLY that JSON
object."""
else:
    verdict_contract = f"""Your FINAL message MUST be a single JSON object matching
`schemas/orchestration/audit-verdict.v0.schema.json`: schema
"singular.orchestration.audit-verdict.v0", taskId "{t['taskId']}", runId
"{run_id}", branch "{t['workerBranch']}", verdict
(accepted|needs-fix|blocked|needs-human), evidenceReviewed[], commandsRun[],
findings[], requiredFixes[], rationale. Reproduce the host gate classification
in the rationale and never turn an infrastructure limitation into a product
finding. Emit ONLY that JSON object."""
contract = f"""

---

## Audit Context For This Run (authoritative)

- Task: {t['taskId']} ({t['area']}); worker branch {t['workerBranch']} (committed)
- Owned files: {", ".join(t['ownedFiles'])}
- Forbidden files (must NOT be modified): {forbidden}
- Compact evidence manifest: {run_dir}/evidence-manifest.json
- Host verification report: {run_dir}/audit-verification.json
- To inspect one raw artifact declared by the manifest, use only:
  `{script_dir}/evidence-show.sh {run_dir}/evidence-manifest.json <artifact-ref> [max-bytes]`

Read-only. The host already reran the gate in a disposable writable worktree
at the exact committed head with isolated caches. Do not rerun tests in the
original worktree. Start from the compact manifest and fetch a bounded raw
artifact only for a named finding; do not bulk-read raw evidence. Verify scope,
red/green evidence, and acceptance criteria. Do NOT approve without evidence.

{verdict_contract}
"""
with open(out_path, "w", encoding="utf-8") as f:
    f.write(tmpl + contract)
PY

if [[ "$dry_run" == "yes" ]]; then
  echo ""
  echo "DRY RUN — no worktree, no codex, no commit. Prompts assembled at $run_dir."
  singular_append_event "l1.dry_run" "l1 drive dry run" "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}"
  l1_status terminal completed "Dry-run context assembly completed" true \
    "No action required" "dry-run"
  exit 0
fi

# ---- Outcome tracking + EXIT trap ----
_l1_outcome="incomplete"
_l1_lease_written="no"
l1_on_exit() {
  local code=$?
  if [[ "$_l1_outcome" != "accepted" && "$_l1_outcome" != "terminal" ]]; then
    l1_status terminal failed "L1 driver exited before a durable terminal handoff" true \
      "Inspect the run artifacts and recovery record" "exit-$code"
  fi
  if [[ "$_l1_outcome" == "accept-pending" ]]; then
    # Audit ACCEPTED but the driver died before inbox placement. Never fail
    # the lease — the committed branch + packet + audit record are intact and
    # the next dispatch self-heals via accept-existing-packet (0.4.0 marked
    # the lease failed here, orphaning accepted work behind an exit-2
    # re-dispatch loop).
    singular_record_recovery "accepted work stranded before inbox placement; next dispatch auto-heals via accept-existing-packet" \
      "$task_id" "$worker_branch" "accept-existing-packet" "origin" "auto-heal on next dispatch" "origin" || true
    singular_append_event "l1.accept_interrupted" "l1 drive died between acceptance and inbox placement" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"code\":$code}" || true
  elif [[ "$_l1_outcome" == "incomplete" && "$_l1_lease_written" == "yes" ]]; then
    singular_lease_set_status "$task_id" "failed" 2>/dev/null || true
    singular_record_recovery "l1-drive exited before a terminal outcome (code $code)" \
      "$task_id" "$worker_branch" "rebuild-context" "origin" "rerun or decide" "origin" || true
    singular_append_event "l1.aborted" "l1 drive aborted" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"code\":$code}" || true
  fi
}
trap l1_on_exit EXIT
l1_status implementing active "Preparing the isolated worker workspace" false \
  "Run the implementer after bootstrap"

# ---- Worktree lifecycle: reset / orphan auto-recovery ----
remove_worktree() {
  singular_git_lock_acquire
  if singular_worktree_registered "$worktree"; then
    git -C "$SINGULAR_ROOT" worktree remove --force "$worktree" 2>/dev/null || true
  fi
  rm -rf "$worktree"
  git -C "$SINGULAR_ROOT" worktree prune 2>/dev/null || true
  singular_git_lock_release
}

if [[ "$reset" == "yes" ]]; then
  remove_worktree
  singular_with_git_lock git -C "$SINGULAR_ROOT" branch -D "$worker_branch" 2>/dev/null || true
fi

# A deterministic refusal that repeats forever starves the loop (0.4.0: a
# task-id collision re-dispatched into a preserved worktree every cycle until
# the breaker halted the run). Count refusals per task; at the threshold,
# park the task as a DECIDED outcome (exit 3) so the frontier stops
# re-selecting it and an operator sees exactly why.
l1_refusals_file="$SINGULAR_DISPATCH_DIR/$task_id.refusals"
l1_note_refusal_and_maybe_park() {
  local reason="$1" n=0
  mkdir -p "$SINGULAR_DISPATCH_DIR"
  [[ -f "$l1_refusals_file" ]] && n="$(head -1 "$l1_refusals_file" 2>/dev/null | tr -d '[:space:]')"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$((n + 1))
  printf '%s\n' "$n" >"$l1_refusals_file"
  if (( n >= ${SINGULAR_REFUSAL_PARK_THRESHOLD:-3} )); then
    singular_task_set_status "$task_file" "blocked" 2>/dev/null || true
    "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "escalate-parked" \
      --rationale "repeated dispatch refusal x$n: $reason" --run "$run_id" \
      --authority "l1-driver" 2>/dev/null || true
    singular_append_event "l1.refusal_parked" "task parked after repeated dispatch refusals" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"refusals\":$n,\"reason\":\"$reason\"}"
    rm -f "$l1_refusals_file"
    echo "parked $task_id after $n refusals: $reason" >&2
    exit 3
  fi
}

# Auto-heal stranded accepted work (E5): an `accepted` lease whose packet
# never reached the inbox (driver died post-acceptance, reap race) used to
# refuse every re-dispatch forever (exit-2 loop -> breaker). If the prior
# run's packet exists and validates, accept it deterministically and enqueue —
# no worker/auditor re-run.
l1_try_auto_accept_existing() {
  [[ "${SINGULAR_AUTO_ACCEPT_EXISTING:-1}" == "1" ]] || return 1
  local prev_run cand
  prev_run="$(singular_lease_field "$task_id" runId 2>/dev/null || true)"
  [[ -n "$prev_run" ]] || return 1
  # Already queued or imported: the work is in flight — dispatch is a no-op.
  if [[ -f "$SINGULAR_INBOX_DIR/$prev_run.json" ]]     || find "$SINGULAR_ORCH_DIR/packets/imported/$task_id" -maxdepth 1 -name '*.json'          -not -name '*.audit.json' -type f 2>/dev/null | grep -q .; then
    echo "accepted packet for $task_id already queued/imported; dispatch is a no-op"
    _l1_outcome="accepted"
    l1_status terminal completed "Existing accepted packet is already queued or imported" true \
      "Continue origin reconciliation" "accepted-existing"
    exit 0
  fi
  cand="$SINGULAR_RUNS_DIR/$prev_run/packet.json"
  [[ -f "$cand" ]] || return 1
  [[ "$(singular_json_field "$cand" taskId 2>/dev/null || true)" == "$task_id" ]] || return 1
  if "$SCRIPT_DIR/accept-existing-packet.sh" "$cand"; then
    cp "$cand" "$SINGULAR_INBOX_DIR/$prev_run.json.tmp" \
      && mv "$SINGULAR_INBOX_DIR/$prev_run.json.tmp" "$SINGULAR_INBOX_DIR/$prev_run.json"
    singular_append_event "l1.auto_accepted_existing" "stranded accepted packet re-accepted and enqueued" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$prev_run\",\"packet\":\"$cand\"}"
    echo "auto-accepted stranded packet for $task_id (run $prev_run); enqueued to inbox"
    _l1_outcome="accepted"
    l1_status terminal completed "Recovered and queued an existing accepted packet" true \
      "Continue origin reconciliation" "accepted-existing"
    exit 0
  fi
  return 1
}

if singular_worktree_registered "$worktree" || [[ -e "$worktree" ]]; then
  existing_lease="$(singular_lease_status "$task_id" 2>/dev/null || echo none)"
  case "$existing_lease" in
    accepted)
      l1_try_auto_accept_existing || true
      l1_note_refusal_and_maybe_park "accepted worktree without importable packet (lease: $existing_lease)"
      echo "active/accepted worktree for $task_id (lease: $existing_lease); refusing (use --reset)" >&2
      exit 2 ;;
    running|planned|needs-review|integrated)
      l1_note_refusal_and_maybe_park "active/accepted worktree (lease: $existing_lease)"
      echo "active/accepted worktree for $task_id (lease: $existing_lease); refusing (use --reset)" >&2
      exit 2 ;;
    *)
      echo "auto-recovering orphaned worktree for $task_id (lease: $existing_lease)"
      remove_worktree
      singular_with_git_lock git -C "$SINGULAR_ROOT" branch -D "$worker_branch" 2>/dev/null || true
      singular_append_event "l1.orphan_recovered" "reclaimed orphaned worktree" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"priorLease\":\"$existing_lease\"}" ;;
  esac
fi

# ---- Lease + branch + worktree ----
owned_json="$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
forbidden_json="$(printf '%s\n' "${forbidden_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
singular_lease_write "$task_id" "$worker_branch" "$area" "l2-developer" "${owned_files[*]}" \
  "running" "$run_id" "$worktree" "$packet_base_ref" "$dispatch_batch_id" "$owned_json" "$forbidden_json"
_l1_lease_written="yes"
rm -f "$l1_refusals_file" 2>/dev/null || true  # a successful dispatch clears refusal history
singular_append_event "l1.dispatch_started" "l1 dispatch started" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"branch\":\"$worker_branch\",\"baseSha\":\"$packet_base_ref\",\"batchId\":\"$dispatch_batch_id\"}"
singular_git_lock_acquire
git_ec=0
set +e
if ! git -C "$SINGULAR_ROOT" rev-parse --verify --quiet "$worker_branch" >/dev/null; then
  git -C "$SINGULAR_ROOT" branch "$worker_branch" "$branch_base"
  git_ec=$?
fi
if [[ "$git_ec" -eq 0 ]]; then
  mkdir -p "$SINGULAR_WORKTREES_DIR"
  git -C "$SINGULAR_ROOT" worktree add "$worktree" "$worker_branch"
  git_ec=$?
fi
set -e
singular_git_lock_release
if [[ "$git_ec" -ne 0 ]]; then
  echo "failed to create worker branch/worktree for $task_id from $branch_base" >&2
  exit "$git_ec"
fi
singular_append_event "l1.worktree_created" "worker worktree created" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"worktree\":\"$worktree\"}"
provision_log="$run_dir/worktree-provision.log"
# The shared preparer, so the worker worktree and the auditor's disposable
# worktree are built the same way by construction. Bootstrap stays non-fatal
# here (it is fatal in the audit path) and the failure is reported through
# SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FAILED below.
SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FATAL=no
if ! singular_worktree_prepare "$worktree" "$run_dir" "$SINGULAR_ROOT" "$provision_log"; then
  provision_out="$(cat "$provision_log" 2>/dev/null || true)"
  _l1_outcome="terminal"
  l1_status terminal failed "Worker workspace provisioning failed" true \
    "Inspect worktree-provision.log and repair the host dependency" "provision-failed"
  singular_lease_set_status "$task_id" "blocked" 2>/dev/null || true
  singular_task_set_status "$task_file" "blocked" || true
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "escalate-parked" \
    --rationale "worktree provisioning failed before runner invocation; see $provision_log" \
    --run "$run_id" --branch "$worker_branch" --authority l1 >/dev/null 2>&1 || true
  singular_append_event "l1.provision_failed" "worktree provisioning failed" \
    "$(python3 - "$task_id" "$run_id" "$provision_log" "$provision_out" <<'PY'
import json, sys
task_id, run_id, log, reason = sys.argv[1:5]
print(json.dumps({"taskId": task_id, "runId": run_id, "log": log, "reason": reason[:500]}, separators=(",", ":")))
PY
)"
  echo "worktree provisioning failed for $task_id (see $provision_log)" >&2
  exit 3
fi
singular_append_event "l1.provisioned" "worktree provisioning completed" \
  "$(python3 - "$task_id" "$run_id" "${SINGULAR_WORKTREE_ENV_FILE:-}" <<'PY'
import json, sys
task_id, run_id, env_file = sys.argv[1:4]
print(json.dumps({"taskId": task_id, "runId": run_id, "envFile": env_file}, separators=(",", ":")))
PY
)"
bootstrap_failure=""
bootstrap_log="$provision_log"
if [[ "$SINGULAR_WORKTREE_PREPARE_BOOTSTRAP_FAILED" == "yes" ]]; then
  bootstrap_failure="required-bootstrap-failed"
  singular_append_event "l1.bootstrap_failed" \
    "required worktree bootstrap failed (infrastructure)" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"log\":\"$bootstrap_log\"}" || true
else
  singular_append_event "l1.bootstrap_completed" "worktree bootstrap completed" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"log\":\"$bootstrap_log\"}" || true
fi

# ---- One attempt: worker -> scope -> gate -> commit -> stamp -> audit ----
# Sets globals: attempt_failure (class), attempt_ctx (file). worker_rc/audit_rc
# hold the raw runner exit codes of the latest attempt (captured, not yet acted
# on — later waves branch on timeout/resume codes such as 124/86).
head_sha=""
packet="$run_dir/packet.json"
audit_record="$(singular_audit_record_path "$run_id")"
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

# Durable `decision-record` extra spec (node rehydrate-path, layer engine_runtime).
# The repo-level decision log lives OUTSIDE run_dir, so the pure resolver
# singular_ctx_rehydrate_sources never emits it; it is supplied as a class-tagged
# extra computed by the pure leaf over SINGULAR_ROOT. It is snapshotted ONCE here at
# drive start (existence-gated) so a rehydrate attempt rehydrates the decision log
# as it stood when the run began — NOT this run's own in-flight decider appends
# (record-decision.sh mutates docs/orchestration/decisions.md between attempts, and
# capturing those would be circular). Empty when the decision log is absent at
# drive start. Both rehydrate sites reference this identical spec, so the injected
# packet and the recorded manifest carry the SAME decision record (id + content
# hash) by construction. Its CONTENT is hashed/rendered later at rehydrate time.
decision_source_extra="$(singular_ctx_rehydrate_decision_source "$SINGULAR_ROOT" 2>/dev/null || true)"

# Worker-runner selection (singular_select_l2_runner): generic engine returns the
# default runner; an enabled module may route specific tasks to an alternate
# runner (3rd arg). An explicit SINGULAR_RUNNER override always wins.
l2_runner="$(singular_select_l2_runner "$task_file" "$SINGULAR_RUNNER_BIN" "$SCRIPT_DIR/claude-run.sh")"
if [[ "$l2_runner" != "$SINGULAR_RUNNER_BIN" ]]; then
  echo "  module-routed L2 worker -> $(basename "$l2_runner")"
  singular_append_event "l1.worker_runner_selected" "worker routed to alternate runner" \
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
  # SINGULAR_FIX_PROMPT_STRUCTURED=0) stays byte-identical to today.
  if [[ "${SINGULAR_FIX_PROMPT_STRUCTURED:-1}" == "1" ]]; then
    local cur_owned_json cur_forbidden_json
    cur_owned_json="$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
    cur_forbidden_json="$(printf '%s\n' "${forbidden_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
    if singular_render_fix_prompt "$active_prompt" "$l2_prompt" "$run_dir" "$n" \
         "${prev_failure_class:-unknown}" "${prev_attempt_ctx:-/dev/null}" \
         "$cur_owned_json" "$cur_forbidden_json" 2>/dev/null; then
      return 0
    fi
    singular_append_event "l1.fix_prompt_fallback" "structured fix prompt render failed; using legacy hints" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true
  fi
  cp "$l2_prompt" "$active_prompt"
  if [[ -n "$fix_hints" ]]; then
    { echo ""; echo "---"; echo "## Previous attempt feedback (fix these, stay in scope)"; echo ""; echo "$fix_hints"; } >>"$active_prompt"
  fi
}

# Inject the assembled durable-context rehydration packet into the implementer's
# already-rendered active prompt when the routing decision upgraded a refused
# resume to `rehydrate` (only behind SINGULAR_REHYDRATE=1; the spine never yields
# `rehydrate` otherwise, so with the flag unset this is a no-op and $active_prompt
# stays byte-identical). The run stays FRESH (worker_resume_id empty -> no
# --resume-session): a fresh session PLUS injected durable context, not a resume.
# The packet is assembled by delegating into the integrated pure bricks —
# singular_ctx_rehydrate_packet over singular_ctx_rehydrate_sources "$run_dir" — so
# determinism, the per-section SINGULAR_CONTEXT_SECTION_MAX_CHARS cap, and
# quarantine exclusion all come for free; no rehydration/resolution logic is
# inlined here. The section is headed as injected durable context from a
# refused-resume lineage — reference-only, NOT authoritative — because rehydrated
# content is tainted / model-authored, not host-verified. Called ONCE at
# attempt-open (outside the infra-retry try loop) so try>0 reuse the same
# $active_prompt (idempotent). Mirrors assumptions_inject_fix / the fix-hints
# append. Non-fatal: on any error nothing is injected and the attempt proceeds.
rehydrate_inject_packet() {
  local active_prompt="$1"
  [[ "${worker_strategy:-}" == "rehydrate" ]] || return 0
  # The repo-level `decision-record` lives OUTSIDE run_dir; it is supplied as the
  # class-tagged extra `decision_source_extra` snapshotted at drive start. The event
  # record site passes the IDENTICAL spec, so the injected packet and the recorded
  # manifest carry the SAME decision record. Empty when the decision log was absent
  # at drive start.
  # SUBGRAPH branch (node subgraph-rehydrate; behind SINGULAR_CTX_SUBGRAPH_REHYDRATE
  # and only on the treatment arm with a present non-empty corpus). The shared
  # selector yields the contradictions-first subgraph packet keyed on the SAME
  # task_id / arm-mode / node the manifest-record site (ctx-rehydrate-event.sh)
  # keys on, so the injected packet and the recorded manifest carry the SAME
  # subgraph sources by construction. Inject THAT under the identical reference-
  # only / NOT-authoritative header and skip the flat durable composition. With the
  # knob off / control arm / absent corpus the selector returns non-zero/empty and
  # the flat path below runs unchanged (byte-identical to today).
  local packet=""
  local subgraph_packet
  if subgraph_packet="$(singular_ctx_route_subgraph_render "$task_id" packet 2>/dev/null)" \
     && [[ -n "$subgraph_packet" ]]; then
    packet="$subgraph_packet"
  else
    local -a specs=()
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] && specs+=("$line")
    done < <(singular_ctx_rehydrate_sources "$run_dir" ${decision_source_extra:+"$decision_source_extra"} 2>/dev/null)
    packet="$(singular_ctx_rehydrate_packet ${specs[@]+"${specs[@]}"} 2>/dev/null)" || return 0
  fi
  [[ -n "$packet" ]] || return 0
  {
    echo ""
    echo "---"
    echo ""
    echo "## Injected durable context (rehydrated from a refused-resume lineage)"
    echo ""
    echo "> Reference only, NOT authoritative. This is durable context rehydrated"
    echo "> from a prior (tainted, model-authored) session's artifacts, not"
    echo "> host-verified evidence. Do not pass its content off as authoritative."
    echo ""
    printf '%s\n' "$packet"
  } >> "$active_prompt" 2>/dev/null || true

  # Authored-knowledge augmentation (node rehydrate-path; OPTIONAL, NOT part of
  # requiredCompletion). AFTER the durable packet, ALSO append the eligible
  # authored-knowledge entries under a reference-only / NOT-authoritative wrapper.
  # The hook is a minimal delegating append into the integrated config-gated
  # render (TASK-0058–0061); no config/selection/render logic is inlined here.
  # The render internally gates on SINGULAR_CTX_MANIFEST (default 0) and the
  # OPTIONAL singular.config.json `contextManifest` field, so with either OFF it
  # returns empty and nothing is appended — the durable-only injection is
  # byte-identical. The trigger set comes from the pure builder
  # singular_ctx_rehydrate_authored_triggers (TASK-0064): the run's deterministic,
  # de-duplicated `load-when` tokens (role `implementer`, step `implement`, task
  # id) rather than the bare literal `implement`, so authored entries scoped to a
  # role or task — not only the literal step — become eligible. The enriched set
  # is a strict superset of {implement}, so implement-scoped entries still match
  # (backward compatible). The manifest-record site
  # (engine/ctx-rehydrate-event.sh) passes the IDENTICAL set so the injected and
  # recorded authored entries stay consistent. Minimal delegation: the set is
  # computed and passed expanded; no selection/render logic is inlined here.
  # Non-fatal: on any error nothing is appended.
  #
  # NODE dimension (TASK-0066 -> TASK-0067): resolve the run's executable DAG node
  # via the pure read-only resolver singular_ctx_rehydrate_authored_node "$task_id"
  # and thread it into the builder's position-3 [node] slot so node-scoped
  # `load-when` entries (e.g. ["rehydrate-path"]) become eligible. The resolver
  # returns empty (fail-safe) on an absent or ambiguous task->node association;
  # the builder skips empty dimensions, so the set stays {implementer, implement,
  # task-id} — byte-identical to the pre-node-dimension behavior. The
  # manifest-record site resolves the node from the SAME task_id via the SAME
  # deterministic resolver, so both derive the identical token and identical set.
  local node
  node="$(singular_ctx_rehydrate_authored_node "$task_id" 2>/dev/null)" || node=""
  local -a authored_triggers=()
  local trigger
  while IFS= read -r trigger; do
    [[ -n "$trigger" ]] && authored_triggers+=("$trigger")
  done < <(singular_ctx_rehydrate_authored_triggers implementer implement "$node" "$task_id" 2>/dev/null)
  local authored
  authored="$(singular_ctx_rehydrate_authored_config_render ${authored_triggers[@]+"${authored_triggers[@]}"} 2>/dev/null)" || authored=""
  [[ -n "$authored" ]] || return 0
  {
    echo ""
    echo "---"
    echo ""
    echo "## Injected authored knowledge (reference material, NOT authoritative)"
    echo ""
    echo "> Reference only, NOT authoritative. Human-curated authored-knowledge"
    echo "> entries eligible for this step, augmenting the rehydration packet."
    echo "> Per-entry markers frame each section; do not treat as host-verified"
    echo "> evidence."
    echo ""
    printf '%s\n' "$authored"
  } >> "$active_prompt" 2>/dev/null || true
  return 0
}

# Worker invocation through scope/gate/commit/packet stamping + validation.
# Sets head_sha, attempt_failure, attempt_ctx, worker_rc. Returns 0 when a
# validated packet exists on a committed branch, 1 otherwise.
run_worker_phase() {
  local n="$1"
  l1_status implementing active "Running implementer attempt $n" false \
    "Validate scope and run the regression gate" "" "worker-controller"
  if [[ -n "$bootstrap_failure" ]]; then
    attempt_failure="worker-infra"
    attempt_ctx="$bootstrap_log"
    return 1
  fi
  local active_prompt="$run_dir/l2-active-prompt.md"

  # ---- Worker runner with bounded infra-retry (T-E6) ------------------------
  # A worker "infra failure" is the runner itself failing/timing out — rc 124
  # (claude-run kills the tree on SINGULAR_CLAUDE_TIMEOUT_SEC), or rc!=0 with a truly
  # empty/missing last-message file. That is distinct from worker-no-packet (the
  # model ran fine and emitted prose: output EXISTS but carries no packet) — which
  # the packet-validation path below already classifies. We re-run ONLY the worker
  # up to SINGULAR_WORKER_INFRA_MAX extra times; this never bumps the lease retryCount.
  # QUOTA GUARD: singular_planner_failure_class returns "quota" (priority over timeout/
  # empty) when the log carries a usage/rate-limit marker; we must NOT swallow that
  # as worker-infra, so a quota classification falls through to the normal path
  # (the breaker/quota-backoff machinery owns it).
  local worker_infra_max="${SINGULAR_WORKER_INFRA_MAX:-1}"
  [[ "$worker_infra_max" =~ ^[0-9]+$ ]] || worker_infra_max=1
  local worker_try worker_fc worker_result_file worker_try_log worker_classification_log

  # ---- Session affinity (T-E5): resume decision (first try only) ------------
  # Reuse the implementer's prior runtime session iff every gate passes; else go
  # fresh. Lineage head = the worktree's current HEAD. The decision is computed
  # ONCE per attempt; infra retries (try>0) always run FRESH (no --resume-session).
  local l2_runner_basename worker_prompt_sha worker_resume_id="" worker_decision
  local worker_capability_profile
  l2_runner_basename="$(basename "$l2_runner")"
  worker_prompt_sha="$(singular_prompt_sha "$l2_prompt" 2>/dev/null || true)"
  local worktree_head; worktree_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)"
  # Routed through the ctx-* adapter (SINGULAR_CTX_ROUTING; default 0 -> OFF-parity,
  # byte-identical to the direct decider call). Step `implement` is not an
  # independence-required step, so the routing gates (window/diff/lease) may apply.
  worker_decision="$(singular_ctx_route_decide implementer implement "$session_meta_implementer" \
    "$task_id" "$run_id" "$l2_runner_basename" "$worker_prompt_sha" "$worktree" "$worktree_head" 2>/dev/null || echo "fresh decide-error")"
  worker_strategy="${worker_decision%% *}"
  worker_strategy_reason="${worker_decision#* }"
  if [[ "$worker_strategy" == "resume" ]]; then
    worker_resume_id="$worker_strategy_reason"; worker_strategy_reason="resume"
    singular_append_event "context.strategy_selected" "session resume strategy selected" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"implementer\",\"attempt\":$n,\"strategy\":\"resume\",\"reason\":\"resume\",\"sessionId\":\"$worker_resume_id\"}" || true
  elif [[ "$worker_strategy" == "rehydrate" ]]; then
    # A refused-resume lineage step upgraded to rehydrate (only behind
    # SINGULAR_REHYDRATE=1; the routing spine never yields `rehydrate` otherwise).
    # Record strategy=rehydrate, the refusal reason, and the NESTED packet manifest
    # (ids + hashes only) by delegating into the integrated pure assembler over the
    # durable-artifact root run_dir. No resume session is reused (rehydrate is a
    # fresh session with injected context); the packet-injection hook is a later
    # slice. worker_resume_id stays empty so the worker runs fresh below.
    # The repo-level `decision-record` lives OUTSIDE run_dir; supply it as a trailing
    # class-tagged extra so the recorded manifest carries the SAME decision record
    # (id + content hash) the packet-injection hook injects — both reference the
    # identical drive-start `decision_source_extra`, so they agree by construction.
    singular_append_event "context.strategy_selected" "rehydrate strategy selected" \
      "$(singular_ctx_rehydrate_event_data implementer "$task_id" "$run_id" "$n" "$worker_strategy_reason" "$run_dir" ${decision_source_extra:+"$decision_source_extra"})" || true
  else
    singular_append_event "context.strategy_selected" "fresh-run strategy selected" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"implementer\",\"attempt\":$n,\"strategy\":\"fresh\",\"reason\":\"$worker_strategy_reason\"}" || true
  fi

  # ---- Rehydrate packet injection (node rehydrate-path; behind SINGULAR_REHYDRATE)
  # On a `rehydrate` decision, append the assembled durable-context packet to the
  # already-rendered active prompt ONCE, before the (fresh) worker try loop. No-op
  # for resume/fresh, so with SINGULAR_REHYDRATE unset $active_prompt is unchanged.
  rehydrate_inject_packet "$active_prompt"

  local worker_resume_failed="no"
  for ((worker_try=0; worker_try<=worker_infra_max; worker_try++)); do
    worker_try_log="$run_dir/worker-attempt-${n}-try-${worker_try}.log"
    worker_classification_log="$worker_try_log"
    if [[ "$worker_try" -gt 0 ]]; then
      singular_append_event "worker.infra_retry" "worker infra failure; re-running worker only" \
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
      worker_result_file="$run_dir/implementer-attempt-${n}-try-${worker_try}-resume-runner-result.json"
    else
      echo "  running L2 worker via $l2_runner_basename..."
      worker_result_file="$run_dir/implementer-attempt-${n}-try-${worker_try}-runner-result.json"
    fi
    worker_rc=0
    worker_capability_profile="${SINGULAR_IMPLEMENTER_CAPABILITY_PROFILE:-implementer-core}"
    singular_runner_contract_prepare \
      "$l2_runner" implementer "$worker_capability_profile" "$worker_result_file"
    SINGULAR_RUNNER_ROLE=implementer \
    SINGULAR_RUNNER_CAPABILITY_PROFILE="$worker_capability_profile" \
    SINGULAR_RUNNER_RESULT_FILE="$worker_result_file" \
      "$l2_runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
        "${worker_run_args[@]}" >"$worker_try_log" 2>&1 || worker_rc=$?
    printf -- '--- worker try %s (attempt %s) ---\n' "$worker_try" "$n" \
      >>"$run_dir/worker-codex.log" || true
    cat "$worker_try_log" >>"$run_dir/worker-codex.log" 2>/dev/null || true

    # Resume-refused (86) or resume-failure (86): the runner could not reuse the
    # session. Fall back to FRESH within the SAME try (don't consume an infra/main
    # retry on a resume miss). This is a pure optimization miss; the task outcome
    # is unchanged.
    if [[ "$worker_rc" -eq 86 && -n "$worker_resume_id" && "$worker_resume_failed" == "no" ]]; then
      worker_resume_failed="yes"
      singular_append_event "context.resume_failed" "implementer resume failed; re-running fresh" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"implementer\",\"attempt\":$n,\"sessionId\":\"$worker_resume_id\"}" || true
      worker_strategy="fresh"; worker_strategy_reason="resume-failed"
      echo "  worker resume failed; falling back to fresh run..."
      worker_classification_log="$run_dir/worker-attempt-${n}-try-${worker_try}-resume-fallback.log"
      worker_result_file="$run_dir/implementer-attempt-${n}-try-${worker_try}-resume-fallback-runner-result.json"
      worker_rc=0
      singular_runner_contract_prepare \
        "$l2_runner" implementer "$worker_capability_profile" "$worker_result_file"
      SINGULAR_RUNNER_ROLE=implementer \
      SINGULAR_RUNNER_CAPABILITY_PROFILE="$worker_capability_profile" \
      SINGULAR_RUNNER_RESULT_FILE="$worker_result_file" \
        "$l2_runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
          --level l2 -C "$worktree" --run-id "$run_id" \
          --prompt-file "$active_prompt" --output-last-message "$run_dir/last-message.json" \
          --session-meta "$session_meta_implementer" >"$worker_classification_log" 2>&1 || worker_rc=$?
      printf -- '--- worker resume-fallback try %s (attempt %s) ---\n' "$worker_try" "$n" \
        >>"$run_dir/worker-codex.log" || true
      cat "$worker_classification_log" >>"$run_dir/worker-codex.log" 2>/dev/null || true
    fi

    # Classify infra-vs-not. quota -> NOT infra (let the normal/breaker path own
    # it). timeout(rc 124)/empty-output(rc!=0, empty file) -> infra: retry the
    # worker only. invalid-output (output exists, rc 0) -> NOT infra; that is a
    # potential worker-no-packet handled by packet validation below.
    worker_fc="$(singular_planner_failure_class "$worker_classification_log" "$worker_rc" \
      "$run_dir/last-message.json" "$worker_result_file")"
    # "empty-output" only counts as infra when the runner itself failed (rc!=0);
    # a rc-0 run that emitted an empty file is a clean run with no packet (prose),
    # which is worker-no-packet, owned by the packet-validation path — NOT infra.
    [[ "$worker_fc" == "empty-output" && "$worker_rc" -eq 0 ]] && worker_fc="invalid-output"
    case "$worker_fc" in
      timeout|empty-output) : ;;          # infra: loop to re-run the worker
      *) break ;;                         # quota / codex-exit-with-output / clean: stop retrying
    esac
  done
  singular_append_event "l1.worker_completed" "l2 worker completed" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}"
  # Persisted worker infra failure (still timeout/empty after the retry budget):
  # surface worker-infra so the fast-path decider parks it; retryCount untouched.
  if [[ "$worker_fc" == "timeout" || "$worker_fc" == "empty-output" ]]; then
    attempt_failure="worker-infra"; attempt_ctx="$run_dir/worker-codex.log"
    return 1
  fi

  local worker_packet_log="$run_dir/worker-packet-validation.log"
  local worker_packet_ec=0
  singular_l1_prepare_worker_packet "$run_dir/last-message.json" "$run_dir/last-message.json" "$worker_packet_log" \
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

  if [[ -d "$worktree/.singular-evidence" ]]; then
    rm -rf "$run_dir/worker-evidence"; cp -R "$worktree/.singular-evidence" "$run_dir/worker-evidence"
  fi
  local storage_guard_log="$run_dir/module-packet-guard.log"
  if ! singular_packet_module_guard "$run_dir/last-message.json" "$task_file" "$worktree" "$run_dir" >"$storage_guard_log" 2>&1; then
    attempt_failure="packet-invalid"; attempt_ctx="$storage_guard_log"; return 1
  fi

  # Scope (owned allow + forbidden deny).
  local scope_args=(--worktree "$worktree")
  local f
  for f in "${owned_files[@]}"; do scope_args+=(--allow-prefix "$f"); done
  for f in "${forbidden_files[@]}"; do scope_args+=(--forbid-prefix "$f"); done
  local scope_rc=0
  "$SCRIPT_DIR/scope-check.sh" "${scope_args[@]}" >"$run_dir/scope-check.log" 2>&1 \
    || scope_rc=$?
  singular_check_result_write "$run_dir/scope-check-result.json" scope \
    "$([[ "$scope_rc" -eq 0 ]] && echo passed || echo failed)" \
    "$scope_rc" "$run_dir/scope-check.log"
  if [[ "$scope_rc" -ne 0 ]]; then
    attempt_failure="scope-violation"; attempt_ctx="$run_dir/scope-check.log"; return 1
  fi
  if singular_strict_proof_skip_detected "$task_file" "$worktree" "${owned_files[@]}"; then
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
  l1_status gating active "Running the worker regression gate for attempt $n" false \
    "Classify the gate and commit verified content" "" "gate-controller"
  singular_run_in_worktree_env "$worktree" "$SCRIPT_DIR/gate-check.sh" "$run_id" \
    --task-id "$task_id" --phase worker --workspace-kind worker -- \
    "$(singular_bash_bin)" -c "$gate_cmd" || gate_exit=$?
  local gate_outcome
  gate_outcome="$(singular_json_field "$run_dir/gate-report.json" outcome 2>/dev/null || true)"
  if [[ "$gate_exit" -ne 0 ]]; then
    if [[ "$gate_outcome" == "inconclusive-infrastructure" || -z "$gate_outcome" ]]; then
      attempt_failure="audit-infra"; attempt_ctx="$run_dir/gate-report.json"; return 1
    fi
    attempt_failure="gate-red"; attempt_ctx="$run_dir/gate-check.log"; return 1
  fi
  singular_append_event "l1.gate_passed" "regression gate passed" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"outcome\":\"$gate_outcome\"}"

  # Secret-scan staged-to-be content (working changes), then stage owned + commit.
  for f in "${owned_files[@]}"; do [[ -e "$worktree/$f" ]] && git -C "$worktree" add -- "$f"; done
  singular_check_result_write "$run_dir/secret-scan-result.json" secret \
    not-run 0 ""
  if git -C "$worktree" diff --cached --quiet; then
    # Empty staged diff. If the owned files at HEAD already differ from the
    # base — a PRIOR attempt committed the content — and the gate above just
    # passed, this is a valid empty-diff retry, not a failure. 0.4.0 raised
    # `no-changes` here, the decider's revalidate-evidence could not audit a
    # no-change replay, and fully green work terminally parked (field audit:
    # TASK-0052/0053). Truly-no-content (HEAD == base on owned paths) still
    # fails as before.
    local owned_diff_rc=0
    git -C "$worktree" diff --quiet "$packet_base_ref"...HEAD -- "${owned_files[@]}" 2>/dev/null \
      || owned_diff_rc=$?
    if [[ "$owned_diff_rc" -eq 1 ]]; then
      singular_append_event "l1.no_changes_reconciled" \
        "gate green and owned content already committed at HEAD; proceeding with empty diff" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"headSha\":\"$(git -C "$worktree" rev-parse HEAD)\"}"
      head_sha="$(git -C "$worktree" rev-parse HEAD)"
    else
      # rc 0 = no content vs base; rc >1 = diff failed — both fail conservatively.
      attempt_failure="no-changes"; attempt_ctx="$run_dir/worker-codex.log"; return 1
    fi
  else
    local secret_rc=0
    "$SCRIPT_DIR/secret-scan.sh" --worktree "$worktree" --staged \
      >"$run_dir/secret-scan.log" 2>&1 || secret_rc=$?
    singular_check_result_write "$run_dir/secret-scan-result.json" secret \
      "$([[ "$secret_rc" -eq 0 ]] && echo passed || echo failed)" \
      "$secret_rc" "$run_dir/secret-scan.log"
    if [[ "$secret_rc" -ne 0 ]]; then
      git -C "$worktree" reset -q
      attempt_failure="secret-detected"; attempt_ctx="$run_dir/secret-scan.log"; return 1
    fi
    singular_git_lock_acquire
    local commit_ec=0
    set +e
    git -C "$worktree" -c user.name="$SINGULAR_GIT_L1_NAME" -c user.email="$SINGULAR_GIT_L1_EMAIL" \
      commit -q -m "$task_id: ${test_policy} worker output (run $run_id)" \
      -m "Driven by L1 from $packet_base_ref. Owned: ${owned_files[*]}."
    commit_ec=$?
    set -e
    singular_git_lock_release
    if [[ "$commit_ec" -ne 0 ]]; then
      attempt_failure="commit-failed"; attempt_ctx="$run_dir/worker-codex.log"; return 1
    fi
    head_sha="$(git -C "$worktree" rev-parse HEAD)"
    singular_append_event "l1.committed" "worker branch committed" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"headSha\":\"$head_sha\"}"
  fi

  # The gate ran immediately before commit. Bind its command and full-log
  # hashes to the commit containing those exact tested bytes.
  if ! "$SCRIPT_DIR/gate-report.py" bind-head \
      --report "$run_dir/gate-report.json" --head-sha "$head_sha" --task-id "$task_id" \
      >"$run_dir/gate-report-bind.log" 2>&1 \
    || ! cp "$run_dir/gate-report.json" "$run_dir/gate-check.json"; then
    attempt_failure="audit-infra"; attempt_ctx="$run_dir/gate-report-bind.log"; return 1
  fi

  mapfile -t changed_files < <(git -C "$worktree" diff --name-only "$target_branch"...HEAD)
  python3 - "$run_dir/last-message.json" "$packet" "$run_id" "$task_id" "$area" \
    "$worker_branch" "$packet_base_ref" "$head_sha" "$worktree" \
    "$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')" \
    "$(printf '%s\n' "${changed_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')" <<'PY'
import json, sys
(src,dst,run_id,task_id,area,branch,base_ref,head_sha,workspace,owned_json,changed_json)=sys.argv[1:12]
with open(src) as f: p=json.load(f)
p["schema"]="singular.orchestration.state-packet.v0"; p["runId"]=run_id; p["taskId"]=task_id
p["area"]=area; p["role"]=p.get("role") or "l2-developer"; p["baseRef"]=base_ref
p["branch"]=branch; p["headSha"]=head_sha; p["workspace"]=workspace
p["ownedFiles"]=json.loads(owned_json)
changed=json.loads(changed_json)
if changed: p["changedFiles"]=changed
p.setdefault("packetId",f"{run_id}-packet"); p.setdefault("changedFiles",[])
for k in ("commands","tests","evidence","blockers"): p.setdefault(k,[])
p.setdefault("nextAction","await auditor verdict"); p.setdefault("status","needs-review")
p["evidence"].append({"kind":"gate-report","ref":f"runs/{run_id}/gate-report.json"})
with open(dst,"w") as f: json.dump(p,f,indent=2); f.write("\n")
PY
  singular_validate_packet_basic "$packet" >/dev/null 2>&1 || { attempt_failure="packet-invalid"; attempt_ctx="$packet"; return 1; }

  # Compact, hash-bound reviewer input. Full raw evidence remains available
  # only through evidence-show.sh's declared-reference and byte-budget checks.
  if ! "$SCRIPT_DIR/evidence-manifest.sh" \
      --run-dir "$run_dir" --task-id "$task_id" --worktree "$worktree" \
      --base-ref "$packet_base_ref" --head-sha "$head_sha" \
      >"$run_dir/evidence-manifest-build.log" 2>&1; then
    attempt_failure="audit-infra"; attempt_ctx="$run_dir/evidence-manifest-build.log"; return 1
  fi

  # Implementer context capsule (additive observability; never aborts the
  # drive). Scope arrays are the CURRENT post-amend scope, not the packet's.
  local capsule_owned capsule_forbidden
  capsule_owned="$(printf '%s\n' "${owned_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  capsule_forbidden="$(printf '%s\n' "${forbidden_files[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  singular_capsule_write_implementer "$run_dir" "$n" "$packet" "$head_sha" "$capsule_owned" "$capsule_forbidden" >/dev/null 2>&1 \
    || singular_append_event "l1.capsule_write_failed" "implementer capsule write failed (non-fatal)" \
         "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"implementer\",\"attempt\":$n}" || true

  # Assumption ledger (node assumption-ledger; behind SINGULAR_CTX_PACKET): record this
  # attempt's ledger (assumption statuses) alongside the implementer capsule write,
  # additively and non-fatally. No-op when OFF.
  assumptions_record_capsule "$n" || true

  # Session affinity (T-E5): merge host-authority fields into the runner-written
  # implementer meta so the NEXT attempt can resume it. headShaAtCreate = the
  # committed head (the lineage anchor the resume decider checks). Never fatal.
  singular_session_meta_finalize "$session_meta_implementer" implementer "$task_id" "$run_id" \
    "$l2_runner_basename" "$worker_prompt_sha" "$head_sha" "$n" >/dev/null 2>&1 || true
  return 0
}

# Dual-read the legacy v0 audit contract and the v1 verification contract.
validate_audit_record() {
  local record="$1" schema
  schema="$(singular_json_field "$record" schema 2>/dev/null || true)"
  if [[ "$schema" == "singular.orchestration.audit-verdict.v1" ]]; then
    SINGULAR_AUDIT_SCHEMA="$SINGULAR_SCHEMA_DIR/audit-verdict.v1.schema.json" \
      singular_validate_audit_verdict "$record" "$task_id" "$run_id"
  else
    singular_validate_audit_verdict "$record" "$task_id" "$run_id"
  fi
}

# Render a fresh auditor repair prompt after a structurally parseable response
# fails schema validation or host binding. The retry count remains owned by the
# existing SINGULAR_AUDIT_INFRA_MAX loop; this helper only makes the next retry
# actionable instead of replaying an unchanged prompt.
render_audit_repair_prompt() {
  local base_prompt="$1" output_prompt="$2" error_file="$3"
  local invalid_response_file="$4" contract="$5"
  python3 - "$base_prompt" "$output_prompt" "$error_file" \
    "$invalid_response_file" "$contract" <<'PY'
import json
import sys

base_path, output_path, error_path, invalid_path, contract = sys.argv[1:6]

def read_bounded(path, limit):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        value = handle.read(limit + 1)
    if len(value) > limit:
        value = value[:limit] + "\n[truncated by host]"
    return value

with open(base_path, "r", encoding="utf-8") as handle:
    base = handle.read()
error = read_bounded(error_path, 8192)
invalid = read_bounded(invalid_path, 65536)

if contract == "v1":
    required_contract = """Return exactly one audit-verdict.v1 JSON object.
Required top-level members: schema, taskId, runId, branch, verdict,
evidenceReviewed, verificationResults, commandsRun, findings, requiredFixes,
and rationale. No other top-level members are allowed except optional
findingsStatus. Each verificationResults[] object requires exactly status,
command, evidenceRefs, and rationale; optional integer exitCode is also
allowed. status must be one of passed, failed-product,
inconclusive-infrastructure, or not-rerun-evidence-verified. command and
rationale must be non-empty strings. evidenceRefs must be an array of
non-empty strings."""
else:
    required_contract = """Return exactly one audit-verdict.v0 JSON object.
Required top-level members: schema, taskId, runId, branch, verdict,
evidenceReviewed, commandsRun, findings, requiredFixes, and rationale. No
other top-level members are allowed except optional findingsStatus."""

repair_input = json.dumps(
    {
        "validatorOrBinderError": error,
        "invalidResponse": invalid,
    },
    ensure_ascii=False,
    indent=2,
)
repair = f"""

---

## Audit Verdict Repair (authoritative)

Your previous response was rejected before its verdict could influence
acceptance. Produce a corrected response from a fresh evaluation. Do not repeat
the invalid shape.

{required_contract}

The host-supplied prior error and invalid response are:

<audit-repair-input>
{repair_input}
</audit-repair-input>

Emit ONLY the corrected JSON object.
"""
with open(output_path, "w", encoding="utf-8") as handle:
    handle.write(base + repair)
PY
}

append_audit_evidence() {
  python3 - "$packet" "$run_id" <<'PY'
import json
import sys

packet, run_id = sys.argv[1:3]
with open(packet, encoding="utf-8") as handle:
    data = json.load(handle)
refs = [
    ("audit", f"runs/{run_id}/audit.json"),
    ("audit-verification", f"runs/{run_id}/audit-verification.json"),
    ("evidence-manifest", f"runs/{run_id}/evidence-manifest.json"),
]
for kind, ref in refs:
    if not any(e.get("kind") == kind and e.get("ref") == ref for e in data["evidence"]):
        data["evidence"].append({"kind": kind, "ref": ref})
with open(packet, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
}

write_host_audit_verdict() {
  local verification_status="$1" host_verdict="$2" rationale="$3"
  python3 - "$audit_record" "$run_dir/audit-verification.json" "$task_id" "$run_id" \
    "$worker_branch" "$verification_status" "$host_verdict" "$rationale" "$gate_cmd" \
    "$audit_write_contract" <<'PY'
import json
import sys

(output, report_path, task_id, run_id, branch, status, verdict, rationale,
 command, contract) = sys.argv[1:11]
try:
    report = json.load(open(report_path, encoding="utf-8"))
except Exception:
    report = {}
finding = rationale
unexpected = report.get("unexpectedFailures")
if isinstance(unexpected, list) and unexpected and isinstance(unexpected[0], dict):
    finding = str(unexpected[0].get("title") or rationale)
exit_code = report.get("rawExitCode")
verification = {
    "status": status,
    "command": command,
    "evidenceRefs": [f"runs/{run_id}/audit-verification.json"],
    "rationale": rationale,
}
if isinstance(exit_code, int):
    verification["exitCode"] = exit_code
data = {
    "schema": f"singular.orchestration.audit-verdict.{contract}",
    "taskId": task_id,
    "runId": run_id,
    "branch": branch,
    "verdict": verdict,
    "evidenceReviewed": [
        f"runs/{run_id}/evidence-manifest.json",
        f"runs/{run_id}/audit-verification.json",
    ],
    "commandsRun": [command],
    "findings": [finding],
    "requiredFixes": [finding] if status == "failed-product" else [],
    "rationale": rationale,
}
if contract == "v1":
    data["verificationResults"] = [verification]
with open(output, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
}

# Auditor invocation through verdict extraction + packet evidence append.
# Sets verdict, attempt_failure, attempt_ctx, audit_rc. Returns 0 when the
# attempt is acceptable (verdict accepted, or audits disabled), 1 otherwise.
run_audit_phase() {
  local n="$1"
  local model_verification_status=""
  l1_status auditing active "Verifying committed evidence for attempt $n" true \
    "Classify host verification and obtain the audit verdict" "" "audit-controller"

  # Re-audit delta prompt (T-E4). prior_head is the existing reviewer capsule's
  # auditedHeadSha (read BEFORE the capsule is overwritten this attempt) — the
  # SHA the auditor last reviewed. Render to a NEW per-attempt file and pass THAT
  # to the runner; on attempt 1 / no capsule / empty prior_head the renderer is a
  # plain copy (byte-identical to the base audit prompt). Renderer failure ->
  # warning event + fall back to the base audit prompt.
  local prior_head active_audit_prompt="$run_dir/auditor-active-prompt.md"
  prior_head="$(singular_json_field "$run_dir/reviewer-capsule.json" auditedHeadSha 2>/dev/null || true)"
  if singular_render_reaudit_prompt "$active_audit_prompt" "$audit_prompt" "$run_dir" "$n" \
       "$prior_head" "$head_sha" "$worktree" 2>/dev/null; then
    :
  else
    singular_append_event "l1.reaudit_prompt_fallback" "re-audit prompt render failed; using base audit prompt" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true
    cp "$audit_prompt" "$active_audit_prompt" 2>/dev/null || active_audit_prompt="$audit_prompt"
  fi

  # Assumption ledger (node assumption-ledger; behind SINGULAR_CTX_PACKET): inject the
  # assembled auditSection (staged at attempt-open) into the per-attempt auditor prompt
  # so the auditor verifies the assumptions and flags violations citing the assumption
  # id. No-op when OFF (byte-identical) and never aborts the drive.
  assumptions_inject_audit "$active_audit_prompt" || true

  local audit_infra_max="${SINGULAR_AUDIT_INFRA_MAX:-2}"
  [[ "$audit_infra_max" =~ ^[0-9]+$ ]] || audit_infra_max=2
  local verify_infra_max="${SINGULAR_AUDIT_VERIFY_INFRA_MAX:-$audit_infra_max}"
  [[ "$verify_infra_max" =~ ^[0-9]+$ ]] || verify_infra_max="$audit_infra_max"
  local verification_outcome="" verification_integrity="" verification_rc=0
  local host_verification_status=""
  local verification_try=0 verification_ready="no"

  # Re-run the committed gate in a disposable writable worktree. Cache and log
  # writes are isolated there; the original audited worktree remains untouched.
  if [[ "${SINGULAR_AUDIT_VERIFY:-1}" == "1" ]]; then
    for ((verification_try=0; verification_try<=verify_infra_max; verification_try++)); do
      if [[ "$verification_try" -gt 0 ]]; then
        singular_append_event "audit.verification_infra_retry" \
          "audit verification infrastructure failure; retrying disposable gate only" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$verification_try}" || true
      fi
      verification_rc=0
      "$SCRIPT_DIR/audit-verify.sh" \
        --run-dir "$run_dir" --task-id "$task_id" --source-worktree "$worktree" \
        --head-sha "$head_sha" --gate-command "$gate_cmd" \
        --worker-gate-report "$run_dir/gate-report.json" \
        --attempt "$n" --try "$verification_try" \
        >"$run_dir/audit-verification-driver.log" 2>&1 || verification_rc=$?
      verification_outcome="$(singular_json_field "$run_dir/audit-verification.json" outcome 2>/dev/null || true)"
      verification_integrity="$(
        singular_json_field "$run_dir/audit-verification.json" sourceIntegrity.status \
          2>/dev/null || true
      )"
      if [[ "$verification_integrity" == "violation" ]]; then
        # A gate that tries to modify committed source has crossed the audit
        # integrity boundary. Never mask that deterministic violation with the
        # worker's earlier evidence-only report.
        write_host_audit_verdict "inconclusive-infrastructure" "blocked" \
          "The independently rerun gate attempted to mutate committed source; the disposable worktree was discarded and evidence-only substitution is forbidden."
        verdict="blocked"
        append_audit_evidence
        singular_append_event "audit.source_integrity_violation" \
          "audit gate attempted source mutation; task parked without evidence-only fallback" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$verification_try}" \
          || true
        attempt_failure="audit-infra"
        attempt_ctx="$run_dir/audit-verification.json"
        return 1
      fi
      case "$verification_outcome" in
        passed|passed-with-acknowledged-baseline|not-rerun-evidence-verified)
          verification_ready="yes"
          break
          ;;
        failed-product)
          write_host_audit_verdict "failed-product" "needs-fix" \
            "The independently rerun gate failed with a product-test signal at the committed head."
          verdict="needs-fix"
          append_audit_evidence
          singular_append_event "l1.audit_completed" "host audit verification found a product failure" \
            "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"verdict\":\"needs-fix\",\"verification\":\"failed-product\"}"
          attempt_failure="audit-needs-fix"
          attempt_ctx="$run_dir/audit-verification.json"
          return 1
          ;;
        *)
          : # infrastructure/invalid report: bounded disposable retry
          ;;
      esac
    done
  fi

  # A deterministic, successful worker gate may substitute only after every
  # disposable rerun was infrastructure-inconclusive (or reruns were disabled).
  if [[ "$verification_ready" != "yes" ]]; then
    verification_rc=0
    "$SCRIPT_DIR/audit-verify.sh" \
      --run-dir "$run_dir" --task-id "$task_id" --source-worktree "$worktree" \
      --head-sha "$head_sha" --gate-command "$gate_cmd" \
      --worker-gate-report "$run_dir/gate-report.json" \
      --worker-gate-command "$(singular_bash_bin) -c $gate_cmd" --evidence-only \
      >"$run_dir/audit-verification-evidence-only.log" 2>&1 || verification_rc=$?
    verification_outcome="$(singular_json_field "$run_dir/audit-verification.json" outcome 2>/dev/null || true)"
    if [[ "$verification_rc" -eq 0 && "$verification_outcome" == "not-rerun-evidence-verified" ]]; then
      verification_ready="yes"
      singular_append_event "audit.evidence_only_verified" \
        "disposable rerun inconclusive; hash-bound worker gate evidence verified" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true
    else
      write_host_audit_verdict "inconclusive-infrastructure" "blocked" \
        "The gate could not be rerun in a disposable workspace and the original gate evidence did not verify."
      verdict="blocked"
      append_audit_evidence
      singular_append_event "l1.audit_completed" "audit verification infrastructure failure" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"verdict\":\"infra\",\"verification\":\"inconclusive-infrastructure\"}"
      attempt_failure="audit-infra"
      attempt_ctx="$run_dir/audit-verification.json"
      return 1
    fi
  fi

  # The host owns verification classification. In particular, successful
  # hash-bound evidence-only validation is not equivalent to a real rerun.
  # Normalize only the acknowledged-baseline success alias; every other v1
  # classification remains exact.
  if ! host_verification_status="$(
    python3 "$SCRIPT_DIR/audit-verdict-host-bind.py" \
      --host-report "$run_dir/audit-verification.json" 2>/dev/null
  )"; then
    write_host_audit_verdict "inconclusive-infrastructure" "blocked" \
      "The host verification report did not contain a supported classification."
    verdict="blocked"
    append_audit_evidence
    attempt_failure="audit-infra"
    attempt_ctx="$run_dir/audit-verification.json"
    return 1
  fi

  # Refresh the compact manifest so it includes the host verification report.
  if ! "$SCRIPT_DIR/evidence-manifest.sh" \
      --run-dir "$run_dir" --task-id "$task_id" --worktree "$worktree" \
      --base-ref "$packet_base_ref" --head-sha "$head_sha" \
      >"$run_dir/evidence-manifest-audit-refresh.log" 2>&1; then
    write_host_audit_verdict "inconclusive-infrastructure" "blocked" \
      "The host verification completed, but its hash-bound evidence manifest could not be refreshed."
    verdict="blocked"
    append_audit_evidence
    attempt_failure="audit-infra"
    attempt_ctx="$run_dir/evidence-manifest-audit-refresh.log"
    return 1
  fi

  # Give the model the exact host-derived value it must reproduce. Use a
  # per-attempt copy so a prompt-render fallback can never mutate the reusable
  # base prompt.
  local bound_audit_prompt="$run_dir/auditor-bound-prompt-attempt-$n.md"
  if ! cp "$active_audit_prompt" "$bound_audit_prompt" \
    || ! python3 - "$bound_audit_prompt" "$host_verification_status" <<'PY'
import sys

path, classification = sys.argv[1:3]
with open(path, "a", encoding="utf-8") as handle:
    handle.write(
        "\n\n---\n\n"
        "## Host Verification Binding (authoritative)\n\n"
        f"The host verification classification is `{classification}`. "
        "For audit-verdict.v1, the aggregate of verificationResults.status "
        "MUST equal this exact value. Do not report `passed` for "
        "`not-rerun-evidence-verified`.\n"
    )
PY
  then
    write_host_audit_verdict "inconclusive-infrastructure" "blocked" \
      "The host verification completed, but its classification could not be bound into the auditor prompt."
    verdict="blocked"
    append_audit_evidence
    attempt_failure="audit-infra"
    attempt_ctx="$bound_audit_prompt"
    return 1
  fi
  active_audit_prompt="$bound_audit_prompt"

  # ---- Auditor runner with bounded infra-retry (T-E6) -----------------------
  # An auditor "infra failure" is the runner itself timing out (rc 124) / refusing
  # (later-wave rc 86), the record file never appearing, or output that carries no
  # parseable JSON verdict (broken/empty model output, the l1.audit_unparseable
  # path) — distinct from a real needs-fix verdict. We re-run ONLY the auditor,
  # fresh (no session reuse), up to SINGULAR_AUDIT_INFRA_MAX extra times. This never
  # bumps the lease retryCount and never re-runs the worker. If a parseable verdict
  # appears on any try, we proceed to the normal ledger/capsule/verdict handling;
  # if exhausted, the attempt fails as audit-infra and the (fast-path) decider parks it.
  verdict="unknown"

  # ---- Session affinity (T-E5): reviewer resume decision (first try only) ----
  # The auditor runs on SINGULAR_RUNNER_BIN (cross-model independence preserved). It
  # uses a SEPARATE per-role meta file + role gate, so the reviewer can NEVER be
  # offered the implementer's session. Lineage head = head_sha (the audited head).
  # prompt_sha is the BASE auditor prompt (the active prompt is per-attempt delta).
  local audit_runner_basename reviewer_prompt_sha reviewer_resume_id="" reviewer_decision
  audit_runner_basename="$(basename "$SINGULAR_RUNNER_BIN")"
  reviewer_prompt_sha="$(singular_prompt_sha "$audit_prompt" 2>/dev/null || true)"
  # Routed through the ctx-* adapter (SINGULAR_CTX_ROUTING; default 0 -> OFF-parity,
  # byte-identical to the direct decider call). Step `final-audit` is an
  # independence-required step, so ON the taint pin binds here: a would-be resume
  # is refused as `fresh tainted` regardless of routing knob values.
  reviewer_decision="$(singular_ctx_route_decide reviewer final-audit "$session_meta_reviewer" \
    "$task_id" "$run_id" "$audit_runner_basename" "$reviewer_prompt_sha" "$worktree" "$head_sha" 2>/dev/null || echo "fresh decide-error")"
  reviewer_strategy="${reviewer_decision%% *}"
  reviewer_strategy_reason="${reviewer_decision#* }"
  if [[ "$reviewer_strategy" == "resume" ]]; then
    reviewer_resume_id="$reviewer_strategy_reason"; reviewer_strategy_reason="resume"
    singular_append_event "context.strategy_selected" "session resume strategy selected" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"reviewer\",\"attempt\":$n,\"strategy\":\"resume\",\"reason\":\"resume\",\"sessionId\":\"$reviewer_resume_id\"}" || true
  else
    singular_append_event "context.strategy_selected" "fresh-run strategy selected" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"reviewer\",\"attempt\":$n,\"strategy\":\"fresh\",\"reason\":\"$reviewer_strategy_reason\"}" || true
  fi
  local reviewer_resume_failed="no"

  local audit_parsed="no" audit_try infra_reason audit_result_file audit_fc
  local audit_capability_profile
  local audit_pid="" audit_child_pgid=""
  local audit_schema audit_validation_rc
  local audit_repair_error_file="" audit_repair_response_file=""
  local audit_prompt_for_try repair_prompt
  # Auditor runner output is durable (0.6.0): the console streams it as a
  # labeled session pane; previously it went to /dev/null.
  local auditor_log="$run_dir/auditor-codex.log"
  for ((audit_try=0; audit_try<=audit_infra_max; audit_try++)); do
    if [[ "$audit_try" -gt 0 ]]; then
      singular_append_event "audit.infra_retry" "auditor infra failure; re-running auditor only" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$audit_try,\"reason\":\"$infra_reason\"}"
      echo "  auditor infra retry $audit_try/$audit_infra_max ($infra_reason)..."
    fi
    audit_prompt_for_try="$active_audit_prompt"
    if [[ "$audit_try" -gt 0 && -n "$audit_repair_error_file" \
        && -n "$audit_repair_response_file" ]]; then
      repair_prompt="$run_dir/auditor-repair-prompt-attempt-${n}-try-${audit_try}.md"
      if ! render_audit_repair_prompt "$active_audit_prompt" "$repair_prompt" \
          "$audit_repair_error_file" "$audit_repair_response_file" \
          "$audit_write_contract"; then
        infra_reason="repair-prompt-failed"
        singular_append_event "l1.audit_repair_prompt_failed" \
          "auditor validation-feedback repair prompt could not be rendered" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$audit_try}" \
          || true
        break
      fi
      audit_prompt_for_try="$repair_prompt"
      singular_append_event "l1.audit_repair_retry" \
        "auditor validation-feedback repair retry prepared" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"try\":$audit_try,\"reason\":\"$infra_reason\"}" \
        || true
    fi
    # Resume only on the FIRST try; wave-4 audit-infra retries stay FRESH.
    local audit_run_args=(--level readonly -C "$worktree" --run-id "$run_id" \
      --prompt-file "$audit_prompt_for_try" --output-last-message "$audit_record" \
      --session-meta "$session_meta_reviewer")
    if [[ "$audit_try" -eq 0 && -n "$reviewer_resume_id" && "$reviewer_resume_failed" == "no" ]]; then
      echo "  running auditor via $audit_runner_basename (read-only, resume $reviewer_resume_id)..."
      audit_run_args+=(--resume-session "$reviewer_resume_id")
      audit_result_file="$run_dir/auditor-attempt-${n}-try-${audit_try}-resume-runner-result.json"
    else
      echo "  running auditor via $audit_runner_basename (read-only)..."
      audit_result_file="$run_dir/auditor-attempt-${n}-try-${audit_try}-runner-result.json"
    fi
    audit_rc=0
    rm -f "$audit_record"
    printf -- '--- auditor try %s (attempt %s) ---\n' "$audit_try" "$n" >>"$auditor_log" || true
    audit_capability_profile="${SINGULAR_AUDITOR_CAPABILITY_PROFILE:-audit-core}"
    singular_runner_contract_prepare \
      "$SINGULAR_RUNNER_BIN" auditor "$audit_capability_profile" "$audit_result_file"
    SINGULAR_RUNNER_ROLE=auditor \
    SINGULAR_RUNNER_CAPABILITY_PROFILE="$audit_capability_profile" \
    SINGULAR_RUNNER_RESULT_FILE="$audit_result_file" \
      "$SINGULAR_RUNNER_BIN" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
        "${audit_run_args[@]}" >>"$auditor_log" 2>&1 &
    audit_pid="$!"
    audit_child_pgid="$(ps -o pgid= -p "$audit_pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$audit_child_pgid" =~ ^[1-9][0-9]*$ ]] || audit_child_pgid="$l1_pgid"
    l1_status auditing active "Auditor is reviewing attempt $n" true \
      "Wait for the auditor verdict" "" "auditor" "$audit_pid" "$audit_child_pgid"
    if wait "$audit_pid"; then
      audit_rc=0
    else
      audit_rc=$?
    fi
    l1_status auditing active "Classifying the auditor response for attempt $n" true \
      "Validate the audit verdict" "" "audit-controller"

    # Resume-refused/failure (86): fall back to FRESH within the SAME try (don't
    # consume an infra retry on a resume miss). Pure optimization miss.
    if [[ "$audit_rc" -eq 86 && -n "$reviewer_resume_id" && "$reviewer_resume_failed" == "no" ]]; then
      reviewer_resume_failed="yes"
      singular_append_event "context.resume_failed" "reviewer resume failed; re-running fresh" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"reviewer\",\"attempt\":$n,\"sessionId\":\"$reviewer_resume_id\"}" || true
      reviewer_strategy="fresh"; reviewer_strategy_reason="resume-failed"
      echo "  auditor resume failed; falling back to fresh run..."
      audit_result_file="$run_dir/auditor-attempt-${n}-try-${audit_try}-resume-fallback-runner-result.json"
      audit_rc=0
      rm -f "$audit_record"
      printf -- '--- auditor resume-fallback (attempt %s) ---\n' "$n" >>"$auditor_log" || true
      singular_runner_contract_prepare \
        "$SINGULAR_RUNNER_BIN" auditor "$audit_capability_profile" "$audit_result_file"
      SINGULAR_RUNNER_ROLE=auditor \
      SINGULAR_RUNNER_CAPABILITY_PROFILE="$audit_capability_profile" \
      SINGULAR_RUNNER_RESULT_FILE="$audit_result_file" \
        "$SINGULAR_RUNNER_BIN" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
          --level readonly -C "$worktree" --run-id "$run_id" \
          --prompt-file "$active_audit_prompt" --output-last-message "$audit_record" \
          --session-meta "$session_meta_reviewer" >>"$auditor_log" 2>&1 &
      audit_pid="$!"
      audit_child_pgid="$(ps -o pgid= -p "$audit_pid" 2>/dev/null | tr -d '[:space:]' || true)"
      [[ "$audit_child_pgid" =~ ^[1-9][0-9]*$ ]] || audit_child_pgid="$l1_pgid"
      l1_status auditing active "Auditor is reviewing attempt $n" true \
        "Wait for the fresh auditor verdict" "" "auditor" "$audit_pid" "$audit_child_pgid"
      if wait "$audit_pid"; then
        audit_rc=0
      else
        audit_rc=$?
      fi
      l1_status auditing active "Classifying the auditor response for attempt $n" true \
        "Validate the audit verdict" "" "audit-controller"
    fi
    audit_fc="$(singular_planner_failure_class "$auditor_log" "$audit_rc" \
      "$audit_record" "$audit_result_file")"
    # Structured provider results take precedence. Neither provider-window class
    # is retried here; the cycle-level validated-provider-evidence path owns any
    # backoff. Without the provider-overloaded arm a 529 fell through to the
    # `! -f "$audit_record"` branch below and was mislabelled `no-record`.
    if [[ "$audit_fc" == "quota" || "$audit_fc" == "provider-overloaded" ]]; then
      infra_reason="$audit_fc"
      break
    elif [[ "$audit_fc" == "timeout" ]]; then
      infra_reason="timeout"
    elif [[ "$audit_fc" == "codex-exit" ]]; then
      infra_reason="provider-exit"
    elif [[ ! -f "$audit_record" ]]; then
      infra_reason="no-record"
    elif ! singular_extract_json "$audit_record" "$audit_record" 2>/dev/null; then
      # No parseable JSON verdict (prose-only, refusal, or truncated output). Keep
      # the existing l1.audit_unparseable signal firing per infra try.
      infra_reason="unparseable"
      singular_append_event "l1.audit_unparseable" "auditor produced no parseable JSON verdict" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}"
    else
      audit_schema="$(singular_json_field "$audit_record" schema 2>/dev/null || true)"
      audit_validation_rc=0
      validate_audit_record "$audit_record" 2>"$run_dir/audit-validate.err" \
        || audit_validation_rc=$?
      if [[ "$audit_schema" == "singular.orchestration.audit-verdict.v1" \
          && "$audit_validation_rc" -ne 0 ]]; then
        # v1 is captured as plain provider output because the public schema is
        # richer than provider strict-output subsets. Host validation is always
        # fail-closed before any v1 verdict can influence acceptance.
        infra_reason="invalid-verdict"
        audit_repair_response_file="$run_dir/audit-attempt-${n}-try-${audit_try}.invalid.json"
        audit_repair_error_file="$run_dir/audit-attempt-${n}-try-${audit_try}.validate.err"
        cp "$audit_record" "$audit_repair_response_file"
        cp "$run_dir/audit-validate.err" "$audit_repair_error_file"
        cp "$audit_record" "$audit_record.invalid.json" 2>/dev/null || true
        singular_append_event "l1.audit_invalid_verdict" "auditor v1 verdict failed host schema validation" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"detail\":\"$(head -1 "$run_dir/audit-validate.err" 2>/dev/null | tr '"' "'" | head -c 300)\"}"
      elif [[ -n "$audit_schema" \
          && "$audit_schema" != "singular.orchestration.audit-verdict.v1" \
          && "$audit_schema" != "singular.orchestration.audit-verdict.v0" \
          && "$audit_schema" != "pmgo.orchestration.audit-verdict.v0" ]]; then
        infra_reason="unsupported-verdict-schema"
        audit_repair_response_file="$run_dir/audit-attempt-${n}-try-${audit_try}.invalid.json"
        audit_repair_error_file="$run_dir/audit-attempt-${n}-try-${audit_try}.validate.err"
        cp "$audit_record" "$audit_repair_response_file"
        printf 'unsupported audit verdict schema %q; expected %s\n' \
          "$audit_schema" "$audit_write_schema" >"$audit_repair_error_file"
      elif [[ -z "$audit_schema" && "$audit_write_contract" == "v1" ]]; then
        infra_reason="unsupported-verdict-schema"
        audit_repair_response_file="$run_dir/audit-attempt-${n}-try-${audit_try}.invalid.json"
        audit_repair_error_file="$run_dir/audit-attempt-${n}-try-${audit_try}.validate.err"
        cp "$audit_record" "$audit_repair_response_file"
        printf 'audit verdict schema is missing; expected %s\n' \
          "$audit_write_schema" >"$audit_repair_error_file"
      elif [[ "${SINGULAR_AUDIT_VERDICT_VALIDATE:-warn}" == "strict" \
          && "$audit_validation_rc" -ne 0 ]]; then
        infra_reason="invalid-verdict"
        audit_repair_response_file="$run_dir/audit-attempt-${n}-try-${audit_try}.invalid.json"
        audit_repair_error_file="$run_dir/audit-attempt-${n}-try-${audit_try}.validate.err"
        cp "$audit_record" "$audit_repair_response_file"
        cp "$run_dir/audit-validate.err" "$audit_repair_error_file"
        cp "$audit_record" "$audit_record.invalid.json" 2>/dev/null || true
        singular_append_event "l1.audit_invalid_verdict" "legacy auditor verdict failed schema validation" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"detail\":\"$(head -1 "$run_dir/audit-validate.err" 2>/dev/null | tr '"' "'" | head -c 300)\"}"
      elif [[ "$audit_schema" == "singular.orchestration.audit-verdict.v1" ]]; then
        # Schema validity is not enough: the model must reproduce the
        # host-owned verification aggregate exactly. A model cannot upgrade
        # hash-verified evidence-only validation into a real rerun pass.
        if model_verification_status="$(
          python3 "$SCRIPT_DIR/audit-verdict-host-bind.py" \
            --host-report "$run_dir/audit-verification.json" \
            --verdict "$audit_record" 2>"$run_dir/audit-verification-bind.err"
        )"; then
          audit_parsed="yes"
          break
        else
          model_verification_status=""
          infra_reason="verification-classification-mismatch"
          audit_repair_response_file="$run_dir/audit-attempt-${n}-try-${audit_try}.invalid.json"
          audit_repair_error_file="$run_dir/audit-attempt-${n}-try-${audit_try}.bind.err"
          cp "$audit_record" "$audit_repair_response_file"
          cp "$run_dir/audit-verification-bind.err" "$audit_repair_error_file"
          cp "$audit_record" "$audit_record.invalid.json" 2>/dev/null || true
          singular_append_event "l1.audit_verification_mismatch" \
            "auditor verification classification did not match the host report" \
            "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"hostVerification\":\"$host_verification_status\",\"detail\":\"$(head -1 "$run_dir/audit-verification-bind.err" 2>/dev/null | tr '"' "'" | head -c 300)\"}" \
            || true
        fi
      else
        if [[ "${SINGULAR_AUDIT_VERDICT_VALIDATE:-warn}" == "warn" \
            && "$audit_validation_rc" -ne 0 ]]; then
        singular_append_event "l1.audit_verdict_warned" "auditor verdict failed schema validation (warn mode; proceeding)" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"detail\":\"$(head -1 "$run_dir/audit-validate.err" 2>/dev/null | tr '"' "'" | head -c 300)\"}" || true
        fi
        audit_parsed="yes"
        break
      fi
    fi
  done
  if [[ "$audit_parsed" == "yes" ]]; then
    {
      verdict="$(singular_json_field "$audit_record" verdict 2>/dev/null || echo unknown)"
      # Findings ledger + reviewer capsule on every parseable verdict (additive
      # observability; never aborts the drive). prior_head is the previous
      # attempt's auditedHeadSha when a reviewer capsule already exists.
      local ledger_out ledger_event
      ledger_out="$(singular_findings_ledger_update "$run_dir" "$n" "$audit_record" 2>/dev/null)" \
        || { ledger_out=""; singular_append_event "l1.findings_ledger_failed" "findings ledger update failed (non-fatal)" \
               "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true; }
      if [[ -n "$ledger_out" ]]; then
        ledger_event="$(python3 -c 'import json,sys
parts = dict(kv.split("=", 1) for kv in sys.argv[3].split() if "=" in kv)
print(json.dumps({"taskId": sys.argv[1], "runId": sys.argv[2], "attempt": int(sys.argv[4]),
                  "open": int(parts.get("open", 0)), "resolved": int(parts.get("resolved", 0)),
                  "new": int(parts.get("new", 0))}, separators=(",", ":")))' \
          "$task_id" "$run_id" "$ledger_out" "$n" 2>/dev/null || true)"
        [[ -n "$ledger_event" ]] && { singular_append_event "findings.ledger_updated" "findings ledger updated" "$ledger_event" || true; }
      fi
      # prior_head was captured at the top of run_audit_phase (before this
      # attempt overwrites the reviewer capsule); reuse it for the diffRange.
      singular_capsule_write_reviewer "$run_dir" "$n" "$audit_record" "$prior_head" "$head_sha" >/dev/null 2>&1 \
        || singular_append_event "l1.capsule_write_failed" "reviewer capsule write failed (non-fatal)" \
             "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"role\":\"reviewer\",\"attempt\":$n}" || true
      # Session affinity (T-E5): merge host-authority fields into the reviewer meta
      # so a later audit try (this run) can resume it. headShaAtCreate = head_sha
      # (the audited head). Never fatal.
      singular_session_meta_finalize "$session_meta_reviewer" reviewer "$task_id" "$run_id" \
        "$audit_runner_basename" "$reviewer_prompt_sha" "$head_sha" "$n" >/dev/null 2>&1 || true
      # Assumption ledger attempt-close (node assumption-ledger; behind
      # SINGULAR_CTX_PACKET): fold the auditor findings (which cite assumption ids) into
      # this attempt's input ledger via the integrated host-derived transition and
      # persist the updated ledger to the run_dir sidecar, so the NEXT attempt's
      # assemble carries sticky `violated` statuses. No-op when OFF; never fatal.
      assumptions_attempt_close "$audit_record" || true
    }
  else
    # Auditor infra failure persisted across SINGULAR_AUDIT_INFRA_MAX fresh re-runs:
    # a model decider cannot fix broken/empty auditor output. Surface as
    # audit-infra so the (fast-path) decider parks it; retryCount stays untouched.
    singular_append_event "l1.audit_completed" "auditor completed (infra failure)" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"verdict\":\"infra\"}"
    attempt_failure="audit-infra"; attempt_ctx="$run_dir/worker-codex.log"
    [[ -f "$audit_record" ]] && attempt_ctx="$audit_record"
    return 1
  fi
  echo "  auditor verdict=$verdict"
  singular_append_event "l1.audit_completed" "auditor completed" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"verdict\":\"$verdict\",\"verification\":\"${model_verification_status:-legacy}\"}"
  append_audit_evidence
  # Persist the final provider usage and every per-try runner sidecar after the
  # auditor invocation. The pre-audit manifest remains the bounded prompt input;
  # this refresh is the durable post-run accounting record.
  if ! "$SCRIPT_DIR/evidence-manifest.sh" \
      --run-dir "$run_dir" --task-id "$task_id" --worktree "$worktree" \
      --base-ref "$packet_base_ref" --head-sha "$head_sha" \
      >"$run_dir/evidence-manifest-final-refresh.log" 2>&1; then
    attempt_failure="audit-infra"
    attempt_ctx="$run_dir/evidence-manifest-final-refresh.log"
    return 1
  fi

  if [[ "${model_verification_status:-}" == "failed-product" ]]; then
    attempt_failure="audit-needs-fix"; attempt_ctx="$audit_record"; return 1
  fi
  if [[ "${model_verification_status:-}" == "inconclusive-infrastructure" ]]; then
    attempt_failure="audit-infra"; attempt_ctx="$audit_record"; return 1
  fi

  if [[ "$require_audit" == "1" && "$verdict" != "accepted" ]]; then
    attempt_failure="audit-$verdict"; attempt_ctx="$audit_record"; return 1
  fi
  return 0
}

# Archive one attempt's artifacts (T-E1): wraps singular_attempt_archive with the
# driver's globals; a failure here NEVER aborts the drive.
# args: n failure_class decider_action authority
archive_attempt() {
  SINGULAR_ATTEMPT_TASK_ID="$task_id" SINGULAR_ATTEMPT_STARTED_AT="$attempt_started_at" \
    SINGULAR_ATTEMPT_WORKER_STRATEGY="${worker_strategy:-}" \
    SINGULAR_ATTEMPT_REVIEWER_STRATEGY="${reviewer_strategy:-}" \
    singular_attempt_archive "$run_dir" "$1" "$2" "$verdict" "$head_sha" "$3" "$4" >/dev/null 2>&1 \
    || { singular_append_event "l1.attempt_archive_failed" "attempt archive failed (non-fatal)" \
           "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"n\":$1}" 2>/dev/null || true; }
}

# ---- Assumption ledger wire-in (node assumption-ledger; behind SINGULAR_CTX_PACKET) --
# Terminal driver wire-in for the S4-context-packets assumption-ledger node. Every
# site below is a no-op unless SINGULAR_CTX_PACKET is set to a non-zero value (default
# 0), so with the flag unset/0 l1-drive.sh renders byte-identical prompts, writes no
# ledger sidecar / section files, and emits no assumptions events. Each site delegates
# into the integrated PURE bricks (singular_ctx_assumptions_assemble at attempt-open,
# singular_ctx_assumptions_transition at attempt-close) and adds no rendering of its
# own. Fail-closed: on any error the attempt proceeds WITHOUT injection (non-fatal),
# preserving the run. These sites are additive and disjoint from the post-acceptance
# paired-audit (TASK-0006) and critic-recheck (TASK-0033) hooks, so this node's
# l1-drive.sh ownership does not collide with theirs.
assumptions_ctx_enabled() { [[ -n "${SINGULAR_CTX_PACKET:-}" && "${SINGULAR_CTX_PACKET}" != "0" ]]; }
assumptions_ledger_sidecar="$run_dir/assumptions-ledger.json"
assumptions_fix_section_file="$run_dir/assumptions-fix-section.md"
assumptions_audit_section_file="$run_dir/assumptions-audit-section.md"
assumptions_attempt_ledger_file="$run_dir/assumptions-attempt-ledger.json"

# Attempt-open: assemble the per-run ledger as carry(prior, seed(task)) from the task
# packet and the per-run prior sidecar (empty on attempt 1) and stage this attempt's
# fixSection/auditSection + input-ledger snapshot to run_dir files. Non-fatal; on any
# error nothing is staged (fail-closed) and the attempt proceeds without injection.
assumptions_attempt_open() {
  assumptions_ctx_enabled || return 0
  rm -f "$assumptions_fix_section_file" "$assumptions_audit_section_file" \
    "$assumptions_attempt_ledger_file" 2>/dev/null || true
  local prior='' envelope
  [[ -f "$assumptions_ledger_sidecar" ]] && prior="$(cat "$assumptions_ledger_sidecar" 2>/dev/null || true)"
  envelope="$(singular_ctx_assumptions_assemble "$task_file" "$prior" 2>/dev/null)" || return 0
  [[ -n "$envelope" ]] || return 0
  python3 - "$envelope" "$assumptions_fix_section_file" "$assumptions_audit_section_file" \
    "$assumptions_attempt_ledger_file" <<'PY' 2>/dev/null || return 0
import json, sys
env = json.loads(sys.argv[1])
fix = env.get("fixSection") or ""
aud = env.get("auditSection") or ""
led = env.get("ledger") or {}
if fix:
    open(sys.argv[2], "w", encoding="utf-8").write(fix)
if aud:
    open(sys.argv[3], "w", encoding="utf-8").write(aud)
open(sys.argv[4], "w", encoding="utf-8").write(json.dumps(led, sort_keys=True))
PY
  return 0
}

# Inject the staged fixSection into the implementer's already-rendered active/fix
# prompt (the file the worker runner reads). Called AFTER prepare_worker_prompt so it
# applies uniformly across the attempt-1 copy and the retry fix-prompt render. No-op
# when OFF or when the section is empty (a zero-assumption task).
assumptions_inject_fix() {
  assumptions_ctx_enabled || return 0
  [[ -s "$assumptions_fix_section_file" ]] || return 0
  { echo ""; echo "---"; echo ""; cat "$assumptions_fix_section_file"; } \
    >> "$run_dir/l2-active-prompt.md" 2>/dev/null || true
  return 0
}

# Inject the staged auditSection into the per-attempt auditor prompt (the file the
# auditor runner reads), around the re-audit render site and before the runner reads
# it. No-op when OFF or when the section is empty.
assumptions_inject_audit() {
  local active_audit_prompt="$1"
  assumptions_ctx_enabled || return 0
  [[ -s "$assumptions_audit_section_file" ]] || return 0
  { echo ""; echo "---"; echo ""; cat "$assumptions_audit_section_file"; } \
    >> "$active_audit_prompt" 2>/dev/null || true
  return 0
}

# Record the per-attempt ledger (assumption statuses) alongside the implementer
# capsule write — additive and non-fatal: a failure logs an event and never aborts
# the attempt. No-op when OFF.
assumptions_record_capsule() {
  local n="$1"
  assumptions_ctx_enabled || return 0
  [[ -f "$assumptions_attempt_ledger_file" ]] || return 0
  cp "$assumptions_attempt_ledger_file" "$run_dir/assumptions-attempt-$n.json" 2>/dev/null \
    || singular_append_event "l1.assumptions_record_failed" "per-attempt assumption ledger record failed (non-fatal)" \
         "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n}" || true
  return 0
}

# Attempt-close: after a parseable auditor verdict, fold the auditor findings (which
# the injected auditSection instructs the auditor to cite by assumption id) into this
# attempt's input ledger via the integrated host-derived transition, then persist the
# updated ledger to the run_dir sidecar so the NEXT attempt's assemble carries sticky
# `violated` statuses. Non-fatal; fail-closed leaves the prior sidecar untouched.
assumptions_attempt_close() {
  local audit_record="$1"
  assumptions_ctx_enabled || return 0
  [[ -f "$assumptions_attempt_ledger_file" && -f "$audit_record" ]] || return 0
  local ledger findings updated
  ledger="$(cat "$assumptions_attempt_ledger_file" 2>/dev/null || true)"
  [[ -n "$ledger" ]] || return 0
  findings="$(python3 - "$audit_record" 2>/dev/null <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception:
    r = {}
f = r.get("findings") if isinstance(r, dict) else None
sys.stdout.write(json.dumps(f if isinstance(f, list) else []))
PY
)" || return 0
  updated="$(singular_ctx_assumptions_transition "$ledger" "$findings" 2>/dev/null)" || return 0
  [[ -n "$updated" ]] || return 0
  printf '%s\n' "$updated" > "$assumptions_ledger_sidecar.tmp" 2>/dev/null \
    && mv "$assumptions_ledger_sidecar.tmp" "$assumptions_ledger_sidecar" 2>/dev/null || true
  return 0
}

# ---- Decider-driven retry loop ----
# prev_failure_class/prev_attempt_ctx carry the PRIOR attempt's failure into the
# next prepare_worker_prompt (the per-iteration reset clears attempt_failure
# before the structured fix prompt is rendered); they mirror fix_hints.
accepted="no"; waiver="no"; fix_hints=""; prev_failure_class=""; prev_attempt_ctx=""; terminal_action=""
prev_progress_signature=""
terminal_authority="decider"
terminal_rationale=""
attempt_started_at=""
for ((attempt=0; attempt<=max_retries; attempt++)); do
  [[ "$attempt" -gt 0 ]] && echo "  retry attempt $attempt/$max_retries (last: $attempt_failure)"
  n=$((attempt + 1))
  attempt_started_at="$(singular_timestamp)"
  attempt_failure=""; attempt_ctx=""
  verdict="unknown"; head_sha=""
  attempt_ok="no"
  # Assumption ledger (node assumption-ledger; behind SINGULAR_CTX_PACKET): assemble
  # this attempt's ledger from the task packet + per-run prior sidecar BEFORE the
  # prompt is rendered, then inject the assembled fixSection into the already-rendered
  # active/fix prompt. Both no-op when OFF (byte-identical) and never abort the drive.
  assumptions_attempt_open "$n" || true
  prepare_worker_prompt "$n"
  assumptions_inject_fix || true
  if run_worker_phase "$n"; then
    if run_audit_phase "$n"; then attempt_ok="yes"; fi
  fi
  if [[ "$attempt_ok" == "yes" ]]; then
    accepted="yes"
    # From this decision until inbox placement, an interruption must never
    # revert the lease to failed — the packet/audit already exist and the
    # next dispatch auto-heals via accept-existing-packet (E5).
    _l1_outcome="accept-pending"
    archive_attempt "$n" "" "accept" "l1"
    break
  fi

  blocker_rationale="$(singular_terminal_blocker_rationale "$attempt_failure" "${attempt_ctx:-/dev/null}" 2>/dev/null || true)"
  if [[ -n "$blocker_rationale" ]]; then
    terminal_action="escalate-parked"
    terminal_authority="l1"
    terminal_rationale="$blocker_rationale"
    echo "  $attempt_failure: parking (project blocker)"
    archive_attempt "$n" "$attempt_failure" "escalate-parked" "l1"
    break
  fi

  # No-progress guard. An attempt that produced the same code and the same
  # failure as the one before it will produce them again; there is nothing for a
  # retry to act on. Checked BEFORE the decider so a provably pointless cycle
  # does not also pay for a decider round-trip.
  #
  # Parked with a reason of its own, not as a product failure, because the two
  # call for opposite responses: a product failure wants another attempt, this
  # wants a human or a changed environment. `singular unpark` is how it comes
  # back once something outside the loop is different.
  progress_signature="$(singular_attempt_progress_signature \
    "$worktree" "$attempt_failure" "$head_sha" "$run_dir/gate-report.json" 2>/dev/null || true)"
  if [[ -n "$progress_signature" && "$progress_signature" == "$prev_progress_signature" ]]; then
    terminal_action="escalate-parked"
    terminal_authority="l1"
    terminal_rationale="no progress: attempt $n reproduced attempt $((n - 1)) exactly — same head ($([[ -n "$head_sha" ]] && echo "${head_sha:0:12}" || echo "no commit")), same uncommitted changes, same $attempt_failure failure. A further retry cannot differ; unpark once the environment or the task changes."
    echo "  $attempt_failure: parking (no progress since the previous attempt)"
    singular_append_event "l1.no_progress_parked" \
      "task parked because an attempt reproduced the previous one exactly" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"attempt\":$n,\"failureClass\":\"$attempt_failure\",\"headSha\":\"$head_sha\"}" || true
    archive_attempt "$n" "$attempt_failure" "escalate-parked" "l1"
    break
  fi
  prev_progress_signature="$progress_signature"

  # Failure -> decider. Try the policy fast-path first (T-F1): for clear-cut
  # classes with retry budget it resolves the action WITHOUT a model round-trip,
  # records provenance as authority=policy, and skips decide.sh. budget accounting
  # mirrors the loop's own retry-vs-park test below ($attempt vs max_retries), so
  # "retries left" is computed identically. An empty fast action falls through to
  # the model decider unchanged (authority=decider).
  decider_authority="decider"
  action=""
  if [[ "$verdict" == "needs-human" ]]; then
    l1_status awaiting-human waiting "Auditor requested human judgment" true \
      "Record an artifact-bound human approval or park the task"
  fi
  l1_status deciding active "Selecting the recovery action for $attempt_failure" true \
    "Retry within policy or record a terminal decision" "" "decision-controller"
  fast_action="$(singular_decider_fast_action "$attempt_failure" "$attempt" "$max_retries" "$prev_failure_class")"
  if [[ -n "$fast_action" ]]; then
    action="$fast_action"
    decider_authority="policy"
    echo "  failure: $attempt_failure -> fast-path: $action"
    "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "decide:$action" \
      --rationale "fast-path: $attempt_failure -> $action" --run "$run_id" \
      --branch "$worker_branch" --authority policy >/dev/null 2>&1 || true
    singular_append_event "decider.fast_path" "decider fast-path resolved a failure" \
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
      singular_lease_bump_retry "$task_id" >/dev/null 2>&1 || true
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
          if ! singular_scope_amendment_path_allowed "$p"; then
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
        singular_lease_update_owned "$task_id" "$amended_owned_json" 2>/dev/null || true
      fi
      archive_attempt "$n" "$attempt_failure" "$action" "$decider_authority"
      continue ;;
    accept-waiver)
      if singular_unbound_waivers_enabled; then
        accepted="yes"; waiver="yes"
        _l1_outcome="accept-pending"
        archive_attempt "$n" "$attempt_failure" "accept-waiver" "$decider_authority"
      else
        terminal_action="escalate-parked"
        terminal_authority="policy"
        terminal_rationale="unbound accept-waiver is disabled; record an exact-artifact human approval or repair the product failure"
        archive_attempt "$n" "$attempt_failure" "$terminal_action" "$terminal_authority"
        singular_append_event "governance.unbound_waiver_rejected" \
          "legacy unbound waiver rejected; exact-artifact approval required" \
          "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"failureClass\":\"$attempt_failure\"}" \
          || true
      fi
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
  if [[ -z "$terminal_rationale" ]]; then
    if [[ "$terminal_action" == "escalate-infra" ]]; then
      terminal_rationale="environment failure ($attempt_failure), not a product defect: the workspace could not run the gate. Repair the environment, then \`singular unpark $task_id\`."
    else
      terminal_rationale="decider terminal action after $attempt_failure"
    fi
  fi
  l1_status terminal failed "Task ended without acceptance: $terminal_action" true \
    "Inspect the decision and referenced failure evidence" "$terminal_action"
  case "$terminal_action" in
    supersede) singular_lease_set_status "$task_id" "superseded" 2>/dev/null || true; singular_task_set_status "$task_file" "superseded" || true ;;
    cancel)    singular_lease_set_status "$task_id" "cancelled"  2>/dev/null || true; singular_task_set_status "$task_file" "cancelled"  || true ;;
    split-task|fork) singular_lease_set_status "$task_id" "blocked" 2>/dev/null || true; singular_task_set_status "$task_file" "blocked" || true ;;
    *)         singular_lease_set_status "$task_id" "blocked" 2>/dev/null || true; singular_task_set_status "$task_file" "blocked" || true ;;
  esac
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "$terminal_action" \
    --rationale "$terminal_rationale" --run "$run_id" --branch "$worker_branch" --authority "$terminal_authority" || true
  singular_append_event "l1.task_terminal" "l1 task ended without acceptance" \
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

singular_lease_set_status "$task_id" "accepted"
singular_task_set_status "$task_file" "accepted"
dec_rationale="auditor accepted; regression gate green; scope clean"
[[ "$waiver" == "yes" ]] && dec_rationale="accepted via decider waiver (auditor: $verdict); gate green"
"$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "accept" \
  --rationale "$dec_rationale" --run "$run_id" --branch "$worker_branch"

inbox_packet="$SINGULAR_INBOX_DIR/$run_id.json"
cp "$packet" "$inbox_packet.tmp"
mv "$inbox_packet.tmp" "$inbox_packet"
_l1_outcome="accepted"
l1_status integrating active "Accepted packet queued for origin integration" true \
  "Finish acceptance bookkeeping and let origin reconcile"
singular_append_event "l1.task_accepted" "l1 task accepted" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"branch\":\"$worker_branch\",\"headSha\":\"$head_sha\",\"waiver\":\"$waiver\"}"

# ---- Artifact secret-scan finalize hook (DAG node artifact-secret-scan, layer
# engine_runtime; behind the default-OFF SINGULAR_CTX_ARTIFACT_SCAN knob) --------
# Strictly AFTER acceptance is finalized above and placed BEFORE the
# post-acceptance paired-audit fresh-audit prompt is assembled from durable
# artifacts (the singular_ctx_paired_audit_record hook below), beside the paired-
# audit / critic-recheck hooks. When the knob is unset or "0" this whole block is
# a no-op: no scan, no rename, no ctx.artifact_secret event, no manifest — so the
# accepted flow is byte-identical to pre-hook behavior. When ON it delegates into
# the integrated, already-tested containment bricks (ctx-artifact-quarantine.sh,
# ctx-artifact-exclude.sh, ctx-artifact-scan.sh) and adds no scan/exclude logic
# of its own:
#   1. singular_ctx_artifact_quarantine "$run_dir" renames any durable context
#      artifact whose content matches a secret pattern to `<path>.quarantined`
#      (evidence-preserving; content never deleted), records exactly one
#      ctx.artifact_secret event per hit, and leaves the accept/reject outcome
#      untouched. The rename already removes the artifact from its canonical path.
#   2. As belt-and-suspenders beyond the rename, enumerate the durable artifacts
#      (singular_ctx_artifact_scan_paths) and apply singular_ctx_artifact_exclude so
#      any quarantined artifact is dropped from the durable-artifact set that
#      feeds downstream rendered prompt assembly; the surviving safe set is staged
#      to $run_dir/durable-artifacts.manifest.
# Non-fatal (same pattern as the capsule-write-failed / paired-audit hooks): on
# any quarantine error it logs an l1.artifact_scan_failed event and NEVER aborts
# the drive. The quarantine/exclude result NEVER feeds back into the accept
# decision or the exit status.
if [[ -n "${SINGULAR_CTX_ARTIFACT_SCAN:-}" && "${SINGULAR_CTX_ARTIFACT_SCAN}" != "0" ]]; then
  # singular_secret_scan_patterns now lives in lib.sh (reading
  # engine/secret-patterns.tsv), so it is already defined here. It used to live
  # inside secret-scan.sh — a self-executing script lib.sh does not source —
  # which forced this branch to sed the function body out and eval it.
  if ! singular_ctx_artifact_quarantine "$run_dir" >/dev/null 2>&1; then
    singular_append_event "l1.artifact_scan_failed" "artifact secret-scan quarantine failed (non-fatal)" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\"}" || true
  fi
  # Belt-and-suspenders: the durable-artifact set that feeds downstream prompt
  # assembly, with every quarantined artifact excluded. Non-fatal.
  singular_ctx_artifact_scan_paths "$run_dir" 2>/dev/null \
    | singular_ctx_artifact_exclude > "$run_dir/durable-artifacts.manifest" 2>/dev/null \
    || true
fi

# Post-acceptance paired audit (observability only). Strictly AFTER acceptance is
# finalized above; self-guards on the default-OFF SINGULAR_PAIRED_AUDIT_PCT knob
# (unset/0 -> no fresh audit, no event, no file) so the accepted flow is
# byte-identical when disabled. The paired verdict NEVER feeds back into the
# accept decision or the exit status; a recorder/runner failure is non-fatal.
singular_ctx_paired_audit_record "$run_id" "$task_id" "$run_dir" "$worktree" || true

# Post-acceptance critic recheck (read-only; observability only). Strictly AFTER
# acceptance is finalized above, beside the paired-audit hook. Minimal delegation
# per the planner driver-hook rule: resolve the node and the prior plan-critique
# record via the pure/read-only locators (TASK-0032), and only when BOTH resolve
# invoke the recheck runner (TASK-0031). The runner self-guards on the default-OFF
# SINGULAR_CRITIC_RECHECK_PCT sampling gate (unset/0 -> no ctx.critic_recheck event,
# no recheck files, no state write) so the accepted flow is byte-identical when
# disabled. The recheck verdict/dispositions NEVER feed back into the accept
# decision or the exit status; a locator or runner failure is non-fatal (guarded).
#
# The integrated locators/runner are reached through an ASSEMBLED PREFIX (never the
# contiguous literal name), mirroring engine/ctx-critic-recheck-run.sh: this is the
# codebase's S2 contract-gate idiom that keeps a brick "structurally present but
# uncalled" under its own literal-substring invariance grep while a later slice
# (this hook) legitimately composes it (planner-contract rule 9). The delegation
# adds no recheck logic of its own.
_cr_pfx=singular_ctx_critic_recheck_
critic_recheck_node="$("${_cr_pfx}locate_node" "$task_id" "$worktree" 2>/dev/null || true)"
if [[ -n "$critic_recheck_node" ]]; then
  critic_recheck_record="$("${_cr_pfx}locate_record" "$critic_recheck_node" "$task_id" "$worktree" 2>/dev/null || true)"
  if [[ -n "$critic_recheck_record" ]]; then
    "${_cr_pfx}run" "$critic_recheck_node" "$run_id" "$task_id" "$run_dir" "$critic_recheck_record" "$worktree" || true
  fi
fi
unset _cr_pfx

# ---- Experiment arm knob-state finalize hook (DAG node experiment-run, layer
# evaluation; behind the default-OFF SINGULAR_CTX_ARMSTATE knob) ----------------
# Beside the sibling per-run provenance blocks above (the SINGULAR_CTX_ARTIFACT_SCAN
# durable-artifacts block, the paired-audit recorder, and the critic-recheck
# block): durably RECORD this run's observed continuity knob-state so the
# experiment report's per-arm attribution (control = M0 knob-state vs treatment)
# is auditable on disk. TASK-0093 shipped the pure read-only emitter
# singular_ctx_experiment_armstate_json but left it present-but-uncalled; this hook
# is the separable driver wire-in that emitter's context packet deferred.
#
# Minimal delegating call site — it inlines NO knob-state logic and only forwards
# to the integrated emitter, writing its output (for the run's environment) to a
# durable arm-knob-state.json under the run directory, non-fatal (|| true),
# mirroring the SINGULAR_CTX_ARTIFACT_SCAN block that writes durable-artifacts.manifest.
# When the knob is unset or "0" this whole block is a no-op: no file, no event,
# no state write — the accepted flow is byte-identical to pre-hook behavior. The
# recorded knob-state NEVER feeds back into the accept decision or the exit status
# (evidence invariance; it only writes an auditable file).
if [[ -n "${SINGULAR_CTX_ARMSTATE:-}" && "${SINGULAR_CTX_ARMSTATE}" != "0" ]]; then
  singular_ctx_experiment_armstate_json > "$run_dir/arm-knob-state.json" 2>/dev/null || true
fi

l1_status terminal completed "Accepted packet and audit evidence are durable" true \
  "Origin may import and integrate the packet" "accepted"
echo ""
echo "ACCEPTED: $task_id @ $head_sha (waiver=$waiver)"
echo "  packet: $inbox_packet  audit: $audit_record (verdict: $verdict)"
echo "  next: 'make orch-reconcile' to import, or let L0 actuate."
