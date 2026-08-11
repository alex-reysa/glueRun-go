#!/usr/bin/env bash
# Covers the task/commit/paired-audit source-record projection mappers in
# engine/ctx-graph-project-records.sh — the graph-projector inner layer that
# turns integrated durable S0 records (a task markdown header, `l1.committed`
# event-log envelopes {type,message,ts,data}, and a paired-audit record) into
# projected context-graph.v0 JSONL node lines by composing the integrated
# identity convention + emitters (engine/ctx-graph.sh, engine/ctx-graph-project.sh):
#   singular_graph_project_task          <taskFilePath>           -> one task node (claim)
#   singular_graph_project_commits       <eventsPath>             -> commit nodes (authoritative)
#   singular_graph_project_paired_audits <pairedAuditRecordPath>  -> one audit node (claim)
#
# Asserts: a task markdown yields exactly one claim `task` node whose id equals
# node_id(identity('task', taskId)) — the same id the integrated `implements`
# edge targets — so that dangling edge target is now minted; each `l1.committed`
# event yields exactly one `commit` node keyed by data.headSha with evidenceClass
# authoritative (a git commit is a host-verified fact), and two events sharing a
# headSha collapse to one node under singular_graph_canonicalize; the paired-audit
# record yields exactly one claim `audit` node keyed identity('audit', runId)
# carrying attributes for verdict/findingsCount/disagreement (never authoritative,
# even though it is a verdict); every emitted line validates against the SHIPPED
# schema; evidence invariance (fail-closed — no model path mints authoritative;
# commit is authoritative only because it is host-verified); determinism/
# idempotence (re-running emits byte-identical lines, so singular_graph_canonicalize
# collapses to the same canonical set); no edges; and OFF-parity/no-writes —
# sourcing the file invokes nothing and the mappers touch NO filesystem.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORDS="$ENGINE_HOME/engine/ctx-graph-project-records.sh"
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
[[ -f "$RECORDS" ]] || fail "impl not present yet: $RECORDS (strict-test-first RED)"

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
( cd "$snap_dir" && source "$GRAPH" && source "$PROJECT" && source "$RECORDS" ) \
  || fail "sourcing $RECORDS failed"
after="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail "sourcing $RECORDS created filesystem artifacts (OFF-parity)"

# shellcheck disable=SC1090
source "$GRAPH"   || fail "sourcing $GRAPH failed"
# shellcheck disable=SC1090
source "$PROJECT" || fail "sourcing $PROJECT failed"
# shellcheck disable=SC1090
source "$CORPUS"  || fail "sourcing $CORPUS failed"
# shellcheck disable=SC1090
source "$RECORDS" || fail "sourcing $RECORDS failed"
for fn in singular_graph_project_task singular_graph_project_commits \
          singular_graph_project_paired_audits; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $RECORDS"
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

NODE="TASK-0080"
RUN_A="RUN-20260712T100000Z-00001"
RUN_B="RUN-20260712T110000Z-00002"
SHA_A="0123456789abcdef0123456789abcdef01234567"
SHA_B="fedcba9876543210fedcba9876543210fedcba98"

# --- Slice 1: task mapper ----------------------------------------------------
task_md="$work_root/task.md"
cat > "$task_md" <<MD
# TASK-0080: Extend the graph-projector with task/commit/audit node families

Objective: project the task node so the integrated implements edge stops dangling.
MD

task_out="$(singular_graph_project_task "$task_md")" || fail "project_task failed"
[[ -n "$task_out" ]] || fail "project_task produced no output"
printf '%s\n' "$task_out" | validates || fail "the task line failed schema validation:
$task_out"
# Exactly one task node, no edge.
[[ "$(count_where "$task_out" kind node)" == "1" ]] || fail "expected exactly one task node"
[[ "$(count_where "$task_out" type task)" == "1" ]] || fail "node must be type task"
[[ "$(count_where "$task_out" kind edge)" == "0" ]] || fail "task mapper must emit no edge"
# claim (a task file is model-authored).
[[ "$(count_where "$task_out" evidenceClass claim)" == "1" ]] || fail "task node must be claim"
# Id agreement: the node id is exactly the one the integrated implements edge targets.
task_node="$(singular_graph_node_id "$(singular_graph_identity task "$NODE")")"
[[ "$(printf '%s' "$task_out" | jq_field id)" == "$task_node" ]] \
  || fail "task node id != node_id(identity('task', taskId))"
