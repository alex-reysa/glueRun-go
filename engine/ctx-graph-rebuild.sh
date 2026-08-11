#!/usr/bin/env bash
# ctx-graph-rebuild.sh — the graph-projector `rebuild` entry point for the context
# provenance graph (schemas/context-graph.v0.schema.json).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions ONLY; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior
# (OFF-parity when SINGULAR_CTX_GRAPH is unset or 0). The eventual `cli/singular
# graph` call site is a later task. singular_graph_rebuild writes ONLY under the
# passed <graphDir> (via singular_graph_write_corpus); it reads <stateDir> and
# touches no other path.
#
# This is the composition keystone: it walks the durable S0-S5 sources under
# <stateDir>, invokes every integrated projection mapper over its source set,
# partitions the mappers' mixed node+edge stream by `kind`, and delegates
# canonical writing to singular_graph_write_corpus (engine/ctx-graph-corpus.sh).
# Determinism comes for free from the canonicalizer inside the writer (dedup by
# id + sort by id), so the final corpus is independent of walk/emission order
# provided the walk reads a complete, stable set of source files.
#
# Public functions:
#   singular_graph_partition <nodesOut> <edgesOut>
#       Read a mixed node+edge JSONL stream on stdin; route every `kind` node
#       line to <nodesOut> and every `kind` edge line to <edgesOut>, losslessly
#       (no line dropped, duplicated, or mutated) and deterministically. Bridges
#       the mappers' mixed stdout to the separate node/edge inputs that
#       singular_graph_write_corpus expects.
#   singular_graph_rebuild <stateDir> [graphDir]
#       Walk the durable sources under <stateDir> in sorted order and invoke each
#       integrated mapper over its source set — runs/*/attempts/index.json via
#       singular_graph_project_attempts; docs/orchestration/gates/*.gate-result.json
#       via singular_graph_project_gate_results; events.ndjson via
#       singular_graph_project_plan_versions / singular_graph_project_decisions /
#       singular_graph_project_commits; runs/*/plan-critique.json via
#       singular_graph_project_critique; docs/orchestration/tasks/TASK-*.md via
#       singular_graph_project_task; and runs/*/paired-audit.json via
#       singular_graph_project_paired_audits — collect every emitted line, partition
#       it, and call singular_graph_write_corpus <graphDir> to write the canonical
#       nodes.jsonl + edges.jsonl. <graphDir> defaults to
#       ${SINGULAR_CTX_GRAPH_DIR:-.singular-state/graph}.

# --- Slice 1: kind-partition helper ------------------------------------------

# Route a mixed node+edge JSONL stream on stdin: every `kind` node line to
# <nodesOut>, every `kind` edge line to <edgesOut>. Lossless — no line dropped,
# duplicated, or mutated (each surviving line is written back byte-for-byte).
# Blank/whitespace-only lines carry no record and are skipped. Deterministic:
# the same input yields byte-identical outputs.
singular_graph_partition() {
  local nodes_out="$1" edges_out="$2"
  SINGULAR_GP_NODES="$nodes_out" SINGULAR_GP_EDGES="$edges_out" python3 -c '
import json, os, sys
with open(os.environ["SINGULAR_GP_NODES"], "w", encoding="utf-8") as nf, \
     open(os.environ["SINGULAR_GP_EDGES"], "w", encoding="utf-8") as ef:
    for line in sys.stdin:
        rec = line.rstrip("\n")
        if not rec.strip():
            continue
        kind = json.loads(rec)["kind"]
        out = rec + "\n"
        if kind == "node":
            nf.write(out)
        elif kind == "edge":
            ef.write(out)
'
}

# --- Slice 2: rebuild entry point --------------------------------------------

