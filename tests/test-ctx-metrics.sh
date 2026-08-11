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
{"ts":"2026-07-11T00:00:01Z","type":"context.strategy_selected","message":"m","data":{"strategy":"fresh","reason":"no-prior-session"}}
{"ts":"2026-07-11T00:00:02Z","type":"context.strategy_selected","message":"m","data":{"strategy":"resume","reason":"resume"}}
{"ts":"2026-07-11T00:00:03Z","type":"l1.attempt_archived","message":"m","data":{"n":1}}
{"ts":"2026-07-11T00:00:04Z","type":"context.strategy_selected","message":"m","data":{"strategy":"resume","reason":"resume"}}
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
print("shape-ok")
PY

# --- Determinism: identical inputs -> byte-identical output ------------------
out2="$(singular_ctx_metrics_json "$runs" "$events")"
[[ "$out" == "$out2" ]] || fail "output not deterministic across identical runs"

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
print("empty-ok")
PY

# --- No-args default is also fail-safe (no runs/events configured) -----------
SINGULAR_RUNS_DIR="$empty_runs" SINGULAR_EVENTS_FILE="$missing_events" \
  singular_ctx_metrics_json >/dev/null \
  || fail "no-arg default invocation crashed instead of failing safe"

echo "ctx-metrics tests passed"
