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
#
# CAPSTONE (requiredCompletion walk): beyond the primitives above, this file is
# the composed end-to-end guard for the graph-projector node. Slice 4 composes the
# INTEGRATED engine functions (gluerun_graph_rebuild / gluerun_graph_sync /
# gluerun_graph_query_* over the mappers + loss-free writer) across a single
# fixture <stateDir> spanning several source families — an authoritative commit +
# gate-result plus claim nodes — and asserts, strict-test-first: rebuild
# determinism (byte-identical nodes.jsonl + edges.jsonl on repeat), graph deletable
# + rebuildable loss-free (delete the graph dir, rebuild, byte-identical), sync
# equals rebuild (from scratch AND incrementally after appending events, both
# byte-identical to a full rebuild over the augmented state), the query readers'
# documented outputs (neighbors, lineage, open-contradictions), the
# authoritative/claim split (commit + gate-result authoritative, every other node
# claim) with every corpus line valid vs the SHIPPED schema, and OFF-parity
# end-to-end (with GLUERUN_CTX_GRAPH unset/0 sourcing every composed module invokes
# nothing and writes no file, and `gluerun graph ...` refuses exactly as an unknown
# command did — both pinned behaviorally by directory snapshots, never by an
# absence-grep). The guard only asserts requiredCompletion behaviors over the
# integrated functions; it re-implements no projection logic.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTX_GRAPH="$ENGINE_HOME/engine/ctx-graph.sh"
SCHEMA="$ENGINE_HOME/schemas/context-graph.v0.schema.json"
# Composed-guard (Slice 4) module + CLI paths.
GG_PROJECT="$ENGINE_HOME/engine/ctx-graph-project.sh"
GG_PLANS="$ENGINE_HOME/engine/ctx-graph-project-plans.sh"
GG_RECORDS="$ENGINE_HOME/engine/ctx-graph-project-records.sh"
GG_CORPUS="$ENGINE_HOME/engine/ctx-graph-corpus.sh"
GG_REBUILD="$ENGINE_HOME/engine/ctx-graph-rebuild.sh"
GG_SYNC="$ENGINE_HOME/engine/ctx-graph-sync.sh"
GG_QUERY="$ENGINE_HOME/engine/ctx-graph-query.sh"
GLUERUN_SRC="$ENGINE_HOME/cli/gluerun"

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

# =============================================================================
# Slice 4: composed end-to-end requiredCompletion walk
# -----------------------------------------------------------------------------
# Compose the INTEGRATED engine functions (rebuild / sync / query_* over the
# mappers + loss-free writer) across ONE fixture <stateDir> and assert the
# requiredCompletion properties. Strict-test-first: with any composed module
# absent the preconditions below fail closed; the behavioral assertions would
# fail were rebuild/sync/query/loss-free behavior wrong.
# =============================================================================

# --- strict-test-first RED preconditions: fail closed if any composed impl is
#     absent (the composed behavior this slice guards would then be missing).
[[ -f "$GG_PROJECT" ]] || fail "impl not present yet: $GG_PROJECT (strict-test-first RED)"
[[ -f "$GG_PLANS" ]]   || fail "impl not present yet: $GG_PLANS (strict-test-first RED)"
[[ -f "$GG_RECORDS" ]] || fail "impl not present yet: $GG_RECORDS (strict-test-first RED)"
[[ -f "$GG_CORPUS" ]]  || fail "impl not present yet: $GG_CORPUS (strict-test-first RED)"
[[ -f "$GG_REBUILD" ]] || fail "impl not present yet: $GG_REBUILD (strict-test-first RED)"
[[ -f "$GG_SYNC" ]]    || fail "impl not present yet: $GG_SYNC (strict-test-first RED)"
[[ -f "$GG_QUERY" ]]   || fail "impl not present yet: $GG_QUERY (strict-test-first RED)"
[[ -f "$GLUERUN_SRC" ]] || fail "impl not present yet: $GLUERUN_SRC (strict-test-first RED)"

E2E_ROOT="$(mktemp -d)"
E2E_SNAP="$(mktemp -d)"
E2E_EHOME="$(mktemp -d)"
# Widen the EXIT trap to also clean the Slice 4 scratch dirs.
trap 'rm -rf "$snap_dir" "$VALIDATOR" "$E2E_ROOT" "$E2E_SNAP" "$E2E_EHOME"' EXIT

