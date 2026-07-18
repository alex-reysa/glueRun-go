#!/usr/bin/env bash
set -euo pipefail

# Require bash >= 4 (mapfile). macOS /bin/bash is 3.2; re-exec under Homebrew bash
# if launched with an old interpreter (e.g. via the launchd /bin/bash wrapper).
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "reconcile.sh requires bash >= 4 (mapfile); install via 'brew install bash'" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

mode="dry-run"
case "${1:-}" in
  --dry-run|"")
    mode="dry-run"
    ;;
  --apply)
    mode="apply"
    ;;
  --actuate)
    mode="actuate"
    ;;
  --status)
    mode="status"
    ;;
  --drain)
    mode="drain"
    ;;
  *)
    echo "usage: $0 [--dry-run|--apply|--actuate|--status|--drain]" >&2
    exit 2
    ;;
esac

# apply and actuate both import packets; only actuate dispatches workers.
do_import="no"
[[ "$mode" == "apply" || "$mode" == "actuate" ]] && do_import="yes"

gluerun_ensure_state_dirs
gluerun_ensure_repo_scaffold

if [[ "$mode" == "status" ]]; then
  echo "gluerun orchestration status"
  echo "repo: $GLUERUN_ROOT"
  echo "current_branch: $(gluerun_current_branch)"
  echo "target_branch: ${GLUERUN_TARGET_BRANCH:-<unset>}"
  if [[ -f "$GLUERUN_LOCK_FILE" ]]; then
    echo "lock: present ($GLUERUN_LOCK_FILE)"
  else
    echo "lock: none"
  fi
  # Console lifecycle (cheap: pid liveness only, no HTTP round trip).
  if [[ -f "$GLUERUN_STATE_DIR/console.url" ]]; then
    console_url="$(head -1 "$GLUERUN_STATE_DIR/console.url" 2>/dev/null || true)"
    console_pid="$(tr -d '[:space:]' < "$GLUERUN_STATE_DIR/console.pid" 2>/dev/null || true)"
    if [[ -n "$console_pid" ]] && kill -0 "$console_pid" 2>/dev/null; then
      echo "console: $console_url"
    else
      echo "console: stale (not running)"
    fi
  fi
  inbox_count="$(gluerun_count_files "$GLUERUN_STATE_DIR/inbox" -maxdepth 1 -name '*.json')"
  imported_count="$(gluerun_count_files "$GLUERUN_ORCH_DIR/packets/imported" -name '*.json' -not -name '*.audit.json')"
  echo "packets_inbox: $inbox_count"
  echo "packets_imported: $imported_count"
  echo "recent_events:"
  if [[ -f "$GLUERUN_EVENTS_FILE" ]]; then
    tail -5 "$GLUERUN_EVENTS_FILE"
  else
    echo "  <none>"
  fi
  exit 0
fi

# Drain: block until no launched dispatch records remain (detached-mode tests
# and clean shutdown). Each poll reaps under the origin lock so finished or
# crashed workers are finalized exactly once even if a reconcile cycle runs
# concurrently.
if [[ "$mode" == "drain" ]]; then
  drain_interval="${GLUERUN_DRAIN_POLL_SECS:-2}"
  drain_deadline=0
  if [[ "${GLUERUN_DRAIN_TIMEOUT_SECS:-0}" =~ ^[0-9]+$ && "${GLUERUN_DRAIN_TIMEOUT_SECS:-0}" -gt 0 ]]; then
    drain_deadline=$(( $(date +%s) + GLUERUN_DRAIN_TIMEOUT_SECS ))
  fi
  while true; do
    drain_run_id="$(gluerun_run_id)"
    if gluerun_acquire_lock "$drain_run_id"; then
      drain_out="$(gluerun_reap_dispatches "$drain_run_id")" || true
      gluerun_release_lock "$drain_run_id"
      drain_running="$(printf '%s\n' "$drain_out" | sed -n 's/^workers_running=//p' | tail -1)"
      [[ "$drain_running" =~ ^[0-9]+$ ]] || drain_running=0
      if [[ "$drain_running" -eq 0 ]]; then
        printf '%s\n' "$drain_out"
        echo "drain: no launched dispatch records remain"
        exit 0
      fi
      echo "drain: $drain_running worker(s) still running"
    else
      echo "drain: origin lock busy"
    fi
    if [[ "$drain_deadline" -gt 0 && "$(date +%s)" -ge "$drain_deadline" ]]; then
      echo "drain: timed out after ${GLUERUN_DRAIN_TIMEOUT_SECS}s" >&2
      exit 1
    fi
    sleep "$drain_interval"
  done
