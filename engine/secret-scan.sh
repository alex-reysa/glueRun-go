#!/usr/bin/env bash
set -euo pipefail

# Credential accident-guard. Scans added content for high-confidence secret
# patterns before a commit or push. This is deliberately NOT a decision the
# decider can override — it prevents accidentally leaking live credentials (e.g.
# the Supabase service-role tokens in the environment) to git/origin.
#
# Usage:
#   secret-scan.sh --worktree PATH --staged          # scan staged diff (pre-commit)
#   secret-scan.sh --worktree PATH --range A..B       # scan a commit range (pre-push)
#   secret-scan.sh --worktree PATH                    # scan unstaged + untracked
#   secret-scan.sh --artifacts RUN_DIR                # scan durable context artifacts
#
# Exit 0 = clean; exit 2 = secret(s) found (offending lines printed to stderr).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# The pattern set now lives in engine/secret-patterns.tsv and is exposed by
# singular_secret_scan_patterns() in lib.sh (sourced above), so the console's
# python redactor can read the same definition.

worktree="$SINGULAR_ROOT"
mode="working"
range=""
artifacts_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree|-C) worktree="$2"; shift 2 ;;
    --staged) mode="staged"; shift ;;
    --range) mode="range"; range="$2"; shift 2 ;;
    --artifacts)
      [[ $# -ge 2 ]] || { echo "missing value for --artifacts" >&2; exit 2; }
      mode="artifacts"; artifacts_dir="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$mode" == "artifacts" ]]; then
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/ctx-artifact-scan.sh"
  singular_ctx_artifact_scan "$artifacts_dir"
  exit $?
fi

# Gather the diff text (added lines) plus the set of added file paths.
case "$mode" in
  staged) diff_text="$(git -C "$worktree" diff --cached -U0 2>/dev/null || true)"
          added_paths="$(git -C "$worktree" diff --cached --name-only --diff-filter=A 2>/dev/null || true)" ;;
  range)  diff_text="$(git -C "$worktree" diff -U0 "$range" 2>/dev/null || true)"
          added_paths="$(git -C "$worktree" diff --name-only --diff-filter=A "$range" 2>/dev/null || true)" ;;
  *)      diff_text="$(git -C "$worktree" diff -U0 2>/dev/null || true)"
          added_paths="$(git -C "$worktree" ls-files --others --exclude-standard 2>/dev/null || true)" ;;
esac

# Only inspect added lines (leading '+', excluding the +++ file header).
added_lines="$(printf '%s\n' "$diff_text" | grep -E '^\+' | grep -vE '^\+\+\+ ' || true)"

hits=0
report() { echo "secret-scan: $1" >&2; hits=$((hits + 1)); }

scan() {
  local label="$1" regex="$2"
  local m
  # -e so patterns beginning with '-' (e.g. private-key headers) are not parsed as flags.
  m="$(printf '%s\n' "$added_lines" | grep -nE -e "$regex" || true)"
  if [[ -n "$m" ]]; then
    report "$label match in added lines:"
    printf '%s\n' "$m" | sed 's/^/    /' >&2
  fi
}

while IFS="$(printf '\t')" read -r label regex; do
  scan "$label" "$regex"
done < <(singular_secret_scan_patterns)

# Flag any added dotenv files outright.
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  case "$(basename "$p")" in
    .env|.env.*) [[ "$(basename "$p")" == ".env.example" ]] || report "dotenv file added: $p" ;;
  esac
done <<<"$added_paths"

if [[ "$hits" -gt 0 ]]; then
  echo "secret-scan: $hits potential secret(s) found; refusing." >&2
  exit 2
fi
echo "secret-scan: clean"
