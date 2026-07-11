#!/usr/bin/env bash
# Covers the deterministic A/B arm-assignment slice engine/ctx-ab.sh: a stable
# content-hash maps each task id to an arm in {A,B}, and the assignment is
# recorded as a ctx.arm_assigned event ONLY when the default-OFF GLUERUN_CTX_AB
# knob is 1. Asserts:
#   (a) OFF (GLUERUN_CTX_AB unset AND =0) -> zero ctx.arm_assigned events, no
#       other change to an isolated events log;
#   (b) determinism -> same task id always yields the same arm across repeated
#       calls and across separate bash processes; both arms drawn from {A,B};
#   (c) distribution sanity -> over a fixture id set both A and B occur and no id
#       maps to two different arms;
#   (d) ON (GLUERUN_CTX_AB=1) -> each assignment appends exactly one
#       ctx.arm_assigned event whose data carries the task id and its arm.
# The events log is pinned to an isolated temp file (GLUERUN_EVENTS_FILE) so the
# suite never mutates real run state.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_AB="$ENGINE_HOME/engine/ctx-ab.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

# lib.sh provides gluerun_append_event; source it against an isolated root so no
# real state is touched. lib.sh's ctx-loader also auto-sources engine/ctx-ab.sh.
export GLUERUN_ROOT="$tmp"
export GLUERUN_STATE_DIR="$tmp/state"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the assignment functions (RED before it
# is written). It is auto-sourced by lib.sh above; source again defensively so a
# failure here is unambiguous.
[[ -f "$CTX_AB" ]] || fail "engine not present yet: $CTX_AB"
# shellcheck disable=SC1090
source "$CTX_AB" || fail "sourcing $CTX_AB failed"
[[ "$(type -t gluerun_ctx_ab_arm_for)" == "function" ]] \
  || fail "gluerun_ctx_ab_arm_for is not defined by $CTX_AB"
[[ "$(type -t gluerun_ctx_ab_assign)" == "function" ]] \
  || fail "gluerun_ctx_ab_assign is not defined by $CTX_AB"

# Point the events log at an isolated temp file. lib.sh sets GLUERUN_EVENTS_FILE
# unconditionally at source time, so override it AFTER sourcing.
export GLUERUN_EVENTS_FILE="$tmp/events.ndjson"

count_arm_events() {
  [[ -f "$GLUERUN_EVENTS_FILE" ]] || { echo 0; return 0; }
  local c
  # grep -c always prints a count (0 on no match, exiting 1); keep just the number.
  c="$(grep -c '"type":"ctx.arm_assigned"' "$GLUERUN_EVENTS_FILE" 2>/dev/null)" || true
  echo "${c:-0}"
}

# ---------------------------------------------------------------------------
# (a) OFF -> zero ctx.arm_assigned events; the events log is untouched.
# ---------------------------------------------------------------------------
# Unset knob.
unset GLUERUN_CTX_AB
: > "$GLUERUN_EVENTS_FILE"
before="$(shasum "$GLUERUN_EVENTS_FILE" | awk '{print $1}')"
arm_off="$(gluerun_ctx_ab_assign "TASK-0004")" || fail "assign crashed with knob unset"
[[ "$arm_off" == "A" || "$arm_off" == "B" ]] || fail "OFF: arm not in {A,B}: [$arm_off]"
[[ "$(count_arm_events)" -eq 0 ]] || fail "OFF (unset): ctx.arm_assigned event emitted"
after="$(shasum "$GLUERUN_EVENTS_FILE" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail "OFF (unset): events log mutated"

# Knob explicitly 0.
GLUERUN_CTX_AB=0
before="$(shasum "$GLUERUN_EVENTS_FILE" | awk '{print $1}')"
gluerun_ctx_ab_assign "TASK-0004" >/dev/null || fail "assign crashed with knob=0"
[[ "$(count_arm_events)" -eq 0 ]] || fail "OFF (=0): ctx.arm_assigned event emitted"
after="$(shasum "$GLUERUN_EVENTS_FILE" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail "OFF (=0): events log mutated"
unset GLUERUN_CTX_AB

# ---------------------------------------------------------------------------
# (b) Determinism: same id -> same arm across repeated calls and across
#     separate bash processes; arms are drawn from {A,B}.
# ---------------------------------------------------------------------------
a1="$(gluerun_ctx_ab_arm_for "TASK-0004")"
a2="$(gluerun_ctx_ab_arm_for "TASK-0004")"
[[ "$a1" == "$a2" ]] || fail "determinism: repeated calls differ ($a1 vs $a2)"
# Separate process: source only ctx-ab.sh (pure fn needs no lib.sh) and print.
a3="$(bash -c 'source "'"$CTX_AB"'"; gluerun_ctx_ab_arm_for "TASK-0004"')" \
  || fail "determinism: subprocess invocation failed"
[[ "$a1" == "$a3" ]] || fail "determinism: cross-process arm differs ($a1 vs $a3)"
[[ "$a1" == "A" || "$a1" == "B" ]] || fail "determinism: arm not in {A,B}: [$a1]"

# ---------------------------------------------------------------------------
# (c) Distribution sanity over a fixture id set: both arms occur; no id maps to
#     two different arms.
# ---------------------------------------------------------------------------
fixture=(TASK-0001 TASK-0002 TASK-0003 TASK-0004 TASK-0005 \
         TASK-0006 TASK-0007 TASK-0008 TASK-0009 TASK-0010 \
         TASK-0011 TASK-0012)
saw_a=0
saw_b=0
for id in "${fixture[@]}"; do
  arm="$(gluerun_ctx_ab_arm_for "$id")"
  [[ "$arm" == "A" || "$arm" == "B" ]] || fail "distribution: arm not in {A,B} for $id: [$arm]"
  # Stability: three more calls must agree.
  for _ in 1 2 3; do
    again="$(gluerun_ctx_ab_arm_for "$id")"
    [[ "$again" == "$arm" ]] || fail "distribution: $id mapped to two arms ($arm vs $again)"
  done
  [[ "$arm" == "A" ]] && saw_a=1
  [[ "$arm" == "B" ]] && saw_b=1
done
[[ "$saw_a" -eq 1 ]] || fail "distribution: arm A never occurred over fixture set"
[[ "$saw_b" -eq 1 ]] || fail "distribution: arm B never occurred over fixture set"

# ---------------------------------------------------------------------------
# (d) ON (GLUERUN_CTX_AB=1): each assignment appends exactly one
#     ctx.arm_assigned event whose data includes the task id and the arm.
# ---------------------------------------------------------------------------
: > "$GLUERUN_EVENTS_FILE"
export GLUERUN_CTX_AB=1
declare -a expect_ids=()
declare -a expect_arms=()
n=0
for id in "${fixture[@]}"; do
  arm="$(gluerun_ctx_ab_assign "$id")" || fail "ON: assign crashed for $id"
  # Arm printed by assign must equal the pure mapping.
  pure="$(gluerun_ctx_ab_arm_for "$id")"
  [[ "$arm" == "$pure" ]] || fail "ON: assign arm ($arm) != pure arm ($pure) for $id"
  expect_ids+=("$id")
  expect_arms+=("$arm")
  n=$((n + 1))
done
# Exactly one event per assignment.
[[ "$(count_arm_events)" -eq "$n" ]] \
  || fail "ON: expected $n ctx.arm_assigned events, got $(count_arm_events)"

# Event shape: every event carries the correct task id + arm, in order.
python3 - "$GLUERUN_EVENTS_FILE" "${expect_ids[@]}" "--arms--" "${expect_arms[@]}" <<'PY' \
  || fail "ON: ctx.arm_assigned event shape/data mismatch"
import json, sys
path = sys.argv[1]
rest = sys.argv[2:]
sep = rest.index("--arms--")
ids = rest[:sep]
arms = rest[sep + 1:]
assert len(ids) == len(arms), "fixture/arm length mismatch"

events = []
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        ev = json.loads(line)
        if ev.get("type") == "ctx.arm_assigned":
            events.append(ev)

assert len(events) == len(ids), f"event count {len(events)} != {len(ids)}"
for ev, want_id, want_arm in zip(events, ids, arms):
    data = ev.get("data")
    assert isinstance(data, dict), f"event data not an object: {ev!r}"
    assert data.get("taskId") == want_id, f"taskId {data.get('taskId')!r} != {want_id!r}"
    assert data.get("arm") == want_arm, f"arm {data.get('arm')!r} != {want_arm!r}"
    assert data.get("arm") in ("A", "B"), f"arm not in A/B: {data.get('arm')!r}"
print("event-shape-ok")
PY
unset GLUERUN_CTX_AB

echo "ctx-ab tests passed"
