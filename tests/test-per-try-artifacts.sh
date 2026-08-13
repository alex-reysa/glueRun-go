#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER_CHECKOUT="$ENGINE_HOME"
CALLER_STATE_DIR="${SINGULAR_STATE_DIR:-$CALLER_CHECKOUT/.singular-state}"
CALLER_EVENTS_FILE="${SINGULAR_EVENTS_FILE:-$CALLER_STATE_DIR/events.ndjson}"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "$2: missing $1"; }
assert_not_file() { [[ ! -f "$1" ]] || fail "$2: unexpected $1"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
tree_inventory() {
  local root="$1" path rel digest target
  if [[ ! -e "$root" && ! -L "$root" ]]; then
    printf 'MISSING\t%s\n' "$root"
    return
  fi
  while IFS= read -r path; do
    rel="${path#"$root"}"
    [[ -n "$rel" ]] || rel=.
    if [[ -L "$path" ]]; then
      target="$(readlink "$path")"
      digest="$(printf '%s' "$target" | shasum -a 256 | awk '{print $1}')"
      printf 'L\t%s\t%s\n' "$rel" "$digest"
    elif [[ -f "$path" ]]; then
      digest="$(shasum -a 256 "$path" | awk '{print $1}')"
      printf 'F\t%s\t%s\n' "$rel" "$digest"
    elif [[ -d "$path" ]]; then
      printf 'D\t%s\n' "$rel"
    else
      printf 'O\t%s\n' "$rel"
    fi
  done < <(find "$root" -print | LC_ALL=C sort)
}
event_inventory() {
  local path="$1"
  if [[ -f "$path" ]]; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif [[ -e "$path" || -L "$path" ]]; then
    printf 'NOT-REGULAR\n'
  else
    printf 'MISSING\n'
  fi
}
assert_caller_unchanged() {
  local label="$1" current
  current="$(tree_inventory "$CALLER_CHECKOUT")"
  if [[ "$current" != "$caller_checkout_before" ]]; then
    diff -u <(printf '%s\n' "$caller_checkout_before") <(printf '%s\n' "$current") >&2 || true
    fail "$label: literal incoming caller checkout inventory changed: $CALLER_CHECKOUT"
  fi
  current="$(tree_inventory "$CALLER_STATE_DIR")"
  if [[ "$current" != "$caller_state_before" ]]; then
    diff -u <(printf '%s\n' "$caller_state_before") <(printf '%s\n' "$current") >&2 || true
    fail "$label: incoming state inventory changed: $CALLER_STATE_DIR"
  fi
  [[ "$(event_inventory "$CALLER_EVENTS_FILE")" == "$caller_event_before" ]] \
    || fail "$label: incoming event bytes changed: $CALLER_EVENTS_FILE"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
caller_checkout_before="$(tree_inventory "$CALLER_CHECKOUT")"
caller_state_before="$(tree_inventory "$CALLER_STATE_DIR")"
caller_event_before="$(event_inventory "$CALLER_EVENTS_FILE")"
run_dir="$tmp/run"
mkdir -p "$run_dir"
printf 'prompt\n' >"$run_dir/l2-active-prompt.md"

# Extract only the worker phase so this remains a focused unit test rather than
# provisioning a real worktree and provider session.
eval "$(awk '/^run_worker_phase\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$ENGINE_HOME/engine/l1-drive.sh")"

runner="$tmp/runner.sh"
cat >"$runner" <<'SH'
#!/usr/bin/env bash
count_file="$SINGULAR_TEST_RUNNER_COUNT"
count=0
[[ -f "$count_file" ]] && count="$(cat "$count_file")"
printf '%s\n' "$((count + 1))" >"$count_file"
if [[ "${SINGULAR_TEST_RUNNER_MODE:-retry}" == "resume" ]]; then
  if [[ "$count" -eq 0 ]]; then
    printf '{"call":"resume","exitCode":86}\n' >"$SINGULAR_RUNNER_RESULT_FILE"
    printf 'live-resume-envelope\n' >"${SINGULAR_RUNNER_RESULT_FILE%.json}.provider-envelope.raw"
    printf 'resume-refused-diagnostic\n' >&2
    exit 86
  fi
  printf '{"call":"resume-fallback","exitCode":0}\n' >"$SINGULAR_RUNNER_RESULT_FILE"
  printf 'live-resume-fallback-envelope\n' >"${SINGULAR_RUNNER_RESULT_FILE%.json}.provider-envelope.raw"
  printf 'fallback-output\n'
  exit 0
fi
if [[ "$count" -eq 0 ]]; then
  printf 'try-zero-timeout-marker\n'
  exit 124
fi
printf 'try-one-success-marker\n'
exit 0
SH
chmod +x "$runner"

export SINGULAR_TEST_RUNNER_COUNT="$tmp/runner-count"
export SINGULAR_WORKER_INFRA_MAX=1
task_id=TASK-0109
run_id=RUN-TRY-TEST
worktree="$tmp/worktree"
mkdir -p "$worktree"
l2_runner="$runner"
l2_prompt="$run_dir/l2-active-prompt.md"
session_meta_implementer="$tmp/session.json"
bootstrap_failure=""
bootstrap_log="$tmp/bootstrap.log"
worker_rc=0
attempt_failure=""
attempt_ctx=""
worker_strategy=""
worker_strategy_reason=""
SINGULAR_RUNNER_CONTRACT_ARGS=()

l1_status() { :; }
git() { printf 'deadbeef\n'; }
singular_prompt_sha() { printf 'promptsha\n'; }
singular_ctx_route_decide() { printf 'fresh test\n'; }
singular_append_event() { :; }
singular_ctx_rehydrate_authored_node() { return 1; }
singular_ctx_rehydrate_authored_triggers() { :; }
singular_ctx_rehydrate_authored_config_render() { :; }
rehydrate_inject_packet() { :; }
singular_runner_contract_prepare() { SINGULAR_RUNNER_CONTRACT_ARGS=(); }
singular_planner_failure_class() {
  local log="$1" rc="$2"
  printf '%s|%s|%s\n' "$(basename "$log")" "$rc" "$(cat "$log" 2>/dev/null || true)" \
    >>"$tmp/classifier-inputs"
  if [[ "$rc" -eq 124 ]]; then
    printf 'timeout\n'
  elif [[ "$rc" -eq 0 ]]; then
    printf 'clean\n'
  else
    printf 'empty-output\n'
  fi
}
singular_l1_prepare_worker_packet() { return 10; }

rc=0
run_worker_phase 3 >"$tmp/worker-phase-3.out" 2>&1 || rc=$?
[[ "$rc" -eq 1 && "$attempt_failure" == "worker-no-packet" ]] \
  || fail "successful retry must proceed to packet validation"
assert_file "$run_dir/worker-attempt-3-try-0.log" "try 0 log"
assert_file "$run_dir/worker-attempt-3-try-1.log" "try 1 log"
assert_contains "$(sed -n '1p' "$tmp/classifier-inputs")" \
  'worker-attempt-3-try-0.log|124|try-zero-timeout-marker' \
  "try 0 classification uses only try 0 output"
[[ "$(sed -n '2p' "$tmp/classifier-inputs")" == 'worker-attempt-3-try-1.log|0|try-one-success-marker' ]] \
  || fail "try 1 classification must use only its own successful output"
printf 'try-zero-timeout-marker\n' >"$tmp/expected-try-0"
printf 'try-one-success-marker\n' >"$tmp/expected-try-1"
cmp -s "$tmp/expected-try-0" "$run_dir/worker-attempt-3-try-0.log" \
  || fail "try 0 bytes differ from runner output"
cmp -s "$tmp/expected-try-1" "$run_dir/worker-attempt-3-try-1.log" \
  || fail "try 1 bytes differ from runner output"
{
  printf '%s\n' '--- worker try 0 (attempt 3) ---'
  cat "$tmp/expected-try-0"
  printf '%s\n' '--- worker try 1 (attempt 3) ---'
  cat "$tmp/expected-try-1"
} >"$tmp/expected-aggregate"
cmp -s "$tmp/expected-aggregate" "$run_dir/worker-codex.log" \
  || fail "aggregate separators, ordering, or copied bytes differ"

# Resume refusal bytes and the fresh fallback rerun each remain independently
# durable, while classification follows the fallback output for this try.
run_dir="$tmp/resume-run"
mkdir -p "$run_dir"
printf 'prompt\n' >"$run_dir/l2-active-prompt.md"
l2_prompt="$run_dir/l2-active-prompt.md"
rm -f "$SINGULAR_TEST_RUNNER_COUNT"
export SINGULAR_TEST_RUNNER_MODE=resume
export SINGULAR_WORKER_INFRA_MAX=0
singular_ctx_route_decide() { printf 'resume session-123\n'; }
attempt_failure=""
rc=0
run_worker_phase 4 >"$tmp/worker-phase-4.out" 2>&1 || rc=$?
[[ "$rc" -eq 1 && "$attempt_failure" == "worker-no-packet" ]] \
  || fail "resume fallback fixture must reach packet validation"
assert_file "$run_dir/worker-attempt-4-try-0.log" "resume-refused log"
assert_file "$run_dir/worker-attempt-4-try-0-resume-fallback.log" "resume fallback log"
resume_result="$run_dir/implementer-attempt-4-try-0-resume-runner-result.json"
resume_envelope="$run_dir/implementer-attempt-4-try-0-resume-runner-result.provider-envelope.raw"
fallback_result="$run_dir/implementer-attempt-4-try-0-resume-fallback-runner-result.json"
fallback_envelope="$run_dir/implementer-attempt-4-try-0-resume-fallback-runner-result.provider-envelope.raw"
assert_file "$resume_result" "live resumed-call runner result uses attempt 4 try 0 name"
assert_file "$resume_envelope" "live resumed-call provider envelope uses attempt 4 try 0 name"
assert_file "$fallback_result" "live fallback runner result stays in attempt 4 try 0"
assert_file "$fallback_envelope" "live fallback provider envelope stays in attempt 4 try 0"
[[ "$(cat "$resume_result")" == '{"call":"resume","exitCode":86}' ]] \
  || fail "live resumed-call result bytes are not from the rc-86 invocation"
[[ "$(cat "$resume_envelope")" == 'live-resume-envelope' ]] \
  || fail "live resumed-call envelope bytes differ"
[[ "$(cat "$fallback_result")" == '{"call":"resume-fallback","exitCode":0}' ]] \
  || fail "live fallback result bytes are not from the fresh invocation"
[[ "$(cat "$fallback_envelope")" == 'live-resume-fallback-envelope' ]] \
  || fail "live fallback envelope bytes differ"
assert_not_file "$run_dir/implementer-attempt-4-try-1-runner-result.json" \
  "resume fallback must not consume an infra try"
assert_contains "$(cat "$run_dir/worker-attempt-4-try-0.log")" \
  'resume-refused-diagnostic' "resume refusal diagnostic retained"
assert_contains "$(cat "$run_dir/worker-attempt-4-try-0-resume-fallback.log")" \
  'fallback-output' "fallback output retained"
assert_contains "$(cat "$run_dir/worker-codex.log")" \
  'resume-refused-diagnostic' "aggregate retains refused resume bytes"
assert_contains "$(cat "$run_dir/worker-codex.log")" \
  'fallback-output' "aggregate retains fallback bytes"
printf 'resume-refused-diagnostic\n' >"$tmp/expected-resume-refusal"
printf 'fallback-output\n' >"$tmp/expected-resume-fallback"
{
  printf '%s\n' '--- worker try 0 (attempt 4) ---'
  cat "$tmp/expected-resume-refusal"
  printf '%s\n' '--- worker resume-fallback try 0 (attempt 4) ---'
  cat "$tmp/expected-resume-fallback"
} >"$tmp/expected-resume-aggregate"
cmp -s "$tmp/expected-resume-refusal" "$run_dir/worker-attempt-4-try-0.log" \
  || fail "resume-refusal log bytes differ from live runner output"
cmp -s "$tmp/expected-resume-fallback" "$run_dir/worker-attempt-4-try-0-resume-fallback.log" \
  || fail "resume-fallback log bytes differ from live runner output"
cmp -s "$tmp/expected-resume-aggregate" "$run_dir/worker-codex.log" \
  || fail "resume aggregate headers, same-try ordering, or copied bytes differ"
assert_contains "$(tail -1 "$tmp/classifier-inputs")" \
  'worker-attempt-4-try-0-resume-fallback.log|0|fallback-output' \
  "fallback classification uses fallback output"

unset SINGULAR_TEST_RUNNER_MODE

# Archive selection is attempt-scoped and additive. Bind every production
# helper path to the first fixture before sourcing lib.sh, then rebind the
# stateful paths for each same-process iteration.
fixture_root="$tmp/archive-iteration-1/root"
fixture_state="$tmp/archive-iteration-1/state"
mkdir -p "$fixture_root" "$fixture_state"
export SINGULAR_ROOT="$fixture_root"
export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
export SINGULAR_ENGINE_DIR="$ENGINE_HOME/engine"
export SINGULAR_SCHEMA_DIR="$ENGINE_HOME/schemas"
export SINGULAR_ORCH_DIR="$fixture_root/docs/orchestration"
export SINGULAR_STATE_DIR="$fixture_state"
export SINGULAR_EVENTS_FILE="$fixture_state/events.ndjson"
export SINGULAR_TASKS_DIR="$fixture_root/docs/orchestration/tasks"
export SINGULAR_LEASES_DIR="$fixture_state/leases"
export SINGULAR_INBOX_DIR="$fixture_state/inbox"
export SINGULAR_RUNS_DIR="$fixture_state/runs"
export SINGULAR_WORKTREES_DIR="$fixture_root/.worktrees"
export SINGULAR_ORIGIN_STATE_FILE="$fixture_state/origin-state.json"
export SINGULAR_GIT_LOCK_DIR="$fixture_state/locks/git-op.lock"
export SINGULAR_STOP_FILE="$fixture_state/STOP"
export SINGULAR_STATUS_FILE="$fixture_state/STATUS.md"
export SINGULAR_BREAKER_FILE="$fixture_state/circuit.json"
export SINGULAR_PLANNER_BACKOFF_FILE="$fixture_state/planner-backoff.json"
export SINGULAR_PROVIDER_PRESSURE_FILE="$fixture_state/provider-pressure.json"
export SINGULAR_DISPATCH_DIR="$fixture_state/dispatch"
export SINGULAR_L1_LEASES_DIR="$fixture_state/l1-leases"
export SINGULAR_JSON_CONFIG_FILE="$tmp/fixture-config.absent.json"
export SINGULAR_CONFIG_FILE="$tmp/fixture-config.absent.sh"
export SINGULAR_LOCAL_CONFIG_FILE="$tmp/fixture-local-config.absent.sh"
[[ "$SINGULAR_STATE_DIR" == "$fixture_state" ]] \
  || fail "production helpers must be sourced with fixture-local state"
source "$ENGINE_HOME/engine/lib.sh"

archive_execution_count=0
iteration_event_hashes=()
run_archive_iteration() {
  local iteration="$1" archive event_count
  fixture_root="$tmp/archive-iteration-$iteration/root"
  fixture_state="$tmp/archive-iteration-$iteration/state"
  run_dir="$fixture_state/runs/resume-run-iteration-$iteration"
  mkdir -p "$fixture_root" "$fixture_state" "$run_dir"
  export SINGULAR_ROOT="$fixture_root"
  export SINGULAR_ORCH_DIR="$fixture_root/docs/orchestration"
  export SINGULAR_STATE_DIR="$fixture_state"
  export SINGULAR_EVENTS_FILE="$fixture_state/events.ndjson"
  export SINGULAR_TASKS_DIR="$fixture_root/docs/orchestration/tasks"
  export SINGULAR_LEASES_DIR="$fixture_state/leases"
  export SINGULAR_INBOX_DIR="$fixture_state/inbox"
  export SINGULAR_RUNS_DIR="$fixture_state/runs"
  export SINGULAR_WORKTREES_DIR="$fixture_root/.worktrees"
  export SINGULAR_ORIGIN_STATE_FILE="$fixture_state/origin-state.json"
  export SINGULAR_GIT_LOCK_DIR="$fixture_state/locks/git-op.lock"
  export SINGULAR_STOP_FILE="$fixture_state/STOP"
  export SINGULAR_STATUS_FILE="$fixture_state/STATUS.md"
  export SINGULAR_BREAKER_FILE="$fixture_state/circuit.json"
  export SINGULAR_PLANNER_BACKOFF_FILE="$fixture_state/planner-backoff.json"
  export SINGULAR_PROVIDER_PRESSURE_FILE="$fixture_state/provider-pressure.json"
  export SINGULAR_DISPATCH_DIR="$fixture_state/dispatch"
  export SINGULAR_L1_LEASES_DIR="$fixture_state/l1-leases"
  export SINGULAR_JSON_CONFIG_FILE="$tmp/archive-iteration-$iteration/config.absent.json"
  export SINGULAR_CONFIG_FILE="$tmp/archive-iteration-$iteration/config.absent.sh"
  export SINGULAR_LOCAL_CONFIG_FILE="$tmp/archive-iteration-$iteration/config.local.absent.sh"

  printf 'audit aggregate %s\n' "$iteration" >"$run_dir/auditor-codex.log"
  printf 'worker a1 %s\n' "$iteration" >"$run_dir/worker-attempt-1-try-0.log"
  printf 'worker a1 fallback %s\n' "$iteration" >"$run_dir/worker-attempt-1-try-0-resume-fallback.log"
  printf 'worker a2 %s\n' "$iteration" >"$run_dir/worker-attempt-2-try-0.log"
  printf '{}\n' >"$run_dir/implementer-attempt-1-try-0-runner-result.json"
  printf 'implementer envelope a1 %s\n' "$iteration" >"$run_dir/implementer-attempt-1-try-0-runner-result.provider-envelope.raw"
  printf '{}\n' >"$run_dir/auditor-attempt-1-try-0-runner-result.json"
  printf 'auditor envelope a1 %s\n' "$iteration" >"$run_dir/auditor-attempt-1-try-0-runner-result.provider-envelope.raw"
  printf '{}\n' >"$run_dir/implementer-attempt-2-try-0-runner-result.json"
  printf '{}\n' >"$run_dir/auditor-attempt-2-try-0-runner-result.json"
  printf 'implementer envelope a2 %s\n' "$iteration" >"$run_dir/implementer-attempt-2-try-0-runner-result.provider-envelope.raw"
  printf 'auditor envelope a2 %s\n' "$iteration" >"$run_dir/auditor-attempt-2-try-0-runner-result.provider-envelope.raw"
  SINGULAR_ATTEMPT_TASK_ID=TASK-0109 singular_attempt_archive \
    "$run_dir" 1 worker-infra unknown '' retry decider
  archive_execution_count=$((archive_execution_count + 1))

  archive="$run_dir/attempts/1"
  assert_file "$archive/auditor-codex.log" "iteration $iteration auditor aggregate archive"
  assert_file "$archive/worker-attempt-1-try-0.log" "iteration $iteration worker per-try archive"
  assert_file "$archive/worker-attempt-1-try-0-resume-fallback.log" "iteration $iteration worker fallback archive"
  assert_file "$archive/implementer-attempt-1-try-0-runner-result.json" "iteration $iteration implementer result archive"
  assert_file "$archive/auditor-attempt-1-try-0-runner-result.json" "iteration $iteration auditor result archive"
  assert_file "$archive/implementer-attempt-1-try-0-runner-result.provider-envelope.raw" "iteration $iteration implementer provider envelope archive"
  assert_file "$archive/auditor-attempt-1-try-0-runner-result.provider-envelope.raw" "iteration $iteration auditor provider envelope archive"
  assert_not_file "$archive/worker-attempt-2-try-0.log" "iteration $iteration other attempt worker log excluded"
  assert_not_file "$archive/implementer-attempt-2-try-0-runner-result.json" "iteration $iteration other attempt implementer result excluded"
  assert_not_file "$archive/auditor-attempt-2-try-0-runner-result.json" "iteration $iteration other attempt auditor result excluded"
  assert_not_file "$archive/implementer-attempt-2-try-0-runner-result.provider-envelope.raw" "iteration $iteration other attempt implementer envelope excluded"
  assert_not_file "$archive/auditor-attempt-2-try-0-runner-result.provider-envelope.raw" "iteration $iteration other attempt auditor envelope excluded"
  assert_file "$run_dir/auditor-codex.log" "iteration $iteration root auditor log retained"
  assert_file "$run_dir/worker-attempt-1-try-0.log" "iteration $iteration root worker log retained"
  event_count="$(grep -c '"type":"l1.attempt_archived"' "$SINGULAR_EVENTS_FILE" || true)"
  [[ "$event_count" -eq 1 && "$(wc -l <"$SINGULAR_EVENTS_FILE" | tr -d ' ')" -eq 1 ]] \
    || fail "iteration $iteration must contain exactly one synthetic archive event"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" \
    '"runId":"resume-run-iteration-'"$iteration"'"' \
    "iteration $iteration archive event uses its own run root"
  iteration_event_hashes[$iteration]="$(event_inventory "$SINGULAR_EVENTS_FILE")"
  assert_caller_unchanged "after archive iteration $iteration"
}

run_archive_iteration 1
run_archive_iteration 2
[[ "$archive_execution_count" -eq 2 ]] \
  || fail "archive fixture must execute twice in the same shell process"
assert_not_file "$tmp/archive-iteration-1/state/runs/resume-run-iteration-2/attempts/1/failure.txt" \
  "iteration 2 archive must not appear in iteration 1 root"
assert_not_file "$tmp/archive-iteration-2/state/runs/resume-run-iteration-1/attempts/1/failure.txt" \
  "iteration 1 archive must not appear in iteration 2 root"

drain_deadline=$((SECONDS + 5))
while [[ -n "$(jobs -pr)" ]]; do
  (( SECONDS < drain_deadline )) || {
    find "$tmp" \( -path '*/dispatch/*' -o -name 'events.ndjson' \) -print >&2
    fail "timed out draining archive fixture children"
  }
  sleep 0.05
done
for iteration in 1 2; do
  fixture_event="$tmp/archive-iteration-$iteration/state/events.ndjson"
  [[ "$(event_inventory "$fixture_event")" == "${iteration_event_hashes[$iteration]}" ]] \
    || fail "delayed write changed iteration $iteration fixture event log"
  [[ "$(grep -c '"type":"l1.attempt_archived"' "$fixture_event" || true)" -eq 1 ]] \
    || fail "iteration $iteration synthetic archive event count changed after drain"
  assert_contains "$(cat "$fixture_event")" \
    '"runId":"resume-run-iteration-'"$iteration"'"' \
    "iteration $iteration event remains fixture-local after drain"
done
assert_caller_unchanged "after bounded final drain"

echo "PASS: test-per-try-artifacts"
