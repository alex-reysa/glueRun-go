#!/usr/bin/env bash
set -euo pipefail

# Low-disk degraded mode. A field run reached ~99-100% disk and kept launching
# expensive worker sessions until temp-dir and cache writes started failing,
# because zero effective slots was not a MODE — dispatch_budget silently became
# 0 and the loop did nothing forever, with no event, no log line and no health
# signal, indistinguishable from "idle because there is no work".
#
# The regression that matters most here is the shape of the fix. The obvious
# move — copy the STOP/breaker downgrade and set mode="apply" — would skip the
# whole actuate block, including auto-integration and the GC sweep, which are
# the only two in-loop actions that RECLAIM disk. That builds a mode that can
# never exit itself. So case B asserts reconciliation keeps running.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in output"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2'"; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"

mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/gates" \
  "$root/docs/orchestration/areas/core" "$root/docs/orchestration/packets/imported" \
  "$root/docs/orchestration/prompts" "$root/schemas/orchestration" "$root/.gluerun-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
for s in dag task-batch state-packet audit-verdict decider-verdict gate-result; do
  cp "$ENGINE_HOME/schemas/$s.v0.schema.json" "$root/schemas/orchestration/" 2>/dev/null || true
done
cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$root/docs/orchestration/prompts/" 2>/dev/null || true
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{"schema":"gluerun.orchestration.dag.v0","nodes":[
 {"id":"D0.contract","stage":"D0","area":"core","layer":"contract","kind":"contract",
  "dependsOn":[],"requiredCompletion":"contract_complete"}]}
EOF
printf '# Project State\n' >"$root/docs/orchestration/project-state.md"
printf '# Area State: Core\n\nCurrent status: active\n' >"$root/docs/orchestration/areas/core/state.md"
cat >"$root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: low disk fixture

Status: ready
Area: core
Target branch: `target`
Worker branch: `agent/core/TASK-0001-lowdisk`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Exercise the low-disk gate.

## Scope

Owned files:

- `src/a.txt`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Pass.
EOF
git -C "$root" add .
git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init

# Stub the L1 driver and the promoter so we can see exactly what the gate lets
# through: the driver must NOT run while degraded, the promoter must.
cat >"$tmp/driver.sh" <<SH
#!/usr/bin/env bash
echo dispatched >>"$tmp/driver-ran"
SH
cat >"$tmp/promoter.sh" <<SH
#!/usr/bin/env bash
echo promoted >>"$tmp/promoter-ran"
echo "promotion: none"
SH
chmod +x "$tmp/driver.sh" "$tmp/promoter.sh"

run_reconcile() {
  env GLUERUN_ROOT="$root" \
    GLUERUN_ORCH_DIR="$root/docs/orchestration" \
    GLUERUN_TASKS_DIR="$root/docs/orchestration/tasks" \
    GLUERUN_STATE_DIR="$root/.gluerun-state" \
    GLUERUN_LEASES_DIR="$root/.gluerun-state/leases" \
    GLUERUN_INBOX_DIR="$root/.gluerun-state/inbox" \
    GLUERUN_RUNS_DIR="$root/.gluerun-state/runs" \
    GLUERUN_WORKTREES_DIR="$root/.worktrees" \
    GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson" \
    GLUERUN_ORIGIN_STATE_FILE="$root/.gluerun-state/origin-state.json" \
    GLUERUN_SCHEMA_DIR="$root/schemas/orchestration" \
    GLUERUN_TARGET_BRANCH=target \
    GLUERUN_L1_DRIVER="$tmp/driver.sh" \
    GLUERUN_PROMOTER="$tmp/promoter.sh" \
    GLUERUN_GENERATE=0 \
    GLUERUN_AUTO_INTEGRATE=0 \
    "$@"
}

