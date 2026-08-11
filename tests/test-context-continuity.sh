#!/usr/bin/env bash
set -euo pipefail

# END-TO-END continuity integration test (the composition proof).
#
# The continuity-core / decider-fastpath / session-affinity suites each cover a
# PIECE in isolation (fix-prompt rendering, re-audit delta, ledger lifecycle,
# capsules, attempts archive, fast-path table, the 10 resume gates). This test
# drives the REAL l1-drive.sh through a full multi-attempt cycle with a scripted
# mock runner and asserts the pieces COMPOSE — the artifacts and events the real
# loop wires together end-to-end:
#   attempt 1: worker commits clean -> auditor needs-fix (2 requiredFixes)
#   attempt 2: worker writes a DIFFERENT change (real fix diff) -> auditor accepted
# Then, in ONE flow:
#   1. cycle shape       (attempt-1 prompt == base; attempt-2 has fix sections)
#   2. re-audit delta    (attempt-1 audit == base; attempt-2 has diff range + contract)
#   3. ledger lifecycle  (open@1 -> resolved after acceptance)
#   4. capsules          (implementer head/scope; reviewer diffRange@2)
#   5. attempts archive  (2 entries, right failureClass per attempt)
#   6. strategy events   (fresh@1, implementer resume-or-valid-reason@2; reviewer
#                         never carries the implementer session id)
#   7. decider provenance (needs-fix->retry took the fast-path; no decider prompt)
#   8. final outcome     (exit 0 ACCEPTED, lease accepted, packet in inbox)
#
# Robustness: SINGULAR_SESSION_AFFINITY=1 + SINGULAR_DECIDER_FAST=1 set explicitly. If the
# attempt-2 implementer resume can't engage through the host gates, we assert
# strategy=fresh with a KNOWN gate reason rather than hard-failing — the point is
# the composition + event wiring, not forcing a resume.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-context-continuity.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in:"$'\n'"$1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in:"$'\n'"$1"; }
assert_file() { [[ -f "$1" ]] || fail "$2: missing file $1"; }

# Known resume-fresh reasons the decider can legitimately emit (session-affinity
# gates). If attempt-2 resume can't engage in the mock, the strategy MUST be a
# fresh run with one of these reasons — never a silent/empty/garbage reason.
KNOWN_FRESH_REASONS="disabled no-session no-session-id role-mismatch run-mismatch runner-changed prompt-template-changed expired head-rewritten worktree-moved resume-failed decide-error init"

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/prompts" \
    "$root/docs/orchestration/tasks" \
    "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$root/docs/orchestration/prompts/l2-test-first-developer.md"
  cp "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/auditor.md"
  printf '.singular-state/\n.worktrees/\n.singular-evidence/\n' >"$root/.gitignore"
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  FIXTURE_TMP="$tmp"
  make_repo "$tmp/repo"
  export SINGULAR_ROOT="$tmp/repo"
  export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
  export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
  export SINGULAR_STOP_FILE="$SINGULAR_STATE_DIR/STOP"
  export SINGULAR_WORKTREES_DIR="$SINGULAR_ROOT/.worktrees"
  export SINGULAR_TARGET_BRANCH="target"
  export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
  unset SINGULAR_MODULES SINGULAR_WORKER_RED_LOG SINGULAR_WORKER_CONTRACT_EXTRA SINGULAR_RUNNER \
    SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE SINGULAR_ATTEMPT_TASK_ID SINGULAR_ATTEMPT_STARTED_AT \
    SINGULAR_WORKER_INFRA_MAX SINGULAR_AUDIT_INFRA_MAX 2>/dev/null || true
  # Defaults, set EXPLICITLY for this composition proof.
  export SINGULAR_SESSION_AFFINITY=1
  export SINGULAR_DECIDER_FAST=1
  export SINGULAR_FIX_PROMPT_STRUCTURED=1
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib.sh"
}

write_generic_task() {
  cat >"$SINGULAR_TASKS_DIR/TASK-0001.md" <<'EOF'
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

# A full-cycle mock runner. It adapts make_seq_runner but additionally:
#   - writes a DIFFERENT changed file per worker call (real fix diff between heads),
#   - emits the requiredFixes "F-alpha"/"F-beta" on the attempt-1 needs-fix verdict,
#   - on the attempt-2 accepted verdict emits findingsStatus marking both resolved,
#   - honors --session-meta by writing a stable session id so resume can engage.
# Worker/auditor call counts are recorded under MOCK_COUNTER_DIR.
make_cycle_runner() {
  local stub="$1"
  cat >"$stub" <<STUB
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPT_DIR/lib.sh"
level=""; chdir=""; out=""; meta=""; resume=""; prompt=""; argv="\$*"
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --level) level="\$2"; shift 2 ;;
    -C|--worktree) chdir="\$2"; shift 2 ;;
    --output-last-message) out="\$2"; shift 2 ;;
    --session-meta) meta="\$2"; shift 2 ;;
    --resume-session) resume="\$2"; shift 2 ;;
    --prompt-file) prompt="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
