#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

worktree="$SINGULAR_ROOT"
base=""
allow_prefixes=()
forbid_prefixes=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree|-C)
      worktree="$2"
      shift 2
      ;;
    --base)
      base="$2"
      shift 2
      ;;
    --allow-prefix)
      allow_prefixes+=("$2")
      shift 2
      ;;
    --forbid-prefix)
      forbid_prefixes+=("$2")
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ${#allow_prefixes[@]} -eq 0 ]]; then
  echo "at least one --allow-prefix is required" >&2
  exit 2
fi

# A path matches a prefix only if it equals the prefix or sits beneath it as a
# path segment (so "internal/artifact" does NOT match "internal/artifact-x.go").
_path_matches() {
  local path="$1" prefix="$2"
  [[ "$path" == "$prefix" || "$path" == "$prefix"/* ]]
}

declare -a files=()
if [[ -n "$base" ]]; then
  while IFS= read -r path; do
    [[ -n "$path" ]] && files+=("$path")
  done < <(git -C "$worktree" diff --name-only "$base"...HEAD)
fi

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  path="${line:3}"
  # Rename entries appear as "old -> new"; validate the destination path.
  if [[ "$path" == *" -> "* ]]; then
    path="${path##* -> }"
  fi
  files+=("$path")
done < <(git -C "$worktree" status --porcelain --untracked-files=all)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "scope check: no changed files"
  exit 0
fi

violations=()
forbidden_hits=()
for ((file_i = 0; file_i < ${#files[@]}; file_i++)); do
  path="${files[$file_i]}"
  # Forbidden takes precedence: a forbidden path is a violation even if it would
  # otherwise match an allow prefix.
  forbidden="no"
  for ((forbid_i = 0; forbid_i < ${#forbid_prefixes[@]}; forbid_i++)); do
    prefix="${forbid_prefixes[$forbid_i]}"
    if _path_matches "$path" "$prefix"; then
      forbidden="yes"
      break
    fi
  done
  if [[ "$forbidden" == "yes" ]]; then
    forbidden_hits+=("$path")
    continue
  fi
  allowed="no"
  for ((allow_i = 0; allow_i < ${#allow_prefixes[@]}; allow_i++)); do
    prefix="${allow_prefixes[$allow_i]}"
    if _path_matches "$path" "$prefix"; then
      allowed="yes"
      break
    fi
  done
  if [[ "$allowed" != "yes" ]]; then
    violations+=("$path")
  fi
done

if [[ ${#forbidden_hits[@]} -gt 0 || ${#violations[@]} -gt 0 ]]; then
  if [[ ${#forbidden_hits[@]} -gt 0 ]]; then
    echo "scope check failed; forbidden paths touched:" >&2
    printf '  %s\n' "${forbidden_hits[@]}" >&2
  fi
  if [[ ${#violations[@]} -gt 0 ]]; then
    echo "scope check failed; disallowed paths:" >&2
    printf '  %s\n' "${violations[@]}" >&2
  fi
  echo "allowed prefixes:" >&2
  printf '  %s\n' "${allow_prefixes[@]}" >&2
  if [[ ${#forbid_prefixes[@]} -gt 0 ]]; then
    echo "forbidden prefixes:" >&2
    printf '  %s\n' "${forbid_prefixes[@]}" >&2
  fi
  exit 2
fi

echo "scope check: ${#files[@]} changed path(s), all allowed"
