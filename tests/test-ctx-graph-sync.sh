#!/usr/bin/env bash
# Covers the graph-projector `sync` entry point in engine/ctx-graph-sync.sh — the
# incremental append that composes the integrated rebuild machinery (the event +
# record mappers, gluerun_graph_partition, gluerun_graph_write_corpus) and
# satisfies the `rebuild equals sync on fixtures` requiredCompletion property.
# Two chained slices:
#   gluerun_graph_sync_cursor_read  <graphDir>       -> count of events.ndjson lines
#   gluerun_graph_sync_cursor_write <graphDir> <n>      already projected, persisted
#       under <graphDir>/.sync-cursor; a missing cursor reads as 0. Pure + deterministic.
#   gluerun_graph_sync <stateDir> [graphDir]
#       -> reads the existing corpus + cursor, projects the events.ndjson lines
#          BEYOND the cursor via the event mappers, reprojects the bounded
#          record-based sources (attempts, gate-results, tasks, paired-audits,
#          critiques — idempotent), merges with the existing corpus, partitions,
#          writes the canonical corpus via gluerun_graph_write_corpus, and advances
#          the cursor to the current events.ndjson line count. <graphDir> defaults
#          to ${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}.
#
# Asserts: cursor round-trips + reads 0 when absent; rebuild-equals-sync FROM
# SCRATCH (no prior corpus -> byte-identical to gluerun_graph_rebuild); cursor
# advances to the consumed events line count; rebuild-equals-sync INCREMENTAL
# (rebuild, append events, sync -> byte-identical to a fresh rebuild over the
# augmented state); a no-new-events sync leaves the corpus byte-identical and does
# not regress the cursor; repeated sync is byte-identical (idempotent + canonical);
# every synced line validates against the SHIPPED schema; the authoritative/claim
# split is preserved; and OFF-parity/no-writes — sourcing invokes nothing and sync
# writes only under <graphDir>, leaving <stateDir> byte-identical.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ENGINE_HOME/engine/ctx-graph-sync.sh"
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
[[ -f "$REBUILD" ]] || fail "missing rebuild machinery: $REBUILD"
[[ -f "$SYNC" ]]    || fail "impl not present yet: $SYNC (strict-test-first RED)"

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
    && source "$RECORDS" && source "$CORPUS" && source "$REBUILD" && source "$SYNC" ) \
  || fail "sourcing $SYNC failed"
after="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail "sourcing $SYNC created filesystem artifacts (OFF-parity)"

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
# shellcheck disable=SC1090
source "$SYNC"    || fail "sourcing $SYNC failed"
for fn in gluerun_graph_sync_cursor_read gluerun_graph_sync_cursor_write gluerun_graph_sync; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $SYNC"
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

# --- Slice 1: cursor round-trip (pure + deterministic) -----------------------
CURDIR="$work_root/curdir"
mkdir -p "$CURDIR"
# A missing cursor reads as 0.
[[ "$(gluerun_graph_sync_cursor_read "$CURDIR")" == "0" ]] || fail "missing cursor did not read as 0"
# A totally-absent graphDir reads as 0 too (no side effects required to read).
[[ "$(gluerun_graph_sync_cursor_read "$work_root/nope")" == "0" ]] || fail "absent graphDir cursor did not read as 0"
# Write then read round-trips; deterministic.
gluerun_graph_sync_cursor_write "$CURDIR" 7 || fail "cursor_write failed"
[[ "$(gluerun_graph_sync_cursor_read "$CURDIR")" == "7" ]] || fail "cursor did not round-trip 7"
gluerun_graph_sync_cursor_write "$CURDIR" 42 || fail "cursor_write (overwrite) failed"
[[ "$(gluerun_graph_sync_cursor_read "$CURDIR")" == "42" ]] || fail "cursor did not overwrite to 42"
[[ "$(gluerun_graph_sync_cursor_read "$CURDIR")" == "$(gluerun_graph_sync_cursor_read "$CURDIR")" ]] \
  || fail "cursor read not deterministic"

