#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg (missing: $needle)"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/state/leases" "$tmp/docs/orchestration/tasks" "$tmp/worktrees"

cat >"$tmp/fake-decider.sh" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "TASK-0004" ]]; then
    echo "fake decider should not run for terminal TASK-0004" >&2
    exit 1
  fi
done
echo action=revalidate-evidence
SH
chmod +x "$tmp/fake-decider.sh"

cat >"$tmp/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: stale running fixture

Status: planned
EOF

cat >"$tmp/docs/orchestration/tasks/TASK-0004.md" <<'EOF'
# TASK-0004: already integrated fixture

Status: integrated
EOF
mkdir -p "$tmp/docs/orchestration/packets/imported/TASK-0004"
printf '%s\n' '{}' >"$tmp/docs/orchestration/packets/imported/TASK-0004/RUN-FIXTURE.json"

printf '%s\n' '{"status":"running"}' >"$tmp/state/leases/TASK-0001.json"
printf '%s\n' '{"status":"planned"}' >"$tmp/state/leases/TASK-0002.json"
printf '%s\n' '{"status":"needs-review"}' >"$tmp/state/leases/TASK-0003.json"
printf '%s\n' '{"status":"running"}' >"$tmp/state/leases/TASK-0004.json"
printf '%s\n' '{not-json' >"$tmp/state/leases/TASK-0005.json"

out="$(
  SINGULAR_ROOT="$tmp" \
  SINGULAR_STATE_DIR="$tmp/state" \
  SINGULAR_ORCH_DIR="$tmp/docs/orchestration" \
  SINGULAR_TASKS_DIR="$tmp/docs/orchestration/tasks" \
  SINGULAR_LEASES_DIR="$tmp/state/leases" \
  SINGULAR_WORKTREES_DIR="$tmp/worktrees" \
  SINGULAR_STALE_MINUTES=0 \
  SINGULAR_RECOVERY_DECIDER="$tmp/fake-decider.sh" \
  "$SCRIPT_DIR/recover.sh" --scan
)"

assert_contains "$out" "recover: cleared stale lease TASK-0001" "running lease should fall back to filename task id"
assert_contains "$out" "recover: cleared stale lease TASK-0002" "planned lease should fall back to filename task id"
assert_contains "$out" "recover: cleared stale lease TASK-0003" "needs-review lease should be recoverable when stale"
assert_contains "$out" "recover: closed stale lease TASK-0004 from task status integrated" "terminal task status should close an active lease instead of requeueing"
assert_contains "$out" "recover: quarantined unreadable lease TASK-0005.json" "invalid lease JSON should be preserved outside active lease scans"
assert_contains "$out" "recover (scan): 5 action(s)" "all stale active lease files and invalid lease residue should be handled"

[[ ! -e "$tmp/state/leases/TASK-0001.json" ]] || fail "TASK-0001 lease should be cleared"
[[ ! -e "$tmp/state/leases/TASK-0002.json" ]] || fail "TASK-0002 lease should be cleared"
[[ ! -e "$tmp/state/leases/TASK-0003.json" ]] || fail "TASK-0003 lease should be cleared"
[[ ! -e "$tmp/state/leases/TASK-0005.json" ]] || fail "TASK-0005 invalid lease should be quarantined"
[[ -e "$tmp/state/leases/superseded/TASK-0005.json" ]] || fail "TASK-0005 invalid lease should be preserved under superseded"
grep -q '"status": "integrated"' "$tmp/state/leases/TASK-0004.json" || fail "TASK-0004 lease should be terminalized"
grep -q '^Status: ready$' "$tmp/docs/orchestration/tasks/TASK-0001.md" || fail "task file should be requeued ready"

echo "ok"
