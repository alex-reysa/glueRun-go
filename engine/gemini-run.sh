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
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$worktree" ]]; then
  echo "usage: $0 --worktree PATH [--level l1|l2|readonly] [--prompt-file FILE]" >&2
  exit 2
fi

gluerun_require_target_branch

command -v gemini >/dev/null 2>&1 || { echo "gemini CLI not found on PATH" >&2; exit 127; }

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

# ---- Session affinity: resume refusal (exit 86) -----------------------------
# Gemini v1 has no captured/resumable session id, so any resume request is
# refused up front; the host re-runs fresh (a pure optimization miss).
if [[ -n "$resume_session_id" ]]; then
  echo "gemini-run: resume unsupported (no session affinity); signalling resume-refusal" >&2
  exit 86
fi

if [[ -z "$run_id" ]]; then
  run_id="RUN-$(date -u +%Y%m%dT%H%M%SZ)-$$"
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
cmd=(gemini -p "" -o json --skip-trust)
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
ro_before_untracked=""
ro_before_mod=""
if [[ "$readonly_run" == "yes" ]]; then
  ro_before_untracked="$(git -C "$worktree" ls-files --others --exclude-standard 2>/dev/null | sort || true)"
  ro_before_mod="$(git -C "$worktree" diff --name-only HEAD 2>/dev/null | sort || true)"
fi

# stdout (the -o json envelope) and stderr (gemini's copious notices) are captured
# to SEPARATE files so a stray stderr line never corrupts the JSON parse.
envelope="$(mktemp "${TMPDIR:-/tmp}/gluerun-gemini-env.XXXXXX")"
envelope_err="$envelope.err"
trap 'rm -f "$envelope" "$envelope_err" 2>/dev/null || true' EXIT

run_gemini() {
  ( cd "$worktree" && "${cmd[@]}" <"$prompt_file" ) >"$envelope" 2>"$envelope_err"
}

exit_code=0
echo "gemini-run: level=$level model=${gem_model:-<default>} worktree=$worktree run_id=$run_id" >&2
# Wall-clock guard (default 1200s; 0 disables). Kill the whole process tree on
# timeout so a stuck run never holds a worker slot; surface exit 124.
gem_timeout="${GLUERUN_GEMINI_TIMEOUT_SEC:-1200}"
if [[ "$gem_timeout" =~ ^[0-9]+$ && "$gem_timeout" -gt 0 ]]; then
  run_gemini & gem_pid=$!
  gem_deadline=$((SECONDS + gem_timeout)); gem_timed_out="no"
  while kill -0 "$gem_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$gem_deadline" ]]; then
      gem_timed_out="yes"
      gluerun_kill_tree "$gem_pid"   # SIGKILL gemini + every descendant
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
  run_gemini || exit_code=$?
fi

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
if [[ "$readonly_run" == "yes" ]]; then
  ro_after_untracked="$(git -C "$worktree" ls-files --others --exclude-standard 2>/dev/null | sort || true)"
  comm -13 <(printf '%s\n' "$ro_before_untracked") <(printf '%s\n' "$ro_after_untracked") \
    | while IFS= read -r f; do
        [[ -n "$f" ]] && rm -rf "$worktree/$f" 2>/dev/null || true
      done
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

exit "$exit_code"