# --- Fixture builder (mirrors the rebuild fixture; every integrated mapper) ----
build_state() { # <stateDir>
  local STATE="$1"
  local NODE="TASK-0080"
  local RUN_A="RUN-20260712T100000Z-00001"
  local RUN_B="RUN-20260712T110000Z-00002"
  local SHA_A="0123456789abcdef0123456789abcdef01234567"
  mkdir -p "$STATE/runs/$RUN_A/attempts" "$STATE/runs/$RUN_B" \
           "$STATE/docs/orchestration/gates" "$STATE/docs/orchestration/tasks"

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

  cat > "$STATE/docs/orchestration/tasks/$NODE.md" <<MD
# $NODE: Assemble the graph-projector rebuild entry point

Objective: walk the durable sources and rebuild the canonical corpus.
MD

  cat > "$STATE/events.ndjson" <<JSON
{"ts":"2026-07-12T10:00:00Z","type":"plan.revised","message":"m","data":{"node":"$NODE","runId":"$RUN_A"}}
{"ts":"2026-07-12T11:00:00Z","type":"plan.revised","message":"m","data":{"node":"$NODE","runId":"$RUN_B","revisesRunId":"$RUN_A"}}
{"ts":"2026-07-12T11:05:00Z","type":"context.strategy_selected","message":"m","data":{"node":"$NODE","runId":"$RUN_B"}}
{"ts":"2026-07-12T11:06:00Z","type":"decision.recorded","message":"m","data":{"node":"$NODE","runId":"$RUN_B"}}
{"ts":"2026-07-12T11:10:00Z","type":"l1.committed","message":"m","data":{"node":"$NODE","runId":"$RUN_B","headSha":"$SHA_A"}}
JSON
}

count_lines() { python3 -c 'import sys; print(sum(1 for _ in open(sys.argv[1])))' "$1"; }

# =============================================================================
# Rebuild equals sync — FROM SCRATCH (no prior corpus).
# =============================================================================
STATE="$work_root/state"
build_state "$STATE"
EVENTS_TOTAL="$(count_lines "$STATE/events.ndjson")"

GDIR_R="$work_root/graph-rebuild"
GDIR_S="$work_root/graph-sync"

gluerun_graph_rebuild "$STATE" "$GDIR_R" || fail "gluerun_graph_rebuild failed"

# sync into a fresh (empty) graphDir must equal a full rebuild, byte-for-byte.
state_before="$(cd "$STATE" && find . | LC_ALL=C sort)"
gluerun_graph_sync "$STATE" "$GDIR_S" || fail "gluerun_graph_sync (from scratch) failed"
state_after="$(cd "$STATE" && find . | LC_ALL=C sort)"
[[ "$state_before" == "$state_after" ]] || fail "sync wrote under <stateDir> (must write only under <graphDir>)"

[[ -f "$GDIR_S/nodes.jsonl" && -f "$GDIR_S/edges.jsonl" ]] || fail "sync did not write the corpus"
diff -q "$GDIR_R/nodes.jsonl" "$GDIR_S/nodes.jsonl" >/dev/null \
  || fail "rebuild != sync (nodes.jsonl) from scratch"
diff -q "$GDIR_R/edges.jsonl" "$GDIR_S/edges.jsonl" >/dev/null \
  || fail "rebuild != sync (edges.jsonl) from scratch"

# Every synced line validates against the SHIPPED schema.
validates_file "$GDIR_S/nodes.jsonl" || fail "a synced nodes.jsonl line failed schema validation"
validates_file "$GDIR_S/edges.jsonl" || fail "a synced edges.jsonl line failed schema validation"

# Authoritative/claim split preserved (commit + gate-result authoritative, else claim).
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
' "$GDIR_S/nodes.jsonl")"
[[ "$split_ok" == "ok" ]] || fail "authoritative/claim split violated in synced corpus"

# Cursor advanced to the consumed events.ndjson line count.
[[ "$(gluerun_graph_sync_cursor_read "$GDIR_S")" == "$EVENTS_TOTAL" ]] \
  || fail "sync did not advance cursor to events line count ($EVENTS_TOTAL)"

# --- Idempotence: repeated sync with no source change is byte-identical -------
cp "$GDIR_S/nodes.jsonl" "$work_root/nodes-sync1.jsonl"
cp "$GDIR_S/edges.jsonl" "$work_root/edges-sync1.jsonl"
gluerun_graph_sync "$STATE" "$GDIR_S" || fail "second gluerun_graph_sync failed"
diff -q "$work_root/nodes-sync1.jsonl" "$GDIR_S/nodes.jsonl" >/dev/null \
  || fail "nodes.jsonl not byte-identical on repeat sync (idempotence)"
