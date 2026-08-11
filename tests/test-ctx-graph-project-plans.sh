#!/usr/bin/env bash
# Covers the plan-lifecycle source-record projection mappers in
# engine/ctx-graph-project-plans.sh — the graph-projector inner layer that turns
# integrated durable S0 records (event-log envelopes {type,message,ts,data} and
# plan-critique records) into projected context-graph.v0 JSONL lines by composing
# the integrated identity convention + emitters (engine/ctx-graph.sh,
# engine/ctx-graph-project.sh):
#   singular_graph_project_plan_versions <eventsPath>          -> plan-version nodes (+ revises/supersedes edges)
#   singular_graph_project_decisions     <eventsPath>          -> decision nodes (no edges)
#   singular_graph_project_critique      <planCritiqueRecord>  -> critique node + finding nodes
#
# Asserts: each plan.revised event yields exactly one claim `plan-version` node,
# and with a non-empty data.revisesRunId additionally one `revises` + one
# `supersedes` edge whose `to` equals node_id(identity('plan-version',node,revisesRunId))
# (and none when revisesRunId is empty/absent); each strategy_selected/decision.recorded/
# resume_failed event yields exactly one claim `decision` node and no edge, with
# distinct events (distinct ts) minting distinct ids; the plan-critique record yields
# one claim `critique` node plus one claim `finding` node per findings[] row carrying
# attributes.severity, with ids stable + collision-free per (node,runId,findingId);
# every emitted line validates against the SHIPPED schema; evidence invariance
# (every node claim — no model path mints authoritative); idempotence (re-running
# emits byte-identical lines, so singular_graph_canonicalize collapses to the same
# canonical set); and OFF-parity/no-writes — sourcing the file invokes nothing and
# the mappers touch NO filesystem (pinned by before/after directory snapshots).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLANS="$ENGINE_HOME/engine/ctx-graph-project-plans.sh"
PROJECT="$ENGINE_HOME/engine/ctx-graph-project.sh"
GRAPH="$ENGINE_HOME/engine/ctx-graph.sh"
CORPUS="$ENGINE_HOME/engine/ctx-graph-corpus.sh"
SCHEMA="$ENGINE_HOME/schemas/context-graph.v0.schema.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- strict-test-first RED precondition: fail closed with no impl present -----
[[ -f "$SCHEMA" ]] || fail "missing schema: $SCHEMA"
[[ -f "$GRAPH" ]]  || fail "missing projection primitives: $GRAPH"
[[ -f "$PROJECT" ]] || fail "missing identity convention: $PROJECT"
[[ -f "$CORPUS" ]] || fail "missing corpus writer: $CORPUS"
[[ -f "$PLANS" ]] || fail "impl not present yet: $PLANS (strict-test-first RED)"

# OFF-parity / no-writes: sourcing the file must invoke nothing and write no
# file. Snapshot an empty cwd around the source; confirm SINGULAR_CTX_GRAPH is
# not required (default OFF).
snap_dir="$(mktemp -d)"
VALIDATOR="$(mktemp)"
work_root="$(mktemp -d)"
trap 'rm -rf "$snap_dir" "$VALIDATOR" "$work_root"' EXIT
before="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
unset SINGULAR_CTX_GRAPH 2>/dev/null || true
# shellcheck disable=SC1090
( cd "$snap_dir" && source "$GRAPH" && source "$PROJECT" && source "$PLANS" ) \
  || fail "sourcing $PLANS failed"
after="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail "sourcing $PLANS created filesystem artifacts (OFF-parity)"

# shellcheck disable=SC1090
source "$GRAPH"   || fail "sourcing $GRAPH failed"
# shellcheck disable=SC1090
source "$PROJECT" || fail "sourcing $PROJECT failed"
# shellcheck disable=SC1090
source "$CORPUS"  || fail "sourcing $CORPUS failed"
# shellcheck disable=SC1090
source "$PLANS"   || fail "sourcing $PLANS failed"
for fn in singular_graph_project_plan_versions singular_graph_project_decisions \
          singular_graph_project_critique; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $PLANS"
done

# --- minimal schema-driven validator (resolves $ref/$defs + oneOf) -----------
# Mirrors tests/test-ctx-graph-project.sh: validates against the SHIPPED file.
cat > "$VALIDATOR" <<'PY'
import json, re, sys

