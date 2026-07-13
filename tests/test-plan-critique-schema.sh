#!/usr/bin/env bash
# Contract test for schemas/plan-critique.v0.schema.json — the plan-critic
# batch verdict emitted by the S2-plan-critique skeptic node. Fail-closed:
# the schema is an additive, closed object (additionalProperties:false) under
# the gluerun.orchestration.*.v0 namespace, and every invalid class below is
# rejected. Stable finding identity mirrors gluerun_finding_id in engine/lib.sh.
#
# No jsonschema module ships in this environment, so this test carries a tiny
# schema-driven validator (const/enum/pattern/minLength/required/additional
# Properties/items) that reads the ACTUAL schema file — fixtures are checked
# against the shipped contract, not a hand-rolled copy of it.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA="$ENGINE_HOME/schemas/plan-critique.v0.schema.json"
PROMPT="$ENGINE_HOME/templates/prompts/plan-critic.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Source the engine helper that mints stable finding ids.
source "$ENGINE_HOME/engine/lib.sh"

[[ -f "$SCHEMA" ]] || fail "missing schema: $SCHEMA"

# --- minimal schema-driven validator -----------------------------------------
VALIDATOR="$(mktemp)"
trap 'rm -f "$VALIDATOR"' EXIT
cat > "$VALIDATOR" <<'PY'
import json, re, sys

def validate(data, schema, path, errs):
    if "const" in schema and data != schema["const"]:
        errs.append(f"{path}: const mismatch")
    if "enum" in schema and data not in schema["enum"]:
        errs.append(f"{path}: not in enum {schema['enum']}")
    t = schema.get("type")
    if t == "object":
        if not isinstance(data, dict):
            errs.append(f"{path}: expected object"); return
        for r in schema.get("required", []):
            if r not in data:
                errs.append(f"{path}: missing required '{r}'")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for k in data:
                if k not in props:
                    errs.append(f"{path}: unknown property '{k}'")
        for k, v in data.items():
            if k in props:
                validate(v, props[k], f"{path}/{k}", errs)
    elif t == "array":
        if not isinstance(data, list):
            errs.append(f"{path}: expected array"); return
        items = schema.get("items")
        if items is not None:
            for i, el in enumerate(data):
                validate(el, items, f"{path}[{i}]", errs)
    elif t == "string":
        if not isinstance(data, str):
            errs.append(f"{path}: expected string"); return
        if "minLength" in schema and len(data) < schema["minLength"]:
            errs.append(f"{path}: shorter than minLength {schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], data):
            errs.append(f"{path}: does not match {schema['pattern']}")

with open(sys.argv[1], "r", encoding="utf-8") as f:
    schema = json.load(f)
data = json.load(sys.stdin)
errs = []
validate(data, schema, "$", errs)
if errs:
    print("\n".join(errs), file=sys.stderr)
    sys.exit(1)
print("ok")
PY

validates() { python3 "$VALIDATOR" "$SCHEMA" >/dev/null 2>&1; }
assert_valid()   { printf '%s' "$1" | validates || fail "$2: should VALIDATE but did not"; }
assert_invalid() { printf '%s' "$1" | validates && fail "$2: should be REJECTED but validated"; return 0; }

# Stable finding id derived from claim text via the engine helper.
FID="$(gluerun_finding_id 'Batch slices TASK-0007 and TASK-0008 with a hidden ordering coupling')"
[[ "$FID" =~ ^f-[0-9a-f]{12}$ ]] || fail "gluerun_finding_id shape unexpected: $FID"

# --- fully-populated valid fixture (verdict approve, real finding id) ---------
valid_fixture() { # verdict
  cat <<JSON
{
  "schema": "gluerun.orchestration.plan-critique.v0",
  "node": "some-dag-node",
  "runId": "RUN-20260711T000000Z-00001",
  "batchTaskIds": ["TASK-0007", "TASK-0008"],
  "verdict": "${1:-approve}",
  "findings": [
    {
      "id": "$FID",
      "severity": "blocking",
      "claim": "Batch slices TASK-0007 and TASK-0008 with a hidden ordering coupling",
      "evidence": "docs/orchestration/tasks/TASK-0008.md owned files overlap TASK-0007",
      "suggestedChange": "Merge the two tasks or declare an explicit dependsOn edge"
    },
    {
      "id": "f-0123456789ab",
      "severity": "note",
      "claim": "Acceptance criteria for TASK-0007 lack a testable assertion",
      "evidence": "no gate command references the new schema"
    }
  ],
  "assumptionsChallenged": ["assumes TASK-0007 lands before TASK-0008"],
  "rationale": "Slicing is sound overall; the ordering coupling must be made explicit."
}
JSON
}

assert_valid "$(valid_fixture approve)" "fully-populated approve fixture"

# --- each verdict validates; any other verdict is rejected --------------------
assert_valid   "$(valid_fixture approve)" "verdict approve"
assert_valid   "$(valid_fixture revise)"  "verdict revise"
assert_valid   "$(valid_fixture park)"    "verdict park"
assert_invalid "$(valid_fixture reject)"  "verdict reject (not in enum)"

# --- suggestedChange is optional (present above; absent in 2nd finding) -------
# The 2nd finding of valid_fixture omits suggestedChange and the whole fixture
# validated above, so both branches are exercised by the approve fixture.

# --- invalid classes, one fixture each ---------------------------------------

# (a) missing a required top-level field (rationale)
assert_invalid '{
  "schema": "gluerun.orchestration.plan-critique.v0",
  "node": "n", "runId": "RUN-1", "batchTaskIds": ["TASK-0007"],
  "verdict": "approve", "findings": [], "assumptionsChallenged": []
}' "missing required rationale"

