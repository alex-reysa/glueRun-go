#!/usr/bin/env bash
# SINGULAR-ext module: route the L2 implementer to Grok, keep every other role
# on $SINGULAR_RUNNER (Claude).
#
# Sourced by engine/lib.sh from SINGULAR_MODULES, after every generic function
# is defined, so this override wins. It MUST be listed after `storage-proof`
# in SINGULAR_MODULES -- both modules override singular_select_l2_runner, and
# the last one loaded is the one that survives. This file therefore re-states
# the storage-proof route rather than assuming it.

# The adapter is pinned by absolute path and defaults to THIS repository's copy,
# not the installed engine snapshot: the installed 0.18.0 grok-run.sh still asks
# for `grok-build`, a product name that is not a model id.
SINGULAR_GROK_RUNNER="${SINGULAR_GROK_RUNNER:-$SINGULAR_ROOT/engine/grok-run.sh}"

# Fail at load, not per task. An operator who opted into this module and whose
# adapter is missing wants to know now -- not after N tasks have quietly run on
# a provider they did not choose.
if [[ "${SINGULAR_GROK_IMPLEMENTER:-1}" == "1" && ! -x "$SINGULAR_GROK_RUNNER" ]]; then
  echo "grok-implementer: adapter not executable: $SINGULAR_GROK_RUNNER" >&2
  echo "grok-implementer: set SINGULAR_GROK_RUNNER, or SINGULAR_GROK_IMPLEMENTER=0 to disable." >&2
  exit 2
fi

# Override: pick the L2 (implementer) runner.
#
# NOTE ON SEMANTICS. The storage-proof module treats a set $SINGULAR_RUNNER as
# "the operator forced one runner for everything" and short-circuits to it. That
# is wrong under this module: here $SINGULAR_RUNNER is deliberately set to the
# NON-implementer provider (claude-run.sh), so honouring it for L2 would send
# every implementer task to Claude and silently undo the whole point. L2 is
# therefore selected independently of $SINGULAR_RUNNER, and
# $SINGULAR_GROK_IMPLEMENTER=0 is the explicit off switch.
singular_select_l2_runner() {
  local task_file="$1" default_runner="$2" claude_runner="${3:-}"

  if [[ "${SINGULAR_GROK_IMPLEMENTER:-1}" != "1" ]]; then
    printf '%s\n' "$default_runner"; return 0
  fi

  # storage_proof tasks stay on Claude: they need real PostgreSQL egress that a
  # provider sandbox blocks. Preserved verbatim from the storage-proof module.
  if [[ -n "$claude_runner" && -x "$claude_runner" ]] \
     && declare -F singular_task_requires_storage_proof_red_guard >/dev/null 2>&1 \
     && singular_task_requires_storage_proof_red_guard "$task_file"; then
    printf '%s\n' "$claude_runner"; return 0
  fi

  if [[ -x "$SINGULAR_GROK_RUNNER" ]]; then
    printf '%s\n' "$SINGULAR_GROK_RUNNER"; return 0
  fi
  printf '%s\n' "$default_runner"
}
