#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p \
  "$root/docs/orchestration/gates/evidence" \
  "$root/docs/orchestration/tasks" \
  "$root/internal/storage" \
  "$root/internal/workflow" \
  "$root/.singular-state"

git -C "$root" init -q
git -C "$root" checkout -q -b target

cat >"$root/singular.config.json" <<'EOF'
{
  "schemaVersion": "v2",
  "targetBranch": "target",
  "legacyCompatibility": {"unboundWaivers": false}
}
EOF
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "singular.orchestration.dag.v0",
  "nodes": [
    {
      "id": "D0.contract",
      "stage": "D0",
      "area": "kernel",
      "layer": "contract",
      "kind": "contract",
      "dependsOn": [],
      "requiredCompletion": "contract_complete"
    },
    {
      "id": "S0.storage_substrate_base",
      "stage": "S0",
      "area": "storage",
      "layer": "storage_substrate_base",
      "kind": "substrate",
      "dependsOn": ["D0.contract"],
      "requiredCompletion": "storage_substrate_ready"
    },
    {
      "id": "D2.contract",
      "stage": "D2",
      "area": "workflow",
      "layer": "contract",
      "kind": "contract",
      "dependsOn": ["D0.contract"],
      "requiredCompletion": "contract_complete"
    }
  ]
}
EOF
cat >"$root/docs/orchestration/gates/D0.contract.gate-result.json" <<'EOF'
{
  "schema": "singular.orchestration.gate-result.v0",
  "node": "D0.contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "grandfathered",
  "evidence": [
    {
      "kind": "source-path",
      "ref": "internal/kernel",
      "description": "Pre-v2 fixture proving that schema-v2 consumers dual-read v0."
    }
  ],
  "decidedBy": "test",
  "recordedAt": "2026-07-24T00:00:00Z"
}
EOF
printf '%s\n' "hash-bound storage source" >"$root/internal/storage/source.txt"
printf '%s\n' "hash-bound workflow source" >"$root/internal/workflow/source.txt"

for task_id in \
  TASK-0313 TASK-0314 TASK-0316 TASK-0318 TASK-0320 TASK-0322 \
  TASK-0324 TASK-0326 TASK-0328 TASK-0330 TASK-0332 TASK-0334 \
  TASK-0336 TASK-0338 TASK-0340 TASK-0342 TASK-0344 TASK-0346 TASK-0348
do
  printf '# %s\n\nStatus: integrated\n' "$task_id" \
    >"$root/docs/orchestration/tasks/$task_id.md"
done

git -C "$root" add .
git -C "$root" -c user.name=test -c user.email=test@example.local \
  commit -q -m fixture

out="$(
  cd "$root"
  env \
    SINGULAR_ROOT="$root" \
    SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_PROMOTE_GATE_COMMAND='printf "%s\n" "{\"schema\":\"singular.orchestration.gate-observation.v0\",\"failures\":[]}" >"$SINGULAR_GATE_REPORT_FILE"; printf "%s\n" promotion-ok' \
    bash "$ENGINE_HOME/singular-ext/promote-gate.sh" S0.storage_substrate_base 2>&1
)" || fail "schema-v2 promotion failed: $out"
[[ "$out" == *"promoted node=S0.storage_substrate_base"* ]] \
  || fail "schema-v2 promotion did not report success: $out"

gate="$root/docs/orchestration/gates/S0.storage_substrate_base.gate-result.json"
[[ -f "$gate" ]] || fail "schema-v2 promotion did not write a gate"
python3 - "$gate" "$root" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

gate_path, root_raw = sys.argv[1:3]
root = pathlib.Path(root_raw)
gate = json.load(open(gate_path, encoding="utf-8"))
assert gate["schema"] == "singular.orchestration.gate-result.v1", gate
assert gate["status"] == "passed"
assert gate["authoritative"] is True
assert gate["verificationClassification"] == "passed"
assert len(gate["evidence"]) == 4
assert all(re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) for item in gate["evidence"])

command_log = next(item for item in gate["evidence"] if item["kind"] == "command-log")
expected_log_sha = hashlib.sha256((root / command_log["logRef"]).read_bytes()).hexdigest()
assert command_log["sha256"] == expected_log_sha

