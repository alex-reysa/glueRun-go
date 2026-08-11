#!/usr/bin/env bash
# Covers the deterministic corpus assembler in engine/ctx-graph-corpus.sh — the
# determinism/idempotence keystone the later graph-projector funnels through so
# equal source sets yield a byte-identical graph:
#   singular_graph_canonicalize   projected JSONL on stdin -> deduped + id-sorted
#   singular_graph_write_corpus   <graphdir> <nodesIn> <edgesIn> -> nodes.jsonl + edges.jsonl
#
# Asserts: canonicalize is permutation-independent (any input ordering of the
# same line set -> byte-identical output), collapses duplicate-id lines to one,
# and sorts by id ascending; the writer clears stale graph files, is idempotent
# (second write == first; delete-and-rewrite == first), defaults <graphdir> to
# ${SINGULAR_CTX_GRAPH_DIR:-.singular-state/graph}, round-trips lines from the real
# singular_graph_emit_node/emit_edge primitives back through the schema, preserves
# every input line verbatim except for dedup/ordering, and touches ONLY the
# provided <graphdir>; plus OFF-parity — sourcing the file invokes nothing and
# writes no file (pinned by a before/after directory snapshot).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$ENGINE_HOME/engine/ctx-graph-corpus.sh"
GRAPH="$ENGINE_HOME/engine/ctx-graph.sh"
SCHEMA="$ENGINE_HOME/schemas/context-graph.v0.schema.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- strict-test-first RED precondition: fail closed with no impl present -----
[[ -f "$SCHEMA" ]] || fail "missing schema: $SCHEMA"
[[ -f "$GRAPH" ]]  || fail "missing projection primitives: $GRAPH"
[[ -f "$CORPUS" ]] || fail "impl not present yet: $CORPUS (strict-test-first RED)"

# OFF-parity / no-writes: sourcing the file must invoke nothing and write no
# file. Snapshot an empty cwd around the source; confirm SINGULAR_CTX_GRAPH is
# not required (default OFF).
snap_dir="$(mktemp -d)"
VALIDATOR="$(mktemp)"
trap 'rm -rf "$snap_dir" "$VALIDATOR"' EXIT
before="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
unset SINGULAR_CTX_GRAPH 2>/dev/null || true
# shellcheck disable=SC1090
( cd "$snap_dir" && source "$GRAPH" && source "$CORPUS" ) \
  || fail "sourcing $CORPUS failed"
after="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail "sourcing $CORPUS created filesystem artifacts (OFF-parity)"

# shellcheck disable=SC1090
source "$GRAPH"  || fail "sourcing $GRAPH failed"
# shellcheck disable=SC1090
source "$CORPUS" || fail "sourcing $CORPUS failed"
for fn in singular_graph_canonicalize singular_graph_write_corpus; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $CORPUS"
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
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        continue
    data = json.loads(line)
    errs = []
    validate(data, root, "$", root, errs)
    if errs:
        print("\n".join(errs), file=sys.stderr); sys.exit(1)
print("ok")
PY
validates() { python3 "$VALIDATOR" "$SCHEMA" >/dev/null 2>&1; }

# id of a single JSONL line.
line_id() { python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])'; }

# --- Build a corpus of real primitive lines (nodes + edges) ------------------
nA="$(singular_graph_emit_node finding    'finding:F1' 'docs/critique/F1.md' 'body A' 'a finding')"
nB="$(singular_graph_emit_node task       'task:T1'    '.singular-state/tasks/T1' 'body B' 'task one')"
nC="$(singular_graph_emit_node commit     'commit:C1'  'refs/commit'         'body C')"
nD="$(singular_graph_emit_node gate-result 'gate:G1'   '.singular-state/gates/G1.json' 'body D' 'gate' '{"verdict":"pass"}')"
fromT="$(singular_graph_node_id 'task:T1')"
toA="$(singular_graph_node_id 'attempt:T1#1')"
eX="$(singular_graph_emit_edge implements "$fromT" "$toA" '.singular-state/events/log.jsonl' 'edge body X')"
eY="$(singular_graph_emit_edge verifies   "$fromT" "$toA" '.singular-state/events/log.jsonl' 'edge body Y')"

# --- Slice 1: canonicalizer --------------------------------------------------

# Dedup: an identical line repeated collapses to a single output line.
dup_out="$(printf '%s\n%s\n%s\n' "$nA" "$nB" "$nA" | singular_graph_canonicalize)"
[[ "$(printf '%s\n' "$dup_out" | wc -l | tr -d ' ')" == "2" ]] \
  || fail "canonicalize did not collapse a duplicate line (got: $dup_out)"

# Sort ascending by id: output ids are non-decreasing.
sorted_ids="$(printf '%s\n%s\n%s\n%s\n' "$nC" "$nA" "$nD" "$nB" \
  | singular_graph_canonicalize \
  | while IFS= read -r l; do printf '%s\n' "$l" | line_id; done)"
[[ "$sorted_ids" == "$(printf '%s\n' "$sorted_ids" | LC_ALL=C sort)" ]] \
  || fail "canonicalize did not sort by id ascending (got: $sorted_ids)"

# Permutation independence: any input ordering of the same line set yields
# byte-identical output.
perm1="$(printf '%s\n%s\n%s\n%s\n' "$nA" "$nB" "$nC" "$nD" | singular_graph_canonicalize)"
perm2="$(printf '%s\n%s\n%s\n%s\n' "$nD" "$nC" "$nB" "$nA" | singular_graph_canonicalize)"
perm3="$(printf '%s\n%s\n%s\n%s\n' "$nB" "$nD" "$nA" "$nC" | singular_graph_canonicalize)"
[[ "$perm1" == "$perm2" && "$perm1" == "$perm3" ]] \
  || fail "canonicalize output depends on input permutation"