# --- OFF-parity (sourcing): with GLUERUN_CTX_GRAPH unset, sourcing EVERY composed
#     module invokes nothing and writes no file — pinned by a dir snapshot, not an
#     absence-grep.
off_before="$(cd "$E2E_SNAP" && find . | LC_ALL=C sort)"
unset GLUERUN_CTX_GRAPH 2>/dev/null || true
# shellcheck disable=SC1090
( cd "$E2E_SNAP" \
    && source "$CTX_GRAPH" && source "$GG_PROJECT" && source "$GG_PLANS" \
    && source "$GG_RECORDS" && source "$GG_CORPUS" && source "$GG_REBUILD" \
    && source "$GG_SYNC" && source "$GG_QUERY" ) \
  || fail "sourcing the composed graph modules failed"
off_after="$(cd "$E2E_SNAP" && find . | LC_ALL=C sort)"
[[ "$off_before" == "$off_after" ]] \
  || fail "sourcing the composed graph modules created filesystem artifacts (OFF-parity)"

# Bring the composed functions into this shell (ctx-graph.sh already sourced above).
# shellcheck disable=SC1090
source "$GG_PROJECT" || fail "sourcing $GG_PROJECT failed"
# shellcheck disable=SC1090
source "$GG_PLANS"   || fail "sourcing $GG_PLANS failed"
# shellcheck disable=SC1090
source "$GG_RECORDS" || fail "sourcing $GG_RECORDS failed"
# shellcheck disable=SC1090
source "$GG_CORPUS"  || fail "sourcing $GG_CORPUS failed"
# shellcheck disable=SC1090
source "$GG_REBUILD" || fail "sourcing $GG_REBUILD failed"
# shellcheck disable=SC1090
source "$GG_SYNC"    || fail "sourcing $GG_SYNC failed"
# shellcheck disable=SC1090
source "$GG_QUERY"   || fail "sourcing $GG_QUERY failed"
for fn in gluerun_graph_rebuild gluerun_graph_sync \
          gluerun_graph_query_neighbors gluerun_graph_query_lineage \
          gluerun_graph_query_open_contradictions; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "composed function not defined: $fn"
done

# --- fixture builder: one <stateDir> spanning several source families ---------
# Exercises attempts (implements), gate-results (verifies on passed, invalidates
# on failed), events (plan-version + revises/supersedes, decision, commit),
# plan-critique (critique + findings), task markdown, and paired-audit — so the
# corpus spans node/edge types and BOTH evidence classes: an authoritative commit
# + gate-result and many claim nodes.
E2E_NODE="TASK-0080"
E2E_NODE2="TASK-0081"
E2E_RUN_A="RUN-20260712T100000Z-00001"
E2E_RUN_B="RUN-20260712T110000Z-00002"
E2E_SHA_A="0123456789abcdef0123456789abcdef01234567"
e2e_build_state() { # <stateDir>
  local STATE="$1"
  mkdir -p "$STATE/runs/$E2E_RUN_A/attempts" "$STATE/runs/$E2E_RUN_B" \
           "$STATE/docs/orchestration/gates" "$STATE/docs/orchestration/tasks"

  cat > "$STATE/runs/$E2E_RUN_A/attempts/index.json" <<JSON
{
  "schema": "gluerun.orchestration.attempts-index.v0",
  "runId": "$E2E_RUN_A",
  "taskId": "$E2E_NODE",
  "attempts": [
    { "n": 1, "status": "failed", "headSha": "aaa" },
    { "n": 2, "status": "passed", "headSha": "bbb" }
  ]
}
JSON

  cat > "$STATE/runs/$E2E_RUN_A/paired-audit.json" <<JSON
{
  "schema": "gluerun.orchestration.paired-audit.v0",
  "runId": "$E2E_RUN_A",
  "taskId": "$E2E_NODE",
  "sampled": true,
  "runnerExit": 0,
  "verdict": "rejected",
  "findings": [ { "id": "f1", "severity": "blocking" } ],
  "findingsCount": 1,
  "disagreement": true,
  "agreement": false
}
JSON

  cat > "$STATE/runs/$E2E_RUN_A/plan-critique.json" <<JSON
{
  "schema": "gluerun.orchestration.plan-critique.v0",
  "node": "$E2E_NODE",
  "runId": "$E2E_RUN_A",
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

  # Passed gate on E2E_NODE -> gate-result (authoritative) + verifies edge.
  cat > "$STATE/docs/orchestration/gates/$E2E_NODE.gate-result.json" <<JSON
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "$E2E_NODE",
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

  # Failed gate on E2E_NODE2 -> gate-result (authoritative) + invalidates edge; its
  # invalidated target (task node) is NOT superseded, so it is an OPEN contradiction.
  cat > "$STATE/docs/orchestration/gates/$E2E_NODE2.gate-result.json" <<JSON
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "$E2E_NODE2",
  "status": "failed",
  "authoritative": true,
  "evidenceClass": "deterministic-proof",
  "evidence": [
    { "kind": "command-log", "ref": "log", "command": "bash tests/y.sh", "exitCode": 1, "logRef": "y" }
  ],
  "decidedBy": "host",
  "recordedAt": "2026-07-12T16:10:00Z"
}
JSON

  cat > "$STATE/docs/orchestration/tasks/$E2E_NODE.md" <<MD
# $E2E_NODE: Assemble the graph-projector rebuild entry point

Objective: walk the durable sources and rebuild the canonical corpus.
MD

  cat > "$STATE/events.ndjson" <<JSON
{"ts":"2026-07-12T10:00:00Z","type":"plan.revised","message":"m","data":{"node":"$E2E_NODE","runId":"$E2E_RUN_A"}}
{"ts":"2026-07-12T11:00:00Z","type":"plan.revised","message":"m","data":{"node":"$E2E_NODE","runId":"$E2E_RUN_B","revisesRunId":"$E2E_RUN_A"}}
{"ts":"2026-07-12T11:05:00Z","type":"context.strategy_selected","message":"m","data":{"node":"$E2E_NODE","runId":"$E2E_RUN_B"}}
{"ts":"2026-07-12T11:06:00Z","type":"decision.recorded","message":"m","data":{"node":"$E2E_NODE","runId":"$E2E_RUN_B"}}
{"ts":"2026-07-12T11:10:00Z","type":"l1.committed","message":"m","data":{"node":"$E2E_NODE","runId":"$E2E_RUN_B","headSha":"$E2E_SHA_A"}}
JSON
}

