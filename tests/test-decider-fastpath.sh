#!/usr/bin/env bash
set -euo pipefail

# T-F1 (decider fast-path) + T-E6 (infra-failure isolation) tests.
#
# Unit (gluerun_decider_fast_action):
#   - the full policy table at left>0 and left<=0 for every class;
#   - a same-class repeat -> empty (escalate to the model);
#   - GLUERUN_DECIDER_FAST=0 -> empty for everything.
#
# Driver-level (a GLUERUN_RUNNER stub stands in for the worker+auditor CLIs, keyed
# off --level / the prompt-file name, the same drop-in contract the real runners
# honor — final-message capture via --output-last-message):
#   - a gate-red attempt WITH retry budget takes the fast-path: NO
#     decider-prompt-*.md is created, a decider.fast_path event fires, and the
#     archived deciderAuthority is "policy";
#   - the same with GLUERUN_DECIDER_FAST=0 consults decide.sh: a decider-prompt is
#     created and the authority is "decider";
#   - an auditor that emits prose twice then a valid verdict: the worker runs
#     ONCE, the auditor runs 3x, the lease retryCount is unchanged, and two
#     audit.infra_retry events fire;
#   - a worker that exits 124 (timeout) every try: a worker.infra_retry event
#     fires, NO decider-prompt is created (worker-infra parks via the fast-path),
#     and the attempt is archived/parked as worker-infra.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-decider-fastpath.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }
assert_file() { [[ -f "$1" ]] || fail "$2: missing file $1"; }
assert_no_file() { [[ ! -f "$1" ]] || fail "$2: unexpected file $1"; }

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/prompts" \
    "$root/docs/orchestration/tasks" \
    "$root/.gluerun-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$root/docs/orchestration/prompts/l2-test-first-developer.md"
  cp "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/auditor.md"
  cp "$ENGINE_HOME/templates/prompts/decider.md" "$root/docs/orchestration/prompts/decider.md"
  printf '.gluerun-state/\n.worktrees/\n.gluerun-evidence/\n' >"$root/.gitignore"
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  FIXTURE_TMP="$tmp"
  make_repo "$tmp/repo"
  export GLUERUN_ROOT="$tmp/repo"
  export GLUERUN_ORCH_DIR="$GLUERUN_ROOT/docs/orchestration"
  export GLUERUN_TASKS_DIR="$GLUERUN_ORCH_DIR/tasks"
  export GLUERUN_STATE_DIR="$GLUERUN_ROOT/.gluerun-state"
  export GLUERUN_RUNS_DIR="$GLUERUN_STATE_DIR/runs"
  export GLUERUN_INBOX_DIR="$GLUERUN_STATE_DIR/inbox"
  export GLUERUN_LEASES_DIR="$GLUERUN_STATE_DIR/leases"
  export GLUERUN_EVENTS_FILE="$GLUERUN_STATE_DIR/events.ndjson"
  export GLUERUN_STOP_FILE="$GLUERUN_STATE_DIR/STOP"
  export GLUERUN_WORKTREES_DIR="$GLUERUN_ROOT/.worktrees"
  export GLUERUN_TARGET_BRANCH="target"
  export GLUERUN_ENGINE_HOME="$ENGINE_HOME"
  unset GLUERUN_MODULES GLUERUN_WORKER_RED_LOG GLUERUN_WORKER_CONTRACT_EXTRA GLUERUN_RUNNER \
    GLUERUN_PREFLIGHT_REQUIRE_ACCEPTANCE GLUERUN_ATTEMPT_TASK_ID GLUERUN_ATTEMPT_STARTED_AT \
    GLUERUN_DECIDER_FAST GLUERUN_WORKER_INFRA_MAX GLUERUN_AUDIT_INFRA_MAX 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib.sh"
}

write_generic_task() {
  cat >"$GLUERUN_TASKS_DIR/TASK-0001.md" <<'EOF'
# TASK-0001: Generic widget parser

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
}

