#!/usr/bin/env bash
set -euo pipefail

# Require bash >= 4 (mapfile). macOS /bin/bash is 3.2; re-exec under Homebrew bash
# if launched with an old interpreter.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "integrate.sh requires bash >= 4 (mapfile); install via 'brew install bash'" >&2
  exit 1
fi

# L0 Integration step: merge ACCEPTED worker branches into the integration target
# branch. Local only — this NEVER pushes and NEVER touches `main`.
#
# A branch is eligible when its imported packet has status=accepted, the matching
# auditor verdict is accepted, the branch head matches the packet headSha, and the
# commit is not already merged into the target. Each merge is verified BEFORE it is
# finalized: `git merge --no-ff --no-commit` stages the merge, the regression gate
# runs on the merged tree, and only a green gate is committed; any conflict or red
# gate is aborted (`git merge --abort`) and recorded for a human. Per-task isolation
# means one bad task never blocks the others or leaves the target mid-merge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

task_filter=""
dry_run="no"
from_reconcile="no"
run_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task_filter="$2"; shift 2 ;;
    --dry-run) dry_run="yes"; shift ;;
    --from-reconcile) from_reconcile="yes"; shift ;;
    --run-id) run_id="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

gluerun_ensure_state_dirs
gluerun_require_target_branch

# ---- Pre-flight policy guards (fail fast, before any lock) ----
current_branch="$(gluerun_current_branch)"
if [[ -z "$current_branch" ]]; then
  echo "refuse: detached HEAD; integration must run on the target branch" >&2
  exit 2
fi
if [[ "$current_branch" != "$GLUERUN_TARGET_BRANCH" ]]; then
  echo "refuse: on '$current_branch', not target '$GLUERUN_TARGET_BRANCH'; checkout the target first" >&2
  exit 2
fi
if [[ "$GLUERUN_TARGET_BRANCH" == "main" ]]; then
  echo "refuse: target is 'main' (release-only); integration into main is human-gated" >&2
  exit 2