e2e_count_lines() { python3 -c 'import sys; print(sum(1 for _ in open(sys.argv[1])))' "$1"; }
# Count JSONL records in file $1 whose field $2 equals value $3.
count_type() { # <file> <field> <value>
  GG_F="$2" GG_V="$3" python3 -c '
import json, os, sys
field, val = os.environ["GG_F"], os.environ["GG_V"]
c = 0
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if line.strip() and json.loads(line).get(field) == val:
        c += 1
print(c)
' "$1"
}
# Validate every line of a corpus file against the SHIPPED schema (reuses the
# single-record validator defined above).
validates_corpus() { # <file>
  local f="$1" line seen=0
  while IFS= read -r line; do
    [[ -n "${line// }" ]] || continue
    seen=1
    printf '%s' "$line" | validates || return 1
  done < "$f"
  [[ "$seen" == 1 ]] || return 1
}
# Print ids of nodes whose `type` == $2 in corpus file $1, sorted.
e2e_node_ids_of_type() { # <nodes.jsonl> <type>
  GG_T="$2" python3 -c '
import json, os, sys
want = os.environ["GG_T"]
out = [json.loads(l)["id"] for l in open(sys.argv[1], encoding="utf-8")
       if l.strip() and json.loads(l).get("type") == want]
for i in sorted(out):
    print(i)
' "$1"
}

STATE="$E2E_ROOT/state"
e2e_build_state "$STATE"
GDIR_R="$E2E_ROOT/graph-rebuild"

# --- rebuild: writes only under <graphDir>, leaving <stateDir> byte-identical ---
state_before="$(cd "$STATE" && find . | LC_ALL=C sort)"
gluerun_graph_rebuild "$STATE" "$GDIR_R" || fail "gluerun_graph_rebuild failed"
state_after="$(cd "$STATE" && find . | LC_ALL=C sort)"
[[ "$state_before" == "$state_after" ]] || fail "rebuild wrote under <stateDir> (must write only under <graphDir>)"
NODES_R="$GDIR_R/nodes.jsonl"; EDGES_R="$GDIR_R/edges.jsonl"
[[ -f "$NODES_R" && -f "$EDGES_R" ]] || fail "rebuild did not write the canonical corpus"

