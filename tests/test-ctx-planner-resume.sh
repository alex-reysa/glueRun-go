#!/usr/bin/env bash
# Covers the planner-role resume decider library brick engine/ctx-planner-resume.sh:
# gluerun_planner_resume_decide — the planner variant of the integrated task-role
# gluerun_session_resume_decide. Same single-line `resume <sessionId>` /
# `fresh <reason>` contract, ordered fail-closed gates (first failing gate names
# the reason), reusing the gluerun.orchestration.session-meta.v0 shape.
#
# Gate deltas from the task-role decider asserted here:
#   - Enable gate (default 0 = OFF): GLUERUN_PLANNER_SESSION unset/!=1 -> fresh disabled.
#   - Node-lineage REPLACES the runId/task-equality gate: meta.node != target node
#     -> fresh node-mismatch; meta.headShaAtCreate not an ancestor of the target
#     head -> fresh head-rewritten; matching node AND ancestor head passes.
#   - Planner-role gate: role != planner -> fresh role-mismatch (a task/advocate/
#     skeptic session is never resumed as the planner).
#   - Prompt-template gate keyed on the TEMPLATE sha: promptSha256 vs sha256 of
#     docs/orchestration/prompts/l1-planner.md; any other stored sha (e.g. a
#     rendered-prompt sha) -> fresh prompt-template-changed.
#   - Session-lease gate: a live lease at .gluerun-state/sessions/planner/<node>.lease
#     -> fresh leased; no held lease with every other gate satisfied -> resume.
#   - Kept task-role gates/reasons: no-session, no-session-id, runner-changed,
#     expired, worktree-moved.
# The function is defined only; NO existing engine path invokes it, so with the
# file present-but-uncalled the engine is byte-identical to prior behavior.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_PR="$ENGINE_HOME/engine/ctx-planner-resume.sh"
REAL_TEMPLATE="$ENGINE_HOME/docs/orchestration/prompts/l1-planner.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { # <got> <want> <label>
  [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"
}
pass() { echo "ok: $*"; }

# --- Isolated state: never touch the real repo or its state dir --------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

export GLUERUN_ROOT="$tmp"
export GLUERUN_STATE_DIR="$tmp/state"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the decider (RED before it is written).
# lib.sh auto-sources it; source again defensively.
[[ -f "$CTX_PR" ]] || fail "engine not present yet: $CTX_PR"
# shellcheck disable=SC1090
source "$CTX_PR" || fail "sourcing $CTX_PR failed"
[[ "$(type -t gluerun_planner_resume_decide)" == "function" ]] \
  || fail "gluerun_planner_resume_decide not defined by $CTX_PR"

NODE="planner-resume-gates"

# The planner template must live under GLUERUN_ROOT so the template-sha gate finds
# it (the gate keys on the TEMPLATE, not the rendered prompt). Copy the real file
# into the hermetic root and derive the expected sha from it.
mkdir -p "$tmp/docs/orchestration/prompts"
[[ -f "$REAL_TEMPLATE" ]] || fail "missing planner template fixture source: $REAL_TEMPLATE"
cp "$REAL_TEMPLATE" "$tmp/docs/orchestration/prompts/l1-planner.md"
TPL_SHA="$(gluerun_sha256_file "$tmp/docs/orchestration/prompts/l1-planner.md")"
[[ -n "$TPL_SHA" ]] || fail "template sha came back empty"

# A real worktree so the node-lineage gate (git merge-base --is-ancestor) is
# exercised against real commits.
wt="$tmp/worktree"; mkdir -p "$wt"
git -C "$wt" init -q
git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
echo a > "$wt/a"; git -C "$wt" add a; git -C "$wt" commit -qm c1
HEAD1="$(git -C "$wt" rev-parse HEAD)"
echo b > "$wt/b"; git -C "$wt" add b; git -C "$wt" commit -qm c2
HEAD2="$(git -C "$wt" rev-parse HEAD)"
# A divergent branch so HEAD2 is NOT an ancestor of HEAD_FORK (head-rewritten).
git -C "$wt" checkout -q -b fork "$HEAD1"
echo x > "$wt/x"; git -C "$wt" add x; git -C "$wt" commit -qm fork1
HEAD_FORK="$(git -C "$wt" rev-parse HEAD)"
git -C "$wt" checkout -q master 2>/dev/null || git -C "$wt" checkout -q main 2>/dev/null || git -C "$wt" checkout -q "$HEAD2"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# forge a base-good planner meta then apply k=v overrides.
forge_meta() { # <path> [k=v ...]
  local path="$1"; shift
  python3 - "$path" "$@" <<'PY'
import json, sys
path = sys.argv[1]
doc = {
    "schema": "gluerun.orchestration.session-meta.v0",
    "provider": "codex", "sessionId": "SID-P", "model": "m", "effort": "e",
    "cwd": "__WT__", "exitCode": 0, "createdAt": "__NOW__",
    "role": "planner", "node": "__NODE__",
    "runner": "codex-run.sh", "promptSha256": "__PSHA__",
    "headShaAtCreate": "__HEAD__", "lastUsedAttempt": 1,
}
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    doc[k] = v
with open(path, "w") as f:
    json.dump(doc, f, indent=2); f.write("\n")
PY
}
mk() { # mk <path> [extra k=v ...] — base-good meta (all gates pass) then overrides
  local path="$1"; shift
  forge_meta "$path" \
    "cwd=$wt" "createdAt=$NOW" "node=$NODE" "promptSha256=$TPL_SHA" \
    "headShaAtCreate=$HEAD2" "$@"
}

# decide <meta> <node> <runner> <worktree> <lineage_head>. Default: knob ON.
decide() { GLUERUN_PLANNER_SESSION="${GLUERUN_PLANNER_SESSION:-1}" gluerun_planner_resume_decide "$@"; }

