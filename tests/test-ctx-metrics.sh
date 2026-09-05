#!/usr/bin/env bash
# Covers the read-only metrics extractor engine/ctx-metrics.sh: given a runs
# directory of singular.orchestration.attempts-index.v0 indexes and an events log,
# singular_ctx_metrics_json emits stable per-task + aggregate JSON WITHOUT mutating
# any input. Asserts documented fields, deterministic key ordering, byte-identical
# inputs after a run, and fail-safe zeroed output for empty/missing inputs.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACTOR="$ENGINE_HOME/engine/ctx-metrics.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Directory-tree fingerprint (path + content sha) so we can prove read-only.
tree_hash() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo "MISSING:$dir"; return 0; }
  find "$dir" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s ' "$f"; shasum "$f" | awk '{print $1}'
  done
}

# The extractor must exist and source cleanly (RED before it is written).
[[ -f "$EXTRACTOR" ]] || fail "extractor not present yet: $EXTRACTOR"
# shellcheck disable=SC1090
source "$EXTRACTOR" || fail "sourcing $EXTRACTOR failed"
[[ "$(type -t singular_ctx_metrics_json)" == "function" ]] \
  || fail "singular_ctx_metrics_json is not defined by $EXTRACTOR"

# --- Fixture: two runs' attempts indexes + an events log ---------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
runs="$tmp/runs"
events="$tmp/events.ndjson"
mkdir -p "$runs/RUN-A/attempts" "$runs/RUN-B/attempts"

cat > "$runs/RUN-A/attempts/index.json" <<'EOF'
{
  "schema": "singular.orchestration.attempts-index.v0",
  "runId": "RUN-A",
  "taskId": "TASK-0002",
  "attempts": [
    {"n": 1, "failureClass": "gate", "auditVerdict": "reject",
     "deciderAction": "retry", "deciderAuthority": "auditor",
     "workerStrategy": "fresh", "reviewerStrategy": "fresh", "dir": "attempts/1"},
    {"n": 2, "failureClass": "", "auditVerdict": "accept",
     "deciderAction": "accept", "deciderAuthority": "decider",
     "workerStrategy": "resume", "reviewerStrategy": "resume", "dir": "attempts/2"}
  ],
  "updatedAt": "2026-07-11T00:00:00Z"
}
EOF

cat > "$runs/RUN-B/attempts/index.json" <<'EOF'
{
  "schema": "singular.orchestration.attempts-index.v0",
  "runId": "RUN-B",
  "taskId": "TASK-0003",
  "attempts": [
    {"n": 1, "failureClass": "scope", "auditVerdict": "reject",
     "deciderAction": "retry", "deciderAuthority": "decider",
     "workerStrategy": "fresh", "dir": "attempts/1"}
  ],
  "updatedAt": "2026-07-11T00:00:00Z"
}
EOF

