#!/usr/bin/env bash
set -euo pipefail

# grok-run.sh — Grok Build drop-in replacement for codex-run.sh / claude-run.sh.
#
# Same CLI surface and output contract so orchestration can dispatch the `grok`
# CLI by setting GLUERUN_RUNNER to this script. Parses the headless JSON envelope
# (.text field) into --output-last-message for gluerun_extract_json.

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
    --role) runner_role="$2"; shift 2 ;;
    --capability-profile) capability_profile="$2"; shift 2 ;;
    --result-file) result_file="$2"; shift 2 ;;
    --describe-contract) describe_contract="yes"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$describe_contract" == "yes" ]]; then
  gluerun_runner_describe_contract grok
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
gluerun_grok_result_on_exit() {
  local rc=$?
  trap - EXIT
  # An interrupted run leaves the provider CLI and its descendants alive; they
  # would keep writing to the worktree while the guard restores it, and the
  # restore would lose the race. Kill first, then restore.
  if [[ -n "${grok_pid:-}" ]]; then
    gluerun_kill_tree "$grok_pid" 2>/dev/null || true
    wait "$grok_pid" 2>/dev/null || true
  fi
  # Before the result write, because a containment failure that outlives the
  # process is the worse outcome. ask/supervise/decide background this runner
  # and kill it on timeout; the old guard was straight-line code after the run,
  # so on every one of those paths it simply never executed.
  gluerun_readonly_guard_restore "${ro_journal:-}" || true
  ro_journal=""
  if [[ "$runner_result_written" != "yes" ]]; then
    gluerun_runner_result_write grok "$run_id" "$runner_role" "$capability_profile" \
      "$result_file" "$rc" "${envelope:-}" "${envelope_err:-}" "$output_last_message" || true
  fi
  [[ -n "${envelope:-}" ]] && rm -f "$envelope" "${envelope_err:-}" 2>/dev/null || true
  exit "$rc"
}
trap gluerun_grok_result_on_exit EXIT
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

grok_bin="$(command -v grok 2>/dev/null || true)"

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
gluerun_runner_capability_prepare grok "$runner_role" "$capability_profile" \
  "$worktree" "$grok_bin" || profile_rc=$?
capability_profile="$GLUERUN_RESOLVED_CAPABILITY_PROFILE"
profile_provider_args=()
if [[ "$GLUERUN_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  profile_provider_args=("${GLUERUN_RESOLVED_PROVIDER_ARGS[@]}")
fi
[[ "$profile_rc" -eq 0 ]] || exit "$profile_rc"
gluerun_runner_reject_strict_legacy_extra_args \
  grok GLUERUN_GROK_EXTRA_ARGS "${GLUERUN_GROK_EXTRA_ARGS:-}" || exit $?
[[ -n "$grok_bin" ]] || { echo "grok CLI not found on PATH" >&2; exit 127; }

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

gluerun_grok_model() {
  local level="$1" prompt_file="$2" prompt_name
  prompt_name="$(basename "${prompt_file:-}")"
  case "$level" in
    l2)
      printf '%s\n' "${GLUERUN_GROK_L2_MODEL:-${GLUERUN_GROK_MODEL:-grok-build}}" ;;
    l0|l1)
      printf '%s\n' "${GLUERUN_GROK_L1_MODEL:-${GLUERUN_GROK_MODEL:-grok-build}}" ;;
    readonly|read-only)
      case "$prompt_name" in
        planner-prompt.md) printf '%s\n' "${GLUERUN_GROK_PLANNER_MODEL:-${GLUERUN_GROK_MODEL:-grok-build}}" ;;
        auditor-prompt.md) printf '%s\n' "${GLUERUN_GROK_AUDITOR_MODEL:-${GLUERUN_GROK_MODEL:-grok-build}}" ;;
        decider-prompt-*.md) printf '%s\n' "${GLUERUN_GROK_DECIDER_MODEL:-${GLUERUN_GROK_MODEL:-grok-build}}" ;;
        *) printf '%s\n' "${GLUERUN_GROK_MODEL:-grok-build}" ;;
      esac ;;
  esac
}
grok_model="$(gluerun_grok_model "$level" "$prompt_file")"

