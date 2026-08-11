#!/usr/bin/env bash
# Covers the plan-batch source-record projection mapper in
# engine/ctx-graph-project-planbatch.sh — the graph-projector inner layer that
# turns a durable S1 planner session-meta record (the `planner-session-meta/
# planner.out` line carrying `node=`, `runId=`, `stage=`, `area=`, and
# `staged:TASK-*` entries) into a projected context-graph.v0 JSONL node line by
# composing the integrated identity convention + emitters (engine/ctx-graph.sh,
# engine/ctx-graph-project.sh):
#   singular_graph_project_plan_batch <sessionMetaRecordPath> -> one plan-batch node (claim)
#
# Asserts: a fixture session-meta record yields exactly one claim `plan-batch`
# node whose id equals node_id(identity('plan-batch', node, runId)), carrying
# attributes projecting stage/area and the staged-task count; every emitted line
# validates against the SHIPPED schema; fail-safe (a malformed, empty, or missing
# record yields no node and a zero exit — no crash, no partial line); evidence
# invariance (fail-closed — the plan-batch node is claim; no input path mints an
# authoritative node); determinism/idempotence (re-running emits byte-identical
# lines, so singular_graph_canonicalize collapses to the same canonical set); node
# only (the derived_from edge to `goal` is deferred — no durable goal source); and
# OFF-parity/no-writes — sourcing the file invokes nothing and the mapper touches
# NO filesystem.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLANBATCH="$ENGINE_HOME/engine/ctx-graph-project-planbatch.sh"
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
[[ -f "$PLANBATCH" ]] || fail "impl not present yet: $PLANBATCH (strict-test-first RED)"

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
( cd "$snap_dir" && source "$GRAPH" && source "$PROJECT" && source "$PLANBATCH" ) \
  || fail "sourcing $PLANBATCH failed"
after="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail "sourcing $PLANBATCH created filesystem artifacts (OFF-parity)"

# shellcheck disable=SC1090
source "$GRAPH"     || fail "sourcing $GRAPH failed"
# shellcheck disable=SC1090
source "$PROJECT"   || fail "sourcing $PROJECT failed"
# shellcheck disable=SC1090
source "$CORPUS"    || fail "sourcing $CORPUS failed"
# shellcheck disable=SC1090
source "$PLANBATCH" || fail "sourcing $PLANBATCH failed"
[[ "$(type -t singular_graph_project_plan_batch)" == "function" ]] \
  || fail "singular_graph_project_plan_batch is not defined by $PLANBATCH"

# --- minimal schema-driven validator (resolves $ref/$defs + oneOf) -----------
# Mirrors tests/test-ctx-graph-project-records.sh: validates against the SHIPPED file.
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
attr_field() { # <stream-line> <attr-key> -> attributes[key] or ""
  python3 -c 'import json,sys;print(json.load(sys.stdin).get("attributes",{}).get(sys.argv[1],""))' "$1"
}
count_where() { # <stream> <field> <value> -> count of lines whose field==value
  local stream="$1" field="$2" value="$3" c=0 l
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    [[ "$(printf '%s' "$l" | jq_field "$field")" == "$value" ]] && c=$((c+1))
  done <<< "$stream"
  printf '%s' "$c"
}

NODE="graph-projector"
RUN="RUN-20260712T215042Z-34522"

# --- Happy path: a fixture session-meta record yields one plan-batch node -----
# The planner.out record carries the identity/attribute tokens interleaved with
# ordinary planner runner noise, proving the mapper picks the tokens out.
rec="$work_root/planner.out"
cat > "$rec" <<REC
planner: starting run for node graph-projector
node=$NODE
runId=$RUN
stage=S3-graph
area=graph
some noise the runner emitted
staged:TASK-0101
staged:TASK-0102
staged:TASK-0103
planner: done
REC

pb_out="$(singular_graph_project_plan_batch "$rec")" || fail "project_plan_batch failed"
[[ -n "$pb_out" ]] || fail "project_plan_batch produced no output"
printf '%s\n' "$pb_out" | validates || fail "the plan-batch line failed schema validation:
$pb_out"
# Exactly one plan-batch node, no edge (derived_from -> goal is deferred).
[[ "$(count_where "$pb_out" kind node)" == "1" ]] || fail "expected exactly one plan-batch node"
[[ "$(count_where "$pb_out" type plan-batch)" == "1" ]] || fail "node must be type plan-batch"
[[ "$(count_where "$pb_out" kind edge)" == "0" ]] || fail "plan-batch mapper must emit no edge"
# claim — a planner session-meta record is model-authored.
[[ "$(count_where "$pb_out" evidenceClass claim)" == "1" ]] || fail "plan-batch node must be claim"
# Id agreement: node id == node_id(identity('plan-batch', node, runId)).
pb_node="$(singular_graph_node_id "$(singular_graph_identity plan-batch "$NODE" "$RUN")")"
[[ "$(printf '%s' "$pb_out" | jq_field id)" == "$pb_node" ]] \
  || fail "plan-batch node id != node_id(identity('plan-batch', node, runId))"
