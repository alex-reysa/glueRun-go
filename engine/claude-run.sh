#!/usr/bin/env bash
set -euo pipefail

# claude-run.sh — Claude Code drop-in replacement for codex-run.sh.
#
# Same CLI surface and same output contract as codex-run.sh so the orchestration
# can dispatch the `claude` CLI instead of `codex` by setting GLUERUN_RUNNER to this
# script (per-call sites honor ${GLUERUN_RUNNER:-$SCRIPT_DIR/codex-run.sh}).
#
# Contract preserved:
#   --worktree/-C, --prompt-file, --level l1|l2|readonly, --run-id,
#   --output-last-message, --output-schema, --no-output-capture, --allow-prefix.
#   The final assistant message text is written to --output-last-message so the
#   existing gluerun_extract_json / gluerun_l1_prepare_worker_packet pipeline can dig
#   the JSON packet/verdict out of it exactly as it does for codex output.
#
# Privilege levels (mapped from codex sandbox semantics):
#   readonly  -> agent may read + run read-only shell, MUST NOT mutate the repo.
#                Enforced at the orchestration layer: file-write tools are denied
#                AND any working-tree mutation the run leaves behind is reverted
#                after the run (git restore guard). This is bulletproof regardless
#                of Claude's internal sandbox and cannot hang on a network prompt.
#   l2        -> workspace-write + Bash + NETWORK (real-PostgreSQL proof needs
#                egress). File scope is enforced downstream by scope-check.sh in
#                l1-drive.sh, identical to the codex path.
#   l0|l1     -> workspace-write limited to --allow-prefix paths, verified by
#                scope-check.sh after the run (mirrors codex-run.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

worktree=""
prompt_file=""
level="l2"
run_id=""
output_schema=""
output_last_message=""
capture_packet="auto"
allow_prefixes=()
# Session affinity (T-E5): both ADDITIVE. NEITHER passed => behavior byte-identical to HEAD.
session_meta_path=""
resume_session_id=""
runner_role="${GLUERUN_RUNNER_ROLE:-unknown}"
capability_profile="${GLUERUN_RUNNER_CAPABILITY_PROFILE:-default}"
result_file="${GLUERUN_RUNNER_RESULT_FILE:-}"
describe_contract="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--worktree) worktree="$2"; shift 2 ;;
    --prompt-file) prompt_file="$2"; shift 2 ;;
    --level) level="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    --output-schema) output_schema="$2"; capture_packet="yes"; shift 2 ;;
    --output-last-message) output_last_message="$2"; capture_packet="yes"; shift 2 ;;
    --no-output-capture) capture_packet="no"; shift ;;
    --allow-prefix) allow_prefixes+=("$2"); shift 2 ;;
    --session-meta) session_meta_path="$2"; shift 2 ;;
    --resume-session) resume_session_id="$2"; shift 2 ;;
    --role) runner_role="$2"; shift 2 ;;
    --capability-profile) capability_profile="$2"; shift 2 ;;
    --result-file) result_file="$2"; shift 2 ;;
    --describe-contract) describe_contract="yes"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$describe_contract" == "yes" ]]; then
  gluerun_runner_describe_contract claude
  exit 0
fi

if [[ -z "$run_id" ]]; then
  run_id="RUN-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
if [[ -z "$result_file" ]]; then
  result_file="$(gluerun_runner_default_result_file "$run_id")"
fi
runner_result_written="no"
gluerun_claude_result_on_exit() {
  local rc=$?
  trap - EXIT
  if [[ "$runner_result_written" != "yes" ]]; then
    gluerun_runner_result_write claude "$run_id" "$runner_role" "$capability_profile" \
      "$result_file" "$rc" "${envelope:-}" "${envelope_err:-}" "$output_last_message" || true
  fi
  [[ -n "${envelope:-}" ]] && rm -f "$envelope" "${envelope_err:-}" 2>/dev/null || true
  [[ -n "${strict_mcp_dir:-}" ]] && rm -rf "$strict_mcp_dir" 2>/dev/null || true
  exit "$rc"
}
trap gluerun_claude_result_on_exit EXIT

