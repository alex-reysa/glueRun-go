#!/usr/bin/env bash
# A graph that cannot advance unattended must say so.
#
# Two individually defensible defaults combine into a dead graph: the shipped
# promoter promotes only nodes in its own registry (ids from one specific
# consumer project), and `authority` defaults to `operator` for evaluation
# nodes. A consumer who writes their own DAG therefore gets a graph that stalls
# after layer 0, whose only symptom is `promotion: no promotable frontier gates`
# every iteration -- which is also exactly what a merely not-yet-ready frontier
# prints. That cost a field operator a full day.
#
# Both remedies already existed and neither was discoverable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

repo="$tmp/repo"
mkdir -p "$repo/docs/orchestration/gates"
git -C "$tmp" init -q repo
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf '{"schemaVersion":"v2","targetBranch":"main"}\n' >"$repo/gluerun.config.json"
printf '.gluerun-state/\n' >"$repo/.gitignore"
cat >"$repo/docs/orchestration/dag.v0.json" <<'JSON'
{
  "schema": "gluerun.orchestration.dag.v0",
  "nodes": [
    {"id": "loc-00-contract", "stage": "loc", "area": "loc", "layer": "contract",
     "kind": "build", "dependsOn": [], "requiredCompletion": "done"},
    {"id": "loc-01-review", "stage": "loc", "area": "loc", "layer": "contract",
     "kind": "evaluation", "dependsOn": ["loc-00-contract"], "requiredCompletion": "done"}
  ]
}
JSON
git -C "$repo" add -A
git -C "$repo" commit -qm init

doctor_json() {
  python3 "$ROOT/engine/doctor.py" --engine-home "$ROOT" --repo-root "$repo" \
    --bash "$(command -v bash)" --bash-version "$BASH_VERSION" --json 2>/dev/null || true
}

check_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
doc = json.loads(sys.argv[1])
by_id = {c["id"]: c for c in doc["checks"]}
check = by_id.get("graph.promotability")
assert check is not None, "graph.promotability check is missing"
print(check[sys.argv[2]] if sys.argv[2] != "json" else json.dumps(check))
PY
}

# --- 1. an unregistered consumer graph warns, and names the remedies ---------
out="$(doctor_json)"
[[ -n "$out" ]] || fail "doctor produced no JSON"
status="$(check_field "$out" status)"
[[ "$status" == "warn" ]] || fail "an unpromotable graph should warn, got '$status'"
detail="$(check_field "$out" json)"
for needle in \
  "cannot advance unattended" \
  "loc-00-contract" \
  "loc-01-review" \
  "promoter" \
  "agent-review-allowed"; do
  [[ "$detail" == *"$needle"* ]] || fail "the finding must mention '$needle': $detail"
done
pass "an unpromotable consumer graph warns and names both remedies"

# The build node is unregistered; the evaluation node is operator-authority.
# They are different problems and must be reported separately.
python3 - "$detail" <<'PY' || fail "the two causes are not reported separately"
import json
import sys
check = json.loads(sys.argv[1])
details = check["details"]
assert details["unregisteredNodes"] == ["loc-00-contract"], details["unregisteredNodes"]
assert details["operatorOnlyEvaluationNodes"] == ["loc-01-review"], \
    details["operatorOnlyEvaluationNodes"]
PY
pass "unregistered nodes and operator-only evaluation nodes are reported separately"

# --- 2. agent-review authority clears the evaluation half -------------------
python3 - "$repo/docs/orchestration/dag.v0.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
for node in data["nodes"]:
    if node["kind"] == "evaluation":
        node["authority"] = "agent-review-allowed"
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
detail="$(check_field "$(doctor_json)" json)"
python3 - "$detail" <<'PY' || fail "agent-review-allowed did not clear the evaluation finding"
import json
import sys
check = json.loads(sys.argv[1])
assert check["status"] == "warn", check["status"]
assert check["details"]["operatorOnlyEvaluationNodes"] == [], check["details"]
assert check["details"]["unregisteredNodes"] == ["loc-00-contract"], check["details"]
PY
pass "authority: agent-review-allowed clears the evaluation-node finding"

# --- 3. a project promoter is never probed ----------------------------------
# A consumer promoter takes a bare NODE argument, so probing it with
# `--registers X` could be read as a node id and make it ACT. A diagnostic must
# never promote anything, so an unrecognised promoter is reported, not executed.
tripwire="$repo/project-promoter.sh"
cat >"$tripwire" <<EOF
#!/usr/bin/env bash
printf 'INVOKED %s\n' "\$*" >>"$repo/promoter-invocations.log"
exit 0
EOF
chmod +x "$tripwire"
promoter_out="$(GLUERUN_PROMOTER="$tripwire" python3 "$ROOT/engine/doctor.py" \
  --engine-home "$ROOT" --repo-root "$repo" --bash "$(command -v bash)" \
  --bash-version "$BASH_VERSION" --json 2>/dev/null || true)"
status="$(check_field "$promoter_out" status)"
[[ "$status" == "skip" ]] || fail "a project promoter should make the check skip, got '$status'"
[[ ! -f "$repo/promoter-invocations.log" ]] \
  || fail "doctor executed the project promoter: $(cat "$repo/promoter-invocations.log")"
pass "a configured project promoter is reported, never executed"

# --- 4. the shipped promoter answers --registers without side effects -------
registers() {
  GLUERUN_ROOT="$repo" GLUERUN_ENGINE_HOME="$ROOT" GLUERUN_TARGET_BRANCH=main \
    bash "$ROOT/gluerun-ext/promote-gate.sh" --registers "$1" >/dev/null 2>&1
}
registers D2.contract || fail "a registered node should answer 0"
registers loc-00-contract && fail "an unregistered node should answer non-zero"
[[ ! -e "$repo/.gluerun-state/locks/origin.lock.json" ]] \
  || fail "a registry query must not take the origin lock (doctor would contend with a live loop)"
[[ ! -d "$repo/docs/orchestration/gates/evidence" ]] \
  || fail "a registry query must not create directories"
pass "--registers is a pure query: no lock, no directories, correct answers"

echo "graph promotability tests passed"
