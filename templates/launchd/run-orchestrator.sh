#!/usr/bin/env bash
set -euo pipefail

# launchd entry point for the glueRun-go bootstrap orchestrator.
#
# launchd jobs run with a minimal environment: no user PATH, possibly no HOME.
# This wrapper reconstructs enough environment for git, go, and the Codex CLI to
# run, confirms the Codex (ChatGPT) credential is readable, then invokes the
# reconciler. The mode is the first argument (default: --actuate).
#
# It deliberately resolves the repo root from its own location so the same file
# works regardless of where it is installed from.

mode="${1:-${GLUERUN_LAUNCHD_MODE:---watchdog}}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

# HOME is required for git config and for Codex to find ~/.codex/auth.json.
export HOME="${HOME:-$(/usr/bin/id -P "$(/usr/bin/id -un)" 2>/dev/null | cut -d: -f9)}"
export HOME="${HOME:-/Users/$(/usr/bin/id -un)}"
export CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

# Load local operational configuration, including proof database credentials.
# Keep it local to .gluerun-state; it is intentionally not committed control state.
export GLUERUN_ENV_FILE="${GLUERUN_ENV_FILE:-$repo_root/.gluerun-state/.env}"
if [[ -f "$GLUERUN_ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$GLUERUN_ENV_FILE"
  set +a
fi

# Resolve a working codex binary. GLUERUN_CODEX_BIN is canonical; CODEX_BIN is
# retained as a deprecated launchd-only fallback. The selected path is exported
# so doctor and codex-run execute exactly what this preflight checks.
codex_bin="${GLUERUN_CODEX_BIN:-${CODEX_BIN:-}}"
if [[ -z "$codex_bin" ]]; then
  for cand in \
    "/Applications/Codex.app/Contents/Resources/codex" \
    "$HOME/.local/bin/codex"; do
    if [[ -x "$cand" ]]; then codex_bin="$cand"; break; fi
  done
fi

# Standard tool locations; executable pinning deliberately does not prepend a
# provider or shell directory to PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [[ -z "$codex_bin" ]]; then
  codex_bin="$(command -v codex 2>/dev/null || true)"
fi
if [[ -n "$codex_bin" ]]; then
  export GLUERUN_CODEX_BIN="$codex_bin"
fi

export GLUERUN_TARGET_BRANCH="${GLUERUN_TARGET_BRANCH:-codex/gluerun-bootstrap-target}"
# Full autonomy for unattended runs.
export GLUERUN_AUTO_INTEGRATE="${GLUERUN_AUTO_INTEGRATE:-1}"
export GLUERUN_PUSH="${GLUERUN_PUSH:-1}"
export GLUERUN_GENERATE="${GLUERUN_GENERATE:-1}"
export GLUERUN_AUTO_PROMOTE_GATES="${GLUERUN_AUTO_PROMOTE_GATES:-1}"
export GLUERUN_L2_SANDBOX="${GLUERUN_L2_SANDBOX:-danger-full-access}"
export GLUERUN_ENABLE_L1_PARALLEL="${GLUERUN_ENABLE_L1_PARALLEL:-1}"
export GLUERUN_MAX_L1_CONCURRENT="${GLUERUN_MAX_L1_CONCURRENT:-3}"
export GLUERUN_L1_TASKS_PER_NODE="${GLUERUN_L1_TASKS_PER_NODE:-1}"
export GLUERUN_L2_SLICE_BUDGET="${GLUERUN_L2_SLICE_BUDGET:-1}"
export GLUERUN_L2_SLICE_BUDGET_MAX="${GLUERUN_L2_SLICE_BUDGET_MAX:-3}"
export GLUERUN_MAX_CONCURRENT="${GLUERUN_MAX_CONCURRENT:-5}"
export GLUERUN_MAX_DISPATCH="${GLUERUN_MAX_DISPATCH:-5}"
export GLUERUN_MAX_HOURS="${GLUERUN_MAX_HOURS:-12}"
# Default 1 = fire-and-forget dispatch (reconcile returns in seconds; the
# reaper attributes worker outcomes on later cycles). Set 0 for legacy batch wait.
export GLUERUN_DETACHED_DISPATCH="${GLUERUN_DETACHED_DISPATCH:-1}"

if [[ "$mode" == "--print-env" ]]; then
  echo "GLUERUN_ENV_FILE=$GLUERUN_ENV_FILE"
  echo "GLUERUN_STORAGE_PROOF_DATABASE_URL=${GLUERUN_STORAGE_PROOF_DATABASE_URL:+SET}"
  echo "GLUERUN_AUTO_PROMOTE_GATES=$GLUERUN_AUTO_PROMOTE_GATES"
  echo "GLUERUN_L2_SANDBOX=$GLUERUN_L2_SANDBOX"
  echo "GLUERUN_ENABLE_L1_PARALLEL=$GLUERUN_ENABLE_L1_PARALLEL"
  echo "GLUERUN_MAX_L1_CONCURRENT=$GLUERUN_MAX_L1_CONCURRENT"
  echo "GLUERUN_L1_TASKS_PER_NODE=$GLUERUN_L1_TASKS_PER_NODE"
  echo "GLUERUN_L2_SLICE_BUDGET=$GLUERUN_L2_SLICE_BUDGET"
  echo "GLUERUN_L2_SLICE_BUDGET_MAX=$GLUERUN_L2_SLICE_BUDGET_MAX"
  echo "GLUERUN_MAX_CONCURRENT=$GLUERUN_MAX_CONCURRENT"
  echo "GLUERUN_MAX_DISPATCH=$GLUERUN_MAX_DISPATCH"
  echo "GLUERUN_MAX_HOURS=$GLUERUN_MAX_HOURS"
  echo "GLUERUN_DETACHED_DISPATCH=$GLUERUN_DETACHED_DISPATCH"
  echo "GLUERUN_CODEX_BIN=${GLUERUN_CODEX_BIN:-}"
  echo "GLUERUN_BASH_BIN=${GLUERUN_BASH_BIN:-}"
  exit 0
fi

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

fail=0
if ! command -v git >/dev/null 2>&1; then log "ERROR: git not found on PATH ($PATH)"; fail=1; fi
if ! command -v go  >/dev/null 2>&1; then log "ERROR: go not found on PATH ($PATH)"; fail=1; fi

# The reconciler uses mapfile (bash >= 4). Prefer the bootstrap-only explicit
# path; otherwise retain the existing PATH/Homebrew fallback.
bash_bin="${GLUERUN_BASH_BIN:-}"
if [[ -n "$bash_bin" && ( "$bash_bin" != /* || ! -x "$bash_bin" ) ]]; then
  log "ERROR: GLUERUN_BASH_BIN must be an absolute executable path ($bash_bin)"
  fail=1
elif [[ -z "$bash_bin" ]]; then
  bash_bin="$(command -v bash 2>/dev/null || true)"
  if [[ -z "$bash_bin" ]] || ! "$bash_bin" -c '[[ "${BASH_VERSINFO[0]}" -ge 4 ]]' 2>/dev/null; then
    [[ -x /opt/homebrew/bin/bash ]] && bash_bin=/opt/homebrew/bin/bash
  fi
fi
if [[ -z "$bash_bin" ]] || ! "$bash_bin" -c '[[ "${BASH_VERSINFO[0]}" -ge 4 ]]' 2>/dev/null; then
  log "ERROR: bash >= 4 not found (set GLUERUN_BASH_BIN or run 'brew install bash')"
  fail=1
else
  export GLUERUN_BASH_BIN="$bash_bin"
fi

# Resolve and FUNCTIONALLY test codex (an executable bit is not enough; the
# Homebrew codex shim is broken on some setups).
codex_check="${GLUERUN_CODEX_BIN:-}"
if [[ -z "$codex_check" || "$codex_check" != /* || ! -x "$codex_check" ]]; then
  log "ERROR: GLUERUN_CODEX_BIN must resolve to an absolute executable path ($codex_check)"
  fail=1
elif "$codex_check" --version >/dev/null 2>&1; then
  log "codex: $codex_check ($("$codex_check" --version 2>/dev/null | head -1))"
else
  log "ERROR: codex not runnable ($codex_check); set GLUERUN_CODEX_BIN to a working binary"; fail=1
fi

if [[ ! -r "$CODEX_HOME/auth.json" ]]; then
  log "ERROR: Codex credential not readable at $CODEX_HOME/auth.json"; fail=1
fi
if [[ "$fail" -ne 0 ]]; then
  log "environment check failed; aborting orchestrator run"
  exit 1
fi

log "repo_root=$repo_root mode=$mode target=$GLUERUN_TARGET_BRANCH"
cd "$repo_root"
# Watchdog: (re)launch the self-driving loop; autonomate's pidfile guard makes
# this a no-op if it is already running. Any other mode runs a single reconcile.
case "$mode" in
  --watchdog) exec "$bash_bin" ./scripts/orchestration/autonomate.sh ;;
  *)          exec "$bash_bin" ./scripts/orchestration/reconcile.sh "$mode" ;;
esac
