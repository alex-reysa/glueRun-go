#!/usr/bin/env bash
# ctx-critic-recheck.sh — deterministic post-acceptance sampling gate behind the
# default-OFF SINGULAR_CRITIC_RECHECK_PCT knob.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior. It adds no
# driver-file hook, invokes no runner, and writes no state. It never owns
# engine/lib.sh.
#
# This is the sampling-gate sibling of the integrated paired-audit sampling
# primitive (engine/ctx-paired-audit.sh, TASK-0005): it establishes the pure,
# side-effect-free entry point the later critic-recheck recorder will consult
# before deciding whether an accepted task is sampled for a critic recheck.
#
# Scope discipline (advocate/skeptic + evidence invariance): this brick decides
# sampling ONLY. It never blocks or changes any accept/reject outcome, never
# weakens a gate, and never makes the fresh implementation auditor bypassable.
# The read-only critic-session resume, the skeptic role gate, the per-finding
# addressed|survives|obsolete disposition recorder + ctx.critic_recheck events,
# and the l1-drive.sh post-acceptance hook are the sanctioned follow-up slices of
# node critic-carryover and are OUT OF SCOPE here.
#
# Knob: SINGULAR_CRITIC_RECHECK_PCT (default 0 = OFF). Sampling is keyed on a
# stable content hash of the id reduced modulo 100 — never $RANDOM or any
# host/process-specific source — so the decision is deterministic, reproducible
# across repeated calls and separate processes, and machine-independent:
#   0 (unset or "0")     -> never samples;
#   100                  -> always samples;
#   a mid value P        -> samples the reproducible subset whose bucket < P;
#   a non-numeric/garbage -> treated as 0 (fail-safe OFF).
#
# Public entry points:
#   singular_ctx_critic_recheck_bucket <id>
#     Pure: print the id's sampling bucket in 0..99 (stable content hash mod 100).
#   singular_ctx_critic_recheck_should_sample <id>
#     Pure: exit 0 iff the id is sampled under the current knob, else exit 1.

# Print the sampling bucket (0..99) for an id via a stable content hash. Uses
# SHA-256 where available, else shasum, else cksum's CRC — all deterministic and
# machine-independent. Never $RANDOM or any process/host-specific source.
singular_ctx_critic_recheck_bucket() {
  local id="$1" hash
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$id" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$id" | shasum -a 256 | awk '{print $1}')"
  else
    hash="$(printf '%s' "$id" | cksum | awk '{print $1}')"
  fi
  # Reduce to 0..99. Interpret the low 6 hex digits as a number, then mod 100.
  # A decimal cksum digit string is a valid hex string too, so this is stable
  # across all hash sources.
  local low="${hash: -6}"
  if [[ "$low" =~ ^[0-9a-fA-F]+$ ]]; then
    printf '%s' $(( 16#$low % 100 ))
  else
    printf '0'
  fi
}

# Exit 0 iff the id is sampled under SINGULAR_CRITIC_RECHECK_PCT, else 1. Pure /
# no side effects. Default 0 (OFF) never samples; 100 always; a mid value P
# samples the reproducible subset whose bucket < P; a non-numeric/garbage value
# is treated as 0 (fail-safe OFF).
singular_ctx_critic_recheck_should_sample() {
  local id="$1" pct="${SINGULAR_CRITIC_RECHECK_PCT:-0}" bucket
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  (( pct <= 0 )) && return 1
  (( pct >= 100 )) && return 0
  bucket="$(singular_ctx_critic_recheck_bucket "$id")"
  (( bucket < pct )) && return 0
  return 1
}
