#!/usr/bin/env bash
# Covers the next strict-test-first slice of the executable DAG node
# `subgraph-rehydrate` (stage S6-graph, layer engine_runtime): the ORDER-
# PRESERVING subgraph rehydration packet + manifest renderer and its composed
# graph entry point in engine/ctx-rehydrate-subgraph-packet.sh. This is the
# brick the resolver comment (engine/ctx-rehydrate-subgraph-sources.sh)
# anticipates — the piece that makes rehydration packets ASSEMBLED BY subgraph
# selection.
#
#   gluerun_ctx_rehydrate_subgraph_packet             # stdin: <id>=<path> specs
#   gluerun_ctx_rehydrate_subgraph_manifest           # stdin: <id>=<path> specs
#   gluerun_ctx_rehydrate_subgraph_assemble <graphDir> <taskNodeId> <packet|manifest>
#
# The two renderers read the resolver output — `<source-class-id>=<path>` specs,
# one per line on stdin — and emit either the rehydration packet or the manifest,
# PRESERVING the input spec order (the selector's contradictions-first ordering)
# instead of re-sorting by the flat assembler RANK. Caps and manifest schema are
# UNCHANGED from the flat assembler engine/ctx-rehydrate.sh.
#
# Asserts:
#   - Order-preserving: given a fixed spec sequence, one `=== <id> ===` section
#     (packet) / one manifest entry per surviving spec IN INPUT ORDER, NOT
#     re-sorted into source-class rank order.
#   - Per-node sections, not per-class dedup: a repeated class label yields
#     repeated sections (one durable source per selected node).
#   - Caps: each section body capped to GLUERUN_CONTEXT_SECTION_MAX_CHARS with the
#     flat truncation marker; default 4000 honored.
#   - Manifest conforms to gluerun.orchestration.ctx-rehydrate-manifest.v0, sources
#     in selection order, each with the sha256 of that artifact's bytes.
#   - Quarantine-aware: a `.quarantined` path or a source with a `.quarantined`
#     sibling never reaches the packet or the manifest (composes the single
#     integrated authority gluerun_ctx_artifact_exclude).
#   - `gluerun_ctx_rehydrate_subgraph_assemble` pipes select -> sources -> render
#     end-to-end over a hand-authored fixture corpus, producing a contradictions-
#     first capped packet or its matching manifest.
#   - Determinism / fail-safe: identical inputs -> byte-identical packet AND
#     manifest; empty input and declared-but-missing artifacts are non-fatal.
#   - OFF-parity: sourcing the file defines the functions, invokes nothing, and
#     writes nothing; the read is pure (source tree byte-identical, rehydrate
#     strategy stays tainted).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
IMPL="$ENGINE_HOME/engine/ctx-rehydrate-subgraph-packet.sh"
GRAPH="$ENGINE_HOME/engine/ctx-graph.sh"
CORPUS="$ENGINE_HOME/engine/ctx-graph-corpus.sh"
QUERY="$ENGINE_HOME/engine/ctx-graph-query.sh"
SUBGRAPH="$ENGINE_HOME/engine/ctx-rehydrate-subgraph.sh"
SOURCES="$ENGINE_HOME/engine/ctx-rehydrate-subgraph-sources.sh"
SCHEMA_CORE="$ENGINE_HOME/schemas/orchestration/ctx-rehydrate-manifest.v0.schema.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- strict-test-first RED precondition: fail closed with no impl present -----
[[ -f "$IMPL" ]] || fail "impl not present yet: $IMPL (strict-test-first RED)"

tmp="$(mktemp -d)"
snap_dir="$(mktemp -d)"
trap 'rm -rf "$tmp" "$snap_dir"' EXIT
export GLUERUN_ROOT="$tmp"

# --- OFF-parity: sourcing the file invokes nothing and writes nothing ---------
before="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
( cd "$snap_dir" && source "$LIB" ) || fail "sourcing engine/lib.sh (with impl present) failed"
after="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail "sourcing $IMPL created filesystem artifacts (OFF-parity)"

# Renderers read specs on stdin; run each in a fresh sourced shell.
packet() {
  bash -c 'source "'"$LIB"'"; gluerun_ctx_rehydrate_subgraph_packet'
}
manifest() {
  bash -c 'source "'"$LIB"'"; gluerun_ctx_rehydrate_subgraph_manifest'
}
assemble() {
  bash -c 'source "'"$LIB"'"; gluerun_ctx_rehydrate_subgraph_assemble "$@"' _ "$@"
}
# section headers, in output order, from a packet on stdin
packet_ids() { grep -E '^=== .* ===$' | sed -E 's/^=== (.*) ===$/\1/'; }
# manifest ids, in output order
manifest_ids() {
  python3 -c 'import json,sys; print("\n".join(s["id"] for s in json.load(sys.stdin)["sources"]))'
}

