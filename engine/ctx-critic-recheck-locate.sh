#!/usr/bin/env bash
# ctx-critic-recheck-locate.sh — the pure, read-only LOCATOR brick the terminal
# post-acceptance recheck hook needs. Stage-file deliverable of the executable DAG
# node `critic-carryover` (stage S3-plan-revision, area plancritic, layer
# engine_runtime, kind runtime).
#
# The recheck runner singular_ctx_critic_recheck_run (TASK-0031) requires two inputs
# that are NOT in scope at the l1-drive.sh acceptance site: (1) the executable DAG
# node that owns the accepted task's critiqued batch, and (2) the path to the prior
# singular.orchestration.plan-critique.v0 record produced for that node at planning
# time. The acceptance hook (alongside the integrated paired-audit hook, TASK-0006)
# has only run_id, task_id, run_dir and worktree in scope — it carries neither the
# originating node nor the critique-record path. The critic session is node-keyed
# (<state-dir>/sessions/plan-critic/<node>.json, TASK-0013) and the critique record
# is written per node (<stage_dir>/plan-critique.json), so the recheck can only
# resume the right specialist session and classify against the right prior findings
# once the node and record are resolved from the accepted task. This brick supplies
# exactly that resolution, reading ONLY already-integrated artifacts: the durable
# task->node association recorded into the control-state event log by
# generate-tasks.sh / the l1 importer (planner.staged / planner.generated events
# carrying data.taskId + data.node), and the plan-critique record convention.
#
# It builds on integrated work only and does NOT depend on the recheck runner
# (engine/ctx-critic-recheck-run.sh, TASK-0031, accepted but not yet integrated).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# TASK-0027 / TASK-0028 / TASK-0029): no events, no state writes. This task does NOT
# own or edit lib.sh.
#
# Advocate/skeptic line + evidence invariance: the locators decide nothing and record
# nothing — they are pure read-only resolvers. They change no accept/reject outcome,
# weaken no gate, and never make the fresh implementation auditor bypassable. Both
# fail SAFE: any ambiguity — a missing/ambiguous node association, or an
# absent/unparseable/wrong-schema record — resolves to EMPTY output (never a crash,
# never a fabricated node or path), so the terminal hook safely SKIPS the recheck and
# records nothing rather than misfiring. A skipped recheck mutates no accept/reject
# outcome, preserving evidence invariance. The whole recheck stays default-OFF behind
# SINGULAR_CRITIC_RECHECK_PCT (TASK-0027).
#
# The terminal l1-drive.sh post-acceptance hook that delegates these locators into the
# recheck runner (TASK-0031), self-guarded on the default-OFF knob and byte-identical
# when OFF, is the sanctioned follow-up slice and is OUT OF SCOPE here.
#
# Public entry points:
#   singular_ctx_critic_recheck_locate_node <task_id> [worktree]
#     PURE and READ-ONLY. Resolve the executable DAG node that owns the accepted task's
#     critiqued batch by reading the durable task->node association recorded in the
#     control-state event log (SINGULAR_EVENTS_FILE). Print the node id when it is
#     present and UNAMBIGUOUS (exactly one distinct non-empty node across all events
#     carrying this taskId); print EMPTY when the association is missing or ambiguous
#     (the same task recorded against two different nodes). Appends no event, writes no
#     state, invokes no runner, always exits 0.
#   singular_ctx_critic_recheck_locate_record <node> <task_id> [worktree]
#     PURE and READ-ONLY. Resolve the path to the prior plan-critique.v0 record produced
#     for <node> at planning time (the durable per-node archive convention, then the
#     node stage-dir convention <stage_dir>/plan-critique.json under the runs dir).
#     Print the path ONLY when the file exists AND parses as a
#     singular.orchestration.plan-critique.v0 record whose node matches <node> and whose
#     batch included <task_id> (or when <task_id> is empty, node-only). Print EMPTY
#     otherwise. Appends no event, writes no state, invokes no runner, always exits 0.

# Pure helper: canonical durable per-node critique-record path. The plan-critic driver
# persists plan-critique.json under the per-run stage dir; by post-acceptance time that
# per-run dir may be gone, so the record locator also consults a durable per-node
# archive. Its root defaults under the runtime state dir (NEVER under docs/); override
# with SINGULAR_CRITIC_RECHECK_RECORD_DIR. Empty node -> empty (caller decides).
singular_ctx_critic_recheck_locate_record_path() {
  local node="$1"
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }
  local record_dir="${SINGULAR_CRITIC_RECHECK_RECORD_DIR:-${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}/critique}"
  printf '%s/%s/plan-critique.json' "$record_dir" "$node"
}

