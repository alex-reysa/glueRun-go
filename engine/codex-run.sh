#!/usr/bin/env bash
set -euo pipefail

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
# Session affinity (T-E5): both flags are ADDITIVE. With NEITHER passed, the
# invocation path below stays byte-identical to HEAD (no tee, no resume).
session_meta_path=""
resume_session_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--worktree)
      worktree="$2"
      shift 2
      ;;
    --prompt-file)
      prompt_file="$2"
      shift 2
      ;;
    --level)
      level="$2"
      shift 2
      ;;
    --run-id)
      run_id="$2"
      shift 2
      ;;
    --output-schema)
      output_schema="$2"
      capture_packet="yes"
      shift 2
      ;;
    --output-last-message)
      output_last_message="$2"
      capture_packet="yes"
      shift 2
      ;;
    --no-output-capture)
      capture_packet="no"
      shift
      ;;
    --allow-prefix)
      allow_prefixes+=("$2")
      shift 2
      ;;
    --session-meta)
      session_meta_path="$2"
      shift 2
      ;;
    --resume-session)
      resume_session_id="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$worktree" ]]; then
  echo "usage: $0 --worktree PATH [--level l1|l2|readonly] [--prompt-file FILE]" >&2
  exit 2
fi

gluerun_require_target_branch

gluerun_validate_codex_sandbox() {
  local value="$1" label="$2"
  case "$value" in
    read-only|workspace-write|danger-full-access) return 0 ;;
    *)
      echo "invalid $label: $value (expected read-only, workspace-write, or danger-full-access)" >&2
      return 2
      ;;
  esac
}

gluerun_codex_reasoning_effort() {
  local level="$1" prompt_file="$2" prompt_name
  case "$level" in
    l0|l1)
      printf '%s\n' "${GLUERUN_CODEX_L1_REASONING_EFFORT:-high}"
      ;;
    l2)
      printf '%s\n' "${GLUERUN_CODEX_L2_REASONING_EFFORT:-medium}"
      ;;
    readonly|read-only)
      prompt_name="$(basename "$prompt_file")"
      case "$prompt_name" in
        planner-prompt.md) printf '%s\n' "${GLUERUN_CODEX_PLANNER_REASONING_EFFORT:-high}" ;;
        auditor.md) printf '%s\n' "${GLUERUN_CODEX_AUDITOR_REASONING_EFFORT:-high}" ;;
        auditor-*.md) printf '%s\n' "${GLUERUN_CODEX_AUDITOR_REASONING_EFFORT:-high}" ;;
        reviewer.md|reviewer-*.md) printf '%s\n' "${GLUERUN_CODEX_AUDITOR_REASONING_EFFORT:-high}" ;;
        decider.md|decider-prompt-*.md) printf '%s\n' "${GLUERUN_CODEX_DECIDER_REASONING_EFFORT:-high}" ;;
        *critic*.md) printf '%s\n' "${GLUERUN_CODEX_CRITIC_REASONING_EFFORT:-high}" ;;
        *) printf '%s\n' "${GLUERUN_CODEX_READONLY_REASONING_EFFORT:-high}" ;;
      esac
      ;;
  esac
}

case "$level" in
  l0|l1)
    sandbox="workspace-write"
    if [[ ${#allow_prefixes[@]} -eq 0 ]]; then
      allow_prefixes=("docs/orchestration/")
    fi
    ;;
  l2)
    sandbox="${GLUERUN_L2_SANDBOX:-workspace-write}"
    gluerun_validate_codex_sandbox "$sandbox" "GLUERUN_L2_SANDBOX"
    ;;
  readonly|read-only)
    sandbox="read-only"
    ;;
  *)
    echo "unknown level: $level" >&2
    exit 2
    ;;
esac

if [[ -z "$run_id" ]]; then
  run_id="RUN-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi

if [[ "$capture_packet" == "auto" && "$level" == "l2" ]]; then
  capture_packet="yes"
elif [[ "$capture_packet" == "auto" ]]; then
  capture_packet="no"
fi

if [[ "$capture_packet" == "yes" ]]; then
  run_dir="$GLUERUN_STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir"
  if [[ -z "$output_last_message" ]]; then
    output_last_message="$run_dir/last-message.json"
  fi
fi

codex_model="${GLUERUN_CODEX_MODEL:-gpt-5.5}"
codex_service_tier="${GLUERUN_CODEX_SERVICE_TIER:-}"
codex_reasoning_effort="$(gluerun_codex_reasoning_effort "$level" "$prompt_file")"

# ---- Session affinity: resume-refusal gate (exit 86) ------------------------
# Model selection lives in the runner. If the host asks us to resume a session
# whose recorded model/effort no longer match what THIS runner derives now,
# refuse (exit 86) so the host goes fresh instead of feeding a model-shifted
# session. This keeps model knowledge entirely on the runner side.
if [[ -n "$resume_session_id" && -n "$session_meta_path" && -f "$session_meta_path" ]]; then
  if ! python3 - "$session_meta_path" "$codex_model" "$codex_reasoning_effort" <<'PY'
import json, sys
path, model_now, effort_now = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, "r", encoding="utf-8") as f:
        m = json.load(f)
except Exception:
    sys.exit(0)  # unparseable meta -> let the host's own gates decide; don't refuse here
prev_model = str(m.get("model", "") or "")
prev_effort = str(m.get("effort", "") or "")
if prev_model and prev_model != model_now:
    sys.exit(1)
if prev_effort and prev_effort != effort_now:
    sys.exit(1)
sys.exit(0)
PY
  then
    echo "codex-run: resume-refused (model/effort changed vs $session_meta_path)" >&2
    exit 86
  fi
fi

