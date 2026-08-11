#!/usr/bin/env bash
# ctx-graph-project-planbatch.sh — plan-batch source-record projection mapper for
# the context provenance graph (schemas/context-graph.v0.schema.json).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines a new
# function ONLY; NO existing engine path invokes it, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# when SINGULAR_CTX_GRAPH is unset or 0). The mapper writes NO file: it prints a
# `node` JSONL stream to stdout (one schema-valid line; every line self-identifies
# via `kind`). This is the 12th of the 13 node types and the last with a durable
# source; it mints a node only — the `derived_from` edge from plan-batch to `goal`
# is deferred because `goal` has no durable source to mint (no docs/orchestration/
# goal.md, no DAG objective field), so plan-batch ships node-only until a goal
# record is introduced.
#
# It composes the integrated primitives — the identity convention
# singular_graph_identity (engine/ctx-graph-project.sh) plus engine/ctx-graph.sh's
# singular_graph_node_id / singular_graph_emit_node — extending the graph-projector's
# inner layer with the plan-batch node family. A later `singular graph rebuild`
# entry point (behind SINGULAR_CTX_GRAPH, default 0) partitions the stream by `kind`
# and hands the node stream to the integrated corpus writer
# singular_graph_write_corpus (engine/ctx-graph-corpus.sh).
#
# A plan-batch is model-authored, so evidenceClass is `claim` (delegated to
# singular_graph_emit_node) — no input path here mints an `authoritative` node.
#
# Public function:
#   singular_graph_project_plan_batch <sessionMetaRecordPath>
#       -> reads a durable S1 planner session-meta record (the `planner-session-
#          meta/planner.out` line carrying `node=`, `runId=`, `stage=`, `area=`,
#          and `staged:TASK-*` entries) and emits one `plan-batch` node (claim)
#          keyed identity('plan-batch', node, runId) with attributes projecting
#          stage/area and the staged-task count. TOLERANT: a missing optional
#          field is skipped, and a malformed, empty, or missing record yields no
#          node and a zero exit (fail-safe) — never a crash, never a partial line.

# --- plan-batch mapper -------------------------------------------------------

# Emit one `plan-batch` node from a planner session-meta record. The identity
# keys (node, runId) and attributes (stage, area, stagedTaskCount) are lifted from
# the record's key=value / staged:TASK-* tokens. Fail-safe: without a node token
# there is nothing to key, so the mapper emits no line and returns zero.
# Deterministic and idempotent: the same source emits byte-identical lines. Pure
# stdout — writes no file.
singular_graph_project_plan_batch() {
  local record_path="$1"
  local node run_id stage area count content_b64 content
  # Newline-delimited fields; the base64 content is a single line (no newlines).
  # The python reader is itself tolerant — any read error yields empty fields, so
  # a malformed/empty/missing record simply produces an empty `node` below.
  { read -r node
    read -r run_id
    read -r stage
    read -r area
    read -r count
    read -r content_b64
  } < <(SINGULAR_GP_PATH="$record_path" python3 -c '
import json, os, base64
node = run_id = stage = area = ""
count = 0
try:
    with open(os.environ["SINGULAR_GP_PATH"], encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("node="):
                node = line[len("node="):]
            elif line.startswith("runId="):
                run_id = line[len("runId="):]
            elif line.startswith("stage="):
                stage = line[len("stage="):]
            elif line.startswith("area="):
                area = line[len("area="):]
            elif line.startswith("staged:TASK-"):
                count += 1
except Exception:
    node = run_id = stage = area = ""
    count = 0
content = json.dumps(
    {"node": node, "runId": run_id, "stage": stage, "area": area, "stagedTaskCount": count},
    sort_keys=True, separators=(",", ":"))
print(node)
print(run_id)
print(stage)
print(area)
print(count)
print(base64.b64encode(content.encode()).decode())
')

  # Fail-safe: no node token -> nothing to key -> emit no line, exit zero.
  [[ -n "$node" ]] || return 0

  content="$(printf '%s' "$content_b64" | base64 --decode)"

  local attrs
  # Always project the staged-task count; project stage/area only when present
  # (a missing optional field is skipped, not emitted).
  attrs="$(SINGULAR_GP_STAGE="$stage" SINGULAR_GP_AREA="$area" SINGULAR_GP_COUNT="$count" python3 -c '
import json, os
a = {"stagedTaskCount": int(os.environ.get("SINGULAR_GP_COUNT") or 0)}
stage = os.environ.get("SINGULAR_GP_STAGE", "")
if stage:
    a["stage"] = stage
area = os.environ.get("SINGULAR_GP_AREA", "")
if area:
    a["area"] = area
print(json.dumps(a, sort_keys=True, separators=(",", ":")))')"

  local ident
  ident="$(singular_graph_identity plan-batch "$node" "$run_id")"
  singular_graph_emit_node plan-batch "$ident" "$record_path" "$content" "" "$attrs"
}
