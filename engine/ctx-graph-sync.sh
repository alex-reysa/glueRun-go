#!/usr/bin/env bash
# ctx-graph-sync.sh — the graph-projector `sync` entry point for the context
# provenance graph (schemas/context-graph.v0.schema.json): the incremental append
# that satisfies the `rebuild equals sync on fixtures` requiredCompletion property.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions ONLY; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior
# (OFF-parity when SINGULAR_CTX_GRAPH is unset or 0). The eventual `cli/singular
# graph` call site is a later task. singular_graph_sync writes ONLY under the
# passed <graphDir>; it reads <stateDir> and touches no other path.
#
# This composes the integrated rebuild machinery: the event mappers
# (singular_graph_project_plan_versions / _decisions / _commits), the bounded
# record mappers (attempts, gate-results, tasks, paired-audits, critiques), the
# `kind`-partition helper (singular_graph_partition, engine/ctx-graph-rebuild.sh)
# and the loss-free canonical writer (singular_graph_write_corpus,
# engine/ctx-graph-corpus.sh). An event-log cursor makes the append-only
# events.ndjson incremental; the bounded record sources are safely re-walked
# (idempotent — duplicates collapse in the writer's canonicalizer). Because
# singular_graph_write_corpus re-canonicalizes (dedup by id + sort by id), the
# union of the existing corpus and the newly-projected delta converges to the same
# canonical corpus a full rebuild produces over the augmented source set — so
# `sync` equals `rebuild` regardless of how the source set was chunked.
#
# Public functions:
#   singular_graph_sync_cursor_read  <graphDir>
#       -> print the count of events.ndjson lines already projected, persisted at
#          <graphDir>/.sync-cursor. A missing/absent cursor reads as 0. A malformed
#          cursor also reads as 0 (fail-closed to a full re-projection). Pure and
#          deterministic — no filesystem writes.
#   singular_graph_sync_cursor_write <graphDir> <n>
#       -> persist <n> as the cursor at <graphDir>/.sync-cursor (creating <graphDir>
#          if needed). Deterministic: the same <n> yields byte-identical state.
#   singular_graph_sync <stateDir> [graphDir]
#       -> read the existing corpus (if any) + the cursor, project the
#          events.ndjson lines BEYOND the cursor via the event mappers, reproject
#          the bounded record-based sources, merge every line with the existing
#          corpus, partition via singular_graph_partition, write the canonical
#          corpus via singular_graph_write_corpus, then advance the cursor to the
#          current events.ndjson line count. <graphDir> defaults to
#          ${SINGULAR_CTX_GRAPH_DIR:-.singular-state/graph}.

# --- Slice 1: event-log cursor -----------------------------------------------

# Resolve the cursor file for a graph dir (kept beside the corpus so it survives a
# corpus rewrite — singular_graph_write_corpus only clears nodes/edges).
_singular_graph_sync_cursor_path() {
  printf '%s/.sync-cursor' "$1"
}

# Print the count of events.ndjson lines already projected. Missing or malformed
# cursor -> 0 (fail-closed to a full re-projection). Pure: reads only, no writes.
singular_graph_sync_cursor_read() {
  local graph_dir="$1"
  local cursor_file
  cursor_file="$(_singular_graph_sync_cursor_path "$graph_dir")"
  if [[ ! -f "$cursor_file" ]]; then
    printf '0\n'
    return 0
  fi
  local raw
  IFS= read -r raw < "$cursor_file" || raw=""
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$raw"
  else
    printf '0\n'
  fi
}

# Persist <n> as the cursor for <graphDir>. Deterministic; creates <graphDir>.
singular_graph_sync_cursor_write() {
  local graph_dir="$1" n="$2"
  mkdir -p "$graph_dir" || return 1
  printf '%s\n' "$n" > "$(_singular_graph_sync_cursor_path "$graph_dir")"
}

# --- Slice 2: sync entry point -----------------------------------------------

# Physical line count of a file (counts a final unterminated line), matching how
# the event mappers iterate the source; a missing file counts as 0.
_singular_graph_sync_line_count() {
  local f="$1"
  if [[ -f "$f" ]]; then
    SINGULAR_GS_PATH="$f" python3 -c '
import os
print(sum(1 for _ in open(os.environ["SINGULAR_GS_PATH"], encoding="utf-8")))'
  else
    printf '0\n'
  fi
}

