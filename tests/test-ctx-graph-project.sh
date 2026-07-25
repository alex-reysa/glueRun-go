#!/usr/bin/env bash
# Covers the first source-record projection mappers in engine/ctx-graph-project.sh
# — the graph-projector inner layer that turns integrated durable S0 records into
# projected context-graph.v0 JSONL lines by composing slice-1 identity + the
# integrated emitters (engine/ctx-graph.sh):
#   gluerun_graph_identity            <type> <key...>       -> canonical identity STRING
#   gluerun_graph_project_attempts    <attemptsIndexPath>   -> attempt nodes + implements edges
#   gluerun_graph_project_gate_results <gateRecordPath>     -> gate-result node + verify/invalidate edge
#
# Asserts: identity is pure/deterministic (byte-identical for identical inputs,
# distinct for distinct source records, distinct across types); ids minted via
# gluerun_graph_node_id(identity) AGREE across mappers (an implements edge's `to`
# equals node_id(identity('task', taskId))); the attempts mapper yields exactly one
# claim `attempt` node + one `implements` edge per row; the gate-result mapper yields
# one authoritative `gate-result` node for every status plus a `verifies` edge on
# `passed` and an `invalidates` edge on `failed` (and no verify/invalidate edge on
# `proposed`/`blocked`) to the decided target's node id; every emitted line validates
# against the SHIPPED schema; evidence invariance (attempt=claim, gate-result=
# authoritative, no model path mints authoritative); idempotence (re-running emits
# byte-identical lines); and OFF-parity/no-writes — sourcing the file invokes nothing
# and the mappers touch NO filesystem (pinned by before/after directory snapshots).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ENGINE_HOME/engine/ctx-graph-project.sh"
GRAPH="$ENGINE_HOME/engine/ctx-graph.sh"
SCHEMA="$ENGINE_HOME/schemas/context-graph.v0.schema.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- strict-test-first RED precondition: fail closed with no impl present -----
[[ -f "$SCHEMA" ]] || fail "missing schema: $SCHEMA"
[[ -f "$GRAPH" ]]  || fail "missing projection primitives: $GRAPH"
[[ -f "$PROJECT" ]] || fail "impl not present yet: $PROJECT (strict-test-first RED)"

# OFF-parity / no-writes: sourcing the file must invoke nothing and write no
# file. Snapshot an empty cwd around the source; confirm GLUERUN_CTX_GRAPH is
# not required (default OFF).
snap_dir="$(mktemp -d)"
VALIDATOR="$(mktemp)"
work_root="$(mktemp -d)"
trap 'rm -rf "$snap_dir" "$VALIDATOR" "$work_root"' EXIT
before="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
unset GLUERUN_CTX_GRAPH 2>/dev/null || true
# shellcheck disable=SC1090
( cd "$snap_dir" && source "$GRAPH" && source "$PROJECT" ) \
  || fail "sourcing $PROJECT failed"
after="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail "sourcing $PROJECT created filesystem artifacts (OFF-parity)"

# shellcheck disable=SC1090
source "$GRAPH"   || fail "sourcing $GRAPH failed"
# shellcheck disable=SC1090
source "$PROJECT" || fail "sourcing $PROJECT failed"
for fn in gluerun_graph_identity gluerun_graph_project_attempts \
          gluerun_graph_project_gate_results; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $PROJECT"
done

# --- minimal schema-driven validator (resolves $ref/$defs + oneOf) -----------
# Mirrors tests/test-ctx-graph.sh: validates against the SHIPPED file.
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

# --- Slice 1: identity convention --------------------------------------------
# Pure + deterministic: identical inputs -> byte-identical strings.
i_task="$(gluerun_graph_identity task TASK-0001)"
i_task_b="$(gluerun_graph_identity task TASK-0001)"
[[ "$i_task" == "$i_task_b" ]] || fail "identity not deterministic: '$i_task' vs '$i_task_b'"
# Distinct source records -> distinct strings.
[[ "$i_task" != "$(gluerun_graph_identity task TASK-0002)" ]] \
  || fail "distinct task key produced identical identity"
[[ "$(gluerun_graph_identity attempt RUN-1 1)" != "$(gluerun_graph_identity attempt RUN-1 2)" ]] \
  || fail "distinct attempt n produced identical identity"
[[ "$(gluerun_graph_identity attempt RUN-1 1)" != "$(gluerun_graph_identity attempt RUN-2 1)" ]] \
  || fail "distinct runId produced identical attempt identity"
