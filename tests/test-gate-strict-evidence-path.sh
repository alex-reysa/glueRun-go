#!/usr/bin/env bash
# The engine must be able to satisfy its own strict gate validator.
#
# gate-check.sh built its refs from $GLUERUN_STATE_DIR, which is absolute, and
# gate_report.py writes --log-ref verbatim. dag.sh's safe_repo_artifact rejects
# an absolute ref before it checks anything else, so NO gate report the engine
# produced could ever back an evidenceClass=deterministic-proof gate-result --
# regardless of hashes, integrity or outcome.
#
# This stayed invisible because every strict test either hand-wrote its report
# with a repo-relative logRef, or drove promote-gate.sh (which already passed a
# relative --log-ref). So this test drives the chain that was actually broken:
# a report engine/gate-check.sh really wrote, cited as gate-report evidence,
# validated by engine/dag.sh. A hand-written report proves nothing here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

repo="$tmp/repo"
mkdir -p "$repo"
git -C "$tmp" init -q repo
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf '{"schemaVersion":"v2","targetBranch":"main"}\n' >"$repo/gluerun.config.json"
# The read-only guard writes its journal under .gluerun-state; without the
# ignore a porcelain comparison reports the engine's own bookkeeping.
printf '.gluerun-state/\n' >"$repo/.gitignore"
mkdir -p "$repo/docs/orchestration/gates" "$repo/docs/orchestration/tasks"
git -C "$repo" add -A
git -C "$repo" commit -qm init

run_gate_check() {
  local run_id="$1"; shift
  GLUERUN_ROOT="$repo" GLUERUN_ENGINE_HOME="$ROOT" \
    bash "$ROOT/engine/gate-check.sh" "$run_id" --task-id TASK-0001 -- "$@" >/dev/null 2>&1
}

# --- 1. the ref is repo-relative, the path stays absolute --------------------
run_gate_check RUN-STRICT true || fail "a passing gate command should exit 0"
report="$repo/.gluerun-state/runs/RUN-STRICT/gate-report.json"
[[ -f "$report" ]] || fail "gate-check.sh wrote no report"

python3 - "$report" "$repo" <<'PY' || fail "gate-check.sh ref/path split is wrong"
import json, os, sys
report, repo = sys.argv[1], sys.argv[2]
data = json.load(open(report, encoding="utf-8"))
ref = data.get("logRef")
assert not os.path.isabs(ref), f"logRef must be repository-relative, got {ref!r}"
assert ".." not in ref.split(os.sep), f"logRef must not escape the repo: {ref!r}"
assert os.path.isfile(os.path.join(repo, ref)), f"logRef does not resolve under the repo: {ref!r}"
path = data.get("logPath")
assert os.path.isabs(path), f"logPath must stay absolute for engine-local readers, got {path!r}"
assert os.path.isfile(path), f"logPath does not exist: {path!r}"
PY
pass "gate-check.sh cites a repo-relative logRef and keeps an absolute logPath"

# --- 2. the report survives strict dag.sh validation -------------------------
# Build the smallest gate-result.v1 that reaches validate_strict_gate_report:
# it fires only on schema v1 + passing + authoritative + deterministic-proof.
python3 - "$repo" "$report" <<'PY' || fail "could not build the strict gate fixture"
import hashlib, json, os, sys
repo, report_path = sys.argv[1], sys.argv[2]
report = json.load(open(report_path, encoding="utf-8"))
report_ref = os.path.relpath(report_path, repo)

def sha_file(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

task_ev = {"kind": "task-set", "ref": "docs/orchestration/tasks",
           "taskIds": [report["taskId"]]}
# Must match dag.sh's task_set_sha256 byte for byte.
task_ev["sha256"] = hashlib.sha256(json.dumps(
    {"ref": task_ev["ref"], "taskIds": task_ev["taskIds"]},
    ensure_ascii=False, sort_keys=True, separators=(",", ":"),
).encode("utf-8")).hexdigest()

gate = {
    "schema": "gluerun.orchestration.gate-result.v1",
    "node": "loc-00-contract",
    "status": "passed",
    "authoritative": True,
    "evidenceClass": "deterministic-proof",
    "verificationClassification": "passed",
    "evidence": [
        {"kind": "command-log", "ref": "gate-check", "command": report["command"],
         "exitCode": report["rawExitCode"], "logRef": report["logRef"],
         "sha256": report["logSha256"], "headSha": report["headSha"]},
        task_ev,
        {"kind": "gate-report", "ref": report_ref, "sha256": sha_file(report_path)},
    ],
    "gateReportRef": report_ref,
    "decidedBy": "gate-strict-evidence-path-test",
    "recordedAt": "2026-07-25T00:00:00Z",
}
gates = os.path.join(repo, "docs/orchestration/gates")
json.dump(gate, open(os.path.join(gates, "loc-00-contract.gate-result.json"), "w",
                    encoding="utf-8"), indent=2)
json.dump({"schema": "gluerun.orchestration.dag.v0", "nodes": [
    {"id": "loc-00-contract", "stage": "loc", "area": "loc", "layer": "contract",
     "kind": "build", "dependsOn": [], "requiredCompletion": "done"}]},
    open(os.path.join(repo, "docs/orchestration/dag.v0.json"), "w",
         encoding="utf-8"), indent=2)
PY

out=""
rc=0
out="$(GLUERUN_ROOT="$repo" GLUERUN_ENGINE_HOME="$ROOT" \
  bash "$ROOT/engine/dag.sh" area-gate loc-00-contract 2>&1)" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  printf '%s\n' "$out" >&2
  fail "a real gate-check.sh report could not back a deterministic-proof gate (exit $rc)"
fi
[[ "$out" == *"gate-passed"* ]] || fail "strict validation did not report the gate as passed: $out"
pass "a report gate-check.sh actually wrote backs a deterministic-proof gate-result"

# --- 3. the ref stays absolute when the state dir is outside the repo --------
# Not every deployment keeps GLUERUN_STATE_DIR inside the repo. There the strict
# path is legitimately unsatisfiable, and the honest answer is the real absolute
# path -- never a fabricated repo-relative ref that resolves to nothing.
outside="$tmp/state-outside"
GLUERUN_ROOT="$repo" GLUERUN_ENGINE_HOME="$ROOT" GLUERUN_STATE_DIR="$outside" \
  bash "$ROOT/engine/gate-check.sh" RUN-OUTSIDE --task-id TASK-0001 -- true >/dev/null 2>&1 \
  || fail "gate-check.sh failed with an external state dir"
python3 - "$outside/runs/RUN-OUTSIDE/gate-report.json" <<'PY' \
  || fail "an out-of-repo log was not cited honestly"
import json, os, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
ref = data["logRef"]
assert os.path.isabs(ref), f"an out-of-repo log must keep its absolute ref, got {ref!r}"
assert os.path.isfile(ref), f"the absolute ref must still resolve: {ref!r}"
PY
pass "a log outside the repo keeps its absolute ref rather than a fabricated one"

echo "gate strict evidence path tests passed"
