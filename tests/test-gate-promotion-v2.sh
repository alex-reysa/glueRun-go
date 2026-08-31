#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

directory_metadata_fingerprint() {
  python3 - "$1" <<'PY'
import os
import sys

stat = os.stat(sys.argv[1], follow_symlinks=False)
print(f"{stat.st_mtime_ns}:{stat.st_ctime_ns}")
PY
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
printf '%s\n' '.singular-state/' '.singular-cache/' '.singular-evidence/' '.worktrees/' \
  >"$root/.gitignore"

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

# Transaction destinations are authority-bearing repository paths. Refuse a
# symlink in either distinct parent chain before publication or rollback can
# reach outside the repository. These fixtures also prove rejection leaves an
# unrelated external sentinel byte-for-byte intact and creates no external
# gate/evidence artifacts.
symlink_case_failures=0

gate_parent_root="$tmp/gate-parent-repo"
mkdir -p "$gate_parent_root"
cp -a "$root/." "$gate_parent_root/"
gate_parent_external="$tmp/gate-parent-external"
mv "$gate_parent_root/docs/orchestration/gates" "$gate_parent_external"
printf '%s\n' 'external-gate-parent-sentinel' >"$gate_parent_external/sentinel.txt"
gate_parent_sentinel_sha="$(shasum -a 256 "$gate_parent_external/sentinel.txt" | awk '{print $1}')"
gate_parent_directory_before="$(directory_metadata_fingerprint "$gate_parent_external")"
ln -s "$gate_parent_external" "$gate_parent_root/docs/orchestration/gates"
set +e
(
  cd "$gate_parent_root"
  env \
    SINGULAR_ROOT="$gate_parent_root" \
    SINGULAR_STATE_DIR="$gate_parent_root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    bash "$ENGINE_HOME/singular-ext/promote-gate.sh" D2.contract
) >"$tmp/gate-parent-symlink.out" 2>&1
gate_parent_rc=$?
set -e
if [[ "$gate_parent_rc" -eq 0 ]]; then
  echo "gate-parent symlink promotion was accepted" >&2
  symlink_case_failures=$((symlink_case_failures + 1))
fi
if [[ -e "$gate_parent_external/D2.contract.gate-result.json" ]]; then
  echo "gate-parent symlink promotion created an external gate" >&2
  symlink_case_failures=$((symlink_case_failures + 1))
fi
if [[ "$(shasum -a 256 "$gate_parent_external/sentinel.txt" | awk '{print $1}')" \
    != "$gate_parent_sentinel_sha" ]]; then
  echo "gate-parent symlink promotion mutated the external sentinel" >&2
  symlink_case_failures=$((symlink_case_failures + 1))
fi
if [[ "$(directory_metadata_fingerprint "$gate_parent_external")" \
    != "$gate_parent_directory_before" ]]; then
  echo "gate-parent symlink promotion mutated the external directory" >&2
  symlink_case_failures=$((symlink_case_failures + 1))
fi

evidence_parent_root="$tmp/evidence-parent-repo"
mkdir -p "$evidence_parent_root"
cp -a "$root/." "$evidence_parent_root/"
evidence_parent_external="$tmp/evidence-parent-external"
mkdir -p "$evidence_parent_external"
rmdir "$evidence_parent_root/docs/orchestration/gates/evidence"
printf '%s\n' 'external-evidence-parent-sentinel' >"$evidence_parent_external/sentinel.txt"
evidence_parent_sentinel_sha="$(shasum -a 256 "$evidence_parent_external/sentinel.txt" | awk '{print $1}')"
evidence_parent_directory_before="$(directory_metadata_fingerprint "$evidence_parent_external")"
ln -s "$evidence_parent_external" \
  "$evidence_parent_root/docs/orchestration/gates/evidence"
set +e
(
  cd "$evidence_parent_root"
  env \
    SINGULAR_ROOT="$evidence_parent_root" \
    SINGULAR_STATE_DIR="$evidence_parent_root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_PROMOTE_GATE_COMMAND='printf "%s\n" "{\"schema\":\"singular.orchestration.gate-observation.v0\",\"failures\":[]}" >"$SINGULAR_GATE_REPORT_FILE"; printf "%s\n" promotion-ok' \
    bash "$ENGINE_HOME/singular-ext/promote-gate.sh" S0.storage_substrate_base
) >"$tmp/evidence-parent-symlink.out" 2>&1
evidence_parent_rc=$?
set -e
if [[ "$evidence_parent_rc" -eq 0 ]]; then
  echo "evidence-parent symlink promotion was accepted" >&2
  symlink_case_failures=$((symlink_case_failures + 1))
fi
if find "$evidence_parent_external" -mindepth 1 ! -name sentinel.txt -print -quit \
    | grep -q .; then
  echo "evidence-parent symlink promotion created external evidence" >&2
  symlink_case_failures=$((symlink_case_failures + 1))
fi
if [[ -e "$evidence_parent_root/docs/orchestration/gates/S0.storage_substrate_base.gate-result.json" ]]; then
  echo "evidence-parent symlink promotion published a gate" >&2
  symlink_case_failures=$((symlink_case_failures + 1))
fi
if [[ "$(shasum -a 256 "$evidence_parent_external/sentinel.txt" | awk '{print $1}')" \
    != "$evidence_parent_sentinel_sha" ]]; then
  echo "evidence-parent symlink promotion mutated the external sentinel" >&2
  symlink_case_failures=$((symlink_case_failures + 1))
fi
if [[ "$(directory_metadata_fingerprint "$evidence_parent_external")" \
    != "$evidence_parent_directory_before" ]]; then
  echo "evidence-parent symlink promotion mutated the external directory during publication/rollback" >&2
  symlink_case_failures=$((symlink_case_failures + 1))
fi
if [[ "$symlink_case_failures" -ne 0 ]]; then
  cat "$tmp/gate-parent-symlink.out" >&2
  cat "$tmp/evidence-parent-symlink.out" >&2
  fail "$symlink_case_failures promotion destination symlink assertion(s) failed"
fi

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
assert gate["campaignBinding"] == "legacy"
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
assert report["logPath"] == str(root / command_log["logRef"])
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
assert gate["blockerClass"] == "needs-work"
assert gate["authoritative"] is True
assert {item["kind"] for item in gate["evidence"]} == {"source-path", "task-set"}
assert all(re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) for item in gate["evidence"])
PY

# Caller-controlled cache and handoff material can never authorize promotion.
# Even a valid-looking manifest and digest must take the normal cold path.
rm -f \
  "$root/docs/orchestration/gates/S0.storage_substrate_base.gate-result.json" \
  "$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.regression.txt" \
  "$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.gate-observation.json" \
  "$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.gate-report.json"
promotion_counter="$tmp/promotion-counter"
printf '0\n' >"$promotion_counter"
promotion_command='count=$(cat "$PROMOTION_COUNTER"); printf "%s\n" "$((count + 1))" >"$PROMOTION_COUNTER"; printf "%s\n" "{\"schema\":\"singular.orchestration.gate-observation.v0\",\"failures\":[]}" >"$SINGULAR_GATE_REPORT_FILE"; printf "%s\n" promotion-ok'
forged_handoff="$tmp/forged-promotion-handoff.json"
printf '%s\n' \
  '{"schema":"singular.orchestration.integration-gate-handoff.v0","outcome":"passed","testedTreeOid":"0000000000000000000000000000000000000000"}' \
  >"$forged_handoff"

cold_out="$(
  cd "$root"
  env \
    PROMOTION_COUNTER="$promotion_counter" \
    SINGULAR_ROOT="$root" \
    SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_GATE_PROOF_CACHE=1 \
    SINGULAR_PROMOTE_GATE_COMMAND="$promotion_command" \
    SINGULAR_GATE_PROMOTION_HANDOFF_FILE="$forged_handoff" \
    SINGULAR_GATE_PROMOTION_HANDOFF_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    bash "$ENGINE_HOME/singular-ext/promote-gate.sh" S0.storage_substrate_base 2>&1
)" || fail "cold promotion with forged proof environment failed: $cold_out"
[[ "$(cat "$promotion_counter")" == 1 ]] \
  || fail "forged proof environment suppressed the promotion regression"
