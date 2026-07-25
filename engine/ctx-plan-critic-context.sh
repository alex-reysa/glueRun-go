#!/usr/bin/env bash
# ctx-plan-critic-context.sh — assemble the read-only staged-candidate critic
# context the S2 skeptic (node plan-critic-driver, layer engine_runtime) must
# actually receive.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-plan-critic.sh and engine/ctx-paired-audit.sh).
#
# Purpose: the integrated driver engine/ctx-plan-critic.sh (TASK-0013) wires the
# fresh, read-only default-runner critic call but invokes the runner with ONLY
# the base plan-critic prompt — it never composes the candidate CONTENT, so the
# critic is flown blind. This brick closes that gap: it builds the composed
# critic input from exactly what the driver stages — the rendered candidate task
# files in the node-local stage dir (`*.candidate.md`), the existing-task summary
# the planner itself was shown, and the node's own stage file under
# docs/context-build-plan/. Wiring the assembled context into the driver's runner
# invocation belongs to a later slice and is out of scope here.
#
# The assembler is PURE and READ-ONLY: it reads the staged inputs and writes ONLY
# its single composed output file. It appends no events, spawns no runner, and
# mutates nothing else — preserving the advocate/skeptic line and evidence
# invariance (the critic stays read-only, fresh-by-default, on the default runner,
# and never weakens, resumes into, or bypasses the un-bypassable implementation
# auditor). Candidate bodies compose in a stable (sorted) order so the composed
# context is byte-stable across runs for a fixed input set.
#
# Public entry points:
#   gluerun_ctx_plan_critic_stage_file <node>
#     Pure: print the node's stage file path under docs/context-build-plan/
#     (GLUERUN_PLAN_DIR), or empty when no stage file declares the node. Read-only;
#     depends on no network or mutable run state.
#   gluerun_ctx_plan_critic_context <node> <stage_dir> <out_file> [summary_file]
#     Pure: compose the read-only critic context — every `*.candidate.md` body in
#     <stage_dir> (sorted), the existing-task summary (summary_file, else
#     <stage_dir>/existing-tasks.md), and the node's stage-file content — into
#     <out_file>. Writes ONLY <out_file>; appends no events; invokes no runner.

# Pure resolver: print the node's stage file under the context-build-plan dir, or
# empty when no plan file declares the node. A node is "declared" by a
# backtick-wrapped mention of its name (e.g. "## Node `plan-critic-driver`").
# Files are scanned in sorted glob order and the first match wins, so resolution
# is deterministic. No side effects.
gluerun_ctx_plan_critic_stage_file() {
  local node="$1"
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }
  local plan_dir="${GLUERUN_PLAN_DIR:-$GLUERUN_ROOT/docs/context-build-plan}"
  [[ -d "$plan_dir" ]] || { printf '%s' ""; return 0; }
  local bt='`' pat f
  pat="${bt}${node}${bt}"
  for f in "$plan_dir"/*.md; do
    [[ -e "$f" ]] || continue
    if grep -qF -- "$pat" "$f" 2>/dev/null; then
      printf '%s' "$f"
      return 0
    fi
  done
  printf '%s' ""
}

# Pure assembler: compose the read-only critic context into <out_file>. Reads the
# staged candidate bodies, the existing-task summary, and the node stage file;
# writes ONLY the named output file and mutates nothing else. Deterministic: the
# `*.candidate.md` glob expands in sorted order, so the output is byte-stable
# across runs for a fixed input set.
gluerun_ctx_plan_critic_context() {
  local node="$1" stage_dir="$2" out_file="$3" summary_file="${4:-}"
  [[ -n "$out_file" ]] || return 2
  local candidate_batch_dir
  candidate_batch_dir="$(gluerun_task_batch_candidate_dir "$stage_dir")" || return 2

  [[ -n "$summary_file" ]] || summary_file="$stage_dir/existing-tasks.md"
  local stage_file; stage_file="$(gluerun_ctx_plan_critic_stage_file "$node")"

  mkdir -p "$(dirname "$out_file")"

  {
    printf '# Plan Critic Context: %s\n\n' "$node"
    printf 'Read-only staged-candidate context for the S2 plan critic (skeptic).\n\n'

    printf '## Candidate Tasks\n\n'
    local c
    for c in "$candidate_batch_dir"/*.candidate.md; do
      [[ -e "$c" ]] || continue
      printf '### %s\n\n' "$(basename "$c")"
      cat "$c"
      printf '\n'
    done

    printf '## Existing Task Summary\n\n'
    if [[ -f "$summary_file" ]]; then
      cat "$summary_file"
      printf '\n'
    fi

    printf '## Node Stage File\n\n'
    if [[ -n "$stage_file" && -f "$stage_file" ]]; then
      cat "$stage_file"
      printf '\n'
    fi
  } > "$out_file"

  return 0
}
