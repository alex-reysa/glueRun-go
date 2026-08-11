#!/usr/bin/env bash
# ctx-graph-project-plans.sh — plan-lifecycle source-record projection mappers
# for the context provenance graph (schemas/context-graph.v0.schema.json).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions ONLY; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior
# (OFF-parity when SINGULAR_CTX_GRAPH is unset or 0). The mappers write NO file:
# each prints a mixed node+edge JSONL stream to stdout (one schema-valid line
# each; every line self-identifies via `kind`).
#
# These compose the integrated primitives — the slice-1 identity convention
# singular_graph_identity (engine/ctx-graph-project.sh) plus engine/ctx-graph.sh's
# singular_graph_node_id / singular_graph_emit_node / singular_graph_emit_edge —
# extending the graph-projector's inner layer with the plan-lifecycle node/edge
# families. A later `singular graph rebuild` entry point (behind SINGULAR_CTX_GRAPH,
# default 0) partitions the stream by `kind` and hands the node/edge streams to
# the integrated corpus writer singular_graph_write_corpus (engine/ctx-graph-corpus.sh).
#
# Every node minted here is model-authored, so evidenceClass is `claim` for all
# four projected node types (plan-version, decision, critique, finding); no input
# path mints an `authoritative` node.
#
# Rows crossing the python->shell boundary are joined with US (0x1f) — a
# non-whitespace byte that cannot appear in these tokens or in base64 content, so
# an EMPTY field (e.g. an absent revisesRunId) is preserved (a whitespace IFS like
# TAB would collapse consecutive delimiters and silently drop it).
#
# Public functions:
#   singular_graph_project_plan_versions <eventsPath>
#       -> reads an event-log JSONL file ({type,message,ts,data} envelopes),
#          filters `plan.revised` events (data.node, data.runId, data.revisesRunId)
#          and emits one `plan-version` node (claim) per event keyed by
#          identity('plan-version', node, runId); when data.revisesRunId is
#          non-empty it additionally emits one `revises` edge and one `supersedes`
#          edge from the new version node to the prior version node id
#          (identity('plan-version', node, revisesRunId)); empty/absent -> no edge.
#   singular_graph_project_decisions <eventsPath>
#       -> filters `context.strategy_selected`, `decision.recorded`, and
#          `context.resume_failed` events and emits one `decision` node (claim)
#          each, keyed collision-free by (type, data.node, data.runId, ts). No edges.
#   singular_graph_project_critique <planCritiqueRecordPath>
#       -> reads a singular.orchestration.plan-critique.v0 record (node, runId,
#          findings[] with id/severity) and emits one `critique` node (claim,
#          identity('critique', node, runId)) plus one `finding` node (claim) per
#          findings[] entry keyed identity('finding', node, runId, findingId) with
#          attributes.severity projected.

# --- Slice 1: plan-version mapper --------------------------------------------

