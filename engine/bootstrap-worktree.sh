#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

worktree=""
dry=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) worktree="${2:-}"; shift 2 ;;
    --dry-run) dry=(--dry-run); shift ;;
    *) echo "bootstrap-worktree: unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$worktree" ]] || { echo "bootstrap-worktree: --worktree is required" >&2; exit 2; }
config="${GLUERUN_BOOTSTRAP_JSON:-}"
[[ -n "$config" ]] || config='{}'
exec python3 "$SCRIPT_DIR/bootstrap_worktree.py" \
  --repo "$GLUERUN_ROOT" --worktree "$worktree" \
  --config-json "$config" --state-dir "$GLUERUN_STATE_DIR" "${dry[@]}"