task_set = next(item for item in gate["evidence"] if item["kind"] == "task-set")
canonical = json.dumps(
    {"ref": task_set["ref"], "taskIds": task_set["taskIds"]},
    ensure_ascii=False,
    sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")
assert task_set["sha256"] == hashlib.sha256(canonical).hexdigest()

report_item = next(item for item in gate["evidence"] if item["kind"] == "gate-report")
assert gate["gateReportRef"] == report_item["ref"]
report_path = root / report_item["ref"]
assert report_item["sha256"] == hashlib.sha256(report_path.read_bytes()).hexdigest()
report = json.loads(report_path.read_text(encoding="utf-8"))
assert report["outcome"] == "passed"
assert report["command"] == command_log["command"]
assert report["rawExitCode"] == command_log["exitCode"] == 0
assert report["logRef"] == command_log["logRef"]
assert report["logSha256"] == command_log["sha256"]
assert report["headSha"] == command_log["headSha"]
bound = {
    "headSha": report["headSha"],
    "commandSha256": report["commandSha256"],
    "rawExitCode": report["rawExitCode"],
    "logSha256": report["logSha256"],
    "outcome": report["outcome"],
    "baselineSha256": report.get("baselineSha256", ""),
}
expected_binding = hashlib.sha256(
    json.dumps(bound, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
assert report["evidenceBindingSha256"] == expected_binding
PY

env \
  SINGULAR_ROOT="$root" \
  SINGULAR_STATE_DIR="$root/.singular-state" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  bash "$ENGINE_HOME/engine/dag.sh" area-gate S0.storage_substrate_base >/dev/null

# Frontier evaluation re-hashes every v1 evidence class. Preserve a known-good
# copy and prove source, task-set, command-log, report bytes, and the report's
# internal binding each fail closed independently.
report="$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.gate-report.json"
log="$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.regression.txt"
cp "$gate" "$tmp/gate.valid.json"
cp "$report" "$tmp/report.valid.json"
cp "$log" "$tmp/log.valid.txt"
cp "$root/internal/storage/source.txt" "$tmp/source.valid.txt"

assert_gate_rejected() {
  local label="$1"
  if env \
    SINGULAR_ROOT="$root" \
    SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    bash "$ENGINE_HOME/engine/dag.sh" area-gate S0.storage_substrate_base \
      >"$tmp/rejected.out" 2>&1
  then
    fail "$label must invalidate the authoritative v1 gate"
  fi
}

printf '%s\n' "mutated source bytes" >"$root/internal/storage/source.txt"
assert_gate_rejected "source-path mutation"
cp "$tmp/source.valid.txt" "$root/internal/storage/source.txt"

python3 - "$gate" <<'PY'
import json
import sys

path = sys.argv[1]
gate = json.load(open(path, encoding="utf-8"))
task_set = next(item for item in gate["evidence"] if item["kind"] == "task-set")
task_set["taskIds"].append("TASK-9999")
with open(path, "w", encoding="utf-8") as stream:
    json.dump(gate, stream, indent=2)
    stream.write("\n")
PY
assert_gate_rejected "task-set mutation"
cp "$tmp/gate.valid.json" "$gate"

printf '%s\n' "mutated command log" >>"$log"
assert_gate_rejected "command-log mutation"
cp "$tmp/log.valid.txt" "$log"

printf '%s\n' " " >>"$report"
assert_gate_rejected "gate-report byte mutation"
cp "$tmp/report.valid.json" "$report"

python3 - "$gate" "$report" <<'PY'
import hashlib
import json
import sys

gate_path, report_path = sys.argv[1:3]
report = json.load(open(report_path, encoding="utf-8"))
report["evidenceBindingSha256"] = "0" * 64
with open(report_path, "w", encoding="utf-8") as stream:
    json.dump(report, stream, indent=2, sort_keys=True)
    stream.write("\n")
report_sha = hashlib.sha256(open(report_path, "rb").read()).hexdigest()
gate = json.load(open(gate_path, encoding="utf-8"))
next(item for item in gate["evidence"] if item["kind"] == "gate-report")[
    "sha256"
] = report_sha
with open(gate_path, "w", encoding="utf-8") as stream:
    json.dump(gate, stream, indent=2)
    stream.write("\n")
PY
assert_gate_rejected "gate-report evidence-binding mutation"
cp "$tmp/report.valid.json" "$report"
cp "$tmp/gate.valid.json" "$gate"

python3 - "$gate" <<'PY'
import json
import sys

path = sys.argv[1]
gate = json.load(open(path, encoding="utf-8"))
gate.pop("verificationClassification")
with open(path, "w", encoding="utf-8") as stream:
    json.dump(gate, stream, indent=2)
    stream.write("\n")
PY
assert_gate_rejected "missing verification classification"
cp "$tmp/gate.valid.json" "$gate"

python3 - "$gate" <<'PY'
import copy
import json
import sys

path = sys.argv[1]
gate = json.load(open(path, encoding="utf-8"))
report_item = next(item for item in gate["evidence"] if item["kind"] == "gate-report")
gate["evidence"].append(copy.deepcopy(report_item))
with open(path, "w", encoding="utf-8") as stream:
    json.dump(gate, stream, indent=2)
    stream.write("\n")
PY
assert_gate_rejected "duplicate gate-report evidence"
cp "$tmp/gate.valid.json" "$gate"

# A schema-v2 blocked disposition also writes v1 and hash-binds both the source
# artifact and the exact set of unmet task IDs.
blocked_out="$(
  cd "$root"
  env \
    SINGULAR_ROOT="$root" \
    SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    bash "$ENGINE_HOME/singular-ext/promote-gate.sh" D2.contract 2>&1
)" || fail "schema-v2 blocked disposition failed: $blocked_out"
[[ "$blocked_out" == *"blocked node=D2.contract"* ]] \
  || fail "schema-v2 blocked disposition did not report the block: $blocked_out"
python3 - "$root/docs/orchestration/gates/D2.contract.gate-result.json" <<'PY'
import json
import re
import sys

gate = json.load(open(sys.argv[1], encoding="utf-8"))
assert gate["schema"] == "singular.orchestration.gate-result.v1", gate
assert gate["status"] == "blocked"
assert gate["authoritative"] is True
assert {item["kind"] for item in gate["evidence"]} == {"source-path", "task-set"}
assert all(re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) for item in gate["evidence"])
PY

echo "PASS: test-gate-promotion-v2"
