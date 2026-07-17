#!/usr/bin/env bash
set -euo pipefail

# Phase E (0.8.0): "plan threads" — gluerun plan archive / list. A completed DAG
# is archived as a browsable mini-repo under .gluerun-state/plans/<id>/ (both
# docs/orchestration/ and .gluerun-state/ subtrees) and the live tree is reset
# to a starter DAG. Preconditions (live autonomate / origin lock / live dispatch
# / incomplete frontier / leftover worktrees) are refusable only with --force.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-plan-archive.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
orch="$root/docs/orchestration"
state="$root/.gluerun-state"
plans="$state/plans"
mkdir -p "$orch/tasks" "$orch/gates" "$orch/areas/core" "$orch/packets/imported" \
  "$orch/prompts" "$state/runs" "$state/dispatch" "$state/leases" "$state/inbox"

git -C "$root" init -q
git -C "$root" checkout -q -b target

ops() {
  env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$state" \
    GLUERUN_ORCH_DIR="$orch" GLUERUN_TASKS_DIR="$orch/tasks" \
    GLUERUN_LEASES_DIR="$state/leases" GLUERUN_INBOX_DIR="$state/inbox" \
    GLUERUN_DISPATCH_DIR="$state/dispatch" GLUERUN_RUNS_DIR="$state/runs" \
    GLUERUN_WORKTREES_DIR="$root/.worktrees" \
    GLUERUN_EVENTS_FILE="$state/events.ndjson" \
    GLUERUN_GATE_SCHEMA="$ENGINE_HOME/schemas/gate-result.v0.schema.json" \
    GLUERUN_TARGET_BRANCH=target \
    bash "$SCRIPT_DIR/ops.sh" plan "$@"
}

seed_dag() {
  cat >"$orch/dag.v0.json" <<'EOF'
{
  "schema": "gluerun.orchestration.dag.v0",
  "layers": ["scaffold", "domain"],
  "kinds": ["build", "test"],
  "nodes": [
    {"id": "M0.scaffold", "stage": "M0", "area": "core", "layer": "scaffold", "kind": "build", "dependsOn": [], "requiredCompletion": "scaffold_complete"},
    {"id": "M1.domain", "stage": "M1", "area": "core", "layer": "domain", "kind": "build", "dependsOn": ["M0.scaffold"], "requiredCompletion": "domain_complete"}
  ]
}
EOF
}

seed_gate() {
  local node="$1"
  cat >"$orch/gates/$node.gate-result.json" <<EOF
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "$node",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "grandfathered",
  "evidence": [
    {"kind": "source-path", "ref": "src/$node", "description": "seeded fixture gate"}
  ],
  "decidedBy": "bootstrap",
  "recordedAt": "2026-07-01T00:00:00Z"
}
EOF
}

# --- seed a complete 2-node plan ---------------------------------------------
seed_dag
seed_gate "M0.scaffold"
seed_gate "M1.domain"
printf '# TASK-0001\n\nStatus: integrated\n' >"$orch/tasks/TASK-0001.md"
printf '# TASK-0002\n\nStatus: integrated\n' >"$orch/tasks/TASK-0002.md"
printf '# TEMPLATE\n' >"$orch/tasks/TEMPLATE.md"
printf '# Planner Contract\n' >"$orch/planner-contract.md"
printf '# Decisions\n\n## Decision Log\n' >"$orch/decisions.md"
printf '# l1-planner\n' >"$orch/prompts/l1-planner.md"
{
  printf '%s\n' '{"ts":"2026-07-01T00:00:00Z","type":"loop.start","message":"start","data":{}}'
  printf '%s\n' '{"ts":"2026-07-01T01:00:00Z","type":"task.integrated","message":"t1","data":{}}'
  printf '%s\n' '{"ts":"2026-07-01T02:00:00Z","type":"gate.passed","message":"g","data":{}}'
} >"$state/events.ndjson"
mkdir -p "$state/runs/RUN-1"; printf 'x\n' >"$state/runs/RUN-1/log.txt"
printf '%s\n' '{"taskId":"TASK-0002","runId":"RUN-1","state":"reaped","pid":1,"pgid":0}' \
  >"$state/dispatch/TASK-0002.json"
printf '%s\n' '{"taskId":"TASK-0002","status":"integrated"}' >"$state/leases/TASK-0002.json"
git -C "$root" add -A
git -C "$root" -c user.email=t@t -c user.name=t commit -q -m init

# --- Refusal 1: live autonomate ----------------------------------------------
printf '%s\n' "$$" >"$state/autonomate.pid"
rc=0; err="$(ops archive 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "live autonomate must refuse"
assert_contains "$err" "autonomate" "autonomate blocker named"
rm -f "$state/autonomate.pid"

# --- Refusal 2: incomplete frontier ------------------------------------------
mv "$orch/gates/M1.domain.gate-result.json" "$tmp/M1.gate.json"
rc=0; err="$(ops archive 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "incomplete plan must refuse"
assert_contains "$err" "INCOMPLETE" "incomplete blocker named"
mv "$tmp/M1.gate.json" "$orch/gates/M1.domain.gate-result.json"

# --- Refusal 3: leftover worktree --------------------------------------------
mkdir -p "$root/.worktrees/TASK-0002"
rc=0; err="$(ops archive 2>&1 >/dev/null)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "leftover worktree must refuse"
assert_contains "$err" "worktrees" "worktree blocker named"
rm -rf "$root/.worktrees"

# --- Success: archive (default commit) ---------------------------------------
out="$(ops archive)"
assert_contains "$out" '"ok":true' "archive ok"
assert_contains "$out" '"reset":true' "archive reset"
assert_contains "$out" '"committed":true' "archive committed"
id1="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
adir="$plans/$id1"