cat > "$events" <<'EOF'
{"ts":"2026-07-11T00:00:00Z","type":"campaign.started","message":"m","data":{"campaignId":"C-1"}}
{"ts":"2026-07-11T00:00:01Z","type":"autonomate.started","message":"m","data":{}}
{"ts":"2026-07-11T00:00:02Z","type":"context.strategy_selected","message":"m","data":{"role":"planner","provider":"fable","strategy":"fresh","reason":"no-prior-session"}}
{"ts":"2026-07-11T00:00:02Z","type":"runner.completed","message":"m","data":{"role":"planner","provider":"fable","outcome":"succeeded"}}
{"ts":"2026-07-11T00:00:02Z","type":"planner.generated","message":"m","data":{"taskId":"TASK-0002"}}
{"ts":"2026-07-11T00:00:03Z","type":"l1.dispatch_started","message":"m","data":{"taskId":"TASK-0002"}}
{"ts":"2026-07-11T00:00:04Z","type":"context.strategy_selected","message":"m","data":{"role":"implementer","provider":"fable","strategy":"resume","reason":"resume"}}
{"ts":"2026-07-11T00:00:04Z","type":"runner.completed","message":"m","data":{"role":"implementer","provider":"fable","outcome":"succeeded"}}
{"ts":"2026-07-11T00:00:04Z","type":"l1.task_accepted","message":"m","data":{"taskId":"TASK-0002"}}
{"ts":"2026-07-11T00:00:05Z","type":"packet.imported","message":"m","data":{"taskId":"TASK-0002","verdict":"needs-fix","acceptanceMode":"accepted-waiver"}}
{"ts":"2026-07-11T00:00:06Z","type":"operator.stop_requested","message":"m","data":{}}
{"ts":"2026-07-11T00:00:08Z","type":"operator.resume_requested","message":"m","data":{}}
{"ts":"2026-07-11T00:00:09Z","type":"plan.attempt_reused","message":"m","data":{"attemptIdentity":"abc"}}
{"ts":"2026-07-11T00:00:10Z","type":"integration.integrated","message":"m","data":{"taskId":"TASK-0002"}}
{"ts":"2026-07-11T00:00:11Z","type":"gate_promotion.completed","message":"m","data":{"node":"N-1"}}
{"ts":"2026-07-11T00:00:11Z","type":"context.strategy_selected","message":"m","data":{"role":"reviewer","strategy":"resume","reason":"resume"}}
{"ts":"2026-07-11T00:00:11Z","type":"runner.completed","message":"m","data":{"role":"auditor","provider":"claude","outcome":"succeeded"}}
EOF

# Runner-result sidecars (0.21.0): one per provider invocation. The archived
# copy under attempts/ must not be double-counted; a foreign schema is ignored.
mkdir -p "$runs/RUN-A/attempts/1"
cat > "$runs/RUN-A/implementer-attempt-1-try-0-runner-result.json" <<'EOF'
{"schema":"singular.orchestration.runner-result.v0","provider":"fable","role":"implementer",
 "outcome":"succeeded","failureClass":"none","usage":{"inputTokens":1000,"cachedInputTokens":800,"outputTokens":50}}
EOF
cp "$runs/RUN-A/implementer-attempt-1-try-0-runner-result.json" \
  "$runs/RUN-A/attempts/1/implementer-attempt-1-try-0-runner-result.json"
cat > "$runs/RUN-A/auditor-attempt-1-try-0-runner-result.json" <<'EOF'
{"schema":"singular.orchestration.runner-result.v0","provider":"claude","role":"auditor",
 "outcome":"succeeded","failureClass":"none","usage":{"inputTokens":500,"outputTokens":20}}
EOF
cat > "$runs/RUN-B/planner-runner-result.json" <<'EOF'
{"schema":"singular.orchestration.runner-result.v0","provider":"fable","role":"planner",
 "outcome":"failed","failureClass":"timeout"}
EOF
cat > "$runs/RUN-B/planner-try-1-runner-result.json" <<'EOF'
{"schema":"singular.orchestration.runner-result.v0","provider":"fable","role":"planner",
 "outcome":"succeeded","failureClass":"none","usage":{"inputTokens":2500,"outputTokens":100}}
EOF
cat > "$runs/RUN-B/not-a-runner-result.json" <<'EOF'
{"schema":"something.else","role":"planner"}
EOF

before="$(tree_hash "$runs")"
before_events="$(shasum "$events" | awk '{print $1}')"

out="$(singular_ctx_metrics_json "$runs" "$events")" \
  || fail "extractor exited non-zero on a valid fixture"
printf '%s' "$out" > "$tmp/out.json"

# --- Read-only: inputs byte-unchanged after the run --------------------------
after="$(tree_hash "$runs")"
after_events="$(shasum "$events" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail "runs dir mutated by extractor (not read-only)"
[[ "$before_events" == "$after_events" ]] || fail "events file mutated by extractor"

# --- Assert documented fields / values via python3 ---------------------------
python3 - "$tmp/out.json" <<'PY' || fail "metrics JSON did not match expected shape/values"
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)

def eq(got, want, label):
    if got != want:
        print(f"MISMATCH {label}: got={got!r} want={want!r}", file=sys.stderr)
        sys.exit(1)

