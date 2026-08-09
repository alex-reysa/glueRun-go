#!/usr/bin/env bash
set -euo pipefail

# cursor-run.sh — Cursor CLI (cursor-agent) drop-in replacement for codex-run.sh /
# claude-run.sh.
#
# Same CLI surface and output contract so orchestration can dispatch the
# `cursor-agent` CLI by setting GLUERUN_RUNNER to this script. `cursor-agent -p
# --output-format json` emits a single result envelope {"type":"result","result":
# "<text>","is_error":bool,...}; we write .result into --output-last-message so the
# existing gluerun_extract_json / gluerun_l1_prepare_worker_packet pipeline digs the
# JSON packet/verdict out exactly as it does for codex/claude output.
#
# Session affinity: Cursor v1 exposes no captured session id here, so --session-meta
# is accepted and best-effort written (provider "cursor", empty sessionId) to keep
# the unconditional --session-meta call sites working, and --resume-session is refused
# with exit 86 (host falls back to a fresh run).
#
# Privilege levels:
#   readonly  -> `--mode ask` (Q&A / read-only) PLUS the post-run git restore guard,
#                which reverts any mutation the run leaves behind.
#   l2        -> `-f` (force / auto-approve all tools); file scope enforced downstream.
#   l0|l1     -> `-f` limited to --allow-prefix paths, verified by scope-check.sh after
#                the run (mirrors codex-run.sh).
# The prompt is fed on STDIN (cursor-agent reads it from stdin in --print mode when
# no positional prompt is given), so large prompts never hit the argv size limit.

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
# Session affinity: both accepted for host compatibility. --session-meta is
# written best-effort (no sessionId); --resume-session is refused (exit 86).
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
  gluerun_runner_describe_contract cursor
  exit 0
fi

if [[ -z "$run_id" ]]; then
  run_id="RUN-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
if [[ -z "$result_file" ]]; then
  result_file="$(gluerun_runner_default_result_file "$run_id")"
fi
runner_result_written="no"
ro_journal=""
gluerun_cursor_result_on_exit() {
  local rc=$?
  trap - EXIT
  # An interrupted run leaves the provider CLI and its descendants alive; they
  # would keep writing to the worktree while the guard restores it, and the
  # restore would lose the race. Kill first, then restore.
  if [[ -n "${cur_pid:-}" ]]; then
    gluerun_kill_tree "$cur_pid" 0 session 2>/dev/null || true
    wait "$cur_pid" 2>/dev/null || true
    cur_pid=""
  fi
  # Before the result write, because a containment failure that outlives the
  # process is the worse outcome. ask/supervise/decide background this runner
  # and kill it on timeout; the old guard was straight-line code after the run,
  # so on every one of those paths it simply never executed.
  gluerun_readonly_guard_restore "${ro_journal:-}" || true
  ro_journal=""
  if [[ "$runner_result_written" != "yes" ]]; then
    gluerun_runner_result_write cursor "$run_id" "$runner_role" "$capability_profile" \
      "$result_file" "$rc" "${envelope:-}" "${envelope_err:-}" "$output_last_message" || true
  fi
  [[ -n "${envelope:-}" ]] && rm -f "$envelope" "${envelope_err:-}" 2>/dev/null || true
  exit "$rc"
}
trap gluerun_cursor_result_on_exit EXIT
# Exiting from a signal handler runs the EXIT trap, so these buy the guard a
# chance to run on the SIGTERM that precedes a kill-tree's SIGKILL. SIGKILL
# itself remains uncoverable; `gluerun_readonly_guard_sweep` is the answer there.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -z "$worktree" ]]; then
  echo "usage: $0 --worktree PATH [--level l1|l2|readonly] [--prompt-file FILE]" >&2
  exit 2
fi

gluerun_require_target_branch

cursor_bin="$(command -v cursor-agent 2>/dev/null || true)"

# --output-schema is accepted for contract parity; cursor-agent cannot enforce a
# caller-supplied JSON schema headlessly, so we capture + validate downstream.
: "${output_schema:=}"

