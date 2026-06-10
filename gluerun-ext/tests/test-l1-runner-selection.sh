#!/usr/bin/env bash
set -euo pipefail

# Tests gluerun_select_l2_runner: storage_proof tasks route to the Claude runner
# (real-PostgreSQL egress that the codex sandbox blocks); every other task keeps
# the default runner; an explicit GLUERUN_RUNNER override always wins. Uses synthetic
# task fixtures so it is self-contained and free.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
export GLUERUN_ENGINE_HOME="$ENGINE_HOME"
export GLUERUN_MODULES="storage-proof"
source "$SCRIPT_DIR/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/gluerun-runner-sel.XXXXXX")"
trap 'rm -rf "$work"' EXIT

default_runner="$work/codex-run.sh"; printf '#!/usr/bin/env bash\n' >"$default_runner"; chmod +x "$default_runner"
claude_runner="$work/claude-run.sh"; printf '#!/usr/bin/env bash\n' >"$claude_runner"; chmod +x "$claude_runner"

# storage_proof fixture: matches gluerun_task_requires_storage_proof_red_guard
# (objective: storage_proof + real PostgreSQL proof; criteria: marked nonzero;
# required evidence: skip-guard-red).
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

# Non-proof fixture: a storage_spec task (no durable proof, no skip-guard-red).
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

# --- predicate sanity ----------------------------------------------------------
gluerun_task_requires_storage_proof_red_guard "$proof_task" || fail "predicate: proof task should require guard"
gluerun_task_requires_storage_proof_red_guard "$spec_task"  && fail "predicate: spec task should NOT require guard" || true
pass "predicate distinguishes storage_proof vs spec"

# --- selection: storage_proof -> claude ---------------------------------------
unset GLUERUN_RUNNER
got="$(gluerun_select_l2_runner "$proof_task" "$default_runner" "$claude_runner")"
[[ "$got" == "$claude_runner" ]] || fail "storage_proof task should route to claude runner (got $got)"
pass "storage_proof task routes to claude runner"

# --- selection: non-proof -> default ------------------------------------------
got="$(gluerun_select_l2_runner "$spec_task" "$default_runner" "$claude_runner")"
[[ "$got" == "$default_runner" ]] || fail "spec task should keep default runner (got $got)"
pass "non-proof task keeps default runner"

# --- explicit GLUERUN_RUNNER override wins even for storage_proof -----------------
got="$(GLUERUN_RUNNER="$default_runner" gluerun_select_l2_runner "$proof_task" "$default_runner" "$claude_runner")"
[[ "$got" == "$default_runner" ]] || fail "explicit GLUERUN_RUNNER override should win (got $got)"
pass "explicit GLUERUN_RUNNER override wins"

# --- missing/non-executable claude runner -> default --------------------------
unset GLUERUN_RUNNER
got="$(gluerun_select_l2_runner "$proof_task" "$default_runner" "$work/nonexistent.sh")"
[[ "$got" == "$default_runner" ]] || fail "absent claude runner should fall back to default (got $got)"
pass "absent claude runner falls back to default"

echo "ALL L1 RUNNER-SELECTION TESTS PASSED"