diff -q "$work_root/edges-sync1.jsonl" "$GDIR_S/edges.jsonl" >/dev/null \
  || fail "edges.jsonl not byte-identical on repeat sync (idempotence)"
# No-new-events sync does not regress the cursor.
[[ "$(gluerun_graph_sync_cursor_read "$GDIR_S")" == "$EVENTS_TOTAL" ]] \
  || fail "no-new-events sync regressed the cursor"

# =============================================================================
# Rebuild equals sync — INCREMENTAL (rebuild, append events, sync).
# =============================================================================
STATE_I="$work_root/state-inc"
build_state "$STATE_I"
GDIR_I="$work_root/graph-inc"

# A full rebuild first, then seed the cursor to the current line count (as a
# rebuild-then-adopt-sync handoff would): starting the incremental append.
gluerun_graph_rebuild "$STATE_I" "$GDIR_I" || fail "incremental: initial rebuild failed"
gluerun_graph_sync "$STATE_I" "$GDIR_I" || fail "incremental: adopt-sync after rebuild failed"
BASE_TOTAL="$(count_lines "$STATE_I/events.ndjson")"
[[ "$(gluerun_graph_sync_cursor_read "$GDIR_I")" == "$BASE_TOTAL" ]] \
  || fail "incremental: cursor not at base line count after adopt-sync"

# Append brand-new events beyond the cursor.
NODE2="TASK-0081"
RUN_C="RUN-20260712T120000Z-00003"
SHA_B="89abcdef0123456789abcdef0123456789abcdef"
cat >> "$STATE_I/events.ndjson" <<JSON
{"ts":"2026-07-12T12:00:00Z","type":"plan.revised","message":"m","data":{"node":"$NODE2","runId":"$RUN_C"}}
{"ts":"2026-07-12T12:05:00Z","type":"decision.recorded","message":"m","data":{"node":"$NODE2","runId":"$RUN_C"}}
{"ts":"2026-07-12T12:10:00Z","type":"l1.committed","message":"m","data":{"node":"$NODE2","runId":"$RUN_C","headSha":"$SHA_B"}}
JSON
AUG_TOTAL="$(count_lines "$STATE_I/events.ndjson")"

# Incremental sync consumes only the appended events.
gluerun_graph_sync "$STATE_I" "$GDIR_I" || fail "incremental sync failed"
[[ "$(gluerun_graph_sync_cursor_read "$GDIR_I")" == "$AUG_TOTAL" ]] \
  || fail "incremental sync did not advance cursor to augmented line count"

# The synced corpus must equal a FRESH full rebuild over the augmented state.
GDIR_FRESH="$work_root/graph-fresh"
gluerun_graph_rebuild "$STATE_I" "$GDIR_FRESH" || fail "fresh rebuild over augmented state failed"
diff -q "$GDIR_FRESH/nodes.jsonl" "$GDIR_I/nodes.jsonl" >/dev/null \
  || fail "incremental sync != fresh rebuild (nodes.jsonl)"
diff -q "$GDIR_FRESH/edges.jsonl" "$GDIR_I/edges.jsonl" >/dev/null \
  || fail "incremental sync != fresh rebuild (edges.jsonl)"
validates_file "$GDIR_I/nodes.jsonl" || fail "incremental: a nodes.jsonl line failed schema validation"
validates_file "$GDIR_I/edges.jsonl" || fail "incremental: an edges.jsonl line failed schema validation"

# =============================================================================
# graphDir default resolves to ${GLUERUN_CTX_GRAPH_DIR}
# =============================================================================
DEFDIR="$work_root/defgraph"
( export GLUERUN_CTX_GRAPH_DIR="$DEFDIR"; gluerun_graph_sync "$STATE" ) \
  || fail "sync with default graphDir failed"
[[ -f "$DEFDIR/nodes.jsonl" && -f "$DEFDIR/edges.jsonl" ]] \
  || fail "sync did not honor GLUERUN_CTX_GRAPH_DIR default for graphDir"
diff -q "$GDIR_R/nodes.jsonl" "$DEFDIR/nodes.jsonl" >/dev/null \
  || fail "default-graphDir synced corpus differs from the rebuild corpus (nodes)"
diff -q "$GDIR_R/edges.jsonl" "$DEFDIR/edges.jsonl" >/dev/null \
  || fail "default-graphDir synced corpus differs from the rebuild corpus (edges)"

echo "test-ctx-graph-sync: all assertions passed"
