#!/usr/bin/env bash
set -euo pipefail

# grok-run.sh — Grok Build drop-in replacement for codex-run.sh / claude-run.sh.
#
# Same CLI surface and output contract so orchestration can dispatch the `grok`
# CLI by setting SINGULAR_RUNNER to this script. Parses the headless JSON envelope
# (.text field) into --output-last-message for singular_extract_json.

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
# Session affinity: both accepted for host compatibility, because
# singular_runner_describe_contract advertises them for every runner and the
# unconditional call sites would otherwise die on "unknown option" (exit 2).
# Unlike cursor, grok's headless envelope DOES carry a real `sessionId`, so
# --session-meta is written with it. --resume-session is still refused (exit 86):
# grok has `--resume`, but resume-plus-prompt-file is unproven here and a wrong
# guess would silently continue the wrong conversation.
session_meta_path=""
resume_session_id=""
runner_role="${SINGULAR_RUNNER_ROLE:-unknown}"
capability_profile="${SINGULAR_RUNNER_CAPABILITY_PROFILE:-default}"
result_file="${SINGULAR_RUNNER_RESULT_FILE:-}"
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
  singular_runner_describe_contract grok
  exit 0
fi

if [[ -z "$run_id" ]]; then
  run_id="RUN-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
if [[ -z "$result_file" ]]; then
  result_file="$(singular_runner_default_result_file "$run_id")"
fi
runner_result_written="no"
ro_journal=""
singular_grok_result_on_exit() {
  local rc=$?
  trap - EXIT
  # An interrupted run leaves the provider CLI and its descendants alive; they
  # would keep writing to the worktree while the guard restores it, and the
  # restore would lose the race. Kill first, then restore.
  if [[ -n "${grok_pid:-}" ]]; then
    singular_kill_tree "$grok_pid" 0 session 2>/dev/null || true
    wait "$grok_pid" 2>/dev/null || true
    grok_pid=""
  fi
  # Before the result write, because a containment failure that outlives the
  # process is the worse outcome. ask/supervise/decide background this runner
  # and kill it on timeout; the old guard was straight-line code after the run,
  # so on every one of those paths it simply never executed.
  singular_readonly_guard_restore "${ro_journal:-}" || true
  ro_journal=""
  if [[ "$runner_result_written" != "yes" ]]; then
    singular_runner_result_write grok "$run_id" "$runner_role" "$capability_profile" \
      "$result_file" "$rc" "${envelope:-}" "${envelope_err:-}" "$output_last_message" || true
  fi
  [[ -n "${envelope:-}" ]] && rm -f "$envelope" "${envelope_err:-}" 2>/dev/null || true
  exit "$rc"
}
trap singular_grok_result_on_exit EXIT
# Exiting from a signal handler runs the EXIT trap, so these buy the guard a
# chance to run on the SIGTERM that precedes a kill-tree's SIGKILL. SIGKILL
# itself remains uncoverable; `singular_readonly_guard_sweep` is the answer there.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -z "$worktree" ]]; then
  echo "usage: $0 --worktree PATH [--level l1|l2|readonly] [--prompt-file FILE]" >&2
  exit 2
fi

singular_require_target_branch

# Provider facts (binary, default model, update pin) come from
# engine/providers.json -- the default that shipped as `grok-build` lived in this
# file and in doctor's table at once, and they were edited apart.
singular_provider_spec_load grok || exit $?

grok_bin="$(command -v "$SINGULAR_SPEC_BINARY" 2>/dev/null || true)"

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
  echo "grok-run: --prompt-file is required" >&2
  exit 2
fi

profile_rc=0
singular_runner_capability_prepare grok "$runner_role" "$capability_profile" \
  "$worktree" "$grok_bin" || profile_rc=$?
capability_profile="$SINGULAR_RESOLVED_CAPABILITY_PROFILE"
profile_provider_args=()
if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  profile_provider_args=("${SINGULAR_RESOLVED_PROVIDER_ARGS[@]}")
fi
[[ "$profile_rc" -eq 0 ]] || exit "$profile_rc"
singular_runner_reject_strict_legacy_extra_args \
  grok SINGULAR_GROK_EXTRA_ARGS "${SINGULAR_GROK_EXTRA_ARGS:-}" || exit $?
[[ -n "$grok_bin" ]] || { echo "grok CLI not found on PATH" >&2; exit 127; }

# ---- Session affinity: resume refusal (exit 86) -----------------------------
if [[ -n "$resume_session_id" ]]; then
  echo "grok-run: resume unsupported (unproven with --prompt-file); signalling resume-refusal" >&2
  exit 86
fi

if [[ "$capture_packet" == "auto" && "$level" == "l2" ]]; then
  capture_packet="yes"
elif [[ "$capture_packet" == "auto" ]]; then
  capture_packet="no"
fi

run_dir=""
if [[ "$capture_packet" == "yes" ]]; then
  run_dir="$SINGULAR_STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir"
  if [[ -z "$output_last_message" ]]; then
    output_last_message="$run_dir/last-message.json"
  fi
