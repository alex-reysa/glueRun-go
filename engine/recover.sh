#!/usr/bin/env bash
set -euo pipefail

# Minimal recovery wiring (operating model section 13).
#
#   --scan   (default) Reclassify stale "running" leases and report orphaned
#            worktrees. Non-destructive. Records a recovery event per action.
#   --prune  In addition, remove orphaned worktree working directories whose
#            lease is in a terminal state (accepted/failed/stale/cancelled).
#            Branches are preserved (they may hold accepted commits).
#
# A "stale" lease is one in status running/planned/needs-review whose updatedAt
# is older than GLUERUN_STALE_MINUTES (default 60) and for which no packet is
# awaiting import and none has been imported. Such a task is reclassified rather
# than left to strand a worktree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

mode="scan"
case "${1:-}" in
  --scan|"") mode="scan" ;;
  --prune) mode="prune" ;;
  *) echo "usage: $0 [--scan|--prune]" >&2; exit 2 ;;
esac

gluerun_ensure_state_dirs
stale_minutes="${GLUERUN_STALE_MINUTES:-60}"
recovery_decider="${GLUERUN_RECOVERY_DECIDER:-$SCRIPT_DIR/decide.sh}"
actions=0

# 1. Reclassify stale leases.
if [[ -d "$GLUERUN_LEASES_DIR" ]]; then
  while IFS= read -r lease; do
    [[ -n "$lease" ]] || continue
    if ! python3 - "$lease" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        json.load(f)
except Exception:
    raise SystemExit(1)
PY
    then
      superseded_dir="$GLUERUN_LEASES_DIR/superseded"
      mkdir -p "$superseded_dir"
      dest="$superseded_dir/$(basename "$lease")"
      if [[ -e "$dest" ]]; then
        dest="$superseded_dir/$(basename "$lease" .json).$(gluerun_timestamp).json"
      fi
      mv "$lease" "$dest"
      echo "recover: quarantined unreadable lease $(basename "$lease")"
      actions=$((actions + 1))
      continue
    fi
    task_id="$(gluerun_json_field "$lease" taskId 2>/dev/null || true)"
    if [[ -z "$task_id" ]]; then
      task_id="$(basename "$lease" .json)"
    fi
    status="$(gluerun_json_field "$lease" status 2>/dev/null || true)"
    branch="$(gluerun_json_field "$lease" branch 2>/dev/null || true)"
    run_id="$(gluerun_json_field "$lease" runId 2>/dev/null || true)"
    updated="$(gluerun_json_field "$lease" updatedAt 2>/dev/null || true)"
    case "$status" in running|planned|needs-review) ;; *) continue ;; esac

    task_file="$GLUERUN_TASKS_DIR/$task_id.md"
    task_status=""
    if [[ -f "$task_file" ]]; then
      task_status="$(gluerun_task_field "$task_file" status 2>/dev/null || true)"
    fi
    case "$task_status" in
      integrated|accepted|failed|blocked|cancelled|superseded|stale)
        gluerun_lease_set_status "$task_id" "$task_status" || true
        echo "recover: closed stale lease $task_id from task status $task_status"
        actions=$((actions + 1))
        continue
        ;;
    esac

    # Skip if a packet for this run is queued for import or already imported.
    if [[ -n "$run_id" && -f "$GLUERUN_INBOX_DIR/$run_id.json" ]]; then
      continue
    fi
    if [[ -n "$task_id" ]] && find "$GLUERUN_ORCH_DIR/packets/imported/$task_id" -name '*.json' -not -name '*.audit.json' -type f 2>/dev/null | grep -q .; then
      continue
    fi

    # Lease age (minutes) feeds both the wall-clock staleness test and the
    # hard-cap override inside the tree-liveness check.
    lease_age_min="$(python3 - "$updated" <<'PY'