# ============================== Unit: fast-path table ==========================
test_fast_action_table() {
  with_fixture
  unset GLUERUN_DECIDER_FAST

  # left>0 (budget remains): retry_count=0 max_retries=3 -> left=3.
  local prev="" out
  for cls in gate-red worker-no-packet packet-invalid no-changes commit-failed; do
    out="$(gluerun_decider_fast_action "$cls" 0 3 "$prev")"
    assert_eq "$out" "retry" "fast table $cls left>0"
    out="$(gluerun_decider_fast_action "$cls" 3 3 "$prev")"
    assert_eq "$out" "escalate-parked" "fast table $cls left<=0"
  done

  out="$(gluerun_decider_fast_action scope-violation 0 3 "$prev")"
  assert_eq "$out" "amend-scope" "fast table scope-violation left>0"
  out="$(gluerun_decider_fast_action scope-violation 3 3 "$prev")"
  assert_eq "$out" "escalate-parked" "fast table scope-violation left<=0"

  # Infra classes park unconditionally (budget irrelevant).
  out="$(gluerun_decider_fast_action worker-infra 0 3 "$prev")"
  assert_eq "$out" "escalate-parked" "fast table worker-infra budget"
  out="$(gluerun_decider_fast_action worker-infra 3 3 "$prev")"
  assert_eq "$out" "escalate-parked" "fast table worker-infra no-budget"
  out="$(gluerun_decider_fast_action audit-infra 0 3 "$prev")"
  assert_eq "$out" "escalate-parked" "fast table audit-infra budget"
  out="$(gluerun_decider_fast_action audit-infra 3 3 "$prev")"
  assert_eq "$out" "escalate-parked" "fast table audit-infra no-budget"

  # audit-needs-fix: retry while budget remains, else EMPTY (model weighs waiver).
  out="$(gluerun_decider_fast_action audit-needs-fix 0 3 "$prev")"
  assert_eq "$out" "retry" "fast table audit-needs-fix left>0"
  out="$(gluerun_decider_fast_action audit-needs-fix 3 3 "$prev")"
  assert_eq "$out" "" "fast table audit-needs-fix left<=0 -> model"

  # Model-only classes -> empty regardless of budget.
  for cls in audit-blocked audit-needs-human audit-unknown secret-detected proof-skip-detected something-else; do
    out="$(gluerun_decider_fast_action "$cls" 0 3 "$prev")"
    assert_eq "$out" "" "fast table $cls -> model (budget)"
    out="$(gluerun_decider_fast_action "$cls" 3 3 "$prev")"
    assert_eq "$out" "" "fast table $cls -> model (no budget)"
  done
  echo "ok: fast-path table"
}

test_fast_action_repeat_and_disabled() {
  with_fixture

  # Same-class repeat escalates to the model (empty), even with budget.
  local out
  out="$(gluerun_decider_fast_action gate-red 0 3 gate-red)"
  assert_eq "$out" "" "fast repeat: same class -> model"
  # A DIFFERENT prev still fast-paths.
  out="$(gluerun_decider_fast_action gate-red 0 3 scope-violation)"
  assert_eq "$out" "retry" "fast repeat: different prev still fast-paths"

  # GLUERUN_DECIDER_FAST=0 -> empty for everything (force the model path).
  for cls in gate-red scope-violation worker-infra audit-infra audit-needs-fix no-changes; do
    out="$(GLUERUN_DECIDER_FAST=0 gluerun_decider_fast_action "$cls" 0 3 "")"
    assert_eq "$out" "" "fast disabled: $cls -> empty"
  done
  echo "ok: fast-path repeat + disabled"
}

# ============================== Driver-level ===================================
# A sequencing runner: auditor verdict follows MOCK_AUDIT_VERDICT_SEQ by call #.
make_seq_runner() {
  local stub="$1"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
level=""; out=""; chdir=""; prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="$2"; shift 2 ;;
    -C) chdir="$2"; shift 2 ;;
    --output-last-message) out="$2"; shift 2 ;;
    --prompt-file) prompt="$2"; shift 2 ;;
    --run-id) shift 2 ;;
    *) shift ;;
  esac