fi

# `grok-build` was the product name, never a model id. The installed CLI serves
# `grok-4.6` (default) and `grok-4.5` — `grok models` lists exactly those — so
# every run built with the old default asked for a model that does not exist.
# The value now comes from the spec row that doctor's conformance probe checks
# against that same listing, so a default nothing serves fails preflight.
SINGULAR_GROK_DEFAULT_MODEL="${SINGULAR_GROK_DEFAULT_MODEL:-$SINGULAR_SPEC_MODEL_DEFAULT}"

singular_grok_model() {
  local level="$1" prompt_file="$2" prompt_name
  prompt_name="$(basename "${prompt_file:-}")"
  case "$level" in
    l2)
      printf '%s\n' "${SINGULAR_GROK_L2_MODEL:-${SINGULAR_GROK_MODEL:-$SINGULAR_GROK_DEFAULT_MODEL}}" ;;
    l0|l1)
      printf '%s\n' "${SINGULAR_GROK_L1_MODEL:-${SINGULAR_GROK_MODEL:-$SINGULAR_GROK_DEFAULT_MODEL}}" ;;
    readonly|read-only)
      case "$prompt_name" in
        planner-prompt.md) printf '%s\n' "${SINGULAR_GROK_PLANNER_MODEL:-${SINGULAR_GROK_MODEL:-$SINGULAR_GROK_DEFAULT_MODEL}}" ;;
        auditor-prompt.md) printf '%s\n' "${SINGULAR_GROK_AUDITOR_MODEL:-${SINGULAR_GROK_MODEL:-$SINGULAR_GROK_DEFAULT_MODEL}}" ;;
        decider-prompt-*.md) printf '%s\n' "${SINGULAR_GROK_DECIDER_MODEL:-${SINGULAR_GROK_MODEL:-$SINGULAR_GROK_DEFAULT_MODEL}}" ;;
        *) printf '%s\n' "${SINGULAR_GROK_MODEL:-$SINGULAR_GROK_DEFAULT_MODEL}" ;;
      esac ;;
  esac
}
grok_model="$(singular_grok_model "$level" "$prompt_file")"

singular_grok_effort() {
  local level="$1" prompt_file="$2" prompt_name
  prompt_name="$(basename "${prompt_file:-}")"
  case "$level" in
    l2)
      printf '%s\n' "${SINGULAR_GROK_L2_EFFORT:-${SINGULAR_GROK_EFFORT:-medium}}" ;;
    readonly|read-only)
      case "$prompt_name" in
        planner-prompt.md) printf '%s\n' "${SINGULAR_GROK_PLANNER_EFFORT:-${SINGULAR_GROK_EFFORT:-high}}" ;;
        auditor-prompt.md) printf '%s\n' "${SINGULAR_GROK_AUDITOR_EFFORT:-${SINGULAR_GROK_EFFORT:-high}}" ;;
        decider-prompt-*.md) printf '%s\n' "${SINGULAR_GROK_DECIDER_EFFORT:-${SINGULAR_GROK_EFFORT:-}}" ;;
        *) printf '%s\n' "${SINGULAR_GROK_EFFORT:-}" ;;
      esac ;;
    *)
      printf '%s\n' "${SINGULAR_GROK_EFFORT:-}" ;;
  esac
}
grok_effort="$(singular_grok_effort "$level" "$prompt_file")"

grok_system_prompt="${SINGULAR_GROK_SYSTEM_PROMPT:-Your FINAL assistant message MUST be exactly one JSON object and nothing else: no prose, no preamble, no code fences, no trailing commentary. If you cannot comply, still emit a single JSON object describing the problem.}"

