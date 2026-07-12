#!/usr/bin/env bash
# Covers the graph-projector `rebuild` entry point in engine/ctx-graph-rebuild.sh
# — the composition keystone that turns the integrated mapper library into an
# actual `gluerun graph rebuild`. Two chained slices:
#   gluerun_graph_partition <nodesOut> <edgesOut>   (stdin mixed node+edge stream)
#       -> routes every `kind` node line to <nodesOut> and every `kind` edge line
#          to <edgesOut>, losslessly and deterministically (no line dropped,
#          duplicated, or mutated). Bridges the mappers' mixed stdout to the
#          separate node/edge inputs gluerun_graph_write_corpus expects.
#   gluerun_graph_rebuild <stateDir> [graphDir]
#       -> walks the durable sources under <stateDir> in sorted order, invokes
#          every integrated mapper over its source set, partitions the collected
#          stream with slice 1, and calls gluerun_graph_write_corpus <graphDir>
#          to write the canonical nodes.jsonl + edges.jsonl. <graphDir> defaults
#          to ${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}.
#
# Asserts: partition is lossless/verbatim; the rebuilt corpus over a fixture
# exercising all integrated mappers carries every node+edge family (attempt +
# implements, gate-result + verifies, plan-version + revises/supersedes, decision,
# critique, finding, task, commit, audit); every line validates against the
# SHIPPED schema; the authoritative/claim split is preserved (commit + gate-result
# authoritative, every other node claim); determinism + loss-free rebuild (repeat
# run and delete-then-rebuild both reproduce a byte-identical corpus, independent
# of source-file ordering because gluerun_graph_write_corpus dedups+sorts by id);
# graphDir defaults to ${GLUERUN_CTX_GRAPH_DIR}; and OFF-parity/no-writes —
# sourcing the file invokes nothing and rebuild writes only under <graphDir>,
# leaving <stateDir> byte-identical.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REBUILD="$ENGINE_HOME/engine/ctx-graph-rebuild.sh"
RECORDS="$ENGINE_HOME/engine/ctx-graph-project-records.sh"
PLANS="$ENGINE_HOME/engine/ctx-graph-project-plans.sh"
PROJECT="$ENGINE_HOME/engine/ctx-graph-project.sh"
GRAPH="$ENGINE_HOME/engine/ctx-graph.sh"
CORPUS="$ENGINE_HOME/engine/ctx-graph-corpus.sh"
SCHEMA="$ENGINE_HOME/schemas/context-graph.v0.schema.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- strict-test-first RED precondition: fail closed with no impl present -----
[[ -f "$SCHEMA" ]]  || fail "missing schema: $SCHEMA"
[[ -f "$GRAPH" ]]   || fail "missing projection primitives: $GRAPH"
[[ -f "$PROJECT" ]] || fail "missing identity/attempts/gate mappers: $PROJECT"
[[ -f "$PLANS" ]]   || fail "missing plan-lifecycle mappers: $PLANS"
[[ -f "$RECORDS" ]] || fail "missing task/commit/audit mappers: $RECORDS"
[[ -f "$CORPUS" ]]  || fail "missing corpus writer: $CORPUS"
[[ -f "$REBUILD" ]] || fail "impl not present yet: $REBUILD (strict-test-first RED)"

work_root="$(mktemp -d)"
snap_dir="$(mktemp -d)"
VALIDATOR="$(mktemp)"
trap 'rm -rf "$work_root" "$snap_dir" "$VALIDATOR"' EXIT

# --- OFF-parity / no-writes on source: sourcing invokes nothing, writes nothing.
before="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
unset GLUERUN_CTX_GRAPH 2>/dev/null || true
# shellcheck disable=SC1090
( cd "$snap_dir" \
    && source "$GRAPH" && source "$PROJECT" && source "$PLANS" \
    && source "$RECORDS" && source "$CORPUS" && source "$REBUILD" ) \
  || fail "sourcing $REBUILD failed"