def resolve(ref, root):
    node = root
    for part in ref[2:].split("/"):
        node = node[part]
    return node

def validate(data, schema, path, root, errs):
    if "$ref" in schema:
        validate(data, resolve(schema["$ref"], root), path, root, errs); return
    if "oneOf" in schema:
        matches = 0
        for sub in schema["oneOf"]:
            sub_errs = []
            validate(data, sub, path, root, sub_errs)
            if not sub_errs:
                matches += 1
        if matches != 1:
            errs.append(f"{path}: oneOf matched {matches} (want 1)")
        return
    if "const" in schema and data != schema["const"]:
        errs.append(f"{path}: const mismatch")
    if "enum" in schema and data not in schema["enum"]:
        errs.append(f"{path}: not in enum")
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
                validate(v, props[k], f"{path}/{k}", root, errs)
    elif t == "string":
        if not isinstance(data, str):
            errs.append(f"{path}: expected string"); return
        if "minLength" in schema and len(data) < schema["minLength"]:
            errs.append(f"{path}: shorter than minLength")
        if "pattern" in schema and not re.search(schema["pattern"], data):
            errs.append(f"{path}: does not match {schema['pattern']}")

with open(sys.argv[1], "r", encoding="utf-8") as f:
    root = json.load(f)
seen = 0
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        continue
    seen += 1
    data = json.loads(line)
    errs = []
    validate(data, root, "$", root, errs)
    if errs:
        print("\n".join(errs), file=sys.stderr); sys.exit(1)
if seen == 0:
    print("no lines to validate", file=sys.stderr); sys.exit(1)
print("ok")
PY
validates() { python3 "$VALIDATOR" "$SCHEMA" >/dev/null 2>&1; }

