#!/usr/bin/env bash
# An invalid DAG must never present as "no work to do".
#
# dag.sh emits a precise diagnostic on stderr and exits 2. Every caller in the
# loop piped that to /dev/null and reported an empty frontier, so a single
# malformed gate file was indistinguishable from an idle graph -- 34 minutes of
# a field run spent reading `frontier=0` while three nodes were ready.
#
# The information already existed; the engine threw it away. These tests pin
# that it now reaches the operator, and that it stays NON-fatal: the loop must
# keep dispatching, integrating and reaping other work.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

repo="$tmp/repo"
mkdir -p "$repo"
git -C "$tmp" init -q repo
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf '{"schemaVersion":"v2","targetBranch":"main"}\n' >"$repo/gluerun.config.json"
printf '.gluerun-state/\n' >"$repo/.gitignore"
mkdir -p "$repo/docs/orchestration/gates"
git -C "$repo" add -A
git -C "$repo" commit -qm init

write_dag() {
  cat >"$repo/docs/orchestration/dag.v0.json" <<'JSON'
{
  "schema": "gluerun.orchestration.dag.v0",
  "nodes": [
    {"id": "loc-00-contract", "stage": "loc", "area": "loc", "layer": "contract",
     "kind": "build", "dependsOn": [], "requiredCompletion": "done"}
  ]
}
JSON
}

