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

# Identity, then the shared OpenCode host owns the run.
provider="opencode"
label="opencode-run"
# shellcheck source=opencode-host.sh
source "$SCRIPT_DIR/opencode-host.sh"
