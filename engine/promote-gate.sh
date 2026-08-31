#!/usr/bin/env bash
set -euo pipefail

# Thin promoter resolver (0.5.0). The standalone `singular promote-gate`
# subcommand used to read SINGULAR_PROMOTER from the shell environment only —
# the CLI never sources lib.sh, where the repo config's `promoter` key is
# mapped into that variable — so a configured project promoter was invisible
# unless the operator exported the env var by hand (field audit: rediscovered
# on three separate days). This wrapper sources lib.sh (all three config
# layers), resolves the promoter with env-over-config precedence, and execs it.
# reconcile.sh's auto-promotion path also uses this file as its fallback.

# Capture the operator's explicit env BEFORE lib.sh: config env{} re-exports
# clobber pre-set environment at source time.
_cli_promoter="${SINGULAR_PROMOTER:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

promoter="${_cli_promoter:-${SINGULAR_PROMOTER:-$SINGULAR_ENGINE_HOME/singular-ext/promote-gate.sh}}"
# Bare-name resolution for env-provided values (lib.sh already resolved the
# config value the same way).
if [[ -n "$promoter" && "$promoter" != */* ]]; then
  promoter="$SINGULAR_ENGINE_HOME/singular-ext/$promoter.sh"
fi

if [[ ! -f "$promoter" ]]; then
  cat >&2 <<EOF
singular: no gate promoter at $promoter
  Set "promoter" in singular.config.json (a bare name resolves to
  <engine>/singular-ext/<name>.sh; a path is used as-is, repo-relative), or
  export SINGULAR_PROMOTER.
EOF
  exit 2
fi

_registers_only="no"
for _arg in "$@"; do
  [[ "$_arg" == "--registers" ]] && _registers_only="yes"
done
if [[ "$_registers_only" != "yes" ]]; then
  singular_campaign_verify_or_refuse promote-gate entry || exit 2
fi

exec "${SINGULAR_BASH_BIN:-bash}" "$promoter" "$@"
