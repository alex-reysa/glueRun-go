#!/usr/bin/env bash
set -euo pipefail

# P4 (0.5.0): evaluation-gate governance — `kind: evaluation` nodes promote
# via operator authority (--operator --evidence) always, and via a valid
# passing gate-review.v0 file ONLY when the node opts in with
# `authority: agent-review-allowed`. All review defects fail closed.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-evaluation-gate.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/gates/evidence" "$root/docs/orchestration/tasks" \
  "$root/docs/readiness" "$root/.gluerun-state" "$root/schemas/orchestration"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/schemas/gate-result.v0.schema.json" "$root/schemas/orchestration/"
cp "$ENGINE_HOME/schemas/dag.v0.schema.json" "$root/schemas/orchestration/"
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "gluerun.orchestration.dag.v0",
  "nodes": [
    { "id": "review-opted-in", "stage": "S9", "area": "release", "layer": "evaluation", "kind": "evaluation", "authority": "agent-review-allowed", "dependsOn": [], "requiredCompletion": "reviewed" },
    { "id": "review-operator-only", "stage": "S9", "area": "release", "layer": "evaluation", "kind": "evaluation", "dependsOn": [], "requiredCompletion": "reviewed" }
  ]
}
EOF
echo "evidence body" >"$root/docs/readiness/evidence.md"
git -C "$root" add . && git -C "$root" -c user.name=t -c user.email=t@t commit -q -m init
head="$(git -C "$root" rev-parse HEAD)"

promote() {
  # args: node extra-args...
  local node="$1"; shift
  ( cd "$root" && env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
      GLUERUN_ENGINE_HOME="$ENGINE_HOME" GLUERUN_TARGET_BRANCH=target \
      bash "$ENGINE_HOME/gluerun-ext/promote-gate.sh" "$node" "$@" 2>&1 )
}

write_review() {
  # args: node verdict headsha [recordedAt]
  python3 - "$root/docs/orchestration/gates/evidence/$1.review.json" "$1" "$2" "$3" "${4:-}" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, node, verdict, head, recorded = sys.argv[1:6]
if not recorded:
    recorded = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
json.dump({
    "schema": "gluerun.orchestration.gate-review.v0",
    "node": node,
    "reviewer": {"kind": "subagent", "id": "review-agent-1"},
    "verdict": verdict,
    "evidenceRefs": ["docs/readiness/evidence.md"],
    "rationale": "independent review fixture",
    "headSha": head,
    "recordedAt": recorded,
}, open(path, "w"), indent=2)
PY
}

# 1. dag.sh accepts the additive authority field.
out="$(cd "$root" && env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
  bash "$ENGINE_HOME/engine/dag.sh" validate-dag 2>&1)" || fail "authority field must validate ($out)"

# 2. Opted-in node + valid passing review -> agent-review promotion.
write_review review-opted-in pass "$head"
out="$(promote review-opted-in)" || fail "agent-review promotion failed: $out"
assert_contains "$out" "evidenceClass=agent-review" "agent-review evidence class"
assert_contains "$out" "reviewer=subagent/review-agent-1" "reviewer identity recorded"
[[ -f "$root/docs/orchestration/gates/review-opted-in.gate-result.json" ]] || fail "gate written"

# 3. Operator-only node + review file present -> refused with unlock text.
write_review review-operator-only pass "$head"
rc=0; out="$(promote review-operator-only)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "operator-only node must refuse agent review (rc=$rc: $out)"
assert_contains "$out" "requires operator authority" "refusal names the authority"
assert_contains "$out" "promote-gate review-operator-only --operator" "refusal shows the unlock"

# 4. --operator promotes it (with evidence refs).
out="$(promote review-operator-only --operator --evidence docs/readiness/evidence.md)" \
  || fail "operator promotion failed: $out"
assert_contains "$out" "evidenceClass=operator-review" "operator evidence class"

# 5. Fail-closed defects on a fresh opted-in fixture.
rm -f "$root/docs/orchestration/gates/review-opted-in.gate-result.json"
write_review review-opted-in fail "$head"
rc=0; out="$(promote review-opted-in)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "fail verdict must refuse"
assert_contains "$out" "review verdict is 'fail'" "fail verdict named"

write_review review-opted-in pass "0000000000000000000000000000000000000000"
rc=0; out="$(promote review-opted-in)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "non-ancestor headSha must refuse"

write_review review-opted-in pass "$head" "2020-01-01T00:00:00Z"
rc=0; out="$(promote review-opted-in)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "stale review must refuse"
assert_contains "$out" "older than" "staleness named"

echo "PASS: test-evaluation-gate"