# The exact shape from the field run: a gate whose evidence ref is absolute, so
# dag.sh's safe_repo_artifact refuses it.
write_broken_gate() {
  cat >"$repo/docs/orchestration/gates/loc-00-contract.gate-result.json" <<'JSON'
{
  "schema": "gluerun.orchestration.gate-result.v1",
  "node": "loc-00-contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "deterministic-proof",
  "evidence": [
    {"kind": "gate-report", "ref": "/private/tmp/nowhere/gate-report.json",
     "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}
  ],
  "gateReportRef": "/private/tmp/nowhere/gate-report.json",
  "decidedBy": "test",
  "recordedAt": "2026-07-25T00:00:00Z"
}
JSON
}

write_dag
write_broken_gate

export GLUERUN_ROOT="$repo"
export GLUERUN_ENGINE_HOME="$ROOT"
export GLUERUN_STATE_DIR="$repo/.gluerun-state"
export GLUERUN_TARGET_BRANCH=main

# --- 1. dag.sh itself still produces the diagnostic --------------------------
raw=""
raw_rc=0
raw="$(bash "$ROOT/engine/dag.sh" next-areas 2>&1)" || raw_rc=$?
[[ "$raw_rc" -ne 0 ]] || fail "an absolute evidence ref should make dag.sh exit non-zero"
contains "$raw" "safe repository-relative path" "dag.sh diagnostic"
pass "dag.sh reports the offending gate precisely"

# --- 2. the helper surfaces it instead of swallowing it ----------------------
out=""
rc=0
out="$(bash -c 'source "$1"; gluerun_dag_next_areas_json' _ "$ROOT/engine/lib.sh" 2>"$tmp/helper.err")" || rc=$?
[[ "$rc" -ne 0 ]] || fail "the helper must report failure, not an empty frontier"
[[ -z "$out" ]] || fail "the helper must print no frontier on failure, got: $out"
helper_err="$(cat "$tmp/helper.err")"
contains "$helper_err" "frontier evaluation failed" "helper warning"
contains "$helper_err" "safe repository-relative path" "helper carries the dag.sh diagnostic"
pass "the frontier helper surfaces the diagnostic rather than discarding it"

# --- 3. the event is emitted, and throttled ----------------------------------
events="$repo/.gluerun-state/events.ndjson"
[[ -f "$events" ]] || fail "no event log was written"
count_events() { grep -c '"type":"dag.evaluation_failed"' "$events" 2>/dev/null || true; }
[[ "$(count_events)" -ge 1 ]] || fail "dag.evaluation_failed was not emitted"
bash -c 'source "$1"; gluerun_dag_next_areas_json' _ "$ROOT/engine/lib.sh" >/dev/null 2>&1 || true
bash -c 'source "$1"; gluerun_dag_next_areas_json' _ "$ROOT/engine/lib.sh" >/dev/null 2>&1 || true
[[ "$(count_events)" -eq 1 ]] \
  || fail "the event must be throttled; the frontier is evaluated every cycle (got $(count_events))"
pass "dag.evaluation_failed is emitted once per distinct diagnostic"

# A CHANGED diagnostic must report again -- throttling keys on the message, so
# fixing one gate and breaking another cannot go unreported.
python3 - "$repo/docs/orchestration/gates/loc-00-contract.gate-result.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["evidence"][0]["ref"] = "/private/tmp/somewhere-else/gate-report.json"
data["gateReportRef"] = "/private/tmp/somewhere-else/gate-report.json"
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
bash -c 'source "$1"; gluerun_dag_next_areas_json' _ "$ROOT/engine/lib.sh" >/dev/null 2>&1 || true
[[ "$(count_events)" -eq 2 ]] \
  || fail "a changed diagnostic must re-emit (got $(count_events))"
pass "a changed diagnostic re-emits rather than being suppressed forever"

# --- 4. health names it instead of printing a bare count ---------------------
health="$(bash "$ROOT/engine/ops.sh" health 2>/dev/null || true)"
contains "$health" "UNEVALUABLE" "health frontier line"
not_contains "$health" "None ready node(s)" "health must not report an unevaluable DAG as a count"
health_json="$(bash "$ROOT/engine/ops.sh" health --json 2>/dev/null || true)"
python3 - "$health_json" <<'PY' || fail "health JSON does not distinguish unevaluable from empty"
import json, sys
doc = json.loads(sys.argv[1])
assert doc["frontier"].get("evaluable") is False, doc["frontier"]
assert any("could not be evaluated" in a for a in doc["attention"]), doc["attention"]
assert doc["ok"] is False, "an unevaluable DAG is not a healthy repo"
PY
pass "gluerun health separates 'unevaluable' from 'no ready work'"

# --- 5. doctor fails with the diagnostic, not a skip -------------------------
doctor_json="$(GLUERUN_ENGINE_HOME="$ROOT" python3 "$ROOT/engine/doctor.py" \
  --engine-home "$ROOT" --repo-root "$repo" --bash "$(command -v bash)" \
  --bash-version "$BASH_VERSION" --json 2>/dev/null || true)"
python3 - "$doctor_json" <<'PY' || fail "doctor does not report the unevaluable DAG"
import json, sys
doc = json.loads(sys.argv[1])
by_id = {c["id"]: c for c in doc["checks"]}
check = by_id["dag.evaluation"]
assert check["status"] == "fail", check
assert "cannot be evaluated" in check["message"], check["message"]
assert check["remediation"], "a failing check must say what to do"
assert check["details"]["diagnostic"], check["details"]
PY
pass "doctor reports the unevaluable DAG as a failure with the diagnostic"

# --- 6. a valid DAG is unaffected -------------------------------------------
rm -f "$repo/docs/orchestration/gates/loc-00-contract.gate-result.json"
rm -f "$events"
ok_out=""
ok_rc=0
ok_out="$(bash -c 'source "$1"; gluerun_dag_next_areas_json' _ "$ROOT/engine/lib.sh" 2>"$tmp/ok.err")" || ok_rc=$?
[[ "$ok_rc" -eq 0 ]] || fail "a valid DAG must evaluate cleanly (exit $ok_rc)"
[[ -s "$tmp/ok.err" ]] && fail "a valid DAG must warn about nothing: $(cat "$tmp/ok.err")"
python3 - "$ok_out" <<'PY' || fail "a valid DAG did not yield a frontier"
import json, sys
data = json.loads(sys.argv[1])
assert any(item.get("node") == "loc-00-contract" for item in data.get("frontier", [])), data
PY
[[ ! -f "$events" ]] || [[ "$(grep -c '"type":"dag.evaluation_failed"' "$events" || true)" -eq 0 ]] \
  || fail "a valid DAG must not emit dag.evaluation_failed"
health_ok="$(bash "$ROOT/engine/ops.sh" health 2>/dev/null || true)"
contains "$health_ok" "1 ready node(s)" "health reports the real count for a valid DAG"
pass "a valid DAG evaluates silently and reports its real frontier"

echo "dag evaluation diagnostics tests passed"