# Resolve the executable DAG node owning an accepted task's critiqued batch from the
# durable control-state event log. Pure/read-only; prints the node when unambiguous,
# else empty. Never exits non-zero. See header for the contract.
#   singular_ctx_critic_recheck_locate_node <task_id> [worktree]
singular_ctx_critic_recheck_locate_node() {
  local task_id="${1:-}" worktree="${2:-.}"
  # Indeterminate/empty task -> empty output (fail-safe).
  [[ -n "$task_id" ]] || { printf '%s' ""; return 0; }
  local events_file="${SINGULAR_EVENTS_FILE:-}"
  [[ -n "$events_file" && -f "$events_file" ]] || { printf '%s' ""; return 0; }

  # Scan the NDJSON control-state log read-only. Collect the DISTINCT non-empty node
  # values across every event carrying data.taskId == <task_id>. Exactly one distinct
  # node -> that node; zero or more-than-one (ambiguous) -> empty. A parse failure on
  # any single line is skipped (never fatal). Prints nothing but the resolved node.
  python3 - "$events_file" "$task_id" <<'PY' 2>/dev/null || true
import json, sys
path, task_id = sys.argv[1], sys.argv[2]
nodes = set()
try:
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if not isinstance(ev, dict):
                continue
            data = ev.get("data")
            if not isinstance(data, dict):
                continue
            if str(data.get("taskId", "")) != task_id:
                continue
            node = data.get("node", "")
            if isinstance(node, str) and node:
                nodes.add(node)
except Exception:
    nodes = set()
# Fail safe: only an unambiguous single association resolves.
if len(nodes) == 1:
    sys.stdout.write(next(iter(nodes)))
PY
  return 0
}

# Resolve the path to the prior plan-critique.v0 record for <node>. Pure/read-only;
# prints the path only when a candidate exists AND parses as a
# singular.orchestration.plan-critique.v0 record whose node matches <node> and whose
# batch included <task_id> (or, when <task_id> is empty, node-only). Else empty. Never
# exits non-zero. See header for the contract.
#   singular_ctx_critic_recheck_locate_record <node> <task_id> [worktree]
singular_ctx_critic_recheck_locate_record() {
  local node="${1:-}" task_id="${2:-}" worktree="${3:-.}"
  # Indeterminate/empty node -> empty output (fail-safe).
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }

  # Candidate paths, in deterministic preference order:
  #   1. the durable per-node archive convention;
  #   2. every per-run stage-dir record for this node (<runs>/*/l1-staging/<node>/
  #      plan-critique.json), sorted for stability.
  local candidates=()
  local durable
  durable="$(singular_ctx_critic_recheck_locate_record_path "$node")"
  [[ -n "$durable" ]] && candidates+=("$durable")

  local runs_dir="${SINGULAR_RUNS_DIR:-${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}/runs}"
  if [[ -d "$runs_dir" ]]; then
    local staged
    while IFS= read -r staged; do
      [[ -n "$staged" ]] && candidates+=("$staged")
    done < <(find "$runs_dir" -type f -path "*/l1-staging/$node/plan-critique.json" 2>/dev/null | sort)
  fi

  local cand
  for cand in "${candidates[@]}"; do
    [[ -f "$cand" ]] || continue
    # Validate read-only: parses, schema matches, node matches, batch includes task
    # (unless task is empty -> node-only). Any failure -> skip (never a crash, never a
    # fabricated path). Exit 0 = valid; prints nothing.
    if python3 - "$cand" "$node" "$task_id" <<'PY' 2>/dev/null
import json, sys
path, node, task_id = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
except Exception:
    sys.exit(1)
if not isinstance(doc, dict):
    sys.exit(1)
if doc.get("schema") != "singular.orchestration.plan-critique.v0":
    sys.exit(1)
if str(doc.get("node", "")) != node:
    sys.exit(1)
if task_id:
    batch = doc.get("batchTaskIds")
    if not isinstance(batch, list) or task_id not in [str(x) for x in batch]:
        sys.exit(1)
sys.exit(0)
PY
    then
      printf '%s' "$cand"
      return 0
    fi
  done

  printf '%s' ""
  return 0
}