fi

gluerun_require_target_branch

run_id="$(gluerun_run_id)"
gluerun_acquire_lock "$run_id"
trap 'gluerun_release_lock "$run_id"' EXIT
run_dir="$GLUERUN_STATE_DIR/runs/$run_id"
mkdir -p "$run_dir"

current_branch="$(gluerun_current_branch)"
head_sha="$(git -C "$GLUERUN_ROOT" rev-parse --short HEAD)"
dirty_count="$(git -C "$GLUERUN_ROOT" status --short | wc -l | tr -d ' ')"
worktree_count="$(git -C "$GLUERUN_ROOT" worktree list --porcelain | awk '/^worktree / {count++} END {print count+0}')"
inbox_count="$(gluerun_count_files "$GLUERUN_STATE_DIR/inbox" -maxdepth 1 -name '*.json')"
imported_count="$(gluerun_count_files "$GLUERUN_ORCH_DIR/packets/imported" -name '*.json')"
valid_inbox_count=0
invalid_inbox_count=0
imported_this_run=0
failed_imports=0
dispatched_this_run=0
failed_dispatches=0
refused_dispatches=0
integrations_this_run=0
integration_failures=0
planner_failures_this_run=0
l1_import_rejections_this_run=0
reaped_ok=0
reaped_failures=0
workers_running=0

mapfile -t inbox_packets < <(find "$GLUERUN_STATE_DIR/inbox" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)

for packet in "${inbox_packets[@]}"; do
  if gluerun_validate_packet_basic "$packet" >/dev/null 2>&1; then
    task_id_for_packet="$(gluerun_json_field "$packet" taskId 2>/dev/null || true)"
    run_id_for_packet="$(gluerun_json_field "$packet" runId 2>/dev/null || true)"
    workspace_for_packet="$(gluerun_json_field "$packet" workspace 2>/dev/null || true)"
    task_file_for_packet="$GLUERUN_TASKS_DIR/$task_id_for_packet.md"
    run_dir_for_packet="$GLUERUN_RUNS_DIR/$run_id_for_packet"
    if [[ -n "$task_id_for_packet" && -f "$task_file_for_packet" ]] \
      && gluerun_packet_module_guard "$packet" "$task_file_for_packet" "$workspace_for_packet" "$run_dir_for_packet" >/dev/null 2>&1; then
      valid_inbox_count=$((valid_inbox_count + 1))
    else
      invalid_inbox_count=$((invalid_inbox_count + 1))
    fi
  else
    invalid_inbox_count=$((invalid_inbox_count + 1))
  fi
done

