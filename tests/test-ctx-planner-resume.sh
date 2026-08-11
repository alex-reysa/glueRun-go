#!/usr/bin/env bash
# Covers the planner-role resume decider library brick engine/ctx-planner-resume.sh:
# singular_planner_resume_decide — the planner variant of the integrated task-role
# singular_session_resume_decide. Same single-line `resume <sessionId>` /
# `fresh <reason>` contract, ordered fail-closed gates (first failing gate names
# the reason), reusing the singular.orchestration.session-meta.v0 shape.
#
# Gate deltas from the task-role decider asserted here:
#   - Enable gate (default 0 = OFF): SINGULAR_PLANNER_SESSION unset/!=1 -> fresh disabled.
#   - Node-lineage REPLACES the runId/task-equality gate: meta.node != target node
#     -> fresh node-mismatch; meta.headShaAtCreate not an ancestor of the target
#     head -> fresh head-rewritten; matching node AND ancestor head passes.
#   - Planner-role gate: role != planner -> fresh role-mismatch (a task/advocate/
#     skeptic session is never resumed as the planner).
#   - Prompt-template gate keyed on the TEMPLATE sha: promptSha256 vs sha256 of
#     docs/orchestration/prompts/l1-planner.md; any other stored sha (e.g. a
#     rendered-prompt sha) -> fresh prompt-template-changed.
#   - Session-lease gate: a live lease at .singular-state/sessions/planner/<node>.lease
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

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the decider (RED before it is written).
# lib.sh auto-sources it; source again defensively.
[[ -f "$CTX_PR" ]] || fail "engine not present yet: $CTX_PR"
# shellcheck disable=SC1090
source "$CTX_PR" || fail "sourcing $CTX_PR failed"
[[ "$(type -t singular_planner_resume_decide)" == "function" ]] \
  || fail "singular_planner_resume_decide not defined by $CTX_PR"

NODE="planner-resume-gates"

# The planner template must live under SINGULAR_ROOT so the template-sha gate finds
# it (the gate keys on the TEMPLATE, not the rendered prompt). Copy the real file
# into the hermetic root and derive the expected sha from it.
mkdir -p "$tmp/docs/orchestration/prompts"
[[ -f "$REAL_TEMPLATE" ]] || fail "missing planner template fixture source: $REAL_TEMPLATE"
cp "$REAL_TEMPLATE" "$tmp/docs/orchestration/prompts/l1-planner.md"
TPL_SHA="$(singular_sha256_file "$tmp/docs/orchestration/prompts/l1-planner.md")"
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
    "schema": "singular.orchestration.session-meta.v0",
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
decide() { SINGULAR_PLANNER_SESSION="${SINGULAR_PLANNER_SESSION:-1}" singular_planner_resume_decide "$@"; }

lease_path="$SINGULAR_STATE_DIR/sessions/planner/$NODE.lease"
rm -f "$lease_path"

# --- Gate: feature-flag disabled (default 0 = OFF) ---------------------------
m="$tmp/g-dis.json"; mk "$m"
out="$(SINGULAR_PLANNER_SESSION=0 singular_planner_resume_decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh disabled" "disabled(=0)"
out="$(unset SINGULAR_PLANNER_SESSION; singular_planner_resume_decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh disabled" "disabled(unset)"
pass "gate: SINGULAR_PLANNER_SESSION unset/0 -> fresh disabled"

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
pass "gate: age > SINGULAR_SESSION_MAX_AGE_SEC -> fresh expired"

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
out="$(SINGULAR_PLANNER_SESSION=0 singular_planner_resume_decide "$m" "$NODE" codex-run.sh "$wt" "$HEAD2")" || rc=$?
assert_eq "$rc" "0" "decider exit code is 0 on fresh"

# ============================================================================
# Consult-hook coverage: engine/generate-tasks.sh wiring of the decider.
#
# The decider tests above prove the verdict in isolation; these prove the single
# sanctioned generate-tasks.sh call site consults it correctly under
# SINGULAR_PLANNER_SESSION=1: resume adds --resume-session and acquires the
# planner session-lease; every gate reason is event-visible via
# context.strategy_selected (role "planner"); rc-86 falls back to a fresh run in
# the SAME run via context.resume_failed; the lease is released after the run;
# and with the knob off nothing is consulted/emitted/leased.
# ============================================================================
GT="$ENGINE_HOME/engine/generate-tasks.sh"
CH_NODE="planner-resume-gates"