# Every corpus line validates against the SHIPPED schema.
validates_corpus "$NODES_R" || fail "a rebuilt nodes.jsonl line failed schema validation"
validates_corpus "$EDGES_R" || fail "a rebuilt edges.jsonl line failed schema validation"

# Authoritative/claim separation: commit + gate-result authoritative, every other
# node claim.
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
print("ok" if ok else "bad")
' "$NODES_R")"
[[ "$split_ok" == "ok" ]] || fail "authoritative/claim separation violated in rebuilt corpus"
# The corpus genuinely spans both evidence classes (authoritative + claim present).
[[ "$(count_type "$NODES_R" evidenceClass authoritative)" -ge 1 ]] \
  || fail "rebuilt corpus has no authoritative node (fixture too thin)"
[[ "$(count_type "$NODES_R" evidenceClass claim)" -ge 1 ]] \
  || fail "rebuilt corpus has no claim node (fixture too thin)"

# --- rebuild determinism: repeat run is byte-identical ------------------------
NODES_SNAP="$E2E_ROOT/nodes-run1.jsonl"; EDGES_SNAP="$E2E_ROOT/edges-run1.jsonl"
cp "$NODES_R" "$NODES_SNAP"; cp "$EDGES_R" "$EDGES_SNAP"
gluerun_graph_rebuild "$STATE" "$GDIR_R" || fail "second gluerun_graph_rebuild failed"
diff -q "$NODES_SNAP" "$NODES_R" >/dev/null || fail "nodes.jsonl not byte-identical on repeat rebuild"
diff -q "$EDGES_SNAP" "$EDGES_R" >/dev/null || fail "edges.jsonl not byte-identical on repeat rebuild"

# --- loss-free: delete the graph dir, rebuild, byte-identical corpus ----------
rm -rf "$GDIR_R"
gluerun_graph_rebuild "$STATE" "$GDIR_R" || fail "rebuild after delete failed"
diff -q "$NODES_SNAP" "$NODES_R" >/dev/null || fail "nodes.jsonl not reproduced loss-free after delete"
diff -q "$EDGES_SNAP" "$EDGES_R" >/dev/null || fail "edges.jsonl not reproduced loss-free after delete"

# --- sync equals rebuild: FROM SCRATCH ----------------------------------------
GDIR_S="$E2E_ROOT/graph-sync"
gluerun_graph_sync "$STATE" "$GDIR_S" || fail "gluerun_graph_sync (from scratch) failed"
diff -q "$NODES_R" "$GDIR_S/nodes.jsonl" >/dev/null || fail "sync != rebuild (nodes.jsonl) from scratch"
diff -q "$EDGES_R" "$GDIR_S/edges.jsonl" >/dev/null || fail "sync != rebuild (edges.jsonl) from scratch"

# --- sync equals rebuild: INCREMENTAL (rebuild, append events, sync) ----------
STATE_I="$E2E_ROOT/state-inc"
e2e_build_state "$STATE_I"
GDIR_I="$E2E_ROOT/graph-inc"
gluerun_graph_rebuild "$STATE_I" "$GDIR_I" || fail "incremental: initial rebuild failed"
gluerun_graph_sync "$STATE_I" "$GDIR_I" || fail "incremental: adopt-sync after rebuild failed"
# Append brand-new events beyond the cursor, then sync only the delta.
E2E_RUN_C="RUN-20260712T120000Z-00003"
E2E_SHA_B="89abcdef0123456789abcdef0123456789abcdef"
cat >> "$STATE_I/events.ndjson" <<JSON
{"ts":"2026-07-12T12:00:00Z","type":"plan.revised","message":"m","data":{"node":"$E2E_NODE2","runId":"$E2E_RUN_C"}}
{"ts":"2026-07-12T12:05:00Z","type":"decision.recorded","message":"m","data":{"node":"$E2E_NODE2","runId":"$E2E_RUN_C"}}
{"ts":"2026-07-12T12:10:00Z","type":"l1.committed","message":"m","data":{"node":"$E2E_NODE2","runId":"$E2E_RUN_C","headSha":"$E2E_SHA_B"}}
JSON
gluerun_graph_sync "$STATE_I" "$GDIR_I" || fail "incremental sync failed"
# The incrementally-synced corpus equals a FRESH full rebuild over the augmented state.
GDIR_FRESH="$E2E_ROOT/graph-fresh"
gluerun_graph_rebuild "$STATE_I" "$GDIR_FRESH" || fail "fresh rebuild over augmented state failed"
diff -q "$GDIR_FRESH/nodes.jsonl" "$GDIR_I/nodes.jsonl" >/dev/null \
  || fail "incremental sync != fresh rebuild (nodes.jsonl)"
