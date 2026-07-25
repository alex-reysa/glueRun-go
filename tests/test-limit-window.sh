#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3 (missing: $2)"
}

run_lib() {
  GLUERUN_ROOT="$tmp" \
  GLUERUN_STATE_DIR="$tmp/state" \
  GLUERUN_RUNS_DIR="$tmp/state/runs" \
  bash -c "source '$ENGINE_HOME/engine/lib.sh'; $1"
}

make_evidence() {
  local root="$1" state="$2" run="$3" status="${4:-429}"
  local dir="$state/runs/$run"
  mkdir -p "$dir"
  printf '{"type":"turn.failed","error":{"status":%s,"code":"rate_limit_exceeded","message":"request rejected"}}\n' \
    "$status" >"$dir/codex-envelope.json"
  GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$state" GLUERUN_RUNS_DIR="$state/runs" \
    bash -c 'source "$1"; gluerun_runner_result_write codex "$2" planner planner-core "$3" 1 "$4" "" ""' \
      bash "$ENGINE_HOME/engine/lib.sh" "$run" "$dir/runner-result.json" "$dir/codex-envelope.json"
  printf '%s\n' "$dir/runner-result.json"
}

mkdir -p "$tmp/state/runs/RUN-noise"

# Raw logs/prompts are never evidence, regardless of how provider-like or
# legally realistic the embedded prose appears.
printf 'api_error_status":429 rate limit exceeded quota overloaded\n' \
  >"$tmp/state/runs/RUN-noise/worker-codex.log"
printf 'Policy: if a customer is rate limited, retain quota evidence.\n' \
  >"$tmp/state/runs/RUN-noise/l2-prompt.md"
run_lib gluerun_cycle_limit_window_evidence_json >/dev/null 2>&1 \
  && fail "raw logs/prompts must never be scanned"

# A schema-valid runner result bound to a provider terminal envelope is evidence.
evidence="$(make_evidence "$tmp" "$tmp/state" RUN-1)"
ev="$(run_lib gluerun_cycle_limit_window_evidence_json)" \
  || fail "structured runner result should be detected"
assert_contains "$ev" '"resultRef":"'"$evidence"'"' "evidence carries resultRef"
assert_contains "$ev" '"providerErrorRef"' "evidence carries providerErrorRef"

# Quota backoff refuses absent, raw-log, and tampered evidence.
if run_lib "gluerun_planner_backoff_set quota RUN-X node-x ''" 2>/dev/null; then
  fail "quota backoff without structured evidence must be refused"
fi
if run_lib "gluerun_planner_backoff_set quota RUN-X node-x '$tmp/state/runs/RUN-noise/worker-codex.log'" 2>/dev/null; then
  fail "quota backoff with a raw log must be refused"
fi
[[ -f "$tmp/state/planner-backoff.json" ]] \
  && fail "refused evidence must not write the backoff file"
assert_contains "$(cat "$tmp/state/events.ndjson")" \
  '"type":"backoff.rejected_invalid_evidence"' "refusal event"

# Valid evidence arms; the v0 compatibility logRef points to the normalized
# provider-error sidecar, never to the raw transcript.
run_lib "gluerun_planner_backoff_set quota RUN-X node-x '$evidence'" \
  || fail "validated result should arm quota backoff"
[[ -f "$tmp/state/planner-backoff.json" ]] || fail "backoff file missing"
backoff="$(cat "$tmp/state/planner-backoff.json")"
assert_contains "$backoff" '"evidenceRef": "'"$evidence"'"' "backoff binds runner result"
assert_contains "$backoff" '.provider-error.json' "compat logRef is normalized evidence"
out="$(run_lib gluerun_planner_backoff_clear)"
assert_contains "$out" "backoff cleared" "clear output"
[[ ! -f "$tmp/state/planner-backoff.json" ]] || fail "clear did not remove backoff"
assert_contains "$(cat "$tmp/state/events.ndjson")" '"type":"backoff.cleared"' "clear event"
out="$(run_lib gluerun_planner_backoff_clear)"
assert_contains "$out" "no active backoff" "clear is idempotent"

# Chokepoint integration: import rejections alone remain ineligible; a dispatch
# failure plus structured evidence arms sleep-through without tripping breaker.
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" branch agent/integration
mkdir -p "$repo/docs/orchestration/tasks"
make_evidence "$repo" "$repo/.gluerun-state" RUN-cycle >/dev/null

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

write_stub 0 1
out="$(auto_env bash "$ENGINE_HOME/engine/autonomate.sh" --once 2>&1)" || true
assert_contains "$out" "breaker -> 1" "import rejections must trip breaker"
[[ ! -f "$repo/.gluerun-state/planner-backoff.json" ]] \
  || fail "import rejections armed quota backoff"

rm -f "$repo/.gluerun-state/circuit.json"
touch "$repo/.gluerun-state/runs/RUN-cycle/runner-result.json"
write_stub 1 0
out="$(auto_env bash "$ENGINE_HOME/engine/autonomate.sh" --once 2>&1)" || true
assert_contains "$out" "armed quota backoff" "dispatch failure + evidence should arm"
[[ -f "$repo/.gluerun-state/planner-backoff.json" ]] || fail "backoff expected"
assert_contains "$(cat "$repo/.gluerun-state/planner-backoff.json")" \
  'runner-result.json' "backoff carries result evidence"

rm -f "$repo/.gluerun-state/planner-backoff.json" "$repo/.gluerun-state/circuit.json"
touch "$repo/.gluerun-state/runs/RUN-cycle/runner-result.json"
out="$(GLUERUN_DISABLE_LIMIT_SLEEPTHROUGH=1 auto_env bash "$ENGINE_HOME/engine/autonomate.sh" --once 2>&1)" || true
assert_contains "$out" "breaker -> 1" "disabled sleepthrough must trip"
[[ ! -f "$repo/.gluerun-state/planner-backoff.json" ]] \
  || fail "disabled sleepthrough armed backoff"

echo "PASS: test-limit-window"
