#!/usr/bin/env bash
set -euo pipefail

# 0.6.0: decide.sh writes durable console artifacts — decider-codex.log
# (runner output, previously /dev/null) and session-decider.json (role
# decider via gluerun_session_meta_finalize). The verdict path is unchanged.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/prompts" "$root/schemas/orchestration" \
  "$root/.gluerun-state/leases" "$root/.gluerun-state/runs" \
  "$root/.gluerun-state/inbox" "$root/.worktrees"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/decider.md" "$root/docs/orchestration/prompts/decider.md"
cp "$ENGINE_HOME/schemas/decider-verdict.v0.schema.json" \
  "$root/schemas/orchestration/decider-verdict.v0.schema.json"
printf '# Decisions\n\n## Decision Log\n\n' >"$root/docs/orchestration/decisions.md"
git -C "$root" add .
git -C "$root" -c user.name=t -c user.email=t@t commit -q -m init

cat >"$root/.gluerun-state/leases/TASK-0001.json" <<EOF
{"taskId":"TASK-0001","branch":"agent/x/TASK-0001","area":"x","owner":"l2-developer",
 "ownedFiles":["a.go"],"forbiddenFiles":[],"baseSha":"target","batchId":"B","runId":"RUN-D",
 "worktree":"$root","status":"running","retryCount":0,"maxRetries":3,
 "createdAt":"2026-07-17T00:00:00Z","updatedAt":"2026-07-17T00:00:00Z"}
EOF

# Runner stub: emits a valid retry verdict, chatter on stdout/stderr, and a
# provider-style session meta when asked.
stub="$root/runner.sh"
cat >"$stub" <<'SH'
#!/usr/bin/env bash
out="" meta=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) out="$2"; shift 2 ;;
    --session-meta) meta="$2"; shift 2 ;;
    --level|-C|--run-id|--prompt-file|--resume-session) shift 2 ;;
    *) shift ;;
  esac
done
echo "decider runner stdout chatter"
echo "decider runner stderr chatter" >&2
[[ -n "$meta" ]] && printf '{"schema":"gluerun.orchestration.session-meta.v0","provider":"fake","model":"fake-1","effort":"low","exitCode":0}\n' >"$meta"
printf '{"schema":"gluerun.orchestration.decider-verdict.v0","taskId":"TASK-0001","failureClass":"gate-red","action":"retry","rationale":"try again","nextOwner":"l1","confidence":"medium"}\n' >"$out"
SH
chmod +x "$stub"

out="$(env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
  GLUERUN_ORCH_DIR="$root/docs/orchestration" GLUERUN_TASKS_DIR="$root/docs/orchestration/tasks" \
  GLUERUN_LEASES_DIR="$root/.gluerun-state/leases" GLUERUN_RUNS_DIR="$root/.gluerun-state/runs" \
  GLUERUN_INBOX_DIR="$root/.gluerun-state/inbox" GLUERUN_WORKTREES_DIR="$root/.worktrees" \
  GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson" GLUERUN_TARGET_BRANCH=target \
  GLUERUN_DECIDER_SCHEMA="$root/schemas/orchestration/decider-verdict.v0.schema.json" \
  GLUERUN_RUNNER="$stub" GLUERUN_DECIDER_TIMEOUT_SEC=30 \
  "$SCRIPT_DIR/decide.sh" --task TASK-0001 --failure-class gate-red \
    --branch agent/x/TASK-0001 --run RUN-D --worktree "$root" 2>&1)"

assert_contains "$out" "action=retry" "verdict path unchanged"

run_dir="$root/.gluerun-state/runs/RUN-D"
[[ -f "$run_dir/decider-codex.log" ]] || fail "decider-codex.log missing"
log="$(cat "$run_dir/decider-codex.log")"
assert_contains "$log" "decider runner stdout chatter" "stdout captured"
assert_contains "$log" "decider runner stderr chatter" "stderr captured"

[[ -f "$run_dir/session-decider.json" ]] || fail "session-decider.json missing"
python3 - "$run_dir/session-decider.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["role"] == "decider", d
assert d["taskId"] == "TASK-0001", d
assert d["runId"] == "RUN-D", d
assert d["provider"] == "fake", d
PY

echo "PASS: test-decide-artifacts"
