#!/usr/bin/env bash
# Covers the assumption/capsule source-record projection mappers in
# engine/ctx-graph-project-context.sh — the graph-projector inner layer that
# turns two more integrated durable S4 context families (a task markdown
# `## Context packet` `### Assumptions` block and a per-run implementer/reviewer
# context-capsule record) into projected context-graph.v0 JSONL node lines by
# composing the integrated identity convention + emitters (engine/ctx-graph.sh,
# engine/ctx-graph-project.sh):
#   singular_graph_project_assumptions <taskFilePath>          -> assumption nodes (claim)
#   singular_graph_project_capsules    <capsuleRecordPath>     -> one capsule node (claim)
#
# Asserts: each `### Assumptions` entry (grammar `- [open|validated|violated]
# <claim> — <basis>`) yields exactly one claim `assumption` node keyed
# identity('assumption', taskId, entryKey) with attributes.status in {open,
# validated, violated} and a stable, collision-free id per (taskId, entry); a
# task with no Context packet OR no Assumptions entries yields NO nodes (empty,
# not an error); each capsule record yields exactly one claim `capsule` node
# keyed identity('capsule', runId, role) carrying provenance (source path +
# sha256: content hash) and attributes.role; every emitted line validates
# against the SHIPPED schema; evidence invariance (fail-closed — both families
# are model-authored, so no input path mints an authoritative node);
# determinism/idempotence (re-running emits byte-identical lines, so
# singular_graph_canonicalize collapses to the same canonical set); no edges; and
# OFF-parity/no-writes — sourcing the file invokes nothing and the mappers touch
# NO filesystem.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTEXT="$ENGINE_HOME/engine/ctx-graph-project-context.sh"
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
[[ -f "$CONTEXT" ]] || fail "impl not present yet: $CONTEXT (strict-test-first RED)"

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
( cd "$snap_dir" && source "$GRAPH" && source "$PROJECT" && source "$CONTEXT" ) \
  || fail "sourcing $CONTEXT failed"
after="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail "sourcing $CONTEXT created filesystem artifacts (OFF-parity)"

# shellcheck disable=SC1090
source "$GRAPH"   || fail "sourcing $GRAPH failed"
# shellcheck disable=SC1090
source "$PROJECT" || fail "sourcing $PROJECT failed"
# shellcheck disable=SC1090
source "$CORPUS"  || fail "sourcing $CORPUS failed"
# shellcheck disable=SC1090
source "$CONTEXT" || fail "sourcing $CONTEXT failed"
for fn in singular_graph_project_assumptions singular_graph_project_capsules; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $CONTEXT"
done

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
attr_field() { # <line> <attrKey> -> value of attributes.<attrKey>
  python3 -c 'import json,sys;print(json.load(sys.stdin).get("attributes",{}).get(sys.argv[1],""))' "$1"
}
prov_field() { # <line> <provKey>
  python3 -c 'import json,sys;print(json.load(sys.stdin).get("provenance",{}).get(sys.argv[1],""))' "$1"
}
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

NODE="TASK-0092"
RUN_A="RUN-20260712T100000Z-00001"

# --- Slice 1: assumption mapper ----------------------------------------------
task_md="$work_root/task.md"
cat > "$task_md" <<'MD'
# TASK-0092: graph-projector assumption + capsule coverage

Status: in-progress

## Context packet

### Decisions

- Land two new node mappers behind the OFF-parity convention.

### Assumptions

- [validated] The events log already carries l1.committed envelopes — basis: engine/ctx-graph-project-records.sh.
- [open] Some fixtures may omit a capsule record; the mapper must treat absence as empty — basis: the fail-safe contract.
- [violated] The prior taxonomy already covered assumption nodes — basis: schemas/context-graph.v0.schema.json enum.

### Rejected alternatives

- Editing an existing mapper in place — rejected: breaks OFF-parity.
MD

