#!/usr/bin/env bash
set -euo pipefail

# opencode-run.sh — OpenCode drop-in replacement for codex-run.sh / claude-run.sh.
#
# Same CLI surface and output contract so orchestration can dispatch the `opencode`
# CLI by setting SINGULAR_RUNNER to this script. `opencode run --format json` emits a
# stream of newline-delimited JSON events; we reassemble the assistant's text parts
# and write them to --output-last-message so the existing singular_extract_json /
# singular_l1_prepare_worker_packet pipeline digs the JSON packet/verdict out exactly
# as it does for codex/claude output.
#
# Session affinity: OpenCode v1 exposes no captured session id here, so --session-meta
# is accepted and best-effort written (provider "opencode", empty sessionId) to keep
# the unconditional --session-meta call sites working, and --resume-session is refused
# with exit 86 (host falls back to a fresh run).
#
# Privilege levels:
#   readonly  -> `--agent plan`, OpenCode's built-in read-only primary agent,
#                plus the post-run restore guard as the backstop. This block
#                used to say the guard was the whole enforcement — it isn't
#                enough on its own: the guard reverts what a run LEFT BEHIND,
#                which cannot undo a `git commit` and cannot help at all if the
#                process is SIGKILLed before it runs.
#   l2        -> unconstrained write; file scope enforced downstream.
#   l0|l1     -> writes limited to --allow-prefix paths, verified by scope-check.sh
#                after the run (mirrors codex-run.sh).
# The prompt is fed on STDIN (opencode reads the message from stdin when no
# positional message is given), so large prompts never hit the argv size limit.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Argument vocabulary, traps, spawn/timeout/kill, capture, guard ordering and the
# result write are the shared skeleton in lib.sh (singular_runner_*). What
# remains below is opencode's own: level mapping, model selection, argv, and
# envelope parsing.
#
# Session affinity: both flags are accepted for host compatibility.
# --session-meta is written best-effort (no sessionId); --resume-session is
# refused (exit 86).
singular_runner_parse_args "$@" || exit $?

if [[ "$describe_contract" == "yes" ]]; then
  singular_runner_describe_contract opencode
  exit 0
fi

singular_runner_install_traps opencode opencode-run

if [[ -z "$worktree" ]]; then
  echo "usage: $0 --worktree PATH [--level l1|l2|readonly] [--prompt-file FILE]" >&2
  exit 2
fi

singular_require_target_branch

# Provider facts (binary, update pin) come from engine/providers.json. The pin --
# OPENCODE_DISABLE_AUTOUPDATE -- is exported by this call: opencode can upgrade
# itself, which would swap the executable a run is using.
singular_provider_spec_load opencode || exit $?

opencode_bin="$(command -v "$SINGULAR_SPEC_BINARY" 2>/dev/null || true)"

# --output-schema is accepted for contract parity; OpenCode cannot enforce a
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
  echo "opencode-run: --prompt-file is required" >&2
  exit 2
fi

profile_rc=0
singular_runner_capability_prepare opencode "$runner_role" "$capability_profile" \
  "$worktree" "$opencode_bin" || profile_rc=$?
capability_profile="$SINGULAR_RESOLVED_CAPABILITY_PROFILE"
profile_provider_args=()
if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  profile_provider_args=("${SINGULAR_RESOLVED_PROVIDER_ARGS[@]}")
fi
[[ "$profile_rc" -eq 0 ]] || exit "$profile_rc"
singular_runner_reject_strict_legacy_extra_args \
  opencode SINGULAR_OPENCODE_EXTRA_ARGS "${SINGULAR_OPENCODE_EXTRA_ARGS:-}" || exit $?
[[ -n "$opencode_bin" ]] || { echo "opencode CLI not found on PATH" >&2; exit 127; }
profile_native_args=()
if [[ "$SINGULAR_RESOLVED_CAPABILITY_STRICT" == "yes" ]]; then
  profile_native_args+=(--pure)
fi

# ---- Session affinity: resume refusal (exit 86) -----------------------------
if [[ -n "$resume_session_id" ]]; then
  echo "opencode-run: resume unsupported (no session affinity); signalling resume-refusal" >&2
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
# -m is OMITTED entirely so OpenCode uses its own configured default model (spec
# 0.9.0). Model refs are `provider/model` strings.
opencode_model() {
  printf '%s\n' "${SINGULAR_OPENCODE_MODEL:-$SINGULAR_SPEC_MODEL_DEFAULT}"
}
oc_model="$(opencode_model)"