# Idempotence.
task_out_b="$(singular_graph_project_task "$task_md")" || fail "second project_task failed"
[[ "$task_out" == "$task_out_b" ]] || fail "project_task is not idempotent"

# --- Slice 2: commit mapper --------------------------------------------------
ev_commits="$work_root/events-commits.jsonl"
cat > "$ev_commits" <<JSON
{"ts":"2026-07-12T10:00:00Z","type":"l1.committed","message":"m","data":{"node":"$NODE","runId":"$RUN_A","headSha":"$SHA_A"}}
{"ts":"2026-07-12T11:00:00Z","type":"l1.committed","message":"m","data":{"node":"$NODE","runId":"$RUN_B","headSha":"$SHA_B"}}
{"ts":"2026-07-12T11:05:00Z","type":"plan.revised","message":"noise","data":{"node":"$NODE","runId":"$RUN_B"}}
JSON

cm_out="$(singular_graph_project_commits "$ev_commits")" || fail "project_commits failed"
[[ -n "$cm_out" ]] || fail "project_commits produced no output"
printf '%s\n' "$cm_out" | validates || fail "a commit line failed schema validation:
$cm_out"
# One commit node per l1.committed event (2 events -> 2 nodes), no edges.
[[ "$(count_where "$cm_out" kind node)" == "2" ]] || fail "expected 2 commit nodes"
[[ "$(count_where "$cm_out" type commit)" == "2" ]] || fail "nodes must all be type commit"
[[ "$(count_where "$cm_out" kind edge)" == "0" ]] || fail "commit mapper must emit no edge"
# Commit nodes are authoritative — a git commit is a host-verified fact.
[[ "$(count_where "$cm_out" evidenceClass authoritative)" == "2" ]] \
  || fail "commit nodes must be authoritative"
# Keyed by data.headSha: node id == node_id(identity('commit', headSha)).
commitA="$(singular_graph_node_id "$(singular_graph_identity commit "$SHA_A")")"
commitB="$(singular_graph_node_id "$(singular_graph_identity commit "$SHA_B")")"
[[ "$commitA" != "$commitB" ]] || fail "distinct headSha produced identical commit node id"
printf '%s\n' "$cm_out" | grep -qF "\"id\":\"$commitA\"" \
  || fail "commit node id != node_id(identity('commit', headSha)) for SHA_A"
printf '%s\n' "$cm_out" | grep -qF "\"id\":\"$commitB\"" \
  || fail "commit node id != node_id(identity('commit', headSha)) for SHA_B"
# Two events sharing a headSha collapse to one node under canonicalize.
ev_dupe="$work_root/events-commits-dupe.jsonl"
cat > "$ev_dupe" <<JSON
{"ts":"2026-07-12T10:00:00Z","type":"l1.committed","message":"m","data":{"node":"$NODE","runId":"$RUN_A","headSha":"$SHA_A"}}
{"ts":"2026-07-12T12:00:00Z","type":"l1.committed","message":"m","data":{"node":"$NODE","runId":"$RUN_B","headSha":"$SHA_A"}}
JSON
dupe_out="$(singular_graph_project_commits "$ev_dupe")" || fail "project_commits (dupe) failed"
[[ "$(count_where "$dupe_out" kind node)" == "2" ]] || fail "expected 2 raw commit lines pre-canonicalize"
canon_dupe="$(printf '%s\n' "$dupe_out" | singular_graph_canonicalize)"
[[ "$(count_where "$canon_dupe" kind node)" == "1" ]] \
  || fail "two events sharing a headSha must collapse to one node under canonicalize"