cdir="\${MOCK_COUNTER_DIR:-/tmp/mock-counters}"; mkdir -p "\$cdir"

if [[ "\$level" == "l2" ]]; then
  wc_file="\$cdir/worker-calls"; n=0; [[ -f "\$wc_file" ]] && n="\$(cat "\$wc_file")"; n=\$((n+1)); printf '%s' "\$n" >"\$wc_file"
  printf '%s\n' "\$argv" >> "\$cdir/worker-argv.log"
  mkdir -p "\$chdir/internal/widget" "\$chdir/.singular-evidence"
  # A DIFFERENT change per attempt -> a real fix diff between the two audited heads.
  printf 'package widget\n// implementation revision %s\nfunc Parse() {}\n' "\$n" >"\$chdir/internal/widget/parser.go"
  printf 'red v%s\n' "\$n" >"\$chdir/.singular-evidence/red.log"
  printf 'green v%s\n' "\$n" >"\$chdir/.singular-evidence/green.log"
  printf 'regression v%s\n' "\$n" >"\$chdir/.singular-evidence/regression.log"
  [[ -n "\$out" ]] && python3 - "\$out" "\$n" <<'PY'
import json, sys
out, n = sys.argv[1], sys.argv[2]
json.dump({"schema":"singular.orchestration.state-packet.v0","packetId":"p"+n,"runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"uncommitted","workspace":"/tmp","ownedFiles":["internal/widget/parser.go"],"changedFiles":["internal/widget/parser.go"],"commands":[{"cmd":"true","exitCode":0,"logRef":""}],"tests":[{"name":"t","phase":"red","status":"fail","logRef":""},{"name":"t","phase":"green","status":"pass","logRef":""}],"evidence":[{"kind":"red","ref":".singular-evidence/red.log"}],"blockers":[],"nextAction":"finish the parser","createdAt":"2026-01-01T00:00:00Z"}, open(out,"w"))
PY
  # The runner's job: write a session id into the meta so the NEXT attempt can resume.
  [[ -n "\$meta" ]] && singular_codex_session_meta_write "\$meta" "WORKER-SID" "gpt-5.5" "medium" "\$chdir" 0
  exit 0
fi

# Auditor (readonly).
ac_file="\$cdir/audit-calls"; n=0; [[ -f "\$ac_file" ]] && n="\$(cat "\$ac_file")"; n=\$((n+1)); printf '%s' "\$n" >"\$ac_file"
printf '%s\n' "\$argv" >> "\$cdir/auditor-argv.log"
if [[ "\$n" -le 1 ]]; then
  # Attempt 1: needs-fix with two requiredFixes.
  [[ -n "\$out" ]] && python3 - "\$out" <<'PY'
import json, sys
json.dump({"schema":"singular.orchestration.audit-verdict.v0","taskId":"TASK-0001","runId":"r","branch":"agent/widget/TASK-0001-generic","verdict":"needs-fix","evidenceReviewed":["runs/r/gate-check.json"],"commandsRun":["git diff"],"findings":[],"requiredFixes":["F-alpha","F-beta"],"rationale":"two fixes required"}, open(sys.argv[1],"w"))
PY
else
  # Attempt 2: accepted AND findingsStatus resolving both prior findings.
  [[ -n "\$out" ]] && python3 - "\$out" <<'PY'
import json, hashlib, sys
def fid(t):
    norm=" ".join(str(t).replace("\`","").lower().split())
    return "f-"+hashlib.sha256(norm.encode()).hexdigest()[:12]
json.dump({"schema":"singular.orchestration.audit-verdict.v0","taskId":"TASK-0001","runId":"r","branch":"agent/widget/TASK-0001-generic","verdict":"accepted","evidenceReviewed":["runs/r/gate-check.json"],"commandsRun":["git diff"],"findings":[],"requiredFixes":[],"rationale":"both fixes verified","findingsStatus":{fid("F-alpha"):"resolved",fid("F-beta"):"resolved"}}, open(sys.argv[1],"w"))
PY
fi
[[ -n "\$meta" ]] && singular_codex_session_meta_write "\$meta" "REVIEWER-SID" "gpt-5.5" "high" "\$chdir" 0
exit 0
STUB
  chmod +x "$stub"
}

test_full_cycle_integration() {
  with_fixture
  write_generic_task
  local stub="$FIXTURE_TMP/mock-cycle-runner.sh"; make_cycle_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters"
  mkdir -p "$MOCK_COUNTER_DIR"

  # Pre-compute the two finding ids for the requiredFixes (text-derived).
  local id_alpha id_beta
  id_alpha="$(singular_finding_id 'F-alpha')"
  id_beta="$(singular_finding_id 'F-beta')"

  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?

  # ===== 8. Final outcome (assert first so a non-accept dumps the run output) ===
  assert_eq "$rc" "0" "run must exit 0 (ACCEPTED); driver output:"$'\n'"$out"
  assert_contains "$out" "ACCEPTED: TASK-0001" "final: ACCEPTED line"
  assert_eq "$(singular_lease_field TASK-0001 status)" "accepted" "final: lease status accepted"

  local run_dir
  run_dir="$(ls -d "$SINGULAR_RUNS_DIR"/RUN-* 2>/dev/null | head -1)"
  [[ -n "$run_dir" ]] || fail "no run dir produced"
  local run_id; run_id="$(basename "$run_dir")"
  local events; events="$(cat "$SINGULAR_EVENTS_FILE")"

  # Worker ran twice (two attempts), auditor twice.
  assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "2" "cycle: worker invoked twice"
  assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "2" "cycle: auditor invoked twice"

  # Packet landed in the inbox under the run id.
  local inbox_packet="$SINGULAR_INBOX_DIR/$run_id.json"
  assert_file "$inbox_packet" "final: accepted packet enqueued in inbox"
  assert_eq "$(singular_json_field "$inbox_packet" status)" "accepted" "final: inbox packet status accepted"

  # ===== 5. Attempts archive: 2 entries, right failureClass per attempt ========
  local idx="$run_dir/attempts/index.json"
  assert_file "$idx" "archive: attempts index"
  local arch
  arch="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["attempts"]; print(len(a), a[0]["n"], a[0]["failureClass"], a[1]["n"], repr(a[1]["failureClass"]), a[1]["auditVerdict"])' "$idx")"
  assert_eq "$arch" "2 1 audit-needs-fix 2 '' accepted" "archive: 2 entries, attempt1 audit-needs-fix, final accepted"
  # Each per-attempt dir holds the archived prompt + packet + audit.json.
  assert_file "$run_dir/attempts/1/l2-active-prompt.md" "archive: attempt-1 worker prompt"
  assert_file "$run_dir/attempts/1/packet.json" "archive: attempt-1 packet"
  assert_file "$run_dir/attempts/1/audit.json" "archive: attempt-1 audit.json"
  assert_file "$run_dir/attempts/2/l2-active-prompt.md" "archive: attempt-2 worker prompt"
  assert_file "$run_dir/attempts/2/packet.json" "archive: attempt-2 packet"
  assert_file "$run_dir/attempts/2/audit.json" "archive: attempt-2 audit.json"
  # The archived attempt-2 head differs from attempt-1 (a real fix diff).
  local head1 head2
  head1="$(python3 -c 'import json,sys; a={x["n"]:x for x in json.load(open(sys.argv[1]))["attempts"]}; print(a[1]["headSha"])' "$idx")"
  head2="$(python3 -c 'import json,sys; a={x["n"]:x for x in json.load(open(sys.argv[1]))["attempts"]}; print(a[2]["headSha"])' "$idx")"
  [[ -n "$head1" && -n "$head2" && "$head1" != "$head2" ]] \
    || fail "archive: attempt heads must differ (got '$head1' and '$head2')"

  # ===== 1. Cycle shape: attempt-1 worker prompt == base; attempt-2 has fixes ===
  cmp -s "$run_dir/l2-prompt.md" "$run_dir/attempts/1/l2-active-prompt.md" \
    || fail "cycle: attempt-1 worker prompt must be byte-identical to the base l2 prompt"
  local w2_file="$run_dir/attempts/2/l2-active-prompt.md"
  local w2; w2="$(cat "$w2_file")"
  assert_contains "$w2" "Authoritative findings" "cycle: attempt-2 fix prompt has findings header"
  assert_contains "$w2" "[from attempt 1] ($id_alpha) F-alpha" "cycle: attempt-2 carries F-alpha @attempt1"
  assert_contains "$w2" "[from attempt 1] ($id_beta) F-beta" "cycle: attempt-2 carries F-beta @attempt1"
  # Confinement: the Authoritative findings section is STRUCTURED (ledger-derived),
  # so the raw audit-verdict JSON byte-tail must NOT leak into it. The renderer
  # DOES (by design) tail the audit context into the class-scoped "### Evidence"
  # section for an audit-* failure, so we assert section-scoped confinement, not a
  # whole-file absence: the raw JSON lives ONLY under Evidence, never under findings.
  local w2_findings
  w2_findings="$(awk '/^### Authoritative findings/{f=1;next} /^### Evidence/{f=0} f' "$w2_file")"
  assert_contains "$w2_findings" "F-alpha" "cycle: findings section carries F-alpha"
  assert_not_contains "$w2_findings" '"schema": "singular.orchestration.audit-verdict' "cycle: no raw audit JSON in the findings section"
  assert_not_contains "$w2_findings" '"requiredFixes":' "cycle: no raw audit JSON fields in the findings section"

  # ===== 2. Re-audit delta: attempt-1 audit == base; attempt-2 has diff+contract =
  cmp -s "$run_dir/auditor-prompt.md" "$run_dir/attempts/1/auditor-active-prompt.md" \
    || fail "re-audit: attempt-1 auditor prompt must be byte-identical to the base auditor prompt"
  local a2; a2="$(cat "$run_dir/attempts/2/auditor-active-prompt.md")"
  assert_contains "$a2" "$head1..$head2" "re-audit: attempt-2 carries the fix diff range sha1..sha2"
  assert_contains "$a2" '"findingsStatus"' "re-audit: attempt-2 carries the findingsStatus output-contract line"
  assert_contains "$a2" "Fix diff since your last audit" "re-audit: attempt-2 has the diff section"

  # ===== 3. Ledger lifecycle: open@1 then resolved after acceptance ============
  # The live ledger reflects the FINAL state (resolved); the attempt-1 archived
  # prompt already proved both were open@1, but assert the ledger entries too.
  local ledger="$run_dir/findings-status.json"
  assert_file "$ledger" "ledger: findings-status.json present"
  assert_eq "$(python3 -c 'import json,sys; f={x["id"]:x for x in json.load(open(sys.argv[1]))["findings"]}; e=f[sys.argv[2]]; print(e["status"], e["firstSeenAttempt"])' "$ledger" "$id_alpha")" \
    "resolved 1" "ledger: F-alpha resolved, firstSeen@1"
  assert_eq "$(python3 -c 'import json,sys; f={x["id"]:x for x in json.load(open(sys.argv[1]))["findings"]}; e=f[sys.argv[2]]; print(e["status"], e["firstSeenAttempt"])' "$ledger" "$id_beta")" \
    "resolved 1" "ledger: F-beta resolved, firstSeen@1"
  local resolved_by
  resolved_by="$(python3 -c 'import json,sys; f={x["id"]:x for x in json.load(open(sys.argv[1]))["findings"]}; print(f[sys.argv[2]]["resolvedBy"])' "$ledger" "$id_alpha")"
  case "$resolved_by" in
    audit-accepted|auditor-status) : ;;
    *) fail "ledger: F-alpha resolvedBy must be audit-accepted|auditor-status, got '$resolved_by'" ;;
  esac

  # ===== 4. Capsules: implementer head/scope; reviewer diffRange@2 =============
  local icap="$run_dir/implementer-capsule.json"
  assert_file "$icap" "capsule: implementer capsule present"
  assert_eq "$(singular_json_field "$icap" headSha)" "$head2" "capsule: implementer headSha == new commit"
  assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ownedFiles"])' "$icap")" \
    "['internal/widget/parser.go']" "capsule: implementer ownedFiles == current scope"
  local rcap="$run_dir/reviewer-capsule.json"
  assert_file "$rcap" "capsule: reviewer capsule present"
  assert_eq "$(singular_json_field "$rcap" auditedHeadSha)" "$head2" "capsule: reviewer auditedHeadSha == attempt-2 head"
  assert_eq "$(singular_json_field "$rcap" diffRange)" "$head1..$head2" "capsule: reviewer diffRange non-empty @attempt2"

  # ===== 6. Strategy events: fresh@1, resume-or-valid-reason@2; reviewer split ==
  # context.strategy_selected emitted for BOTH roles.
  assert_contains "$events" '"context.strategy_selected"' "strategy: event emitted"
  assert_contains "$events" '"role":"implementer"' "strategy: implementer event present"
  assert_contains "$events" '"role":"reviewer"' "strategy: reviewer event present"

  # Attempt-1 implementer strategy must be FRESH with reason no-session (no prior meta).
  local impl1
  impl1="$(python3 -c '
