#!/usr/bin/env bash
# ctx-rehydrate-event.sh — pure, read-only strategy-event payload builder (stage
# S5-routing, node `rehydrate-path`, layer engine_runtime). Sourced exactly once
# by the context-evolution loader block in lib.sh (it matches the ctx-*.sh glob).
# This file DEFINES a new function only and is present-but-uncalled by every
# existing engine/CLI/driver path, so with it sourced the engine stays
# byte-identical to prior behavior.
#
#   gluerun_ctx_rehydrate_event_data \
#     <role> <task-id> <run-id> <attempt> <reason> <run_dir> [extra-id=path ...]
#
# Prints a single compact JSON object on stdout, suitable as the third (`data`)
# argument to `gluerun_append_event "context.strategy_selected"`. It extends the
# existing resume/fresh strategy payload shape ADDITIVELY:
#
#   {"taskId":…,"runId":…,"role":…,"attempt":<n>,"strategy":"rehydrate",
#    "reason":"<reason>","manifest":<manifest-json>}
#
# with `attempt` numeric, the other scalars strings, and `manifest` a NESTED JSON
# object (not a stringified blob) so `gluerun_append_event`'s json.loads stores it
# as structured data rather than a {"raw":…} fallback.
#
# `manifest` is the deterministic output of gluerun_ctx_rehydrate_manifest applied
# to gluerun_ctx_rehydrate_sources <run_dir> [extra…] — i.e.
#   {"schema":"gluerun.orchestration.ctx-rehydrate-manifest.v0",
#    "sources":[{"id","sha256"}…]}
# recording exactly which surviving durable artifacts, at which content hashes,
# the run rehydrates from. It records the MANIFEST (ids + hashes) only, never the
# packet body, so durable artifact bytes are not duplicated into the event stream.
#
# Quarantine-aware transitively: quarantined artifacts are absent from
# manifest.sources because the assembler already composes
# gluerun_ctx_artifact_exclude. Deterministic: identical run_dir bytes yield
# byte-identical event data. Robust to an empty source set: manifest.sources is []
# and the object is still well-formed valid JSON.
#
# Pure and READ-ONLY: it reads artifact bytes (transitively, to hash them) but
# never writes, renames, or deletes anything, and appends NO events itself (it
# PRODUCES the data string; the later l1-drive.sh wire-in calls
# gluerun_append_event). It confers NO independence: `rehydrate` remains tainted
# per gluerun_ctx_route_strategy_tainted. The routing wire-in that records this
# payload at the context.strategy_selected site, and the l1-drive.sh packet
# injection hook, are SEPARATE later slices and are OUT OF SCOPE here.

# gluerun_ctx_rehydrate_event_data <role> <task-id> <run-id> <attempt> <reason> <run_dir> [extra-id=path ...]
gluerun_ctx_rehydrate_event_data() {
  local role="${1-}" task_id="${2-}" run_id="${3-}" attempt="${4-}" reason="${5-}" run_dir="${6-}"
  [[ $# -ge 6 ]] && shift 6 || shift $#

  # Resolve the surviving durable sources for this run (plus caller extras), then
  # assemble the quarantine-aware manifest over exactly those specs. Both helpers
  # are pure and read-only; the manifest is the single content-hash authority.
  local -a source_specs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && source_specs+=("$line")
  done < <(gluerun_ctx_rehydrate_sources "$run_dir" "$@")

  local manifest
  if [[ ${#source_specs[@]} -gt 0 ]]; then
    manifest="$(gluerun_ctx_rehydrate_manifest "${source_specs[@]}")"
  else
    # Empty source set -> the manifest is still well-formed with sources: [].
    manifest="$(gluerun_ctx_rehydrate_manifest)"
  fi

  # Embed the metadata scalars and the NESTED manifest object into a single
  # compact JSON object. Pure: reads its argv, writes only stdout.
  python3 - "$role" "$task_id" "$run_id" "$attempt" "$reason" "$manifest" <<'PY'
import json
import sys

role, task_id, run_id, attempt_raw, reason, manifest_raw = sys.argv[1:7]

# `attempt` is numeric in the additive payload shape; stay non-fatal if a caller
# ever passes a non-integer by keeping the raw value rather than raising.
try:
    attempt = int(attempt_raw)
except ValueError:
    attempt = attempt_raw

try:
    manifest = json.loads(manifest_raw)
except json.JSONDecodeError:
    manifest = {"raw": manifest_raw}

obj = {
    "taskId": task_id,
    "runId": run_id,
    "role": role,
    "attempt": attempt,
    "strategy": "rehydrate",
    "reason": reason,
    "manifest": manifest,
}
# sort_keys keeps output byte-identical across runs for identical inputs.
sys.stdout.write(json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
sys.stdout.write("\n")
PY
}