after="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail "sourcing $REBUILD created filesystem artifacts (OFF-parity)"

# shellcheck disable=SC1090
source "$GRAPH"   || fail "sourcing $GRAPH failed"
# shellcheck disable=SC1090
source "$PROJECT" || fail "sourcing $PROJECT failed"
# shellcheck disable=SC1090
source "$PLANS"   || fail "sourcing $PLANS failed"
# shellcheck disable=SC1090
source "$RECORDS" || fail "sourcing $RECORDS failed"
# shellcheck disable=SC1090
source "$CORPUS"  || fail "sourcing $CORPUS failed"
# shellcheck disable=SC1090
source "$REBUILD" || fail "sourcing $REBUILD failed"
for fn in gluerun_graph_partition gluerun_graph_rebuild; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $REBUILD"
done

# --- minimal schema-driven validator (resolves $ref/$defs + oneOf) -----------
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
validates_file() { python3 "$VALIDATOR" "$SCHEMA" < "$1" >/dev/null 2>&1; }

# helpers over a JSONL file.
count_type() { # <file> <field> <value>
  python3 -c '
import json, sys
f, field, val = sys.argv[1], sys.argv[2], sys.argv[3]
c = 0
for line in open(f, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line.strip():
        continue
    if json.loads(line).get(field) == val:
        c += 1
print(c)
' "$1" "$2" "$3"
}

# --- Slice 1: partition (lossless, verbatim, deterministic) ------------------
mixed="$work_root/mixed.jsonl"
cat > "$mixed" <<'JSONL'
{"kind":"node","id":"n-aaa","type":"task"}
{"kind":"edge","id":"e-111","type":"implements"}
{"kind":"node","id":"n-bbb","type":"commit"}
{"kind":"edge","id":"e-222","type":"verifies"}
{"kind":"node","id":"n-ccc","type":"audit"}
JSONL

p_nodes="$work_root/part-nodes.jsonl"
p_edges="$work_root/part-edges.jsonl"
gluerun_graph_partition "$p_nodes" "$p_edges" < "$mixed" \
  || fail "gluerun_graph_partition failed"

# Every kind-node line went to nodes, every kind-edge line to edges; none lost.
[[ "$(count_type "$p_nodes" kind node)" == "3" ]] || fail "partition: expected 3 node lines in nodesOut"
[[ "$(count_type "$p_nodes" kind edge)" == "0" ]] || fail "partition: an edge line leaked into nodesOut"
[[ "$(count_type "$p_edges" kind edge)" == "2" ]] || fail "partition: expected 2 edge lines in edgesOut"
[[ "$(count_type "$p_edges" kind node)" == "0" ]] || fail "partition: a node line leaked into edgesOut"
# Conservation: total routed == total input records (nothing dropped or duplicated).
in_lines="$(grep -c . "$mixed")"
out_lines=$(( $(grep -c . "$p_nodes") + $(grep -c . "$p_edges") ))
[[ "$out_lines" == "$in_lines" ]] || fail "partition dropped or duplicated lines ($out_lines != $in_lines)"
# Verbatim: content not mutated. The node lines from the source appear byte-exact.
grep -qxF '{"kind":"node","id":"n-aaa","type":"task"}' "$p_nodes" || fail "partition mutated a node line"
grep -qxF '{"kind":"edge","id":"e-222","type":"verifies"}' "$p_edges" || fail "partition mutated an edge line"
# Deterministic: repeat routing is byte-identical.
p_nodes_b="$work_root/part-nodes-b.jsonl"; p_edges_b="$work_root/part-edges-b.jsonl"
gluerun_graph_partition "$p_nodes_b" "$p_edges_b" < "$mixed" || fail "partition (repeat) failed"
diff -q "$p_nodes" "$p_nodes_b" >/dev/null || fail "partition nodes output not deterministic"
diff -q "$p_edges" "$p_edges_b" >/dev/null || fail "partition edges output not deterministic"

# --- Slice 2: rebuild — build a fixture exercising every integrated mapper ----
NODE="TASK-0080"
RUN_A="RUN-20260712T100000Z-00001"
RUN_B="RUN-20260712T110000Z-00002"
SHA_A="0123456789abcdef0123456789abcdef01234567"

STATE="$work_root/state"
mkdir -p "$STATE/runs/$RUN_A/attempts" "$STATE/runs/$RUN_B" \
         "$STATE/docs/orchestration/gates" "$STATE/docs/orchestration/tasks"

# attempts index -> attempt nodes + implements edges
cat > "$STATE/runs/$RUN_A/attempts/index.json" <<JSON
{
  "schema": "gluerun.orchestration.attempts-index.v0",
  "runId": "$RUN_A",
  "taskId": "$NODE",
  "attempts": [
    { "n": 1, "status": "failed", "headSha": "aaa" },
    { "n": 2, "status": "passed", "headSha": "bbb" }
  ]
}
JSON

# paired-audit -> audit node (claim)
cat > "$STATE/runs/$RUN_A/paired-audit.json" <<JSON
{
  "schema": "gluerun.orchestration.paired-audit.v0",
  "runId": "$RUN_A",
  "taskId": "$NODE",
  "sampled": true,
  "runnerExit": 0,
  "verdict": "rejected",
  "findings": [ { "id": "f1", "severity": "blocking" } ],
  "findingsCount": 1,
  "disagreement": true,
  "agreement": false
}
JSON

# plan-critique -> critique node + finding nodes
cat > "$STATE/runs/$RUN_A/plan-critique.json" <<JSON
{
  "schema": "gluerun.orchestration.plan-critique.v0",
  "node": "$NODE",
  "runId": "$RUN_A",
  "batchTaskIds": ["TASK-0078"],
  "verdict": "revise",
  "findings": [
    { "id": "F-001", "severity": "blocking", "claim": "c1", "evidence": "e1" },
    { "id": "F-002", "severity": "note", "claim": "c2", "evidence": "e2" }
  ],
  "assumptionsChallenged": [],
  "rationale": "r"
}
JSON

# gate-result (passed) -> gate-result node (authoritative) + verifies edge
cat > "$STATE/docs/orchestration/gates/$NODE.gate-result.json" <<JSON
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "$NODE",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "deterministic-proof",
  "evidence": [
    { "kind": "command-log", "ref": "log", "command": "bash tests/x.sh", "exitCode": 0, "logRef": "x" }
  ],
  "decidedBy": "host",
  "recordedAt": "2026-07-12T15:48:43Z"
}
JSON

