#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 path/to/state-packet.json" >&2
  exit 2
fi

packet="$1"
if [[ ! -f "$packet" ]]; then
  echo "packet not found: $packet" >&2
  exit 2
fi

singular_validate_packet_basic "$packet" >/dev/null

task_id="$(singular_json_field "$packet" taskId)"
run_id="$(singular_json_field "$packet" runId)"
branch="$(singular_json_field "$packet" branch)"
head_sha="$(singular_json_field "$packet" headSha)"
workspace="$(singular_json_field "$packet" workspace)"
task_file="$SINGULAR_TASKS_DIR/$task_id.md"
run_dir="$SINGULAR_RUNS_DIR/$run_id"

if [[ ! -f "$task_file" ]]; then
  echo "task file not found: $task_file" >&2
  exit 2
fi

guard_log="$run_dir/import-module-packet-guard.log"
mkdir -p "$run_dir"
if ! singular_packet_module_guard "$packet" "$task_file" "$workspace" "$run_dir" >"$guard_log" 2>&1; then
  cat "$guard_log" >&2
  singular_append_event "packet.import_rejected" "import rejected: module packet guard" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"reason\":\"module-packet-guard\"}"
  exit 2
fi

if ! git -C "$SINGULAR_ROOT" rev-parse --verify --quiet "$branch" >/dev/null; then
  echo "packet branch not found: $branch" >&2
  exit 2
fi

actual_head="$(git -C "$SINGULAR_ROOT" rev-parse --short "$branch")"
if [[ "$actual_head" != "${head_sha:0:${#actual_head}}" && "$head_sha" != "$actual_head" ]]; then
  echo "packet headSha $head_sha does not match branch head $actual_head" >&2
  exit 2
fi

# Acceptance gate: no packet is imported without an accepted auditor verdict
# (operating model section 12). The verdict is the run's durable audit record.
# Set SINGULAR_REQUIRE_AUDIT=0 only for explicit, documented bootstrap exceptions.
require_audit="${SINGULAR_REQUIRE_AUDIT:-1}"
audit_record="$(singular_audit_record_path "$run_id")"
verdict="n/a"
acceptance_mode="audit-disabled"
if [[ "$require_audit" == "1" ]]; then
  if [[ ! -f "$audit_record" ]]; then
    if singular_packet_has_accept_waiver "$packet"; then
      acceptance_mode="accepted-waiver"
    else
      echo "no auditor verdict for run $run_id (expected $audit_record); refusing import" >&2
      singular_append_event "packet.import_rejected" "import rejected: missing auditor verdict" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"reason\":\"missing-audit\"}"
      exit 2
    fi
  else
    verdict="$(singular_json_field "$audit_record" verdict 2>/dev/null || echo unknown)"
    acceptance_mode="$(singular_packet_acceptance_mode "$packet" "$audit_record" 2>/dev/null || true)"
    if [[ -z "$acceptance_mode" ]]; then
      echo "auditor verdict for $run_id is '$verdict' (not accepted, no recorded accept-waiver); refusing import" >&2
      singular_append_event "packet.import_rejected" "import rejected: auditor not accepted" \
        "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"verdict\":\"$verdict\"}"
      exit 2
    fi
  fi
fi

dest_dir="$SINGULAR_ORCH_DIR/packets/imported/$task_id"
dest="$dest_dir/$run_id.json"
mkdir -p "$dest_dir"

# Idempotent: re-importing the same packet (e.g. after a crash between copy and
# inbox cleanup) is a success, so the caller can clear it from the inbox queue.
if [[ -e "$dest" ]]; then
  if cmp -s "$packet" "$dest"; then
    echo "already imported (idempotent): $dest"
    exit 0
  fi
  echo "import destination already exists with different content: $dest" >&2
  exit 2
fi

# Atomic publish: copy to a temp name in the destination dir, then rename.
cp "$packet" "$dest.tmp.$$"
mv "$dest.tmp.$$" "$dest"
if [[ -f "$audit_record" ]]; then
  cp "$audit_record" "$dest_dir/$run_id.audit.json.tmp.$$"
  mv "$dest_dir/$run_id.audit.json.tmp.$$" "$dest_dir/$run_id.audit.json"
fi
singular_append_event "packet.imported" "state packet imported" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"branch\":\"$branch\",\"verdict\":\"$verdict\",\"acceptanceMode\":\"$acceptance_mode\"}"
echo "imported $packet -> $dest (auditor verdict: $verdict; acceptance: $acceptance_mode)"
