#!/usr/bin/env bash
# Proof ledger and promotion reuse (0.21.0). integrate.sh proves every merge on
# a disposable checkout of the exact staged tree; the promotion gate then ran
# the same command on the same bytes again. gate-check.sh now records passing
# integration-phase gates by TREE in <state>/proofs/, and the promoter cites a
# matching proof instead of re-executing. Asserts:
#   (a) only an integration-phase, verified, passing gate writes a proof, keyed
#       on the bare gate command (not on `bash -c <cmd>`);
#   (b) a promotion whose HEAD tree matches the proof reuses it: the command is
#       not executed, the gate is written and passes, the event and rationale
#       cite the source run, the strict report is hash-bound to the reused log;
#   (c) a different command, a changed tree, an expired proof, or the knob off
#       runs the gate for real.
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/gates/evidence" "$root/docs/orchestration/tasks" \
  "$root/internal/storage" "$root/.singular-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cat >"$root/singular.config.json" <<'EOF'
{"schemaVersion": "v2", "targetBranch": "target", "legacyCompatibility": {"unboundWaivers": false}}
EOF
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "singular.orchestration.dag.v0",
  "nodes": [
    {"id": "D0.contract", "stage": "D0", "area": "kernel", "layer": "contract", "kind": "contract",
     "dependsOn": [], "requiredCompletion": "contract_complete"},
    {"id": "S0.storage_substrate_base", "stage": "S0", "area": "storage", "layer": "storage_substrate_base",
     "kind": "substrate", "dependsOn": ["D0.contract"], "requiredCompletion": "storage_substrate_ready"}
  ]
}
EOF
cat >"$root/docs/orchestration/gates/D0.contract.gate-result.json" <<'EOF'
{"schema": "singular.orchestration.gate-result.v0", "node": "D0.contract", "status": "passed",
 "authoritative": true, "evidenceClass": "grandfathered",
 "evidence": [{"kind": "source-path", "ref": "internal/kernel", "description": "fixture"}],
 "decidedBy": "test", "recordedAt": "2026-07-24T00:00:00Z"}
EOF
printf '%s\n' "hash-bound storage source" >"$root/internal/storage/source.txt"
printf '%s\n' '.singular-state/' '.singular-cache/' '.singular-evidence/' '.worktrees/' >"$root/.gitignore"
for task_id in TASK-0313 TASK-0314 TASK-0316 TASK-0318 TASK-0320 TASK-0322 TASK-0324 TASK-0326 \
  TASK-0328 TASK-0330 TASK-0332 TASK-0334 TASK-0336 TASK-0338 TASK-0340 TASK-0342 TASK-0344 TASK-0346 TASK-0348; do
  printf '# %s\n\nStatus: integrated\n' "$task_id" >"$root/docs/orchestration/tasks/$task_id.md"
done
git -C "$root" add .
git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m fixture

counter="$tmp/gate-count"
printf '0\n' >"$counter"
# The consumer gate: counts executions, writes a strict observation, passes.
gate_cmd="count=\$(cat '$counter'); printf '%s\\n' \"\$((count + 1))\" >'$counter'; printf '%s\\n' '{\"schema\":\"singular.orchestration.gate-observation.v0\",\"failures\":[]}' >\"\$SINGULAR_GATE_REPORT_FILE\"; printf 'gate ok\\n'"

run_gate_check() { # <run-id> <phase> <workspace-kind> [extra env...]
  local run_id="$1" phase="$2" kind="$3"; shift 3
  (
    cd "$root"
    env SINGULAR_ROOT="$root" SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
      SINGULAR_STATE_DIR="$root/.singular-state" \
      SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" "$@" \
      bash "$ENGINE_HOME/engine/gate-check.sh" "$run_id" \
        --task-id TASK-0313 --phase "$phase" --workspace-kind "$kind" -- \
        bash -c "$gate_cmd"
  ) >"$tmp/$run_id.out" 2>&1
}
tree="$(git -C "$root" rev-parse 'HEAD^{tree}')"
proof="$root/.singular-state/proofs/$tree.json"

# (a) worker phase: no proof. integration phase: proof keyed on the bare command.
run_gate_check RUN-WORKER worker worker || fail "worker gate failed: $(cat "$tmp/RUN-WORKER.out")"
[[ ! -e "$proof" ]] || fail "a: a worker-phase gate must not write a proof"
run_gate_check RUN-INT integration integration || fail "integration gate failed: $(cat "$tmp/RUN-INT.out")"
[[ -f "$proof" ]] || fail "a: integration-phase pass must write $proof"
python3 - "$proof" "$tree" "$gate_cmd" <<'PY' || fail "a: proof record content"
import hashlib, json, os, sys
proof, tree, cmd = sys.argv[1:4]
d = json.load(open(proof))
assert d["schema"] == "singular.orchestration.gate-proof.v0", d
assert d["treeSha"] == tree and d["phase"] == "integration" and d["outcome"] == "passed", d
assert d["command"] == cmd, (d["command"], cmd)
assert d["commandSha256"] == hashlib.sha256(cmd.encode()).hexdigest()
for key in ("reportPath", "logPath", "observationPath"):
    assert os.path.isfile(d[key]), key
