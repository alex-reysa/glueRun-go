#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${GLUERUN_BASH_BIN:-}" ]]; then
    [[ "$GLUERUN_BASH_BIN" == /* && -x "$GLUERUN_BASH_BIN" ]] || { echo "invalid GLUERUN_BASH_BIN: $GLUERUN_BASH_BIN" >&2; exit 2; }
    exec "$GLUERUN_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "dispatch-wrap.sh requires bash >= 4" >&2; exit 1
fi

# Spawn wrapper for L1 dispatch (used in both batch and detached modes): runs
# the driver, then persists its exit code as a dispatch exit file so the reaper
# can attribute the outcome out-of-process. If the driver died before reaching
# its own lease lifecycle (e.g. a preflight failure while a reconcile pre-lease
# is still 'planned'), the lease is backstopped to 'failed' so it stops
# consuming a concurrency slot. usage: dispatch-wrap.sh <task_id> <driver>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

task_id="$1"
driver="$2"

rc=0
"$driver" "$task_id" || rc=$?
gluerun_dispatch_exit_write "$task_id" "$rc"
lease_status="$(gluerun_lease_status "$task_id" 2>/dev/null || true)"
if [[ "$lease_status" == "planned" ]]; then
  # The driver never took lease ownership (it overwrites the pre-lease to
  # 'running' at startup): preflight refusal, STOP-frozen no-op exit 0, or a
  # crash before the lease write. Clear the reconcile pre-lease so the task
  # stops holding a concurrency slot.
  rm -f "$(gluerun_lease_path "$task_id")"
elif [[ "$rc" -ne 0 && "$lease_status" == "running" ]]; then
  # Nonzero exit with the lease still 'running' means the driver died without
  # its EXIT trap (e.g. SIGKILL); mark it failed so the slot frees now instead
  # of after the stale-lease window.
  gluerun_lease_set_status "$task_id" "failed" 2>/dev/null || true
fi
exit "$rc"