as_out="$(singular_graph_project_assumptions "$task_md")" || fail "project_assumptions failed"
[[ -n "$as_out" ]] || fail "project_assumptions produced no output"
printf '%s\n' "$as_out" | validates || fail "an assumption line failed schema validation:
$as_out"
# Exactly three assumption nodes (one per entry), no edges.
[[ "$(count_where "$as_out" kind node)" == "3" ]] || fail "expected exactly 3 assumption nodes"
[[ "$(count_where "$as_out" type assumption)" == "3" ]] || fail "nodes must all be type assumption"
[[ "$(count_where "$as_out" kind edge)" == "0" ]] || fail "assumption mapper must emit no edge"
# claim — a task-authored assumption is model-authored, never authoritative.
[[ "$(count_where "$as_out" evidenceClass claim)" == "3" ]] || fail "assumption nodes must be claim"
[[ "$(count_where "$as_out" evidenceClass authoritative)" == "0" ]] \
  || fail "assumption mapper must not mint an authoritative node"
# attributes.status covers each grammar status exactly once.
for st in open validated violated; do
  hit=0
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    [[ "$(printf '%s' "$l" | attr_field status)" == "$st" ]] && hit=$((hit+1))
  done <<< "$as_out"
  [[ "$hit" == "1" ]] || fail "expected exactly one assumption with status $st (got $hit)"
done
# Every emitted status is one of the three legal values.
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  s="$(printf '%s' "$l" | attr_field status)"
  case "$s" in open|validated|violated) : ;; *) fail "illegal assumption status: $s" ;; esac
done <<< "$as_out"
# Stable, collision-free ids: three distinct node ids.
distinct="$(printf '%s\n' "$as_out" | python3 -c 'import json,sys; ids=[json.loads(l)["id"] for l in sys.stdin if l.strip()]; print(len(set(ids)))')"
[[ "$distinct" == "3" ]] || fail "assumption node ids collide (want 3 distinct, got $distinct)"
# Every id agrees with node_id(identity('assumption', taskId, entryKey)) for some entryKey.
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  id="$(printf '%s' "$l" | jq_field id)"
  ok=0
  for k in 1 2 3; do
    want="$(singular_graph_node_id "$(singular_graph_identity assumption "$NODE" "$k")")"
    [[ "$id" == "$want" ]] && ok=1 && break
  done
  [[ "$ok" == "1" ]] || fail "assumption node id $id != node_id(identity('assumption', taskId, entryKey))"
done <<< "$as_out"
# Idempotence.
as_out_b="$(singular_graph_project_assumptions "$task_md")" || fail "second project_assumptions failed"
[[ "$as_out" == "$as_out_b" ]] || fail "project_assumptions is not idempotent"

# A task with NO Context packet emits nothing (empty, not an error).
task_nopacket="$work_root/task-nopacket.md"
cat > "$task_nopacket" <<'MD'
# TASK-0093: no packet here

Just an objective, no context packet section at all.
MD
np_out="$(singular_graph_project_assumptions "$task_nopacket")" || fail "project_assumptions (no packet) errored"
[[ -z "$np_out" ]] || fail "a task with no Context packet must emit nothing (got: $np_out)"

# A task with a packet but NO Assumptions entries emits nothing.
task_noassume="$work_root/task-noassume.md"
cat > "$task_noassume" <<'MD'
# TASK-0094: packet but no assumptions

## Context packet

### Decisions

- A decision with no assumptions block following it.
MD
na_out="$(singular_graph_project_assumptions "$task_noassume")" || fail "project_assumptions (no assumptions) errored"
[[ -z "$na_out" ]] || fail "a task with no Assumptions entries must emit nothing (got: $na_out)"

# --- Slice 2: capsule mapper -------------------------------------------------
impl_cap="$work_root/implementer-capsule.json"
cat > "$impl_cap" <<JSON
{
  "schema": "singular.orchestration.context-capsule.v0",
  "role": "implementer",
  "taskId": "$NODE",
  "runId": "$RUN_A",
  "attempt": 1,
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "nextAction": "await review",
  "packetSha256": "deadbeef"
}
JSON
rev_cap="$work_root/reviewer-capsule.json"
cat > "$rev_cap" <<JSON
{
  "schema": "singular.orchestration.context-capsule.v0",
  "role": "reviewer",
  "taskId": "$NODE",
  "runId": "$RUN_A",
  "attempt": 1,
  "verdict": "accepted",
  "auditedHeadSha": "0123456789abcdef0123456789abcdef01234567"
}
JSON