[[ "$cold_out" == *"running regression"* ]] \
  || fail "promotion did not report the mandatory cold regression: $cold_out"
[[ "$cold_out" != *"reused"* ]] \
  || fail "promotion claimed to reuse caller-controlled proof: $cold_out"
if [[ -f "$root/.singular-state/events.ndjson" ]] && \
  grep -q '"type":"gate.promotion_handoff_used"' "$root/.singular-state/events.ndjson"
then
  fail "promotion emitted a handoff-reuse event"
fi
python3 - "$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.gate-report.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
assert "proofReuse" not in report, report
assert "reusedAt" not in report, report
assert report["outcome"] == "passed", report
PY

# A cold promotion runs in the origin checkout. It must refuse a command that
# changes the exact source tree it claims to have certified, even where that
# command emits a syntactically valid successful observation. Execution output
# remains in private engine scratch space until this guard succeeds, so it
# cannot mask a source mutation as an engine-owned evidence write.
rm -f \
  "$root/docs/orchestration/gates/S0.storage_substrate_base.gate-result.json" \
  "$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.regression.txt" \
  "$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.gate-report.json"
mutation_command='printf "%s\\n" source-mutation >> internal/storage/source.txt; printf "%s\\n" "{\"schema\":\"singular.orchestration.gate-observation.v0\",\"failures\":[]}" >"$SINGULAR_GATE_REPORT_FILE"; printf "%s\\n" mutation-attempt'
set +e
mutation_out="$(
  cd "$root"
  env \
    SINGULAR_ROOT="$root" \
    SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_PROMOTE_GATE_COMMAND="$mutation_command" \
    bash "$ENGINE_HOME/singular-ext/promote-gate.sh" S0.storage_substrate_base 2>&1
)"
mutation_rc=$?
set -e
[[ "$mutation_rc" -ne 0 ]] || fail "source-mutating promotion gate was accepted"
[[ "$mutation_out" == *"changed certified source state"* ]] \
  || fail "source-mutating promotion did not report source integrity: $mutation_out"