# --- 1. degraded: an absurd reserve makes every slot unaffordable ------------
# Reserve 4 EiB rather than filling the disk, so the test is hermetic.
out="$(run_reconcile GLUERUN_DISK_RESERVE_BYTES=4611686018427387904 \
  GLUERUN_MAX_CONCURRENT=3 \
  bash "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)" || true

[[ "$(field "$out" effective_slots)" == "0" ]] || fail "expected zero effective slots: $(field "$out" effective_slots)"
[[ "$(field "$out" dispatch_gate)" == "low-disk" ]] || fail "dispatch gate should be low-disk, got '$(field "$out" dispatch_gate)'"
assert_contains "$out" "LOW DISK" "degraded banner"
assert_contains "$out" "insufficient-disk-after-reserve" "capacity reason"
[[ ! -f "$tmp/driver-ran" ]] || fail "a worker was dispatched while degraded"
grep -q '"type":"origin.degraded_low_disk"' "$root/.gluerun-state/events.ndjson" \
  || fail "degraded mode must emit origin.degraded_low_disk (a silent stall is the bug)"
echo "  ok  degraded: dispatch suspended, event emitted"

# --- 2. reconciliation continues (the anti-STOP-copy guard) -----------------
# If someone reshapes this as mode="apply", these all disappear and the mode
# loses its own exit path.
assert_contains "$out" "actuation:" "actuate block still executed"
grep -q '"type":"origin.reconcile_completed"' "$root/.gluerun-state/events.ndjson" \
  || fail "reconcile must still complete a cycle while degraded"
[[ -f "$root/.gluerun-state/origin-state.json" ]] || fail "origin state must still be written"
echo "  ok  cycle completes and snapshots while degraded"

# (Gate promotion is checked last — see case 5 — because proving it requires an
# empty ready queue, and draining the queue mid-test would change what the
# recovery case below is actually asserting.)

# --- 3. GC retry was attempted before accepting zero capacity ---------------
[[ "$(field "$out" resource_gc_attempted)" == "1" ]] \
  || fail "one conservative GC sweep must be attempted before declaring zero capacity"
echo "  ok  GC retry attempted"

# --- 4. recovery: a sane reserve reopens the gate ---------------------------
rm -f "$tmp/driver-ran"
out2="$(run_reconcile GLUERUN_DISK_RESERVE_BYTES=1024 \
  GLUERUN_ESTIMATED_WORKTREE_BYTES=1024 GLUERUN_MAX_CONCURRENT=3 \
  bash "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)" || true
[[ "$(field "$out2" dispatch_gate)" == "open" ]] || fail "gate should reopen with capacity: '$(field "$out2" dispatch_gate)'"
assert_not_contains "$out2" "LOW DISK" "no degraded banner once capacity returns"
[[ -f "$tmp/driver-ran" ]] || fail "dispatch must resume once capacity returns"
echo "  ok  recovery: dispatch resumes"

# --- 5. promotion still runs while degraded ---------------------------------
# Gate promotion only fires when the ready queue is empty (pre-existing and
# correct: a ready task means dispatchable work already exists). Marking the
# task integrated drains the queue. This runs LAST so the mutation cannot
# influence any earlier assertion.
sed -i.bak 's/^Status: ready$/Status: integrated/' "$root/docs/orchestration/tasks/TASK-0001.md"
rm -f "$root/docs/orchestration/tasks/TASK-0001.md.bak"
rm -f "$tmp/promoter-ran"
out3="$(run_reconcile GLUERUN_DISK_RESERVE_BYTES=4611686018427387904 \
  GLUERUN_MAX_CONCURRENT=3 \
  bash "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)" || true
[[ "$(field "$out3" dispatch_gate)" == "low-disk" ]] || fail "expected the low-disk gate again"
# Promotion is completion authority: it costs no worktree and can unblock the
# integration that frees the disk, so the degraded gate must not suppress it.
[[ -f "$tmp/promoter-ran" ]] || fail "gate promotion must keep running while degraded"
echo "  ok  gate promotion still runs while degraded"

echo "PASS: test-reconcile-low-disk"
