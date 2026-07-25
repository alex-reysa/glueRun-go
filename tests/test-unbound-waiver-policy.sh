#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
orch="$repo/docs/orchestration"
state="$repo/.gluerun-state"
mkdir -p "$orch" "$state/runs/RUN-waiver"
git -C "$repo" init -q
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
git -C "$repo" commit --allow-empty -qm init

cat >"$state/runs/RUN-waiver/packet.json" <<'JSON'
{
  "taskId": "TASK-0001",
  "runId": "RUN-waiver",
  "branch": "agent/core/TASK-0001",
  "status": "accepted",
  "evidence": [{"kind": "waiver", "ref": "decider:accept-waiver"}]
}
JSON
cat >"$state/runs/RUN-waiver/decision-audit-needs-fix.json" <<'JSON'
{
  "taskId": "TASK-0001",
  "failureClass": "audit-needs-fix",
  "action": "accept-waiver"
}
JSON
printf '# Decisions\n' >"$orch/decisions.md"

waiver_allowed() {
  GLUERUN_ROOT="$repo" \
  GLUERUN_ORCH_DIR="$orch" \
  GLUERUN_STATE_DIR="$state" \
  GLUERUN_RUNS_DIR="$state/runs" \
    bash -c 'source "$1"; gluerun_packet_has_accept_waiver "$2"' \
      bash "$ROOT/engine/lib.sh" "$state/runs/RUN-waiver/packet.json"
}

cat >"$repo/gluerun.config.json" <<'JSON'
{
  "schemaVersion": "v2",
  "legacyCompatibility": {"unboundWaivers": false}
}
JSON
if waiver_allowed; then
  echo "schema v2 must reject unbound waivers by default" >&2
  exit 1
fi

cat >"$repo/gluerun.config.json" <<'JSON'
{
  "schemaVersion": "v2",
  "legacyCompatibility": {"unboundWaivers": true}
}
JSON
waiver_allowed || {
  echo "explicit legacy compatibility should restore the historical waiver" >&2
  exit 1
}

cat >"$repo/gluerun.config.json" <<'JSON'
{"schemaVersion": "v1"}
JSON
waiver_allowed || {
  echo "pre-v2 consumers must retain their historical waiver behavior" >&2
  exit 1
}

echo "unbound waiver governance tests passed"