# attributes project stage/area and the staged-task count.
[[ "$(printf '%s' "$pb_out" | attr_field stage)" == "S3-graph" ]] \
  || fail "plan-batch node must project attributes.stage"
[[ "$(printf '%s' "$pb_out" | attr_field area)" == "graph" ]] \
  || fail "plan-batch node must project attributes.area"
[[ "$(printf '%s' "$pb_out" | attr_field stagedTaskCount)" == "3" ]] \
  || fail "plan-batch node must project attributes.stagedTaskCount"
# Idempotence.
pb_out_b="$(singular_graph_project_plan_batch "$rec")" || fail "second project_plan_batch failed"
[[ "$pb_out" == "$pb_out_b" ]] || fail "project_plan_batch is not idempotent"

# --- Tolerance: a missing optional field is skipped, not fatal ----------------
# A record with node/runId/staged but no stage/area still emits one node; the
# absent attributes are simply omitted.
rec_partial="$work_root/planner-partial.out"
cat > "$rec_partial" <<REC
node=$NODE
runId=$RUN
staged:TASK-0201
REC
pt_out="$(singular_graph_project_plan_batch "$rec_partial")" || fail "project_plan_batch (partial) failed"
[[ "$(count_where "$pt_out" kind node)" == "1" ]] || fail "partial record must still emit one node"
printf '%s\n' "$pt_out" | validates || fail "the partial plan-batch line failed schema validation:
$pt_out"
[[ "$(printf '%s' "$pt_out" | attr_field stagedTaskCount)" == "1" ]] \
  || fail "partial record must project attributes.stagedTaskCount"
[[ -z "$(printf '%s' "$pt_out" | attr_field stage)" ]] \
  || fail "absent stage must be skipped, not emitted"
[[ -z "$(printf '%s' "$pt_out" | attr_field area)" ]] \
  || fail "absent area must be skipped, not emitted"

# --- Fail-safe: malformed, empty, or missing record -> no node, zero exit -----
rec_empty="$work_root/planner-empty.out"; : > "$rec_empty"
es_out="$(singular_graph_project_plan_batch "$rec_empty")"; es_rc=$?
[[ $es_rc -eq 0 ]] || fail "empty record must exit zero (fail-safe), got $es_rc"
[[ -z "$es_out" ]] || fail "empty record must yield no node (no partial line)"

rec_malformed="$work_root/planner-malformed.out"
cat > "$rec_malformed" <<REC
this is not a session-meta record
just some free-form planner chatter
no identifiable node token here
REC
mf_out="$(singular_graph_project_plan_batch "$rec_malformed")"; mf_rc=$?
[[ $mf_rc -eq 0 ]] || fail "malformed record must exit zero (fail-safe), got $mf_rc"
[[ -z "$mf_out" ]] || fail "malformed record must yield no node (no partial line)"

missing_out="$(singular_graph_project_plan_batch "$work_root/does-not-exist.out")"; missing_rc=$?
[[ $missing_rc -eq 0 ]] || fail "missing record must exit zero (fail-safe), got $missing_rc"
[[ -z "$missing_out" ]] || fail "missing record must yield no node (no crash)"

# --- Evidence invariance (fail-closed) ---------------------------------------
# No input path mints an authoritative node — the plan-batch node is a claim.
[[ "$(count_where "$pb_out" evidenceClass authoritative)" == "0" ]] \
  || fail "plan-batch mapper minted an authoritative node (evidence invariance breach)"

# --- Determinism through the canonicalizer: same set collapses identically ----
canon_a="$(printf '%s\n' "$pb_out"   | singular_graph_canonicalize)"
canon_b="$(printf '%s\n' "$pb_out_b" | singular_graph_canonicalize)"
[[ "$canon_a" == "$canon_b" ]] || fail "canonicalize over repeated projection is not stable"
[[ "$(count_where "$canon_a" kind node)" == "1" ]] \
  || fail "re-projected plan-batch node must collapse to one under canonicalize"

# --- No-writes: mapper prints JSONL and touches NO filesystem ------------------
w="$work_root/nowrite"; mkdir -p "$w"
w_before="$(cd "$w" && find . | LC_ALL=C sort)"
( cd "$w" \
  && singular_graph_project_plan_batch "$rec" >/dev/null \
  && singular_graph_project_plan_batch "$rec_empty" >/dev/null )
w_after="$(cd "$w" && find . | LC_ALL=C sort)"
[[ "$w_before" == "$w_after" ]] || fail "the mapper wrote filesystem artifacts (must be pure stdout)"

echo "test-ctx-graph-project-planbatch: all assertions passed"