[[ "$(type -t gluerun_ctx_rehydrate_subgraph_packet 2>/dev/null)" != "" ]] 2>/dev/null || true
for fn in gluerun_ctx_rehydrate_subgraph_packet gluerun_ctx_rehydrate_subgraph_manifest \
          gluerun_ctx_rehydrate_subgraph_assemble; do
  bash -c 'source "'"$LIB"'"; [[ "$(type -t '"$fn"')" == "function" ]]' \
    || fail "$fn not defined after sourcing engine/lib.sh"
done

# --- Durable artifact fixtures (resolver-style specs point at real bytes) -----
art="$tmp/art"; mkdir -p "$art"
p_crit="$art/plan-critique.json";      printf '{"critique":"c"}\n'    >"$p_crit"
p_find1="$art/findings-1.json";        printf '{"finding":"one"}\n'   >"$p_find1"
p_find2="$art/findings-2.json";        printf '{"finding":"two"}\n'   >"$p_find2"
p_task="$art/task-packet.json";        printf '{"task":"T"}\n'        >"$p_task"
p_dec="$art/decision-record.json";     printf '{"decision":"d"}\n'    >"$p_dec"

before_hash="$(find "$art" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"

# The resolver's contradictions-first order, with a REPEATED class label
# (findings-ledger twice, one durable source per selected node). Deliberately
# NOT in source-class rank order — rank would put task-packet first.
specs="critique-record=$p_crit
findings-ledger=$p_find1
findings-ledger=$p_find2
task-packet=$p_task
decision-record=$p_dec"

# --- Case 1: order-preserving packet, NOT re-sorted by rank ------------------
p1="$(printf '%s\n' "$specs" | packet)" || fail "case1: packet exited non-zero"
got_ids="$(printf '%s\n' "$p1" | packet_ids)"
want_ids="critique-record
findings-ledger
findings-ledger
task-packet
decision-record"
[[ "$got_ids" == "$want_ids" ]] || fail "case1: packet section order wrong (not input order).
got:
$got_ids
want:
$want_ids"
first="$(printf '%s\n' "$got_ids" | head -n1)"
[[ "$first" == "critique-record" ]] \
  || fail "case1: packet re-sorted by rank (first section [$first], expected critique-record)"

# --- Case 2: per-node sections, not per-class dedup --------------------------
find_count="$(printf '%s\n' "$got_ids" | grep -cx "findings-ledger")"
[[ "$find_count" == "2" ]] || fail "case2: repeated class label deduped (findings-ledger count=$find_count, want 2)"
# Both distinct bodies must be present (each per-node source rendered).
[[ "$p1" == *'"finding":"one"'* && "$p1" == *'"finding":"two"'* ]] \
  || fail "case2: both per-node finding bodies not rendered"

# --- Case 3: manifest — same selection order, conforms to core schema --------
m1="$(printf '%s\n' "$specs" | manifest)" || fail "case3: manifest exited non-zero"
got_mids="$(printf '%s\n' "$m1" | manifest_ids)"
[[ "$got_mids" == "$want_ids" ]] || fail "case3: manifest id order not selection order.
got:
$got_mids
want:
$want_ids"
# schema const + sha256 derived from artifact bytes
m_schema="$(printf '%s\n' "$m1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["schema"])')"
[[ "$m_schema" == "gluerun.orchestration.ctx-rehydrate-manifest.v0" ]] \
  || fail "case3: manifest schema const wrong: $m_schema"
