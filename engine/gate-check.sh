#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

run_id="${1:-RUN-$(date -u +%Y%m%dT%H%M%SZ)}"
shift || true

task_id="${GLUERUN_GATE_TASK_ID:-TASK-0000}"
phase="${GLUERUN_GATE_PHASE:-other}"
workspace_kind="${GLUERUN_GATE_WORKSPACE_KIND:-worker}"
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --task-id) task_id="${2:-}"; shift 2 ;;
    --phase) phase="${2:-}"; shift 2 ;;
    --workspace-kind) workspace_kind="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [[ $# -eq 0 ]]; then
  set -- make check
fi

run_dir="$GLUERUN_STATE_DIR/runs/$run_id"
mkdir -p "$run_dir"
log="$run_dir/gate-check.log"
observation="$run_dir/gate-observation.json"
report="$run_dir/gate-report.json"
summary="$run_dir/gate-check.json" # compatibility mirror
command_text="$*"
head_sha="$(git -C "$PWD" rev-parse HEAD 2>/dev/null || printf '%040d' 0)"
started_ms="$(python3 -c 'import time; print(time.time_ns() // 1000000)')"
rm -f "$observation" "$report" "$summary"
source_before="$run_dir/gate-source-before.json"
source_after="$run_dir/gate-source-after.json"
status_before="$run_dir/gate-status-before.txt"
status_after="$run_dir/gate-status-after.txt"
integrity_status="verified"
changed_paths=()
if ! gluerun_tracked_source_snapshot "$PWD" "$source_before" >"$run_dir/gate-source-snapshot.err" 2>&1; then
  integrity_status="violation"
  changed_paths+=("source-integrity-snapshot-failed")
fi
git -C "$PWD" status --porcelain=v1 --untracked-files=all 2>/dev/null \
  | sed -E '\#^.. (\.gluerun-state|\.gluerun-cache|\.gluerun-evidence)(/|$)#d' \
  >"$status_before" || true

set +e
GLUERUN_GATE_REPORT_FILE="$observation" "$@" >"$log" 2>&1
exit_code=$?
set -e
finished_ms="$(python3 -c 'import time; print(time.time_ns() // 1000000)')"
if [[ "$integrity_status" == "verified" ]]; then
  if ! gluerun_tracked_source_snapshot "$PWD" "$source_after" >>"$run_dir/gate-source-snapshot.err" 2>&1; then
    integrity_status="violation"
    changed_paths+=("source-integrity-snapshot-failed")
  else
    mapfile -t metadata_changed_paths < <(
      gluerun_tracked_source_changes "$source_before" "$source_after"
    )
    git -C "$PWD" status --porcelain=v1 --untracked-files=all 2>/dev/null \
      | sed -E '\#^.. (\.gluerun-state|\.gluerun-cache|\.gluerun-evidence)(/|$)#d' \
      >"$status_after" || true
    mapfile -t final_changed_paths < <(
      python3 - "$status_before" "$status_after" <<'PY'
import sys

before = set(open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines())
after = set(open(sys.argv[2], encoding="utf-8", errors="replace").read().splitlines())
for line in sorted(before ^ after):
    path = line[3:].strip() if len(line) > 3 else ""
    if path:
        print(path)
PY
    )
    changed_paths+=("${metadata_changed_paths[@]}" "${final_changed_paths[@]}")
    if [[ "${#changed_paths[@]}" -gt 0 ]]; then
      integrity_status="violation"
    fi
  fi
fi

normalize_args=(
  --task-id "$task_id"
  --run-id "$run_id"
  --head-sha "$head_sha"
  --command "$command_text"
  --raw-exit-code "$exit_code"
  --log-ref "$log"
  --log-path "$log"
  --duration-ms "$((finished_ms - started_ms))"
  --phase "$phase"
  --workspace-kind "$workspace_kind"
  --integrity-status "$integrity_status"
  --output "$report"
)
for changed_path in "${changed_paths[@]}"; do
  normalize_args+=(--changed-path "$changed_path")
done
[[ -f "$observation" ]] && normalize_args+=(--observation "$observation")
[[ "${GLUERUN_CONFIG_SCHEMA_VERSION:-}" == "v2" ]] \
  && normalize_args+=(--require-observation)
[[ -n "${GLUERUN_GATE_BASELINE_FILE:-}" ]] \
  && normalize_args+=(--baseline "$GLUERUN_GATE_BASELINE_FILE")

outcome=""
normalize_rc=0
outcome="$(python3 "$SCRIPT_DIR/gate_report.py" "${normalize_args[@]}" \
  2>"$run_dir/gate-report.err")" || normalize_rc=$?
if [[ "$normalize_rc" -ne 0 || ! -f "$report" ]]; then
  # Invalid adapter/baseline data is infrastructure-inconclusive, never a
  # fabricated product failure.
  fallback_rc=0
  fallback_args=(
    create
    --output "$report"
    --task-id "$task_id"
    --run-id "$run_id"
    --head-sha "$head_sha"
    --command "$command_text"
    --exit-code "$exit_code"
    --log "$log"
    --duration-ms "$((finished_ms - started_ms))"
    --phase "$phase"
    --workspace-kind "$workspace_kind"
    --integrity-status "$integrity_status"
    --setup-error gate-report-normalization-failed
  )
  for changed_path in "${changed_paths[@]}"; do
    fallback_args+=(--changed-path "$changed_path")
  done
  "$SCRIPT_DIR/gate-report.py" "${fallback_args[@]}" || fallback_rc=$?
  outcome="inconclusive-infrastructure"
fi
cp "$report" "$summary"
outcome="$(gluerun_json_field "$report" outcome 2>/dev/null || echo inconclusive-infrastructure)"
resolved_expected="$(
  python3 - "$report" <<'PY' 2>/dev/null || echo 0
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
resolved = data.get("resolvedExpectedFailures")
print(len(resolved) if isinstance(resolved, list) else 0)
PY
)"
if [[ "$resolved_expected" =~ ^[1-9][0-9]*$ ]]; then
  echo "warning: $resolved_expected acknowledged gate baseline failure(s) are now resolved; refresh the baseline" >&2
  gluerun_append_event "gate.baseline_stale" \
    "resolved expected failures make the acknowledged baseline stale" \
    "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"resolvedExpectedFailures\":$resolved_expected,\"reportRef\":\"$report\"}" \
    || true
fi

case "$outcome" in
  passed|passed-with-acknowledged-baseline) result_code=0 ;;
  inconclusive-infrastructure) result_code=20 ;;
  *) result_code="$exit_code"; [[ "$result_code" -ne 0 ]] || result_code=1 ;;
esac

gluerun_append_event "gate_check.completed" "gate check completed" \
  "{\"runId\":\"$run_id\",\"taskId\":\"$task_id\",\"exitCode\":$exit_code,\"resultCode\":$result_code,\"outcome\":\"$outcome\",\"logRef\":\"$log\",\"reportRef\":\"$report\"}"
echo "gate check exit_code=$exit_code outcome=$outcome log=$log report=$report"
exit "$result_code"