if [[ "$do_import" == "yes" && ${#inbox_packets[@]} -gt 0 ]]; then
  import_log="$GLUERUN_STATE_DIR/runs/$run_id/import.log"
  mkdir -p "$(dirname "$import_log")"
  for packet in "${inbox_packets[@]}"; do
    # Per-packet isolation: one bad packet must not abort the whole run.
    if "$SCRIPT_DIR/import-packet.sh" "$packet" >>"$import_log" 2>&1; then
      imported_this_run=$((imported_this_run + 1))
      rm -f "$packet"   # imported packets leave the inbox queue
    else
      failed_imports=$((failed_imports + 1))
      echo "import failed: $(basename "$packet") (see $import_log)" >&2
      gluerun_append_event "packet.import_failed" "packet import failed" \
        "{\"runId\":\"$run_id\",\"packet\":\"$(basename "$packet")\"}"
    fi
  done
  imported_count="$(gluerun_count_files "$GLUERUN_ORCH_DIR/packets/imported" -name '*.json' -not -name '*.audit.json')"
fi

gluerun_append_event "origin.reconcile_started" "origin reconcile started" "{\"runId\":\"$run_id\",\"mode\":\"$mode\"}"

# Reap dispatch records BEFORE the recovery pass: finished workers' exit files
# are attributed (and a crashed worker's lease is already terminal) by the time
# the stale-lease scan runs. With detached dispatch off this is shadow
# accounting only -- the in-cycle wait loop below stays authoritative.
if [[ "$do_import" == "yes" ]]; then
  reap_out="$(gluerun_reap_dispatches "$run_id")" || true
  reaped_ok="$(printf '%s\n' "$reap_out" | sed -n 's/^reaped_ok=//p' | tail -1)"
  reaped_failures="$(printf '%s\n' "$reap_out" | sed -n 's/^reaped_failures=//p' | tail -1)"
  reaped_refused="$(printf '%s\n' "$reap_out" | sed -n 's/^reaped_refused=//p' | tail -1)"
  reaped_terminal="$(printf '%s\n' "$reap_out" | sed -n 's/^reaped_terminal=//p' | tail -1)"
  workers_running="$(printf '%s\n' "$reap_out" | sed -n 's/^workers_running=//p' | tail -1)"
  [[ "$reaped_ok" =~ ^[0-9]+$ ]] || reaped_ok=0
  [[ "$reaped_failures" =~ ^[0-9]+$ ]] || reaped_failures=0
  [[ "$reaped_refused" =~ ^[0-9]+$ ]] || reaped_refused=0
  [[ "$reaped_terminal" =~ ^[0-9]+$ ]] || reaped_terminal=0
  [[ "$workers_running" =~ ^[0-9]+$ ]] || workers_running=0
  # Decided-terminal reaps count as failures for progress accounting; refusals
  # never do (exit-code contract, see gluerun_reap_dispatches).
  reaped_failures=$((reaped_failures + reaped_terminal))
  if [[ $((reaped_ok + reaped_failures + reaped_refused + workers_running)) -gt 0 ]]; then
    echo "reap: ok=$reaped_ok failed=$reaped_failures refused=$reaped_refused running=$workers_running"
  fi
fi

# Recovery pass (non-destructive): reclassify stale leases, report orphans.
if [[ "$do_import" == "yes" ]]; then
  "$SCRIPT_DIR/recover.sh" --scan || true
fi

# Actuation: select ready tasks and dispatch L1, respecting the concurrency cap
# and a per-run dispatch budget. Disabled outside --actuate by design.
if [[ "$mode" == "actuate" ]] && gluerun_stop_requested; then
  echo "actuation: STOP sentinel present ($GLUERUN_STOP_FILE); skipping dispatch"
  gluerun_append_event "origin.stop_observed" "STOP sentinel present" "{\"runId\":\"$run_id\"}"
  mode="apply"   # still import/recover/snapshot, but do not dispatch
fi

if [[ "$mode" == "actuate" ]] && [[ "$(gluerun_breaker_count)" -ge "$GLUERUN_MAX_CONSEC_FAILS" ]]; then
  echo "actuation: circuit breaker tripped ($(gluerun_breaker_count)/$GLUERUN_MAX_CONSEC_FAILS); skipping dispatch"
  gluerun_append_event "origin.breaker_open" "circuit breaker open" "{\"runId\":\"$run_id\",\"consecFails\":$(gluerun_breaker_count)}"
  mode="apply"
fi

if [[ "$mode" == "actuate" ]]; then
  # Integrate accepted work FIRST so a newly dispatched task branches from a
  # target that already includes prior accepted slices (avoids a stale-base
  # build break). Packets dispatched this cycle integrate on the next cycle.
  if [[ "${GLUERUN_AUTO_INTEGRATE:-1}" == "1" ]]; then
    echo "actuation: auto-integration (pre-dispatch)"
    integ_out="$("$SCRIPT_DIR/integrate.sh" --from-reconcile --run-id "$run_id" 2>&1)" || true
    printf '%s\n' "$integ_out" | sed 's/^/  integ: /'
    integrations_this_run="$(printf '%s\n' "$integ_out" | sed -n 's/^integrated_this_run=//p' | tail -1)"
    integration_failures="$(printf '%s\n' "$integ_out" | sed -n 's/^failed_integrations=//p' | tail -1)"
    [[ "$integrations_this_run" =~ ^[0-9]+$ ]] || integrations_this_run=0
    [[ "$integration_failures" =~ ^[0-9]+$ ]] || integration_failures=0
  fi

  max_concurrent="${GLUERUN_MAX_CONCURRENT:-1}"
  max_dispatch="${GLUERUN_MAX_DISPATCH:-$max_concurrent}"
  active_leases="$(gluerun_active_lease_count)"
  available_slots=$((max_concurrent - active_leases))
  [[ "$available_slots" -lt 0 ]] && available_slots=0
  dispatch_budget="$max_dispatch"
  [[ "$dispatch_budget" -gt "$available_slots" ]] && dispatch_budget="$available_slots"
  # This list is used only for queue-size/empty checks. Duplicate suppression is
  # authoritative in gluerun_select_dispatch_frontier below, whose single-pass
  # parser also enforces dependencies, leases, and scope conflicts. Re-running
  # the legacy signature scan once per ready task makes large campaigns spend
  # minutes here before every dispatch cycle.
  mapfile -t ready_tasks < <(GLUERUN_SKIP_DUPLICATE_READY_TASKS=0 gluerun_list_ready_tasks)
  base_sha="$(git -C "$GLUERUN_ROOT" rev-parse "$GLUERUN_TARGET_BRANCH")"
  batch_id="$run_id-batch"

  # Keep the queue full: if nothing is ready, first promote completed gate
  # candidates when enabled, then plan the next dispatch frontier. Promotion is
  # L0 completion-authority work, not planner generation, so GLUERUN_GENERATE=0
  # does not suppress it.
  # 0.5.0: default ON, and promotion no longer requires a free dispatch slot —
  # it is completion-authority work, not dispatch (0.4.0's extra condition
  # meant auto-promotion effectively never fired in the field).
  if [[ ${#ready_tasks[@]} -eq 0 && "${GLUERUN_AUTO_PROMOTE_GATES:-1}" == "1" ]]; then
    echo "actuation: ready queue empty; attempting gate promotion..."
    promo_out="$("${GLUERUN_PROMOTER:-$SCRIPT_DIR/promote-gate.sh}" --from-reconcile --frontier 2>&1)" || true
    printf '%s\n' "$promo_out" | sed 's/^/  promotion: /'
    mapfile -t ready_tasks < <(GLUERUN_SKIP_DUPLICATE_READY_TASKS=0 gluerun_list_ready_tasks)
  fi

  # With L1 parallelism enabled, plan several independent DAG nodes concurrently
  # and import their staged proposals serially (L0 stays the only importer);
  # otherwise fall back to the single-node generator (unchanged).
  if [[ ${#ready_tasks[@]} -eq 0 && "$dispatch_budget" -gt 0 && "${GLUERUN_GENERATE:-1}" == "1" ]]; then
    if [[ "${GLUERUN_ENABLE_L1_PARALLEL:-0}" == "1" ]]; then
      echo "actuation: ready queue empty; L1 parallel fanout (cap ${GLUERUN_MAX_L1_CONCURRENT:-3})..."
      # Plan-critique knob (default-OFF): when ON, route the L1 import fanout
      # through the integrated critique-aware orchestrator so L0 import honors the
      # plan critic verdict; it mirrors gluerun_l1_fanout's args and summary lines
      # (l1_planner_failures= / l1_import_rejections=), so the parsing below is
      # unchanged. When OFF (0/unset) this is byte-identical to prior behavior.
      if [[ "${GLUERUN_PLAN_CRITIQUE:-0}" == "1" ]]; then
        l1_out="$(gluerun_ctx_critique_import_fanout "$run_id" "$base_sha" 2>&1)" || true
      else
        l1_out="$(gluerun_l1_fanout "$run_id" "$base_sha" 2>&1)" || true
      fi
      printf '%s\n' "$l1_out" | sed 's/^/  l1: /'
      planner_failures_this_run="$(printf '%s\n' "$l1_out" | sed -n 's/^l1_planner_failures=//p' | tail -1)"
      l1_import_rejections_this_run="$(printf '%s\n' "$l1_out" | sed -n 's/^l1_import_rejections=//p' | tail -1)"
    else
      echo "actuation: ready queue empty; invoking task generator for up to $dispatch_budget task(s)..."
      gen_out="$("$SCRIPT_DIR/generate-tasks.sh" --count "$dispatch_budget" 2>&1)" || true
      printf '%s\n' "$gen_out" | sed 's/^/  gen: /'
      if printf '%s\n' "$gen_out" | grep -q 'planner-failed\|planner-backoff\|planner-blocked'; then
        planner_failures_this_run=1
      fi
    fi
    [[ "$planner_failures_this_run" =~ ^[0-9]+$ ]] || planner_failures_this_run=0
    [[ "$l1_import_rejections_this_run" =~ ^[0-9]+$ ]] || l1_import_rejections_this_run=0
    mapfile -t ready_tasks < <(GLUERUN_SKIP_DUPLICATE_READY_TASKS=0 gluerun_list_ready_tasks)
  fi

  mapfile -t dispatch_tasks < <(gluerun_select_dispatch_frontier "$dispatch_budget")
  echo "actuation: ready=${#ready_tasks[@]} frontier=${#dispatch_tasks[@]} active_leases=$active_leases cap=$max_concurrent max_dispatch=$max_dispatch available=$available_slots"
  if [[ "$available_slots" -eq 0 && ${#ready_tasks[@]} -gt 0 ]]; then
    echo "actuation: max-concurrent cap reached ($max_concurrent); deferring ready tasks"
    gluerun_append_event "origin.actuation_deferred" "max concurrent reached" "{\"runId\":\"$run_id\",\"cap\":$max_concurrent}"
  fi

  l1_driver="${GLUERUN_L1_DRIVER:-$SCRIPT_DIR/l1-drive.sh}"
  declare -a dispatch_pids=()
  declare -a dispatch_tids=()
  declare -a dispatch_logs=()
  declare -a dispatch_starts=()
  for task_file in "${dispatch_tasks[@]}"; do
    tid="$(gluerun_task_field "$task_file" taskId 2>/dev/null || true)"
    [[ -n "$tid" ]] || continue
    dispatch_log="$run_dir/dispatch-$tid.log"
    echo "actuation: dispatching $tid (batch=$batch_id base=$base_sha detached=${GLUERUN_DETACHED_DISPATCH:-0})"
    gluerun_append_event "origin.dispatch" "origin dispatching task" \
      "{\"runId\":\"$run_id\",\"taskId\":\"$tid\",\"batchId\":\"$batch_id\",\"baseSha\":\"$base_sha\",\"detached\":${GLUERUN_DETACHED_DISPATCH:-0}}"
    if [[ "${GLUERUN_DETACHED_DISPATCH:-0}" == "1" ]]; then
      # Pre-lease: hold the slot and publish the scope BEFORE the driver runs.
      # The driver creates its lease only after preflight, so without this a
      # later cycle's frontier could double-select the task (or a scope-
      # overlapping one) in the window before the driver's lease write. The
      # driver's own gluerun_lease_write overwrites this record (preserving
      # createdAt/batchId); dispatch-wrap.sh clears it if the driver exits
      # without ever taking ownership.
      pre_branch="$(gluerun_task_field "$task_file" workerBranch 2>/dev/null || true)"
      pre_area="$(gluerun_task_field "$task_file" area 2>/dev/null || true)"
      pre_owned_json="$(gluerun_task_field "$task_file" ownedFiles 2>/dev/null || echo '[]')"
      pre_scope="$(python3 -c 'import json,sys; print(" ".join(json.loads(sys.argv[1])))' "$pre_owned_json" 2>/dev/null || true)"
      gluerun_lease_write "$tid" "$pre_branch" "$pre_area" "l2-developer" "$pre_scope" \
        "planned" "$run_id" "" "$base_sha" "$batch_id" "$pre_owned_json" "" || true
    fi
    (
      export GLUERUN_DISPATCH_BATCH_ID="$batch_id"
      export GLUERUN_DISPATCH_BASE_SHA="$base_sha"
      if [[ "${GLUERUN_DETACHED_DISPATCH:-0}" == "1" ]]; then
        # New session so the worker survives signals aimed at reconcile's or
        # autonomate's process group (launchd teardown, ^C on a manual run).
        exec python3 -c 'import os, sys
try:
    os.setsid()
except OSError:
    pass
os.execvp(sys.argv[1], sys.argv[1:])' "$SCRIPT_DIR/dispatch-wrap.sh" "$tid" "$l1_driver"
      else
        exec "$SCRIPT_DIR/dispatch-wrap.sh" "$tid" "$l1_driver"
      fi
    ) >"$dispatch_log" 2>&1 &
    dispatch_pid="$!"
    dispatch_pids+=("$dispatch_pid")
    dispatch_tids+=("$tid")
    dispatch_logs+=("$dispatch_log")
    dispatch_starts+=("$(date +%s)")
    gluerun_dispatch_record_write "$tid" "$run_id" "$dispatch_pid" \
      "$(gluerun_dispatch_pid_start "$dispatch_pid")" "$dispatch_log" "$base_sha" "$batch_id"
  done

  if [[ "${GLUERUN_DETACHED_DISPATCH:-0}" == "1" ]]; then
    # Detached: no wait. The cycle ends in seconds; outcomes are attributed by
    # gluerun_reap_dispatches on later cycles via exit files / pid liveness.
    for i in "${!dispatch_pids[@]}"; do
      dispatched_this_run=$((dispatched_this_run + 1))
      echo "actuation: detached ${dispatch_tids[$i]} pid=${dispatch_pids[$i]} log=${dispatch_logs[$i]}"
    done
  else
    for i in "${!dispatch_pids[@]}"; do
      tid="${dispatch_tids[$i]}"
      pid="${dispatch_pids[$i]}"
      dispatch_log="${dispatch_logs[$i]}"
      drive_ec=0
      if wait "$pid"; then
        drive_ec=0
      else
        drive_ec=$?
      fi
      dispatched_this_run=$((dispatched_this_run + 1))
      echo "actuation: l1-drive $tid exit=$drive_ec log=$dispatch_log"
      gluerun_append_event "origin.worker_reaped" "worker reaped (in-cycle wait)" \
        "{\"runId\":\"$run_id\",\"taskId\":\"$tid\",\"exitCode\":$drive_ec,\"durationSec\":$(( $(date +%s) - dispatch_starts[i] ))}"
      # Exit-code contract: 2 = refusal (preconditions unmet, no state
      # consumed) — never a failure/breaker signal; everything else nonzero
      # (incl. 3 = decided-terminal) counts as a failed dispatch.
      if [[ "$drive_ec" -eq 2 ]]; then
        refused_dispatches=$((refused_dispatches + 1))
        gluerun_append_event "origin.dispatch_refused" "l1 dispatch refused (preconditions)" \
          "{\"runId\":\"$run_id\",\"taskId\":\"$tid\",\"exitCode\":$drive_ec,\"log\":\"$dispatch_log\"}"
      elif [[ "$drive_ec" -ne 0 ]]; then
        failed_dispatches=$((failed_dispatches + 1))
        gluerun_append_event "origin.dispatch_failed" "l1 dispatch failed" \
          "{\"runId\":\"$run_id\",\"taskId\":\"$tid\",\"exitCode\":$drive_ec,\"log\":\"$dispatch_log\"}"
      fi
    done
  fi
fi

snapshot="$(cat <<SNAPSHOT
Updated: $(gluerun_timestamp)
Run: \`$run_id\`
Mode: \`$mode\`
Current branch: \`$current_branch\`
Target branch: \`${GLUERUN_TARGET_BRANCH}\`
Head: \`$head_sha\`
Tracked/untracked status entries: $dirty_count
Git worktrees: $worktree_count
Inbox packets: $inbox_count
Valid inbox packets: $valid_inbox_count
Invalid inbox packets: $invalid_inbox_count
Imported packets: $imported_count
Imported this run: $imported_this_run
Failed imports: $failed_imports
Dispatched this run: $dispatched_this_run
Failed dispatches: $failed_dispatches
Integrated this run: $integrations_this_run
Failed integrations: $integration_failures
Planner failures this run: $planner_failures_this_run
L1 import rejections this run: $l1_import_rejections_this_run

Actions:

- Dry-run validates inbox packet shape and writes this snapshot to \`.gluerun-state/runs/$run_id/reconcile-snapshot.md\`.
- Apply mode imports valid inbox packets into \`docs/orchestration/packets/imported/**\`.
- Keep L1/L2 worker launch disabled during Phase 2/3 dry-run scaffolding.
- Continue toward one manual artifact-area proof loop after scaffolding is accepted.
SNAPSHOT
)"
gluerun_write_run_snapshot "$run_id" "$snapshot"
if [[ "$mode" == "apply" || "$mode" == "actuate" ]]; then
  gluerun_update_project_snapshot "$snapshot"
fi
gluerun_write_origin_state "$run_id"

# Commit (and optionally push) the cycle's control-state output so the tree stays
# clean for the next integrate and progress is durable. Only on the target branch.
if [[ "$do_import" == "yes" && "$(gluerun_current_branch)" == "$GLUERUN_TARGET_BRANCH" ]]; then
  if [[ -n "$(git -C "$GLUERUN_ROOT" status --porcelain -- docs/orchestration)" ]]; then
    # add -> scan -> commit/reset mutates the main worktree index, so it runs
    # under the repo-wide git lock shared with worker git ops; detached workers
    # may be running concurrently with this block.
    if gluerun_git_lock_acquire; then
      git -C "$GLUERUN_ROOT" add -- docs/orchestration
      if "$SCRIPT_DIR/secret-scan.sh" --worktree "$GLUERUN_ROOT" --staged >"$GLUERUN_STATE_DIR/runs/$run_id/secret-scan-ctl.log" 2>&1; then
        git -C "$GLUERUN_ROOT" -c user.name="$GLUERUN_GIT_L0_NAME" -c user.email="$GLUERUN_GIT_L0_EMAIL" \
          commit -q -m "chore(orchestration): control-state update (run $run_id)" || true
        gluerun_git_lock_release
        gluerun_append_event "origin.control_state_committed" "control state committed" "{\"runId\":\"$run_id\"}"
        if [[ "${GLUERUN_PUSH:-0}" == "1" ]] && git -C "$GLUERUN_ROOT" remote get-url origin >/dev/null 2>&1; then
          git -C "$GLUERUN_ROOT" push origin "$GLUERUN_TARGET_BRANCH" >/dev/null 2>&1 \
            && gluerun_append_event "push.ok" "pushed control state" "{\"runId\":\"$run_id\",\"branch\":\"$GLUERUN_TARGET_BRANCH\"}" \
            || { git -C "$GLUERUN_ROOT" fetch origin >/dev/null 2>&1 || true; git -C "$GLUERUN_ROOT" push origin "$GLUERUN_TARGET_BRANCH" >/dev/null 2>&1 \
                 && gluerun_append_event "push.ok" "pushed control state (after fetch)" "{\"runId\":\"$run_id\"}" \
                 || gluerun_append_event "push.failed" "control-state push failed" "{\"runId\":\"$run_id\"}"; }
        fi
      else
        git -C "$GLUERUN_ROOT" reset -q -- docs/orchestration || true
        gluerun_git_lock_release
        gluerun_append_event "origin.control_state_blocked" "secret-scan blocked control-state commit" "{\"runId\":\"$run_id\"}"
      fi
    else
      gluerun_append_event "origin.control_state_blocked" "git lock unavailable for control-state commit" "{\"runId\":\"$run_id\"}"
    fi
  fi
fi

echo "gluerun origin reconcile ($mode)"
echo "run_id=$run_id"
echo "current_branch=$current_branch"
echo "target_branch=$GLUERUN_TARGET_BRANCH"
echo "head=$head_sha"
echo "status_entries=$dirty_count"
echo "worktrees=$worktree_count"
echo "inbox_packets=$inbox_count"
echo "valid_inbox_packets=$valid_inbox_count"
echo "invalid_inbox_packets=$invalid_inbox_count"
echo "imported_packets=$imported_count"
echo "imported_this_run=$imported_this_run"
echo "failed_imports=$failed_imports"
echo "snapshot=.gluerun-state/runs/$run_id/reconcile-snapshot.md"
echo "origin_state=.gluerun-state/origin-state.json"
if [[ "$mode" == "actuate" ]]; then
  echo "worker_launch=enabled"
  echo "dispatched_this_run=$dispatched_this_run"
  echo "failed_dispatches=$failed_dispatches"
  echo "refused_dispatches=$refused_dispatches"
  echo "detached_dispatch=${GLUERUN_DETACHED_DISPATCH:-0}"
  echo "reaped_ok=$reaped_ok"
  echo "reaped_failures=$reaped_failures"
  echo "reaped_refused=${reaped_refused:-0}"
  echo "workers_running=$workers_running"
  echo "auto_integrate=${GLUERUN_AUTO_INTEGRATE:-1}"
  echo "integrated_this_run=$integrations_this_run"
  echo "failed_integrations=$integration_failures"
  echo "planner_failures_this_run=$planner_failures_this_run"
  echo "l1_import_rejections_this_run=$l1_import_rejections_this_run"
else
  echo "worker_launch=disabled"
fi

gluerun_append_event "origin.reconcile_completed" "origin reconcile completed" "{\"runId\":\"$run_id\",\"mode\":\"$mode\",\"inboxPackets\":$inbox_count,\"validInboxPackets\":$valid_inbox_count,\"invalidInboxPackets\":$invalid_inbox_count,\"importedThisRun\":$imported_this_run,\"failedImports\":$failed_imports,\"dispatchedThisRun\":$dispatched_this_run,\"failedDispatches\":$failed_dispatches,\"reapedOk\":$reaped_ok,\"reapedFailures\":$reaped_failures,\"workersRunning\":$workers_running,\"integratedThisRun\":$integrations_this_run,\"failedIntegrations\":$integration_failures,\"plannerFailuresThisRun\":$planner_failures_this_run,\"l1ImportRejectionsThisRun\":$l1_import_rejections_this_run,\"importedPackets\":$imported_count}"
