#!/usr/bin/env bash
set -euo pipefail

# P6 (0.5.0): `gluerun health --json` (compact digest, stable across idle
# calls), `gluerun gates` (malformed gates displayed not fatal), and
# `dag.sh next-areas --explain` exclusion reasons.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ops-health.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/gates" "$root/.gluerun-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "gluerun.orchestration.dag.v0",
  "nodes": [
    { "id": "a", "stage": "S0", "area": "core", "layer": "x", "kind": "contract", "dependsOn": [], "requiredCompletion": "done" },
    { "id": "b", "stage": "S1", "area": "core", "layer": "x", "kind": "contract", "dependsOn": ["a"], "requiredCompletion": "done" },
    { "id": "c", "stage": "S1", "area": "aux", "layer": "x", "kind": "contract", "dependsOn": [], "requiredCompletion": "done" }
  ]
}
EOF
cat >"$root/docs/orchestration/gates/a.gate-result.json" <<'EOF'
{"schema":"gluerun.orchestration.gate-result.v0","node":"a","status":"passed","authoritative":true,"evidenceClass":"grandfathered","evidence":[{"kind":"source-path","ref":"x","description":"t"}],"decidedBy":"test","recordedAt":"2026-06-01T00:00:00Z"}
EOF
printf '{broken json' >"$root/docs/orchestration/gates/c.gate-result.json"
git -C "$root" add . && git -C "$root" -c user.email=t@t -c user.name=t commit -q -m init

run_env() {
  env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
    GLUERUN_ORCH_DIR="$root/docs/orchestration" GLUERUN_TASKS_DIR="$root/docs/orchestration/tasks" \
    GLUERUN_LEASES_DIR="$root/.gluerun-state/leases" GLUERUN_WORKTREES_DIR="$root/.worktrees" \
    GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson" GLUERUN_TARGET_BRANCH=target "$@"
}

# 1. gates: passed + missing + malformed all displayed.
out="$(run_env bash "$SCRIPT_DIR/ops.sh" gates)"
assert_contains "$out" "passed 1/3" "gate count"
assert_contains "$out" "(no gate)" "missing gate shown"
assert_contains "$out" "invalid" "malformed gate shown, not fatal"

# 2. health --json: parses, has digest, digest stable across two idle calls.
j1="$(run_env bash "$SCRIPT_DIR/ops.sh" health --json)"
d1="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["digest"])' "$j1")"
sleep 1
j2="$(run_env bash "$SCRIPT_DIR/ops.sh" health --json)"
d2="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["digest"])' "$j2")"
[[ "$d1" == "$d2" ]] || fail "digest must be stable across idle calls ($d1 vs $d2)"
python3 -c 'import json,sys
d=json.loads(sys.argv[1])
assert d["gates"]["passed"]==1 and d["gates"]["total"]==3, d["gates"]
assert isinstance(d["attention"], list)
assert d["breaker"]["threshold"]==5' "$j1" || fail "health fields"

# State change -> digest changes.
touch "$root/.gluerun-state/STOP"
j3="$(run_env bash "$SCRIPT_DIR/ops.sh" health --json)"
d3="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["digest"])' "$j3")"
[[ "$d3" != "$d1" ]] || fail "digest must change when state changes"
assert_contains "$j3" "STOP sentinel present" "attention lists STOP"
rm -f "$root/.gluerun-state/STOP"

# 3. next-areas --explain: exclusion reasons for all three classes.
out="$(run_env bash "$SCRIPT_DIR/dag.sh" next-areas --explain)"
python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
frontier = {e["node"] for e in d["frontier"]}
excluded = {e["node"]: e for e in d.get("excluded", [])}
assert "b" in frontier or "b" in excluded, d
assert excluded["a"]["reason"] == "gate-passed", excluded
# c has a malformed gate (not passed) and no deps -> frontier
assert "c" in frontier, d
# b depends on a (passed) -> frontier
assert "b" in frontier, d
PY

# deps-not-gated reason: drop a's gate.
rm -f "$root/docs/orchestration/gates/a.gate-result.json"
out="$(run_env bash "$SCRIPT_DIR/dag.sh" next-areas --explain)"
python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
excluded = {e["node"]: e for e in d.get("excluded", [])}
assert excluded["b"]["reason"] == "deps-not-gated", excluded
assert excluded["b"]["unmetDeps"] == ["a"], excluded
PY

echo "PASS: test-ops-health"
