#!/usr/bin/env bash
# engine/git-preflight.sh — Git source-tree preflight for the regression suite.
#
# CONTRACT
#   Sourceable library. Defines one public function:
#
#       singular_git_source_preflight <dir>   # 0 = usable, 1 = rejected
#
#   Silent on success. On failure it prints ONE SINGULAR_TEST_SOURCE_UNSUPPORTED
#   block to stderr and returns 1 — the caller exits. This exists so that
#   running the suite from a Git *archive* (tarball, `git archive`, vendored
#   copy) produces one diagnosis instead of dozens of unrelated per-test
#   failures: most engine tests need real history and disposable worktrees.
#
#   Properties checked, in order (first failure wins):
#     1. <dir> is inside a real Git working tree;
#     2. HEAD resolves to a commit (the repo has history);
#     3. a disposable detached worktree can be created, points at HEAD, and
#        can be removed again — the exact probe engine/doctor.py runs as
#        git.disposable-worktree, bounded and always cleaning its temp dir.
#
# PORTABILITY
#   Must PARSE and RUN under Bash 3.2: this may be sourced before any
#   interpreter re-exec. No associative arrays, no ${var,,}, no mapfile, and
#   no empty-array expansion (unbound under 3.2 + `set -u`).

# Run a command under timeout(1)/gtimeout(1) when one exists, else plainly.
# $1 is the timeout binary ("" for none); the rest is the command.
singular_git_preflight__run() {
  local tmo="${1:-}"
  shift
  if [[ -n "$tmo" ]]; then
    "$tmo" 20 "$@"
    return $?
  fi
  "$@"
}

singular_git_source_preflight() {
  local dir="${1:-}"
  local detail="" head="" actual="" parent="" probe="" tmo=""

  if command -v timeout >/dev/null 2>&1; then
    tmo="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    tmo="gtimeout"
  fi

  if [[ -z "$dir" || ! -d "$dir" ]]; then
    detail="source directory does not exist: ${dir:-<empty>}"
  elif ! command -v git >/dev/null 2>&1; then
    detail="git was not found on PATH"
  elif [[ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
    detail="not a Git working tree: $dir"
  elif ! git -C "$dir" rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1; then
    detail="HEAD does not resolve to a commit (no history): $dir"
  else
    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
    parent="$(mktemp -d "${TMPDIR:-/tmp}/singular-git-preflight.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$parent" || ! -d "$parent" ]]; then
      detail="could not create a temporary directory for the disposable-worktree probe"
    else
      probe="$parent/wt"
      if singular_git_preflight__run "$tmo" git -C "$dir" worktree add --detach "$probe" HEAD >/dev/null 2>&1; then
        actual="$(git -C "$probe" rev-parse HEAD 2>/dev/null || true)"
        if ! singular_git_preflight__run "$tmo" git -C "$dir" worktree remove --force "$probe" >/dev/null 2>&1; then
          detail="disposable worktree could not be removed again: $probe"
        elif [[ -z "$actual" || "$actual" != "$head" ]]; then
          detail="disposable worktree HEAD mismatch (expected ${head:-<none>}, got ${actual:-<none>})"
        fi
      else
        detail="disposable worktrees cannot be created from $dir"
      fi
      rm -rf "$parent" 2>/dev/null || true
    fi
  fi

  if [[ -n "$detail" ]]; then
    {
      echo "SINGULAR_TEST_SOURCE_UNSUPPORTED"
      echo "The full regression suite cannot run from a Git archive because it requires"
      echo "history and disposable worktrees."
      echo "Recovery: run from a clean Git clone."
      echo "  detail: $detail"
    } >&2
    return 1
  fi
  return 0
}
