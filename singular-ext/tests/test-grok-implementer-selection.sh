#!/usr/bin/env bash
set -euo pipefail

# Tests the grok-implementer module's singular_select_l2_runner override:
# ordinary L2 work routes to the Grok adapter, storage_proof tasks still route
# to Claude, a set $SINGULAR_RUNNER does NOT capture L2, and the off switch
# restores the default. Synthetic fixtures only -- self-contained and free.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
export SINGULAR_ROOT="$ENGINE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/singular-grok-sel.XXXXXX")"
trap 'rm -rf "$work"' EXIT

default_runner="$work/claude-run.sh"; printf '#!/usr/bin/env bash\n' >"$default_runner"; chmod +x "$default_runner"
claude_runner="$default_runner"
grok_runner="$work/grok-run.sh";   printf '#!/usr/bin/env bash\n' >"$grok_runner";   chmod +x "$grok_runner"
export SINGULAR_GROK_RUNNER="$grok_runner"

# Order matters: grok-implementer must load AFTER storage-proof, since both
# override singular_select_l2_runner.
export SINGULAR_MODULES="storage-proof grok-implementer"
# Hermetic against operator config: without this, the repo's config.local.sh
# is sourced after these exports and its SINGULAR_MODULES/SINGULAR_GROK_*
# values replace the fixture's. This test must pass on a host with NO grok
# operator config at all.
export SINGULAR_LOCAL_CONFIG_FILE=/dev/null
source "$SCRIPT_DIR/lib.sh"

proof_task="$work/proof.md"
cat >"$proof_task" <<'EOF'
# TASK-9001: durable proof
## Objective
Implement the focused D6.storage_proof / storage_proof closure: a durable
round-trip proof against a real PostgreSQL store.
## Acceptance Criteria
The red evidence includes a marked nonzero storage-proof skip-guard command log.
## Required Evidence
Failing output including TASK-9001-skip-guard-red, then passing durable proof.
EOF

spec_task="$work/spec.md"
cat >"$spec_task" <<'EOF'
# TASK-9002: storage spec
## Objective
Define the storage_spec for the scheduler report; no durable proof here.
## Acceptance Criteria
Spec documents the schema and lifecycle.
## Required Evidence
State packet and auditor verdict.
EOF

# --- ordinary L2 work -> grok --------------------------------------------------
unset SINGULAR_RUNNER
got="$(singular_select_l2_runner "$spec_task" "$default_runner" "$claude_runner")"
[[ "$got" == "$grok_runner" ]] || fail "ordinary task should route to grok (got $got)"
pass "ordinary L2 task routes to the grok adapter"

# --- storage_proof still -> claude --------------------------------------------
got="$(singular_select_l2_runner "$proof_task" "$default_runner" "$claude_runner")"
[[ "$got" == "$claude_runner" ]] || fail "storage_proof must stay on claude (got $got)"
pass "storage_proof task still routes to claude (egress preserved)"

# --- a set SINGULAR_RUNNER must NOT capture L2 --------------------------------
# It names the NON-implementer provider now. storage-proof's own override
# short-circuits on it; this module must not, or every task lands on claude.
got="$(SINGULAR_RUNNER="$default_runner" singular_select_l2_runner "$spec_task" "$default_runner" "$claude_runner")"
[[ "$got" == "$grok_runner" ]] || fail "SINGULAR_RUNNER must not capture L2 (got $got)"
pass "a set SINGULAR_RUNNER does not divert L2 away from grok"

# --- explicit off switch -------------------------------------------------------
got="$(SINGULAR_GROK_IMPLEMENTER=0 singular_select_l2_runner "$spec_task" "$default_runner" "$claude_runner")"
[[ "$got" == "$default_runner" ]] || fail "off switch should restore the default (got $got)"
pass "SINGULAR_GROK_IMPLEMENTER=0 restores the default runner"

# --- missing adapter falls back, never silently mis-provisions ----------------
got="$(SINGULAR_GROK_RUNNER="$work/nonexistent.sh" singular_select_l2_runner "$spec_task" "$default_runner" "$claude_runner")"
[[ "$got" == "$default_runner" ]] || fail "absent adapter should fall back to default (got $got)"
pass "absent adapter falls back to the default runner"

echo "ALL GROK-IMPLEMENTER SELECTION TESTS PASSED"