if [[ -z "$worktree" ]]; then
  echo "usage: $0 --worktree PATH [--level l1|l2|readonly] [--prompt-file FILE]" >&2
  exit 2
fi

gluerun_require_target_branch

claude_bin="$(command -v claude 2>/dev/null || true)"

# --- Level -> behavior ----------------------------------------------------------
readonly_run="no"
case "$level" in
  l0|l1)
    if [[ ${#allow_prefixes[@]} -eq 0 ]]; then allow_prefixes=("docs/orchestration/"); fi
    ;;
  l2) ;;
  readonly|read-only) readonly_run="yes" ;;
  *) echo "unknown level: $level" >&2; exit 2 ;;
esac

profile_rc=0
gluerun_runner_capability_prepare claude "$runner_role" "$capability_profile" \
  "$worktree" "$claude_bin" || profile_rc=$?
capability_profile="$GLUERUN_RESOLVED_CAPABILITY_PROFILE"
profile_provider_args=()
if [[ "$GLUERUN_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  profile_provider_args=("${GLUERUN_RESOLVED_PROVIDER_ARGS[@]}")
fi
[[ "$profile_rc" -eq 0 ]] || exit "$profile_rc"
gluerun_runner_reject_strict_legacy_extra_args \
  claude GLUERUN_CLAUDE_EXTRA_ARGS "${GLUERUN_CLAUDE_EXTRA_ARGS:-}" || exit $?
[[ -n "$claude_bin" ]] || { echo "claude CLI not found on PATH" >&2; exit 127; }
profile_native_args=()
strict_mcp_config=""
if [[ "$GLUERUN_RESOLVED_CAPABILITY_STRICT" == "yes" ]]; then
  # A temp DIRECTORY with trailing X's, holding a fixed-name file. The template
  # must end in the X's: BSD/macOS mktemp only substitutes TRAILING X's, so the
  # old "...XXXXXX.json" template created a file named literally
  # "gluerun-claude-empty-mcp.XXXXXX.json". That works once, and the EXIT trap
  # removes it — but any hard kill (a stopped run, an OOM, a reboot mid-run)
  # leaves the literal name behind, and every later strict claude run then dies
  # with "mktemp: mkstemp failed: File exists" until someone deletes it by hand.
  # A persistent, self-inflicted provider outage from a leaked temp file.
  strict_mcp_dir="$(mktemp -d "${TMPDIR:-/tmp}/gluerun-claude-mcp.XXXXXX")"
  strict_mcp_config="$strict_mcp_dir/mcp.json"
  printf '{"mcpServers":{}}\n' >"$strict_mcp_config"
  profile_native_args+=(--safe-mode --strict-mcp-config --mcp-config "$strict_mcp_config")
fi

if [[ "$capture_packet" == "auto" && "$level" == "l2" ]]; then
  capture_packet="yes"
elif [[ "$capture_packet" == "auto" ]]; then
  capture_packet="no"
fi

run_dir=""
if [[ "$capture_packet" == "yes" ]]; then
  run_dir="$GLUERUN_STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir"
  if [[ -z "$output_last_message" ]]; then
    output_last_message="$run_dir/last-message.json"
  fi
fi

# --- Model selection (mirrors codex reasoning-effort-by-role keying) -------------
gluerun_claude_model() {
  local level="$1" prompt_file="$2" prompt_name
  prompt_name="$(basename "${prompt_file:-}")"
  case "$level" in
    l2)
      printf '%s\n' "${GLUERUN_CLAUDE_L2_MODEL:-${GLUERUN_CLAUDE_MODEL:-claude-opus-4-8}}" ;;
    l0|l1)
      printf '%s\n' "${GLUERUN_CLAUDE_L1_MODEL:-${GLUERUN_CLAUDE_MODEL:-claude-opus-4-8}}" ;;
    readonly|read-only)
      case "$prompt_name" in
        planner-prompt.md)    printf '%s\n' "${GLUERUN_CLAUDE_PLANNER_MODEL:-${GLUERUN_CLAUDE_MODEL:-claude-opus-4-8}}" ;;
        auditor-*.md)    printf '%s\n' "${GLUERUN_CLAUDE_AUDITOR_MODEL:-${GLUERUN_CLAUDE_MODEL:-claude-opus-4-8}}" ;;
        decider-prompt-*.md)  printf '%s\n' "${GLUERUN_CLAUDE_DECIDER_MODEL:-${GLUERUN_CLAUDE_MODEL:-claude-opus-4-8}}" ;;
        *)                    printf '%s\n' "${GLUERUN_CLAUDE_MODEL:-claude-opus-4-8}" ;;
      esac ;;
  esac
}
claude_model="$(gluerun_claude_model "$level" "$prompt_file")"

