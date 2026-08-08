#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

configured="${GLUERUN_MAX_CONCURRENT:-${GLUERUN_MAX_L1_CONCURRENT:-3}}"
reserve="${GLUERUN_DISK_RESERVE_BYTES:-2147483648}"
estimate="${GLUERUN_ESTIMATED_WORKTREE_BYTES:-}"
free_bytes=""
json="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configured-slots) configured="${2:-}"; shift 2 ;;
    --reserve-bytes) reserve="${2:-}"; shift 2 ;;
    --estimated-worktree-bytes) estimate="${2:-}"; shift 2 ;;
    --free-bytes) free_bytes="${2:-}"; shift 2 ;;
    --json) json="yes"; shift ;;
    *) echo "resource-plan: unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "$configured" =~ ^[0-9]+$ && "$reserve" =~ ^[0-9]+$ ]] || {
  echo "resource-plan: slots and reserve must be non-negative integers" >&2
  exit 2
}
if [[ -z "$estimate" ]]; then
  estimate="$(python3 - "$GLUERUN_ROOT" <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
excluded = {".git", ".worktrees", ".gluerun-state"}
total = 0
for base, dirs, files in os.walk(root):
    dirs[:] = [name for name in dirs if name not in excluded]
    for name in files:
        try:
            total += (pathlib.Path(base) / name).stat().st_size
        except OSError:
            pass
# A writable worktree needs headroom for build output; use at least 256 MiB and
# otherwise twice the tracked/source footprint.
print(max(268435456, total * 2))
PY
)"
fi
[[ "$estimate" =~ ^[1-9][0-9]*$ ]] || {
  echo "resource-plan: estimate must be a positive integer" >&2
  exit 2
}
if [[ -z "$free_bytes" ]]; then
  free_bytes="$(python3 - "$GLUERUN_ROOT" <<'PY'
import shutil, sys
print(shutil.disk_usage(sys.argv[1]).free)
PY
)"
fi
[[ "$free_bytes" =~ ^[0-9]+$ ]] || {
  echo "resource-plan: free bytes must be a non-negative integer" >&2
  exit 2
}

# Provider-pressure ceiling (opt-in, default off). Read-only: with adaptation
# disabled this prints nothing, no state is created, and the record below is
# byte-identical to the pre-0.17.0 plan.
pressure_json=""
if gluerun_provider_pressure_enabled; then
  # Hand the controller the very baseline this plan is using, so its stored cap
  # is bounded by the same configured ceiling the min() below applies.
  pressure_json="$(GLUERUN_MAX_CONCURRENT="$configured" \
    gluerun_provider_pressure_status_json 2>/dev/null || true)"
fi

python3 - "$configured" "$reserve" "$estimate" "$free_bytes" "$json" "$pressure_json" <<'PY'
import json
import sys

configured, reserve, estimate, free = map(int, sys.argv[1:5])
affordable = max(0, free - reserve) // estimate
effective = min(configured, affordable)
if effective == configured:
    reason = "configured-capacity-available"
elif effective == 0:
    reason = "insufficient-disk-after-reserve"
else:
    reason = "disk-limited-concurrency"
record = {
    "schema": "gluerun.orchestration.resource-plan.v0",
    "configuredSlots": configured,
    "effectiveSlots": effective,
    "freeBytes": free,
    "reserveBytes": reserve,
    "estimatedWorktreeBytes": estimate,
    "affordableSlots": affordable,
    "reason": reason,
}

# Disk decides first, then provider pressure lowers the result further — never
# raises it. Taking the min here is what makes recovery structurally unable to
# exceed configured or disk-affordable capacity, whatever the stored cap says.
pressure_raw = sys.argv[6] if len(sys.argv) > 6 else ""
if pressure_raw:
    try:
        pressure = json.loads(pressure_raw)
    except ValueError:
        pressure = None
    if isinstance(pressure, dict):
        cap = pressure.get("cap")
        applied = (
            isinstance(cap, int) and not isinstance(cap, bool) and cap < effective
        )
        if applied:
            effective = cap
            record["effectiveSlots"] = effective
            record["reason"] = "provider-pressure-limited"
        record["providerPressure"] = {
            "enabled": True,
            "provider": pressure.get("provider"),
            "cap": cap if isinstance(cap, int) and not isinstance(cap, bool) else None,
            "events": pressure.get("events"),
            "pendingEvents": pressure.get("pendingEvents"),
            "quietSuccesses": pressure.get("quietSuccesses"),
            "recoverQuiet": pressure.get("recoverQuiet"),
            "clusterThreshold": pressure.get("clusterThreshold"),
            "applied": applied,
        }
if sys.argv[5] == "yes":
    print(json.dumps(record, separators=(",", ":")))
else:
    print(effective)
PY