if [[ "$level" == "l2" ]]; then
  export GOCACHE="${GLUERUN_GO_BUILD_CACHE:-/private/tmp/gluerun-go-build-cache}"
  mkdir -p "$GOCACHE"
fi

if [[ -n "$resume_session_id" ]]; then
  # Resume path. `codex exec resume` does NOT accept --sandbox/-C/--json as
  # subcommand flags; those live at the GLOBAL codex level (before `exec`), while
  # --json/-o belong to the resume subcommand. Verified form (codex exec resume
  # --help): codex -a never -m M --sandbox S -C WT [-c ...] exec resume <id> --json [-o out] -
  cmd=(codex -a never -m "$codex_model" --sandbox "$sandbox" -C "$worktree")
  if [[ -n "$codex_reasoning_effort" ]]; then
    cmd+=(-c "model_reasoning_effort=\"$codex_reasoning_effort\"")
  fi
  if [[ -n "$codex_service_tier" ]]; then
    cmd+=(-c "service_tier=\"$codex_service_tier\"")
  fi
  cmd+=(exec resume "$resume_session_id" --json)
  if [[ "$capture_packet" == "yes" ]]; then
    if [[ -n "$output_schema" ]]; then
      cmd+=(--output-schema "$output_schema")
    fi
    cmd+=(-o "$output_last_message")
  fi
  cmd+=(-)
else
  cmd=(codex -a never exec -m "$codex_model" --sandbox "$sandbox" -C "$worktree" --json)
  if [[ -n "$codex_reasoning_effort" ]]; then
    cmd+=(-c "model_reasoning_effort=\"$codex_reasoning_effort\"")
  fi
  if [[ -n "$codex_service_tier" ]]; then
    cmd+=(-c "service_tier=\"$codex_service_tier\"")
  fi
  if [[ "$capture_packet" == "yes" ]]; then
    # --output-schema uses OpenAI strict structured-output validation, which is far
    # stricter than JSON Schema (no const/format/pattern, no additionalProperties:true,
    # all properties required). Our packet/verdict schemas are intentionally richer,
    # so we only forward --output-schema when a caller explicitly opts in with a
    # strict-compatible schema; otherwise we just capture the final message and
    # validate it ourselves.
    if [[ -n "$output_schema" ]]; then
      cmd+=(--output-schema "$output_schema")
    fi
    cmd+=(-o "$output_last_message")
  fi
  cmd+=(-)
fi

# ---- Run --------------------------------------------------------------------
# When --session-meta is requested we tee codex's JSONL stdout to a temp file so
# we can scan it for the session id; exit propagation uses PIPESTATUS[0] (works
# under bash 3.2). When --session-meta is ABSENT the invocation is byte-identical
# to HEAD (no tee, no pipe).
exit_code=0
jsonl_tmp=""
if [[ -n "$session_meta_path" ]]; then
  jsonl_tmp="$(mktemp "${TMPDIR:-/tmp}/gluerun-codex-jsonl.XXXXXX")"
  if [[ -n "$prompt_file" ]]; then
    "${cmd[@]}" <"$prompt_file" | tee "$jsonl_tmp"
    exit_code=${PIPESTATUS[0]}
  else
    "${cmd[@]}" | tee "$jsonl_tmp"
    exit_code=${PIPESTATUS[0]}
  fi
else
  if [[ -n "$prompt_file" ]]; then
    "${cmd[@]}" <"$prompt_file" || exit_code=$?
  else
    "${cmd[@]}" || exit_code=$?
  fi
fi

# ---- Session-meta: scan the JSONL for a session id, write the meta file ------
if [[ -n "$session_meta_path" ]]; then
  session_id=""
  if [[ -n "$jsonl_tmp" && -f "$jsonl_tmp" ]]; then
    # Defensive scan: codex event shape drifts. The current CLI emits the
    # resumable id as `thread_id` on a `{"type":"thread.started",...}` event;
    # older/other shapes used session_id/sessionId (top level, .msg, or .session).
    # `codex exec resume` accepts that id (a UUID) directly. A miss yields an
    # empty id, and the host falls back to a fresh run.
    session_id="$(python3 - "$jsonl_tmp" <<'PY' || true
import json, sys
found = ""
def pick(d):
    if not isinstance(d, dict):
        return ""
    for k in ("session_id", "sessionId", "thread_id"):
        v = d.get(k)
        if isinstance(v, str) and v:
            return v
    for sub in ("msg", "session"):
        s = d.get(sub)
        if isinstance(s, dict):
            for k in ("session_id", "sessionId", "thread_id", "id"):
                v = s.get(k)
                if isinstance(v, str) and v:
                    return v
    return ""
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            sid = pick(obj)
            if sid:
                found = sid
                break
except Exception:
    pass
sys.stdout.write(found)
PY
)"
  fi
  gluerun_codex_session_meta_write "$session_meta_path" "$session_id" "$codex_model" \
    "$codex_reasoning_effort" "$worktree" "$exit_code" || true
fi
[[ -n "$jsonl_tmp" ]] && rm -f "$jsonl_tmp" 2>/dev/null || true

# ---- Resume-failure signalling (exit 86) ------------------------------------
# A resumed run that exits nonzero with empty output is indistinguishable, to the
# host, from a real model failure unless we flag it. Surface 86 so the host falls
# back to fresh within the same attempt rather than burning a retry.
if [[ -n "$resume_session_id" && "$exit_code" -ne 0 ]]; then
  out_empty="yes"
  if [[ -n "$output_last_message" && -s "$output_last_message" ]]; then out_empty="no"; fi
  if [[ "$out_empty" == "yes" ]]; then
    echo "codex-run: resume produced no usable output (rc=$exit_code); signalling resume-failure" >&2
    exit 86
  fi
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

exit "$exit_code"