# Archive has BOTH subtrees.
[[ -f "$adir/docs/orchestration/dag.v0.json" ]] || fail "archive dag.v0.json"
[[ -d "$adir/docs/orchestration/tasks" ]] || fail "archive tasks/"
[[ -f "$adir/docs/orchestration/tasks/TASK-0001.md" ]] || fail "archive TASK-0001"
[[ -d "$adir/docs/orchestration/gates" ]] || fail "archive gates/"
[[ -f "$adir/docs/orchestration/prompts/l1-planner.md" ]] || fail "archive prompts copy"
[[ -f "$adir/docs/orchestration/decisions.md" ]] || fail "archive decisions copy"
[[ -f "$adir/.gluerun-state/events.ndjson" ]] || fail "archive events.ndjson"
[[ -d "$adir/.gluerun-state/runs" ]] || fail "archive runs/"
[[ -f "$adir/.gluerun-state/runs/RUN-1/log.txt" ]] || fail "archive run payload"
[[ -d "$adir/.gluerun-state/dispatch" ]] || fail "archive dispatch/"

# Manifest fields.
[[ -f "$adir/manifest.json" ]] || fail "manifest.json present"
mfields="$(python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
assert m["schema"]=="gluerun.plan.manifest.v0", m.get("schema")
assert m["id"], "id"
assert m["name"]==m["id"], "name defaults to id"
assert m["gates"]=={"passed":2,"total":2}, m["gates"]
assert m["taskCount"]==2, m["taskCount"]
assert m["eventCount"]==3, m["eventCount"]
assert m["firstEventAt"]=="2026-07-01T00:00:00Z", m["firstEventAt"]
assert m["lastEventAt"]=="2026-07-01T02:00:00Z", m["lastEventAt"]
assert m["forced"] is False, m["forced"]
print("ok")' "$adir/manifest.json")"
assert_contains "$mfields" "ok" "manifest fields"

# Index has the entry.
[[ -f "$plans/index.json" ]] || fail "index.json present"
icheck="$(python3 -c 'import json,sys
idx=json.load(open(sys.argv[1]))
assert idx["schema"]=="gluerun.plans.index.v0"
ids=[p["id"] for p in idx["plans"]]
assert sys.argv[2] in ids, (sys.argv[2], ids)
print(len(idx["plans"]))' "$plans/index.json" "$id1")"
[[ "$icheck" == "1" ]] || fail "index has 1 plan (got $icheck)"

# Copies stay live.
[[ -f "$orch/decisions.md" ]] || fail "decisions.md stays live"
[[ -f "$orch/planner-contract.md" ]] || fail "planner-contract.md stays live"

# Live tree reset.
grep -q "M0.scaffold" "$orch/dag.v0.json" || fail "starter dag has M0.scaffold"
assert_not_contains "$(cat "$orch/dag.v0.json")" "M1.domain" "starter dag reset"
if compgen -G "$orch/tasks/TASK-*.md" >/dev/null; then fail "tasks dir must be empty of TASK-*.md"; fi
evlines="$(grep -c . "$state/events.ndjson" || true)"
[[ "$evlines" == "1" ]] || fail "events.ndjson has exactly 1 line (got $evlines)"
assert_contains "$(cat "$state/events.ndjson")" '"type":"plan.archived"' "plan.archived event"
assert_contains "$(cat "$state/events.ndjson")" "\"planId\":\"$id1\"" "plan.archived planId"

# Archive commit in git log.
assert_contains "$(git -C "$root" log --oneline)" "plan: archive $id1" "archive commit in log"
[[ -z "$(git -C "$root" status --porcelain docs/orchestration)" ]] || fail "docs/orchestration clean after default commit"

# --- Second archive with --name + --no-commit --------------------------------
# Re-complete the (starter) plan, commit the seed so --no-commit has a live diff.
seed_gate "M0.scaffold"
printf '# TASK-0100\n\nStatus: integrated\n' >"$orch/tasks/TASK-0100.md"
git -C "$root" add -A
git -C "$root" -c user.email=t@t -c user.name=t commit -q -m "seed second plan"

out2="$(ops archive --name "Console Redesign" --no-commit)"
assert_contains "$out2" '"committed":false' "second archive not committed"
id2="$(printf '%s' "$out2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
[[ "$id2" == *-console-redesign ]] || fail "id must end with -console-redesign (got $id2)"

# --no-commit leaves the reset uncommitted.
[[ -n "$(git -C "$root" status --porcelain)" ]] || fail "--no-commit must leave changes uncommitted"
assert_not_contains "$(git -C "$root" log --oneline)" "plan: archive $id2" "no archive commit with --no-commit"

# Index now has 2 plans, newest (console-redesign) first.
order="$(python3 -c 'import json,sys
idx=json.load(open(sys.argv[1]))
print(len(idx["plans"]), idx["plans"][0]["id"])' "$plans/index.json")"
assert_contains "$order" "2 $id2" "index has 2 plans, newest first"

# Second manifest carries the display name.
name2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$plans/$id2/manifest.json")"
[[ "$name2" == "Console Redesign" ]] || fail "second manifest name (got $name2)"

# --- plan list ----------------------------------------------------------------
listjson="$(ops list --json)"
lcount="$(printf '%s' "$listjson" | python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d["schema"]=="gluerun.plans.index.v0"
print(len(d["plans"]))')"
[[ "$lcount" == "2" ]] || fail "plan list --json shows 2 plans (got $lcount)"

lhuman="$(ops list)"
assert_contains "$lhuman" "$id1" "human list has plan 1"
assert_contains "$lhuman" "Console Redesign" "human list has plan 2 name"

echo "PASS: test-plan-archive"