assert_contains() { # <haystack> <needle> <label>
  [[ "$1" == *"$2"* ]] || fail "$3: [$1] does not contain [$2]"
}

# --- Isolated repo fixture (own tmp; never the real repo) ---------------------
ch_make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/prompts" "$root/docs/orchestration/tasks" \
    "$root/schemas/orchestration" "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$root/docs/orchestration/prompts/l1-planner.md"
  cp "$ENGINE_HOME/schemas/task-batch.v0.schema.json" "$root/schemas/orchestration/task-batch.v0.schema.json"
  cp "$ENGINE_HOME/schemas/dag.v0.schema.json" "$root/schemas/orchestration/dag.v0.schema.json"
  cat >"$root/docs/orchestration/dag.v0.json" <<EOF
{
  "schema": "singular.orchestration.dag.v0",
  "layers": ["engine_runtime"],
  "kinds": ["runtime"],
  "nodes": [
    {
      "id": "$CH_NODE",
      "stage": "S1-planner-persistence",
      "area": "session",
      "layer": "engine_runtime",
      "kind": "runtime",
      "dependsOn": [],
      "requiredCompletion": "Planner consults the resume decider per node."
    }
  ]
}
EOF
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

ch_with_fixture() {
  CH_TMP="$(mktemp -d)"
  ch_make_repo "$CH_TMP/repo"
  export SINGULAR_ROOT="$CH_TMP/repo"
  export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_TARGET_BRANCH="target"
  CH_STUB="$SINGULAR_ROOT/runner.sh"        # basename runner.sh (used in forged meta)
  CH_ARGS="$SINGULAR_ROOT/stub-args.txt"
  CH_EVENTS="$SINGULAR_STATE_DIR/events.ndjson"
  CH_META="$SINGULAR_STATE_DIR/sessions/planner/$CH_NODE.json"
  CH_LEASE="$SINGULAR_STATE_DIR/sessions/planner/$CH_NODE.lease"
  export STUB_ARGS_FILE="$CH_ARGS"
  CH_HEAD="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  CH_TPL_SHA="$(singular_sha256_file "$SINGULAR_ROOT/docs/orchestration/prompts/l1-planner.md")"
  rm -f "$CH_ARGS"
  ch_make_stub "$CH_STUB"
}
ch_cleanup() { [[ -n "${CH_TMP:-}" ]] && rm -rf "$CH_TMP"; }

# Stub runner: records each invocation's args; on a --resume-session invocation
# with STUB_RESUME_RC86=1 exits 86 (resume-refused); otherwise writes a
# runner-authored session-meta (so the NEXT decide can resume) and emits a valid
# canonical `session`-area task batch. Records lease presence at invocation time.
ch_make_stub() {
  local stub="$1"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{ printf 'INVOCATION\n'; printf '%s\n' "$@"; } >>"${STUB_ARGS_FILE:?}"
out=""; smeta=""; resume=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message|-o) out="$2"; shift 2 ;;
    --session-meta) smeta="$2"; shift 2 ;;
    --resume-session) resume="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "${STUB_LEASE_SEEN:-}" && -n "${STUB_LEASE_PATH:-}" ]]; then
  if [[ -f "$STUB_LEASE_PATH" ]]; then echo "present" >>"$STUB_LEASE_SEEN"
  else echo "absent" >>"$STUB_LEASE_SEEN"; fi
fi
if [[ -n "$resume" && "${STUB_RESUME_RC86:-0}" == "1" ]]; then
  exit 86
fi
if [[ -n "$smeta" ]]; then
  mkdir -p "$(dirname "$smeta")"
  python3 - "$smeta" "${SINGULAR_ROOT:?}" "${STUB_NOW:?}" <<'PY'
import json, sys
path, cwd, now = sys.argv[1:4]
try:
    doc = json.load(open(path))
    if not isinstance(doc, dict): doc = {}