[[ ! -e "$root/docs/orchestration/gates/S0.storage_substrate_base.gate-result.json" ]] \
  || fail "source-mutating promotion published a gate result"
[[ ! -e "$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.regression.txt" ]] \
  || fail "source-mutating promotion published a durable log"

# The final publication lock is intentionally acquired only after the cold
# regression has produced a private candidate. A concurrent source change in
# that window must invalidate the candidate before any gate or evidence bytes
# become durable. Keep the candidate scratch directory predictable for this
# test, but outside the repository just as production requires.
cp "$tmp/source.valid.txt" "$root/internal/storage/source.txt"
rm -f \
  "$root/docs/orchestration/gates/S0.storage_substrate_base.gate-result.json" \
  "$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.regression.txt" \
  "$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.gate-observation.json" \
  "$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.gate-report.json"
race_tmp="$tmp/promotion-cas-tmp"
race_ready="$tmp/promotion-cas-lock-ready"
race_release="$tmp/promotion-cas-lock-release"
race_out="$tmp/promotion-cas.out"
race_rc="$tmp/promotion-cas.rc"
mkdir -p "$race_tmp"

(
  cd "$root"
  env \
    SINGULAR_ROOT="$root" \
    SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    RACE_READY="$race_ready" \
    RACE_RELEASE="$race_release" \
    bash -c '
      source "$SINGULAR_ENGINE_HOME/engine/lib.sh"
      singular_ensure_state_dirs
      singular_campaign_lock_acquire
      : >"$RACE_READY"
      while [[ ! -e "$RACE_RELEASE" ]]; do sleep 0.05; done
      singular_campaign_lock_release
    '
) &
race_lock_pid=$!
for _ in $(seq 1 100); do
  [[ -e "$race_ready" ]] && break
  sleep 0.05
done
[[ -e "$race_ready" ]] || fail "could not acquire the publication lock for CAS regression"

