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
  # SUBGRAPH branch (node subgraph-rehydrate; behind GLUERUN_CTX_SUBGRAPH_REHYDRATE
  # and only on the treatment arm with a present non-empty corpus). The shared
  # selector yields the subgraph manifest keyed on the SAME task_id / arm-mode /
  # node the packet-injection site (l1-drive.sh) keys on, so the recorded manifest
  # documents exactly the injected sources (same-sources invariant). With the knob
  # off / control arm / absent corpus the selector returns non-zero/empty and the
  # flat manifest below is recorded unchanged (byte-identical to today).
  local manifest=""
  local subgraph_manifest
  if subgraph_manifest="$(gluerun_ctx_route_subgraph_render "$task_id" manifest 2>/dev/null)" \
     && [[ -n "$subgraph_manifest" ]]; then
    manifest="$subgraph_manifest"
  else
    local -a source_specs=()
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] && source_specs+=("$line")
    done < <(gluerun_ctx_rehydrate_sources "$run_dir" "$@")

    if [[ ${#source_specs[@]} -gt 0 ]]; then
      manifest="$(gluerun_ctx_rehydrate_manifest "${source_specs[@]}")"
    else
      # Empty source set -> the manifest is still well-formed with sources: [].
      manifest="$(gluerun_ctx_rehydrate_manifest)"
    fi
  fi

  # OPTIONAL authored-knowledge counterpart (node rehydrate-path; NOT part of
  # requiredCompletion, does NOT gate the node). ALSO record the config-gated
  # authored manifest entries alongside the durable sources, using the SAME
  # trigger set TASK-0062 injects with so the recorded authored entries match the
  # injected authored section (consistency invariant). The set comes from the pure
  # builder gluerun_ctx_rehydrate_authored_triggers (TASK-0064): the run's
  # deterministic, de-duplicated `load-when` tokens (role `implementer`, step
  # `implement`, task id) rather than the bare literal `implement`, so authored
  # entries scoped to a role or task — not only the literal step — become
  # eligible. The enriched set is a strict superset of {implement}, so
  # implement-scoped entries still match (backward compatible), and the injection
  # site (engine/l1-drive.sh) passes the IDENTICAL set. This is a minimal
  # delegation into the integrated config gate (TASK-0058–0061): no
  # config/selection/render logic is inlined here. The gate internally checks
  # GLUERUN_CTX_MANIFEST (default 0) and the OPTIONAL gluerun.config.json
  # `contextManifest` field, so with either OFF it returns empty and nothing is
  # merged — OFF-parity keeps the event data byte-identical to the durable-only
  # payload. Non-fatal: on any error nothing is merged.
  #
  # NODE dimension (TASK-0066 -> TASK-0067): resolve the run's executable DAG node
  # via the pure read-only resolver gluerun_ctx_rehydrate_authored_node from this
  # site's own "$task_id" parameter (no signature change) and thread it into the
  # builder's position-3 [node] slot so node-scoped `load-when` entries become
  # eligible. Empty (fail-safe) on an absent/ambiguous association -> the builder
  # skips it and the set stays byte-identical to the pre-node-dimension behavior.
  # The injection site (engine/l1-drive.sh) resolves from the SAME task_id via the
  # SAME deterministic resolver, so both derive the identical token and identical
  # trigger set, preserving the injected<->recorded consistency invariant.
  local node
  node="$(gluerun_ctx_rehydrate_authored_node "$task_id" 2>/dev/null)" || node=""
  local -a authored_triggers=()
  local trigger
  while IFS= read -r trigger; do
    [[ -n "$trigger" ]] && authored_triggers+=("$trigger")
  done < <(gluerun_ctx_rehydrate_authored_triggers implementer implement "$node" "$task_id" 2>/dev/null)
  local authored
  authored="$(gluerun_ctx_rehydrate_authored_config_manifest ${authored_triggers[@]+"${authored_triggers[@]}"} 2>/dev/null)" || authored=""

  # Embed the metadata scalars and the NESTED manifest object into a single
  # compact JSON object. Pure: reads its argv, writes only stdout.
  python3 - "$role" "$task_id" "$run_id" "$attempt" "$reason" "$manifest" "$authored" <<'PY'
import json
import sys

role, task_id, run_id, attempt_raw, reason, manifest_raw, authored_raw = sys.argv[1:8]

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

# Merge the config-gated authored-knowledge manifest under a DISTINGUISHABLE
# `authored` key, recorded apart from the durable host-verified `sources` and
# never as authoritative. The gate returns empty when OFF/unconfigured, so the
# key is added ONLY when there is a well-formed authored manifest to record —
# preserving OFF-parity (byte-identical to the durable-only payload). A malformed
# blob is skipped (fail-soft) rather than recorded as a {"raw":…} fallback.
if authored_raw.strip() and isinstance(manifest, dict):
    try:
        authored = json.loads(authored_raw)
    except json.JSONDecodeError:
        authored = None
    if authored is not None:
        manifest["authored"] = authored

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