gluerun_grok_effort() {
  local level="$1" prompt_file="$2" prompt_name
  prompt_name="$(basename "${prompt_file:-}")"
  case "$level" in
    l2)
      printf '%s\n' "${GLUERUN_GROK_L2_EFFORT:-${GLUERUN_GROK_EFFORT:-medium}}" ;;
    readonly|read-only)
      case "$prompt_name" in
        planner-prompt.md) printf '%s\n' "${GLUERUN_GROK_PLANNER_EFFORT:-${GLUERUN_GROK_EFFORT:-high}}" ;;
        auditor-prompt.md) printf '%s\n' "${GLUERUN_GROK_AUDITOR_EFFORT:-${GLUERUN_GROK_EFFORT:-high}}" ;;
        decider-prompt-*.md) printf '%s\n' "${GLUERUN_GROK_DECIDER_EFFORT:-${GLUERUN_GROK_EFFORT:-}}" ;;
        *) printf '%s\n' "${GLUERUN_GROK_EFFORT:-}" ;;
      esac ;;
    *)
      printf '%s\n' "${GLUERUN_GROK_EFFORT:-}" ;;
  esac
}
grok_effort="$(gluerun_grok_effort "$level" "$prompt_file")"

grok_system_prompt="${GLUERUN_GROK_SYSTEM_PROMPT:-Your FINAL assistant message MUST be exactly one JSON object and nothing else: no prose, no preamble, no code fences, no trailing commentary. If you cannot comply, still emit a single JSON object describing the problem.}"

cmd=("$grok_bin" --output-format json --model "$grok_model" --cwd "$worktree")
if [[ "$GLUERUN_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  cmd+=("${profile_provider_args[@]}")
fi
[[ -n "$grok_effort" ]] && cmd+=(--effort "$grok_effort")
[[ -n "${GLUERUN_GROK_MAX_TURNS:-}" ]] && cmd+=(--max-turns "$GLUERUN_GROK_MAX_TURNS")

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

if [[ -n "${GLUERUN_GROK_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  cmd+=(${GLUERUN_GROK_EXTRA_ARGS})
fi

cmd+=(--prompt-file "$prompt_file")

if [[ "$readonly_run" == "yes" ]]; then
  ro_journal="$(gluerun_readonly_guard_capture "$worktree" "grok-$run_id")"
fi

envelope="$(mktemp "${TMPDIR:-/tmp}/gluerun-grok-env.XXXXXX")"
envelope_err="$envelope.err"

exit_code=0
echo "grok-run: level=$level model=$grok_model worktree=$worktree run_id=$run_id" >&2
grok_timeout="${GLUERUN_GROK_TIMEOUT_SEC:-1200}"
# The provider always runs in the BACKGROUND, even with the timeout disabled.
# bash defers a trapped signal until the foreground child finishes, so a
# foreground run would swallow the SIGTERM that ask/supervise/decide send on
# their way to a kill -- and with it the read-only guard's only chance to run.
# `wait` is interruptible by a trapped signal; a foreground child is not.
"${cmd[@]}" >"$envelope" 2>"$envelope_err" & grok_pid=$!
if [[ "$grok_timeout" =~ ^[0-9]+$ && "$grok_timeout" -gt 0 ]]; then
  grok_deadline=$((SECONDS + grok_timeout)); grok_timed_out="no"
  while kill -0 "$grok_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$grok_deadline" ]]; then
      grok_timed_out="yes"
      # kill -9 on the direct child only left grok's descendants running, which
      # is exactly what gluerun_kill_tree exists to prevent; the other runners
      # already used it.
      gluerun_kill_tree "$grok_pid"
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
  gluerun_readonly_guard_restore "$ro_journal" || true
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

if gluerun_runner_result_write grok "$run_id" "$runner_role" "$capability_profile" \
  "$result_file" "$exit_code" "$envelope" "$envelope_err" "$output_last_message"; then
  runner_result_written="yes"
fi

exit "$exit_code"