# task markdown -> task node (claim)
cat > "$STATE/docs/orchestration/tasks/$NODE.md" <<MD
# $NODE: Assemble the graph-projector rebuild entry point

Objective: walk the durable sources and rebuild the canonical corpus.
MD

# events.ndjson -> plan-version (+revises/supersedes), decision, commit
cat > "$STATE/events.ndjson" <<JSON
{"ts":"2026-07-12T10:00:00Z","type":"plan.revised","message":"m","data":{"node":"$NODE","runId":"$RUN_A"}}
{"ts":"2026-07-12T11:00:00Z","type":"plan.revised","message":"m","data":{"node":"$NODE","runId":"$RUN_B","revisesRunId":"$RUN_A"}}
{"ts":"2026-07-12T11:05:00Z","type":"context.strategy_selected","message":"m","data":{"node":"$NODE","runId":"$RUN_B"}}
{"ts":"2026-07-12T11:06:00Z","type":"decision.recorded","message":"m","data":{"node":"$NODE","runId":"$RUN_B"}}
{"ts":"2026-07-12T11:10:00Z","type":"l1.committed","message":"m","data":{"node":"$NODE","runId":"$RUN_B","headSha":"$SHA_A"}}
JSON

GRAPHDIR="$work_root/graph"

# Snapshot the stateDir to prove rebuild reads only (writes NOTHING under it).
state_before="$(cd "$STATE" && find . | LC_ALL=C sort)"
gluerun_graph_rebuild "$STATE" "$GRAPHDIR" || fail "gluerun_graph_rebuild failed"
state_after="$(cd "$STATE" && find . | LC_ALL=C sort)"
[[ "$state_before" == "$state_after" ]] || fail "rebuild wrote under <stateDir> (must write only under <graphDir>)"