(
  cd "$root"
  set +e
  env \
    TMPDIR="$race_tmp" \
    SINGULAR_CAMPAIGN_LOCK_WAIT_TICKS=200 \
    SINGULAR_ROOT="$root" \
    SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_PROMOTE_GATE_COMMAND='printf "%s\\n" "{\"schema\":\"singular.orchestration.gate-observation.v0\",\"failures\":[]}" >"$SINGULAR_GATE_REPORT_FILE"; printf "%s\\n" promotion-cas-race' \
    bash "$ENGINE_HOME/singular-ext/promote-gate.sh" S0.storage_substrate_base >"$race_out" 2>&1
  printf '%s\n' "$?" >"$race_rc"
) &
race_promoter_pid=$!

race_candidate=""
for _ in $(seq 1 200); do
  race_candidate="$(find "$race_tmp" -type f -path '*/candidates/S0.storage_substrate_base.gate-result.*' -print -quit 2>/dev/null || true)"
  [[ -n "$race_candidate" ]] && break
  if ! kill -0 "$race_promoter_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
[[ -n "$race_candidate" ]] || {
  cat "$race_out" >&2 2>/dev/null || true
  fail "promotion did not produce a private candidate before publication"
}
printf '%s\n' "changed-after-candidate" >"$root/internal/storage/source.txt"
: >"$race_release"
wait "$race_lock_pid" || fail "publication lock holder did not release cleanly"
wait "$race_promoter_pid" || true
[[ -f "$race_rc" ]] || fail "CAS-race promoter did not record an exit code"
[[ "$(cat "$race_rc")" -ne 0 ]] || {
  cat "$race_out" >&2
  fail "promotion published after its certified source changed while waiting for the lock"
}
grep -q 'certified source/upstream changed before publication' "$race_out" \
  || { cat "$race_out" >&2; fail "CAS-race rejection lacked final publication guard"; }
[[ ! -e "$root/docs/orchestration/gates/S0.storage_substrate_base.gate-result.json" ]] \
  || fail "CAS-race promotion published a gate result"
[[ ! -e "$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.regression.txt" \
    && ! -e "$root/docs/orchestration/gates/evidence/S0.storage_substrate_base.gate-report.json" ]] \
  || fail "CAS-race promotion published authoritative evidence"
cp "$tmp/source.valid.txt" "$root/internal/storage/source.txt"

# A gate is authority only for the campaign identity that published it. Start
# one real frozen campaign, prove the prior legacy gate is stale, then end that
# campaign from inside a long-running gate and prove the old operation cannot
# publish any result or durable evidence after the boundary changes.
cp "$tmp/source.valid.txt" "$root/internal/storage/source.txt"
cp "$tmp/gate.valid.json" "$gate"
cp "$tmp/report.valid.json" "$report"
cp "$tmp/log.valid.txt" "$log"
transition_command='bash "$SINGULAR_ENGINE_HOME/engine/campaign.sh" end >/dev/null; printf "%s\n" "{\"schema\":\"singular.orchestration.gate-observation.v0\",\"failures\":[]}" >"$SINGULAR_GATE_REPORT_FILE"; printf "%s\n" campaign-ended-during-gate'
campaign_out="$(
  cd "$root"
  env \
    SINGULAR_ROOT="$root" \
    SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_PROMOTE_GATE_COMMAND="$transition_command" \
    bash "$ENGINE_HOME/engine/campaign.sh" start --id gate-race-campaign --allow-provider-unchecked 2>&1
)" || fail "could not start gate race campaign: $campaign_out"

if env \
  SINGULAR_ROOT="$root" \
  SINGULAR_STATE_DIR="$root/.singular-state" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  SINGULAR_PROMOTE_GATE_COMMAND="$transition_command" \
  bash "$ENGINE_HOME/engine/dag.sh" area-gate S0.storage_substrate_base \
    >"$tmp/stale-campaign-gate.out" 2>&1
then
  fail "legacy gate remained authoritative in a frozen campaign"
fi
grep -q 'campaign binding mismatch' "$tmp/stale-campaign-gate.out" \
  || { cat "$tmp/stale-campaign-gate.out" >&2; fail "stale gate rejection did not identify its campaign binding"; }