lease_path="$GLUERUN_STATE_DIR/sessions/planner/$NODE.lease"
rm -f "$lease_path"

# --- Gate: feature-flag disabled (default 0 = OFF) ---------------------------
m="$tmp/g-dis.json"; mk "$m"
out="$(GLUERUN_PLANNER_SESSION=0 gluerun_planner_resume_decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh disabled" "disabled(=0)"
out="$(unset GLUERUN_PLANNER_SESSION; gluerun_planner_resume_decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh disabled" "disabled(unset)"
pass "gate: GLUERUN_PLANNER_SESSION unset/0 -> fresh disabled"

# --- Gate: no-session (missing + unparseable meta) ---------------------------
out="$(decide "$tmp/does-not-exist.json" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh no-session" "missing meta"
printf 'not json{' > "$tmp/g-bad.json"
out="$(decide "$tmp/g-bad.json" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh no-session" "unparseable meta"
pass "gate: missing/unparseable meta -> fresh no-session"

# --- Gate: no-session-id (empty provider or sessionId) -----------------------
m="$tmp/g-sid.json"; mk "$m" "sessionId="
out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh no-session-id" "empty sid"
m="$tmp/g-prov.json"; mk "$m" "provider="
out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh no-session-id" "empty provider"
pass "gate: empty provider/sessionId -> fresh no-session-id"

# --- Gate: role-mismatch (advocate/skeptic line) -----------------------------
for r in implementer task advocate skeptic reviewer ""; do
  m="$tmp/g-role.json"; mk "$m" "role=$r"
  out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
  assert_eq "$out" "fresh role-mismatch" "role=$r"
done
pass "gate: role != planner -> fresh role-mismatch (never resume a non-planner session)"

# --- Gate: node-mismatch (node-lineage replaces runId equality) --------------
m="$tmp/g-node.json"; mk "$m" "node=some-other-node"
out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh node-mismatch" "node differs"
pass "gate: meta.node != target node -> fresh node-mismatch"

# --- Gate: head-rewritten (headShaAtCreate not an ancestor of target head) ---
# meta head = HEAD2 (ancestor of HEAD2), but target lineage head = HEAD_FORK on a
# divergent branch -> HEAD2 is NOT an ancestor -> head-rewritten.
m="$tmp/g-head.json"; mk "$m"
out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD_FORK")"
assert_eq "$out" "fresh head-rewritten" "non-ancestor head"
# Fail closed: empty stored head / empty lineage head is indeterminate ancestry.
m="$tmp/g-head2.json"; mk "$m" "headShaAtCreate="
out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh head-rewritten" "empty stored head"
out="$(decide "$tmp/g-head.json" "$NODE" codex-run.sh "$wt" "")"
assert_eq "$out" "fresh head-rewritten" "empty lineage head"
pass "gate: non-ancestor/indeterminate head -> fresh head-rewritten"

# --- Gate: runner-changed ----------------------------------------------------
m="$tmp/g-runner.json"; mk "$m" "runner=claude-run.sh"
out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh runner-changed" "runner differs"
pass "gate: runner changed -> fresh runner-changed"

# --- Gate: prompt-template-changed (keyed on TEMPLATE sha) -------------------
m="$tmp/g-tpl.json"; mk "$m" "promptSha256=0000000000000000000000000000000000000000000000000000000000000000"
out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh prompt-template-changed" "wrong template sha"
# A rendered-prompt sha (differs from the TEMPLATE by design) must also fail.
rendered_sha="$(printf 'rendered-frontier-specific-prompt' | shasum -a 256 | awk '{print $1}')"
m="$tmp/g-tpl2.json"; mk "$m" "promptSha256=$rendered_sha"
out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh prompt-template-changed" "rendered-prompt sha"
pass "gate: stored sha != template sha -> fresh prompt-template-changed"

# --- Gate: expired -----------------------------------------------------------
m="$tmp/g-exp.json"; mk "$m" "createdAt=2000-01-01T00:00:00Z"
out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh expired" "old createdAt"
pass "gate: age > GLUERUN_SESSION_MAX_AGE_SEC -> fresh expired"

# --- Gate: worktree-moved ----------------------------------------------------
m="$tmp/g-cwd.json"; mk "$m" "cwd=/some/other/place"
out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh worktree-moved" "cwd differs"
pass "gate: cwd != worktree -> fresh worktree-moved"

# --- Gate: leased (live lease at the canonical planner lease path) ------------
m="$tmp/g-lease.json"; mk "$m"
mkdir -p "$(dirname "$lease_path")"
# A live lease: hold it with this shell's own PID (kill -0 succeeds).
printf '{"pid": %s}\n' "$$" > "$lease_path"
out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh leased" "live lease present"
rm -f "$lease_path"
pass "gate: live lease -> fresh leased"

# --- Happy path: every gate satisfied, no held lease -> resume <sessionId> ----
m="$tmp/happy.json"; mk "$m"
rm -f "$lease_path"
out="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "resume SID-P" "all-pass resume"
pass "happy: all gates pass (role planner, node equal, ancestor head, template sha, unexpired, cwd, no lease) -> resume SID-P"

# --- Contract: exactly one line; never non-zero even on a fresh decision ------
rc=0
lines="$(decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")" || rc=$?
assert_eq "$rc" "0" "decider exit code is 0 on resume"
[[ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" == "1" ]] || fail "decider printed more than one line"
rc=0
out="$(GLUERUN_PLANNER_SESSION=0 gluerun_planner_resume_decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")" || rc=$?
assert_eq "$rc" "0" "decider exit code is 0 on fresh"

echo "ctx-planner-resume tests passed"