assert d["runId"] == "RUN-INT" and d["taskId"] == "TASK-0313"
print("ok")
PY
grep -q "\"proofTree\":\"$tree\"" "$root/.singular-state/events.ndjson" || fail "a: gate_check.completed lacks proofTree"
[[ "$(cat "$counter")" == 2 ]] || fail "a: expected two real gate executions, got $(cat "$counter")"
echo "PASS: (a) proof ledger write policy"

promote() { # [env...]
  (
    cd "$root"
    env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
      SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
      SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" \
      SINGULAR_PROMOTE_GATE_COMMAND="$gate_cmd" "$@" \
      bash "$ENGINE_HOME/singular-ext/promote-gate.sh" S0.storage_substrate_base
  ) 2>&1
}
gate="$root/docs/orchestration/gates/S0.storage_substrate_base.gate-result.json"

# (b) identical tree -> reuse: no execution, gate written, citations bound.
out="$(promote)" || fail "b: promotion failed: $out"
[[ "$out" == *"promoted node=S0.storage_substrate_base"* ]] || fail "b: not promoted: $out"
[[ "$out" == *"reusing the integration gate proof from run RUN-INT"* ]] || fail "b: reuse not reported: $out"
[[ "$(cat "$counter")" == 2 ]] || fail "b: promotion re-executed the gate (count $(cat "$counter"))"
grep -q '"type":"gate_promotion.proof_reused"' "$root/.singular-state/events.ndjson" || fail "b: proof_reused event missing"
python3 - "$gate" "$root" "$tree" <<'PY' || fail "b: gate result content"
import hashlib, json, pathlib, sys
gate_path, root, tree = sys.argv[1:4]
root = pathlib.Path(root)
g = json.load(open(gate_path))
assert g["schema"] == "singular.orchestration.gate-result.v1" and g["status"] == "passed", g
assert "integration gate proof recorded by run RUN-INT" in g["rationale"], g["rationale"]
assert tree in g["rationale"]
logs = [e for e in g["evidence"] if e["kind"] == "command-log"]
assert logs, g["evidence"]
log_path = root / logs[0]["logRef"]
assert log_path.is_file(), log_path
assert hashlib.sha256(log_path.read_bytes()).hexdigest() == logs[0]["sha256"]
assert log_path.read_text().strip().endswith("gate ok")
report = json.load(open(root / g["gateReportRef"]))
assert report["outcome"] == "passed" and report["logSha256"] == logs[0]["sha256"], report
print("ok")
PY
echo "PASS: (b) promotion reuses the integration proof"

# (c) anything that weakens the binding runs the gate for real.
reset_gate() { rm -f "$gate"; rm -rf "$root/docs/orchestration/gates/evidence"; mkdir -p "$root/docs/orchestration/gates/evidence"; git -C "$root" checkout -q -- docs/orchestration/gates 2>/dev/null || true; }
reset_gate
other_cmd="$gate_cmd; printf 'variant\\n'"
out="$(promote SINGULAR_PROMOTE_GATE_COMMAND="$other_cmd")" || fail "c1: promotion failed: $out"
[[ "$(cat "$counter")" == 3 ]] || fail "c1: a different command must run the gate"
[[ "$out" == *"not reusable (command-mismatch)"* ]] || fail "c1: mismatch reason not reported: $out"
reset_gate
out="$(promote SINGULAR_PROMOTE_PROOF_REUSE=0)" || fail "c2: promotion failed: $out"
[[ "$(cat "$counter")" == 4 ]] || fail "c2: knob off must run the gate"
reset_gate
out="$(promote SINGULAR_PROMOTE_PROOF_TTL_SEC=0)" || fail "c3: promotion failed: $out"
[[ "$(cat "$counter")" == 5 ]] || fail "c3: an expired proof must run the gate"
[[ "$out" == *"not reusable (expired)"* ]] || fail "c3: expiry not reported: $out"
reset_gate
printf 'changed\n' >>"$root/internal/storage/source.txt"
git -C "$root" add . && git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m change
out="$(promote)" || fail "c4: promotion failed: $out"
[[ "$(cat "$counter")" == 6 ]] || fail "c4: a changed tree must run the gate"
[[ "$out" != *"reusing the integration gate proof"* ]] || fail "c4: changed tree must not reuse"
# The genuine run with the original command on the new tree wrote no proof
# (promotion is not integration), so a repeat still runs.
reset_gate
out="$(promote)" || fail "c5: promotion failed: $out"
[[ "$(cat "$counter")" == 7 ]] || fail "c5: promotion runs must not seed the ledger"
echo "PASS: (c) binding checks fall back to a fresh run"
echo "PASS: test-gate-proof-ledger"