done
cdir="${MOCK_COUNTER_DIR:-/tmp}"; mkdir -p "$cdir"
# Decider call (decide.sh dispatches the decider prompt at --level readonly). Emit
# a decider-verdict action so the fast-disabled path actually advances.
if [[ "$prompt" == *decider-prompt-* ]]; then
  fc="${prompt##*decider-prompt-}"
  fc="${fc%.md}"
  python3 - "$out" "${MOCK_DECIDER_ACTION:-retry}" "$fc" <<'PY'
import json, sys
json.dump({"schema":"gluerun.orchestration.decider-verdict.v0","failureClass":sys.argv[3],"taskId":"TASK-0001","action":sys.argv[2],"rationale":"mock decider","nextOwner":"l1"}, open(sys.argv[1],"w"))
PY
  exit 0
fi
if [[ "$level" == "l2" ]]; then
  wc_file="$cdir/worker-calls"; n=0; [[ -f "$wc_file" ]] && n="$(cat "$wc_file")"; n=$((n+1)); printf '%s' "$n" >"$wc_file"
  rc="${MOCK_WORKER_RC:-0}"
  if [[ "$rc" -ne 0 ]]; then : >"$out"; exit "$rc"; fi
  # Clean run (rc 0) but no packet (prose/empty output): must classify as
  # worker-no-packet via the main retry loop, NOT worker-infra.
  if [[ "${MOCK_WORKER_EMPTY:-0}" == "1" ]]; then : >"$out"; exit 0; fi
  mkdir -p "$chdir/internal/widget" "$chdir/.gluerun-evidence"
  printf 'package widget\n// v%s\n' "$n" >"$chdir/internal/widget/parser.go"
  printf 'red\n' >"$chdir/.gluerun-evidence/red.log"; printf 'green\n' >"$chdir/.gluerun-evidence/green.log"; printf 'reg\n' >"$chdir/.gluerun-evidence/regression.log"
  python3 - "$out" <<'PY'
import json, sys
json.dump({"schema":"gluerun.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"uncommitted","workspace":"/tmp","ownedFiles":["internal/widget/parser.go"],"changedFiles":["internal/widget/parser.go"],"commands":[{"cmd":"true","exitCode":0,"logRef":""}],"tests":[{"name":"t","phase":"red","status":"fail","logRef":""},{"name":"t","phase":"green","status":"pass","logRef":""}],"evidence":[{"kind":"red","ref":".gluerun-evidence/red.log"}],"blockers":[],"nextAction":"audit","createdAt":"2026-01-01T00:00:00Z"}, open(sys.argv[1],"w"))
PY
  exit 0
fi
ac_file="$cdir/audit-calls"; n=0; [[ -f "$ac_file" ]] && n="$(cat "$ac_file")"; n=$((n+1)); printf '%s' "$n" >"$ac_file"
prose_tries="${MOCK_AUDIT_PROSE_TRIES:-0}"
if [[ "$n" -le "$prose_tries" ]]; then printf 'prose, no JSON here\n' >"$out"; exit 0; fi
# Per-call verdict from the sequence (1-indexed by parseable-call order). The prose
# tries do not advance the verdict sequence; subtract them.
seq=(${MOCK_AUDIT_VERDICT_SEQ:-accepted})
vi=$((n - prose_tries - 1)); [[ "$vi" -lt 0 ]] && vi=0
verdict="${seq[$vi]:-${seq[${#seq[@]}-1]}}"
python3 - "$out" "$verdict" <<'PY'
import json, sys
json.dump({"schema":"gluerun.orchestration.audit-verdict.v0","taskId":"TASK-0001","runId":"r","branch":"agent/widget/TASK-0001-generic","verdict":sys.argv[2],"evidenceReviewed":[],"commandsRun":[],"findings":[],"requiredFixes":[],"rationale":"ok"}, open(sys.argv[1],"w"))
PY
exit 0
STUB
  chmod +x "$stub"
}

# Fast-path provenance: attempt-1 audit-needs-fix (a fast-path 'retry' class) with
# budget, attempt-2 accepted. The needs-fix failure is resolved by the policy
# fast-path WITHOUT a model decider round-trip: NO decider-prompt-*.md is created,
# a decider.fast_path event fires, and the archived deciderAuthority is "policy".
test_driver_fastpath_provenance() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export GLUERUN_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters1"
  export MOCK_AUDIT_VERDICT_SEQ="needs-fix accepted"

  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "fast-path provenance run accepts ($out)"
  local prompts
  prompts="$(find "$GLUERUN_RUNS_DIR" -name 'decider-prompt-*.md' 2>/dev/null || true)"
  assert_eq "$prompts" "" "fast-path: no decider prompt created"
  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"decider.fast_path"' "fast-path event emitted"
  local idx
  idx="$(find "$GLUERUN_RUNS_DIR" -name index.json -path '*/attempts/*' | head -1)"
  assert_file "$idx" "fast-path: attempts index exists"
  assert_contains "$(cat "$idx")" '"deciderAuthority": "policy"' "fast-path: authority policy archived"
  assert_contains "$(cat "$idx")" '"deciderAction": "retry"' "fast-path: action retry archived"
  # retryCount IS bumped here (a real retry, not an infra retry).
  assert_eq "$(gluerun_lease_field TASK-0001 retryCount)" "1" "fast-path retry bumps retryCount"
  echo "ok: driver fast-path provenance (policy authority, no decider prompt)"
}