import json, sys
want = None
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except Exception: continue
    if e.get("type") != "context.strategy_selected": continue
    d = e.get("data", {})
    if d.get("role") == "implementer" and d.get("attempt") == 1:
        want = (d.get("strategy"), d.get("reason"))
print("%s %s" % want if want else "MISSING")' "$SINGULAR_EVENTS_FILE")"
  assert_eq "$impl1" "fresh no-session" "strategy: attempt-1 implementer is fresh/no-session"

  # Attempt-2 implementer strategy: resume (gates pass) OR a KNOWN fresh reason.
  local impl2_strategy impl2_reason
  read -r impl2_strategy impl2_reason < <(python3 -c '
import json, sys
want = None
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except Exception: continue
    if e.get("type") != "context.strategy_selected": continue
    d = e.get("data", {})
    if d.get("role") == "implementer" and d.get("attempt") == 2:
        want = (d.get("strategy"), d.get("reason"))
print("%s %s" % want if want else "MISSING X")' "$SINGULAR_EVENTS_FILE")
  [[ "$impl2_strategy" != "MISSING" ]] || fail "strategy: attempt-2 implementer strategy event missing"
  if [[ "$impl2_strategy" == "resume" ]]; then
    OBSERVED_ATTEMPT2_STRATEGY="resume"
    # On a resume, the worker argv for the SECOND call must carry --resume-session WORKER-SID.
    local w2argv; w2argv="$(sed -n '2p' "$MOCK_COUNTER_DIR/worker-argv.log")"
    assert_contains "$w2argv" "--resume-session WORKER-SID" "strategy: attempt-2 worker argv resumes WORKER-SID"
  else
    assert_eq "$impl2_strategy" "fresh" "strategy: attempt-2 implementer must be resume or fresh, got '$impl2_strategy'"
    [[ " $KNOWN_FRESH_REASONS " == *" $impl2_reason "* ]] \
      || fail "strategy: attempt-2 fresh reason '$impl2_reason' is not a known gate reason ($KNOWN_FRESH_REASONS)"
    OBSERVED_ATTEMPT2_STRATEGY="fresh:$impl2_reason"
  fi

  # The reviewer strategy event must use the REVIEWER session, never the implementer's.
  # The reviewer session id (REVIEWER-SID) must never appear in the worker argv,
  # and WORKER-SID must never appear in the auditor argv.
  local rev_session_leak
  rev_session_leak="$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except Exception: continue
    if e.get("type") != "context.strategy_selected": continue
    d = e.get("data", {})
    if d.get("role") == "reviewer" and d.get("strategy") == "resume":
        # A reviewer resume must carry the reviewer session, NEVER the worker one.
        if d.get("sessionId") == "WORKER-SID":
            print("LEAK"); sys.exit(0)
print("OK")' "$SINGULAR_EVENTS_FILE")"
  assert_eq "$rev_session_leak" "OK" "strategy: reviewer strategy event never uses the implementer session id"
  if grep -q -- "WORKER-SID" "$MOCK_COUNTER_DIR/auditor-argv.log"; then
    fail "strategy: auditor argv leaked the implementer session id (WORKER-SID)"
  fi

  # ===== 7. Decider provenance: needs-fix -> retry took the fast-path ==========
  assert_contains "$events" '"decider.fast_path"' "decider: fast_path event emitted"
  local fp_fc
  fp_fc="$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except Exception: continue
    if e.get("type") == "decider.fast_path":
        d = e.get("data", {}); print(d.get("failureClass"), d.get("action")); break' "$SINGULAR_EVENTS_FILE")"
  assert_eq "$fp_fc" "audit-needs-fix retry" "decider: fast-path resolved audit-needs-fix -> retry"
  # No decider prompt was ever rendered (the fast-path skips decide.sh entirely).
  local decider_prompts
  decider_prompts="$(find "$SINGULAR_RUNS_DIR" -name 'decider-prompt-*.md' 2>/dev/null || true)"
  assert_eq "$decider_prompts" "" "decider: no decider-prompt-*.md (fast-path skipped the model)"
  # The needs-fix retry bumped the lease (a real retry, not an infra retry).
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "1" "decider: needs-fix retry bumped retryCount"

  echo "ok: full continuity cycle (attempt-2 strategy: ${OBSERVED_ATTEMPT2_STRATEGY})"
}

test_full_cycle_integration

echo "context-continuity integration test passed"
