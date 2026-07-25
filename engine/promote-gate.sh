#!/usr/bin/env bash
set -euo pipefail

# Thin promoter resolver (0.5.0). The standalone `gluerun promote-gate`
# subcommand used to read GLUERUN_PROMOTER from the shell environment only —
# the CLI never sources lib.sh, where the repo config's `promoter` key is
# mapped into that variable — so a configured project promoter was invisible
# unless the operator exported the env var by hand (field audit: rediscovered
# on three separate days). This wrapper sources lib.sh (all three config
# layers), resolves the promoter with env-over-config precedence, and execs it.
# reconcile.sh's auto-promotion path also uses this file as its fallback.

# Capture the operator's explicit env BEFORE lib.sh: config env{} re-exports
# clobber pre-set environment at source time.
_cli_promoter="${GLUERUN_PROMOTER:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

promoter="${_cli_promoter:-${GLUERUN_PROMOTER:-$GLUERUN_ENGINE_HOME/gluerun-ext/promote-gate.sh}}"
# Bare-name resolution for env-provided values (lib.sh already resolved the
# config value the same way).
if [[ -n "$promoter" && "$promoter" != */* ]]; then
  promoter="$GLUERUN_ENGINE_HOME/gluerun-ext/$promoter.sh"
fi

if [[ ! -f "$promoter" ]]; then
  cat >&2 <<EOF
gluerun: no gate promoter at $promoter
  Set "promoter" in gluerun.config.json (a bare name resolves to
  <engine>/gluerun-ext/<name>.sh; a path is used as-is, repo-relative), or
  export GLUERUN_PROMOTER.
EOF
  exit 2
fi

exec "${GLUERUN_BASH_BIN:-bash}" "$promoter" "$@"