# top-level shape
assert isinstance(m.get("perTask"), list), "perTask must be a list"
assert isinstance(m.get("aggregate"), dict), "aggregate must be an object"

# perTask is sorted by (taskId, runId) deterministically
keys = [(t["taskId"], t["runId"]) for t in m["perTask"]]
eq(keys, sorted(keys), "perTask ordering")
eq(len(m["perTask"]), 2, "perTask length")

by_run = {t["runId"]: t for t in m["perTask"]}
a = by_run["RUN-A"]
eq(a["taskId"], "TASK-0002", "RUN-A taskId")
eq(a["attemptsTotal"], 2, "RUN-A attemptsTotal")
eq(a["attemptsToAccept"], 2, "RUN-A attemptsToAccept")
eq(a["accepted"], True, "RUN-A accepted")
eq(a["failureClassCounts"], {"accepted": 1, "gate": 1}, "RUN-A failureClassCounts")
eq(a["auditVerdictCounts"], {"accept": 1, "reject": 1}, "RUN-A auditVerdictCounts")
eq(a["workerStrategyCounts"], {"fresh": 1, "resume": 1}, "RUN-A workerStrategyCounts")
eq(a["reviewerStrategyCounts"], {"fresh": 1, "resume": 1}, "RUN-A reviewerStrategyCounts")
eq(a["deciderAuthorityCounts"], {"auditor": 1, "decider": 1}, "RUN-A deciderAuthorityCounts")

b = by_run["RUN-B"]
eq(b["attemptsToAccept"], None, "RUN-B attemptsToAccept (never accepted)")
eq(b["accepted"], False, "RUN-B accepted")

# roles + ceremony (0.21.0): from runner-result sidecars, archives excluded.
roles = m["aggregate"]["roles"]
eq(sorted(roles), ["auditor", "implementer", "planner"], "roles present")
eq(roles["implementer"]["invocations"], 1, "implementer invocations (archive not double counted)")
eq(roles["implementer"]["inputTokens"], 1000, "implementer inputTokens")
eq(roles["implementer"]["cachedInputTokens"], 800, "implementer cachedInputTokens")
eq(roles["implementer"]["outputTokens"], 50, "implementer outputTokens")
eq(roles["planner"]["invocations"], 2, "planner invocations")
eq(roles["planner"]["outcomes"], {"failed": 1, "succeeded": 1}, "planner outcomes")
eq(roles["planner"]["failureClasses"], {"none": 1, "timeout": 1}, "planner failureClasses")
eq(roles["planner"]["usageRecords"], 1, "planner usageRecords")
eq(roles["planner"]["inputTokens"], 2500, "planner inputTokens")
c = m["aggregate"]["ceremony"]
eq(c["runnerResultsScanned"], 4, "ceremony scanned")
eq(c["modelInvocations"], 4, "ceremony modelInvocations")
eq(c["controlPlaneInvocations"], 3, "ceremony controlPlaneInvocations")
eq(c["implementerInvocations"], 1, "ceremony implementerInvocations")
eq(c["controlPlaneInvocationFraction"], 0.75, "ceremony invocation fraction")
eq(c["controlPlaneInputTokens"], 3000, "ceremony control tokens")
eq(c["implementerInputTokens"], 1000, "ceremony implementer tokens")
eq(c["controlPlaneInputTokenFraction"], 0.75, "ceremony token fraction")
eq(c["acceptedTasks"], 1, "ceremony acceptedTasks")
eq(c["integrations"], 1, "ceremony integrations")
eq(c["invocationsPerAcceptedTask"], 4.0, "ceremony invocationsPerAcceptedTask")
eq(c["invocationsPerIntegration"], 4.0, "ceremony invocationsPerIntegration")
eq(c["inputTokensPerIntegration"], 4000, "ceremony inputTokensPerIntegration")