# --- Reasoning-effort selection (per-role, env-overridable; empty = model default).
# Implementer (l2) runs Opus at medium effort for bulk code-writing; the gatekeeping
# planner + auditor run at xhigh. Decider/L1/other left at the model default (empty).
gluerun_claude_effort() {
  local level="$1" prompt_file="$2" prompt_name
  prompt_name="$(basename "${prompt_file:-}")"
  case "$level" in
    l2)
      printf '%s\n' "${GLUERUN_CLAUDE_L2_EFFORT:-${GLUERUN_CLAUDE_EFFORT:-medium}}" ;;
    readonly|read-only)
      case "$prompt_name" in
        planner-prompt.md) printf '%s\n' "${GLUERUN_CLAUDE_PLANNER_EFFORT:-${GLUERUN_CLAUDE_EFFORT:-xhigh}}" ;;
        auditor-*.md) printf '%s\n' "${GLUERUN_CLAUDE_AUDITOR_EFFORT:-${GLUERUN_CLAUDE_EFFORT:-xhigh}}" ;;
        decider-prompt-*.md) printf '%s\n' "${GLUERUN_CLAUDE_DECIDER_EFFORT:-${GLUERUN_CLAUDE_EFFORT:-}}" ;;
        *) printf '%s\n' "${GLUERUN_CLAUDE_EFFORT:-}" ;;
      esac ;;
    *)
      printf '%s\n' "${GLUERUN_CLAUDE_EFFORT:-}" ;;
  esac
}
claude_effort="$(gluerun_claude_effort "$level" "$prompt_file")"

# ---- Session affinity: resume-refusal gate (exit 86) ------------------------
# Model selection lives in the runner. Refuse to resume a session recorded under
# a different model/effort than this runner derives now (exit 86 -> host goes fresh).
if [[ -n "$resume_session_id" && -n "$session_meta_path" && -f "$session_meta_path" ]]; then
  if ! python3 - "$session_meta_path" "$claude_model" "$claude_effort" <<'PY'
import json, sys
path, model_now, effort_now = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, "r", encoding="utf-8") as f:
        m = json.load(f)
except Exception:
    sys.exit(0)
prev_model = str(m.get("model", "") or "")
prev_effort = str(m.get("effort", "") or "")
if prev_model and prev_model != model_now:
    sys.exit(1)
if prev_effort and prev_effort != effort_now:
    sys.exit(1)
sys.exit(0)
PY
  then
    echo "claude-run: resume-refused (model/effort changed vs $session_meta_path)" >&2
    exit 86
  fi
fi

if [[ "$level" == "l2" ]]; then
  export GOCACHE="${GLUERUN_GO_BUILD_CACHE:-/private/tmp/gluerun-go-build-cache}"
  mkdir -p "$GOCACHE"
fi

