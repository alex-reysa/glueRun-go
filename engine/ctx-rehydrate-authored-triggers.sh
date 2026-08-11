#!/usr/bin/env bash
# ctx-rehydrate-authored-triggers.sh — pure, read-only authored-knowledge
# trigger-set builder (stage S5-routing, node `rehydrate-path`, layer
# engine_runtime). Sourced exactly once by the context-evolution loader block in
# lib.sh (it matches the ctx-*.sh glob). This file DEFINES a new function only
# and is present-but-uncalled by every existing engine/CLI/driver path, so with
# it sourced the engine stays byte-identical to prior behavior.
#
# This is the REFINEMENT slice of the explicitly-OPTIONAL authored-knowledge
# deliverable. TASK-0059 (singular_ctx_rehydrate_authored_eligible) matches each
# authored entry's `load-when` list against the trigger tokens the caller
# supplies. But the two live call sites — the injection wire-in
# (engine/l1-drive.sh, TASK-0062) and the manifest-record merge
# (engine/ctx-rehydrate-event.sh, TASK-0063) — both pass only the single
# hardcoded literal `implement`, so an authored entry whose `load-when` targets
# any other dimension (a role, a node/stage, or a specific task) can never become
# eligible. This slice adds the pure token-set builder that closes that gap; a
# follow-up slice substitutes the hardcoded `implement` at the two call sites
# with this set. It is NOT part of the `rehydrate-path` node's requiredCompletion
# and does NOT gate the node. SINGULAR_CTX_MANIFEST (default 0) still gates the
# feature end to end; this leaf is inert until the follow-up wire-in feeds its
# output to singular_ctx_rehydrate_authored_config_render /
# singular_ctx_rehydrate_authored_config_manifest.
#
#   singular_ctx_rehydrate_authored_triggers <role> <step> [node] [task-id]
#
# Emits a deterministic, order-stable, de-duplicated set of `load-when` trigger
# tokens for the run — one per line — drawn from the run's identifying
# dimensions in a fixed order: the role, the step, and, when supplied, the node
# and the task id.
#
#   - the literal `implement` token is included whenever the step is `implement`
#     (it IS the step token), so existing implement-scoped authored entries keep
#     matching once the follow-up wire-in lands (backward compatible).
#   - absent optional arguments (empty node / task id) contribute nothing — no
#     empty tokens are ever emitted.
#   - repeated dimensions collapse to a single token; the first occurrence fixes
#     that token's position, so identical inputs yield byte-identical output.
#
# Pure, READ-ONLY, deterministic: it names the run's dimensions only, reads no
# config or manifest, writes/renames/deletes nothing, appends no events, and
# never exits non-zero on well-formed input.

# singular_ctx_rehydrate_authored_triggers <role> <step> [node] [task-id]
singular_ctx_rehydrate_authored_triggers() {
  local role="${1-}" step="${2-}" node="${3-}" task="${4-}"
  local dim
  # Fixed dimension order: role, step, node, task. Non-empty dimensions are
  # emitted once each; a `seen` set collapses repeats while the first occurrence
  # fixes the token's position, keeping the output order-stable and deterministic.
  local -A seen=()
  for dim in "$role" "$step" "$node" "$task"; do
    [[ -n "$dim" ]] || continue
    [[ -n "${seen[$dim]+x}" ]] && continue
    seen[$dim]=1
    printf '%s\n' "$dim"
  done
}
