#!/usr/bin/env bash
# ctx-rehydrate-authored-config.sh — pure, read-only config-gated entry point for
# the authored-knowledge manifest (stage S5-routing, node `rehydrate-path`, layer
# engine_runtime; singular-brain integration point 4). Sourced exactly once by the
# context-evolution loader block in lib.sh (it matches the ctx-*.sh glob). This
# file DEFINES new functions only and is present-but-uncalled by every existing
# engine/CLI/driver path, so with it sourced the engine stays byte-identical to
# prior behavior.
#
# This is the FOURTH slice of the explicitly-OPTIONAL authored-knowledge
# deliverable. TASK-0058 (select), TASK-0059 (eligible), and TASK-0060 (render /
# manifest — `singular_ctx_rehydrate_authored_render` /
# `singular_ctx_rehydrate_authored_manifest`) reduce and compose a FIXTURE authored
# manifest over a manifest PATH. This slice folds the SINGULAR_CTX_MANIFEST knob and
# the OPTIONAL `singular.config.json` `contextManifest` field into a single decision
# so the eventual driver wire-in becomes two one-line delegations rather than
# duplicating the gate across two scarce driver files. It is NOT part of the
# `rehydrate-path` node's requiredCompletion and does NOT gate the node.
# SINGULAR_CTX_MANIFEST (default 0) gates this feature; with it unset the entry
# point emits nothing. It takes NO dependency on any singular-brain runtime.
#
#   singular_ctx_rehydrate_authored_config_render   [trigger ...]
#   singular_ctx_rehydrate_authored_config_manifest [trigger ...]
#
# Both emit the authored packet section / manifest entries ONLY when
# SINGULAR_CTX_MANIFEST=1 AND singular.config.json declares a readable
# `contextManifest` path — by resolving that path and delegating to
# `singular_ctx_rehydrate_authored_render <resolved> [trigger ...]` /
# `singular_ctx_rehydrate_authored_manifest <resolved> [trigger ...]`; otherwise
# they emit nothing.
#
# `contextManifest` is an OPTIONAL ADDITIVE field read via `singular_json_field`
# over SINGULAR_JSON_CONFIG_FILE (engine/lib.sh); there is no config schema file, so
# no schema change is needed and the field's absence is the OFF default. A relative
# value resolves against the config file's own directory; an absolute value is used
# as-is.
#
# Pure, read-only, deterministic, fail-soft: any unmet precondition (flag off,
# field absent, config or manifest path missing/unreadable, malformed manifest)
# yields empty output; the functions write/rename/delete nothing, append no events,
# and never exit non-zero on well-formed input.

# Internal: apply the gate and echo the resolved, readable manifest path on
# success; emit nothing and return 1 when any precondition is unmet. Pure and
# read-only — it only reads the config file and stats the resolved path.
_singular_ctx_rehydrate_authored_config_path() {
  [[ "${SINGULAR_CTX_MANIFEST:-0}" == "1" ]] || return 1

  local cfg="${SINGULAR_JSON_CONFIG_FILE:-}"
  [[ -n "$cfg" && -f "$cfg" && -r "$cfg" ]] || return 1

  # OPTIONAL ADDITIVE field; its absence (singular_json_field exits non-zero) is the
  # OFF default. Errors are swallowed so a malformed/absent field is fail-soft.
  local rel
  rel="$(singular_json_field "$cfg" contextManifest 2>/dev/null)" || return 1
  [[ -n "$rel" ]] || return 1

  local resolved
  case "$rel" in
    /*) resolved="$rel" ;;
    *)  resolved="$(cd "$(dirname "$cfg")" 2>/dev/null && pwd)/$rel" ;;
  esac

  [[ -f "$resolved" && -r "$resolved" ]] || return 1
  printf '%s\n' "$resolved"
}

# singular_ctx_rehydrate_authored_config_render [trigger ...]
singular_ctx_rehydrate_authored_config_render() {
  local resolved
  resolved="$(_singular_ctx_rehydrate_authored_config_path)" || return 0
  singular_ctx_rehydrate_authored_render "$resolved" "$@"
}

# singular_ctx_rehydrate_authored_config_manifest [trigger ...]
singular_ctx_rehydrate_authored_config_manifest() {
  local resolved
  resolved="$(_singular_ctx_rehydrate_authored_config_path)" || return 0
  singular_ctx_rehydrate_authored_manifest "$resolved" "$@"
}
