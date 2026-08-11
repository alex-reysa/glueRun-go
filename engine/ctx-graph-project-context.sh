#!/usr/bin/env bash
# ctx-graph-project-context.sh — S4 context-family source-record projection
# mappers (assumption, capsule) for the context provenance graph
# (schemas/context-graph.v0.schema.json).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions ONLY; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior
# (OFF-parity when SINGULAR_CTX_GRAPH is unset or 0). The mappers write NO file:
# each prints a `node` JSONL stream to stdout (one schema-valid line each; every
# line self-identifies via `kind`). These two families mint nodes only — the
# cross-family `derived_from` edges (assumption/capsule -> its task/attempt) are
# deferred to a follow-up linkage task.
#
# These compose the integrated primitives — the identity convention
# singular_graph_identity (engine/ctx-graph-project.sh) plus engine/ctx-graph.sh's
# singular_graph_node_id / singular_graph_emit_node — extending the graph-projector's
# inner layer with the assumption/capsule node families. A later `singular graph
# rebuild` entry point (behind SINGULAR_CTX_GRAPH, default 0) partitions the stream
# by `kind` and hands the node stream to the integrated corpus writer
# singular_graph_write_corpus (engine/ctx-graph-corpus.sh).
#
# Evidence class is fail-closed and delegated to singular_graph_emit_node: both
# `assumption` and `capsule` are model-authored (a task-authored assumption
# claim; an implementer/reviewer context capsule), so every node minted here is
# `claim`. No input path in this file mints an `authoritative` node.
#
# Public functions:
#   singular_graph_project_assumptions <taskFilePath>
#       -> parses the task markdown `## Context packet` `### Assumptions` block
#          (grammar `- [open|validated|violated] <claim> — <basis>`) and emits one
#          `assumption` node (claim) per entry, keyed identity('assumption',
#          taskId, entryKey) with attributes.status in {open, validated, violated}.
#          A task with no Context packet or no Assumptions entries emits nothing
#          (empty, not an error). No edge.
#   singular_graph_project_capsules <capsuleRecordPath>
#       -> reads a per-run implementer/reviewer context-capsule record
#          (implementer-capsule.json / reviewer-capsule.json; role + runId) and
#          emits one `capsule` node (claim) keyed identity('capsule', runId, role)
#          with provenance (source path + content hash) and attributes.role.
#          No edge.

# --- Slice 1: assumption mapper ----------------------------------------------

# Emit one `assumption` node per `### Assumptions` entry inside the task's
# `## Context packet`. The taskId is read from the first-line header
# `# TASK-XXXX: ...`. Each entry is keyed identity('assumption', taskId,
# entryKey) with entryKey the 1-based ordinal of the entry within the block, so
# ids are stable and collision-free per (taskId, entry) even when two claims are
# textually identical. attributes.status is the grammar status token. A task
# with no Context packet or no Assumptions entries emits nothing (empty, not an
# error). Deterministic and idempotent; pure stdout — writes no file.
singular_graph_project_assumptions() {
  local task_path="$1"
  local task_id
  task_id="$(SINGULAR_GP_PATH="$task_path" python3 -c '
import os, re, sys
with open(os.environ["SINGULAR_GP_PATH"], encoding="utf-8") as f:
    first = f.readline().rstrip("\n")
m = re.match(r"^#\s+(TASK-\w+)\b", first)
if not m:
    sys.exit(1)
print(m.group(1))
')" || return 1

  local key status attrs content_b64 content ident
  # US-delimited rows: entryKey, status, base64(canonical entry object).
  while IFS=$'\037' read -r key status content_b64; do
    [[ -n "$content_b64" ]] || continue
    content="$(printf '%s' "$content_b64" | base64 --decode)"
    ident="$(singular_graph_identity assumption "$task_id" "$key")"
    attrs="$(SINGULAR_GP_STATUS="$status" python3 -c '
import json, os
print(json.dumps({"status": os.environ["SINGULAR_GP_STATUS"]}, separators=(",", ":")))')"
    singular_graph_emit_node assumption "$ident" "$task_path" "$content" "" "$attrs"
  done < <(SINGULAR_GP_PATH="$task_path" python3 -c '
import os, re, json, base64

US = "\x1f"
with open(os.environ["SINGULAR_GP_PATH"], encoding="utf-8") as f:
    lines = f.read().split("\n")

# Locate the `## Context packet` section, then the `### Assumptions` subsection
# within it (bounded by the next `###` heading or a same/higher-level heading).
in_packet = False
in_assume = False
idx = 0
entry = re.compile(r"^-\s*\[(open|validated|violated)\]\s*(.*)$")
for raw in lines:
    line = raw.rstrip()
    stripped = line.strip()
    if stripped.startswith("## "):
        in_packet = stripped[3:].strip().lower() == "context packet"
        in_assume = False
        continue
    if not in_packet:
        continue
    if stripped.startswith("### "):
        in_assume = stripped[4:].strip().lower() == "assumptions"
        continue
    if not in_assume:
        continue
    m = entry.match(stripped)
    if not m:
        continue
    idx += 1
    status = m.group(1)
    rest = m.group(2).strip()
    claim, basis = rest, ""
    if " — " in rest:
        claim, basis = rest.split(" — ", 1)
        claim, basis = claim.strip(), basis.strip()
    obj = {"basis": basis, "claim": claim, "index": idx, "status": status}
    content = json.dumps(obj, sort_keys=True, separators=(",", ":"))
    b = base64.b64encode(content.encode()).decode()
    print(US.join([str(idx), status, b]))
')
}

# --- Slice 2: capsule mapper -------------------------------------------------

# Emit one `capsule` node (claim — a context capsule is model-authored, never
# authoritative) from an implementer/reviewer context-capsule record, keyed
# identity('capsule', runId, role) with attributes.role and provenance (source
# path + content hash). Deterministic and idempotent; pure stdout — writes no
# file.
singular_graph_project_capsules() {
  local record_path="$1"
  local run_id role attrs content_b64 content ident
  # Newline-delimited fields; attrs and content are single-line (no newlines).
  { read -r run_id
    read -r role
    read -r attrs
    read -r content_b64
  } < <(SINGULAR_GP_PATH="$record_path" python3 -c '
import json, os, base64
d = json.load(open(os.environ["SINGULAR_GP_PATH"]))
role = str(d.get("role", ""))
attrs = {"role": role}
content = json.dumps(d, sort_keys=True, separators=(",", ":"))
print(str(d.get("runId", "")))
print(role)
print(json.dumps(attrs, sort_keys=True, separators=(",", ":")))
print(base64.b64encode(content.encode()).decode())
') || return 1

  content="$(printf '%s' "$content_b64" | base64 --decode)"
  ident="$(singular_graph_identity capsule "$run_id" "$role")"
  singular_graph_emit_node capsule "$ident" "$record_path" "$content" "" "$attrs"
}