# Same needs-fix->accepted run but GLUERUN_DECIDER_FAST=0: decide.sh IS consulted
# (a decider prompt is created) and the authority is "decider".
test_driver_decider_when_fast_disabled() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export GLUERUN_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters2"
  export MOCK_AUDIT_VERDICT_SEQ="needs-fix accepted"
  export GLUERUN_DECIDER_FAST=0

  local out rc=0
  out="$(GLUERUN_DECIDER_TIMEOUT_SEC=60 "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "driver (fast disabled) run accepts ($out)"
  local prompts
  prompts="$(find "$GLUERUN_RUNS_DIR" -name 'decider-prompt-*.md' 2>/dev/null || true)"
  assert_contains "$prompts" "decider-prompt-audit-needs-fix.md" "fast disabled: decider prompt created"
  assert_not_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"decider.fast_path"' "fast disabled: no fast_path event"
  local idx
  idx="$(find "$GLUERUN_RUNS_DIR" -name index.json -path '*/attempts/*' | head -1)"
  assert_contains "$(cat "$idx")" '"deciderAuthority": "decider"' "fast disabled: authority decider archived"
  unset GLUERUN_DECIDER_FAST
  echo "ok: driver decider consulted when fast disabled"
}

# Auditor infra: prose x2 then a valid verdict. Worker runs ONCE; auditor 3x;
# lease retryCount unchanged; two audit.infra_retry events.
test_driver_audit_infra_retry() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export GLUERUN_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters3"
  export MOCK_AUDIT_PROSE_TRIES=2
  export MOCK_AUDIT_VERDICT_SEQ="accepted"
  export GLUERUN_AUDIT_INFRA_MAX=2

  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "audit-infra run accepts after fresh re-audits ($out)"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "1" "audit-infra: worker invoked exactly once"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "3" "audit-infra: auditor invoked 3x (1 + 2 infra retries)"
  local retries
  retries="$(gluerun_lease_field TASK-0001 retryCount)"
  assert_eq "$retries" "0" "audit-infra: lease retryCount unchanged"
  local infra_events
  infra_events="$(grep -c '"audit.infra_retry"' "$GLUERUN_EVENTS_FILE" || true)"
  assert_eq "$infra_events" "2" "audit-infra: two audit.infra_retry events"
  unset MOCK_AUDIT_PROSE_TRIES GLUERUN_AUDIT_INFRA_MAX
  echo "ok: driver audit-infra isolation (worker x1, auditor x3, retryCount=0)"
}