# Emit one `plan-version` node per `plan.revised` event, plus a `revises` + a
# `supersedes` edge from the new version to the prior version node when
# data.revisesRunId is non-empty. Deterministic and idempotent: the same source
# emits byte-identical lines. Pure stdout — writes no file.
singular_graph_project_plan_versions() {
  local events_path="$1"
  local node run_id revises content_b64 content
  local ident version_node prior_ident prior_node
  # US-delimited rows: node, runId, revisesRunId, base64(canonical event).
  while IFS=$'\037' read -r node run_id revises content_b64; do
    [[ -n "$content_b64" ]] || continue
    content="$(printf '%s' "$content_b64" | base64 --decode)"
    ident="$(singular_graph_identity plan-version "$node" "$run_id")"
    version_node="$(singular_graph_node_id "$ident")"
    singular_graph_emit_node plan-version "$ident" "$events_path" "$content"
    if [[ -n "$revises" ]]; then
      prior_ident="$(singular_graph_identity plan-version "$node" "$revises")"
      prior_node="$(singular_graph_node_id "$prior_ident")"
      singular_graph_emit_edge revises    "$version_node" "$prior_node" "$events_path" "$content"
      singular_graph_emit_edge supersedes "$version_node" "$prior_node" "$events_path" "$content"
    fi
  done < <(SINGULAR_GP_PATH="$events_path" python3 -c '
import json, os, base64
US = "\x1f"
for line in open(os.environ["SINGULAR_GP_PATH"], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    ev = json.loads(line)
    if ev.get("type") != "plan.revised":
        continue
    d = ev.get("data", {})
    content = json.dumps(ev, sort_keys=True, separators=(",", ":"))
    b = base64.b64encode(content.encode()).decode()
    print(US.join([d.get("node", ""), d.get("runId", ""), d.get("revisesRunId", ""), b]))
')
}

# --- Slice 2: decision mapper ------------------------------------------------

# Emit one `decision` node per `context.strategy_selected` / `decision.recorded`
# / `context.resume_failed` event, keyed collision-free by (type, node, runId, ts)
# so distinct events yield distinct ids. No edges. Deterministic and idempotent;
# pure stdout — writes no file.
singular_graph_project_decisions() {
  local events_path="$1"
  local etype node run_id ts content_b64 content ident
  # US-delimited rows: type, node, runId, ts, base64(canonical event).
  while IFS=$'\037' read -r etype node run_id ts content_b64; do
    [[ -n "$content_b64" ]] || continue
    content="$(printf '%s' "$content_b64" | base64 --decode)"
    ident="$(singular_graph_identity decision "$etype" "$node" "$run_id" "$ts")"
    singular_graph_emit_node decision "$ident" "$events_path" "$content"
  done < <(SINGULAR_GP_PATH="$events_path" python3 -c '
import json, os, base64
US = "\x1f"
MATCH = {"context.strategy_selected", "decision.recorded", "context.resume_failed"}
for line in open(os.environ["SINGULAR_GP_PATH"], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    ev = json.loads(line)
    t = ev.get("type")
    if t not in MATCH:
        continue
    d = ev.get("data", {})
    content = json.dumps(ev, sort_keys=True, separators=(",", ":"))
    b = base64.b64encode(content.encode()).decode()
    print(US.join([t, d.get("node", ""), d.get("runId", ""), ev.get("ts", ""), b]))
')
}

# --- Slice 3: critique/finding mapper ----------------------------------------

# Emit one `critique` node (identity('critique', node, runId)) plus one `finding`
# node per findings[] row (identity('finding', node, runId, findingId), with
# attributes.severity projected) from a singular.orchestration.plan-critique.v0
# record. Deterministic and idempotent; pure stdout — writes no file.
singular_graph_project_critique() {
  local record_path="$1"
  local node run_id record_b64 record_content
  # Newline-delimited fields; the base64 content is a single line (no newlines).
  { read -r node
    read -r run_id
    read -r record_b64
  } < <(SINGULAR_GP_PATH="$record_path" python3 -c '
import json, os, base64
d = json.load(open(os.environ["SINGULAR_GP_PATH"]))
content = json.dumps(d, sort_keys=True, separators=(",", ":"))
print(d["node"])
print(d["runId"])
print(base64.b64encode(content.encode()).decode())
') || return 1

  record_content="$(printf '%s' "$record_b64" | base64 --decode)"
  local crit_ident
  crit_ident="$(singular_graph_identity critique "$node" "$run_id")"
  singular_graph_emit_node critique "$crit_ident" "$record_path" "$record_content"

  local fid severity content_b64 content ident attrs
  # US-delimited rows: findingId, severity, base64(canonical finding row).
  while IFS=$'\037' read -r fid severity content_b64; do
    [[ -n "$content_b64" ]] || continue
    content="$(printf '%s' "$content_b64" | base64 --decode)"
    ident="$(singular_graph_identity finding "$node" "$run_id" "$fid")"
    attrs="$(SINGULAR_GP_SEV="$severity" python3 -c '
import json, os
print(json.dumps({"severity": os.environ["SINGULAR_GP_SEV"]}, separators=(",", ":")))')"
    singular_graph_emit_node finding "$ident" "$record_path" "$content" "" "$attrs"
  done < <(SINGULAR_GP_PATH="$record_path" python3 -c '
import json, os, base64
US = "\x1f"
d = json.load(open(os.environ["SINGULAR_GP_PATH"]))
for row in d.get("findings", []):
    content = json.dumps(row, sort_keys=True, separators=(",", ":"))
    b = base64.b64encode(content.encode()).decode()
    print(US.join([row.get("id", ""), row.get("severity", ""), b]))
')
}