# aggregate across all runs
g = m["aggregate"]
eq(g["runsTotal"], 2, "aggregate runsTotal")
eq(g["attemptsTotal"], 3, "aggregate attemptsTotal")
eq(g["acceptedRuns"], 1, "aggregate acceptedRuns")
eq(g["failureClassCounts"], {"accepted": 1, "gate": 1, "scope": 1}, "aggregate failureClassCounts")
eq(g["auditVerdictCounts"], {"accept": 1, "reject": 2}, "aggregate auditVerdictCounts")
eq(g["workerStrategyCounts"], {"fresh": 2, "resume": 1}, "aggregate workerStrategyCounts")
eq(g["reviewerStrategyCounts"], {"fresh": 1, "resume": 1}, "aggregate reviewerStrategyCounts")
eq(g["deciderAuthorityCounts"], {"auditor": 1, "decider": 2}, "aggregate deciderAuthorityCounts")
eq(g["strategySelectedReasonCounts"], {"no-prior-session": 1, "resume": 2}, "aggregate strategySelectedReasonCounts")

# campaign SLOs are evidence-backed: the fixture has an explicit campaign
# anchor, a closed STOP interval, concrete lifecycle events, and one identity
# re-entry.  New fields are additive; legacy aggregate fields above remain
# byte-compatible.
c = g["campaign"]
eq(c["availability"], {
    "eventsReadable": True,
    "timestampEvents": 17,
    "roleInvocationEvents": True,
    "providerInvocationEvents": True,
    "invocationSource": "runner.completed",
    "attemptIdentityEvents": True,
}, "campaign availability")
eq(c["state"], "active", "campaign active state")
eq(c["startedAt"], "2026-07-11T00:00:00Z", "campaign startedAt")
eq(c["endedAt"], None, "active campaign endedAt")
eq(c["startSource"], "campaign.started", "campaign startSource")
eq(c["observedEndedAt"], "2026-07-11T00:00:11Z", "campaign observedEndedAt")
eq(c["observedDurationSeconds"], 11, "campaign observedDurationSeconds")
eq(c["timeToFirstPlanningSeconds"], 2, "campaign planning latency")
eq(c["timeToFirstImplementationSeconds"], 3, "campaign implementation latency")
eq(c["timeToFirstIntegrationSeconds"], 10, "campaign integration latency")
eq(c["counters"], {
    "acceptedImports": 1,
    "acceptedImportsConfirmed": 1,
    "acceptedImportsAvailability": "available",
    "acceptedTasks": 1,
    "integrations": 1,
    "promotions": 1,
    "roleInvocationCounts": {"auditor": 1, "implementer": 1, "planner": 1},
    "providerInvocationCounts": {"claude": 1, "fable": 2},
    "modelCalls": 3,
    "plannerCriticCalls": 1,
    "plannerCriticCallFraction": 1 / 3,
    "identicalAttemptLineageReentries": 1,
}, "campaign counters")
eq(c["stop"], {
    "closedIntervals": 1,
    "openIntervals": 0,
    "closedSeconds": 2,
    "observedOpenSeconds": 0,
    "openSince": None,
}, "campaign STOP intervals")
eq(c["usefulThroughput"], {
    "integrationsPerObservedActiveHour": 400.0,
    "observedActiveSeconds": 9,
}, "campaign useful throughput")
print("shape-ok")
PY

# --- Determinism: identical inputs -> byte-identical output ------------------
out2="$(singular_ctx_metrics_json "$runs" "$events")"
[[ "$out" == "$out2" ]] || fail "output not deterministic across identical runs"

# --- Campaign boundary + private L1 runner evidence -------------------------
# The latest campaign ends explicitly while STOP is still open. Events after
# that matching end, an end for a different campaign, and pre-campaign private
# runner rows must not leak into the selected campaign. Private runner rows that
# duplicate a global/result-ref peer are counted exactly once.
boundary_runs="$tmp/boundary-runs"
boundary_events="$tmp/boundary-events.ndjson"
mkdir -p \
  "$boundary_runs/RUN-C/l1-staging/NODE-A" \
  "$boundary_runs/RUN-C/l1-staging/NODE-B" \
  "$boundary_runs/RUN-C/l1-staging/NODE-C"

