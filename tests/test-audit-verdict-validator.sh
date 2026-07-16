#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg (missing: $needle)"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

run_lib() {
  GLUERUN_ROOT="$tmp" \
  GLUERUN_STATE_DIR="$tmp/state" \
  GLUERUN_LEGACY_SCHEMA_MODE="${MODE:-warn}" \
  bash -c "source '$ENGINE_HOME/engine/lib.sh'; $1"
}

valid_verdict() {
  local schema_id="$1"
  cat <<EOF
{
  "schema": "$schema_id",
  "taskId": "TASK-0001",
  "runId": "RUN-1",
  "branch": "agent/x/TASK-0001",
  "verdict": "accepted",
  "evidenceReviewed": ["red.log"],
  "commandsRun": ["true"],
  "findings": [],
  "requiredFixes": [],
  "rationale": "clean"
}
EOF
}

# 1. Valid gluerun verdict passes.
valid_verdict "gluerun.orchestration.audit-verdict.v0" >"$tmp/v.json"
run_lib "gluerun_validate_audit_verdict '$tmp/v.json' TASK-0001 RUN-1" \
  || fail "valid verdict should pass"

# 2. Legacy pmgo id: warn mode tolerates (rc 0 + warning on stderr), file untouched.
valid_verdict "pmgo.orchestration.audit-verdict.v0" >"$tmp/legacy.json"
err="$(run_lib "gluerun_validate_audit_verdict '$tmp/legacy.json' TASK-0001" 2>&1 >/dev/null)" \
  || fail "warn mode should tolerate legacy schema id"
assert_contains "$err" "tolerating legacy schema id" "warn-mode stderr"
grep -q '"pmgo.orchestration.audit-verdict.v0"' "$tmp/legacy.json" \
  || fail "verdict file must never be rewritten"

# 3. Reject mode hard-fails with a migration pointer.
if MODE=reject run_lib "gluerun_validate_audit_verdict '$tmp/legacy.json' TASK-0001" 2>"$tmp/reject.err"; then
  fail "reject mode should fail on legacy schema id"
fi
assert_contains "$(cat "$tmp/reject.err")" "migrations/v0-to-v1.sh" "reject-mode migration hint"

# 4. Bad enum fails with a specific message.
valid_verdict "gluerun.orchestration.audit-verdict.v0" \
  | sed 's/"accepted"/"accept"/' >"$tmp/enum.json"
if run_lib "gluerun_validate_audit_verdict '$tmp/enum.json' TASK-0001" 2>"$tmp/enum.err"; then
  fail "bad verdict enum should fail"
fi
assert_contains "$(cat "$tmp/enum.err")" "verdict" "enum error names the field"

# 5. Missing required field fails.
valid_verdict "gluerun.orchestration.audit-verdict.v0" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); d.pop("evidenceReviewed"); print(json.dumps(d))' \
  >"$tmp/missing.json"
run_lib "gluerun_validate_audit_verdict '$tmp/missing.json' TASK-0001" 2>/dev/null \
  && fail "missing evidenceReviewed should fail"

# 6. taskId mismatch fails; runId mismatch is warn-only.
valid_verdict "gluerun.orchestration.audit-verdict.v0" >"$tmp/mismatch.json"
run_lib "gluerun_validate_audit_verdict '$tmp/mismatch.json' TASK-0002" 2>/dev/null \
  && fail "taskId mismatch should fail"
err="$(run_lib "gluerun_validate_audit_verdict '$tmp/mismatch.json' TASK-0001 RUN-9" 2>&1 >/dev/null)" \
  || fail "runId mismatch must be warn-only"
assert_contains "$err" "runId mismatch" "runId warn text"

# 7. Decider validator symmetry: legacy id tolerated in warn mode there too.
cat >"$tmp/decider.json" <<'EOF'
{
  "schema": "pmgo.orchestration.decider-verdict.v0",
  "taskId": "TASK-0001",
  "failureClass": "gate-red",
  "action": "retry",
  "rationale": "fixture",
  "nextOwner": "l1"
}
EOF
run_lib "GLUERUN_DECIDER_SCHEMA='$ENGINE_HOME/schemas/decider-verdict.v0.schema.json'; gluerun_validate_decider_verdict '$tmp/decider.json' gate-red TASK-0001" 2>/dev/null \
  || fail "decider validator should tolerate legacy id in warn mode"

echo "PASS: test-audit-verdict-validator"
