#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/docs/orchestration/human-gates" "$repo/docs/orchestration/gates"
git -C "$tmp" init -q repo
printf '{"schemaVersion":"v2"}\n' >"$repo/gluerun.config.json"
printf 'release artifact\n' >"$repo/release.txt"
printf 'review notes\n' >"$repo/review.txt"

# Every human-gate CLI call below pins its clock with --now, but dag.sh's
# frontier evaluation has no such flag and used to read the wall clock. With a
# fixture that expires at 2026-07-25T10:00:00Z that made this a time bomb: green
# until real time crossed the expiry, then permanently red with nothing in the
# diff to explain it. GLUERUN_NOW injects the same instant into that path.
FIXED_NOW="2026-07-24T12:00:00Z"

common=(GLUERUN_ROOT="$repo" GLUERUN_STATE_DIR="$repo/.gluerun-state")
request_ref="docs/orchestration/human-gates/release.human-gate.json"
approval_ref="docs/orchestration/human-gates/release.human-approval.json"
gate_ref="docs/orchestration/gates/release.gate-result.json"

env "${common[@]}" "$ROOT/engine/human-gate.sh" request \
  --node release --gate-id release-approval --approval-type exact-artifact \
  --owner owner@example.com --expires-at 2026-07-25T10:00:00Z \
  --request-ref "$request_ref" --question risk="Are release risks acceptable?" \
  --artifact release.txt --blocked-node deploy --now 2026-07-24T10:00:00Z

if env "${common[@]}" "$ROOT/engine/human-gate.sh" approve \
  --node release --request-ref "$request_ref" --approval-ref "$approval_ref" \
  --gate-result-ref "$gate_ref" --approver wrong@example.com --answer risk=yes \
  --evidence review.txt --rationale approved --now 2026-07-24T11:00:00Z >/dev/null 2>&1; then
  echo "wrong owner must be rejected" >&2
  exit 1
fi

if env "${common[@]}" "$ROOT/engine/human-gate.sh" approve \
  --node release --request-ref "$request_ref" --approval-ref "$approval_ref" \
  --gate-result-ref "$gate_ref" --approver owner@example.com \
  --evidence review.txt --rationale approved --now 2026-07-24T11:00:00Z >/dev/null 2>&1; then
  echo "missing required answer must be rejected" >&2
  exit 1
fi

env "${common[@]}" "$ROOT/engine/human-gate.sh" approve \
  --node release --request-ref "$request_ref" --approval-ref "$approval_ref" \
  --gate-result-ref "$gate_ref" --approver owner@example.com --answer risk=yes \
  --evidence review.txt --rationale approved --now 2026-07-24T11:00:00Z >/dev/null

python3 - "$repo/$gate_ref" "$request_ref" "$approval_ref" <<'PY'
import json
import sys

gate = json.load(open(sys.argv[1], encoding="utf-8"))
assert gate["schema"] == "gluerun.orchestration.gate-result.v1"
assert gate["verificationClassification"] == "not-rerun-evidence-verified"
assert gate["humanGateRef"] == sys.argv[2]
assert gate["humanApprovalRef"] == sys.argv[3]
assert gate["blockedNodes"] == ["deploy"]
PY

env "${common[@]}" "$ROOT/engine/human-gate.sh" status \
  --node release --request-ref "$request_ref" --approval-ref "$approval_ref" \
  --now 2026-07-24T12:00:00Z --require-approved >/dev/null

# Malformed request/approval documents fail closed as invalid.  Each mutation
# starts from the same known-good bytes so one defect cannot mask another.
cp "$repo/$request_ref" "$tmp/request.valid.json"
cp "$repo/$approval_ref" "$tmp/approval.valid.json"
assert_invalid() {
  local expected="$1" result
  result="$(env "${common[@]}" "$ROOT/engine/human-gate.sh" status \
    --node release --request-ref "$request_ref" --approval-ref "$approval_ref" \
    --now 2026-07-24T12:00:00Z)"
  python3 - "$result" "$expected" <<'PY'
import json
import sys

record = json.loads(sys.argv[1])
assert record["state"] == "invalid", record
assert sys.argv[2] in record["reason"], record
PY
  cp "$tmp/request.valid.json" "$repo/$request_ref"
  cp "$tmp/approval.valid.json" "$repo/$approval_ref"
}