impl_out="$(singular_graph_project_capsules "$impl_cap")" || fail "project_capsules (implementer) failed"
[[ -n "$impl_out" ]] || fail "project_capsules produced no output"
printf '%s\n' "$impl_out" | validates || fail "the implementer capsule line failed schema validation:
$impl_out"
# Exactly one capsule node, no edge.
[[ "$(count_where "$impl_out" kind node)" == "1" ]] || fail "expected exactly one capsule node"
[[ "$(count_where "$impl_out" type capsule)" == "1" ]] || fail "node must be type capsule"
[[ "$(count_where "$impl_out" kind edge)" == "0" ]] || fail "capsule mapper must emit no edge"
# claim — a capsule is model-authored, never authoritative.
[[ "$(count_where "$impl_out" evidenceClass claim)" == "1" ]] || fail "capsule node must be claim"
[[ "$(count_where "$impl_out" evidenceClass authoritative)" == "0" ]] \
  || fail "capsule mapper must not mint an authoritative node"
# Keyed identity('capsule', runId, role).
impl_node="$(singular_graph_node_id "$(singular_graph_identity capsule "$RUN_A" implementer)")"
[[ "$(printf '%s' "$impl_out" | jq_field id)" == "$impl_node" ]] \
  || fail "capsule node id != node_id(identity('capsule', runId, role))"
# attributes.role projected.
[[ "$(printf '%s' "$impl_out" | attr_field role)" == "implementer" ]] \
  || fail "capsule node must project attributes.role"
# Provenance: source path + sha256: content hash.
[[ "$(printf '%s' "$impl_out" | prov_field sourcePath)" == "$impl_cap" ]] \
  || fail "capsule node provenance.sourcePath must be the record path"
ch="$(printf '%s' "$impl_out" | prov_field contentHash)"
[[ "$ch" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "capsule node provenance.contentHash must be sha256:<64hex> (got $ch)"
# Idempotence.
impl_out_b="$(singular_graph_project_capsules "$impl_cap")" || fail "second project_capsules failed"
[[ "$impl_out" == "$impl_out_b" ]] || fail "project_capsules is not idempotent"

# Reviewer capsule: same shape, distinct identity via role.
rev_out="$(singular_graph_project_capsules "$rev_cap")" || fail "project_capsules (reviewer) failed"
printf '%s\n' "$rev_out" | validates || fail "the reviewer capsule line failed schema validation:
$rev_out"
[[ "$(count_where "$rev_out" type capsule)" == "1" ]] || fail "reviewer capsule node must be type capsule"
[[ "$(printf '%s' "$rev_out" | attr_field role)" == "reviewer" ]] \
  || fail "reviewer capsule node must project attributes.role=reviewer"
rev_node="$(singular_graph_node_id "$(singular_graph_identity capsule "$RUN_A" reviewer)")"
[[ "$(printf '%s' "$rev_out" | jq_field id)" == "$rev_node" ]] \
  || fail "reviewer capsule node id != node_id(identity('capsule', runId, role))"
[[ "$impl_node" != "$rev_node" ]] \
  || fail "implementer and reviewer capsules of one run must have distinct node ids (role keys identity)"

# --- Determinism through the canonicalizer: same set collapses identically ----
canon_a="$(printf '%s\n' "$as_out" | singular_graph_canonicalize)"
canon_b="$(printf '%s\n' "$as_out_b" | singular_graph_canonicalize)"
[[ "$canon_a" == "$canon_b" ]] || fail "canonicalize over repeated assumption projection is not stable"
cap_canon_a="$(printf '%s\n' "$impl_out" | singular_graph_canonicalize)"
cap_canon_b="$(printf '%s\n' "$impl_out_b" | singular_graph_canonicalize)"
[[ "$cap_canon_a" == "$cap_canon_b" ]] || fail "canonicalize over repeated capsule projection is not stable"

# --- No-writes: mappers print JSONL and touch NO filesystem -------------------
w="$work_root/nowrite"; mkdir -p "$w"
w_before="$(cd "$w" && find . | LC_ALL=C sort)"
( cd "$w" \
  && singular_graph_project_assumptions "$task_md" >/dev/null \
  && singular_graph_project_capsules "$impl_cap" >/dev/null \
  && singular_graph_project_capsules "$rev_cap" >/dev/null )
w_after="$(cd "$w" && find . | LC_ALL=C sort)"
[[ "$w_before" == "$w_after" ]] || fail "a mapper wrote filesystem artifacts (must be pure stdout)"

echo "test-ctx-graph-project-context: all assertions passed"
