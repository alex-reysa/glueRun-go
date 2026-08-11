#!/usr/bin/env bash
# ctx-graph-project-records.sh — task/commit/paired-audit source-record
# projection mappers for the context provenance graph
# (schemas/context-graph.v0.schema.json).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions ONLY; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior
# (OFF-parity when SINGULAR_CTX_GRAPH is unset or 0). The mappers write NO file:
# each prints a `node` JSONL stream to stdout (one schema-valid line each; every
# line self-identifies via `kind`). These three families mint nodes only — the
# cross-record edges (audit verifies/contradicts the accepted attempt, and the
# task's depends_on) are deferred to a follow-up linkage task.
#
# These compose the integrated primitives — the identity convention
# singular_graph_identity (engine/ctx-graph-project.sh) plus engine/ctx-graph.sh's
# singular_graph_node_id / singular_graph_emit_node — extending the graph-projector's
# inner layer with the task/commit/audit node families. A later `singular graph
# rebuild` entry point (behind SINGULAR_CTX_GRAPH, default 0) partitions the stream
# by `kind` and hands the node stream to the integrated corpus writer
# singular_graph_write_corpus (engine/ctx-graph-corpus.sh).
#
# Evidence class is fail-closed and delegated to singular_graph_emit_node: `commit`
# is `authoritative` SOLELY because a git commit is a host-verified fact; `task`
# and `audit` are `claim` (a task file and an auditor verdict are both
# model-authored). No input path here mints an `authoritative` node except the
# host-verified commit.
#
# Public functions:
#   singular_graph_project_task <taskFilePath>
#       -> parses the task markdown first-line header `# TASK-XXXX: ...` for the
#          taskId and emits one `task` node (claim) keyed identity('task', taskId)
#          — the exact node the integrated `implements` (attempt->task) and
#          gate-result target edges already point at. No edge.
#   singular_graph_project_commits <eventsPath>
#       -> reads an event-log JSONL file ({type,message,ts,data} envelopes),
#          filters `l1.committed` events (data.headSha, data.node, data.runId) and
#          emits one `commit` node (authoritative) each keyed identity('commit',
#          headSha); two events sharing a headSha collapse under canonicalize. No edge.
#   singular_graph_project_paired_audits <pairedAuditRecordPath>
#       -> reads a singular.orchestration.paired-audit.v0 record (runId, taskId,
#          verdict, findingsCount, disagreement/agreement) and emits one `audit`
#          node (claim) keyed identity('audit', runId) with attributes projecting
#          verdict/findingsCount/disagreement. No edge.

# --- Slice 1: task mapper ----------------------------------------------------

# Emit one `task` node from a task markdown file. The taskId is read from the
# first-line header `# TASK-XXXX: ...`. The node id is node_id(identity('task',
# taskId)) — the same id the integrated `implements` and gate-result edges target,
# so this closes those dangling edge targets. Deterministic and idempotent: the
# same source emits byte-identical lines. Pure stdout — writes no file.
singular_graph_project_task() {
  local task_path="$1"
  local task_id content_b64 content
  # Newline-delimited fields; the base64 content is a single line (no newlines).
  { read -r task_id
    read -r content_b64
  } < <(SINGULAR_GP_PATH="$task_path" python3 -c '
import os, re, base64, sys
with open(os.environ["SINGULAR_GP_PATH"], encoding="utf-8") as f:
    first = f.readline().rstrip("\n")
m = re.match(r"^#\s+(TASK-\w+)\b", first)
if not m:
    sys.exit(1)
task_id = m.group(1)
print(task_id)
print(base64.b64encode(first.encode()).decode())
') || return 1

  content="$(printf '%s' "$content_b64" | base64 --decode)"
  local ident
  ident="$(singular_graph_identity task "$task_id")"
  singular_graph_emit_node task "$ident" "$task_path" "$content"
}

# --- Slice 2: commit mapper --------------------------------------------------

# Emit one `commit` node (authoritative — a git commit is a host-verified fact)
# per `l1.committed` event, keyed identity('commit', headSha) so events sharing a
# headSha collapse to one node under the canonicalizer. No edge. Deterministic and
# idempotent; pure stdout — writes no file.
singular_graph_project_commits() {
  local events_path="$1"
  local head_sha content_b64 content ident
  # US-delimited rows: headSha, base64(canonical event).
  while IFS=$'\037' read -r head_sha content_b64; do
    [[ -n "$content_b64" ]] || continue
    content="$(printf '%s' "$content_b64" | base64 --decode)"
    ident="$(singular_graph_identity commit "$head_sha")"
    singular_graph_emit_node commit "$ident" "$events_path" "$content"
  done < <(SINGULAR_GP_PATH="$events_path" python3 -c '
import json, os, base64
US = "\x1f"
for line in open(os.environ["SINGULAR_GP_PATH"], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    ev = json.loads(line)
    if ev.get("type") != "l1.committed":
        continue
    d = ev.get("data", {})
    head = d.get("headSha", "")
    if not head:
        continue
    content = json.dumps(ev, sort_keys=True, separators=(",", ":"))
    b = base64.b64encode(content.encode()).decode()
    print(US.join([head, b]))
')
}

# --- Slice 3: paired-audit mapper --------------------------------------------

# Emit one `audit` node (claim — the auditor is itself a model, never
# authoritative even for a verdict) from a singular.orchestration.paired-audit.v0
# record, keyed identity('audit', runId) with attributes projecting
# verdict/findingsCount/disagreement. No edge. Deterministic and idempotent; pure
# stdout — writes no file.
singular_graph_project_paired_audits() {
  local record_path="$1"
  local run_id attrs content_b64 content ident
  # Newline-delimited fields; attrs and content are single-line (no newlines).
  { read -r run_id
    read -r attrs
    read -r content_b64
  } < <(SINGULAR_GP_PATH="$record_path" python3 -c '
import json, os, base64
d = json.load(open(os.environ["SINGULAR_GP_PATH"]))
attrs = {
    "verdict": d.get("verdict"),
    "findingsCount": d.get("findingsCount"),
    "disagreement": d.get("disagreement"),
}
content = json.dumps(d, sort_keys=True, separators=(",", ":"))
print(d["runId"])
print(json.dumps(attrs, sort_keys=True, separators=(",", ":")))
print(base64.b64encode(content.encode()).decode())
') || return 1

  content="$(printf '%s' "$content_b64" | base64 --decode)"
  ident="$(singular_graph_identity audit "$run_id")"
  singular_graph_emit_node audit "$ident" "$record_path" "$content" "" "$attrs"
}