NODES="$GRAPHDIR/nodes.jsonl"
EDGES="$GRAPHDIR/edges.jsonl"
[[ -f "$NODES" ]] || fail "rebuild did not write nodes.jsonl"
[[ -f "$EDGES" ]] || fail "rebuild did not write edges.jsonl"

# Every corpus line validates against the SHIPPED schema.
validates_file "$NODES" || fail "a nodes.jsonl line failed schema validation"
validates_file "$EDGES" || fail "an edges.jsonl line failed schema validation"

# Coverage: every integrated node family is present.
for nt in attempt gate-result plan-version decision critique finding task commit audit; do
  [[ "$(count_type "$NODES" type "$nt")" -ge 1 ]] || fail "rebuilt corpus missing node type: $nt"
done
# Coverage: every integrated edge family is present.
for et in implements verifies revises supersedes; do
  [[ "$(count_type "$EDGES" type "$et")" -ge 1 ]] || fail "rebuilt corpus missing edge type: $et"
done

# Authoritative/claim split: commit + gate-result authoritative, every other node claim.
split_ok="$(python3 -c '
import json, sys
auth = {"commit", "gate-result"}
ok = True
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if not line.strip():
        continue
    d = json.loads(line)
    want = "authoritative" if d["type"] in auth else "claim"
    if d.get("evidenceClass") != want:
        ok = False
        sys.stderr.write("%s -> %s (want %s)\n" % (d["type"], d.get("evidenceClass"), want))
print("ok" if ok else "bad")
' "$NODES")"
[[ "$split_ok" == "ok" ]] || fail "authoritative/claim split violated in rebuilt corpus"

# --- Determinism: repeated rebuild is byte-identical --------------------------
NODES_SNAP="$work_root/nodes-run1.jsonl"; EDGES_SNAP="$work_root/edges-run1.jsonl"
cp "$NODES" "$NODES_SNAP"; cp "$EDGES" "$EDGES_SNAP"
gluerun_graph_rebuild "$STATE" "$GRAPHDIR" || fail "second gluerun_graph_rebuild failed"
diff -q "$NODES_SNAP" "$NODES" >/dev/null || fail "nodes.jsonl not byte-identical on repeat rebuild"
diff -q "$EDGES_SNAP" "$EDGES" >/dev/null || fail "edges.jsonl not byte-identical on repeat rebuild"

# --- Loss-free: delete graphDir then rebuild reproduces the byte-identical corpus.
rm -rf "$GRAPHDIR"
gluerun_graph_rebuild "$STATE" "$GRAPHDIR" || fail "rebuild after delete failed"
diff -q "$NODES_SNAP" "$NODES" >/dev/null || fail "nodes.jsonl not reproduced loss-free after delete"
diff -q "$EDGES_SNAP" "$EDGES" >/dev/null || fail "edges.jsonl not reproduced loss-free after delete"

# --- graphDir default resolves to ${GLUERUN_CTX_GRAPH_DIR} --------------------
DEFDIR="$work_root/defgraph"
( export GLUERUN_CTX_GRAPH_DIR="$DEFDIR"; gluerun_graph_rebuild "$STATE" ) \
  || fail "rebuild with default graphDir failed"
[[ -f "$DEFDIR/nodes.jsonl" && -f "$DEFDIR/edges.jsonl" ]] \
  || fail "rebuild did not honor GLUERUN_CTX_GRAPH_DIR default for graphDir"
diff -q "$NODES_SNAP" "$DEFDIR/nodes.jsonl" >/dev/null \
  || fail "default-graphDir corpus differs from explicit-graphDir corpus (not source-order independent)"

echo "test-ctx-graph-rebuild: all assertions passed"
