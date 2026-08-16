#!/usr/bin/env bash
set -euo pipefail

# cursor-run.sh — Cursor CLI (cursor-agent) drop-in replacement for codex-run.sh /
# claude-run.sh.
#
# Same CLI surface and output contract so orchestration can dispatch the
# `cursor-agent` CLI by setting SINGULAR_RUNNER to this script. `cursor-agent -p
# --output-format json` emits a single result envelope {"type":"result","result":
# "<text>","is_error":bool,...}; we write .result into --output-last-message so the
# existing singular_extract_json / singular_l1_prepare_worker_packet pipeline digs the
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

# Argument vocabulary, traps, spawn/timeout/kill, capture, guard ordering and the
# result write are the shared skeleton in lib.sh (singular_runner_*). What
# remains below is cursor's own: level mapping, model selection, argv, envelope
# parsing, and its session-affinity answer.
#
# Session affinity: both flags are accepted for host compatibility.
# --session-meta is written best-effort (no sessionId); --resume-session is
# refused (exit 86).
singular_runner_parse_args "$@" || exit $?

if [[ "$describe_contract" == "yes" ]]; then
  singular_runner_describe_contract cursor
  exit 0
fi

singular_runner_install_traps cursor cursor-run

if [[ -z "$worktree" ]]; then
  echo "usage: $0 --worktree PATH [--level l1|l2|readonly] [--prompt-file FILE]" >&2
  exit 2
fi

singular_require_target_branch

# Provider facts (binary, update pin) come from engine/providers.json.
singular_provider_spec_load cursor || exit $?

cursor_bin="$(command -v "$SINGULAR_SPEC_BINARY" 2>/dev/null || true)"

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
singular_runner_capability_prepare cursor "$runner_role" "$capability_profile" \
  "$worktree" "$cursor_bin" || profile_rc=$?
capability_profile="$SINGULAR_RESOLVED_CAPABILITY_PROFILE"
profile_provider_args=()
if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  profile_provider_args=("${SINGULAR_RESOLVED_PROVIDER_ARGS[@]}")
fi
[[ "$profile_rc" -eq 0 ]] || exit "$profile_rc"
singular_runner_reject_strict_legacy_extra_args \
  cursor SINGULAR_CURSOR_EXTRA_ARGS "${SINGULAR_CURSOR_EXTRA_ARGS:-}" || exit $?
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
  run_dir="$SINGULAR_STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir"
  if [[ -z "$output_last_message" ]]; then
    output_last_message="$run_dir/last-message.json"
  fi
fi

# --- Model selection ------------------------------------------------------------
# The fallback is the spec's model.default, empty today: with nothing configured
# --model is OMITTED entirely so cursor-agent uses its own default/auto routing
# (spec 0.9.0). No per-role/effort mapping in v1.
cursor_model() {
  printf '%s\n' "${SINGULAR_CURSOR_MODEL:-$SINGULAR_SPEC_MODEL_DEFAULT}"
}
cur_model="$(cursor_model)"

# --- Assemble the cursor-agent invocation ---------------------------------------
# Prompt travels on STDIN (--print mode, no positional prompt). --trust trusts the
# worktree so a headless run never blocks on a workspace-trust prompt.
# The update pin goes FIRST and unconditionally: cursor-agent can install a new
# version of itself, which would swap the executable under a containment-critical
# invocation mid-run. The flag is the spec's, so the pin and the doctor probe
# that uses it cannot disagree.
cmd=("$cursor_bin")
if [[ ${#SINGULAR_SPEC_UPDATE_ARGS[@]} -gt 0 ]]; then
  cmd+=("${SINGULAR_SPEC_UPDATE_ARGS[@]}")
fi
cmd+=(-p --output-format json --workspace "$worktree" --trust)
if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  cmd+=("${profile_provider_args[@]}")
fi
[[ -n "$cur_model" ]] && cmd+=(--model "$cur_model")
if [[ "$readonly_run" == "yes" ]]; then
  cmd+=(--mode ask)   # read-only Q&A; no edits
else
  cmd+=(-f)           # force / auto-approve all tools
fi

if [[ -n "${SINGULAR_CURSOR_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  cmd+=(${SINGULAR_CURSOR_EXTRA_ARGS})
fi

# --- Read-only snapshot (for restore-after) -------------------------------------
singular_runner_guard_capture "$readonly_run" "$worktree" "cursor-$run_id"

singular_runner_capture_files cursor
envelope="$SINGULAR_RUNNER_ENVELOPE"

echo "cursor-run: level=$level model=${cur_model:-<default>} worktree=$worktree run_id=$run_id" >&2
# cursor-agent takes no working-directory flag, so the spawn cds into the
# worktree; the prompt travels on stdin.
singular_runner_spawn_wait "${SINGULAR_CURSOR_TIMEOUT_SEC:-1200}" "$prompt_file" \
  "$worktree" -- "${cmd[@]}"
exit_code="$SINGULAR_RUNNER_EXIT_CODE"

singular_runner_report_envelope "$run_dir"

# --- Session-meta: no resumable id in v1; record provider + empty sessionId ----
if [[ -n "$session_meta_path" ]]; then
  singular_session_meta_write_provider "$session_meta_path" "cursor" "" "$cur_model" \
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
singular_runner_guard_restore_now

# --- Scope enforcement for L0/L1 (mirrors codex-run.sh) -------------------------
singular_runner_scope_enforce "$level" "$worktree" "${allow_prefixes[@]}"

if [[ "$capture_packet" == "yes" ]]; then
  echo "last_message=$output_last_message" >&2
fi

singular_runner_finish "$exit_code"

exit "$exit_code"