except Exception:
    doc = {}
doc.update({
    "schema": "singular.orchestration.session-meta.v0",
    "provider": "codex", "sessionId": "SID-PLANNER",
    "model": "m", "effort": "e",
    "cwd": cwd, "exitCode": 0, "createdAt": now,
})
json.dump(doc, open(path, "w"), indent=2)
PY
fi
[[ -n "$out" ]] || exit 2
python3 - "$out" <<'PY'
import json, sys
md = (
    "# TASK-0001: planner resume consult hook slice\n\n"
    "Status: ready\n"
    "Area: session\n"
    "Target branch: `target`\n"
    "Worker branch: `agent/session/TASK-0001-hook`\n"
    "Test policy: `strict_test_first`\n"
    "Gate command: `bash tests/run.sh`\n"
    "Dispatch mode: canonical\n"
    "Depends on: []\n\n"
    "## Objective\n\nConsult the planner resume decider.\n\n"
    "## Scope\n\nOwned files:\n\n"
    "- `engine/generate-tasks.sh`\n"
    "- `tests/test-ctx-planner-resume.sh`\n\n"
    "Forbidden files:\n\n- `engine/lib.sh`\n\n"
    "## Acceptance Criteria\n\n- Tests first.\n"
)
batch = {"schema": "singular.orchestration.task-batch.v0",
         "tasks": [{"taskId": "TASK-0001", "markdown": md}]}
json.dump(batch, open(sys.argv[1], "w"))
PY
EOF
  chmod +x "$stub"
}

ch_run() { # runs generate-tasks (knob ON) against the fixture stub
  SINGULAR_PLANNER_SESSION=1 SINGULAR_RUNNER="$CH_STUB" STUB_NOW="$NOW" \
    "$GT" --node "$CH_NODE" --count 1 2>&1 || true
}
ch_stub_has_resume() { grep -qx -- '--resume-session' "$CH_ARGS"; }
ch_last_event_data() { # <type> -> JSON data of last matching event ("" if none)
  python3 - "$CH_EVENTS" "$1" <<'PY'
import json, sys
path, typ = sys.argv[1:3]
last = None
try:
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        if e.get("type") == typ:
            last = e
except FileNotFoundError:
    pass
print("" if last is None else json.dumps(last.get("data", {})))
PY
}
ch_ev_count() { # <type>
  [[ -f "$CH_EVENTS" ]] || { echo 0; return; }
  local n; n="$(grep -c "\"type\":\"$1\"" "$CH_EVENTS" 2>/dev/null || true)"
  echo "${n:-0}"
}
ch_field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1] or "{}").get(sys.argv[2],""))' "$1" "$2"; }

# Forge a base-good planner meta at the canonical path, then apply k=v overrides
# so exactly one gate trips (all other gates pass -> the override names the reason).
ch_forge_meta() { # [k=v ...]
  mkdir -p "$(dirname "$CH_META")"
  python3 - "$CH_META" "$SINGULAR_ROOT" "$NOW" "$CH_NODE" "$CH_TPL_SHA" "$CH_HEAD" "$@" <<'PY'
import json, sys
path, cwd, now, node, tpl, head = sys.argv[1:7]
doc = {
    "schema": "singular.orchestration.session-meta.v0",
    "provider": "codex", "sessionId": "SID-PLANNER", "model": "m", "effort": "e",
    "cwd": cwd, "exitCode": 0, "createdAt": now,
    "role": "planner", "node": node, "runner": "runner.sh",
    "promptSha256": tpl, "headShaAtCreate": head, "lastUsedAttempt": 1,
}
for kv in sys.argv[7:]:
    k, v = kv.split("=", 1)
    doc[k] = v
json.dump(doc, open(path, "w"), indent=2)
PY
}

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Feature-flag discipline: knob OFF consults/emits/leases nothing ----------
ch_with_fixture
out="$(SINGULAR_RUNNER="$CH_STUB" STUB_NOW="$NOW" "$GT" --node "$CH_NODE" --count 1 2>&1 || true)"
assert_contains "$out" "generated:" "OFF: batch accepted"
[[ "$(ch_ev_count context.strategy_selected)" == "0" ]] || fail "OFF: strategy_selected emitted while knob off"
! ch_stub_has_resume || fail "OFF: --resume-session added while knob off"
[[ ! -e "$CH_LEASE" ]] || fail "OFF: planner session-lease acquired while knob off"
ch_cleanup
pass "consult: knob OFF consults no decider, adds no --resume-session, emits no strategy event, acquires no lease"