# Type is part of the identity: same key, different type -> distinct.
[[ "$(gluerun_graph_identity task X)" != "$(gluerun_graph_identity attempt X)" ]] \
  || fail "type not part of identity"
# Minted node ids are stable and shape-correct.
[[ "$(gluerun_graph_node_id "$i_task")" =~ ^n-[0-9a-f]{12}$ ]] \
  || fail "node id from identity has bad shape"

# --- Slice 2: attempts mapper ------------------------------------------------
RUN_ID="RUN-20260712T154843Z-36590"
TASK_ID="TASK-0076"
idx="$work_root/attempts-index.json"
cat > "$idx" <<JSON
{
  "schema": "gluerun.orchestration.attempts-index.v0",
  "runId": "$RUN_ID",
  "taskId": "$TASK_ID",
  "attempts": [
    { "n": 1, "status": "failed", "headSha": "aaa" },
    { "n": 2, "status": "needs-review", "headSha": "bbb" },
    { "n": 3, "status": "passed", "headSha": "ccc" }
  ]
}
JSON

att_out="$(gluerun_graph_project_attempts "$idx")" || fail "project_attempts failed"
[[ -n "$att_out" ]] || fail "project_attempts produced no output"
# Every emitted line validates against the shipped schema.
printf '%s\n' "$att_out" | validates || fail "an attempts line failed schema validation:
$att_out"
# Exactly one attempt node + one implements edge per row (3 rows -> 3 + 3).
[[ "$(count_where "$att_out" kind node)" == "3" ]] || fail "expected 3 attempt nodes"
[[ "$(count_where "$att_out" kind edge)" == "3" ]] || fail "expected 3 implements edges"
[[ "$(count_where "$att_out" type attempt)" == "3" ]] || fail "nodes must all be type 'attempt'"
[[ "$(count_where "$att_out" type implements)" == "3" ]] || fail "edges must all be type 'implements'"
# Every attempt node is evidenceClass claim (model-authored source).
node_lines="$(printf '%s\n' "$att_out" | while IFS= read -r l; do
  [[ -n "$l" ]] && [[ "$(printf '%s' "$l" | jq_field kind)" == node ]] && printf '%s\n' "$l"
done)"
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  [[ "$(printf '%s' "$l" | jq_field evidenceClass)" == "claim" ]] \
    || fail "attempt node must be claim, got: $l"
done <<< "$node_lines"
# Cross-mapper id agreement: every implements edge points at the task node id.
task_node="$(gluerun_graph_node_id "$(gluerun_graph_identity task "$TASK_ID")")"
edge_lines="$(printf '%s\n' "$att_out" | while IFS= read -r l; do
  [[ -n "$l" ]] && [[ "$(printf '%s' "$l" | jq_field kind)" == edge ]] && printf '%s\n' "$l"
done)"
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  [[ "$(printf '%s' "$l" | jq_field to)" == "$task_node" ]] \
    || fail "implements edge 'to' != node_id(identity('task',taskId)): $l"
done <<< "$edge_lines"
# Each edge 'from' equals a minted attempt node id (n=1 in particular).
attempt1_node="$(gluerun_graph_node_id "$(gluerun_graph_identity attempt "$RUN_ID" 1)")"
printf '%s\n' "$edge_lines" | grep -qF "\"from\":\"$attempt1_node\"" \
  || fail "no implements edge originates from the n=1 attempt node id"
# Idempotence: re-running over the same source emits byte-identical lines.
att_out_b="$(gluerun_graph_project_attempts "$idx")" || fail "second project_attempts failed"
[[ "$att_out" == "$att_out_b" ]] || fail "project_attempts is not idempotent"

# --- Slice 3: gate-result mapper ---------------------------------------------
gate_record() { # <status> -> path to a valid gluerun.orchestration.gate-result.v0
  local st="$1" p="$work_root/gate-$1.json"
  cat > "$p" <<JSON
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "$TASK_ID",
  "status": "$st",
  "authoritative": true,
  "evidenceClass": "deterministic-proof",
  "evidence": [
    { "kind": "command-log", "ref": "log", "command": "bash tests/x.sh", "exitCode": 0, "logRef": "x" }
  ],
  "decidedBy": "host",
  "recordedAt": "2026-07-12T15:48:43Z"
}
JSON
  printf '%s' "$p"
}

