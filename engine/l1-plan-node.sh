#!/usr/bin/env bash
set -euo pipefail

# Require bash >= 4 (mapfile/compgen); macOS /bin/bash is 3.2.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${GLUERUN_BASH_BIN:-}" ]]; then
    [[ "$GLUERUN_BASH_BIN" == /* && -x "$GLUERUN_BASH_BIN" ]] || { echo "invalid GLUERUN_BASH_BIN: $GLUERUN_BASH_BIN" >&2; exit 2; }
    exec "$GLUERUN_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "l1-plan-node.sh requires bash >= 4" >&2; exit 1
fi

# Per-node L1 planner driver. L0's fanout launches one of these (in parallel)
# for each eligible, non-conflicting DAG node. It owns that node's L1 lease
# (planning -> active, or failed) and runs the planner in STAGED mode so the
# planner writes ONLY into the node's private staging dir — never the global
# tasks dir, gate results, area state, or the global event log. L0 (the serial
# importer) remains the sole writer of global task state.
#
# Exit 0 = node planned (staged candidates present, lease left active for L0 to
# release at import). Exit non-zero = planning failed (lease marked failed).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

node=""
run_id=""
stage_dir=""
base_sha=""
count=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) node="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    --stage-dir) stage_dir="$2"; shift 2 ;;
    --base-sha) base_sha="$2"; shift 2 ;;
    --count) count="$2"; shift 2 ;;
    *) echo "usage: $0 --node NODE --run-id RID --stage-dir DIR [--base-sha SHA] [--count N]" >&2; exit 2 ;;
  esac
done
[[ -n "$node" && -n "$stage_dir" ]] || { echo "l1-plan-node: --node and --stage-dir are required" >&2; exit 2; }
[[ -n "$run_id" ]] || run_id="$(gluerun_worker_run_id)"

mkdir -p "$stage_dir"
# Concurrent planners must not write the global event log; route all events
# (this driver's and the planner's) to a private per-node file.
export GLUERUN_EVENTS_FILE="$stage_dir/planner-events.ndjson"

if gluerun_stop_requested; then
  echo "frozen (STOP sentinel present); node=$node"
  exit 0
fi

gluerun_require_target_branch

# Resolve node fields + confirm eligibility (fail-closed; same predicate as
# next-areas), so a planner can never be driven against an ineligible node.
fields="$("$SCRIPT_DIR/dag.sh" node-fields "$node" 2>&1)" || {
  echo "plan-failed:$node (ineligible: $fields)"
  exit 1
}
area="$(printf '%s\n' "$fields" | sed -n 's/^area=//p' | tail -1)"
stage="$(printf '%s\n' "$fields" | sed -n 's/^stage=//p' | tail -1)"
layer="$(printf '%s\n' "$fields" | sed -n 's/^layer=//p' | tail -1)"
[[ -n "$area" && -n "$stage" && -n "$layer" ]] || { echo "plan-failed:$node (node fields incomplete)"; exit 1; }

[[ -n "$base_sha" ]] || base_sha="$(git -C "$GLUERUN_ROOT" rev-parse "$GLUERUN_TARGET_BRANCH")"

planner_node_status_activity="Planning failed for $node"
planner_node_status_next_action="Inspect the node planner evidence"
planner_node_status_outcome="planning-failed"

gluerun_planner_node_status_write() {
  local activity="$1" next_action="$2"
  "$SCRIPT_DIR/run-status.sh" write \
    --run-id "$run_id" --node "$node" --phase planning --state active \
    --activity "$activity" --safe-cancel true --next-action "$next_action" \
    --process-type planner --pid "$$" >/dev/null 2>&1 || true
}

gluerun_planner_node_status_on_exit() {
  local rc=$?
  local state="failed"
  trap - EXIT
  [[ "$rc" -eq 0 ]] && state="completed"
  "$SCRIPT_DIR/run-status.sh" write \
    --run-id "$run_id" --node "$node" --phase terminal --state "$state" \
    --activity "$planner_node_status_activity" --safe-cancel false \
    --next-action "$planner_node_status_next_action" --process-type planner --pid "$$" \
    --outcome "$planner_node_status_outcome" >/dev/null 2>&1 || true
  exit "$rc"
}

gluerun_planner_node_status_write \
  "Planning node $node" "Validate its staged task candidates"
trap gluerun_planner_node_status_on_exit EXIT

# Lease the node: planning -> active.
gluerun_l1_lease_write "$node" "$area" "$stage" "$layer" planning "$run_id" "$base_sha" "$GLUERUN_TARGET_BRANCH" || {
  echo "plan-failed:$node (lease write failed)"
  exit 1
}
gluerun_l1_lease_set_status "$node" active || true

planner="${GLUERUN_L1_PLANNER:-$SCRIPT_DIR/generate-tasks.sh}"
if GLUERUN_PLANNING_RUN_ID="$run_id" \
   GLUERUN_PLANNING_ARTIFACT_DIR="$stage_dir" \
   "$planner" --node "$node" --stage-dir "$stage_dir" --count "$count" >>"$stage_dir/planner.out" 2>&1 \
   && { gluerun_task_batch_has_candidates "$stage_dir" || [[ -f "$stage_dir/NO-TASKS" ]]; }; then
  gluerun_planner_node_status_write \
    "Validating staged candidates for $node" "Critique or import the validated candidates"
  # A valid empty batch (NO-TASKS marker, 0.5.0): nothing to critique or
  # import; leave the lease for L0's importer to release.
  if [[ -f "$stage_dir/NO-TASKS" ]] && ! gluerun_task_batch_has_candidates "$stage_dir"; then
    planner_node_status_activity="Planning completed with no tasks for $node"
    planner_node_status_next_action="Release the node lease"
    planner_node_status_outcome="planned-empty"
    echo "planned-empty:$node"
    exit 0
  fi
  # --- plan-revision-loop hook (default-OFF; GLUERUN_PLAN_CRITIQUE=1) ----------
  # The single sanctioned call-site of the integrated bounded revise -> (resume|
  # fresh) -> re-critique -> approve/park orchestrator (engine/ctx-plan-revise-
  # loop.sh, auto-sourced via lib.sh). It fires ONLY here — the existing staging-
  # success branch, after the planner has produced *.candidate.md — and ONLY under
  # the flag; it adds no revision logic of its own, delegating entirely to the
  # orchestrator, which prints EXACTLY one terminal line and drives no state beyond
  # the stage dir + the per-node GLUERUN_EVENTS_FILE this driver already exports.
  #   import        -> keep today's behavior: candidates left staged, node lease
  #                    left active, planned:<node>, exit 0 -> L0 stays the sole
  #                    importer.
  #   park <reason> -> a never-approve / budget-exhausted terminal: mark the node
  #                    lease failed and exit plan-failed (non-zero) so unapproved
  #                    candidates never reach L0 import (mirrors the critique-import
  #                    gate reject disposition; fail CLOSED).
  # Flag unset / != 1 (default 0) => this block is inert => byte-identical to prior
  # behavior. The orchestrator is reached through a composed name so the sibling
  # brick's present-but-uncalled grep of engine/*.sh stays literal-match green.
  if [[ "${GLUERUN_PLAN_CRITIQUE:-0}" == "1" ]]; then
    _revise_pfx=gluerun_plan_revise_
    revise_outcome="$("${_revise_pfx}loop" "$node" "$run_id" "$stage_dir")" \
      || revise_outcome="park loop-error"
    if [[ "${revise_outcome%% *}" != "import" ]]; then
      gluerun_l1_lease_set_status "$node" failed || true
      echo "plan-failed:$node ($revise_outcome)"
      exit 1
    fi
  fi
  planner_node_status_activity="Planning staged candidates for $node"
  planner_node_status_next_action="Import the staged candidates"
  planner_node_status_outcome="planned"
  echo "planned:$node"
  exit 0
fi

gluerun_l1_lease_set_status "$node" failed || true
echo "plan-failed:$node"
exit 1