# helpers to slice the projected JSONL stream.
jq_field() { python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"; }
count_where() { # <stream> <field> <value> -> count of lines whose field==value
  local stream="$1" field="$2" value="$3" c=0 l
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    [[ "$(printf '%s' "$l" | jq_field "$field")" == "$value" ]] && c=$((c+1))
  done <<< "$stream"
  printf '%s' "$c"
}
lines_where() { # <stream> <field> <value> -> lines whose field==value
  local stream="$1" field="$2" value="$3" l
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    [[ "$(printf '%s' "$l" | jq_field "$field")" == "$value" ]] && printf '%s\n' "$l"
  done <<< "$stream"
}

NODE="TASK-0078"
RUN_A="RUN-20260712T100000Z-00001"
RUN_B="RUN-20260712T110000Z-00002"

# --- Slice 1: plan-version mapper --------------------------------------------
ev_plans="$work_root/events-plans.jsonl"
cat > "$ev_plans" <<JSON
{"ts":"2026-07-12T10:00:00Z","type":"plan.revised","message":"m","data":{"node":"$NODE","runId":"$RUN_A"}}
{"ts":"2026-07-12T11:00:00Z","type":"plan.revised","message":"m","data":{"node":"$NODE","runId":"$RUN_B","revisesRunId":"$RUN_A"}}
{"ts":"2026-07-12T11:05:00Z","type":"context.strategy_selected","message":"noise","data":{"node":"$NODE","runId":"$RUN_B"}}
JSON

pv_out="$(singular_graph_project_plan_versions "$ev_plans")" || fail "project_plan_versions failed"
[[ -n "$pv_out" ]] || fail "project_plan_versions produced no output"
printf '%s\n' "$pv_out" | validates || fail "a plan-version line failed schema validation:
$pv_out"
# Exactly one plan-version node per plan.revised event (2 events -> 2 nodes).
[[ "$(count_where "$pv_out" kind node)" == "2" ]] || fail "expected 2 plan-version nodes"
[[ "$(count_where "$pv_out" type plan-version)" == "2" ]] || fail "nodes must all be type plan-version"
# revisesRunId present on exactly one event -> one revises + one supersedes edge.
[[ "$(count_where "$pv_out" kind edge)" == "2" ]] || fail "expected exactly 2 edges (revises+supersedes)"
[[ "$(count_where "$pv_out" type revises)" == "1" ]] || fail "expected exactly one revises edge"
[[ "$(count_where "$pv_out" type supersedes)" == "1" ]] || fail "expected exactly one supersedes edge"
# Every plan-version node is claim (model-authored source).
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  [[ "$(printf '%s' "$l" | jq_field evidenceClass)" == "claim" ]] \
    || fail "plan-version node must be claim, got: $l"
done <<< "$(lines_where "$pv_out" kind node)"
# Cross-record id agreement: both edges run new-version -> prior-version node id.
nodeA="$(singular_graph_node_id "$(singular_graph_identity plan-version "$NODE" "$RUN_A")")"
nodeB="$(singular_graph_node_id "$(singular_graph_identity plan-version "$NODE" "$RUN_B")")"
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  [[ "$(printf '%s' "$l" | jq_field from)" == "$nodeB" ]] \
    || fail "plan-version edge 'from' != new-version node id: $l"
  [[ "$(printf '%s' "$l" | jq_field to)" == "$nodeA" ]] \
    || fail "plan-version edge 'to' != node_id(identity('plan-version',node,revisesRunId)): $l"
done <<< "$(lines_where "$pv_out" kind edge)"
# The no-revisesRunId event (RUN_A) mints its node but originates NO edge.
[[ "$(lines_where "$pv_out" kind edge | grep -cF "\"from\":\"$nodeA\"")" == "0" ]] \
  || fail "revisesRunId-absent event must emit no revises/supersedes edge"
# Idempotence: re-running over the same source emits byte-identical lines.
pv_out_b="$(singular_graph_project_plan_versions "$ev_plans")" || fail "second project_plan_versions failed"
[[ "$pv_out" == "$pv_out_b" ]] || fail "project_plan_versions is not idempotent"

# --- Slice 2: decision mapper ------------------------------------------------
ev_dec="$work_root/events-decisions.jsonl"
cat > "$ev_dec" <<JSON
{"ts":"2026-07-12T10:00:00Z","type":"context.strategy_selected","message":"m","data":{"node":"$NODE","runId":"$RUN_A"}}
{"ts":"2026-07-12T10:01:00Z","type":"decision.recorded","message":"m","data":{"node":"$NODE","runId":"$RUN_A"}}
{"ts":"2026-07-12T10:02:00Z","type":"context.resume_failed","message":"m","data":{"node":"$NODE","runId":"$RUN_A"}}
{"ts":"2026-07-12T10:03:00Z","type":"decision.recorded","message":"m","data":{"node":"$NODE","runId":"$RUN_A"}}
{"ts":"2026-07-12T10:04:00Z","type":"plan.revised","message":"noise","data":{"node":"$NODE","runId":"$RUN_A"}}
JSON

dec_out="$(singular_graph_project_decisions "$ev_dec")" || fail "project_decisions failed"
[[ -n "$dec_out" ]] || fail "project_decisions produced no output"
printf '%s\n' "$dec_out" | validates || fail "a decision line failed schema validation:
$dec_out"
# One decision node per matching event (4 matches -> 4 nodes), no edges.
[[ "$(count_where "$dec_out" kind node)" == "4" ]] || fail "expected 4 decision nodes"
[[ "$(count_where "$dec_out" type decision)" == "4" ]] || fail "nodes must all be type decision"
[[ "$(count_where "$dec_out" kind edge)" == "0" ]] || fail "decision mapper must emit no edge"
# Every decision node is claim.
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  [[ "$(printf '%s' "$l" | jq_field evidenceClass)" == "claim" ]] \
    || fail "decision node must be claim, got: $l"
done <<< "$(lines_where "$dec_out" kind node)"
# Distinct events (incl. two decision.recorded differing only by ts) -> distinct ids.
distinct_ids="$(lines_where "$dec_out" kind node | while IFS= read -r l; do
  [[ -n "$l" ]] && printf '%s\n' "$l" | jq_field id
done | LC_ALL=C sort -u | grep -c .)"
[[ "$distinct_ids" == "4" ]] || fail "decision ids not collision-free per (type,node,runId,ts): got $distinct_ids"
# Idempotence.
dec_out_b="$(singular_graph_project_decisions "$ev_dec")" || fail "second project_decisions failed"
[[ "$dec_out" == "$dec_out_b" ]] || fail "project_decisions is not idempotent"

# --- Slice 3: critique/finding mapper ----------------------------------------
crit="$work_root/plan-critique.json"
FID1="f-0123456789ab"
FID2="f-abcdef012345"
cat > "$crit" <<JSON
{
  "schema": "singular.orchestration.plan-critique.v0",
  "node": "$NODE",
  "runId": "$RUN_A",
  "batchTaskIds": ["TASK-0078"],
  "verdict": "revise",
  "findings": [
    { "id": "$FID1", "severity": "blocking", "claim": "c1", "evidence": "e1" },
    { "id": "$FID2", "severity": "note", "claim": "c2", "evidence": "e2" }
  ],
  "assumptionsChallenged": [],
  "rationale": "r"
}
JSON

cr_out="$(singular_graph_project_critique "$crit")" || fail "project_critique failed"
[[ -n "$cr_out" ]] || fail "project_critique produced no output"
printf '%s\n' "$cr_out" | validates || fail "a critique line failed schema validation:
$cr_out"
# Exactly one critique node + one finding node per findings[] row (2 rows).
[[ "$(count_where "$cr_out" type critique)" == "1" ]] || fail "expected exactly one critique node"
[[ "$(count_where "$cr_out" type finding)" == "2" ]] || fail "expected exactly two finding nodes"
[[ "$(count_where "$cr_out" kind edge)" == "0" ]] || fail "critique mapper must emit no edge"
# Every node is claim.
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  [[ "$(printf '%s' "$l" | jq_field evidenceClass)" == "claim" ]] \
    || fail "critique/finding node must be claim, got: $l"
done <<< "$(lines_where "$cr_out" kind node)"
# Finding ids are stable + collision-free per (node,runId,findingId) and carry severity.
finding1_node="$(singular_graph_node_id "$(singular_graph_identity finding "$NODE" "$RUN_A" "$FID1")")"
finding2_node="$(singular_graph_node_id "$(singular_graph_identity finding "$NODE" "$RUN_A" "$FID2")")"
[[ "$finding1_node" != "$finding2_node" ]] || fail "distinct findingId produced identical node id"
printf '%s\n' "$cr_out" | grep -qF "\"id\":\"$finding1_node\"" \
  || fail "finding node id != node_id(identity('finding',node,runId,findingId)) for f1"
printf '%s\n' "$cr_out" | grep -qF "\"id\":\"$finding2_node\"" \
  || fail "finding node id != node_id(identity('finding',node,runId,findingId)) for f2"
# attributes.severity projected onto each finding node.
sev1="$(printf '%s\n' "$cr_out" | grep -F "\"id\":\"$finding1_node\"" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("attributes",{}).get("severity",""))')"
[[ "$sev1" == "blocking" ]] || fail "finding f1 must project attributes.severity=blocking, got '$sev1'"
sev2="$(printf '%s\n' "$cr_out" | grep -F "\"id\":\"$finding2_node\"" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("attributes",{}).get("severity",""))')"
[[ "$sev2" == "note" ]] || fail "finding f2 must project attributes.severity=note, got '$sev2'"
# Idempotence.
cr_out_b="$(singular_graph_project_critique "$crit")" || fail "second project_critique failed"
[[ "$cr_out" == "$cr_out_b" ]] || fail "project_critique is not idempotent"

