#!/usr/bin/env bash
# ctx-rehydrate-sources.sh — pure, read-only durable-rehydration-source resolver
# (stage S5-routing, node `rehydrate-path`, layer engine_runtime). Sourced exactly
# once by the context-evolution loader block in lib.sh (it matches the ctx-*.sh
# glob). This file DEFINES a new function only and is present-but-uncalled by every
# existing engine/CLI/driver path, so with it sourced the engine stays
# byte-identical to prior behavior.
#
#   gluerun_ctx_rehydrate_sources <run_dir> [extra-id=path ...]
#
# Prints, one per line, the class-tagged `<id>=<path>` specs for each durable
# rehydration source that EXISTS under <run_dir>, in the assembler's fixed
# source-class order, deterministically (independent of on-disk enumeration).
# Its stdout composes directly as arguments to the TASK-0051 assembler
# (gluerun_ctx_rehydrate_packet / gluerun_ctx_rehydrate_manifest): the emitted
# ids MUST match that assembler's source-class ids exactly.
#
# Single-sourced class -> run_dir file mapping (the canonical durable-artifact
# root is run_dir = dirname(meta), the same root engine/ctx-route-drive.sh derives
# and gluerun_ctx_artifact_scan_paths scans). This is a curated, class-tagged
# subset of that scan set: it deliberately EXCLUDES raw provider session logs
# (session-*.json) that must never be injected as durable context.
#
#   task-packet          packet.json
#   implementer-capsule  implementer-capsule.json
#   reviewer-capsule     reviewer-capsule.json
#   findings-ledger      findings-status.json
#   assumptions-ledger   assumptions-ledger.json
#   critique-record      plan-critique.json
#
# The repo-level `decision-record` lives OUTSIDE run_dir, so it is supplied by the
# caller as an `extra-id=path` spec rather than resolved here.
#
# Existing-files-only: a class is emitted only when its mapped file exists (`-f`),
# mirroring gluerun_ctx_artifact_scan_paths; a missing artifact contributes
# nothing. Caller-supplied `extra-id=path` specs are appended verbatim after the
# run_dir-resolved specs.
#
# Quarantine exclusion is NOT performed here: the assembler/manifest already
# compose gluerun_ctx_artifact_exclude, so a single quarantine authority is
# preserved; this resolver only enumerates candidates.
#
# Pure and READ-ONLY: it inspects paths but never writes, renames, or deletes;
# appends no events; and never exits non-zero on well-formed input (an absent or
# empty run_dir yields no specs, non-fatal). It confers NO independence: the
# `rehydrate` strategy remains tainted per gluerun_ctx_route_strategy_tainted.

# gluerun_ctx_rehydrate_sources <run_dir> [extra-id=path ...]
gluerun_ctx_rehydrate_sources() {
  local run_dir="${1-}"
  [[ $# -gt 0 ]] && shift

  # Fixed source-class order: <id> <run_dir-relative file>. Kept in the
  # assembler's documented rank order so the resolver's stdout composes directly
  # as assembler arguments.
  local map=(
    "task-packet=packet.json"
    "implementer-capsule=implementer-capsule.json"
    "reviewer-capsule=reviewer-capsule.json"
    "findings-ledger=findings-status.json"
    "assumptions-ledger=assumptions-ledger.json"
    "critique-record=plan-critique.json"
  )

  local entry id file path
  if [[ -n "$run_dir" ]]; then
    for entry in "${map[@]}"; do
      id="${entry%%=*}"
      file="${entry#*=}"
      path="$run_dir/$file"
      [[ -f "$path" ]] && printf '%s=%s\n' "$id" "$path"
    done
  fi

  # Caller-supplied extra specs appended verbatim after the run_dir-resolved set.
  local spec
  for spec in "$@"; do
    printf '%s\n' "$spec"
  done
}