# (b) unknown extra top-level field (closed object)
assert_invalid '{
  "schema": "gluerun.orchestration.plan-critique.v0",
  "node": "n", "runId": "RUN-1", "batchTaskIds": ["TASK-0007"],
  "verdict": "approve", "findings": [], "assumptionsChallenged": [],
  "rationale": "ok", "extraField": "nope"
}' "unknown extra top-level field"

# (c) finding severity outside blocking | should-fix | note
assert_invalid '{
  "schema": "gluerun.orchestration.plan-critique.v0",
  "node": "n", "runId": "RUN-1", "batchTaskIds": ["TASK-0007"],
  "verdict": "approve",
  "findings": [{"id":"f-0123456789ab","severity":"critical","claim":"c","evidence":"e"}],
  "assumptionsChallenged": [], "rationale": "ok"
}' "finding severity out of enum"

# (d) finding id not matching ^f-[0-9a-f]{12}$
assert_invalid '{
  "schema": "gluerun.orchestration.plan-critique.v0",
  "node": "n", "runId": "RUN-1", "batchTaskIds": ["TASK-0007"],
  "verdict": "approve",
  "findings": [{"id":"F-XYZ","severity":"note","claim":"c","evidence":"e"}],
  "assumptionsChallenged": [], "rationale": "ok"
}' "finding id bad pattern"

# (e) finding missing claim
assert_invalid '{
  "schema": "gluerun.orchestration.plan-critique.v0",
  "node": "n", "runId": "RUN-1", "batchTaskIds": ["TASK-0007"],
  "verdict": "approve",
  "findings": [{"id":"f-0123456789ab","severity":"note","evidence":"e"}],
  "assumptionsChallenged": [], "rationale": "ok"
}' "finding missing claim"

# (f) finding missing evidence
assert_invalid '{
  "schema": "gluerun.orchestration.plan-critique.v0",
  "node": "n", "runId": "RUN-1", "batchTaskIds": ["TASK-0007"],
  "verdict": "approve",
  "findings": [{"id":"f-0123456789ab","severity":"note","claim":"c"}],
  "assumptionsChallenged": [], "rationale": "ok"
}' "finding missing evidence"

# (g) batchTaskIds entry not matching ^TASK-[0-9]{4,}$
assert_invalid '{
  "schema": "gluerun.orchestration.plan-critique.v0",
  "node": "n", "runId": "RUN-1", "batchTaskIds": ["TASK-7"],
  "verdict": "approve", "findings": [], "assumptionsChallenged": [], "rationale": "ok"
}' "batchTaskIds bad pattern"

# --- stable finding identity: formatting variants map to the same id ----------
id_a="$(gluerun_finding_id 'Parser drops nil input')"
id_b="$(gluerun_finding_id '  parser   DROPS nil INPUT  ')"
[[ "$id_a" == "$id_b" ]] || fail "finding id not stable across formatting: $id_a vs $id_b"
assert_valid "{
  \"schema\": \"gluerun.orchestration.plan-critique.v0\",
  \"node\": \"n\", \"runId\": \"RUN-1\", \"batchTaskIds\": [\"TASK-0007\"],
  \"verdict\": \"revise\",
  \"findings\": [{\"id\":\"$id_a\",\"severity\":\"should-fix\",\"claim\":\"Parser drops nil input\",\"evidence\":\"engine/parse.sh line 12\"}],
  \"assumptionsChallenged\": [], \"rationale\": \"reproducible id\"
}" "derived gluerun_finding_id validates against pattern"

# --- prompt exists, is the plan-batch skeptic, and is present-but-unwired -----
[[ -f "$PROMPT" ]] || fail "missing prompt: $PROMPT"
grep -qi "skeptic" "$PROMPT" || fail "plan-critic.md must frame the critic as a skeptic"
grep -qi "read-only" "$PROMPT" || fail "plan-critic.md must instruct read-only repo access"
grep -q "plan-critique.v0.schema.json" "$PROMPT" \
  || fail "plan-critic.md must point its final JSON at the schema"

# No engine/CLI/driver path may reference the prompt yet (contract-node gate).
wired="$(grep -rl "plan-critic.md" "$ENGINE_HOME/engine" "$ENGINE_HOME/cli" 2>/dev/null || true)"
[[ -z "$wired" ]] || fail "plan-critic.md must be unwired but is referenced by: $wired"

echo "test-plan-critique-schema: all assertions passed"
