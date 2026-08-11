#!/usr/bin/env bash
set -euo pipefail

# P9 (0.5.0): singular gc — runs-history cap with reference protection,
# integrated-worktree pruning, events rotation; --dry-run removes nothing.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-gc.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/.singular-state/runs" "$root/.singular-state/leases" \
  "$root/.singular-state/dispatch" "$root/.singular-state/inbox" "$root/docs/orchestration/tasks"
git -C "$root" init -q
git -C "$root" checkout -q -b target
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

ops() {
  env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks" \
    SINGULAR_LEASES_DIR="$root/.singular-state/leases" SINGULAR_INBOX_DIR="$root/.singular-state/inbox" \
    SINGULAR_DISPATCH_DIR="$root/.singular-state/dispatch" SINGULAR_RUNS_DIR="$root/.singular-state/runs" \
    SINGULAR_WORKTREES_DIR="$root/.worktrees" \
    SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" SINGULAR_TARGET_BRANCH=target "$@" \
    bash "$SCRIPT_DIR/ops.sh" gc "${GC_ARGS[@]}"
}

# 12 old RUN- dirs + 3 old ORIGIN- dirs; RUN-keeper referenced by a live lease.
for i in $(seq 1 12); do
  d="$root/.singular-state/runs/RUN-old-$i"; mkdir -p "$d"; touch "$d/x.log"
done
for i in 1 2 3; do
  d="$root/.singular-state/runs/ORIGIN-old-$i"; mkdir -p "$d"; touch "$d/x.log"
done
mkdir -p "$root/.singular-state/runs/RUN-keeper"; touch "$root/.singular-state/runs/RUN-keeper/x.log"
printf '%s\n' '{"taskId":"TASK-0001","status":"running","runId":"RUN-keeper"}' \
  >"$root/.singular-state/leases/TASK-0001.json"
# Age everything past the min-age window.
find "$root/.singular-state/runs" -exec touch -t 202601010000 {} + 2>/dev/null || true

# 1. Dry run removes nothing.
GC_ARGS=(--dry-run)
out="$(ops env SINGULAR_RUNS_KEEP=5 SINGULAR_RUNS_MIN_AGE_HOURS=1)"
assert_contains "$out" "would-removed" "dry-run reports"
[[ "$(find "$root/.singular-state/runs" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')" == "16" ]] \
  || fail "dry-run must not delete"

# 2. Real gc: keeps 5 newest per bucket + the referenced run.
GC_ARGS=()
out="$(ops env SINGULAR_RUNS_KEEP=5 SINGULAR_RUNS_MIN_AGE_HOURS=1)"
[[ -d "$root/.singular-state/runs/RUN-keeper" ]] || fail "referenced run protected"
remaining="$(find "$root/.singular-state/runs" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
# RUN bucket: 13 entries -> keep 5 (+keeper if outside top-5); ORIGIN: 3 -> keep 3.
(( remaining <= 9 )) || fail "runs not capped (remaining=$remaining)"

# 3. Events rotation.
python3 -c 'open("'"$root"'/.singular-state/events.ndjson","w").write("x"*2*1024*1024)'
GC_ARGS=()
out="$(ops env SINGULAR_EVENTS_MAX_MB=1)"
assert_contains "$out" "rotated" "events rotated"
[[ -f "$root/.singular-state/events.ndjson.1" ]] || fail "rotated file exists"
[[ ! -s "$root/.singular-state/events.ndjson" || "$(wc -c <"$root/.singular-state/events.ndjson")" -lt 1024 ]] \
  || fail "live journal reset"

echo "PASS: test-gc"