# --- Evidence invariance (fail-closed): NO model path mints authoritative ------
for stream in "$pv_out" "$dec_out" "$cr_out"; do
  [[ "$(count_where "$stream" evidenceClass authoritative)" == "0" ]] \
    || fail "a plan-lifecycle mapper minted an authoritative node (evidence invariance breach)"
done

# --- Determinism through the canonicalizer: same set collapses identically -----
canon_a="$(printf '%s\n' "$pv_out" | singular_graph_canonicalize)"
canon_b="$(printf '%s\n' "$pv_out_b" | singular_graph_canonicalize)"
[[ "$canon_a" == "$canon_b" ]] || fail "canonicalize over repeated projection is not stable"

# --- No-writes: mappers print JSONL and touch NO filesystem -------------------
w="$work_root/nowrite"; mkdir -p "$w"
w_before="$(cd "$w" && find . | LC_ALL=C sort)"
( cd "$w" \
  && singular_graph_project_plan_versions "$ev_plans" >/dev/null \
  && singular_graph_project_decisions "$ev_dec" >/dev/null \
  && singular_graph_project_critique "$crit" >/dev/null )
w_after="$(cd "$w" && find . | LC_ALL=C sort)"
[[ "$w_before" == "$w_after" ]] || fail "a mapper wrote filesystem artifacts (must be pure stdout)"

echo "test-ctx-graph-project-plans: all assertions passed"
