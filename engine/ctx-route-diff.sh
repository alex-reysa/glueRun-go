#!/usr/bin/env bash
# ctx-route-diff.sh — the diff-volume resume gate, the second of the two
# role-available tripwires the later engine/ctx-route.sh strategy dispatcher will
# consult before it ever returns `resume`.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines a new
# function only; NO existing engine path invokes it, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# by construction, mirroring engine/ctx-planner-resume.sh). The
# GLUERUN_CTX_ROUTING wire-in and the engine/ctx-route.sh spine that composes this
# gate with gluerun_session_resume_decide / gluerun_planner_resume_decide are
# later slices of the routing-module node and are OUT OF SCOPE here.
#
# gluerun_ctx_route_diff_gate <role> <worktree> <head-sha-at-create> \
#                             <lineage-head> [role-relevant-paths...]
#
# Wall-clock age alone under-measures staleness — this is the churn axis. The
# gate measures churn (git numstat added+deleted lines) in the role's relevant
# files between headShaAtCreate and the current lineage head and refuses when it
# exceeds GLUERUN_SESSION_DIFF_MAX_LINES:
#
#   churn > GLUERUN_SESSION_DIFF_MAX_LINES  -> refuse diff-volume
#   churn <= threshold                      -> pass
#
# Role-relevant paths are the gate's scoping input: the trailing arguments are
# passed to `git diff` as a pathspec (a leading `--` separator is conventional),
# so churn outside those paths does not count. With no pathspec supplied the whole
# tree is measured. <role> is accepted so the later dispatcher can consult the
# gate per role (the caller maps a role to its relevant paths); the argument does
# not otherwise steer the arithmetic.
#
# Fail closed (evidence invariance): an empty/absent head-sha-at-create, an empty
# lineage head, or ANY git error (bad sha, non-repo worktree, unreadable diff)
# resolves to `refuse diff-volume`, NEVER to `pass`. This gate is
# monotonic-refuse — its ONLY outputs are `pass` and `refuse diff-volume`; there
# is no input under which it turns a would-be-fresh decision into a resumable one.
# Prints EXACTLY one line and never exits non-zero.
#
# Additive documented knob (default lives here):
#   GLUERUN_SESSION_DIFF_MAX_LINES  400  max churned lines before refusing resume
gluerun_ctx_route_diff_gate() {
  local role="$1" worktree="$2" base_sha="$3" head_sha="$4"
  shift 4 || true
  : "$role"  # accepted for per-role dispatch; the caller supplies the pathspec

  # Fail closed: either sha empty/absent -> indeterminate churn.
  if [[ -z "$base_sha" || -z "$head_sha" ]]; then
    printf 'refuse diff-volume\n'; return 0
  fi

  # git numstat over the range, scoped to the role-relevant pathspec ("$@").
  # A git failure (bad sha, non-repo, etc.) yields empty output AND a non-zero
  # status; either way we fail closed. numstat emits "<added>\t<deleted>\t<path>"
  # with "-" for binary files (treated as 0 churned lines — the axis is text
  # churn); we sum the numeric added+deleted columns.
  local numstat rc=0
  numstat="$(git -C "$worktree" diff --numstat "$base_sha" "$head_sha" "$@" 2>/dev/null)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf 'refuse diff-volume\n'; return 0
  fi

  local max_lines="${GLUERUN_SESSION_DIFF_MAX_LINES:-400}"
  local verdict
  # numstat is passed as an argv, NOT on stdin: the heredoc that feeds the python
  # program already occupies stdin, so a piped stdin would be discarded.
  verdict="$(python3 - "$max_lines" "$numstat" <<'PY' 2>/dev/null || true
import sys
def as_int(s, lo=None):
    try:
        v = int(str(s).strip())
    except Exception:
        return None
    if lo is not None and v < lo:
        return None
    return v
max_lines = as_int(sys.argv[1], lo=0)
if max_lines is None:
    print("REFUSE"); sys.exit(0)   # unparseable knob -> fail closed
churn = 0
for line in sys.argv[2].splitlines():
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) < 3:
        continue
    for col in parts[:2]:
        if col == "-":     # binary file: not text-line churn
            continue
        n = as_int(col)
        if n is None:
            continue
        churn += n
print("REFUSE" if churn > max_lines else "PASS")
PY
)"

  if [[ "$verdict" == "PASS" ]]; then
    printf 'pass\n'
  else
    printf 'refuse diff-volume\n'
  fi
  return 0
}
