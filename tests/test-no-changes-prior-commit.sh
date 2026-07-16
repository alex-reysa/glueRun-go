#!/usr/bin/env bash
set -euo pipefail

# E7 (0.5.0): a retry whose content was already committed by a PRIOR attempt
# (empty staged diff, owned files differ from base, gate green) proceeds as a
# valid empty-diff attempt instead of failing `no-changes`. 0.4.0 parked fully
# green work here (field audit: TASK-0052/0053).

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-no-changes-prior-commit.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

workroot="$(mktemp -d)"
trap 'rm -rf "$workroot"' EXIT
root="$workroot/repo"
mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/prompts" "$root/.gluerun-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$root/docs/orchestration/prompts/"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/"
printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' >"$root/docs/orchestration/prompts/decider.md"

cat >"$root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Empty-diff retry fixture

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-generic`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Implement the widget parser.

## Scope

Owned files:

- `internal/widget/parser.go`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Parser handles empty input.
EOF
git -C "$root" add . && git -C "$root" -c user.name=t -c user.email=t@t commit -qm init

# Mock runner: L2 writes FIXED content every attempt (attempt 2 therefore has
# an empty staged diff on top of attempt 1's commit). Auditor returns needs-fix
# on the first call, accepted afterwards. WRITE_MODE=never makes L2 write
# nothing at all (regression case).
mock="$workroot/mock-runner.sh"
cat >"$mock" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
level=""; worktree=""; out=""
args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    --level) level="${args[$((i+1))]}"; i=$((i+2)) ;;
    -C|--worktree) worktree="${args[$((i+1))]}"; i=$((i+2)) ;;
    --output-last-message) out="${args[$((i+1))]}"; i=$((i+2)) ;;
    *) i=$((i+1)) ;;
  esac
done
if [[ "$level" == "l2" ]]; then
  if [[ "${WRITE_MODE:-fixed}" == "fixed" ]]; then
    mkdir -p "$worktree/internal/widget"
    printf 'package widget\n// stable content\n' >"$worktree/internal/widget/parser.go"
  fi
  [[ -n "$out" ]] && cat >"$out" <<'PKT'
{"schema":"gluerun.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  exit 0
fi
ac=0; [[ -f "${AUDIT_COUNT_FILE:-/dev/null}" ]] && ac="$(cat "$AUDIT_COUNT_FILE" 2>/dev/null || echo 0)"
ac=$((ac+1)); [[ -n "${AUDIT_COUNT_FILE:-}" ]] && echo "$ac" >"$AUDIT_COUNT_FILE"
if [[ "$ac" -eq 1 ]]; then
  [[ -n "$out" ]] && printf '{"verdict":"needs-fix","findings":[{"summary":"tighten tests"}]}\n' >"$out"
else
  [[ -n "$out" ]] && printf '{"verdict":"accepted","findings":[]}\n' >"$out"
fi
exit 0
MOCK
chmod +x "$mock"

run_drive() {
  env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
    GLUERUN_ORCH_DIR="$root/docs/orchestration" GLUERUN_TASKS_DIR="$root/docs/orchestration/tasks" \
    GLUERUN_LEASES_DIR="$root/.gluerun-state/leases" GLUERUN_INBOX_DIR="$root/.gluerun-state/inbox" \
    GLUERUN_RUNS_DIR="$root/.gluerun-state/runs" GLUERUN_WORKTREES_DIR="$root/.worktrees" \
    GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson" \
    GLUERUN_TARGET_BRANCH=target GLUERUN_RUNNER="$mock" GLUERUN_ENGINE_HOME="$ENGINE_HOME" \
    GLUERUN_DECIDER_FAST=1 AUDIT_COUNT_FILE="$workroot/audit-count" "$@" \
    bash "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1
}

# 1. needs-fix then retry-with-identical-content: reconciled, accepted.
out="$(run_drive env WRITE_MODE=fixed)" || fail "drive should accept (out: $out)"
events="$(cat "$root/.gluerun-state/events.ndjson")"
assert_contains "$events" '"type":"l1.no_changes_reconciled"' "empty-diff retry reconciled"
assert_contains "$events" '"type":"l1.task_accepted"' "task accepted after reconciled retry"

# 2. Regression: a worker that writes nothing on a FRESH task still fails
#    no-changes (truly no content vs base).
rm -rf "$root/.gluerun-state/runs" "$root/.gluerun-state/leases" "$root/.gluerun-state/inbox" "$root/.worktrees"
: >"$root/.gluerun-state/events.ndjson"
rm -f "$workroot/audit-count"
git -C "$root" worktree prune 2>/dev/null || true
git -C "$root" branch -D agent/widget/TASK-0001-generic 2>/dev/null || true
python3 - "$root/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
open(p, "w").write(re.sub(r"Status: \w+", "Status: ready", t, count=1))
PY
rc=0
out="$(run_drive env WRITE_MODE=never)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "empty fresh attempt must not accept"
assert_contains "$(cat "$root/.gluerun-state/events.ndjson")" 'no-changes' "no-changes failure recorded"

echo "PASS: test-no-changes-prior-commit"
