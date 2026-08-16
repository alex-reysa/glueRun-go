#!/usr/bin/env bash
set -euo pipefail

# gemini-run.sh — Gemini CLI drop-in replacement for codex-run.sh / claude-run.sh.
#
# Same CLI surface and output contract so orchestration can dispatch the `gemini`
# CLI by setting SINGULAR_RUNNER to this script. Parses the headless JSON output
# (.response field of `gemini -o json`) into --output-last-message so the existing
# singular_extract_json / singular_l1_prepare_worker_packet pipeline digs the JSON
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

# Argument vocabulary, traps, spawn/timeout/kill, capture, guard ordering and the
# result write are the shared skeleton in lib.sh (singular_runner_*). What
# remains below is gemini's own: level mapping, model selection, argv, and
# envelope parsing.
#
# Session affinity: both flags are accepted for host compatibility.
# --session-meta is written best-effort (no sessionId); --resume-session is
# refused (exit 86).
singular_runner_parse_args "$@" || exit $?

if [[ "$describe_contract" == "yes" ]]; then
  singular_runner_describe_contract gemini
  exit 0
fi

singular_runner_install_traps gemini gemini-run

if [[ -z "$worktree" ]]; then
  echo "usage: $0 --worktree PATH [--level l1|l2|readonly] [--prompt-file FILE]" >&2
  exit 2
fi

singular_require_target_branch

# Provider facts (binary, model default, update pin) come from
# engine/providers.json. Gemini's row declares no pin and says why: its
# auto-update path is reached only from the interactive UI startup, which a
# headless run never enters.
singular_provider_spec_load gemini || exit $?

gemini_bin="$(command -v "$SINGULAR_SPEC_BINARY" 2>/dev/null || true)"

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
singular_runner_capability_prepare gemini "$runner_role" "$capability_profile" \
  "$worktree" "$gemini_bin" || profile_rc=$?
capability_profile="$SINGULAR_RESOLVED_CAPABILITY_PROFILE"
profile_provider_args=()
if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  profile_provider_args=("${SINGULAR_RESOLVED_PROVIDER_ARGS[@]}")
fi
[[ "$profile_rc" -eq 0 ]] || exit "$profile_rc"
singular_runner_reject_strict_legacy_extra_args \
  gemini SINGULAR_GEMINI_EXTRA_ARGS "${SINGULAR_GEMINI_EXTRA_ARGS:-}" || exit $?
[[ -n "$gemini_bin" ]] || { echo "gemini CLI not found on PATH" >&2; exit 127; }
profile_native_args=()
if [[ "$SINGULAR_RESOLVED_CAPABILITY_STRICT" == "yes" ]]; then
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
  run_dir="$SINGULAR_STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir"
  if [[ -z "$output_last_message" ]]; then
    output_last_message="$run_dir/last-message.json"
  fi
fi

# --- Model selection ------------------------------------------------------------
# The fallback is the spec's model.default, empty today: with nothing configured
# -m is OMITTED entirely so the CLI uses its own default/auto routing (spec
# 0.9.0). Giving gemini a default later is a spec edit, not an adapter edit.
# No per-role/effort mapping in v1.
gemini_model() {
  printf '%s\n' "${SINGULAR_GEMINI_MODEL:-$SINGULAR_SPEC_MODEL_DEFAULT}"
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
if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  cmd+=("${profile_provider_args[@]}")
fi
[[ -n "$gem_model" ]] && cmd+=(-m "$gem_model")
if [[ "$readonly_run" == "yes" ]]; then
  cmd+=(--approval-mode plan)
else
  cmd+=(--yolo)
fi

if [[ -n "${SINGULAR_GEMINI_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  cmd+=(${SINGULAR_GEMINI_EXTRA_ARGS})
fi

# --- Read-only snapshot (for restore-after) -------------------------------------
singular_runner_guard_capture "$readonly_run" "$worktree" "gemini-$run_id"

# stdout (the -o json envelope) and stderr (gemini's copious notices) are
# captured to SEPARATE files so a stray stderr line never corrupts the parse.
singular_runner_capture_files gemini
envelope="$SINGULAR_RUNNER_ENVELOPE"
envelope_err="$SINGULAR_RUNNER_ENVELOPE_ERR"

echo "gemini-run: level=$level model=${gem_model:-<default>} worktree=$worktree run_id=$run_id" >&2
# gemini takes no working-directory flag, so the spawn cds into the worktree.
singular_runner_spawn_wait "${SINGULAR_GEMINI_TIMEOUT_SEC:-1200}" "$prompt_file" \
  "$worktree" -- "${cmd[@]}"
exit_code="$SINGULAR_RUNNER_EXIT_CODE"

singular_runner_report_envelope "$run_dir"

# --- Session-meta: no resumable id in v1; record provider + empty sessionId ----
if [[ -n "$session_meta_path" ]]; then
  singular_session_meta_write_provider "$session_meta_path" "gemini" "" "$gem_model" \
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
singular_runner_guard_restore_now

# --- Scope enforcement for L0/L1 (mirrors codex-run.sh) -------------------------
singular_runner_scope_enforce "$level" "$worktree" "${allow_prefixes[@]}"

if [[ "$capture_packet" == "yes" ]]; then
  echo "last_message=$output_last_message" >&2
fi

singular_runner_finish "$exit_code"

exit "$exit_code"