# --- Assemble the claude invocation ---------------------------------------------
cmd=("$claude_bin" -p --output-format json --model "$claude_model")
if [[ ${#profile_native_args[@]} -gt 0 ]]; then
  cmd+=("${profile_native_args[@]}")
fi
if [[ "$GLUERUN_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  cmd+=("${profile_provider_args[@]}")
fi
[[ -n "$claude_effort" ]] && cmd+=(--effort "$claude_effort")
# Session resume (T-E5): -r <id> resumes; --fork-session forks a fresh branch off
# the resumed session when GLUERUN_CLAUDE_FORK_ON_RESUME=1. Additive: absent flag ->
# cmd is unchanged from HEAD.
if [[ -n "$resume_session_id" ]]; then
  cmd+=(-r "$resume_session_id")
  [[ "${GLUERUN_CLAUDE_FORK_ON_RESUME:-0}" == "1" ]] && cmd+=(--fork-session)
fi

# Runaway protection: no --max-turns exists, so cap dollar spend per run.
claude_budget="${GLUERUN_CLAUDE_MAX_BUDGET_USD:-5}"
if [[ "$claude_budget" != "0" && -n "$claude_budget" ]]; then
  cmd+=(--max-budget-usd "$claude_budget")
fi

# Output-shape enforcement at the seam. The role prompts already ask for JSON-only
# output, but Claude tends to wrap the JSON in reasoning prose; a system-prompt
# constraint is far stickier than a user-prompt one and keeps every role's final
# message parseable. Do NOT instruct literal id reuse here — the planner is
# expected to renumber placeholder TASK ids to the next free id. Env-overridable.
claude_system_prompt="${GLUERUN_CLAUDE_SYSTEM_PROMPT:-Your FINAL assistant message MUST be exactly one JSON object and nothing else: no prose, no preamble, no \"Here is\", no code fences, no trailing commentary. If you cannot comply, still emit a single JSON object describing the problem.}"
if [[ "$readonly_run" == "yes" ]]; then
  # Deny file-mutation tools (first line); the post-run restore guard is the
  # working-tree backstop. Bash stays available for read-only review (git diff,
  # viewing logs) the way the codex read-only sandbox permits. The system-prompt
  # clause additionally forbids state-mutating commands, since tool-denial alone
  # does not stop a Bash `git commit`/`git checkout` the codex OS sandbox blocked.
  cmd+=(--disallowedTools "Edit,Write,NotebookEdit,MultiEdit")
  claude_system_prompt+=" You are STRICTLY READ-ONLY: do not create, modify, or delete any file, and do not run any state-mutating command (no git add/commit/checkout/reset/rebase/push/stash, no redirections that write files); use only reads and read-only inspection commands."
fi
if [[ -n "$claude_system_prompt" ]]; then
  cmd+=(--append-system-prompt "$claude_system_prompt")
fi
cmd+=(--dangerously-skip-permissions)

if [[ -n "${GLUERUN_CLAUDE_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  cmd+=(${GLUERUN_CLAUDE_EXTRA_ARGS})
fi

# --- Read-only snapshot (for restore-after) -------------------------------------
ro_before_untracked=""
ro_before_mod=""
if [[ "$readonly_run" == "yes" ]]; then
  ro_before_untracked="$(git -C "$worktree" ls-files --others --exclude-standard 2>/dev/null | sort || true)"
  ro_before_mod="$(git -C "$worktree" diff --name-only HEAD 2>/dev/null | sort || true)"
fi

# --- Run claude in the working directory ----------------------------------------
# stdout (the --output-format json envelope) and stderr (CLI notices/errors) are
# captured to SEPARATE files so a stray stderr line never corrupts the JSON parse.
envelope="$(mktemp "${TMPDIR:-/tmp}/gluerun-claude-env.XXXXXX")"
envelope_err="$envelope.err"

# SIGKILL a pid and every transitive descendant. Snapshots the full ps tree
# (which is intact at timeout, before anything exits) so reparenting can't let a
# child escape — more reliable than recursive pgrep -P or a process-group kill,
# which both let the mock's grandchild survive in testing.
gluerun_claude_kill_tree() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import os, signal, subprocess, sys
root = int(sys.argv[1])
out = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid="],
                     capture_output=True, text=True).stdout
children = {}
for line in out.splitlines():
    f = line.split()
    if len(f) != 2:
        continue
    try:
        pid, ppid = int(f[0]), int(f[1])
    except ValueError:
        continue
    children.setdefault(ppid, []).append(pid)
order, stack = [], [root]
while stack:
    p = stack.pop()
    for c in children.get(p, []):
        order.append(c)
        stack.append(c)
for pid in list(reversed(order)) + [root]:
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
PY
}

run_claude() {
  if [[ -n "$prompt_file" ]]; then
    ( cd "$worktree" && "${cmd[@]}" <"$prompt_file" ) >"$envelope" 2>"$envelope_err"
  else
    ( cd "$worktree" && "${cmd[@]}" ) >"$envelope" 2>"$envelope_err"
  fi
}

exit_code=0
echo "claude-run: level=$level model=$claude_model worktree=$worktree run_id=$run_id" >&2
# Wall-clock guard: `claude -p` has no --max-turns, so an agentic session can loop;
# bound it (default 1200s) and kill the whole process tree on timeout so a stuck
# run never holds a worker slot indefinitely. Set GLUERUN_CLAUDE_TIMEOUT_SEC=0 to disable.
claude_timeout="${GLUERUN_CLAUDE_TIMEOUT_SEC:-1200}"
if [[ "$claude_timeout" =~ ^[0-9]+$ && "$claude_timeout" -gt 0 ]]; then
  run_claude & cl_pid=$!
  cl_deadline=$((SECONDS + claude_timeout)); cl_timed_out="no"
  while kill -0 "$cl_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$cl_deadline" ]]; then
      cl_timed_out="yes"
      gluerun_claude_kill_tree "$cl_pid"   # SIGKILL claude + every descendant
      wait "$cl_pid" 2>/dev/null || true
      exit_code=124
      break
    fi
    sleep 2
  done
  if [[ "$cl_timed_out" != "yes" ]]; then
    cl_ec=0; wait "$cl_pid" || cl_ec=$?; exit_code="$cl_ec"
  else
    echo "claude-run: TIMED OUT after ${claude_timeout}s; killed run $run_id (output left empty so the caller treats it as a soft failure)" >&2
  fi
else
  run_claude || exit_code=$?
fi

# Surface stdout (the envelope — also the source for retry fix-hints) then any
# stderr (CLI notices/errors) into the caller's log, and keep a copy under run dir.
cat "$envelope" >&2 || true
[[ -s "$envelope_err" ]] && cat "$envelope_err" >&2 || true
if [[ -n "$run_dir" ]]; then cp "$envelope" "$run_dir/claude-envelope.json" 2>/dev/null || true; fi

# --- Session-meta (T-E5): parse session_id from the envelope -------------------
# Always (re)write the meta from the envelope when --session-meta is passed, even
# on fork (the id may churn). The host merges its authority fields afterwards.
if [[ -n "$session_meta_path" ]]; then
  session_id="$(python3 - "$envelope" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        env = json.load(f)
except Exception:
    env = {}
sid = env.get("session_id") if isinstance(env, dict) else None
sys.stdout.write(sid if isinstance(sid, str) else "")
PY
)"
  gluerun_claude_session_meta_write "$session_meta_path" "$session_id" "$claude_model" \
    "$claude_effort" "$worktree" "$exit_code" || true
fi

# --- Extract the final assistant message into the output file -------------------
if [[ "$capture_packet" == "yes" && -n "$output_last_message" ]]; then
  parse_ec=0
  python3 - "$envelope" "$output_last_message" <<'PY' || parse_ec=$?
import json, sys
env_path, out_path = sys.argv[1], sys.argv[2]
try:
    with open(env_path, "r", encoding="utf-8") as f:
        env = json.load(f)
except Exception as e:
    sys.stderr.write(f"claude-run: could not parse claude envelope as JSON: {e}\n")
    sys.exit(3)
result = env.get("result")
if result is None and isinstance(env, dict):
    # stream-json fallback: last result event, if a NDJSON stream slipped through.
    result = env.get("text")
if result is None:
    sys.stderr.write("claude-run: claude envelope had no 'result' field\n")
    sys.exit(3)
if not isinstance(result, str):
    result = json.dumps(result)
with open(out_path, "w", encoding="utf-8") as f:
    f.write(result)
    if not result.endswith("\n"):
        f.write("\n")
sys.exit(4 if env.get("is_error") else 0)
PY
  if [[ "$parse_ec" -ne 0 ]]; then
    # is_error (4) or missing result (3) — treat as a soft failure; callers that
    # need a packet detect the missing/empty output themselves, exactly as with
    # codex. Preserve a nonzero exit so hard errors propagate.
    if [[ "$exit_code" -eq 0 ]]; then exit_code="$parse_ec"; fi
  fi
fi

# --- Read-only restore guard: revert anything the run mutated -------------------
if [[ "$readonly_run" == "yes" ]]; then
  # Remove untracked (non-ignored) files the run created (preserve pre-existing).
  ro_after_untracked="$(git -C "$worktree" ls-files --others --exclude-standard 2>/dev/null | sort || true)"
  comm -13 <(printf '%s\n' "$ro_before_untracked") <(printf '%s\n' "$ro_after_untracked") \
    | while IFS= read -r f; do
        [[ -n "$f" ]] && rm -rf "$worktree/$f" 2>/dev/null || true
      done
  # Revert ONLY the tracked files this run modified (surgical). Never a repo-wide
  # checkout and never touches files that were already dirty before the run, so
  # concurrent readonly runs sharing a root (e.g. parallel L1 planners in
  # $GLUERUN_ROOT) cannot clobber each other or in-flight work.
  ro_after_mod="$(git -C "$worktree" diff --name-only HEAD 2>/dev/null | sort || true)"
  comm -13 <(printf '%s\n' "$ro_before_mod") <(printf '%s\n' "$ro_after_mod") \
    | while IFS= read -r f; do
        [[ -n "$f" ]] && git -C "$worktree" checkout -- "$f" 2>/dev/null || true
      done
fi

# --- Scope enforcement for L0/L1 (mirrors codex-run.sh) -------------------------
if [[ "$level" == "l0" || "$level" == "l1" ]]; then
  scope_args=(--worktree "$worktree")
  for prefix in "${allow_prefixes[@]}"; do
    scope_args+=(--allow-prefix "$prefix")
  done
  "$SCRIPT_DIR/scope-check.sh" "${scope_args[@]}"
fi

if [[ "$capture_packet" == "yes" ]]; then
  echo "last_message=$output_last_message" >&2
fi

# --- Resume-failure signalling (exit 86) -------------------------------------
# A resumed run that exits nonzero with empty output is indistinguishable from a
# real model failure unless flagged; surface 86 so the host falls back to fresh.
if [[ -n "$resume_session_id" && "$exit_code" -ne 0 ]]; then
  out_empty="yes"
  if [[ -n "$output_last_message" && -s "$output_last_message" ]]; then out_empty="no"; fi
  if [[ "$out_empty" == "yes" ]]; then
    echo "claude-run: resume produced no usable output (rc=$exit_code); signalling resume-failure" >&2
    exit 86
  fi
fi

if gluerun_runner_result_write claude "$run_id" "$runner_role" "$capability_profile" \
  "$result_file" "$exit_code" "$envelope" "$envelope_err" "$output_last_message"; then
  runner_result_written="yes"
fi
# Temp envelope files are removed by the EXIT trap registered above.
exit "$exit_code"
