#!/usr/bin/env bash
set -euo pipefail

# opencode-run.sh — OpenCode drop-in replacement for codex-run.sh / claude-run.sh.
#
# Same CLI surface and output contract so orchestration can dispatch the `opencode`
# CLI by setting GLUERUN_RUNNER to this script. `opencode run --format json` emits a
# stream of newline-delimited JSON events; we reassemble the assistant's text parts
# and write them to --output-last-message so the existing gluerun_extract_json /
# gluerun_l1_prepare_worker_packet pipeline digs the JSON packet/verdict out exactly
# as it does for codex/claude output.
#
# Session affinity: OpenCode v1 exposes no captured session id here, so --session-meta
# is accepted and best-effort written (provider "opencode", empty sessionId) to keep
# the unconditional --session-meta call sites working, and --resume-session is refused
# with exit 86 (host falls back to a fresh run).
#
# Privilege levels:
#   readonly  -> OpenCode `run` has no read-only mode flag; enforcement is the
#                post-run git restore guard, which reverts any mutation the run
#                leaves behind (bulletproof regardless of the model's tools).
#   l2        -> unconstrained write; file scope enforced downstream.
#   l0|l1     -> writes limited to --allow-prefix paths, verified by scope-check.sh
#                after the run (mirrors codex-run.sh).
# The prompt is fed on STDIN (opencode reads the message from stdin when no
# positional message is given), so large prompts never hit the argv size limit.

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
  gluerun_runner_describe_contract opencode
  exit 0
fi

if [[ -z "$run_id" ]]; then
  run_id="RUN-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
if [[ -z "$result_file" ]]; then
  result_file="$(gluerun_runner_default_result_file "$run_id")"
fi
runner_result_written="no"
gluerun_opencode_result_on_exit() {
  local rc=$?
  trap - EXIT
  if [[ "$runner_result_written" != "yes" ]]; then
    gluerun_runner_result_write opencode "$run_id" "$runner_role" "$capability_profile" \
      "$result_file" "$rc" "${envelope:-}" "${envelope_err:-}" "$output_last_message" || true
  fi
  [[ -n "${envelope:-}" ]] && rm -f "$envelope" "${envelope_err:-}" 2>/dev/null || true
  exit "$rc"
}
trap gluerun_opencode_result_on_exit EXIT

if [[ -z "$worktree" ]]; then
  echo "usage: $0 --worktree PATH [--level l1|l2|readonly] [--prompt-file FILE]" >&2
  exit 2
fi

gluerun_require_target_branch

opencode_bin="$(command -v opencode 2>/dev/null || true)"

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
gluerun_runner_capability_prepare opencode "$runner_role" "$capability_profile" \
  "$worktree" "$opencode_bin" || profile_rc=$?
capability_profile="$GLUERUN_RESOLVED_CAPABILITY_PROFILE"
profile_provider_args=()
if [[ "$GLUERUN_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  profile_provider_args=("${GLUERUN_RESOLVED_PROVIDER_ARGS[@]}")
fi
[[ "$profile_rc" -eq 0 ]] || exit "$profile_rc"
gluerun_runner_reject_strict_legacy_extra_args \
  opencode GLUERUN_OPENCODE_EXTRA_ARGS "${GLUERUN_OPENCODE_EXTRA_ARGS:-}" || exit $?
[[ -n "$opencode_bin" ]] || { echo "opencode CLI not found on PATH" >&2; exit 127; }
profile_native_args=()
if [[ "$GLUERUN_RESOLVED_CAPABILITY_STRICT" == "yes" ]]; then
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
  run_dir="$GLUERUN_STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir"
  if [[ -z "$output_last_message" ]]; then
    output_last_message="$run_dir/last-message.json"
  fi
fi

# --- Model selection ------------------------------------------------------------
# When GLUERUN_OPENCODE_MODEL is unset, OMIT -m entirely so OpenCode uses its own
# configured default model (spec 0.9.0). Model refs are `provider/model` strings.
opencode_model() {
  printf '%s\n' "${GLUERUN_OPENCODE_MODEL:-}"
}
oc_model="$(opencode_model)"

# --- Assemble the opencode invocation -------------------------------------------
# Prompt travels on STDIN (no positional message). --format json emits raw JSON
# events; there are no interactive approval prompts (permission config governs).
cmd=("$opencode_bin" run --format json)
if [[ ${#profile_native_args[@]} -gt 0 ]]; then
  cmd+=("${profile_native_args[@]}")
fi
if [[ "$GLUERUN_RESOLVED_PROVIDER_ARGS_COUNT" -gt 0 ]]; then
  cmd+=("${profile_provider_args[@]}")
fi
[[ -n "$oc_model" ]] && cmd+=(-m "$oc_model")

if [[ -n "${GLUERUN_OPENCODE_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  cmd+=(${GLUERUN_OPENCODE_EXTRA_ARGS})
fi

# --- Read-only snapshot (for restore-after) -------------------------------------
ro_before_untracked=""
ro_before_mod=""
if [[ "$readonly_run" == "yes" ]]; then
  ro_before_untracked="$(git -C "$worktree" ls-files --others --exclude-standard 2>/dev/null | sort || true)"
  ro_before_mod="$(git -C "$worktree" diff --name-only HEAD 2>/dev/null | sort || true)"
fi

envelope="$(mktemp "${TMPDIR:-/tmp}/gluerun-opencode-env.XXXXXX")"
envelope_err="$envelope.err"

run_opencode() {
  ( cd "$worktree" && "${cmd[@]}" <"$prompt_file" ) >"$envelope" 2>"$envelope_err"
}

exit_code=0
echo "opencode-run: level=$level model=${oc_model:-<default>} worktree=$worktree run_id=$run_id" >&2
oc_timeout="${GLUERUN_OPENCODE_TIMEOUT_SEC:-1200}"
if [[ "$oc_timeout" =~ ^[0-9]+$ && "$oc_timeout" -gt 0 ]]; then
  run_opencode & oc_pid=$!
  oc_deadline=$((SECONDS + oc_timeout)); oc_timed_out="no"
  while kill -0 "$oc_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$oc_deadline" ]]; then
      oc_timed_out="yes"
      gluerun_kill_tree "$oc_pid"   # SIGKILL opencode + every descendant
      wait "$oc_pid" 2>/dev/null || true
      exit_code=124
      break
    fi
    sleep 2
  done
  if [[ "$oc_timed_out" != "yes" ]]; then
    oc_ec=0; wait "$oc_pid" || oc_ec=$?; exit_code="$oc_ec"
  else
    echo "opencode-run: TIMED OUT after ${oc_timeout}s; killed run $run_id" >&2
  fi
else
  run_opencode || exit_code=$?
fi

cat "$envelope" >&2 || true
[[ -s "$envelope_err" ]] && cat "$envelope_err" >&2 || true
if [[ -n "$run_dir" ]]; then cp "$envelope" "$run_dir/opencode-envelope.json" 2>/dev/null || true; fi

# --- Session-meta: no resumable id in v1; record provider + empty sessionId ----
if [[ -n "$session_meta_path" ]]; then
  gluerun_session_meta_write_provider "$session_meta_path" "opencode" "" "$oc_model" \
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

if gluerun_runner_result_write opencode "$run_id" "$runner_role" "$capability_profile" \
  "$result_file" "$exit_code" "$envelope" "$envelope_err" "$output_last_message"; then
  runner_result_written="yes"
fi

exit "$exit_code"