# Idempotence.
cm_out_b="$(singular_graph_project_commits "$ev_commits")" || fail "second project_commits failed"
[[ "$cm_out" == "$cm_out_b" ]] || fail "project_commits is not idempotent"

# --- Slice 3: paired-audit mapper --------------------------------------------
audit="$work_root/paired-audit.json"
cat > "$audit" <<JSON
{
  "schema": "singular.orchestration.paired-audit.v0",
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

au_out="$(singular_graph_project_paired_audits "$audit")" || fail "project_paired_audits failed"
[[ -n "$au_out" ]] || fail "project_paired_audits produced no output"
printf '%s\n' "$au_out" | validates || fail "the audit line failed schema validation:
$au_out"
# Exactly one audit node, no edge.
[[ "$(count_where "$au_out" kind node)" == "1" ]] || fail "expected exactly one audit node"
[[ "$(count_where "$au_out" type audit)" == "1" ]] || fail "node must be type audit"
[[ "$(count_where "$au_out" kind edge)" == "0" ]] || fail "audit mapper must emit no edge"
# claim — the auditor is itself a model, never authoritative, even for a verdict.
[[ "$(count_where "$au_out" evidenceClass claim)" == "1" ]] \
  || fail "audit node must be claim (never authoritative)"
[[ "$(count_where "$au_out" evidenceClass authoritative)" == "0" ]] \
  || fail "audit verdict must not mint an authoritative node"
# Keyed identity('audit', runId).
audit_node="$(singular_graph_node_id "$(singular_graph_identity audit "$RUN_A")")"
[[ "$(printf '%s' "$au_out" | jq_field id)" == "$audit_node" ]] \
  || fail "audit node id != node_id(identity('audit', runId))"
# attributes project verdict/findingsCount/disagreement.
au_attr="$(printf '%s' "$au_out" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin).get("attributes",{}),sort_keys=True))')"
[[ "$(printf '%s' "$au_attr" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("verdict",""))')" == "rejected" ]] \
  || fail "audit node must project attributes.verdict"
[[ "$(printf '%s' "$au_attr" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("findingsCount",""))')" == "1" ]] \
  || fail "audit node must project attributes.findingsCount"
[[ "$(printf '%s' "$au_attr" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("disagreement",""))')" == "True" ]] \
  || fail "audit node must project attributes.disagreement"
# Idempotence.
au_out_b="$(singular_graph_project_paired_audits "$audit")" || fail "second project_paired_audits failed"
[[ "$au_out" == "$au_out_b" ]] || fail "project_paired_audits is not idempotent"

# --- Evidence invariance (fail-closed) ---------------------------------------
# No model-authored input path (task, audit) mints an authoritative node; commit
# is authoritative solely because a git commit is a host-verified fact.
[[ "$(count_where "$task_out" evidenceClass authoritative)" == "0" ]] \
  || fail "task mapper minted an authoritative node (evidence invariance breach)"
[[ "$(count_where "$au_out" evidenceClass authoritative)" == "0" ]] \
  || fail "audit mapper minted an authoritative node (evidence invariance breach)"

# --- Determinism through the canonicalizer: same set collapses identically ----
canon_a="$(printf '%s\n' "$cm_out" | singular_graph_canonicalize)"
canon_b="$(printf '%s\n' "$cm_out_b" | singular_graph_canonicalize)"
[[ "$canon_a" == "$canon_b" ]] || fail "canonicalize over repeated projection is not stable"

# --- No-writes: mappers print JSONL and touch NO filesystem -------------------
w="$work_root/nowrite"; mkdir -p "$w"
w_before="$(cd "$w" && find . | LC_ALL=C sort)"
( cd "$w" \
  && singular_graph_project_task "$task_md" >/dev/null \
  && singular_graph_project_commits "$ev_commits" >/dev/null \
  && singular_graph_project_paired_audits "$audit" >/dev/null )
w_after="$(cd "$w" && find . | LC_ALL=C sort)"
[[ "$w_before" == "$w_after" ]] || fail "a mapper wrote filesystem artifacts (must be pure stdout)"

echo "test-ctx-graph-project-records: all assertions passed"