readonly_run="no"
case "$level" in
  l0|l1)
    if [[ ${#allow_prefixes[@]} -eq 0 ]]; then allow_prefixes=("docs/orchestration/"); fi
    ;;
  l2) ;;
  readonly|read-only) readonly_run="yes" ;;
  *) echo "unknown level: $level" >&2; exit 2 ;;
esac

if [[ -z "$prompt_file" ]]; then
  echo "cursor-run: --prompt-file is required" >&2
  exit 2
fi

profile_rc=0
gluerun_runner_capability_prepare cursor "$runner_role" "$capability_profile" \
  "$worktree" "$cursor_bin" || profile_rc=$?
capability_profile="$GLUERUN_RESOLVED_CAPABILITY_PROFILE"
profile_provider_args=()
if [[ "$GLUERUN_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  profile_provider_args=("${GLUERUN_RESOLVED_PROVIDER_ARGS[@]}")
fi
[[ "$profile_rc" -eq 0 ]] || exit "$profile_rc"
gluerun_runner_reject_strict_legacy_extra_args \
  cursor GLUERUN_CURSOR_EXTRA_ARGS "${GLUERUN_CURSOR_EXTRA_ARGS:-}" || exit $?
[[ -n "$cursor_bin" ]] || { echo "cursor-agent CLI not found on PATH" >&2; exit 127; }

# ---- Session affinity: resume refusal (exit 86) -----------------------------
if [[ -n "$resume_session_id" ]]; then
  echo "cursor-run: resume unsupported (no session affinity); signalling resume-refusal" >&2
  exit 86
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

# --- Model selection ------------------------------------------------------------
# When GLUERUN_CURSOR_MODEL is unset, OMIT --model entirely so cursor-agent uses
# its own default/auto routing (spec 0.9.0). No per-role/effort mapping in v1.
cursor_model() {
  printf '%s\n' "${GLUERUN_CURSOR_MODEL:-}"
}
cur_model="$(cursor_model)"

# --- Assemble the cursor-agent invocation ---------------------------------------
# Prompt travels on STDIN (--print mode, no positional prompt). --trust trusts the
# worktree so a headless run never blocks on a workspace-trust prompt.
cmd=("$cursor_bin" -p --output-format json --workspace "$worktree" --trust)
if [[ "$GLUERUN_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  cmd+=("${profile_provider_args[@]}")
fi
[[ -n "$cur_model" ]] && cmd+=(--model "$cur_model")
if [[ "$readonly_run" == "yes" ]]; then
  cmd+=(--mode ask)   # read-only Q&A; no edits
else
  cmd+=(-f)           # force / auto-approve all tools
fi

if [[ -n "${GLUERUN_CURSOR_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  cmd+=(${GLUERUN_CURSOR_EXTRA_ARGS})
fi

# --- Read-only snapshot (for restore-after) -------------------------------------
if [[ "$readonly_run" == "yes" ]]; then
  ro_journal="$(gluerun_readonly_guard_capture "$worktree" "cursor-$run_id")"
fi

envelope="$(mktemp "${TMPDIR:-/tmp}/gluerun-cursor-env.XXXXXX")"
envelope_err="$envelope.err"

# The provider as a SESSION LEADER: gluerun_setsid_exec is the LAST command, so
# the `&` at the call site makes $! the leader itself (pid == pgid) and
# gluerun_kill_tree group-kills the whole tree with one negative pid, without
# `ps` (PMGO-004). Only ever invoked as a background job, so the `cd` is
# contained; redirections live on the call site so they bind to the job.
run_cursor() {
  cd "$worktree" || exit 1
  gluerun_setsid_exec "${cmd[@]}"
}

exit_code=0
echo "cursor-run: level=$level model=${cur_model:-<default>} worktree=$worktree run_id=$run_id" >&2
cur_timeout="${GLUERUN_CURSOR_TIMEOUT_SEC:-1200}"
# The provider always runs in the BACKGROUND, even with the timeout disabled.
# bash defers a trapped signal until the foreground child finishes, so a
# foreground run would swallow the SIGTERM that ask/supervise/decide send on
# their way to a kill -- and with it the read-only guard's only chance to run.
# `wait` is interruptible by a trapped signal; a foreground child is not.
run_cursor <"$prompt_file" >"$envelope" 2>"$envelope_err" & cur_pid=$!
if [[ "$cur_timeout" =~ ^[0-9]+$ && "$cur_timeout" -gt 0 ]]; then
  cur_deadline=$((SECONDS + cur_timeout)); cur_timed_out="no"
  while kill -0 "$cur_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$cur_deadline" ]]; then
      cur_timed_out="yes"
      # TERM the provider session, then KILL what is left.
      gluerun_kill_tree "$cur_pid" "$(gluerun_provider_kill_grace_sec)" session
      wait "$cur_pid" 2>/dev/null || true
      exit_code=124
      break
    fi
    sleep 2
  done
  if [[ "$cur_timed_out" != "yes" ]]; then
    cur_ec=0; wait "$cur_pid" || cur_ec=$?; exit_code="$cur_ec"
  else
    echo "cursor-run: TIMED OUT after ${cur_timeout}s; killed run $run_id" >&2
  fi
else
  cur_ec=0; wait "$cur_pid" || cur_ec=$?; exit_code="$cur_ec"
fi
cur_pid=""

cat "$envelope" >&2 || true
[[ -s "$envelope_err" ]] && cat "$envelope_err" >&2 || true
if [[ -n "$run_dir" ]]; then cp "$envelope" "$run_dir/cursor-envelope.json" 2>/dev/null || true; fi

# --- Session-meta: no resumable id in v1; record provider + empty sessionId ----
if [[ -n "$session_meta_path" ]]; then
  gluerun_session_meta_write_provider "$session_meta_path" "cursor" "" "$cur_model" \
    "" "$worktree" "$exit_code" || true
fi

# --- Extract the final message into the output file -----------------------------
if [[ "$capture_packet" == "yes" && -n "$output_last_message" ]]; then
  parse_ec=0
  python3 - "$envelope" "$output_last_message" <<'PY' || parse_ec=$?
import json, sys
env_path, out_path = sys.argv[1], sys.argv[2]
try:
    with open(env_path, "r", encoding="utf-8") as f:
        raw = f.read()
except Exception as e:
    sys.stderr.write(f"cursor-run: could not read cursor output: {e}\n")
    sys.exit(3)

env = None
try:
    env = json.loads(raw)
except Exception:
    # stream-json fallback: keep the last result event (else the last object).
    last = None
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if isinstance(o, dict) and o.get("type") == "result":
            env = o
        last = o
    if env is None:
        env = last

if not isinstance(env, dict):
    sys.stderr.write("cursor-run: could not parse cursor output as JSON\n")
    sys.exit(3)

def write_result(text):
    if not isinstance(text, str):
        text = json.dumps(text)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(text)
        if not text.endswith("\n"):
            f.write("\n")

is_error = env.get("type") == "error" or env.get("is_error") is True
result = env.get("result")
if result is None:
    result = env.get("text")
if result is None:
    result = env.get("response")

if is_error:
    if result is not None:
        write_result(result)   # surface the error text for the host's fix-hints
    msg = result or env.get("message") or env.get("error") or "error"
    sys.stderr.write(f"cursor-run: error result: {msg}\n")
    sys.exit(4)

if result is None:
    sys.stderr.write("cursor-run: cursor output had no 'result' field\n")
    sys.exit(3)
write_result(result)
sys.exit(0)
PY
  if [[ "$parse_ec" -ne 0 && "$exit_code" -eq 0 ]]; then exit_code="$parse_ec"; fi
fi

# --- Read-only restore guard: revert anything the run mutated -------------------
# Explicitly here, and not only from the EXIT trap, because scope-check.sh below
# must see the restored tree. The trap still holds the timeout and signal paths;
# a second restore of a consumed journal is a no-op.
if [[ "$readonly_run" == "yes" ]]; then
  gluerun_readonly_guard_restore "$ro_journal" || true
  ro_journal=""
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

if gluerun_runner_result_write cursor "$run_id" "$runner_role" "$capability_profile" \
  "$result_file" "$exit_code" "$envelope" "$envelope_err" "$output_last_message"; then
  runner_result_written="yes"
fi

exit "$exit_code"
