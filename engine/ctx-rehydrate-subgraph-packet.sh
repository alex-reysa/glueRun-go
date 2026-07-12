#!/usr/bin/env bash
# ctx-rehydrate-subgraph-packet.sh — the ORDER-PRESERVING subgraph rehydration
# packet + manifest renderer and its composed graph entry point (stage S6-graph,
# node `subgraph-rehydrate`, layer engine_runtime). Sourced exactly once by the
# context-evolution loader block in lib.sh (it matches the ctx-*.sh glob). This
# file DEFINES new functions ONLY and is present-but-uncalled by every existing
# engine/CLI/driver path, so with it sourced the engine stays byte-identical to
# prior behavior (OFF-parity).
#
# This is the chained brick after the integrated selection reader (TASK-0099,
# gluerun_ctx_rehydrate_subgraph_select) and the node-record source-spec resolver
# (TASK-0101, gluerun_ctx_rehydrate_subgraph_sources) — the piece the resolver
# comment anticipates and the one that makes rehydration packets ASSEMBLED BY
# subgraph selection. It mirrors how the flat assembler engine/ctx-rehydrate.sh
# carries both packet and manifest modes, but renders in the INPUT (selection)
# order instead of re-sorting by the flat assembler RANK.
#
#   gluerun_ctx_rehydrate_subgraph_packet     # stdin: <source-class-id>=<path> specs
#   gluerun_ctx_rehydrate_subgraph_manifest   # stdin: <source-class-id>=<path> specs
#   gluerun_ctx_rehydrate_subgraph_assemble <graphDir> <taskNodeId> <packet|manifest>
#
# Renderers (slice 1): read the resolver output — `<source-class-id>=<path>`
# specs, one per line on stdin — and emit either the rehydration packet or the
# manifest, PRESERVING the input spec order (the selector's contradictions-first
# ordering). Caps and manifest schema are UNCHANGED from the flat assembler:
#
#   - `..._packet`   — one labeled `=== <source-class-id> ===` section per
#     surviving spec IN INPUT ORDER, each artifact body read READ-ONLY and capped
#     to GLUERUN_CONTEXT_SECTION_MAX_CHARS (default 4000) with the same stable
#     truncation marker convention as the flat assembler.
#   - `..._manifest` — a manifest conforming to the EXISTING schema
#     gluerun.orchestration.ctx-rehydrate-manifest.v0 (included source ids + the
#     sha256 of each artifact's bytes), sources listed in the same selection order.
#
# Per-node sections, not per-class dedup: because a subgraph can select several
# nodes of one class (e.g. multiple surviving findings), multiple sections may
# carry the same class label — one durable source per selected node, in selection
# order; this is intended.
#
# Quarantine-aware: each candidate is filtered through the integrated
# gluerun_ctx_artifact_exclude, so a quarantined source (a `.quarantined` path or
# one with a `.quarantined` sibling on disk) never reaches the packet or the
# manifest — the single quarantine authority is preserved. A declared-but-missing
# artifact contributes nothing (non-fatal).
#
# Composed graph entry point (slice 2): gluerun_ctx_rehydrate_subgraph_assemble
# pipes the integrated read path end-to-end — select the subgraph -> resolve
# source specs -> render (slice 1) — so a contradictions-first, capped packet or
# its matching manifest is produced directly from a graph dir + task node id.
#
# Choosing subgraph vs flat rehydration per A/B arm and the l1-drive.sh injection
# wire-in are SEPARATE later slices and are OUT OF SCOPE here.
#
# Evidence invariance / advocate-skeptic line: rendering is a PURE READ — it reads
# and hashes artifact bytes but never writes, renames, or deletes; appends no
# events; mutates no taint; confers NO independence (the rehydrate strategy stays
# tainted per gluerun_ctx_route_strategy_tainted); and records nothing as
# authoritative.

# gluerun_ctx_rehydrate_subgraph_packet   (specs on stdin)
gluerun_ctx_rehydrate_subgraph_packet() {
  _gluerun_ctx_rehydrate_subgraph_render packet
}

# gluerun_ctx_rehydrate_subgraph_manifest (specs on stdin)
gluerun_ctx_rehydrate_subgraph_manifest() {
  _gluerun_ctx_rehydrate_subgraph_render manifest
}

