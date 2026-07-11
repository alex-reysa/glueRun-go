#!/usr/bin/env bash
# Covers the deterministic post-acceptance sampling gate slice
# engine/ctx-critic-recheck.sh: a default-OFF GLUERUN_CRITIC_RECHECK_PCT knob
# gates a pure, side-effect-free content-hash sampling decision — the sibling of
# the integrated paired-audit sampling primitive (engine/ctx-paired-audit.sh).
# This brick decides sampling ONLY; it never blocks/changes an accept/reject
# outcome, makes no event, writes no file, and holds no state. Asserts:
#   (a) file present-but-uncalled: lib.sh auto-sources it and it defines NEW
#       functions only (bucket + should_sample), no recorder/side-effecting entry;
#   (b) OFF-by-default: GLUERUN_CRITIC_RECHECK_PCT unset OR "0" never samples any
#       id, and the gate makes no event, no file, and no state write;
#   (c) PCT=100 samples every id; a mid value P samples exactly the reproducible
#       subset whose bucket < P; a non-numeric/garbage value behaves as OFF;
#   (d) bucket is deterministic in 0..99, identical across repeated calls and
#       across separate bash processes for the same id (stable content hash mod
#       100, never $RANDOM or any process/host-specific source).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_CR="$ENGINE_HOME/engine/ctx-critic-recheck.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

export GLUERUN_ROOT="$tmp"
export GLUERUN_STATE_DIR="$tmp/state"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# (a) The engine file must exist and be auto-sourced by lib.sh's ctx-loader.
#     It defines the two pure gate functions (RED before it is written).
[[ -f "$CTX_CR" ]] || fail "engine not present yet: $CTX_CR"
[[ "$(type -t gluerun_ctx_critic_recheck_bucket)" == "function" ]] \
  || fail "gluerun_ctx_critic_recheck_bucket not defined (auto-source failed?)"
[[ "$(type -t gluerun_ctx_critic_recheck_should_sample)" == "function" ]] \
  || fail "gluerun_ctx_critic_recheck_should_sample not defined (auto-source failed?)"

# Pin an isolated events log so we can prove the gate never appends an event.
export GLUERUN_EVENTS_FILE="$tmp/events.ndjson"
: > "$GLUERUN_EVENTS_FILE"

fixture=(RUN-1:TASK-0001 RUN-1:TASK-0002 RUN-2:TASK-0003 RUN-3:TASK-0004 \
         RUN-4:TASK-0005 RUN-5:TASK-0006 RUN-6:TASK-0007 RUN-7:TASK-0008 \
         RUN-8:TASK-0009 RUN-9:TASK-0010 RUN-10:TASK-0011 RUN-11:TASK-0012)

# ---------------------------------------------------------------------------
# (d) bucket determinism: value in 0..99, identical across repeated calls and a
#     separate bash process for the same id.
# ---------------------------------------------------------------------------
for id in "${fixture[@]}"; do
  b1="$(gluerun_ctx_critic_recheck_bucket "$id")" || fail "bucket crashed for $id"
  [[ "$b1" =~ ^[0-9]+$ ]] || fail "bucket not numeric for $id: '$b1'"
  (( b1 >= 0 && b1 <= 99 )) || fail "bucket out of 0..99 for $id: $b1"
  b2="$(gluerun_ctx_critic_recheck_bucket "$id")" || fail "bucket repeat crashed for $id"
  [[ "$b1" == "$b2" ]] || fail "bucket not stable across calls for $id ($b1 vs $b2)"
  b3="$(bash -c 'source "'"$CTX_CR"'"; gluerun_ctx_critic_recheck_bucket "'"$id"'"')" \
    || fail "bucket subprocess crashed for $id"
  [[ "$b1" == "$b3" ]] || fail "bucket differs cross-process for $id ($b1 vs $b3)"
done