fi
# Refuse only on NON-control-state dirt. Control-state churn under
# docs/orchestration/ (generated tasks, imported packets, decisions, snapshots)
# is expected mid-cycle and never participates in the code merge; reconcile
# commits it separately at the end of the cycle.
if [[ "$dry_run" != "yes" ]]; then
  code_dirt=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == '??'* ]] && continue   # untracked files never enter the merge
    p="${line:3}"; p="${p##* -> }"
    case "$p" in docs/orchestration/*) ;; *) code_dirt=1; break ;; esac
  done < <(git -C "$GLUERUN_ROOT" status --porcelain)
  if [[ "$code_dirt" -eq 1 ]]; then
    echo "refuse: working tree has non-control-state changes; commit or stash before integrating" >&2
    exit 2
  fi
fi

[[ -n "$run_id" ]] || run_id="$(gluerun_run_id)"

# ---- Lock (shared with reconcile when invoked via --from-reconcile) ----
if [[ "$from_reconcile" != "yes" ]]; then
  gluerun_acquire_lock "$run_id"
  trap 'gluerun_release_lock "$run_id"' EXIT
fi

gate_cmd="${GLUERUN_DEFAULT_GATE_CMD}"
integrated_this_run=0
failed_integrations=0
skipped=0
eligible=0

# ---- Eligibility discovery ----
declare -a dirs=()
if [[ -n "$task_filter" ]]; then
  dirs=("$GLUERUN_ORCH_DIR/packets/imported/$task_filter")
else
  mapfile -t dirs < <(find "$GLUERUN_ORCH_DIR/packets/imported" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

# headSha prefix-tolerant comparison (matches import-packet.sh semantics).
sha_matches() {
  local want="$1" actual="$2"
  [[ "$actual" == "${want:0:${#actual}}" || "$want" == "$actual" ]]
}

push_enabled="${GLUERUN_PUSH:-0}"

gluerun_log_slug() {
  local s="${1//\//__}"
  printf '%s' "$s" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

# Ask the decider for an action at an integration failure point. Echoes action.
integration_decide() {
  local fc="$1" task="$2" branch="$3" ctx="$4"
  local out
  out="$("$SCRIPT_DIR/decide.sh" --task "$task" --failure-class "$fc" --branch "$branch" \
    --run "$run_id" --context-file "${ctx:-/dev/null}" --worktree "$GLUERUN_ROOT" 2>/dev/null || true)"
  printf '%s\n' "$out" | sed -n 's/^action=//p' | tail -1
}

# Push a branch to origin (no force). Secret-scans the outgoing range first; on a
# non-fast-forward, fetches and retries once, else records and skips (no block).
push_branch() {
  local b="$1"
  [[ "$push_enabled" == "1" ]] || return 0
  git -C "$GLUERUN_ROOT" remote get-url origin >/dev/null 2>&1 || { echo "push: no origin remote; skipping"; return 0; }
  local range="$b"
  if git -C "$GLUERUN_ROOT" rev-parse --verify --quiet "origin/$b" >/dev/null; then range="origin/$b..$b"; fi
  local scan_log="$run_dir/secret-scan-push-$(gluerun_log_slug "$b").log"
  if ! "$SCRIPT_DIR/secret-scan.sh" --worktree "$GLUERUN_ROOT" --range "$range" >"$scan_log" 2>&1; then
    gluerun_append_event "push.blocked" "secret-scan blocked push" "{\"runId\":\"$run_id\",\"branch\":\"$b\"}"
    echo "push BLOCKED for $b (secret-scan)"; return 0
  fi
  if git -C "$GLUERUN_ROOT" push origin "$b" >/dev/null 2>&1; then
    gluerun_append_event "push.ok" "pushed to origin" "{\"runId\":\"$run_id\",\"branch\":\"$b\"}"
    echo "pushed $b -> origin"; return 0
  fi
  git -C "$GLUERUN_ROOT" fetch origin >/dev/null 2>&1 || true
  if git -C "$GLUERUN_ROOT" push origin "$b" >/dev/null 2>&1; then
    gluerun_append_event "push.ok" "pushed to origin (after fetch)" "{\"runId\":\"$run_id\",\"branch\":\"$b\"}"
    echo "pushed $b -> origin (after fetch)"; return 0
  fi
  gluerun_append_event "push.failed" "push failed (non-ff or remote error)" "{\"runId\":\"$run_id\",\"branch\":\"$b\"}"
  echo "push FAILED for $b (parked)"; return 0
}

# run_dir for this integration run's logs.
run_dir="$(gluerun_run_dir "$run_id")"; mkdir -p "$run_dir"

for d in "${dirs[@]}"; do
  [[ -d "$d" ]] || continue
  task_id="$(basename "$d")"
  # Early-skip terminal leases: never re-process already-integrated work.
  # The hundreds of integrated tasks were re-scanned every cycle (find over
  # all imported packets) and paid python+git merge-base cost before the
  # idempotency guard below; this short-circuits them with one cheap lease
  # read. Guarded by -z task_filter so an explicit --task re-integration still
  # runs; the merge-base guard below remains the correctness safety net.
  if [[ -z "$task_filter" ]]; then
    case "$(gluerun_lease_status "$task_id" 2>/dev/null || true)" in
      integrated|blocked|cancelled|superseded|stale) skipped=$((skipped + 1)); continue ;;
    esac
  fi
  # newest accepted packet for this task (exclude audit sidecars)
  packet="$(find "$d" -maxdepth 1 -name '*.json' -not -name '*.audit.json' -type f 2>/dev/null | sort | tail -1)"
  [[ -n "$packet" ]] || continue

  status="$(gluerun_json_field "$packet" status 2>/dev/null || echo "")"
  [[ "$status" == "accepted" ]] || { continue; }

  branch="$(gluerun_json_field "$packet" branch 2>/dev/null || echo "")"
  head_sha="$(gluerun_json_field "$packet" headSha 2>/dev/null || echo "")"
  run_packet="$(basename "$packet" .json)"
  sidecar="${packet%.json}.audit.json"

  # Audit sidecar must say accepted, unless a decider accept-waiver is recorded
  # in the packet evidence and durable decision trail.
  acceptance_mode="$(gluerun_packet_acceptance_mode "$packet" "$sidecar" 2>/dev/null || true)"
  if [[ -z "$acceptance_mode" ]]; then
    echo "skip $task_id: no accepted auditor verdict or recorded accept-waiver"
    skipped=$((skipped + 1))
    continue
  fi

  # Branch must exist.
  if ! git -C "$GLUERUN_ROOT" rev-parse --verify --quiet "$branch^{commit}" >/dev/null; then
    echo "skip $task_id: branch missing ($branch)"
    if [[ "$dry_run" != "yes" ]]; then
      gluerun_record_recovery "integration branch missing for accepted packet" \
        "$task_id" "$branch" "escalate-parked" "origin" "restore branch or supersede accepted packet" "human"
      "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "decide:escalate-parked" \
        --rationale "integration branch missing: $branch; restore the branch or supersede the imported packet" \
        --run "$run_id" --branch "$branch" --authority origin >/dev/null 2>&1 || true
      gluerun_lease_set_status "$task_id" "blocked" 2>/dev/null || true
      task_file="$GLUERUN_TASKS_DIR/$task_id.md"
      [[ -f "$task_file" ]] && gluerun_task_set_status "$task_file" "blocked" || true
      gluerun_append_event "integration.parked" "accepted packet has no integration branch" \
        "$(python3 - "$run_id" "$task_id" "$branch" <<'PY'
import json, sys
run_id, task_id, branch = sys.argv[1:4]
print(json.dumps({"runId": run_id, "taskId": task_id, "branch": branch, "reason": "branch-missing", "action": "escalate-parked"}, separators=(",", ":")))
PY
)"
    fi
    skipped=$((skipped + 1))
    continue
  fi

  actual_head="$(git -C "$GLUERUN_ROOT" rev-parse "$branch")"
  if ! sha_matches "$head_sha" "$actual_head"; then
    echo "skip $task_id: branch head $actual_head != packet headSha $head_sha"
    gluerun_record_recovery "branch advanced past audited headSha for $task_id" \
      "$task_id" "$branch" "request-human-decision" "origin" "re-audit at current head" "human"
    skipped=$((skipped + 1))
    continue
  fi

  # Idempotency guard: skip if already merged into the target.
  if git -C "$GLUERUN_ROOT" merge-base --is-ancestor "$head_sha" "$GLUERUN_TARGET_BRANCH" 2>/dev/null; then
    echo "skip $task_id: already merged into $GLUERUN_TARGET_BRANCH"
    gluerun_append_event "integration.skipped" "branch already integrated" \
      "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"already-merged\"}"
    skipped=$((skipped + 1))
    continue
  fi

  eligible=$((eligible + 1))

  if [[ "$dry_run" == "yes" ]]; then
    echo "eligible: $task_id -> merge $branch ($actual_head) into $GLUERUN_TARGET_BRANCH"
    continue
  fi

  # ---- Verify-before-finalize merge ----
  gluerun_append_event "integration.started" "integration started" \
    "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"branch\":\"$branch\",\"headSha\":\"$actual_head\",\"target\":\"$GLUERUN_TARGET_BRANCH\"}"

  # The merge/abort pair mutates the main worktree index and shared refs, so it
  # runs under the repo-wide git lock that workers use for their git ops. The
  # gate run below stays OUTSIDE the lock: it can take minutes and holding the
  # lock through it would starve worker commits (lock wait caps at 60s).
  merge_ec=0
  if gluerun_git_lock_acquire; then
    git -C "$GLUERUN_ROOT" merge --no-ff --no-commit "$actual_head" >/dev/null 2>&1 || merge_ec=$?
    if [[ "$merge_ec" -ne 0 ]]; then
      git -C "$GLUERUN_ROOT" diff --name-only --diff-filter=U >"$run_dir/conflict-$task_id.log" 2>/dev/null || true
      git -C "$GLUERUN_ROOT" merge --abort 2>/dev/null || true
    fi
    gluerun_git_lock_release
  else
    gluerun_append_event "integration.failed" "git lock unavailable" \
      "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"git-lock-timeout\"}"
    echo "FAILED $task_id: git lock unavailable; retrying next cycle"
    failed_integrations=$((failed_integrations + 1)); continue
  fi
  if [[ "$merge_ec" -ne 0 ]]; then
    action="$(integration_decide "integration-conflict" "$task_id" "$branch" "$run_dir/conflict-$task_id.log")"
    echo "  decider (conflict): ${action:-escalate-parked}"
    git -C "$GLUERUN_ROOT" rebase --abort 2>/dev/null || true
    git -C "$GLUERUN_ROOT" checkout -q "$GLUERUN_TARGET_BRANCH" 2>/dev/null || true
    gluerun_record_recovery "merge conflict integrating $task_id into $GLUERUN_TARGET_BRANCH" \
      "$task_id" "$branch" "${action:-escalate-parked}" "decider" "fresh conflict resolution with re-audit if branch changes" "origin"
    gluerun_append_event "integration.failed" "integration merge conflict" \
      "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"conflict\",\"action\":\"${action:-escalate-parked}\",\"note\":\"audited branch not rebased in v1\"}"
    echo "FAILED $task_id: merge conflict (decider: ${action:-escalate-parked}; audited branch not rebased)"
    failed_integrations=$((failed_integrations + 1)); continue
  fi

  # Gate-verify the staged merged tree.
  gate_ec=0
  ( cd "$GLUERUN_ROOT" && GLUERUN_ROOT="$GLUERUN_ROOT" GLUERUN_STATE_DIR="$GLUERUN_STATE_DIR" \
      "$SCRIPT_DIR/gate-check.sh" "$run_id-integrate-$task_id" -- bash -c "$gate_cmd" ) >/dev/null 2>&1 || gate_ec=$?
  if [[ "$gate_ec" -ne 0 ]]; then
    gluerun_with_git_lock git -C "$GLUERUN_ROOT" merge --abort 2>/dev/null || true
    action="$(integration_decide "integration-gate-red" "$task_id" "$branch" "$GLUERUN_RUNS_DIR/$run_id-integrate-$task_id/gate-check.log")"
    gluerun_record_recovery "post-merge regression gate red (exit $gate_ec) for $task_id" \
      "$task_id" "$branch" "${action:-escalate-parked}" "decider" "green regression on merged tree" "human"
    gluerun_append_event "integration.failed" "integration gate red" \
      "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"gate-red\",\"exitCode\":$gate_ec,\"action\":\"${action:-escalate-parked}\"}"
    echo "FAILED $task_id: post-merge gate red (decider: ${action:-escalate-parked})"
    failed_integrations=$((failed_integrations + 1))
    continue
  fi

  # Secret-scan the staged merged tree before finalizing.
  if ! "$SCRIPT_DIR/secret-scan.sh" --worktree "$GLUERUN_ROOT" --staged >"$run_dir/secret-scan-merge-$task_id.log" 2>&1; then
    gluerun_with_git_lock git -C "$GLUERUN_ROOT" merge --abort 2>/dev/null || true
    gluerun_append_event "integration.failed" "secret-scan blocked merge" \
      "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"reason\":\"secret-detected\"}"
    echo "FAILED $task_id: secret-scan blocked merge (parked)"
    failed_integrations=$((failed_integrations + 1))
    continue
  fi

  # Green: finalize the merge commit.
  gluerun_with_git_lock git -C "$GLUERUN_ROOT" -c user.name="$GLUERUN_GIT_L0_NAME" -c user.email="$GLUERUN_GIT_L0_EMAIL" \
    commit --no-edit -q \
    -m "integrate($task_id): merge $branch into $GLUERUN_TARGET_BRANCH" \
    -m "Worker head: $actual_head" \
    -m "Packet: docs/orchestration/packets/imported/$task_id/$run_packet.json" \
    -m "Acceptance: $acceptance_mode. Regression gate: green (run $run_id)."
  merge_commit="$(git -C "$GLUERUN_ROOT" rev-parse HEAD)"
  echo "INTEGRATED $task_id: $branch ($actual_head) -> $GLUERUN_TARGET_BRANCH @ $merge_commit"

  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "integrate" \
    --rationale "merged $branch ($actual_head) into $GLUERUN_TARGET_BRANCH as $merge_commit; gate green; acceptance=$acceptance_mode" \
    --run "$run_id" --branch "$branch" --authority origin || true
  gluerun_append_event "integration.integrated" "branch integrated" \
    "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"branch\":\"$branch\",\"headSha\":\"$actual_head\",\"mergeCommit\":\"$merge_commit\",\"target\":\"$GLUERUN_TARGET_BRANCH\"}"
  gluerun_lease_set_status "$task_id" "integrated" 2>/dev/null || true
  task_file="$GLUERUN_TASKS_DIR/$task_id.md"
  [[ -f "$task_file" ]] && gluerun_task_set_status "$task_file" "integrated" || true
  integrated_this_run=$((integrated_this_run + 1))

  # Push the updated target and the worker branch to origin (no-op unless GLUERUN_PUSH=1).
  push_branch "$GLUERUN_TARGET_BRANCH"
  push_branch "$branch"
done

if [[ "$dry_run" == "yes" ]]; then
  echo "eligible=$eligible (dry-run; no merges performed)"
  echo "skipped=$skipped"
  exit 0
fi

gluerun_write_origin_state "$run_id" 2>/dev/null || true
echo "integrated_this_run=$integrated_this_run"
echo "failed_integrations=$failed_integrations"
echo "skipped=$skipped"
gluerun_append_event "integration.completed" "integration run completed" \
  "{\"runId\":\"$run_id\",\"eligible\":$eligible,\"integratedThisRun\":$integrated_this_run,\"failedIntegrations\":$failed_integrations,\"skipped\":$skipped}"

[[ "$failed_integrations" -eq 0 ]]