# Internal: read <id>=<path> specs from stdin IN ORDER, filter each through the
# integrated quarantine authority, and hand the surviving <id>\t<path> specs to
# the pure Python renderer for order-preserving capping, hashing, and emission.
_gluerun_ctx_rehydrate_subgraph_render() {
  local mode="$1"
  local spec id path survivor specs=""
  while IFS= read -r spec; do
    [[ "$spec" == *"="* ]] || continue
    id="${spec%%=*}"
    path="${spec#*=}"
    [[ -n "$id" && -n "$path" ]] || continue
    # Compose the single integrated quarantine filter: a quarantined candidate (a
    # *.quarantined path or an original with a .quarantined sibling) yields no
    # survivor and is silently excluded from the packet and the manifest.
    survivor="$(gluerun_ctx_artifact_exclude "$path")"
    [[ -n "$survivor" ]] || continue
    specs+="$id"$'\t'"$path"$'\n'
  done
  _gluerun_ctx_rehydrate_subgraph_render_py \
    "$mode" "${GLUERUN_CONTEXT_SECTION_MAX_CHARS:-4000}" "$specs"
}

# Internal: the pure Python renderer. Takes mode, section cap, and the newline-
# delimited surviving <id>\t<path> specs on argv (stdin is the heredoc script).
# Reads each artifact READ-ONLY and emits either the labeled packet or the JSON
# manifest, PRESERVING the input spec order (NO rank re-sort). Caps and manifest
# schema match the flat assembler exactly. No I/O beyond reading artifacts and
# writing stdout; no side effects.
_gluerun_ctx_rehydrate_subgraph_render_py() {
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib
import json
import sys

mode = sys.argv[1]
try:
    cap = int(sys.argv[2])
except (ValueError, IndexError):
    cap = 4000
specs = sys.argv[3] if len(sys.argv) > 3 else ""

# Same stable truncation marker convention as the flat assembler
# (engine/ctx-rehydrate.sh); caps UNCHANGED.
TRUNC = "\n[... rehydration section truncated to fit the context budget ...]"


def section_cap(text):
    if len(text) <= cap:
        return text
    keep = max(0, cap - len(TRUNC))
    return text[:keep] + TRUNC


# PRESERVE input order — the selector's contradictions-first ordering. Unlike the
# flat assembler this does NOT sort by source-class rank; one durable source per
# selected node, so a class label may repeat (per-node sections, not per-class
# dedup).
sources = []
for line in specs.splitlines():
    if "\t" not in line:
        continue
    sid, path = line.split("\t", 1)
    if not sid or not path:
        continue
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        # A declared-but-missing/unreadable durable artifact contributes nothing;
        # stay pure and non-fatal on well-formed input.
        continue
    sources.append((sid, path, data))

if mode == "manifest":
    obj = {
        "schema": "gluerun.orchestration.ctx-rehydrate-manifest.v0",
        "sources": [
            {"id": sid, "sha256": hashlib.sha256(data).hexdigest()}
            for sid, _path, data in sources
        ],
    }
    sys.stdout.write(json.dumps(obj, sort_keys=True, ensure_ascii=False))
    sys.stdout.write("\n")
else:
    parts = []
    for sid, _path, data in sources:
        parts.append("=== %s ===" % sid)
        parts.append(section_cap(data.decode("utf-8", "replace")))
    sys.stdout.write("\n".join(parts))
    sys.stdout.write("\n")
PY
}

# gluerun_ctx_rehydrate_subgraph_assemble <graphDir> <taskNodeId> <packet|manifest>
# Pipe the integrated read path end-to-end: select the subgraph -> resolve source
# specs -> render (slice 1), producing a contradictions-first, capped packet or
# its matching manifest directly from a graph dir + task node id. Pure read-only.
gluerun_ctx_rehydrate_subgraph_assemble() {
  local graph_dir="${1:-${GLUERUN_CTX_GRAPH_DIR:-.gluerun-state/graph}}"
  local task_node="${2:-}"
  local mode="${3:-packet}"
  case "$mode" in
    packet|manifest) ;;
    *) mode="packet" ;;
  esac
  gluerun_ctx_rehydrate_subgraph_select "$graph_dir" "$task_node" \
    | gluerun_ctx_rehydrate_subgraph_sources \
    | gluerun_ctx_rehydrate_subgraph_"$mode"
}
