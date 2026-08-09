#!/usr/bin/env bash
set -euo pipefail

# gemini-run.sh — Gemini CLI drop-in replacement for codex-run.sh / claude-run.sh.
#
# Same CLI surface and output contract so orchestration can dispatch the `gemini`
# CLI by setting GLUERUN_RUNNER to this script. Parses the headless JSON output
# (.response field of `gemini -o json`) into --output-last-message so the existing
# gluerun_extract_json / gluerun_l1_prepare_worker_packet pipeline digs the JSON
# packet/verdict out of it exactly as it does for codex/claude output.
#
# Session affinity: Gemini v1 has no captured session id, so --session-meta is
# accepted and best-effort written (provider "gemini", empty sessionId) to keep
# the unconditional --session-meta call sites (decide.sh, l1-drive.sh) working,
# and --resume-session is refused with exit 86 (host falls back to a fresh run).
#
# Privilege levels (mapped from codex sandbox semantics):
#   readonly  -> `--approval-mode plan` (read-only planning; no edits) PLUS the
#                post-run git restore guard, so a mutation is reverted regardless
#                of what the model attempts.
#   l2        -> `--yolo` auto-approve; file scope enforced downstream.
#   l0|l1     -> `--yolo` auto-approve limited to --allow-prefix paths, verified
#                by scope-check.sh after the run (mirrors codex-run.sh).
# The prompt is fed on STDIN (gemini prepends stdin to -p), so multi-hundred-KB
# prompts never hit the argv size limit.

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
  gluerun_runner_describe_contract gemini
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
gluerun_gemini_result_on_exit() {
  local rc=$?
  trap - EXIT
  # An interrupted run leaves the provider CLI and its descendants alive; they
  # would keep writing to the worktree while the guard restores it, and the
  # restore would lose the race. Kill first, then restore.
  if [[ -n "${gem_pid:-}" ]]; then
    gluerun_kill_tree "$gem_pid" 0 session 2>/dev/null || true
    wait "$gem_pid" 2>/dev/null || true
    gem_pid=""
  fi
  # Before the result write, because a containment failure that outlives the
  # process is the worse outcome. ask/supervise/decide background this runner
  # and kill it on timeout; the old guard was straight-line code after the run,
  # so on every one of those paths it simply never executed.
  gluerun_readonly_guard_restore "${ro_journal:-}" || true
  ro_journal=""
  if [[ "$runner_result_written" != "yes" ]]; then
    gluerun_runner_result_write gemini "$run_id" "$runner_role" "$capability_profile" \
      "$result_file" "$rc" "${envelope:-}" "${envelope_err:-}" "$output_last_message" || true
  fi
  [[ -n "${envelope:-}" ]] && rm -f "$envelope" "${envelope_err:-}" 2>/dev/null || true
  exit "$rc"
}
trap gluerun_gemini_result_on_exit EXIT
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

gemini_bin="$(command -v gemini 2>/dev/null || true)"

# --output-schema is accepted for contract parity; the Gemini CLI cannot enforce
# a caller-supplied JSON schema headlessly, so we capture + validate downstream.
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
  echo "gemini-run: --prompt-file is required" >&2
  exit 2
fi

profile_rc=0
gluerun_runner_capability_prepare gemini "$runner_role" "$capability_profile" \
  "$worktree" "$gemini_bin" || profile_rc=$?
