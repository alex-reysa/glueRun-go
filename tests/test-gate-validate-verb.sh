#!/usr/bin/env bash
# `singular gate validate` must report EVERY contract violation in one pass.
#
# dag.sh's fail() prints and exits, which is right for the loop -- a frontier
# read must stop at the first breach -- but it means a promoter learns about
# exactly one violation per run. A consumer's promoter hit four in sequence:
# absolute evidence[].ref, absolute gateReportRef, a task-set hashed by their
# own convention, and a taskId that did not match ^TASK-[0-9]{4,}. Each hid the
# next, each cost a loop restart, and the whole loop took hours.
#
# The critical property is PLURALITY: a test asserting one violation would pass
# against the unfixed collector.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

repo="$tmp/repo"
mkdir -p "$repo/docs/orchestration/gates" "$repo/docs/orchestration/tasks"
git -C "$tmp" init -q repo
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf '{"schemaVersion":"v2","targetBranch":"main"}\n' >"$repo/singular.config.json"
printf '.singular-state/\n' >"$repo/.gitignore"
cat >"$repo/docs/orchestration/dag.v0.json" <<'JSON'
{"schema": "singular.orchestration.dag.v0", "nodes": [
  {"id": "loc-00-contract", "stage": "loc", "area": "loc", "layer": "contract",
   "kind": "build", "dependsOn": [], "requiredCompletion": "done"}]}
JSON
git -C "$repo" add -A
git -C "$repo" commit -qm init

gate="$repo/docs/orchestration/gates/loc-00-contract.gate-result.json"
zero="0000000000000000000000000000000000000000000000000000000000000000"

# The field shape: several independent breaches at once.
cat >"$gate" <<JSON
{
  "schema": "singular.orchestration.gate-result.v1",
  "node": "loc-00-contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "deterministic-proof",
  "verificationClassification": "passed",
  "evidence": [
    {"kind": "gate-report", "ref": "/private/tmp/nowhere/gate-report.json", "sha256": "$zero"},
    {"kind": "task-set", "ref": "docs/orchestration/tasks",
     "taskIds": ["loc-00-contract"], "sha256": "$zero"},
    {"kind": "command-log", "ref": "x", "command": "make check", "exitCode": 0,
     "logRef": "/private/tmp/nowhere/gate.log", "sha256": "$zero",
     "headSha": "0000000000000000000000000000000000000000"}
  ],
  "gateReportRef": "/private/tmp/nowhere/gate-report.json",
  "decidedBy": "test",
  "recordedAt": "2026-07-26T00:00:00Z"
}
JSON

run_validate() {
  SINGULAR_ROOT="$repo" SINGULAR_ENGINE_HOME="$ROOT" \
    bash "$ROOT/engine/dag.sh" validate-gate-file "$1" 2>&1
}

# --- 1. plurality: several violations, one pass ------------------------------
out=""
rc=0
out="$(run_validate "$gate")" || rc=$?
[[ "$rc" -ne 0 ]] || fail "a gate with violations must exit non-zero"
count="$(printf '%s\n' "$out" | grep -c '^  - ' || true)"
[[ "$count" -ge 3 ]] \
  || fail "expected at least 3 violations in one pass, got $count:
$out"
pass "several independent violations are reported in a single pass ($count found)"

# Each independent breach must appear -- one must not hide another.
for needle in \
  "evidence[0] ref must be a safe repository-relative path" \
  "evidence[1] sha256 mismatch" \
  "evidence[2] logRef must be a safe repository-relative path" \
  "gateReportRef must be a safe repository-relative path"; do
  [[ "$out" == *"$needle"* ]] || fail "missing violation '$needle' in:
$out"
done
pass "absolute refs and a mis-hashed task-set are each reported independently"

# --- 2. the loop's own path is unchanged: first breach, then stop ------------
# This is the property that makes collecting mode safe to add: every existing
# subcommand must still short-circuit exactly as before.
loop_out=""
loop_rc=0
loop_out="$(SINGULAR_ROOT="$repo" SINGULAR_ENGINE_HOME="$ROOT" \
  bash "$ROOT/engine/dag.sh" next-areas 2>&1)" || loop_rc=$?
[[ "$loop_rc" -ne 0 ]] || fail "the frontier read should still fail on this gate"
loop_lines="$(printf '%s\n' "$loop_out" | grep -c . || true)"
[[ "$loop_lines" -eq 1 ]] \
  || fail "next-areas must still stop at the FIRST breach, got $loop_lines lines:
$loop_out"
pass "next-areas still exits on the first violation (collecting mode is opt-in)"

# --- 3. a valid gate validates cleanly --------------------------------------
# Built from a report engine/gate-check.sh actually wrote, so this doubles as a
# check that the two commands agree about what "valid" means.
SINGULAR_ROOT="$repo" SINGULAR_ENGINE_HOME="$ROOT" \
  bash "$ROOT/engine/gate-check.sh" RUN-VALIDATE --task-id TASK-0001 -- true >/dev/null 2>&1 \
  || fail "gate-check.sh failed"
python3 - "$repo" "$repo/.singular-state/runs/RUN-VALIDATE/gate-report.json" "$gate" <<'PY'
import hashlib
import json
import os
import sys

repo, report_path, gate_path = sys.argv[1:4]
report = json.load(open(report_path, encoding="utf-8"))
report_ref = os.path.relpath(report_path, repo)

task_ev = {"kind": "task-set", "ref": "docs/orchestration/tasks",
           "taskIds": [report["taskId"]]}
task_ev["sha256"] = hashlib.sha256(json.dumps(
    {"ref": task_ev["ref"], "taskIds": task_ev["taskIds"]},
    ensure_ascii=False, sort_keys=True, separators=(",", ":"),
).encode("utf-8")).hexdigest()

json.dump({
    "schema": "singular.orchestration.gate-result.v1",
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
        {"kind": "gate-report", "ref": report_ref,
         "sha256": hashlib.sha256(open(report_path, "rb").read()).hexdigest()},
    ],
    "gateReportRef": report_ref,
    "decidedBy": "gate-validate-verb-test",
    "recordedAt": "2026-07-26T00:00:00Z",
}, open(gate_path, "w", encoding="utf-8"), indent=2)
PY
out=""
rc=0
out="$(run_validate "$gate")" || rc=$?
[[ "$rc" -eq 0 ]] || fail "a valid gate must validate cleanly, got:
$out"
[[ "$out" == *"gate-valid"* ]] || fail "a valid gate should say so: $out"
pass "a gate built from a real gate-check.sh report validates cleanly"

# --- 4. unreadable input is reported as itself, not as a pile of noise -------
printf 'not json\n' >"$tmp/broken.json"
out=""
rc=0
out="$(run_validate "$tmp/broken.json")" || rc=$?
[[ "$rc" -ne 0 ]] || fail "unreadable input must exit non-zero"
[[ "$out" == *"not readable JSON"* ]] || fail "unreadable input should say so: $out"
out=""
rc=0
out="$(run_validate "$tmp/absent.json")" || rc=$?
[[ "$rc" -ne 0 ]] || fail "a missing file must exit non-zero"
[[ "$out" == *"gate file not found"* ]] || fail "a missing file should say so: $out"
pass "unreadable and missing gate files are reported as themselves"

echo "gate validate verb tests passed"
