#!/usr/bin/env bash
set -euo pipefail

# openrouter-run.sh — OpenRouter as a first-class singular provider.
#
# OpenRouter is an API aggregator, not a CLI: it serves 400+ models from every
# vendor behind one endpoint and one key, and it ships no agent of its own. The
# engine's roles need an agent — one that reads the worktree, runs commands and
# edits files — so this adapter dispatches OpenRouter models through the OpenCode
# CLI, which is a first-class OpenRouter client (it bundles
# @openrouter/ai-sdk-provider and reads OPENROUTER_API_KEY). The whole run is
# engine/opencode-host.sh; this file is the identity.
#
# Why a separate provider row rather than "set SINGULAR_OPENCODE_MODEL to an
# openrouter/ ref": everything downstream is genuinely per-provider. Doctor
# checks OPENROUTER_API_KEY rather than OpenCode's own credentials, and verifies
# the configured model against OpenRouter's own catalog
# (https://openrouter.ai/api/v1/models) instead of a shape regex — a model id
# that OpenRouter does not serve fails preflight rather than a dispatch. The
# SINGULAR_OPENROUTER_* env family, the role-split routing, the provider named in
# every runner result, and the quota/overload evidence that arms the backoffs all
# become OpenRouter's own.
#
# Configuration:
#   SINGULAR_OPENROUTER_MODEL   REQUIRED, and must be an `openrouter/...` ref
#                               (e.g. openrouter/anthropic/claude-sonnet-4.5).
#                               The namespace is enforced: an unset or foreign
#                               ref would silently answer from OpenCode's own
#                               default model under OpenRouter's name.
#   OPENROUTER_API_KEY          the OpenRouter key (https://openrouter.ai/keys),
#                               or authenticate OpenCode with OpenRouter once.
#   SINGULAR_OPENROUTER_{TIMEOUT_SEC,EXTRA_ARGS,READONLY_AGENT} as for opencode.
#
# Privilege levels, the OpenCode mapping:
#   readonly  -> `--agent plan` (OpenCode's built-in read-only agent) plus the
#                post-run restore guard as the backstop.
#   l2        -> unconstrained write; file scope enforced downstream.
#   l0|l1     -> writes limited to --allow-prefix paths, verified by
#                scope-check.sh after the run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Identity, then the shared OpenCode host owns the run.
provider="openrouter"
label="openrouter-run"
# shellcheck source=opencode-host.sh
source "$SCRIPT_DIR/opencode-host.sh"