printf '{malformed\n' >"$repo/$request_ref"
assert_invalid "invalid request document"

python3 - "$repo/$request_ref" "$tmp/request.valid.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[2], encoding="utf-8"))
data.pop("requiredOwner")
json.dump(data, open(sys.argv[1], "w", encoding="utf-8"))
PY
assert_invalid "request missing required fields: requiredOwner"

python3 - "$repo/$request_ref" "$tmp/request.valid.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[2], encoding="utf-8"))
data["questions"][0]["required"] = False
json.dump(data, open(sys.argv[1], "w", encoding="utf-8"))
PY
assert_invalid "request question must be mandatory"

python3 - "$repo/$request_ref" "$tmp/request.valid.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[2], encoding="utf-8"))
data["createdAt"] = data["expiresAt"]
json.dump(data, open(sys.argv[1], "w", encoding="utf-8"))
PY
assert_invalid "request expiry must be after creation"

printf '{malformed\n' >"$repo/$approval_ref"
assert_invalid "invalid approval document"

python3 - "$repo/$approval_ref" "$tmp/approval.valid.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[2], encoding="utf-8"))
data.pop("requestRef")
json.dump(data, open(sys.argv[1], "w", encoding="utf-8"))
PY
assert_invalid "approval missing required fields: requestRef"

python3 - "$repo/$approval_ref" "$tmp/approval.valid.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[2], encoding="utf-8"))
data["requestRef"] = "docs/orchestration/human-gates/another.human-gate.json"
json.dump(data, open(sys.argv[1], "w", encoding="utf-8"))
PY
assert_invalid "approval request reference mismatch"

python3 - "$repo/$approval_ref" "$tmp/approval.valid.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[2], encoding="utf-8"))
data["answers"]["unknown"] = "yes"
json.dump(data, open(sys.argv[1], "w", encoding="utf-8"))
PY
assert_invalid "approval has answer for unknown question"

python3 - "$repo/$approval_ref" "$tmp/approval.valid.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[2], encoding="utf-8"))
data["evidence"] = []
json.dump(data, open(sys.argv[1], "w", encoding="utf-8"))
PY
assert_invalid "approval evidence must be a non-empty array"

python3 - "$repo/$approval_ref" "$tmp/approval.valid.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[2], encoding="utf-8"))
data["approvedAt"] = "2026-07-23T11:00:00Z"
json.dump(data, open(sys.argv[1], "w", encoding="utf-8"))
PY
assert_invalid "approval predates request creation"

cat >"$repo/docs/orchestration/dag.v0.json" <<JSON
{
  "schema": "gluerun.orchestration.dag.v0",
  "nodes": [
    {
      "id": "release",
      "stage": "release",
      "area": "core",
      "layer": "approval",
      "kind": "human-gate",
      "authority": "operator",
      "humanGate": {
        "requestRef": "$request_ref",
        "approvalRef": "$approval_ref"
      },
      "dependsOn": [],
      "requiredCompletion": "owner approves exact artifact"
    },
    {
      "id": "deploy",
      "stage": "deploy",
      "area": "core",
      "layer": "delivery",
      "kind": "work",
      "dependsOn": ["release"],
      "requiredCompletion": "deployment complete"
    }
  ]
}
JSON
frontier="$(env "${common[@]}" GLUERUN_DAG_FILE="$repo/docs/orchestration/dag.v0.json" \
  GLUERUN_GATES_DIR="$repo/docs/orchestration/gates" \
  GLUERUN_GATE_SCHEMA="$ROOT/schemas/gate-result.v0.schema.json" \
  GLUERUN_NOW="$FIXED_NOW" \
  "$ROOT/engine/dag.sh" next-areas --explain)"