# The update pin FIRST and unconditionally: grok's bootstrap can replace the
# executable mid-run, which would swap the binary under a containment-critical
# invocation. It is a hidden flag (absent from --help) but accepted by 1.0.4, and
# it comes from the spec so this pin and doctor's model listing cannot disagree.
cmd=("$grok_bin")
if [[ ${#SINGULAR_SPEC_UPDATE_ARGS[@]} -gt 0 ]]; then
  cmd+=("${SINGULAR_SPEC_UPDATE_ARGS[@]}")
fi
cmd+=(--output-format json --model "$grok_model" --cwd "$worktree")
if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  cmd+=("${profile_provider_args[@]}")
fi
[[ -n "$grok_effort" ]] && cmd+=(--effort "$grok_effort")
[[ -n "${SINGULAR_GROK_MAX_TURNS:-}" ]] && cmd+=(--max-turns "$SINGULAR_GROK_MAX_TURNS")

if [[ "$readonly_run" == "yes" ]]; then
  cmd+=(--sandbox read-only)
  cmd+=(--disallowed-tools "search_replace,write,delete_file,edit_notebook")
  grok_system_prompt+=" You are STRICTLY READ-ONLY: do not create, modify, or delete any file, and do not run state-mutating git commands."
else
  cmd+=(--sandbox workspace --yolo)
  if [[ "$level" == "l0" || "$level" == "l1" ]]; then
    for prefix in "${allow_prefixes[@]}"; do
      cmd+=(--allow "Write($prefix**)" --allow "Edit($prefix**)")
    done
  fi
fi

if [[ -n "$grok_system_prompt" ]]; then
  cmd+=(--system-prompt-override "$grok_system_prompt")
fi

if [[ -n "${SINGULAR_GROK_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  cmd+=(${SINGULAR_GROK_EXTRA_ARGS})
fi

cmd+=(--prompt-file "$prompt_file")

if [[ "$readonly_run" == "yes" ]]; then
  ro_journal="$(singular_readonly_guard_capture "$worktree" "grok-$run_id")"
fi

envelope="$(mktemp "${TMPDIR:-/tmp}/singular-grok-env.XXXXXX")"
envelope_err="$envelope.err"

exit_code=0
echo "grok-run: level=$level model=$grok_model worktree=$worktree run_id=$run_id" >&2
grok_timeout="${SINGULAR_GROK_TIMEOUT_SEC:-1200}"
# The provider always runs in the BACKGROUND, even with the timeout disabled.
# bash defers a trapped signal until the foreground child finishes, so a
# foreground run would swallow the SIGTERM that ask/supervise/decide send on
# their way to a kill -- and with it the read-only guard's only chance to run.
# `wait` is interruptible by a trapped signal; a foreground child is not.
# The provider as a SESSION LEADER: singular_setsid_exec is the LAST command of
# run_grok, so `&` makes $! the leader itself (pid == pgid) and singular_kill_tree
# group-kills the whole tree with one negative pid, without `ps` (PMGO-004).
# grok gets its working directory from --cwd, so there is no `cd` here.
# Redirections live on the call site so they bind to the job.
run_grok() {
  singular_setsid_exec "${cmd[@]}"
}
run_grok >"$envelope" 2>"$envelope_err" & grok_pid=$!
if [[ "$grok_timeout" =~ ^[0-9]+$ && "$grok_timeout" -gt 0 ]]; then
  grok_deadline=$((SECONDS + grok_timeout)); grok_timed_out="no"
  while kill -0 "$grok_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$grok_deadline" ]]; then
      grok_timed_out="yes"
      # kill -9 on the direct child only left grok's descendants running, which
      # is exactly what singular_kill_tree exists to prevent; the other runners
      # already used it. TERM the session first, then KILL what is left.
      singular_kill_tree "$grok_pid" "$(singular_provider_kill_grace_sec)" session
      wait "$grok_pid" 2>/dev/null || true
      exit_code=124
      break
    fi
    sleep 2
  done
  if [[ "$grok_timed_out" != "yes" ]]; then
    grok_ec=0; wait "$grok_pid" || grok_ec=$?; exit_code="$grok_ec"
  else
    echo "grok-run: TIMED OUT after ${grok_timeout}s; killed run $run_id" >&2
  fi
else
  grok_ec=0; wait "$grok_pid" || grok_ec=$?; exit_code="$grok_ec"
fi
grok_pid=""

cat "$envelope" >&2 || true
[[ -s "$envelope_err" ]] && cat "$envelope_err" >&2 || true
if [[ -n "$run_dir" ]]; then cp "$envelope" "$run_dir/grok-envelope.json" 2>/dev/null || true; fi

# --- Session-meta: the real sessionId out of the envelope ----------------------
# Best-effort: a missing/unparseable id writes an empty one rather than failing
# the run, and never fabricates a value.
if [[ -n "$session_meta_path" ]]; then
  grok_session_id="$(python3 - "$envelope" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        env = json.load(f)
except Exception:
    env = {}
sid = env.get("sessionId") if isinstance(env, dict) else None
sys.stdout.write(sid if isinstance(sid, str) else "")
PY
)"
  singular_session_meta_write_provider "$session_meta_path" "grok" "$grok_session_id" \
    "$grok_model" "$grok_effort" "$worktree" "$exit_code" || true
fi

if [[ "$capture_packet" == "yes" && -n "$output_last_message" ]]; then
  parse_ec=0
  python3 - "$envelope" "$output_last_message" <<'PY' || parse_ec=$?
import json, sys
env_path, out_path = sys.argv[1], sys.argv[2]
try:
    with open(env_path, "r", encoding="utf-8") as f:
        env = json.load(f)
except Exception as e:
    sys.stderr.write(f"grok-run: could not parse grok envelope as JSON: {e}\n")
    sys.exit(3)
if env.get("type") == "error":
    sys.stderr.write(f"grok-run: error envelope: {env.get('message', env)}\n")
    sys.exit(3)
result = env.get("text")
if result is None:
    sys.stderr.write("grok-run: grok envelope had no 'text' field\n")
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
  singular_readonly_guard_restore "$ro_journal" || true
  ro_journal=""
fi

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

if singular_runner_result_write grok "$run_id" "$runner_role" "$capability_profile" \
  "$result_file" "$exit_code" "$envelope" "$envelope_err" "$output_last_message"; then
  runner_result_written="yes"
fi

exit "$exit_code"
