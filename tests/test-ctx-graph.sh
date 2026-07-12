#!/usr/bin/env bash
# Covers the deterministic pure-projection primitives in engine/ctx-graph.sh —
# the atom every later graph-projector capability composes:
#   gluerun_graph_content_hash  source content            -> sha256:<64-hex>
#   gluerun_graph_node_id       source-record identity    -> n-<12-hex>
#   gluerun_graph_edge_id       (fromId, edgeType, toId)  -> e-<12-hex>
#   gluerun_graph_emit_node     -> one nodes.jsonl line valid vs the shipped schema
#   gluerun_graph_emit_edge     -> one edges.jsonl line valid vs the shipped schema
#
# Asserts: byte-identical output for identical input and distinct output for
# distinct identities; the id/hash shapes; fail-closed evidenceClass
# (authoritative ONLY for commit/gate-result, claim for every other type
# including audit); the emitted edge id == gluerun_graph_edge_id(from,type,to);
# schema validity of every emitted line (via a tiny schema-driven validator that
# reads the ACTUAL shipped schema, mirroring test-context-graph-schema.sh); and
# OFF-parity/no-writes — sourcing the file and calling the emitters creates no
# filesystem artifact (pinned behaviorally by a before/after directory snapshot,
# not a temporal absence-grep).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTX_GRAPH="$ENGINE_HOME/engine/ctx-graph.sh"
SCHEMA="$ENGINE_HOME/schemas/context-graph.v0.schema.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- strict-test-first RED precondition: fail closed with no impl present -----
[[ -f "$SCHEMA" ]] || fail "missing schema: $SCHEMA"
[[ -f "$CTX_GRAPH" ]] || fail "impl not present yet: $CTX_GRAPH (strict-test-first RED)"

# OFF-parity / no-writes: sourcing the file must invoke nothing and write no
# file. Snapshot an empty cwd around the source, and confirm GLUERUN_CTX_GRAPH is
# not required (default OFF).
snap_dir="$(mktemp -d)"
trap 'rm -rf "$snap_dir" "$VALIDATOR"' EXIT
before="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
unset GLUERUN_CTX_GRAPH 2>/dev/null || true
# shellcheck disable=SC1090
( cd "$snap_dir" && source "$CTX_GRAPH" ) || fail "sourcing $CTX_GRAPH failed"
after="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail "sourcing $CTX_GRAPH created filesystem artifacts (OFF-parity)"

# shellcheck disable=SC1090
source "$CTX_GRAPH" || fail "sourcing $CTX_GRAPH failed"
for fn in gluerun_graph_content_hash gluerun_graph_node_id gluerun_graph_edge_id \
          gluerun_graph_emit_node gluerun_graph_emit_edge; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $CTX_GRAPH"
done

# --- Slice 1: deterministic identity primitives ------------------------------