python3 - "$frontier" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert [item["node"] for item in data["frontier"]] == ["deploy"]
PY

# v2 DAG evaluation remains backward-compatible with an authoritative v0 record.
cp "$repo/$gate_ref" "$tmp/gate-v1.json"
python3 - "$repo/$gate_ref" <<'PY'
import json
import sys

path = sys.argv[1]
gate = json.load(open(path, encoding="utf-8"))
gate["schema"] = "gluerun.orchestration.gate-result.v0"
for key in (
    "verificationClassification",
    "humanGateRef",
    "humanApprovalRef",
    "blockedNodes",
):
    gate.pop(key, None)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(gate, handle)
    handle.write("\n")
PY
frontier="$(env "${common[@]}" GLUERUN_DAG_FILE="$repo/docs/orchestration/dag.v0.json" \
  GLUERUN_GATES_DIR="$repo/docs/orchestration/gates" \
  GLUERUN_GATE_SCHEMA="$ROOT/schemas/gate-result.v0.schema.json" \
  GLUERUN_GATE_SCHEMA_V1="$ROOT/schemas/gate-result.v1.schema.json" \
  GLUERUN_NOW="$FIXED_NOW" \
  "$ROOT/engine/dag.sh" next-areas --explain)"
python3 - "$frontier" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert [item["node"] for item in data["frontier"]] == ["deploy"]
PY
cp "$tmp/gate-v1.json" "$repo/$gate_ref"

# Approval evidence is hash-bound independently from the approved artifact.
printf 'changed review evidence\n' >"$repo/review.txt"
evidence_state="$(env "${common[@]}" "$ROOT/engine/human-gate.sh" status \
  --node release --request-ref "$request_ref" --approval-ref "$approval_ref" \
  --now 2026-07-24T12:00:00Z)"
python3 - "$evidence_state" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["state"] == "stale"
assert "evidence changed" in data["reason"]
PY
printf 'review notes\n' >"$repo/review.txt"
env "${common[@]}" "$ROOT/engine/human-gate.sh" status \
  --node release --request-ref "$request_ref" --approval-ref "$approval_ref" \
  --now 2026-07-24T12:00:00Z --require-approved >/dev/null

printf 'changed after approval\n' >"$repo/release.txt"
if env "${common[@]}" "$ROOT/engine/human-gate.sh" status \
  --node release --request-ref "$request_ref" --approval-ref "$approval_ref" \
  --now 2026-07-24T12:00:00Z --require-approved >/dev/null 2>&1; then
  echo "artifact change must invalidate approval" >&2
  exit 1
fi

frontier="$(env "${common[@]}" GLUERUN_DAG_FILE="$repo/docs/orchestration/dag.v0.json" \
  GLUERUN_GATES_DIR="$repo/docs/orchestration/gates" \
  GLUERUN_GATE_SCHEMA="$ROOT/schemas/gate-result.v0.schema.json" \
  GLUERUN_NOW="$FIXED_NOW" \
  "$ROOT/engine/dag.sh" next-areas --explain)"
python3 - "$frontier" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["frontier"] == []
reasons = {item["node"]: item["reason"] for item in data["excluded"]}
assert reasons["release"] == "human-gate-stale"
assert reasons["deploy"] == "deps-not-gated"
PY

# Expiry invalidates the approval even if every recorded byte were otherwise
# current, and is surfaced as its own first-class state.
expired_state="$(env "${common[@]}" "$ROOT/engine/human-gate.sh" status \
  --node release --request-ref "$request_ref" --approval-ref "$approval_ref" \
  --now 2026-07-26T12:00:00Z)"
python3 - "$expired_state" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["state"] == "expired"
assert data["reason"] == "request expired"
PY

echo "human gate tests passed"