import sys
from datetime import datetime, timezone
updated = sys.argv[1]
try:
    t = datetime.fromisoformat(updated.replace("Z", "+00:00"))
    print(int((datetime.now(timezone.utc) - t).total_seconds() // 60))
except Exception:
    print(999999)
PY
)"

    # Tree-aware fast-stale (0.5.0): a launched dispatch record with no exit
    # file is stale only when the whole process TREE is dead (descendants,
    # pgroup, run-id command lines, recent run-dir writes). The 0.4.0
    # root-pid-only check reclaimed leases under live auditors (field audit:
    # accepted work destroyed, then an infinite re-dispatch loop).
    fast_stale="no"
    tree_alive="unknown"
    drec="$(gluerun_dispatch_record_path "$task_id")"
    if [[ -f "$drec" && ! -f "$(gluerun_dispatch_exit_path "$task_id")" ]] \
      && [[ "$(gluerun_json_field "$drec" state 2>/dev/null || true)" == "launched" ]]; then
      dpid="$(gluerun_json_field "$drec" pid 2>/dev/null || true)"
      dpid_start="$(gluerun_json_field "$drec" pidStart 2>/dev/null || true)"
      dpgid="$(gluerun_json_field "$drec" pgid 2>/dev/null || true)"
      if gluerun_dispatch_tree_alive "$task_id" "$dpid" "$dpid_start" "$run_id" "${dpgid:-0}" "$lease_age_min"; then
        tree_alive="yes"
      else
        tree_alive="no"
        fast_stale="yes"
      fi
    fi

    if [[ "$tree_alive" == "yes" ]]; then
      echo "recover: skipped $task_id (process tree still alive)"
      continue
    fi
    if [[ "$fast_stale" == "yes" ]]; then
      is_stale="yes"
      echo "recover: dispatch tree gone for $task_id; treating lease as stale now"
    else
      is_stale="$([[ "$lease_age_min" -ge "$stale_minutes" ]] && echo yes || echo no)"
    fi
    if [[ "$is_stale" == "yes" ]]; then
      # Ask the autonomous decider what to do with the stale task (AI-native; no
      # human halt). retry/rerun/rebuild -> clear the lease so it re-dispatches;
      # cancel/supersede -> terminal; otherwise park as stale.
      gluerun_lease_set_status "$task_id" "stale" || true
      if [[ "$fast_stale" == "yes" ]]; then
        # Close out the dispatch record here so the reconcile reaper does not
        # re-count the same crash on its next pass.
        gluerun_dispatch_record_finalize "$task_id" "-1" "crashed" || true
      fi
      dec_out="$("$recovery_decider" --task "$task_id" --failure-class "stale-lease" \
        --branch "$branch" --run "${run_id:-RECOVER}" --worktree "$GLUERUN_ROOT" 2>/dev/null || true)"
      action="$(printf '%s\n' "$dec_out" | sed -n 's/^action=//p' | tail -1)"
      [[ -n "$action" ]] || action="escalate-parked"
      case "$action" in
        retry|rerun-tests|rebuild-context|revalidate-evidence)
          rm -f "$(gluerun_lease_path "$task_id")"
          [[ -f "$task_file" ]] && gluerun_task_set_status "$task_file" "ready" || true
          echo "recover: cleared stale lease $task_id for retry (decider: $action)" ;;
        cancel)    gluerun_lease_set_status "$task_id" "cancelled" || true; echo "recover: cancelled stale $task_id" ;;
        supersede) gluerun_lease_set_status "$task_id" "superseded" || true; echo "recover: superseded stale $task_id" ;;
        *)         echo "recover: parked stale lease $task_id (decider: $action)" ;;
      esac
      actions=$((actions + 1))
    fi
  done < <(find "$GLUERUN_LEASES_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)
fi

# 2. Detect (and optionally prune) orphaned worktrees.
if [[ -d "$GLUERUN_WORKTREES_DIR" ]]; then
  while IFS= read -r wt; do
    [[ -n "$wt" ]] || continue
    [[ -d "$wt" ]] || continue
    task_id="$(basename "$wt")"
    status="$(gluerun_lease_status "$task_id" 2>/dev/null || echo none)"
    case "$status" in
      running|planned|needs-review)
        # Active; leave it alone.
        continue
        ;;
    esac
    echo "recover: orphaned worktree $wt (lease status: $status)"
    if [[ "$mode" == "prune" ]]; then
      # Only delete the directory after git has released the worktree, so we
      # never leave git tracking a path we already removed.
      removed="no"
      if gluerun_worktree_registered "$wt"; then
        if git -C "$GLUERUN_ROOT" worktree remove --force "$wt" 2>/dev/null; then
          removed="yes"
        else
          echo "recover: git could not remove worktree $wt; leaving it in place" >&2
        fi
      else
        removed="yes"   # not registered with git; safe to delete directly
      fi
      if [[ "$removed" == "yes" ]]; then
        rm -rf "$wt"
        gluerun_record_recovery "orphaned worktree pruned" "$task_id" "n/a" "rebuild-context" "origin" "n/a" "origin"
        echo "recover: pruned worktree $wt"
        actions=$((actions + 1))
      fi
    fi
  done < <(find "$GLUERUN_WORKTREES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

git -C "$GLUERUN_ROOT" worktree prune 2>/dev/null || true
echo "recover ($mode): $actions action(s)"
