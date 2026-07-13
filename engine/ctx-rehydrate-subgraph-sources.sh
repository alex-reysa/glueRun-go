#!/usr/bin/env bash
# ctx-rehydrate-subgraph-sources.sh — pure, read-only, deterministic
# subgraph->source-spec resolver (stage S6-graph, node `subgraph-rehydrate`,
# layer engine_runtime). Sourced exactly once by the context-evolution loader
# block in lib.sh (it matches the ctx-*.sh glob). This file DEFINES a new
# function only and is present-but-uncalled by every existing engine/CLI/driver
# path, so with it sourced the engine stays byte-identical to prior behavior
# (OFF-parity).
#
#   gluerun_ctx_rehydrate_subgraph_sources [file]
#
# Reads the SELECTED subgraph — a stream of canonical
# schemas/context-graph.v0.schema.json NODE records (JSONL) — from stdin (or the
# optional file arg) and maps each selected node whose `type` has a durable
# rehydration source class onto one `<source-class-id>=<provenance.sourcePath>`
# spec on stdout. It is the bridge from graph nodes to the integrated rehydration
# assembler.
#
# Node-type -> source-class mapping (the durable classes; every other type —
# goal, plan-batch, plan-version, attempt, commit, gate-result, audit — has no
# durable rehydration source class and emits nothing):
#
#   task                        -> task-packet
#   capsule (attributes.role=implementer) -> implementer-capsule
#   capsule (attributes.role=reviewer)    -> reviewer-capsule
#   finding                     -> findings-ledger
#   assumption                  -> assumptions-ledger
#   critique                    -> critique-record
#   decision                    -> decision-record
#
# The emitted source-class ids match the integrated assembler vocabulary EXACTLY
# (the RANK in engine/ctx-rehydrate.sh, the same vocabulary as the run-dir
# resolver gluerun_ctx_rehydrate_sources in engine/ctx-rehydrate-sources.sh), so
# the resolver stdout composes directly as arguments to
# gluerun_ctx_rehydrate_packet / gluerun_ctx_rehydrate_manifest with caps and
# manifest UNCHANGED.
#
# Order: PRESERVES the input record order (the selection order emitted by the
# selector) — it does NOT re-sort by source-class rank — so the selector's
# contradictions-first ordering survives intact into a later order-preserving
# subgraph packet renderer slice.
#
# Data contract: consumes selected node records as INPUT; it does NOT call the
# TASK-0099 selection reader. The two pieces compose later purely through the
# canonical node-record JSONL contract, each fixture-tested on its own.
#
# Pure and READ-ONLY: it parses records but never writes, renames, or deletes;
# appends no events; and never exits non-zero on well-formed input (empty input
# yields no specs, non-fatal). It confers NO independence and records nothing as
# `authoritative` — the `rehydrate` strategy remains tainted per
# gluerun_ctx_route_strategy_tainted. It only maps selected records to specs.

# gluerun_ctx_rehydrate_subgraph_sources [file]
gluerun_ctx_rehydrate_subgraph_sources() {
  local src="${1-}"
  if [[ -n "$src" ]]; then
    _gluerun_ctx_rehydrate_subgraph_py <"$src"
  else
    _gluerun_ctx_rehydrate_subgraph_py
  fi
}

# Internal: the pure Python mapper. Reads canonical context-graph.v0 node records
# (JSONL) from stdin and writes one `<source-class-id>=<provenance.sourcePath>`
# spec per durable-class selected node, in INPUT order. The script is passed via
# `-c` (NOT a heredoc) so python3 stdin stays bound to the node-record stream. No
# I/O beyond reading stdin and writing stdout; no side effects.
_gluerun_ctx_rehydrate_subgraph_py() {
  python3 -c '
import json
import sys

# Node-type -> durable source-class id. Ids match the assembler vocabulary
# (RANK in engine/ctx-rehydrate.sh) exactly. capsule is resolved by role
# below (implementer-capsule / reviewer-capsule); node types absent from this
# map and absent from the capsule branch have no durable rehydration source
# class and emit nothing.
TYPE_CLASS = {
    "task": "task-packet",
    "finding": "findings-ledger",
    "assumption": "assumptions-ledger",
    "critique": "critique-record",
    "decision": "decision-record",
}
CAPSULE_ROLE_CLASS = {
    "implementer": "implementer-capsule",
    "reviewer": "reviewer-capsule",
}

out = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except ValueError:
        # A malformed line is not a canonical node record; stay pure and
        # non-fatal — contribute nothing.
        continue
    if not isinstance(rec, dict):
        continue
    # Only node records carry a durable source; edges and other kinds emit
    # nothing.
    if rec.get("kind") != "node":
        continue
    node_type = rec.get("type")
    if node_type == "capsule":
        role = ""
        attrs = rec.get("attributes")
        if isinstance(attrs, dict):
            role = str(attrs.get("role", ""))
        cls = CAPSULE_ROLE_CLASS.get(role)
    else:
        cls = TYPE_CLASS.get(node_type)
    if not cls:
        continue
    prov = rec.get("provenance")
    if not isinstance(prov, dict):
        continue
    path = prov.get("sourcePath")
    if not isinstance(path, str) or not path:
        continue
    out.append("%s=%s" % (cls, path))

if out:
    sys.stdout.write("\n".join(out))
    sys.stdout.write("\n")
'
}