# content hash: shape + determinism + distinctness
h1="$(gluerun_graph_content_hash 'canonical content A')"
h1b="$(gluerun_graph_content_hash 'canonical content A')"
h2="$(gluerun_graph_content_hash 'canonical content B')"
[[ "$h1" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "content hash bad shape: '$h1'"
[[ "$h1" == "$h1b" ]] || fail "content hash not deterministic: '$h1' vs '$h1b'"
[[ "$h1" != "$h2" ]] || fail "distinct content produced identical hash"

# node id: shape + determinism + distinctness
n1="$(gluerun_graph_node_id 'task:TASK-0001')"
n1b="$(gluerun_graph_node_id 'task:TASK-0001')"
n2="$(gluerun_graph_node_id 'task:TASK-0002')"
[[ "$n1" =~ ^n-[0-9a-f]{12}$ ]] || fail "node id bad shape: '$n1'"
[[ "$n1" == "$n1b" ]] || fail "node id not deterministic: '$n1' vs '$n1b'"
[[ "$n1" != "$n2" ]] || fail "distinct node identity produced identical id"

# edge id: shape + determinism + distinctness (each triple slot matters)
e1="$(gluerun_graph_edge_id "$n1" implements "$n2")"
e1b="$(gluerun_graph_edge_id "$n1" implements "$n2")"
e_type="$(gluerun_graph_edge_id "$n1" verifies "$n2")"
e_dir="$(gluerun_graph_edge_id "$n2" implements "$n1")"
[[ "$e1" =~ ^e-[0-9a-f]{12}$ ]] || fail "edge id bad shape: '$e1'"
[[ "$e1" == "$e1b" ]] || fail "edge id not deterministic: '$e1' vs '$e1b'"
[[ "$e1" != "$e_type" ]] || fail "distinct edge type produced identical id"
[[ "$e1" != "$e_dir" ]]  || fail "edge id is not direction-sensitive (from/to swapped)"

# --- minimal schema-driven validator (resolves $ref/$defs + oneOf) -----------
# Mirrors tests/test-context-graph-schema.sh: validates against the SHIPPED file.
VALIDATOR="$(mktemp)"
cat > "$VALIDATOR" <<'PY'
import json, re, sys

def resolve(ref, root):
    if not ref.startswith("#/"):
        raise ValueError("only local $ref supported: %s" % ref)
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
data = json.load(sys.stdin)
errs = []
validate(data, root, "$", root, errs)
if errs:
    print("\n".join(errs), file=sys.stderr); sys.exit(1)
print("ok")
PY
validates() { python3 "$VALIDATOR" "$SCHEMA" >/dev/null 2>&1; }

# --- Slice 2: node emitter ---------------------------------------------------

# A claim-class node (finding): validates, correct id + hash, evidenceClass claim.
node_line="$(gluerun_graph_emit_node finding 'finding:F1' 'docs/critique/F1.md' \
             'the finding body' 'a finding')"
[[ -n "$node_line" ]] || fail "emit_node produced no output"
printf '%s' "$node_line" | validates || fail "emit_node line failed schema validation: $node_line"
got_id="$(printf '%s' "$node_line" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')"
[[ "$got_id" == "$(gluerun_graph_node_id 'finding:F1')" ]] \
  || fail "emitted node id != gluerun_graph_node_id(identity)"
got_ev="$(printf '%s' "$node_line" | python3 -c 'import json,sys;print(json.load(sys.stdin)["evidenceClass"])')"
[[ "$got_ev" == "claim" ]] || fail "finding node evidenceClass should be claim, got '$got_ev'"
got_ch="$(printf '%s' "$node_line" | python3 -c 'import json,sys;print(json.load(sys.stdin)["provenance"]["contentHash"])')"
[[ "$got_ch" == "$(gluerun_graph_content_hash 'the finding body')" ]] \
  || fail "emitted node contentHash != gluerun_graph_content_hash(content)"
got_sp="$(printf '%s' "$node_line" | python3 -c 'import json,sys;print(json.load(sys.stdin)["provenance"]["sourcePath"])')"
[[ "$got_sp" == "docs/critique/F1.md" ]] || fail "emitted node sourcePath wrong: '$got_sp'"

# Determinism: identical inputs -> byte-identical line.
node_line_b="$(gluerun_graph_emit_node finding 'finding:F1' 'docs/critique/F1.md' \
               'the finding body' 'a finding')"
[[ "$node_line" == "$node_line_b" ]] || fail "emit_node is not deterministic"

# Evidence invariance (fail-closed): authoritative ONLY for commit + gate-result.
node_ev() {
  gluerun_graph_emit_node "$1" "id:$1" "src/$1" "content-$1" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["evidenceClass"])'
}
[[ "$(node_ev commit)" == "authoritative" ]]      || fail "commit node must be authoritative"
[[ "$(node_ev gate-result)" == "authoritative" ]] || fail "gate-result node must be authoritative"
# audit is a model (the auditor) — must be claim, never authoritative.
[[ "$(node_ev audit)" == "claim" ]]     || fail "audit node must be claim (auditor is a model)"
for t in goal plan-batch plan-version critique finding assumption task attempt decision capsule; do
  [[ "$(node_ev "$t")" == "claim" ]] || fail "node type '$t' must be claim"
done

# Optional attributes are projected as a nested object and still validate.
attr_line="$(gluerun_graph_emit_node gate-result 'gate:G1' '.gluerun-state/gates/G1.json' \
             'gate body' 'gate G1' '{"verdict":"pass"}')"
printf '%s' "$attr_line" | validates || fail "emit_node with attributes failed validation: $attr_line"
[[ "$(printf '%s' "$attr_line" | python3 -c 'import json,sys;print(json.load(sys.stdin)["attributes"]["verdict"])')" == "pass" ]] \
  || fail "emit_node did not project attributes.verdict"

# --- Slice 3: edge emitter ---------------------------------------------------
from_id="$(gluerun_graph_node_id 'task:TASK-0001')"
to_id="$(gluerun_graph_node_id 'attempt:TASK-0001#1')"
edge_line="$(gluerun_graph_emit_edge implements "$from_id" "$to_id" \
             '.gluerun-state/events/log.jsonl' 'edge source content')"
[[ -n "$edge_line" ]] || fail "emit_edge produced no output"
printf '%s' "$edge_line" | validates || fail "emit_edge line failed schema validation: $edge_line"
got_eid="$(printf '%s' "$edge_line" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')"
[[ "$got_eid" == "$(gluerun_graph_edge_id "$from_id" implements "$to_id")" ]] \
  || fail "emitted edge id != gluerun_graph_edge_id(from,type,to)"
got_from="$(printf '%s' "$edge_line" | python3 -c 'import json,sys;print(json.load(sys.stdin)["from"])')"
got_to="$(printf '%s' "$edge_line" | python3 -c 'import json,sys;print(json.load(sys.stdin)["to"])')"
[[ "$got_from" == "$from_id" && "$got_to" == "$to_id" ]] || fail "emit_edge did not preserve from/to"
# Determinism.
edge_line_b="$(gluerun_graph_emit_edge implements "$from_id" "$to_id" \
               '.gluerun-state/events/log.jsonl' 'edge source content')"
[[ "$edge_line" == "$edge_line_b" ]] || fail "emit_edge is not deterministic"
# Optional edge attributes still validate.
edge_attr="$(gluerun_graph_emit_edge accepts_observation "$from_id" "$to_id" \
             'src/obs' 'obs' '{"disposition":"accept"}')"
printf '%s' "$edge_attr" | validates || fail "emit_edge with attributes failed validation: $edge_attr"

# --- No-writes: the emitters print JSONL and touch NO filesystem --------------
work="$(mktemp -d)"
w_before="$(cd "$work" && find . | LC_ALL=C sort)"
( cd "$work" && \
  gluerun_graph_emit_node commit 'commit:abc' 'refs/commit' 'body' >/dev/null && \
  gluerun_graph_emit_edge verifies "$from_id" "$to_id" 'src' 'body' >/dev/null )
w_after="$(cd "$work" && find . | LC_ALL=C sort)"
[[ "$w_before" == "$w_after" ]] || fail "emitters wrote filesystem artifacts (must be pure stdout)"
rm -rf "$work"

echo "test-ctx-graph: all assertions passed"