# The stale gate must exclude ordinary planning without becoming permanent
# poison: the promoter re-evaluates the node with only its own disposition
# hidden, then replaces it with a current-campaign result.
current_campaign_binding="$(
  cd "$root"
  env \
    SINGULAR_ROOT="$root" \
    SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    bash -c 'source "$SINGULAR_ENGINE_HOME/engine/lib.sh"; singular_campaign_binding'
)" || fail "could not resolve active campaign binding"
# Keep the dependency authoritative so this isolates replacement of D2's own
# stale blocked disposition; dependency drift must remain a separate refusal.
python3 - "$root/docs/orchestration/gates/D0.contract.gate-result.json" \
  "$current_campaign_binding" <<'PY'
import json
import sys

path, binding = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    gate = json.load(handle)
gate["campaignBinding"] = binding
with open(path, "w", encoding="utf-8") as handle:
    json.dump(gate, handle, indent=2)
    handle.write("\n")
PY
rebind_out="$(
  cd "$root"
  env \
    SINGULAR_ROOT="$root" \
    SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_PROMOTE_GATE_COMMAND="$transition_command" \
    bash "$ENGINE_HOME/singular-ext/promote-gate.sh" D2.contract 2>&1
)" || fail "stale blocked gate could not be re-evaluated: $rebind_out"
[[ "$rebind_out" == *"blocked node=D2.contract"* ]] \
  || fail "stale blocked gate was not replaced: $rebind_out"
python3 - "$root/docs/orchestration/gates/D2.contract.gate-result.json" \
  "$current_campaign_binding" <<'PY'
import json
import sys

gate = json.load(open(sys.argv[1], encoding="utf-8"))
assert gate["status"] == "blocked", gate
assert gate["campaignBinding"] == sys.argv[2], gate
PY
env \
  SINGULAR_ROOT="$root" \
  SINGULAR_STATE_DIR="$root/.singular-state" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  SINGULAR_PROMOTE_GATE_COMMAND="$transition_command" \
  bash "$ENGINE_HOME/engine/dag.sh" validate-gate-file \
    "$root/docs/orchestration/gates/D2.contract.gate-result.json" >/dev/null \
  || fail "current-campaign blocked replacement did not validate"

rm -f "$gate" "$report" "$log"
set +e
transition_out="$(
  cd "$root"
  env \
    SINGULAR_ROOT="$root" \
    SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_PROMOTE_GATE_COMMAND="$transition_command" \
    bash "$ENGINE_HOME/singular-ext/promote-gate.sh" S0.storage_substrate_base 2>&1
)"
transition_rc=$?
set -e
[[ "$transition_rc" -ne 0 ]] || fail "promotion crossed a campaign transition"
[[ "$transition_out" == *"campaign identity changed"* ]] \
  || fail "cross-campaign promotion did not report identity drift: $transition_out"
[[ ! -e "$gate" && ! -e "$report" && ! -e "$log" ]] \
  || fail "cross-campaign promotion published authoritative artifacts"
[[ ! -e "$root/.singular-state/campaign/ACTIVE" \
    && ! -e "$root/.singular-state/campaign/manifest.json" \
    && ! -e "$root/.singular-state/CAMPAIGN_ENFORCED" ]] \
  || fail "gate command did not complete the campaign transition"

# Ending a campaign rotates the inactive epoch. A pre-campaign legacy proof
# must not regain authority after a complete start/end ABA cycle.
cp "$tmp/gate.valid.json" "$gate"
cp "$tmp/report.valid.json" "$report"
cp "$tmp/log.valid.txt" "$log"
if env \
  SINGULAR_ROOT="$root" \
  SINGULAR_STATE_DIR="$root/.singular-state" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  bash "$ENGINE_HOME/engine/dag.sh" area-gate S0.storage_substrate_base \
    >"$tmp/post-campaign-legacy-gate.out" 2>&1
then
  fail "pre-campaign legacy gate regained authority after campaign end"
fi
grep -q 'campaign binding mismatch' "$tmp/post-campaign-legacy-gate.out" \
  || { cat "$tmp/post-campaign-legacy-gate.out" >&2; fail "post-campaign stale gate rejection lacked binding reason"; }

echo "PASS: test-gate-promotion-v2"