capability_profile="$GLUERUN_RESOLVED_CAPABILITY_PROFILE"
profile_provider_args=()
if [[ "$GLUERUN_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  profile_provider_args=("${GLUERUN_RESOLVED_PROVIDER_ARGS[@]}")
fi
[[ "$profile_rc" -eq 0 ]] || exit "$profile_rc"
gluerun_runner_reject_strict_legacy_extra_args \
  gemini GLUERUN_GEMINI_EXTRA_ARGS "${GLUERUN_GEMINI_EXTRA_ARGS:-}" || exit $?
[[ -n "$gemini_bin" ]] || { echo "gemini CLI not found on PATH" >&2; exit 127; }
profile_native_args=()
if [[ "$GLUERUN_RESOLVED_CAPABILITY_STRICT" == "yes" ]]; then
  # An empty MCP allowlist plus the documented `none` extension selector keeps
  # strict runs from inheriting user-configured MCP servers or extensions.
  profile_native_args+=(--allowed-mcp-server-names "" --extensions none)
fi

# ---- Session affinity: resume refusal (exit 86) -----------------------------
# Gemini v1 has no captured/resumable session id, so any resume request is
# refused up front; the host re-runs fresh (a pure optimization miss).
if [[ -n "$resume_session_id" ]]; then
  echo "gemini-run: resume unsupported (no session affinity); signalling resume-refusal" >&2
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
# When GLUERUN_GEMINI_MODEL is unset, OMIT -m entirely so the CLI uses its own
# default/auto routing (spec 0.9.0). No per-role/effort mapping in v1.
gemini_model() {
  printf '%s\n' "${GLUERUN_GEMINI_MODEL:-}"
}
gem_model="$(gemini_model)"

# --- Assemble the gemini invocation ---------------------------------------------
# Prompt travels on STDIN; -p "" keeps the CLI in non-interactive (headless) mode
# with the stdin content as the prompt. --skip-trust trusts the worktree so --yolo
# is honored (an untrusted folder silently downgrades approval to prompt-for-each).
cmd=("$gemini_bin" -p "" -o json --skip-trust)
if [[ ${#profile_native_args[@]} -gt 0 ]]; then
  cmd+=("${profile_native_args[@]}")
fi
if [[ "$GLUERUN_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  cmd+=("${profile_provider_args[@]}")
fi
[[ -n "$gem_model" ]] && cmd+=(-m "$gem_model")
if [[ "$readonly_run" == "yes" ]]; then
  cmd+=(--approval-mode plan)
else
  cmd+=(--yolo)
fi

if [[ -n "${GLUERUN_GEMINI_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  cmd+=(${GLUERUN_GEMINI_EXTRA_ARGS})
fi

# --- Read-only snapshot (for restore-after) -------------------------------------
if [[ "$readonly_run" == "yes" ]]; then
  ro_journal="$(gluerun_readonly_guard_capture "$worktree" "gemini-$run_id")"
fi

# stdout (the -o json envelope) and stderr (gemini's copious notices) are captured
# to SEPARATE files so a stray stderr line never corrupts the JSON parse.
envelope="$(mktemp "${TMPDIR:-/tmp}/gluerun-gemini-env.XXXXXX")"
envelope_err="$envelope.err"

# The provider as a SESSION LEADER: gluerun_setsid_exec is the LAST command, so
# the `&` at the call site makes $! the leader itself (pid == pgid) and
# gluerun_kill_tree group-kills the whole tree with one negative pid, without
# `ps` (PMGO-004). Only ever invoked as a background job, so the `cd` is
# contained; redirections live on the call site so they bind to the job.
run_gemini() {
  cd "$worktree" || exit 1
  gluerun_setsid_exec "${cmd[@]}"
}

exit_code=0
echo "gemini-run: level=$level model=${gem_model:-<default>} worktree=$worktree run_id=$run_id" >&2
# Wall-clock guard (default 1200s; 0 disables). Kill the whole process tree on
# timeout so a stuck run never holds a worker slot; surface exit 124.
gem_timeout="${GLUERUN_GEMINI_TIMEOUT_SEC:-1200}"
# The provider always runs in the BACKGROUND, even with the timeout disabled.
# bash defers a trapped signal until the foreground child finishes, so a
# foreground run would swallow the SIGTERM that ask/supervise/decide send on
# their way to a kill -- and with it the read-only guard's only chance to run.
# `wait` is interruptible by a trapped signal; a foreground child is not.
run_gemini <"$prompt_file" >"$envelope" 2>"$envelope_err" & gem_pid=$!
if [[ "$gem_timeout" =~ ^[0-9]+$ && "$gem_timeout" -gt 0 ]]; then
  gem_deadline=$((SECONDS + gem_timeout)); gem_timed_out="no"
  while kill -0 "$gem_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$gem_deadline" ]]; then
      gem_timed_out="yes"
      # TERM the provider session, then KILL what is left.
      gluerun_kill_tree "$gem_pid" "$(gluerun_provider_kill_grace_sec)" session
      wait "$gem_pid" 2>/dev/null || true
      exit_code=124
      break
    fi
    sleep 2
  done
  if [[ "$gem_timed_out" != "yes" ]]; then
    gem_ec=0; wait "$gem_pid" || gem_ec=$?; exit_code="$gem_ec"
  else
    echo "gemini-run: TIMED OUT after ${gem_timeout}s; killed run $run_id" >&2
  fi
else
  gem_ec=0; wait "$gem_pid" || gem_ec=$?; exit_code="$gem_ec"
fi
gem_pid=""

cat "$envelope" >&2 || true
[[ -s "$envelope_err" ]] && cat "$envelope_err" >&2 || true
if [[ -n "$run_dir" ]]; then cp "$envelope" "$run_dir/gemini-envelope.json" 2>/dev/null || true; fi

# --- Session-meta: no resumable id in v1; record provider + empty sessionId ----
if [[ -n "$session_meta_path" ]]; then
  gluerun_session_meta_write_provider "$session_meta_path" "gemini" "" "$gem_model" \
    "" "$worktree" "$exit_code" || true
fi

# --- Extract the final message into the output file -----------------------------
if [[ "$capture_packet" == "yes" && -n "$output_last_message" ]]; then
  parse_ec=0
  python3 - "$envelope" "$envelope_err" "$output_last_message" <<'PY' || parse_ec=$?
import json, sys
env_path, err_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

def load_envelope(path):
    # The `-o json` envelope has been observed on stdout AND (0.42.x, at least
    # for error envelopes) on stderr after human-readable warning lines. Accept
    # either stream: parse the whole file as JSON, else raw_decode from the
    # first '{'.
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read()
    except Exception:
        return None
    if not raw.strip():
        return None
    try:
        return json.loads(raw)
    except Exception:
        pass
    i = raw.find("{")
    if i < 0:
        return None
    try:
        env, _ = json.JSONDecoder().raw_decode(raw[i:])
        return env
    except Exception:
        return None

env = load_envelope(env_path)
if env is None:
    env = load_envelope(err_path)
if env is None:
    sys.stderr.write("gemini-run: could not parse gemini output as JSON (stdout or stderr)\n")
    sys.exit(3)
# `gemini -o json` reports failures as a top-level {"error": {...}} envelope.
if isinstance(env, dict) and env.get("error"):
    err = env.get("error")
    msg = err.get("message") if isinstance(err, dict) else err
    sys.stderr.write(f"gemini-run: error result: {msg}\n")
    sys.exit(4)
result = None
if isinstance(env, dict):
    result = env.get("response")
    if result is None:
        result = env.get("result")
    if result is None:
        result = env.get("text")
if result is None:
    sys.stderr.write("gemini-run: gemini output had no 'response' field\n")
    sys.exit(3)
if not isinstance(result, str):
    result = json.dumps(result)
with open(out_path, "w", encoding="utf-8") as f:
    f.write(result)
    if not result.endswith("\n"):
        f.write("\n")
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

if gluerun_runner_result_write gemini "$run_id" "$runner_role" "$capability_profile" \
  "$result_file" "$exit_code" "$envelope" "$envelope_err" "$output_last_message"; then
  runner_result_written="yes"
fi

exit "$exit_code"
