#!/usr/bin/env bash
# Covers the sanctioned `cli/gluerun metrics` subcommand: a thin, read-only hook
# that delegates into the already-integrated engine/ctx-metrics.sh extractor
# (gluerun_ctx_metrics_json). Asserts the subcommand emits byte-identical output
# to the extractor over the same fixture runs dir + events file, mutates none of
# its inputs, writes no real .gluerun-state, fails safe on empty/missing inputs,
# and that dispatch for all other commands is byte-identical (metrics is purely
# additive and listed in usage()).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLUERUN="$ENGINE_HOME/cli/gluerun"
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

[[ -f "$GLUERUN" ]] || fail "cli/gluerun not present: $GLUERUN"
[[ -f "$EXTRACTOR" ]] || fail "extractor not present: $EXTRACTOR"

# --- Fixture: two runs' attempts indexes + an events log ---------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Hermetic engine home: run the CLI against a temp skeleton holding only the
# bits under test. Pinning GLUERUN_ENGINE_HOME to the live repo would make the
# no-side-effect assertion below vacuous-or-false depending on where the suite
# runs (a pristine task worktree has no .gluerun-state; the ops tree, where
# integrate gates run, always has one). resolve_engine_home only requires
# engine/lib.sh to exist, and the extractor is self-contained.
EHOME="$tmp/engine-home"
mkdir -p "$EHOME/engine" "$EHOME/cli"
: > "$EHOME/engine/lib.sh"
cp "$EXTRACTOR" "$EHOME/engine/ctx-metrics.sh"
cp "$GLUERUN" "$EHOME/cli/gluerun"
GLUERUN="$EHOME/cli/gluerun"
export GLUERUN_ENGINE_HOME="$EHOME"
runs="$tmp/runs"
events="$tmp/events.ndjson"
mkdir -p "$runs/RUN-A/attempts" "$runs/RUN-B/attempts"

cat > "$runs/RUN-A/attempts/index.json" <<'EOF'
{
  "schema": "gluerun.orchestration.attempts-index.v0",
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
  "schema": "gluerun.orchestration.attempts-index.v0",
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

# Ground truth: the extractor's own bytes over the same fixture.
( set -uo pipefail
  # shellcheck disable=SC1090
  source "$EXTRACTOR"
  gluerun_ctx_metrics_json "$runs" "$events"
) > "$tmp/expected.json" || fail "extractor failed producing ground-truth"

before="$(tree_hash "$runs")"
before_events="$(shasum "$events" | awk '{print $1}')"

# --- Delegation: `gluerun metrics --json` == extractor bytes -----------------
"$GLUERUN" metrics --json --runs-dir "$runs" --events-file "$events" \
  > "$tmp/cli.json" 2>"$tmp/cli.err" \
  || fail "gluerun metrics --json exited non-zero: $(cat "$tmp/cli.err")"

cmp -s "$tmp/expected.json" "$tmp/cli.json" \
  || fail "gluerun metrics output not byte-identical to extractor: $(diff "$tmp/expected.json" "$tmp/cli.json" | head)"

# schema value + sorted keys + trailing newline (documented contract).
python3 - "$tmp/cli.json" <<'PY' || fail "metrics JSON did not match documented contract"
import json, sys
raw = open(sys.argv[1], "rb").read()
assert raw.endswith(b"\n"), "output must end with a trailing newline"
m = json.loads(raw)
assert m["schema"] == "gluerun.orchestration.ctx-metrics.v0", m.get("schema")
# sorted-keys: re-dump with sort_keys and compare to the (stripped) bytes.
again = (json.dumps(m, indent=2, sort_keys=True) + "\n").encode()
assert again == raw, "keys not emitted in sorted order"
assert m["aggregate"]["runsTotal"] == 2 and m["aggregate"]["attemptsTotal"] == 3
print("contract-ok")
PY

# --- Read-only: inputs byte-unchanged; no real .gluerun-state written --------
after="$(tree_hash "$runs")"
after_events="$(shasum "$events" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail "runs dir mutated by metrics subcommand (not read-only)"
[[ "$before_events" == "$after_events" ]] || fail "events file mutated by metrics subcommand"
[[ ! -e "$EHOME/.gluerun-state" ]] || fail "metrics wrote a real .gluerun-state artifact"

# --- Fail-safe: empty/missing runs dir + events file -> zeroed, exit 0 -------
"$GLUERUN" metrics --json --runs-dir "$tmp/no-such-runs" --events-file "$tmp/no-such.ndjson" \
  > "$tmp/empty.json" 2>"$tmp/empty.err" \
  || fail "metrics crashed on missing inputs (should fail safe): $(cat "$tmp/empty.err")"
python3 - "$tmp/empty.json" <<'PY' || fail "empty-input metrics not well-formed/zeroed"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["perTask"] == [], "perTask must be empty"
g = m["aggregate"]
assert g["runsTotal"] == 0 and g["attemptsTotal"] == 0 and g["acceptedRuns"] == 0
print("empty-ok")
PY

# --- Additive dispatch: help/usage lists metrics; other paths unchanged -------
"$GLUERUN" help > "$tmp/help.txt" 2>&1 || fail "gluerun help exited non-zero"
grep -q '^  metrics' "$tmp/help.txt" || fail "metrics not listed in usage()"

# Unknown-command path is unchanged (still errors, non-zero).
if "$GLUERUN" definitely-not-a-command >/dev/null 2>&1; then
  fail "unknown command should still exit non-zero"
fi

echo "ctx-metrics-cli tests passed"