# Walk the durable sources under <stateDir> in sorted order, invoke each
# integrated mapper over its source set, partition the collected node+edge stream
# with singular_graph_partition, and hand the two streams to
# singular_graph_write_corpus <graphDir>. Deterministic + loss-free: the writer's
# canonicalizer dedups by id and sorts by id, so equal source sets yield a
# byte-identical corpus and deleting <graphDir> then re-running reproduces it.
singular_graph_rebuild() {
  local state_dir="$1"
  local graph_dir="${2:-${SINGULAR_CTX_GRAPH_DIR:-.singular-state/graph}}"

  local work
  work="$(mktemp -d)" || return 1
  local combined="$work/combined.jsonl"
  local nodes_in="$work/nodes.jsonl"
  local edges_in="$work/edges.jsonl"
  : > "$combined"

  local rc=0 f
  # Every mapper prints JSONL to stdout; append it all to a single combined
  # stream. Walk each source set in sorted order for a stable, complete read
  # (final ordering is irrelevant — the writer sorts by id).

  # runs/*/attempts/index.json -> attempt nodes + implements edges
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    singular_graph_project_attempts "$f" >> "$combined" || rc=1
  done < <(find "$state_dir/runs" -mindepth 3 -maxdepth 3 -type f \
             -path '*/attempts/index.json' 2>/dev/null | LC_ALL=C sort)

  # docs/orchestration/gates/*.gate-result.json -> gate-result node + verify/invalidate edge
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    singular_graph_project_gate_results "$f" >> "$combined" || rc=1
  done < <(find "$state_dir/docs/orchestration/gates" -mindepth 1 -maxdepth 1 -type f \
             -name '*.gate-result.json' 2>/dev/null | LC_ALL=C sort)

  # events.ndjson -> plan-version (+revises/supersedes), decision, commit
  if [[ -f "$state_dir/events.ndjson" ]]; then
    singular_graph_project_plan_versions "$state_dir/events.ndjson" >> "$combined" || rc=1
    singular_graph_project_decisions     "$state_dir/events.ndjson" >> "$combined" || rc=1
    singular_graph_project_commits       "$state_dir/events.ndjson" >> "$combined" || rc=1
  fi

  # runs/*/plan-critique.json -> critique node + finding nodes
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    singular_graph_project_critique "$f" >> "$combined" || rc=1
  done < <(find "$state_dir/runs" -mindepth 2 -maxdepth 2 -type f \
             -name 'plan-critique.json' 2>/dev/null | LC_ALL=C sort)

  # docs/orchestration/tasks/TASK-*.md -> task node + assumption nodes.
  # The S4 context mappers (singular_graph_project_assumptions / _capsules,
  # engine/ctx-graph-project-context.sh) are sibling ctx-*.sh files loaded by the
  # lib.sh ctx-loader alongside this one; guard on their presence so the walk
  # degrades gracefully in an isolated harness that sources only a mapper subset
  # (the guard is identical in singular_graph_sync, preserving sync == rebuild).
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    singular_graph_project_task "$f" >> "$combined" || rc=1
    if declare -F singular_graph_project_assumptions >/dev/null 2>&1; then
      singular_graph_project_assumptions "$f" >> "$combined" || rc=1
    fi
  done < <(find "$state_dir/docs/orchestration/tasks" -mindepth 1 -maxdepth 1 -type f \
             -name 'TASK-*.md' 2>/dev/null | LC_ALL=C sort)

  # runs/*/paired-audit.json -> audit node
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    singular_graph_project_paired_audits "$f" >> "$combined" || rc=1
  done < <(find "$state_dir/runs" -mindepth 2 -maxdepth 2 -type f \
             -name 'paired-audit.json' 2>/dev/null | LC_ALL=C sort)

  # runs/*/{implementer,reviewer}-capsule.json -> capsule node (see guard note above).
  if declare -F singular_graph_project_capsules >/dev/null 2>&1; then
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      singular_graph_project_capsules "$f" >> "$combined" || rc=1
    done < <(find "$state_dir/runs" -mindepth 2 -maxdepth 2 -type f \
               \( -name 'implementer-capsule.json' -o -name 'reviewer-capsule.json' \) \
               2>/dev/null | LC_ALL=C sort)
  fi

  if [[ "$rc" -ne 0 ]]; then
    rm -rf "$work"
    return 1
  fi

  singular_graph_partition "$nodes_in" "$edges_in" < "$combined" \
    || { rm -rf "$work"; return 1; }
  singular_graph_write_corpus "$graph_dir" "$nodes_in" "$edges_in" \
    || { rm -rf "$work"; return 1; }

  rm -rf "$work"
}
