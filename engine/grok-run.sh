#!/usr/bin/env bash
set -euo pipefail

# grok-run.sh — Grok Build drop-in replacement for codex-run.sh / claude-run.sh.
#
# Same CLI surface and output contract so orchestration can dispatch the `grok`
# CLI by setting SINGULAR_RUNNER to this script. Parses the headless JSON envelope
# (.text field) into --output-last-message for singular_extract_json.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Argument vocabulary, traps, spawn/timeout/kill, capture, guard ordering and the
# result write are the shared skeleton in lib.sh (singular_runner_*). What
# remains below is grok's own: level mapping, model and effort selection, argv,
# envelope parsing, and the session id its envelope carries.
#
# Session affinity: both flags are accepted for host compatibility.
# Unlike cursor, grok's headless envelope DOES carry a
# real sessionId, so --session-meta is written with it. --resume-session is
# still refused (exit 86): grok has `--resume`, but resume-plus-prompt-file is
# unproven here and a wrong guess would silently continue the wrong conversation.
singular_runner_parse_args "$@" || exit $?

if [[ "$describe_contract" == "yes" ]]; then
  singular_runner_describe_contract grok
  exit 0
fi

singular_runner_install_traps grok grok-run

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

singular_runner_guard_capture "$readonly_run" "$worktree" "grok-$run_id"

singular_runner_capture_files grok
envelope="$SINGULAR_RUNNER_ENVELOPE"
envelope_err="$SINGULAR_RUNNER_ENVELOPE_ERR"

echo "grok-run: level=$level model=$grok_model worktree=$worktree run_id=$run_id" >&2
# grok gets its working directory from --cwd and its prompt from --prompt-file,
# so the spawn needs neither a cd nor stdin.
singular_runner_spawn_wait "${SINGULAR_GROK_TIMEOUT_SEC:-1200}" "" "" -- "${cmd[@]}"
exit_code="$SINGULAR_RUNNER_EXIT_CODE"

singular_runner_report_envelope "$run_dir"

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
singular_runner_guard_restore_now

# --- Scope enforcement for L0/L1 (mirrors codex-run.sh) -------------------------
singular_runner_scope_enforce "$level" "$worktree" "${allow_prefixes[@]}"

if [[ "$capture_packet" == "yes" ]]; then
  echo "last_message=$output_last_message" >&2
fi

singular_runner_finish "$exit_code"

exit "$exit_code"