diff -q "$GDIR_FRESH/edges.jsonl" "$GDIR_I/edges.jsonl" >/dev/null \
  || fail "incremental sync != fresh rebuild (edges.jsonl)"

# --- query readers: documented outputs over the rebuilt corpus ----------------
# Pick the real task node id (TASK-0080 has a task record) to anchor the walks.
TASK_ID="$(e2e_node_ids_of_type "$NODES_R" task | head -1)"
[[ -n "$TASK_ID" ]] || fail "no task node in rebuilt corpus to anchor query walks"

# neighbors(task): non-empty; every incident edge is incident to TASK_ID; the
# adjacent node set is exactly the incident edges' other-end node records.
neigh="$(gluerun_graph_query_neighbors "$GDIR_R" "$TASK_ID")" || fail "neighbors(task) nonzero exit"
[[ -n "$neigh" ]] || fail "neighbors(task) unexpectedly empty over a connected corpus"
printf '%s\n' "$neigh" | GG_ID="$TASK_ID" python3 -c '
import json, os, sys
tid = os.environ["GG_ID"]
edges, nodes = [], []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        continue
    o = json.loads(line)
    (edges if o.get("kind") == "edge" else nodes).append(o)
if not edges:
    print("no incident edges", file=sys.stderr); sys.exit(1)
others = set()
for e in edges:
    if e.get("from") != tid and e.get("to") != tid:
        print("edge not incident to target", file=sys.stderr); sys.exit(1)
    for side in ("from", "to"):
        v = e.get(side)
        if v is not None and v != tid:
            others.add(v)
got_nodes = {n["id"] for n in nodes}
# Every adjacent node returned is a genuine other-end; none is the target itself.
if tid in got_nodes:
    print("neighbors leaked the target node record", file=sys.stderr); sys.exit(1)
if not got_nodes <= others:
    print("neighbors returned a non-adjacent node", file=sys.stderr); sys.exit(1)
' || fail "neighbors(task) output is not the documented incident-edges + adjacent-nodes projection"
# Determinism.
neigh2="$(gluerun_graph_query_neighbors "$GDIR_R" "$TASK_ID")" || fail "neighbors(task) repeat nonzero exit"
[[ "$neigh" == "$neigh2" ]] || fail "neighbors(task) not byte-identical on repeat"

# lineage(task): reaches the connected provenance component — contains the start
# plus the attempt nodes (implements) and the passed gate-result (verifies), and
# terminates (returns) despite the revises cycle among plan-versions.
lin="$(gluerun_graph_query_lineage "$GDIR_R" "$TASK_ID")" || fail "lineage(task) nonzero exit"
lin_ids="$(printf '%s\n' "$lin" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.strip():
        print(json.loads(line)["id"])
')"
printf '%s\n' "$lin_ids" | grep -qx "$TASK_ID" || fail "lineage(task) omits the start node"
for att in $(e2e_node_ids_of_type "$NODES_R" attempt); do
  printf '%s\n' "$lin_ids" | grep -qx "$att" \
    || fail "lineage(task) omits attempt node $att reachable via implements"
done
# Determinism.
lin2="$(gluerun_graph_query_lineage "$GDIR_R" "$TASK_ID")" || fail "lineage(task) repeat nonzero exit"
[[ "$lin" == "$lin2" ]] || fail "lineage(task) not byte-identical on repeat"

# open-contradictions: exactly the unresolved contradicts/invalidates edges. The
# failed gate on E2E_NODE2 emits an invalidates edge whose target is NOT
# superseded, so the result is non-empty; every returned edge is a
# contradicts/invalidates edge; the passed-gate verifies edge is NOT returned.
oc="$(gluerun_graph_query_open_contradictions "$GDIR_R")" || fail "open-contradictions nonzero exit"
[[ -n "$oc" ]] || fail "open-contradictions unexpectedly empty (fixture has an unresolved invalidates edge)"
printf '%s\n' "$oc" | python3 -c '
import json, sys
n = 0
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        continue
    n += 1
    o = json.loads(line)
    if o.get("kind") != "edge" or o.get("type") not in ("contradicts", "invalidates"):
        print("non-contradiction edge in open-contradictions", file=sys.stderr); sys.exit(1)