task_hash="$(printf '%s\n' "$m1" | python3 -c 'import json,sys; print(next(s["sha256"] for s in json.load(sys.stdin)["sources"] if s["id"]=="task-packet"))')"
py_hash="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$p_task")"
[[ "$task_hash" == "$py_hash" ]] || fail "case3: manifest sha256 not derived from artifact bytes"
# Conform to the SHIPPED core schema via a minimal schema-driven validator.
VALIDATOR="$tmp/validator.py"
cat > "$VALIDATOR" <<'PY'
import json, re, sys
def validate(data, schema, path, errs):
    if "const" in schema and data != schema["const"]:
        errs.append(f"{path}: const mismatch")
    t = schema.get("type")
    if t == "object":
        if not isinstance(data, dict):
            errs.append(f"{path}: expected object"); return
        for r in schema.get("required", []):
            if r not in data: errs.append(f"{path}: missing required '{r}'")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for k in data:
                if k not in props: errs.append(f"{path}: unknown property '{k}'")
        for k, v in data.items():
            if k in props: validate(v, props[k], f"{path}/{k}", errs)
    elif t == "array":
        if not isinstance(data, list):
            errs.append(f"{path}: expected array"); return
        items = schema.get("items")
        if items is not None:
            for i, el in enumerate(data): validate(el, items, f"{path}[{i}]", errs)
    elif t == "string":
        if not isinstance(data, str):
            errs.append(f"{path}: expected string"); return
        if "minLength" in schema and len(data) < schema["minLength"]:
            errs.append(f"{path}: shorter than minLength")
        if "pattern" in schema and not re.search(schema["pattern"], data):
            errs.append(f"{path}: pattern mismatch")
with open(sys.argv[1], encoding="utf-8") as f:
    schema = json.load(f)
errs = []
validate(json.load(sys.stdin), schema, "$", errs)
if errs:
    print("\n".join(errs), file=sys.stderr); sys.exit(1)
PY
printf '%s\n' "$m1" | python3 "$VALIDATOR" "$SCHEMA_CORE" \
  || fail "case3: manifest does not conform to $SCHEMA_CORE"

# --- Case 4: caps (marker + default) ----------------------------------------
big="$(printf 'X%.0s' $(seq 1 9000))"
printf '%s\n' "$big" >"$art/big.json"
cp="$(printf 'task-packet=%s\n' "$art/big.json" | GLUERUN_CONTEXT_SECTION_MAX_CHARS=200 packet)" \
  || fail "case4: capped packet exited non-zero"