# --- Assemble the opencode invocation -------------------------------------------
# Prompt travels on STDIN (no positional message). --format json emits raw JSON
# events; there are no interactive approval prompts (permission config governs).
cmd=("$opencode_bin" run --format json)
if [[ ${#profile_native_args[@]} -gt 0 ]]; then
  cmd+=("${profile_native_args[@]}")
fi
if [[ "$SINGULAR_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  cmd+=("${profile_provider_args[@]}")
fi
[[ -n "$oc_model" ]] && cmd+=(-m "$oc_model")
if [[ "$readonly_run" == "yes" ]]; then
  # `plan` is OpenCode's built-in read-only primary agent. Until now this runner
  # passed NOTHING for a read-only run — its header said so outright, treating
  # the post-run restore guard as the entire enforcement. That made opencode the
  # only provider with no in-run restriction at all: codex takes an OS sandbox,
  # grok --sandbox read-only, gemini --approval-mode plan, cursor --mode ask.
  cmd+=(--agent "${SINGULAR_OPENCODE_READONLY_AGENT:-plan}")
fi

if [[ -n "${SINGULAR_OPENCODE_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  cmd+=(${SINGULAR_OPENCODE_EXTRA_ARGS})
fi

# --- Read-only snapshot (for restore-after) -------------------------------------
singular_runner_guard_capture "$readonly_run" "$worktree" "opencode-$run_id"

singular_runner_capture_files opencode
envelope="$SINGULAR_RUNNER_ENVELOPE"
envelope_err="$SINGULAR_RUNNER_ENVELOPE_ERR"

echo "opencode-run: level=$level model=${oc_model:-<default>} worktree=$worktree run_id=$run_id" >&2
# opencode takes no working-directory flag, so the spawn cds into the worktree;
# the prompt travels on stdin.
singular_runner_spawn_wait "${SINGULAR_OPENCODE_TIMEOUT_SEC:-1200}" "$prompt_file" \
  "$worktree" -- "${cmd[@]}"
exit_code="$SINGULAR_RUNNER_EXIT_CODE"

singular_runner_report_envelope "$run_dir"

# --- Session-meta: no resumable id in v1; record provider + empty sessionId ----
if [[ -n "$session_meta_path" ]]; then
  singular_session_meta_write_provider "$session_meta_path" "opencode" "" "$oc_model" \
    "" "$worktree" "$exit_code" || true
fi

# --- Reassemble the assistant message from the JSON event stream ----------------
if [[ "$capture_packet" == "yes" && -n "$output_last_message" ]]; then
  parse_ec=0
  python3 - "$envelope" "$output_last_message" <<'PY' || parse_ec=$?
import json, sys
env_path, out_path = sys.argv[1], sys.argv[2]

error_msg = None
text_parts = {}   # part id -> full text (parts are full-state snapshots; last wins)
part_order = []   # first-appearance order of part ids
part_msg = {}     # part id -> owning messageID
roles = {}        # messageID -> role
had_json = False

def note_text_part(d):
    pid = d.get("id")
    if not isinstance(pid, str):
        pid = "__anon_%d" % len(part_order)
    if pid not in text_parts:
        part_order.append(pid)
    text_parts[pid] = d.get("text") or ""
    mid = d.get("messageID") or d.get("messageId")
    if isinstance(mid, str):
        part_msg[pid] = mid

def note_role(d):
    mid, role = d.get("id"), d.get("role")
    if isinstance(mid, str) and isinstance(role, str) and role in ("user", "assistant", "system"):
        roles[mid] = role

def walk(o):
    if isinstance(o, dict):
        if o.get("type") == "text" and isinstance(o.get("text"), str):
            note_text_part(o)
        if isinstance(o.get("role"), str) and isinstance(o.get("id"), str):
            note_role(o)
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)

try:
    with open(env_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            had_json = True
            if isinstance(obj, dict) and obj.get("type") == "error":
                err = obj.get("error")
                if isinstance(err, dict):
                    data = err.get("data") if isinstance(err.get("data"), dict) else {}
                    error_msg = data.get("message") or err.get("message") or err.get("name") or "error"
                else:
                    error_msg = str(err) if err else "error"
            walk(obj)
except Exception as e:
    sys.stderr.write(f"opencode-run: could not read opencode output: {e}\n")
    sys.exit(3)

if error_msg is not None:
    sys.stderr.write(f"opencode-run: error event: {error_msg}\n")
    sys.exit(4)

# Prefer assistant-role text; when roles are known, drop parts owned by the
# echoed user/system messages. Otherwise fall back to all text parts in order.
assistant = {m for m, r in roles.items() if r == "assistant"}
ordered = part_order
if assistant:
    sel = [pid for pid in ordered if part_msg.get(pid) in assistant]
    if sel:
        ordered = sel
result = "".join(text_parts[pid] for pid in ordered).strip()
if not result:
    sys.stderr.write("opencode-run: no assistant text found in opencode events\n"
                     if had_json else "opencode-run: opencode produced no JSON events\n")
    sys.exit(3)
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
