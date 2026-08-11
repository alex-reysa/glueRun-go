#!/usr/bin/env bash
# Covers the read-only route-metrics extractor engine/ctx-route-metrics.sh: given a
# runs directory of singular.orchestration.attempts-index.v0 indexes and an events
# log, singular_ctx_route_metrics_json emits stable per-role, per-strategy
# outcome-split JSON (accepted vs rejected) WITHOUT mutating any input. The
# accepted/rejected classification MUST match engine/ctx-metrics.sh: a per-attempt
# failureClass that is "" / "accepted" / "none" counts as accepted, anything else
# rejected. Asserts the joint splits, absent-strategy exclusion, deterministic key
# ordering, byte-identical inputs after a run, and empty output for empty inputs.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACTOR="$ENGINE_HOME/engine/ctx-route-metrics.sh"

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
[[ "$(type -t singular_ctx_route_metrics_json)" == "function" ]] \
  || fail "singular_ctx_route_metrics_json is not defined by $EXTRACTOR"

# --- Fixture: two runs' attempts indexes with varied (role strategy, outcome) --
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
runs="$tmp/runs"
events="$tmp/events.ndjson"
mkdir -p "$runs/RUN-A/attempts" "$runs/RUN-B/attempts"

# RUN-A:
#  #1 worker=fresh reviewer=fresh  failureClass=gate   -> REJECTED
#  #2 worker=resume reviewer=resume failureClass=""    -> ACCEPTED
cat > "$runs/RUN-A/attempts/index.json" <<'EOF'
{
  "schema": "singular.orchestration.attempts-index.v0",
  "runId": "RUN-A",
  "taskId": "TASK-0002",
  "attempts": [
    {"n": 1, "failureClass": "gate",
     "workerStrategy": "fresh", "reviewerStrategy": "fresh", "dir": "attempts/1"},
    {"n": 2, "failureClass": "",
     "workerStrategy": "resume", "reviewerStrategy": "resume", "dir": "attempts/2"}
  ],
  "updatedAt": "2026-07-11T00:00:00Z"
}
EOF

# RUN-B:
#  #1 worker=fresh  (no reviewerStrategy)  failureClass=scope    -> REJECTED
#  #2 worker=fresh  reviewer=fresh         failureClass=none     -> ACCEPTED
#  #3 worker=resume reviewer=fresh         failureClass=accepted -> ACCEPTED
cat > "$runs/RUN-B/attempts/index.json" <<'EOF'
{
  "schema": "singular.orchestration.attempts-index.v0",
  "runId": "RUN-B",
  "taskId": "TASK-0003",
  "attempts": [
    {"n": 1, "failureClass": "scope",
     "workerStrategy": "fresh", "dir": "attempts/1"},
    {"n": 2, "failureClass": "none",
     "workerStrategy": "fresh", "reviewerStrategy": "fresh", "dir": "attempts/2"},
    {"n": 3, "failureClass": "accepted",
     "workerStrategy": "resume", "reviewerStrategy": "fresh", "dir": "attempts/3"}
  ],
  "updatedAt": "2026-07-11T00:00:00Z"
}
EOF

cat > "$events" <<'EOF'
{"ts":"2026-07-11T00:00:01Z","type":"context.strategy_selected","message":"m","data":{"strategy":"fresh","reason":"no-prior-session"}}
{"ts":"2026-07-11T00:00:02Z","type":"context.strategy_selected","message":"m","data":{"strategy":"resume","reason":"resume"}}
EOF

before="$(tree_hash "$runs")"
before_events="$(shasum "$events" | awk '{print $1}')"

out="$(singular_ctx_route_metrics_json "$runs" "$events")" \
  || fail "extractor exited non-zero on a valid fixture"
printf '%s' "$out" > "$tmp/out.json"

# --- Read-only: inputs byte-unchanged after the run --------------------------
after="$(tree_hash "$runs")"
after_events="$(shasum "$events" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail "runs dir mutated by extractor (not read-only)"
[[ "$before_events" == "$after_events" ]] || fail "events file mutated by extractor"

# --- Extractor appends no events / writes no files ---------------------------
[[ "$before_events" == "$(shasum "$events" | awk '{print $1}')" ]] \
  || fail "events file changed"

# --- Trailing newline so bytes can be pinned ---------------------------------
# (Capture raw, unstripped, since command substitution eats trailing newlines.)
singular_ctx_route_metrics_json "$runs" "$events" > "$tmp/raw.json"
[[ "$(tail -c1 "$tmp/raw.json" | od -An -tx1 | tr -d ' \n')" == "0a" ]] \
  || fail "output missing trailing newline"

# --- Assert the joint per-role, per-strategy outcome splits ------------------
python3 - "$tmp/out.json" <<'PY' || fail "route-metrics JSON did not match expected shape/values"
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)

