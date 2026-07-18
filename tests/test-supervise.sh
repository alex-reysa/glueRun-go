#!/usr/bin/env bash
set -euo pipefail

# 0.10.0: supervise.sh runs ONE read-only briefing pass and, only on a
# schema-valid report, publishes .gluerun-state/supervisor/latest.json (+ a
# pruned history snapshot + a supervisor.report event). An invalid report or a
# timeout emits supervisor.failed and leaves latest.json untouched. The run dir
# is shaped like a session dir (supervisor-prompt.md / supervisor-codex.log /
# session-supervisor.json / report-raw.json) so the console can discover it.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-supervise.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/prompts" "$root/docs/orchestration/tasks" \
  "$root/docs/orchestration/gates" "$root/schemas/orchestration" \
  "$root/.gluerun-state/leases" "$root/.gluerun-state/runs" \
  "$root/.gluerun-state/inbox" "$root/.worktrees"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/supervisor.md" "$root/docs/orchestration/prompts/supervisor.md"
cp "$ENGINE_HOME/schemas/supervisor-report.v0.schema.json" \
  "$root/schemas/orchestration/supervisor-report.v0.schema.json"
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{"schema":"gluerun.orchestration.dag.v0","layers":["scaffold"],"kinds":["build"],
 "nodes":[{"id":"M0.core","stage":"M0","area":"core","layer":"scaffold","kind":"build","dependsOn":[],"requiredCompletion":"scaffold_complete"}]}
EOF
printf '# gluerun Autonomous Status\n\nIteration: 3\nNote: running\n' >"$root/.gluerun-state/STATUS.md"
printf '%s\n' '{"ts":"2026-07-18T00:00:00Z","type":"autonomate.started","message":"loop started","data":{}}' \
  >"$root/.gluerun-state/events.ndjson"
git -C "$root" add .
git -C "$root" -c user.name=t -c user.email=t@t commit -q -m init

# Runner stub: emits per STUB_MODE — a valid report, a schema-invalid object, or a
# sleep (to drive the watchdog timeout). Always writes a provider session meta.
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
echo "supervisor runner chatter"
[[ -n "$meta" ]] && printf '{"schema":"gluerun.orchestration.session-meta.v0","provider":"fake","model":"fake-1","effort":"low","exitCode":0}\n' >"$meta"
case "${STUB_MODE:-valid}" in
  valid)   printf '%s\n' '{"schema":"gluerun.orchestration.supervisor-report.v0","stage":"working core","narrative":"All nominal; one area on the frontier.","risks":["disk filling"],"nextSteps":["watch disk"],"proposedSettings":{"GLUERUN_MAX_CONCURRENT":"2"}}' >"$out" ;;
  invalid) printf '%s\n' '{"schema":"gluerun.orchestration.supervisor-report.v0","stage":"x"}' >"$out" ;;
  sleep)   sleep 30 ;;
esac
SH
chmod +x "$stub"

supervise() {
  env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
    GLUERUN_ORCH_DIR="$root/docs/orchestration" GLUERUN_TASKS_DIR="$root/docs/orchestration/tasks" \
    GLUERUN_LEASES_DIR="$root/.gluerun-state/leases" GLUERUN_RUNS_DIR="$root/.gluerun-state/runs" \
    GLUERUN_INBOX_DIR="$root/.gluerun-state/inbox" GLUERUN_WORKTREES_DIR="$root/.worktrees" \
    GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson" GLUERUN_TARGET_BRANCH=target \
    GLUERUN_SUPERVISOR_SCHEMA="$root/schemas/orchestration/supervisor-report.v0.schema.json" \
    GLUERUN_RUNNER="$stub" "$@" bash "$SCRIPT_DIR/supervise.sh" --once
}

# --- 1. valid report -> published ------------------------------------------
out="$(supervise STUB_MODE=valid 2>&1)"
assert_contains "$out" "status=ok" "valid report publishes"
run_id="$(sed -n 's/^runId=//p' <<<"$out" | tail -1)"
run_dir="$root/.gluerun-state/runs/$run_id"

latest="$root/.gluerun-state/supervisor/latest.json"
[[ -f "$latest" ]] || fail "latest.json not written"
python3 - "$latest" "$run_id" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == "gluerun.orchestration.supervisor-report.v0", d
assert d["stage"] == "working core", d
assert d["narrative"], d
assert d["runId"] == sys.argv[2], d
assert d["generatedAt"], d
assert d["proposedSettings"] == {"GLUERUN_MAX_CONCURRENT": "2"}, d
PY
[[ -n "$(find "$root/.gluerun-state/supervisor/history" -name '*.json' 2>/dev/null)" ]] || fail "history snapshot not written"

# Session-dir contract for the console.
[[ -f "$run_dir/supervisor-prompt.md" ]] || fail "supervisor-prompt.md missing"
[[ -f "$run_dir/supervisor-codex.log" ]] || fail "supervisor-codex.log missing"
[[ -f "$run_dir/report-raw.json" ]] || fail "report-raw.json missing"
[[ -f "$run_dir/session-supervisor.json" ]] || fail "session-supervisor.json missing"
grep -q "supervisor runner chatter" "$run_dir/supervisor-codex.log" || fail "runner log not captured"
python3 - "$run_dir/session-supervisor.json" "$run_id" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["role"] == "supervisor", d
assert d["runId"] == sys.argv[2], d
assert d["provider"] == "fake", d
PY
# The rendered prompt carries the digest (STATUS.md verbatim + whitelist).
grep -q "gluerun Autonomous Status" "$run_dir/supervisor-prompt.md" || fail "digest STATUS.md not rendered into prompt"
grep -q "GLUERUN_MAX_CONCURRENT" "$run_dir/supervisor-prompt.md" || fail "settings whitelist not rendered into prompt"
assert_contains "$(cat "$root/.gluerun-state/events.ndjson")" '"type":"supervisor.report"' "report event"

latest_before="$(cat "$latest")"

# --- 2. schema-invalid report -> failed, latest untouched -------------------
out="$(supervise STUB_MODE=invalid 2>&1)"
assert_contains "$out" "status=failed" "invalid report fails"
assert_contains "$(cat "$root/.gluerun-state/events.ndjson")" '"type":"supervisor.failed"' "failed event"
assert_contains "$(cat "$root/.gluerun-state/events.ndjson")" '"reason":"invalid"' "failure reason invalid"
[[ "$(cat "$latest")" == "$latest_before" ]] || fail "latest.json must be untouched after an invalid report"

# --- 3. timeout -> failed(timeout), latest untouched ------------------------
out="$(supervise STUB_MODE=sleep GLUERUN_SUPERVISOR_TIMEOUT_SEC=2 2>&1)"
assert_contains "$out" "status=failed" "timeout fails"
assert_contains "$(cat "$root/.gluerun-state/events.ndjson")" '"reason":"timeout"' "failure reason timeout"
[[ "$(cat "$latest")" == "$latest_before" ]] || fail "latest.json must be untouched after a timeout"

echo "PASS: test-supervise"