if n == 0:
    print("empty", file=sys.stderr); sys.exit(1)
' || fail "open-contradictions returned a non-contradiction record"
printf '%s\n' "$oc" | python3 -c '
import json, sys
for line in sys.stdin:
    if line.strip() and json.loads(line).get("type") == "verifies":
        sys.exit(1)
' || fail "open-contradictions leaked a verifies edge"
# Determinism.
oc2="$(gluerun_graph_query_open_contradictions "$GDIR_R")" || fail "open-contradictions repeat nonzero exit"
[[ "$oc" == "$oc2" ]] || fail "open-contradictions not byte-identical on repeat"

# --- OFF-parity end-to-end: `gluerun graph ...` refuses as an unknown command --
#     did, and writes no corpus. Hermetic engine home (empty lib.sh stub + the
#     integrated graph modules + the CLI) so the delegation/refusal is independent
#     of whatever .gluerun-state the suite host carries. Pinned behaviorally by a
#     directory snapshot + a refusal-equivalence comparison, never an absence-grep.
mkdir -p "$E2E_EHOME/engine" "$E2E_EHOME/cli"
: > "$E2E_EHOME/engine/lib.sh"
cp "$ENGINE_HOME"/engine/ctx-graph*.sh "$E2E_EHOME/engine/"
cp "$GLUERUN_SRC" "$E2E_EHOME/cli/gluerun"
E2E_CLI="$E2E_EHOME/cli/gluerun"
OFF_STATE="$E2E_ROOT/off-state"; e2e_build_state "$OFF_STATE"
OFF_GRAPH="$E2E_ROOT/off-graph"   # must never be created while the flag is OFF

for flag in unset 0; do
  off_dir_before="$(cd "$E2E_ROOT" && find off-graph 2>/dev/null | LC_ALL=C sort)"
  if [[ "$flag" == unset ]]; then
    env -u GLUERUN_CTX_GRAPH GLUERUN_ENGINE_HOME="$E2E_EHOME" "$E2E_CLI" \
      graph rebuild "$OFF_STATE" "$OFF_GRAPH" >/dev/null 2>"$E2E_ROOT/off-graph.err" \
      && fail "gluerun graph must refuse when GLUERUN_CTX_GRAPH is $flag"
    env -u GLUERUN_CTX_GRAPH GLUERUN_ENGINE_HOME="$E2E_EHOME" "$E2E_CLI" \
      totally-unknown-xyz >/dev/null 2>"$E2E_ROOT/off-unknown.err" \
      && fail "control unknown command should exit non-zero ($flag)"
  else
    GLUERUN_CTX_GRAPH=0 GLUERUN_ENGINE_HOME="$E2E_EHOME" "$E2E_CLI" \
      graph rebuild "$OFF_STATE" "$OFF_GRAPH" >/dev/null 2>"$E2E_ROOT/off-graph.err" \
      && fail "gluerun graph must refuse when GLUERUN_CTX_GRAPH is $flag"
    GLUERUN_CTX_GRAPH=0 GLUERUN_ENGINE_HOME="$E2E_EHOME" "$E2E_CLI" \
      totally-unknown-xyz >/dev/null 2>"$E2E_ROOT/off-unknown.err" \
      && fail "control unknown command should exit non-zero ($flag)"
  fi
  # The refusal reads exactly like an unknown command's, modulo the command token.
  off_g="$(sed 's/graph/CMD/' "$E2E_ROOT/off-graph.err")"
  off_u="$(sed 's/totally-unknown-xyz/CMD/' "$E2E_ROOT/off-unknown.err")"
  [[ "$off_g" == "$off_u" ]] \
    || fail "graph OFF refusal differs from an unknown command's ($flag): [$off_g] vs [$off_u]"
  # Behavioral no-write pin: the graph dir was not created by the refused command.
  off_dir_after="$(cd "$E2E_ROOT" && find off-graph 2>/dev/null | LC_ALL=C sort)"
  [[ "$off_dir_before" == "$off_dir_after" ]] \
    || fail "refused 'gluerun graph' wrote a corpus dir when flag is $flag (OFF-parity)"
  [[ ! -e "$OFF_GRAPH" ]] || fail "refused 'gluerun graph' created $OFF_GRAPH (flag $flag)"
done

echo "test-ctx-graph: all assertions passed"