cat > "$boundary_events" <<'EOF'
{"ts":"2026-07-11T00:00:00Z","type":"campaign.started","message":"old","data":{"campaignId":"C-OLD"}}
{"ts":"2026-07-11T00:00:01Z","type":"runner.completed","message":"old","data":{"runnerResultRef":"/results/old.json","role":"planner","provider":"old"}}
{"ts":"2026-07-11T00:00:02Z","type":"campaign.ended","message":"old","data":{"campaignId":"C-OLD"}}
{"ts":"2026-07-11T00:00:10Z","type":"campaign.started","message":"current","data":{"campaignId":"C-2"}}
{"ts":"2026-07-11T00:00:11Z","type":"planner.generated","message":"planned","data":{"taskId":"TASK-0100"}}
{"ts":"2026-07-11T00:00:12Z","type":"l1.task_accepted","message":"accepted","data":{"taskId":"TASK-0100","runId":"RUN-100"}}
{"ts":"2026-07-11T00:00:12Z","type":"l1.accepted_evidence_resume_completed","message":"replayed acceptance","data":{"taskId":"TASK-0100","runId":"RUN-100","resumeRunId":"RUN-RESUME"}}
{"ts":"2026-07-11T00:00:13Z","type":"l1.accepted_evidence_resume_completed","message":"evidence-only acceptance","data":{"taskId":"TASK-0101","runId":"RUN-101","resumeRunId":"RUN-RESUME-2"}}
{"ts":"2026-07-11T00:00:13Z","type":"integration.integrated","message":"integrated","data":{"taskId":"TASK-0100"}}
{"ts":"2026-07-11T00:00:13Z","type":"runner.completed","message":"global planner","data":{"runnerResultRef":"/results/shared.json","role":"planner","provider":"fable"}}
{"ts":"2026-07-11T00:00:14Z","type":"operator.stop_requested","message":"paused","data":{}}
{"ts":"2026-07-11T00:00:15Z","type":"campaign.ended","message":"wrong campaign","data":{"campaignId":"C-OTHER"}}
{"ts":"2026-07-11T00:00:20Z","type":"campaign.ended","message":"current ended","data":{"campaignId":"C-2"}}
{"ts":"2026-07-11T00:00:21Z","type":"l1.task_accepted","message":"too late","data":{"taskId":"TASK-POST","runId":"RUN-POST"}}
{"ts":"2026-07-11T00:00:22Z","type":"integration.integrated","message":"too late","data":{"taskId":"TASK-POST"}}
{"ts":"2026-07-11T00:00:23Z","type":"runner.completed","message":"too late","data":{"runnerResultRef":"/results/post.json","role":"auditor","provider":"post"}}
EOF

cat > "$boundary_runs/RUN-C/l1-staging/NODE-A/planner-events.ndjson" <<'EOF'
{"ts":"2026-07-11T00:00:13Z","type":"runner.completed","message":"duplicate private planner","data":{"runnerResultRef":"/results/shared.json","role":"planner","provider":"fable"}}
{"ts":"2026-07-11T00:00:13.500000Z","type":"runner.completed","message":"private critic","data":{"runnerResultRef":"/results/critic.json","role":"critic","provider":"claude"}}
EOF
cat > "$boundary_runs/RUN-C/l1-staging/NODE-B/planner-events.ndjson" <<'EOF'
{"ts":"2026-07-11T00:00:13.500000Z","type":"runner.completed","message":"duplicate private critic","data":{"runnerResultRef":"/results/critic.json","role":"critic","provider":"claude"}}
{"ts":"2026-07-11T00:00:21Z","type":"runner.completed","message":"private after end","data":{"runnerResultRef":"/results/private-post.json","role":"critic","provider":"late"}}
EOF
cat > "$boundary_runs/RUN-C/l1-staging/NODE-C/planner-events.ndjson" <<'EOF'
{"ts":"2026-07-11T00:00:01Z","type":"runner.completed","message":"private before campaign","data":{"runnerResultRef":"/results/private-old.json","role":"planner","provider":"old"}}
not-json-yet
EOF

boundary_before="$(tree_hash "$boundary_runs")"
boundary_events_before="$(shasum "$boundary_events" | awk '{print $1}')"
boundary_out="$(singular_ctx_metrics_json "$boundary_runs" "$boundary_events")" \
  || fail "extractor exited non-zero on bounded campaign/private-runner fixture"