cbody="$(printf '%s\n' "$cp" | tail -n +2)"
(( ${#cbody} <= 200 )) || fail "case4: section body ${#cbody} exceeds cap 200"
[[ "$cbody" == *"truncated"* ]] || fail "case4: capped section missing truncation marker"
# Default cap 4000 honored: a 3000-char single-line body is NOT truncated.
mid="$(printf 'Y%.0s' $(seq 1 3000))"
printf '%s\n' "$mid" >"$art/mid.json"
dp="$(printf 'task-packet=%s\n' "$art/mid.json" | packet)" || fail "case4b: default-cap packet exited non-zero"
dbody="$(printf '%s\n' "$dp" | tail -n +2)"
(( ${#dbody} == 3000 )) || fail "case4b: default cap 4000 not honored (body=${#dbody})"
[[ "$dbody" != *"truncated"* ]] || fail "case4b: 3000-char body wrongly truncated under default cap"

# --- Case 5: quarantine exclusion (single authority) ------------------------
# critique-record: original present but a .quarantined sibling exists -> DROP.
printf '{"leak":"c"}\n' >"$p_crit.quarantined"
# decision-record: the spec path is itself a *.quarantined file -> DROP.
printf '{"leak":"d"}\n' >"$art/decision.json.quarantined"
q_specs="task-packet=$p_task
critique-record=$p_crit
findings-ledger=$p_find1
decision-record=$art/decision.json.quarantined"
qp="$(printf '%s\n' "$q_specs" | packet)"   || fail "case5: quarantine packet exited non-zero"
qm="$(printf '%s\n' "$q_specs" | manifest)" || fail "case5: quarantine manifest exited non-zero"
q_ids="$(printf '%s\n' "$qp" | packet_ids | tr '\n' ' ' | sed 's/ $//')"
[[ "$q_ids" == "task-packet findings-ledger" ]] \
  || fail "case5: quarantined sources leaked into packet. got:[$q_ids]"
qm_ids="$(printf '%s\n' "$qm" | manifest_ids | tr '\n' ' ' | sed 's/ $//')"
[[ "$qm_ids" == "task-packet findings-ledger" ]] \
  || fail "case5: quarantined sources leaked into manifest. got:[$qm_ids]"
[[ "$qp" != *"leak"* && "$qm" != *"leak"* ]] || fail "case5: quarantined bytes reached output"
rm -f "$p_crit.quarantined" "$art/decision.json.quarantined"

# --- Case 6: fail-safe (empty input, declared-but-missing artifact) ----------
empty_p="$(printf '' | packet)" || fail "case6: empty packet exited non-zero"
[[ -z "$(printf '%s\n' "$empty_p" | packet_ids)" ]] || fail "case6: empty input produced sections"
empty_m="$(printf '' | manifest)" || fail "case6: empty manifest exited non-zero"
empty_mids="$(printf '%s\n' "$empty_m" | manifest_ids)"
[[ -z "$empty_mids" ]] || fail "case6: empty input produced manifest sources: [$empty_mids]"
printf '%s\n' "$empty_m" | python3 "$VALIDATOR" "$SCHEMA_CORE" \
  || fail "case6: empty manifest does not conform to core schema"
# A declared-but-missing artifact contributes nothing (non-fatal), the present one survives.
miss_p="$(printf 'task-packet=%s\nfindings-ledger=%s\n' "$art/does-not-exist.json" "$p_find1" | packet)" \
  || fail "case6: missing-artifact packet exited non-zero"
miss_ids="$(printf '%s\n' "$miss_p" | packet_ids | tr '\n' ' ' | sed 's/ $//')"
[[ "$miss_ids" == "findings-ledger" ]] || fail "case6: missing artifact not skipped non-fatally. got:[$miss_ids]"

# --- Case 7: determinism -----------------------------------------------------
p1b="$(printf '%s\n' "$specs" | packet)"   || fail "case7: packet(2) exited non-zero"
m1b="$(printf '%s\n' "$specs" | manifest)" || fail "case7: manifest(2) exited non-zero"
[[ "$p1" == "$p1b" ]] || fail "case7: packet not byte-identical on repeat"
[[ "$m1" == "$m1b" ]] || fail "case7: manifest not byte-identical on repeat"

# =============================================================================
# Case 8: composed graph entry point over a hand-authored fixture corpus.
# select (contradictions-first) -> sources -> render, end to end.
#
# Corpus: task T with attempt A, plan-version P, critique C, TWO findings F1/F2
# (both derived, distinct durable sources -> two findings-ledger sections), and
# an assumption AS that is the target of an OPEN contradicts edge (surfaced
# FIRST). Provenance sourcePaths point at the real artifact files above.
# =============================================================================
EXCLUDE="$ENGINE_HOME/engine/ctx-artifact-exclude.sh"
source "$GRAPH"; source "$CORPUS"; source "$QUERY"; source "$SUBGRAPH"; source "$SOURCES"
source "$EXCLUDE"; source "$IMPL"

GDIR="$tmp/graph"
NODES_IN="$tmp/nodes.in"
EDGES_IN="$tmp/edges.in"

T="$(gluerun_graph_node_id 'task:T')"
A="$(gluerun_graph_node_id 'attempt:A')"
P="$(gluerun_graph_node_id 'pv:P')"
C="$(gluerun_graph_node_id 'crit:C')"
AS="$(gluerun_graph_node_id 'assume:AS')"
F1="$(gluerun_graph_node_id 'find:F1')"
F2="$(gluerun_graph_node_id 'find:F2')"
G="$(gluerun_graph_node_id 'pv:G')"

{
  gluerun_graph_emit_node task         'task:T'    "$p_task"  'cT'
  gluerun_graph_emit_node attempt      'attempt:A' 'src/A'    'cA'
  gluerun_graph_emit_node plan-version 'pv:P'      'src/P'    'cP'
  gluerun_graph_emit_node critique     'crit:C'    "$p_crit"  'cC'
  gluerun_graph_emit_node assumption   'assume:AS' "$art/assumptions.json" 'cAS'
  gluerun_graph_emit_node finding      'find:F1'   "$p_find1" 'cF1'
  gluerun_graph_emit_node finding      'find:F2'   "$p_find2" 'cF2'
  gluerun_graph_emit_node plan-version 'pv:G'      'src/G'    'cG'
} > "$NODES_IN"
printf '{"assume":"as"}\n' > "$art/assumptions.json"

{
  gluerun_graph_emit_edge implements   "$A"  "$T" 'src/e1' 'c1'
  gluerun_graph_emit_edge derived_from "$P"  "$A" 'src/e2' 'c2'
  gluerun_graph_emit_edge critiques    "$C"  "$P" 'src/e3' 'c3'
  gluerun_graph_emit_edge derived_from "$AS" "$P" 'src/e4' 'c4'
  gluerun_graph_emit_edge derived_from "$F1" "$C" 'src/e5' 'c5'
  gluerun_graph_emit_edge derived_from "$F2" "$C" 'src/e6' 'c6'
  gluerun_graph_emit_edge contradicts  "$G"  "$AS" 'src/e7' 'c7'
} > "$EDGES_IN"

gluerun_graph_write_corpus "$GDIR" "$NODES_IN" "$EDGES_IN" || fail "case8: write_corpus failed"

# assemble MUST equal the composed pipeline select | sources | render.
pipe_packet="$(gluerun_ctx_rehydrate_subgraph_select "$GDIR" "$T" \
  | gluerun_ctx_rehydrate_subgraph_sources \
  | gluerun_ctx_rehydrate_subgraph_packet)" || fail "case8: composed pipeline (packet) failed"
asm_packet="$(assemble "$GDIR" "$T" packet)" || fail "case8: assemble packet exited non-zero"
[[ "$asm_packet" == "$pipe_packet" ]] \
  || fail "case8: assemble packet != select|sources|packet pipeline"

pipe_manifest="$(gluerun_ctx_rehydrate_subgraph_select "$GDIR" "$T" \
  | gluerun_ctx_rehydrate_subgraph_sources \
  | gluerun_ctx_rehydrate_subgraph_manifest)" || fail "case8: composed pipeline (manifest) failed"
asm_manifest="$(assemble "$GDIR" "$T" manifest)" || fail "case8: assemble manifest exited non-zero"
[[ "$asm_manifest" == "$pipe_manifest" ]] \
  || fail "case8: assemble manifest != select|sources|manifest pipeline"

# Contradictions-first: the flagged assumption AS surfaces first, so the FIRST
# packet section is assumptions-ledger.
asm_ids="$(printf '%s\n' "$asm_packet" | packet_ids)"
asm_first="$(printf '%s\n' "$asm_ids" | head -n1)"
[[ "$asm_first" == "assumptions-ledger" ]] \
  || fail "case8: contradictions-first violated (first section [$asm_first], want assumptions-ledger)"
# Two findings selected -> two findings-ledger sections (per-node, not deduped).
asm_find_count="$(printf '%s\n' "$asm_ids" | grep -cx "findings-ledger")"
[[ "$asm_find_count" == "2" ]] || fail "case8: expected 2 per-node findings-ledger sections, got $asm_find_count"
# assemble manifest conforms to the core schema.
printf '%s\n' "$asm_manifest" | python3 "$VALIDATOR" "$SCHEMA_CORE" \
  || fail "case8: assemble manifest does not conform to core schema"
# The off-lineage contradiction source G contributes nothing (no plan-version has
# a durable rehydration source class anyway), and its src/G never renders.
[[ "$asm_packet" != *"src/G"* ]] || fail "case8: off-lineage source leaked into packet"
# Determinism of assemble.
asm_packet2="$(assemble "$GDIR" "$T" packet)" || fail "case8: assemble packet(2) exited non-zero"
[[ "$asm_packet" == "$asm_packet2" ]] || fail "case8: assemble packet not deterministic"

# assemble default mode is packet.
asm_default="$(assemble "$GDIR" "$T")" || fail "case8: assemble default-mode exited non-zero"
[[ "$asm_default" == "$asm_packet" ]] || fail "case8: assemble default mode is not packet"

# --- Case 9: purity / evidence invariance -----------------------------------
after_hash="$(find "$art" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
# (art gained big/mid/assumptions fixtures during the run; snapshot around a lone
# assemble to prove the render itself is read-only.)
corpus_snap() { ( cd "$GDIR" && find . | LC_ALL=C sort; cat "$GDIR/nodes.jsonl" "$GDIR/edges.jsonl" | shasum | awk '{print $1}' ); }
snap_before="$(corpus_snap)"
assemble "$GDIR" "$T" packet >/dev/null   || fail "case9: read-only assemble failed"
assemble "$GDIR" "$T" manifest >/dev/null || fail "case9: read-only assemble(manifest) failed"
snap_after="$(corpus_snap)"
[[ "$snap_before" == "$snap_after" ]] || fail "case9: assemble mutated the corpus (must be read-only)"

# grants no independence: rehydrate strategy stays tainted.
tainted="$(bash -c 'source "'"$LIB"'"; gluerun_ctx_route_strategy_tainted rehydrate')" \
  || fail "case9: taint query exited non-zero"
[[ "$tainted" == "1" ]] || fail "case9: rehydrate strategy no longer tainted (got [$tainted])"

echo "test-ctx-rehydrate-subgraph-packet: all assertions passed"