# --- Fresh path: every gate reason reachable with the knob ON is event-visible
# via context.strategy_selected(role=planner, strategy=fresh) and adds no resume.
ch_with_fixture
run_fresh_reason() { # <expected-reason> ; canonical meta already forged (or absent)
  rm -f "$CH_ARGS"
  # Each iteration emits an identical batch; clear prior generated tasks so the
  # planner's duplicate-signature guard does not reject the run (unrelated to the
  # consult hook under test).
  rm -f "$SINGULAR_TASKS_DIR"/*.md 2>/dev/null || true
  out="$(ch_run)"
  assert_contains "$out" "generated:" "fresh/$1: batch accepted (fresh run proceeds)"
  ! ch_stub_has_resume || fail "fresh/$1: --resume-session added on a fresh decision"
  data="$(ch_last_event_data context.strategy_selected)"
  [[ -n "$data" ]] || fail "fresh/$1: no context.strategy_selected event"
  assert_eq "$(ch_field "$data" role)" "planner" "fresh/$1: role"
  assert_eq "$(ch_field "$data" strategy)" "fresh" "fresh/$1: strategy"
  assert_eq "$(ch_field "$data" node)" "$CH_NODE" "fresh/$1: node"
  assert_eq "$(ch_field "$data" reason)" "$1" "fresh/$1: reason"
}
# no-session: no meta present.
rm -f "$CH_META"; run_fresh_reason "no-session"
# no-session-id: empty sessionId.
ch_forge_meta "sessionId="; run_fresh_reason "no-session-id"
# role-mismatch: a non-planner (task/advocate/skeptic) session is never resumed.
ch_forge_meta "role=advocate"; run_fresh_reason "role-mismatch"
# node-mismatch: node-lineage replaces runId equality.
ch_forge_meta "node=some-other-node"; run_fresh_reason "node-mismatch"
# head-rewritten: stored head not an ancestor of the lineage head.
ch_forge_meta "headShaAtCreate=0000000000000000000000000000000000000000"; run_fresh_reason "head-rewritten"
# runner-changed.
ch_forge_meta "runner=claude-run.sh"; run_fresh_reason "runner-changed"
# prompt-template-changed (keyed on the TEMPLATE sha).
ch_forge_meta "promptSha256=deadbeef"; run_fresh_reason "prompt-template-changed"
# expired.
ch_forge_meta "createdAt=2000-01-01T00:00:00Z"; run_fresh_reason "expired"
# worktree-moved.
ch_forge_meta "cwd=/some/other/place"; run_fresh_reason "worktree-moved"
# leased: a live lease at the canonical planner lease path -> fresh leased, and
# the hook acquires no lease of its own (the pre-existing one is left untouched).
ch_forge_meta
mkdir -p "$(dirname "$CH_LEASE")"; printf '{"pid": %s}\n' "$$" > "$CH_LEASE"
run_fresh_reason "leased"
grep -q "\"pid\": $$" "$CH_LEASE" || fail "leased: hook disturbed the pre-existing live lease"
rm -f "$CH_LEASE"
ch_cleanup
pass "consult: knob ON — every gate reason (no-session..leased) is event-visible as a fresh strategy event; no resume on any fresh"

# --- Resume path: a finalized meta that decides resume adds --resume-session,
# emits exactly one resume strategy event, and acquires+releases the lease. ----
ch_with_fixture
# Run 1 (no meta yet) finalizes a good, resumable planner meta.
ch_run >/dev/null
[[ -f "$CH_META" ]] || fail "resume: run 1 did not finalize a planner meta"
# Run 2 should decide resume.
rm -f "$CH_ARGS"
rm -f "$SINGULAR_TASKS_DIR"/*.md 2>/dev/null || true   # avoid the unrelated duplicate guard
before_resume="$(ch_ev_count context.strategy_selected)"
export STUB_LEASE_PATH="$CH_LEASE" STUB_LEASE_SEEN="$SINGULAR_ROOT/lease-seen.txt"
rm -f "$STUB_LEASE_SEEN"
out="$(ch_run)"
assert_contains "$out" "generated:" "resume: batch accepted"
ch_stub_has_resume || fail "resume: runner NOT invoked with --resume-session"
grep -qx -- 'SID-PLANNER' "$CH_ARGS" || fail "resume: --resume-session value != SID-PLANNER"
[[ "$(ch_ev_count context.strategy_selected)" == "$((before_resume + 1))" ]] \
  || fail "resume: expected exactly one new strategy_selected event"
data="$(ch_last_event_data context.strategy_selected)"
assert_eq "$(ch_field "$data" role)" "planner" "resume: role"
assert_eq "$(ch_field "$data" strategy)" "resume" "resume: strategy"
assert_eq "$(ch_field "$data" reason)" "resume" "resume: reason"
assert_eq "$(ch_field "$data" sessionId)" "SID-PLANNER" "resume: sessionId"
assert_eq "$(ch_field "$data" node)" "$CH_NODE" "resume: node"
# Lease lifecycle: held during the resume run, released after it returns.
grep -qx present "$STUB_LEASE_SEEN" || fail "resume: lease NOT held during the resume run"
[[ ! -e "$CH_LEASE" ]] || fail "resume: lease NOT released after the run returned"
unset STUB_LEASE_PATH STUB_LEASE_SEEN
ch_cleanup
pass "consult: resume decision adds --resume-session, emits one resume strategy event, acquires+releases the planner session-lease"

# --- rc-86 in-run fresh fallback: resume-refused re-runs fresh in the SAME run
ch_with_fixture
ch_run >/dev/null                     # finalize a resumable meta
[[ -f "$CH_META" ]] || fail "rc86: setup did not finalize a meta"
rm -f "$CH_ARGS"
rm -f "$SINGULAR_TASKS_DIR"/*.md 2>/dev/null || true   # avoid the unrelated duplicate guard
before_rf="$(ch_ev_count context.resume_failed)"
out="$(SINGULAR_PLANNER_SESSION=1 SINGULAR_RUNNER="$CH_STUB" STUB_NOW="$NOW" STUB_RESUME_RC86=1 \
  "$GT" --node "$CH_NODE" --count 1 2>&1 || true)"
assert_contains "$out" "generated:" "rc86: planning completes as fresh"
# Two invocations: the first (resume) with --resume-session, the second fresh.
inv="$(grep -c '^INVOCATION$' "$CH_ARGS" || echo 0)"
assert_eq "$inv" "2" "rc86: expected exactly two runner invocations (resume then fresh)"
first_block="$(awk '/^INVOCATION$/{n++} n==1' "$CH_ARGS")"
second_block="$(awk '/^INVOCATION$/{n++} n==2' "$CH_ARGS")"
printf '%s\n' "$first_block" | grep -qx -- '--resume-session' \
  || fail "rc86: first (resume) invocation lacked --resume-session"
printf '%s\n' "$second_block" | grep -qx -- '--resume-session' \
  && fail "rc86: fresh re-run still carried --resume-session"
[[ "$(ch_ev_count context.resume_failed)" == "$((before_rf + 1))" ]] \
  || fail "rc86: expected exactly one context.resume_failed event"
data="$(ch_last_event_data context.resume_failed)"
assert_eq "$(ch_field "$data" role)" "planner" "rc86: resume_failed role"
assert_eq "$(ch_field "$data" sessionId)" "SID-PLANNER" "rc86: resume_failed sessionId"
[[ ! -e "$CH_LEASE" ]] || fail "rc86: lease NOT released after the fresh fallback"
ch_cleanup
pass "consult: rc-86 emits context.resume_failed, re-runs fresh in the SAME run, releases the lease, completes as fresh"

echo "ctx-planner-resume tests passed"