# ---------------------------------------------------------------------------
# (b) OFF-by-default: unset AND "0" never sample any id, and no event/file/state
#     is written by the gate.
# ---------------------------------------------------------------------------
before_ev="$(shasum "$GLUERUN_EVENTS_FILE" | awk '{print $1}')"
before_state="$(ls -1a "$tmp/state" | sort | shasum | awk '{print $1}')"

unset GLUERUN_CRITIC_RECHECK_PCT
for id in "${fixture[@]}"; do
  if gluerun_ctx_critic_recheck_should_sample "$id"; then
    fail "OFF (unset): sampled id $id"
  fi
done

export GLUERUN_CRITIC_RECHECK_PCT=0
for id in "${fixture[@]}"; do
  if gluerun_ctx_critic_recheck_should_sample "$id"; then
    fail "OFF (=0): sampled id $id"
  fi
done

after_ev="$(shasum "$GLUERUN_EVENTS_FILE" | awk '{print $1}')"
after_state="$(ls -1a "$tmp/state" | sort | shasum | awk '{print $1}')"
[[ "$before_ev" == "$after_ev" ]] || fail "gate mutated the events log"
[[ "$before_state" == "$after_state" ]] || fail "gate mutated state dir"
[[ ! -s "$GLUERUN_EVENTS_FILE" ]] || fail "gate appended an event"

# ---------------------------------------------------------------------------
# (c) garbage PCT is fail-safe OFF.
# ---------------------------------------------------------------------------
for junk in "abc" "1.5" "-3" "10x" " " "1e2" "0x10" "nan"; do
  export GLUERUN_CRITIC_RECHECK_PCT="$junk"
  for id in "${fixture[@]}"; do
    if gluerun_ctx_critic_recheck_should_sample "$id"; then
      fail "garbage PCT='$junk' sampled id $id (should be fail-safe OFF)"
    fi
  done
done

# ---------------------------------------------------------------------------
# (c) PCT=100 samples every id.
# ---------------------------------------------------------------------------
export GLUERUN_CRITIC_RECHECK_PCT=100
for id in "${fixture[@]}"; do
  gluerun_ctx_critic_recheck_should_sample "$id" \
    || fail "PCT=100 did not sample id $id"
done

# ---------------------------------------------------------------------------
# (c)+(d) Mid value P: samples EXACTLY the reproducible subset whose bucket < P,
#     and the per-id decision is reproducible across repeated calls and a
#     separate bash process.
# ---------------------------------------------------------------------------
for P in 25 50 73; do
  export GLUERUN_CRITIC_RECHECK_PCT="$P"
  sampled=0
  for id in "${fixture[@]}"; do
    bucket="$(gluerun_ctx_critic_recheck_bucket "$id")"
    want=1; (( bucket < P )) || want=0
    got=0; gluerun_ctx_critic_recheck_should_sample "$id" && got=1
    [[ "$want" == "$got" ]] \
      || fail "P=$P: id $id bucket=$bucket want=$want got=$got (subset != bucket<P)"
    (( got == 1 )) && sampled=$((sampled + 1))

    got2=0; gluerun_ctx_critic_recheck_should_sample "$id" && got2=1
    [[ "$got" == "$got2" ]] || fail "P=$P: repeated decision differs for $id"
    got3="$(GLUERUN_CRITIC_RECHECK_PCT="$P" bash -c \
      'source "'"$CTX_CR"'"; if gluerun_ctx_critic_recheck_should_sample "'"$id"'"; then echo 1; else echo 0; fi')" \
      || fail "P=$P: subprocess decision failed for $id"
    [[ "$got" == "$got3" ]] || fail "P=$P: cross-process decision differs for $id ($got vs $got3)"
  done
  # A mid value must be a proper subset: not none, not all (given a spread fixture).
  (( sampled > 0 && sampled < ${#fixture[@]} )) \
    || fail "P=$P: expected a proper subset, sampled $sampled/${#fixture[@]}"
done

echo "ctx-critic-recheck tests passed"