printf '%s' "$boundary_out" > "$tmp/boundary-out.json"
[[ "$boundary_before" == "$(tree_hash "$boundary_runs")" ]] \
  || fail "private L1 event scan mutated the runs tree"
[[ "$boundary_events_before" == "$(shasum "$boundary_events" | awk '{print $1}')" ]] \
  || fail "bounded campaign scan mutated the global journal"

python3 - "$tmp/boundary-out.json" <<'PY' \
  || fail "bounded campaign/private-runner metrics were incorrect"
import json, sys
with open(sys.argv[1]) as stream:
    campaign = json.load(stream)["aggregate"]["campaign"]

assert campaign["state"] == "ended", campaign
assert campaign["startedAt"] == "2026-07-11T00:00:10Z", campaign
assert campaign["endedAt"] == "2026-07-11T00:00:20Z", campaign
assert campaign["observedEndedAt"] == "2026-07-11T00:00:20Z", campaign
assert campaign["observedDurationSeconds"] == 10, campaign
assert campaign["timeToFirstPlanningSeconds"] == 1, campaign
assert campaign["counters"]["acceptedTasks"] == 2, campaign
assert campaign["counters"]["integrations"] == 1, campaign
assert campaign["counters"]["roleInvocationCounts"] == {"critic": 1, "planner": 1}, campaign
assert campaign["counters"]["providerInvocationCounts"] == {"claude": 1, "fable": 1}, campaign
assert campaign["counters"]["modelCalls"] == 2, campaign
assert campaign["counters"]["plannerCriticCalls"] == 2, campaign
assert campaign["counters"]["plannerCriticCallFraction"] == 1, campaign
assert campaign["stop"] == {
    "closedIntervals": 0,
    "openIntervals": 1,
    "closedSeconds": 0,
    "observedOpenSeconds": 6,
    "openSince": "2026-07-11T00:00:14Z",
}, campaign
assert campaign["usefulThroughput"] == {
    "integrationsPerObservedActiveHour": 900.0,
    "observedActiveSeconds": 4,
}, campaign
print("boundary-ok")
PY

# --- Fail-safe: empty/missing inputs -> well-formed zeroed metrics -----------
empty_runs="$tmp/no-such-runs"
missing_events="$tmp/no-such-events.ndjson"
out_empty="$(singular_ctx_metrics_json "$empty_runs" "$missing_events")" \
  || fail "extractor crashed on missing inputs (should fail safe)"
printf '%s' "$out_empty" > "$tmp/empty.json"
python3 - "$tmp/empty.json" <<'PY' || fail "empty-input metrics not well-formed/zeroed"
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
assert m["perTask"] == [], "perTask must be empty"
g = m["aggregate"]
assert g["runsTotal"] == 0 and g["attemptsTotal"] == 0 and g["acceptedRuns"] == 0, "counts must be zeroed"
for k in ("failureClassCounts", "auditVerdictCounts", "workerStrategyCounts",
          "reviewerStrategyCounts", "deciderAuthorityCounts", "strategySelectedReasonCounts"):
    assert m["aggregate"][k] == {}, f"{k} must be empty"
c = m["aggregate"]["campaign"]
assert c["state"] is None and c["startedAt"] is None and c["endedAt"] is None
assert c["observedDurationSeconds"] is None
assert c["counters"]["integrations"] is None
assert c["stop"]["observedOpenSeconds"] is None
assert c["availability"] == {
    "eventsReadable": False,
    "timestampEvents": 0,
    "roleInvocationEvents": False,
    "providerInvocationEvents": False,
    "invocationSource": None,
    "attemptIdentityEvents": False,
}
print("empty-ok")
PY

# --- No-args default is also fail-safe (no runs/events configured) -----------
SINGULAR_RUNS_DIR="$empty_runs" SINGULAR_EVENTS_FILE="$missing_events" \
  singular_ctx_metrics_json >/dev/null \
  || fail "no-arg default invocation crashed instead of failing safe"

echo "ctx-metrics tests passed"