# Verbatim: every canonicalized line still validates and each input line
# survives byte-for-byte (only dedup + reordering applied).
printf '%s\n' "$perm1" | validates || fail "canonicalized lines failed schema validation"
for l in "$nA" "$nB" "$nC" "$nD"; do
  printf '%s\n' "$perm1" | grep -qxF "$l" || fail "canonicalize dropped/mutated a line: $l"
done

# --- Slice 2: loss-free corpus writer ----------------------------------------
gdir="$(mktemp -d)/graph"     # nonexistent leaf: writer must create it
nodes_in="$(mktemp)"; edges_in="$(mktemp)"
# Unsorted, with a duplicate node line and a duplicate edge line.
printf '%s\n%s\n%s\n%s\n%s\n' "$nC" "$nA" "$nD" "$nB" "$nA" > "$nodes_in"
printf '%s\n%s\n%s\n' "$eY" "$eX" "$eY" > "$edges_in"

singular_graph_write_corpus "$gdir" "$nodes_in" "$edges_in" \
  || fail "write_corpus failed"
[[ -f "$gdir/nodes.jsonl" ]] || fail "write_corpus did not create nodes.jsonl"
[[ -f "$gdir/edges.jsonl" ]] || fail "write_corpus did not create edges.jsonl"

# Written files equal canonicalized inputs, and every written line validates.
cmp -s "$gdir/nodes.jsonl" <(singular_graph_canonicalize < "$nodes_in") \
  || fail "nodes.jsonl is not the canonicalized node input"
cmp -s "$gdir/edges.jsonl" <(singular_graph_canonicalize < "$edges_in") \
  || fail "edges.jsonl is not the canonicalized edge input"
validates < "$gdir/nodes.jsonl" || fail "a written nodes.jsonl line failed schema validation"
validates < "$gdir/edges.jsonl" || fail "a written edges.jsonl line failed schema validation"

# Dedup applied on disk: 5 node input lines (1 dup) -> 4 lines; 3 edge (1 dup) -> 2.
[[ "$(wc -l < "$gdir/nodes.jsonl" | tr -d ' ')" == "4" ]] || fail "nodes.jsonl not deduped on disk"
[[ "$(wc -l < "$gdir/edges.jsonl" | tr -d ' ')" == "2" ]] || fail "edges.jsonl not deduped on disk"

# Snapshot the byte-exact corpus for idempotence comparisons.
nodes_snap="$(cat "$gdir/nodes.jsonl")"; edges_snap="$(cat "$gdir/edges.jsonl")"

# Idempotent: a second write over the same inputs is byte-identical.
singular_graph_write_corpus "$gdir" "$nodes_in" "$edges_in" || fail "second write_corpus failed"
[[ "$(cat "$gdir/nodes.jsonl")" == "$nodes_snap" ]] || fail "second write changed nodes.jsonl (not idempotent)"
[[ "$(cat "$gdir/edges.jsonl")" == "$edges_snap" ]] || fail "second write changed edges.jsonl (not idempotent)"

# Loss-free rebuild: delete the whole graphdir, rewrite over the same inputs,
# byte-identical corpus reproduced.
rm -rf "$gdir"
singular_graph_write_corpus "$gdir" "$nodes_in" "$edges_in" || fail "rebuild write_corpus failed"
[[ "$(cat "$gdir/nodes.jsonl")" == "$nodes_snap" ]] || fail "rebuild did not reproduce byte-identical nodes.jsonl"
[[ "$(cat "$gdir/edges.jsonl")" == "$edges_snap" ]] || fail "rebuild did not reproduce byte-identical edges.jsonl"

# Stale lines never survive a rewrite: inject a stale line into an existing
# corpus, rewrite, confirm it is gone and the corpus matches the canonical one.
printf 'STALE-LEFTOVER-LINE\n' >> "$gdir/nodes.jsonl"
singular_graph_write_corpus "$gdir" "$nodes_in" "$edges_in" || fail "rewrite over stale corpus failed"
grep -qF 'STALE-LEFTOVER-LINE' "$gdir/nodes.jsonl" && fail "stale line survived a rewrite"
[[ "$(cat "$gdir/nodes.jsonl")" == "$nodes_snap" ]] || fail "post-stale rewrite is not byte-identical"

# Default <graphdir>: when unset/empty, falls back to
# ${SINGULAR_CTX_GRAPH_DIR:-.singular-state/graph}.
def_root="$(mktemp -d)"
(
  cd "$def_root"
  export SINGULAR_CTX_GRAPH_DIR="$def_root/custom-graph"
  singular_graph_write_corpus "" "$nodes_in" "$edges_in"
) || fail "write_corpus with default graphdir failed"
[[ -f "$def_root/custom-graph/nodes.jsonl" ]] \
  || fail "write_corpus did not honor SINGULAR_CTX_GRAPH_DIR default"
[[ "$(cat "$def_root/custom-graph/nodes.jsonl")" == "$nodes_snap" ]] \
  || fail "default-graphdir corpus differs from explicit-graphdir corpus"

# Touches ONLY the provided <graphdir>: a sibling cwd is unchanged by a write.
work="$(mktemp -d)"
w_before="$(cd "$work" && find . | LC_ALL=C sort)"
target="$(mktemp -d)/g"
( cd "$work" && singular_graph_write_corpus "$target" "$nodes_in" "$edges_in" ) \
  || fail "isolated write_corpus failed"
w_after="$(cd "$work" && find . | LC_ALL=C sort)"
[[ "$w_before" == "$w_after" ]] || fail "write_corpus wrote outside the provided <graphdir>"

rm -rf "$gdir" "$def_root" "$work" "$target" "$nodes_in" "$edges_in"
echo "test-ctx-graph-corpus: all assertions passed"