# passed -> node (authoritative) + verifies edge to the decided target.
gp="$(gate_record passed)"
g_pass="$(gluerun_graph_project_gate_results "$gp")" || fail "project_gate_results(passed) failed"
printf '%s\n' "$g_pass" | validates || fail "gate-result(passed) line failed validation:
$g_pass"
[[ "$(count_where "$g_pass" kind node)" == "1" ]] || fail "passed: expected 1 gate-result node"
[[ "$(count_where "$g_pass" type gate-result)" == "1" ]] || fail "passed: node must be type gate-result"
[[ "$(count_where "$g_pass" evidenceClass authoritative)" == "1" ]] \
  || fail "gate-result node must be authoritative (host-verified source)"
[[ "$(count_where "$g_pass" type verifies)" == "1" ]] || fail "passed: expected exactly one verifies edge"
[[ "$(count_where "$g_pass" type invalidates)" == "0" ]] || fail "passed: must not emit invalidates"
# verify edge points at the decided target (task) node id.
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  [[ "$(printf '%s' "$l" | jq_field kind)" == edge ]] || continue
  [[ "$(printf '%s' "$l" | jq_field to)" == "$task_node" ]] \
    || fail "verifies edge 'to' != decided target node id: $l"
done <<< "$g_pass"
# Idempotence.
g_pass_b="$(gluerun_graph_project_gate_results "$gp")" || fail "second gate_results(passed) failed"
[[ "$g_pass" == "$g_pass_b" ]] || fail "project_gate_results is not idempotent"

# acknowledged-baseline pass -> verifies edge too (v1 success classification).
ga="$(gate_record passed-with-acknowledged-baseline)"
g_ack="$(gluerun_graph_project_gate_results "$ga")" \
  || fail "project_gate_results(passed-with-acknowledged-baseline) failed"
printf '%s\n' "$g_ack" | validates \
  || fail "gate-result(passed-with-acknowledged-baseline) line failed validation: $g_ack"
[[ "$(count_where "$g_ack" type verifies)" == "1" ]] \
  || fail "acknowledged-baseline pass: expected exactly one verifies edge"
[[ "$(count_where "$g_ack" type invalidates)" == "0" ]] \
  || fail "acknowledged-baseline pass: must not emit invalidates"

# failed -> node + invalidates edge (no verifies).
gf="$(gate_record failed)"
g_fail="$(gluerun_graph_project_gate_results "$gf")" || fail "project_gate_results(failed) failed"
printf '%s\n' "$g_fail" | validates || fail "gate-result(failed) line failed validation:
$g_fail"
[[ "$(count_where "$g_fail" type gate-result)" == "1" ]] || fail "failed: expected gate-result node"
[[ "$(count_where "$g_fail" type invalidates)" == "1" ]] || fail "failed: expected exactly one invalidates edge"
[[ "$(count_where "$g_fail" type verifies)" == "0" ]] || fail "failed: must not emit verifies"

# proposed / blocked -> node only, no verify/invalidate edge.
for st in proposed blocked; do
  grec="$(gate_record "$st")"
  g_out="$(gluerun_graph_project_gate_results "$grec")" || fail "project_gate_results($st) failed"
  printf '%s\n' "$g_out" | validates || fail "gate-result($st) line failed validation: $g_out"
  [[ "$(count_where "$g_out" kind node)" == "1" ]] || fail "$st: expected exactly one node"
  [[ "$(count_where "$g_out" type gate-result)" == "1" ]] || fail "$st: node must be gate-result"
  [[ "$(count_where "$g_out" kind edge)" == "0" ]] || fail "$st: must emit no edge"
  [[ "$(count_where "$g_out" evidenceClass authoritative)" == "1" ]] \
    || fail "$st: gate-result node must be authoritative"
done

# --- Evidence invariance (fail-closed): no model path mints authoritative -----
# The attempts stream (model-authored source) contains ZERO authoritative lines.
[[ "$(count_where "$att_out" evidenceClass authoritative)" == "0" ]] \
  || fail "attempts mapper minted an authoritative node (evidence invariance breach)"

# --- No-writes: mappers print JSONL and touch NO filesystem -------------------
w="$work_root/nowrite"; mkdir -p "$w"
w_before="$(cd "$w" && find . | LC_ALL=C sort)"
( cd "$w" \
  && gluerun_graph_project_attempts "$idx" >/dev/null \
  && gluerun_graph_project_gate_results "$gp" >/dev/null )
w_after="$(cd "$w" && find . | LC_ALL=C sort)"
[[ "$w_before" == "$w_after" ]] || fail "a mapper wrote filesystem artifacts (must be pure stdout)"

echo "test-ctx-graph-project: all assertions passed"