def eq(got, want, label):
    if got != want:
        print(f"MISMATCH {label}: got={got!r} want={want!r}", file=sys.stderr)
        sys.exit(1)

eq(m.get("schema"), "singular.orchestration.ctx-route-metrics.v0", "schema")

splits = m.get("roleStrategyOutcomeSplits")
assert isinstance(splits, dict), "roleStrategyOutcomeSplits must be an object"

# worker: fresh accepted 1 (RUN-B#2) / rejected 2 (RUN-A#1, RUN-B#1);
#         resume accepted 2 (RUN-A#2, RUN-B#3) / rejected 0
eq(splits["worker"], {
    "fresh":  {"accepted": 1, "rejected": 2},
    "resume": {"accepted": 2, "rejected": 0},
}, "worker splits")

# reviewer: fresh accepted 2 (RUN-B#2, RUN-B#3) / rejected 1 (RUN-A#1);
#           resume accepted 1 (RUN-A#2) / rejected 0
# RUN-B#1 has no reviewerStrategy -> not counted for reviewer.
eq(splits["reviewer"], {
    "fresh":  {"accepted": 2, "rejected": 1},
    "resume": {"accepted": 1, "rejected": 0},
}, "reviewer splits")

print("shape-ok")
PY

# --- Classification parity with engine/ctx-metrics.sh ------------------------
# The route extractor's accepted/rejected split, aggregated per role across all
# strategies, must reconcile with ctx-metrics.sh's own strategy counts (which
# tally every attempt bearing that strategy field, regardless of outcome).
METRICS="$ENGINE_HOME/engine/ctx-metrics.sh"
[[ -f "$METRICS" ]] || fail "sibling extractor missing: $METRICS"
# shellcheck disable=SC1090
source "$METRICS" || fail "sourcing $METRICS failed"
metrics_out="$(singular_ctx_metrics_json "$runs" "$events")" \
  || fail "ctx-metrics extractor failed on fixture"
printf '%s' "$metrics_out" > "$tmp/metrics.json"
python3 - "$tmp/out.json" "$tmp/metrics.json" <<'PY' || fail "classification not consistent with ctx-metrics.sh"
import json, sys
route = json.load(open(sys.argv[1]))
metrics = json.load(open(sys.argv[2]))
splits = route["roleStrategyOutcomeSplits"]
agg = metrics["aggregate"]
for role, mkey in (("worker", "workerStrategyCounts"), ("reviewer", "reviewerStrategyCounts")):
    for strat, total in agg[mkey].items():
        s = splits[role].get(strat, {"accepted": 0, "rejected": 0})
        got = s["accepted"] + s["rejected"]
        if got != total:
            print(f"MISMATCH {role}/{strat}: split total={got} vs metrics count={total}",
                  file=sys.stderr)
            sys.exit(1)
print("parity-ok")
PY

# --- Determinism: identical inputs -> byte-identical output ------------------
out2="$(singular_ctx_route_metrics_json "$runs" "$events")"
[[ "$out" == "$out2" ]] || fail "output not deterministic across identical runs"

# --- Empty / missing runs dir -> empty splits, still well-formed -------------
empty_runs="$tmp/no-such-runs"
missing_events="$tmp/no-such-events.ndjson"
out_empty="$(singular_ctx_route_metrics_json "$empty_runs" "$missing_events")" \
  || fail "extractor crashed on missing inputs (should fail safe)"
printf '%s' "$out_empty" > "$tmp/empty.json"
python3 - "$tmp/empty.json" <<'PY' || fail "empty-input route-metrics not well-formed/empty"
import json, sys
m = json.load(open(sys.argv[1]))
eq_schema = m.get("schema") == "singular.orchestration.ctx-route-metrics.v0"
assert eq_schema, "schema wrong on empty input"
assert m["roleStrategyOutcomeSplits"] == {"worker": {}, "reviewer": {}}, \
    "empty input must yield empty per-role splits"
print("empty-ok")
PY

# --- Malformed index -> degrades to empty, never non-zero exit ---------------
mkdir -p "$tmp/bad/BAD/attempts"
printf 'not json at all' > "$tmp/bad/BAD/attempts/index.json"
singular_ctx_route_metrics_json "$tmp/bad" "$missing_events" >/dev/null \
  || fail "extractor exited non-zero on malformed index (should degrade)"

# --- No-arg default is also fail-safe ----------------------------------------
SINGULAR_RUNS_DIR="$empty_runs" SINGULAR_EVENTS_FILE="$missing_events" \
  singular_ctx_route_metrics_json >/dev/null \
  || fail "no-arg default invocation crashed instead of failing safe"

echo "ctx-route-metrics tests passed"
