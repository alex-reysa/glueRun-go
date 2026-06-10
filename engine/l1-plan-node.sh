#!/usr/bin/env bash
set -euo pipefail

# Require bash >= 4 (mapfile/compgen); macOS /bin/bash is 3.2.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
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

# Lease the node: planning -> active.
gluerun_l1_lease_write "$node" "$area" "$stage" "$layer" planning "$run_id" "$base_sha" "$GLUERUN_TARGET_BRANCH" || {
  echo "plan-failed:$node (lease write failed)"
  exit 1
}
gluerun_l1_lease_set_status "$node" active || true

planner="${GLUERUN_L1_PLANNER:-$SCRIPT_DIR/generate-tasks.sh}"
if "$planner" --node "$node" --stage-dir "$stage_dir" --count "$count" >>"$stage_dir/planner.out" 2>&1 \
   && compgen -G "$stage_dir/"'*.candidate.md' >/dev/null; then
  echo "planned:$node"
  exit 0
fi

gluerun_l1_lease_set_status "$node" failed || true
echo "plan-failed:$node"
exit 1
