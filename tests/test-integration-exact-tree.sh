#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-integration-exact-tree.sh requires bash >= 4" >&2
  exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
watcher_pid=""
cleanup() {
  [[ -z "$watcher_pid" ]] || kill "$watcher_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
repo="$tmp/repo"
mkdir -p "$repo/docs/orchestration/tasks" \
  "$repo/docs/orchestration/packets/imported/TASK-0401" \
  "$repo/.singular-state"
git -C "$repo" init -q
git -C "$repo" checkout -q -b target
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.local

cat >"$repo/singular.config.json" <<'JSON'
{
  "schemaVersion": "v2",
  "targetBranch": "target",
  "gateCommand": "bash integration-gate.sh",
  "bootstrap": {"required": false, "commands": []}
}
JSON
cat >"$repo/integration-gate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
while [[ ! -f "$MAIN_DIRT_READY" ]]; do sleep 0.01; done
printf '%s\n' "$PWD" >"$GATE_PWD_FILE"
[[ "$(cat app.txt)" == "merged-and-tested" ]]
printf '%s\n' \
  '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
chmod +x "$repo/integration-gate.sh"
printf 'base\n' >"$repo/app.txt"
cat >"$repo/docs/orchestration/tasks/TASK-0401.md" <<'EOF'
# TASK-0401: Exact integration tree

Status: accepted
Area: core
Target branch: `target`
Worker branch: `agent/core/TASK-0401-exact-tree`
Test policy: `strict_test_first`
Gate command: `bash integration-gate.sh`
Dispatch mode: canonical
Depends on: []

## Objective

Prove the exact staged merge tree.

## Scope

Owned files:

- `app.txt`
EOF
printf '%s\n' '.singular-state/' '.singular-cache/' '.singular-evidence/' '.worktrees/' \
  >"$repo/.gitignore"
git -C "$repo" add .
git -C "$repo" commit -qm fixture

git -C "$repo" checkout -q -b agent/core/TASK-0401-exact-tree
printf 'merged-and-tested\n' >"$repo/app.txt"
git -C "$repo" add app.txt
git -C "$repo" commit -qm feature
feature_head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q target

packet="$repo/docs/orchestration/packets/imported/TASK-0401/RUN-EXACT.json"
cat >"$packet" <<JSON
{
  "schema": "singular.orchestration.state-packet.v0",
  "packetId": "RUN-EXACT",
  "runId": "RUN-EXACT",
  "taskId": "TASK-0401",
  "area": "core",
  "role": "l2-developer",
  "status": "accepted",
  "baseRef": "target",
  "branch": "agent/core/TASK-0401-exact-tree",
  "headSha": "$feature_head",
  "workspace": "$repo",
  "ownedFiles": ["app.txt"],
  "changedFiles": ["app.txt"],
  "commands": [{"cmd": "bash integration-gate.sh", "exitCode": 0}],
  "tests": [{"name": "exact-tree", "phase": "regression", "status": "passed"}],
  "evidence": [{"kind": "test", "ref": "exact-tree"}],
  "blockers": [],
  "nextAction": "integrate",
  "createdAt": "2026-08-30T00:00:00Z"
}
JSON
cat >"${packet%.json}.audit.json" <<'JSON'
{
  "schema": "singular.orchestration.audit-verdict.v0",
  "taskId": "TASK-0401",
  "runId": "RUN-EXACT",
  "branch": "agent/core/TASK-0401-exact-tree",
  "verdict": "accepted",
  "evidenceReviewed": ["exact-tree"],
  "commandsRun": ["bash integration-gate.sh"],
  "findings": [],
  "requiredFixes": [],
  "rationale": "fixture accepted"
}
JSON
git -C "$repo" add docs/orchestration/packets
git -C "$repo" commit -qm packet
target_parent="$(git -C "$repo" rev-parse HEAD)"

# A green exact-tree gate is not permission to commit after the campaign
# publication boundary becomes unavailable. Hold the campaign lock only after
# the merge is staged, let the gate pass, and force the final lock acquisition
# to time out. The merge/index/task-status mutation must be fully aborted.
lock_fail_dirt_ready="$tmp/lock-fail-dirt-ready"
lock_fail_release="$tmp/lock-fail-release"
lock_fail_gate_pwd="$tmp/lock-fail-gate-pwd"
lock_fail_out="$tmp/integrate-lock-fail.out"
(
  while [[ ! -f "$repo/.git/MERGE_HEAD" ]]; do sleep 0.01; done
  export SINGULAR_ROOT="$repo"
  export SINGULAR_STATE_DIR="$repo/.singular-state"
  export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
  # shellcheck source=/dev/null
  source "$ENGINE_HOME/engine/lib.sh"
  singular_campaign_lock_acquire
  printf 'poison-lock-fail-main-worktree\n' >"$repo/app.txt"
  : >"$lock_fail_dirt_ready"
  # The parent releases us only after integrate returns. This makes the race
  # independent of machine speed while the publisher's 0.2s bounded wait
  # still guarantees the test itself terminates.
  while [[ ! -e "$lock_fail_release" ]]; do sleep 0.01; done
  singular_campaign_lock_release
) &
watcher_pid=$!
lock_fail_rc=0
env \
  SINGULAR_ROOT="$repo" \
  SINGULAR_STATE_DIR="$repo/.singular-state" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  SINGULAR_AUTO_PROMOTE_GATES=0 \
  SINGULAR_PUSH=0 \
  SINGULAR_CAMPAIGN_LOCK_WAIT_TICKS=2 \
  MAIN_DIRT_READY="$lock_fail_dirt_ready" \
  GATE_PWD_FILE="$lock_fail_gate_pwd" \
  bash "$ENGINE_HOME/engine/integrate.sh" \
    --task TASK-0401 --run-id RUN-LOCK-FAIL >"$lock_fail_out" 2>&1 \
  || lock_fail_rc=$?
: >"$lock_fail_release"
wait "$watcher_pid"
watcher_pid=""
[[ "$lock_fail_rc" -ne 0 ]] \
  || fail "campaign publication lock timeout unexpectedly integrated: $(cat "$lock_fail_out")"
grep -q 'campaign-publication-lock-timeout' "$lock_fail_out" \
  || fail "campaign lock timeout reason missing: $(cat "$lock_fail_out")"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$target_parent" ]] \
  || fail "campaign lock timeout advanced target HEAD"
[[ ! -e "$repo/.git/MERGE_HEAD" ]] \
  || fail "campaign lock timeout left an in-progress merge"
git -C "$repo" diff --cached --quiet \
  || fail "campaign lock timeout left staged integration bytes"
grep -q '^Status: accepted$' "$repo/docs/orchestration/tasks/TASK-0401.md" \
  || fail "campaign lock timeout retained the staged integrated task status"
[[ "$(cat "$repo/app.txt")" == "poison-lock-fail-main-worktree" ]] \
  || fail "campaign lock timeout destroyed a concurrent worktree edit"
git -C "$repo" restore --worktree -- app.txt

# The mutation happens only after integrate's clean-worktree preflight and
# merge staging. An old in-place gate reads "poison-main-worktree" and fails;
# the exact-tree disposable gate reads the staged "merged-and-tested" bytes.
main_dirt_ready="$tmp/main-dirt-ready"
gate_pwd_file="$tmp/gate-pwd"
(
  while [[ ! -f "$repo/.git/MERGE_HEAD" ]]; do sleep 0.01; done
  printf 'poison-main-worktree\n' >"$repo/app.txt"
  : >"$main_dirt_ready"
) &
watcher_pid=$!

out="$tmp/integrate.out"
env \
  SINGULAR_ROOT="$repo" \
  SINGULAR_STATE_DIR="$repo/.singular-state" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  SINGULAR_AUTO_PROMOTE_GATES=0 \
  SINGULAR_PUSH=0 \
  MAIN_DIRT_READY="$main_dirt_ready" \
  GATE_PWD_FILE="$gate_pwd_file" \
  bash "$ENGINE_HOME/engine/integrate.sh" \
    --task TASK-0401 --run-id RUN-EXACT >"$out" 2>&1 \
  || fail "exact-tree integration failed: $(cat "$out")"
wait "$watcher_pid"
watcher_pid=""

grep -q '^INTEGRATED TASK-0401:' "$out" || fail "integration did not complete: $(cat "$out")"
[[ "$(cat "$gate_pwd_file")" != "$repo" ]] || fail "integration gate ran in the dirty main checkout"
[[ "$(git -C "$repo" show HEAD:app.txt)" == "merged-and-tested" ]] \
  || fail "committed tree did not preserve the tested staged bytes"
[[ "$(cat "$repo/app.txt")" == "poison-main-worktree" ]] \
  || fail "fixture did not retain distinct unstaged main-checkout bytes"
merge_commit="$(git -C "$repo" rev-parse HEAD)"
[[ "$(git -C "$repo" rev-list --parents -n 1 HEAD)" == \
    "$merge_commit $target_parent $feature_head" ]] \
  || fail "committed merge parents differ from the tested synthetic parents"
[[ "$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')" == 1 ]] \
  || fail "disposable integration gate worktree leaked"

echo "PASS: test-integration-exact-tree"
