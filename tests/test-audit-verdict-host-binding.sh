#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
host="$tmp/audit-verification.json"
verdict="$tmp/audit.json"

write_host() {
  python3 - "$host" "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(
        {
            "schema": "singular.orchestration.gate-report.v0",
            "outcome": sys.argv[2],
        },
        handle,
    )
PY
}

write_verdict() {
  python3 - "$verdict" "$@" <<'PY'
import json
import sys

statuses = sys.argv[2:]
record = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001",
    "runId": "RUN-binding",
    "branch": "agent/test",
    "verdict": "accepted",
    "evidenceReviewed": ["runs/RUN-binding/audit-verification.json"],
    "verificationResults": [
        {
            "status": status,
            "command": "run tests",
            "evidenceRefs": ["runs/RUN-binding/audit-verification.json"],
            "rationale": "fixture",
        }
        for status in statuses
    ],
    "commandsRun": [],
    "findings": [],
    "requiredFixes": [],
    "rationale": "fixture",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(record, handle)
PY
}

assert_bound() {
  local expected="$1"
  local actual
  actual="$(
    python3 "$ROOT/engine/audit-verdict-host-bind.py" \
      --host-report "$host" --verdict "$verdict"
  )"
  [[ "$actual" == "$expected" ]] || {
    echo "expected binding $expected, got $actual" >&2
    exit 1
  }
}

assert_rejected() {
  if python3 "$ROOT/engine/audit-verdict-host-bind.py" \
    --host-report "$host" --verdict "$verdict" \
    >"$tmp/rejected.out" 2>"$tmp/rejected.err"; then
    echo "expected host/model classification mismatch to be rejected" >&2
    exit 1
  fi
}

write_host passed
write_verdict passed
assert_bound passed

# A resolved acknowledged baseline is still a genuinely rerun pass in the v1
# classification vocabulary.
write_host passed-with-acknowledged-baseline
write_verdict passed
assert_bound passed

# Evidence-only verification remains its own classification and may not be
# upgraded by the model to a real rerun pass, even in a mixed result array.
write_host not-rerun-evidence-verified
write_verdict not-rerun-evidence-verified
assert_bound not-rerun-evidence-verified
write_verdict passed
assert_rejected
grep -q "evidence-only host verification cannot be represented as passed" \
  "$tmp/rejected.err"
write_verdict not-rerun-evidence-verified passed
assert_rejected

# The inverse mismatch is also fail-closed.
write_host passed
write_verdict not-rerun-evidence-verified
assert_rejected

# Product and infrastructure classifications retain their exact semantics.
write_host failed-product
write_verdict failed-product
assert_bound failed-product
write_verdict passed
assert_rejected

write_host inconclusive-infrastructure
write_verdict inconclusive-infrastructure
assert_bound inconclusive-infrastructure
write_verdict passed
assert_rejected

echo "audit verdict host binding tests passed"