# Rewrite provenance.sourcePath on a projected JSONL stream (stdin) to <sourcePath>
# and re-emit each line canonically (sort_keys + compact separators, exactly as
# the emitters do). Used so an events delta projected from a temp slice carries the
# canonical <stateDir>/events.ndjson sourcePath a full rebuild would emit — keeping
# sync byte-identical to rebuild while only reading the beyond-cursor lines.
_singular_graph_sync_setpath() {
  SINGULAR_GS_SP="$1" python3 -c '
import json, os, sys
sp = os.environ["SINGULAR_GS_SP"]
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        continue
    o = json.loads(line)
    o["provenance"]["sourcePath"] = sp
    print(json.dumps(o, separators=(",", ":"), sort_keys=True))
'
}

# Incrementally project <stateDir> into the canonical corpus under <graphDir>.
# Seeds the merge with the existing corpus, appends the events delta beyond the
# cursor (event mappers) and a full re-walk of the bounded record sources, then
# partitions and hands the streams to singular_graph_write_corpus. The writer's
# dedup-by-id + sort-by-id makes the union converge to the same canonical corpus a
# full rebuild produces over the augmented source set. Finally advances the cursor
# to the current events.ndjson line count.
singular_graph_sync() {
  local state_dir="$1"
  local graph_dir="${2:-${SINGULAR_CTX_GRAPH_DIR:-.singular-state/graph}}"
  local events_path="$state_dir/events.ndjson"

  local work
  work="$(mktemp -d)" || return 1
  local combined="$work/combined.jsonl"
  local nodes_in="$work/nodes.jsonl"
  local edges_in="$work/edges.jsonl"
  : > "$combined"

  local rc=0 f

  # 1. Seed the merge with the existing corpus so already-projected lines (notably
  #    event nodes at or below the cursor, which we do NOT re-read) are retained.
  [[ -f "$graph_dir/nodes.jsonl" ]] && cat "$graph_dir/nodes.jsonl" >> "$combined"
  [[ -f "$graph_dir/edges.jsonl" ]] && cat "$graph_dir/edges.jsonl" >> "$combined"

  # 2. Event delta BEYOND the cursor. Slice out the new lines into a temp file,
  #    project them, and normalize sourcePath back to the canonical events path so
  #    the emitted lines match a full rebuild byte-for-byte.
  local cursor total
  cursor="$(singular_graph_sync_cursor_read "$graph_dir")"
  total="$(_singular_graph_sync_line_count "$events_path")"
  if [[ -f "$events_path" && "$total" -gt "$cursor" ]]; then
    local delta="$work/events-delta.ndjson"
    SINGULAR_GS_CUR="$cursor" SINGULAR_GS_PATH="$events_path" python3 -c '
import os, sys
cur = int(os.environ["SINGULAR_GS_CUR"])
with open(os.environ["SINGULAR_GS_PATH"], encoding="utf-8") as fh:
    for i, line in enumerate(fh):
        if i >= cur:
            sys.stdout.write(line)
' > "$delta" || rc=1
    singular_graph_project_plan_versions "$delta" | _singular_graph_sync_setpath "$events_path" >> "$combined" || rc=1
    singular_graph_project_decisions     "$delta" | _singular_graph_sync_setpath "$events_path" >> "$combined" || rc=1
    singular_graph_project_commits       "$delta" | _singular_graph_sync_setpath "$events_path" >> "$combined" || rc=1
  fi

  # 3. Reproject the bounded record-based sources in full (idempotent — duplicates
  #    collapse in the canonicalizer). Same walks as singular_graph_rebuild, with
  #    the real source paths, so their emitted lines match byte-for-byte.

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

  # runs/*/plan-critique.json -> critique node + finding nodes
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    singular_graph_project_critique "$f" >> "$combined" || rc=1
  done < <(find "$state_dir/runs" -mindepth 2 -maxdepth 2 -type f \
             -name 'plan-critique.json' 2>/dev/null | LC_ALL=C sort)

  # docs/orchestration/tasks/TASK-*.md -> task node + assumption nodes. Guard on
  # the S4 context mapper's presence exactly as singular_graph_rebuild does, so an
  # isolated harness sourcing only a mapper subset degrades identically and the
  # sync == rebuild equivalence holds byte-for-byte.
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

  # 4/5. Partition the merged stream and write the canonical corpus. The writer
  #      re-canonicalizes (dedup by id + sort by id) so the union converges to the
  #      rebuild corpus regardless of chunking.
  singular_graph_partition "$nodes_in" "$edges_in" < "$combined" \
    || { rm -rf "$work"; return 1; }
  singular_graph_write_corpus "$graph_dir" "$nodes_in" "$edges_in" \
    || { rm -rf "$work"; return 1; }

  # 6. Advance the cursor to the consumed events.ndjson line count.
  singular_graph_sync_cursor_write "$graph_dir" "$total" \
    || { rm -rf "$work"; return 1; }

  rm -rf "$work"
}
