#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
mkdir -p "$tmp/state/runs/RUN-1"

run_lib() {
  GLUERUN_ROOT="$tmp" \
  GLUERUN_STATE_DIR="$tmp/state" \
  GLUERUN_RUNS_DIR="$tmp/state/runs" \
  bash -c "source '$ENGINE_HOME/engine/lib.sh'; $1"
}

# 1. Provider marker in a RUNNER log -> structured evidence with that logRef.
printf 'stream...\nerror: rate limited, try again at 10pm\n' >"$tmp/state/runs/RUN-1/worker-codex.log"
ev="$(run_lib gluerun_cycle_limit_window_evidence_json)" || fail "runner-log marker should be detected"
assert_contains "$ev" '"logRef":"'"$tmp"'/state/runs/RUN-1/worker-codex.log"' "evidence carries logRef"
assert_contains "$ev" '"marker"' "evidence carries marker"
rm -f "$tmp/state/runs/RUN-1/worker-codex.log"

# 2. Same content in a prompt .md is NEVER evidence (prompts embed repo prose —
#    the 0.4.0 false-positive vector).
printf 'the quota banner shows: rate limit exceeded\n' >"$tmp/state/runs/RUN-1/l2-prompt.md"
run_lib gluerun_cycle_limit_window_evidence_json >/dev/null 2>&1 \
  && fail ".md files must not be scanned"

# 3. Bare repo word "quota" in a runner log is not a marker; a provider
#    phrasing is.
printf 'building the quota management module\n' >"$tmp/state/runs/RUN-1/worker-codex.log"
run_lib gluerun_cycle_limit_window_evidence_json >/dev/null 2>&1 \
  && fail "bare 'quota' prose must not match"
printf 'api says: quota exceeded for this billing period\n' >"$tmp/state/runs/RUN-1/worker-codex.log"
run_lib gluerun_cycle_limit_window_evidence_json >/dev/null \
  || fail "'quota exceeded' must match"
rm -f "$tmp/state/runs/RUN-1/worker-codex.log"

# 4. Arming a quota backoff without logRef evidence is refused.
if run_lib "gluerun_planner_backoff_set quota RUN-X node-x ''" 2>/dev/null; then
  fail "quota backoff with empty logRef must be refused"
fi
[[ -f "$tmp/state/planner-backoff.json" ]] && fail "refused backoff must not write the file"
assert_contains "$(cat "$tmp/state/events.ndjson")" '"type":"backoff.rejected_no_evidence"' "refusal event"

# 5. With a logRef it arms; clear removes it with an event.
run_lib "gluerun_planner_backoff_set quota RUN-X node-x '$tmp/state/runs/RUN-1/some.log'" \
  || fail "quota backoff with logRef should arm"
[[ -f "$tmp/state/planner-backoff.json" ]] || fail "backoff file missing after arm"
out="$(run_lib gluerun_planner_backoff_clear)"
assert_contains "$out" "backoff cleared" "clear output"
[[ -f "$tmp/state/planner-backoff.json" ]] && fail "backoff file should be gone"
assert_contains "$(cat "$tmp/state/events.ndjson")" '"type":"backoff.cleared"' "clear event"
out="$(run_lib gluerun_planner_backoff_clear)"
assert_contains "$out" "no active backoff" "idempotent clear"

# 6. Chokepoint integration: import rejections alone are never limit-eligible
#    (breaker trips even with a planted marker); dispatch failures with runner
#    evidence arm the backoff with the logRef.
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" branch agent/integration

auto_env() {
  GLUERUN_ROOT="$repo" \
  GLUERUN_STATE_DIR="$repo/.gluerun-state" \
  GLUERUN_RUNS_DIR="$repo/.gluerun-state/runs" \
  GLUERUN_ORCH_DIR="$repo/docs/orchestration" \
  GLUERUN_TASKS_DIR="$repo/docs/orchestration/tasks" \
  GLUERUN_TARGET_BRANCH=agent/integration \
  GLUERUN_RECONCILE_SCRIPT="$repo/stub-reconcile.sh" \
  GLUERUN_PUSH=0 \
  "$@"
}

write_stub() {
  # args: failed_dispatches l1_import_rejections
  cat >"$repo/stub-reconcile.sh" <<SH
#!/usr/bin/env bash
echo "dispatched_this_run=0"
echo "integrated_this_run=0"
echo "failed_dispatches=$1"
echo "failed_integrations=0"
echo "planner_failures_this_run=0"
echo "l1_import_rejections_this_run=$2"
echo "reaped_ok=0"
echo "reaped_failures=0"
echo "workers_running=0"
SH
  chmod +x "$repo/stub-reconcile.sh"
}

mkdir -p "$repo/.gluerun-state/runs/RUN-2" "$repo/docs/orchestration/tasks"
printf 'error: usage limit reached, try again at 9pm\n' >"$repo/.gluerun-state/runs/RUN-2/planner-codex.log"

# 6a. Rejections only: no limit eligibility -> breaker trips, no backoff.
write_stub 0 1
out="$(auto_env bash "$ENGINE_HOME/engine/autonomate.sh" --once 2>&1)" || true
assert_contains "$out" "breaker -> 1" "import rejections alone must trip the breaker"
[[ -f "$repo/.gluerun-state/planner-backoff.json" ]] \
  && fail "import rejections must never arm a quota backoff"

# 6b. Dispatch failure + runner evidence: backoff armed with logRef, breaker untouched.
touch "$repo/.gluerun-state/runs/RUN-2/planner-codex.log"
write_stub 1 0
out="$(auto_env bash "$ENGINE_HOME/engine/autonomate.sh" --once 2>&1)" || true
assert_contains "$out" "armed quota backoff" "dispatch failure + evidence should arm"
[[ -f "$repo/.gluerun-state/planner-backoff.json" ]] || fail "backoff file expected"
logref="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["logRef"])' "$repo/.gluerun-state/planner-backoff.json")"
assert_contains "$logref" "planner-codex.log" "backoff logRef points at the evidence"

# 6c. Sleepthrough disabled (legacy knob): breaker trips despite evidence.
rm -f "$repo/.gluerun-state/planner-backoff.json" "$repo/.gluerun-state/circuit.json"
touch "$repo/.gluerun-state/runs/RUN-2/planner-codex.log"
out="$(GLUERUN_DISABLE_LIMIT_SLEEPTHROUGH=1 auto_env bash "$ENGINE_HOME/engine/autonomate.sh" --once 2>&1)" || true
assert_contains "$out" "breaker -> 1" "disabled sleepthrough must trip"
[[ -f "$repo/.gluerun-state/planner-backoff.json" ]] && fail "disabled sleepthrough must not arm"

echo "PASS: test-limit-window"