# Worker infra: worker exits 124 every try. worker.infra_retry fires; the
# fast-path parks worker-infra (no decider prompt); attempt archived worker-infra.
test_driver_worker_infra_parks() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export GLUERUN_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters4"
  export MOCK_WORKER_RC=124
  export GLUERUN_WORKER_INFRA_MAX=1

  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "worker-infra run parks (exit 3) ($out)"
  # Worker invoked 1 + 1 infra retry = 2 times; auditor never (worker phase failed).
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "2" "worker-infra: worker invoked 2x (1 + 1 retry)"
  assert_no_file "$MOCK_COUNTER_DIR/audit-calls" "worker-infra: auditor never invoked"
  local wevents
  wevents="$(grep -c '"worker.infra_retry"' "$GLUERUN_EVENTS_FILE" || true)"
  assert_eq "$wevents" "1" "worker-infra: one worker.infra_retry event"
  # Fast-path parks worker-infra: NO decider prompt created.
  local prompts
  prompts="$(find "$GLUERUN_RUNS_DIR" -name 'decider-prompt-*.md' 2>/dev/null || true)"
  assert_eq "$prompts" "" "worker-infra: no decider prompt (fast-path parked)"
  assert_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"decider.fast_path"' "worker-infra: fast_path event emitted"
  # Attempt archived as worker-infra with policy authority + escalate-parked.
  local idx
  idx="$(find "$GLUERUN_RUNS_DIR" -name index.json -path '*/attempts/*' | head -1)"
  assert_file "$idx" "worker-infra: attempts index"
  assert_contains "$(cat "$idx")" '"failureClass": "worker-infra"' "worker-infra: archived failureClass"
  assert_contains "$(cat "$idx")" '"deciderAuthority": "policy"' "worker-infra: archived authority policy"
  # The lease retryCount must NOT have been bumped by the infra retry.
  assert_eq "$(gluerun_lease_field TASK-0001 retryCount)" "0" "worker-infra: retryCount unchanged"
  unset MOCK_WORKER_RC GLUERUN_WORKER_INFRA_MAX
  echo "ok: driver worker-infra parks via fast-path (no decider prompt)"
}

# rc==0 but empty/prose worker output must classify as worker-no-packet (a real
# model run that produced no packet) and flow through the MAIN retry loop — NOT
# the worker-infra fast-path. Guards the rc==0 empty-output downgrade.
test_driver_empty_output_is_no_packet_not_infra() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-runner.sh"; make_seq_runner "$stub"
  export GLUERUN_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters5"
  export MOCK_WORKER_EMPTY=1
  export GLUERUN_MAX_RETRIES=1

  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "3" "empty-output run parks after budget ($out)"
  # Main loop: attempt 0 (worker-no-packet, retry) + attempt 1 (parked) = 2 worker calls.
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "2" "no-packet: worker invoked via main loop (2x)"
  assert_not_contains "$(cat "$GLUERUN_EVENTS_FILE")" '"worker.infra_retry"' "no-packet: NOT classified as worker-infra"
  local idx
  idx="$(find "$GLUERUN_RUNS_DIR" -name index.json -path '*/attempts/*' | head -1)"
  assert_contains "$(cat "$idx")" '"failureClass": "worker-no-packet"' "no-packet: archived worker-no-packet"
  # A real retry bumped the lease (infra retries never do).
  assert_eq "$(gluerun_lease_field TASK-0001 retryCount)" "1" "no-packet: retryCount bumped by real retry"
  unset MOCK_WORKER_EMPTY GLUERUN_MAX_RETRIES
  echo "ok: driver rc==0 empty output is worker-no-packet, not worker-infra"
}

test_fast_action_table
test_fast_action_repeat_and_disabled
test_driver_fastpath_provenance
test_driver_decider_when_fast_disabled
test_driver_audit_infra_retry
test_driver_worker_infra_parks
test_driver_empty_output_is_no_packet_not_infra

echo "decider-fastpath tests passed"
