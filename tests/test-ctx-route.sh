#!/usr/bin/env bash
# Covers the composed routing-module spine engine/ctx-route.sh:
#   gluerun_ctx_route <role> <step> <meta> <key> <run_id> <runner> <prompt_sha> \
#                     <worktree> <lineage_head> <transcript> <lease_key> \
#                     <base_sha> [role-relevant-paths...]
#
# The spine WRAPS (does not reimplement) the two baseline resume deciders —
# gluerun_session_resume_decide (task role, engine/lib.sh) and
# gluerun_planner_resume_decide (planner role, engine/ctx-planner-resume.sh) —
# and adds the strategy/taint framing plus the three fail-closed resume gates
# (generalized session lease, window pressure, diff volume). It prints EXACTLY
# one line `<strategy> <arg-or-reason>` where <strategy> is one of
# continue|resume|fork|fresh|rehydrate, and never exits non-zero.
#
# Contract asserted here:
#   - OFF-parity: with GLUERUN_CTX_ROUTING unset/!=1 (default 0), for a given role
#     fixture the router emits byte-for-byte exactly what the role's wrapped
#     decider emits (`resume <id>` or `fresh <reason>`), with NO new gate applied
#     and no strategy outside {resume,fresh} appearing — even at an
#     independence-required step (OFF ignores the independence pin entirely).
#   - ON, per-role strategy table: with GLUERUN_CTX_ROUTING=1 and a fixture where
#     the wrapped decider would `resume`, all gates passing -> `resume <id>`;
#     independently a window refusal -> `fresh window-pressure`, a diff refusal ->
#     `fresh diff-volume`, and a live generalized session lease -> `fresh
#     session-lease`. First refusal wins (lease, then window, then diff).
#   - Taint / independence pin: with GLUERUN_CTX_ROUTING=1, at steps final-audit
#     and paired-audit the router emits `fresh <reason>` and NEVER resume/rehydrate
#     even when the decider would resume and even with routing knobs set to
#     arbitrary values (structurally unreachable, via _independence_admit).
#   - Contract: exactly one line, exit 0, reason (or session id) always present.
# The function is defined only; NO existing engine path invokes it, so with the
# file present-but-uncalled the engine is byte-identical to prior behavior.
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-route.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_ROUTE="$ENGINE_HOME/engine/ctx-route.sh"
REAL_TEMPLATE="$ENGINE_HOME/docs/orchestration/prompts/l1-planner.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { # <got> <want> <label>
  [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"
}
assert_ne() { # <got> <notwant> <label>
  [[ "$1" != "$2" ]] || fail "$3: expected NOT [$2], got [$1]"
}
pass() { echo "ok: $*"; }

# --- Isolated state: never touch the real repo or its state dir --------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GLUERUN_ROOT="$tmp"
export GLUERUN_STATE_DIR="$tmp/state"
export GLUERUN_TARGET_BRANCH="target"
mkdir -p "$GLUERUN_STATE_DIR"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The spine must exist and define gluerun_ctx_route (RED before it is written).
# lib.sh auto-sources it; source again defensively.
[[ -f "$CTX_ROUTE" ]] || fail "engine not present yet: $CTX_ROUTE"
# shellcheck disable=SC1090
source "$CTX_ROUTE" || fail "sourcing $CTX_ROUTE failed"
[[ "$(type -t gluerun_ctx_route)" == "function" ]] \
  || fail "gluerun_ctx_route not defined by $CTX_ROUTE"

# The wrapped deciders must be present (the spine wraps, not reimplements).
[[ "$(type -t gluerun_session_resume_decide)" == "function" ]] \
  || fail "gluerun_session_resume_decide missing (task-role decider)"
[[ "$(type -t gluerun_planner_resume_decide)" == "function" ]] \
  || fail "gluerun_planner_resume_decide missing (planner-role decider)"

# --- A real worktree so the lineage / diff gates exercise real git -----------
wt="$tmp/wt"; mkdir -p "$wt"
git -C "$wt" init -q
git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
echo a > "$wt/a"; git -C "$wt" add a; git -C "$wt" commit -qm c1
HEAD1="$(git -C "$wt" rev-parse HEAD)"
echo b > "$wt/b"; git -C "$wt" add b; git -C "$wt" commit -qm c2
HEAD2="$(git -C "$wt" rev-parse HEAD)"

# A small readable transcript that passes the window gate (bytes/4 well under
# 70% of a 200000-token window).
TRANSCRIPT="$tmp/session.jsonl"; printf 'a small transcript\n' > "$TRANSCRIPT"

# --- Planner template under GLUERUN_ROOT so the template-sha gate finds it ----
mkdir -p "$tmp/docs/orchestration/prompts"
[[ -f "$REAL_TEMPLATE" ]] || fail "missing planner template fixture source: $REAL_TEMPLATE"
cp "$REAL_TEMPLATE" "$tmp/docs/orchestration/prompts/l1-planner.md"
TPL_SHA="$(gluerun_sha256_file "$tmp/docs/orchestration/prompts/l1-planner.md")"
[[ -n "$TPL_SHA" ]] || fail "template sha came back empty"

PROMPT="$tmp/prompt.md"; printf 'base prompt\n' > "$PROMPT"
PSHA="$(gluerun_prompt_sha "$PROMPT")"
[[ -n "$PSHA" ]] || fail "prompt sha came back empty"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Fixture builders ---------------------------------------------------------
# Task-role base-good meta (all decider gates pass -> resume SID-T).
forge_task() { # <path> [k=v ...]
  local path="$1"; shift
  python3 - "$path" "$@" <<'PY'
import json, sys
path = sys.argv[1]
doc = {
    "schema": "gluerun.orchestration.session-meta.v0",
    "provider": "codex", "sessionId": "SID-T", "model": "m", "effort": "e",
    "cwd": "__WT__", "exitCode": 0, "createdAt": "__NOW__",
    "role": "implementer", "taskId": "TASK-1", "runId": "RUN-1",
    "runner": "codex-run.sh", "promptSha256": "__PSHA__",
    "headShaAtCreate": "__HEAD1__", "lastUsedAttempt": 1,
}
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    doc[k] = v
with open(path, "w") as f:
    json.dump(doc, f, indent=2); f.write("\n")
PY
}
mk_task() { local p="$1"; shift; forge_task "$p" "cwd=$wt" "createdAt=$NOW" \
  "promptSha256=$PSHA" "headShaAtCreate=$HEAD1" "$@"; }

# Planner-role base-good meta (all decider gates pass -> resume SID-P).
forge_planner() { # <path> [k=v ...]
  local path="$1"; shift
  python3 - "$path" "$@" <<'PY'
import json, sys
path = sys.argv[1]
doc = {
    "schema": "gluerun.orchestration.session-meta.v0",
    "provider": "codex", "sessionId": "SID-P", "model": "m", "effort": "e",
    "cwd": "__WT__", "exitCode": 0, "createdAt": "__NOW__",
    "role": "planner", "node": "node-1",
    "runner": "codex-run.sh", "promptSha256": "__PSHA__",
    "headShaAtCreate": "__HEAD1__", "lastUsedAttempt": 1,
}
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    doc[k] = v
with open(path, "w") as f:
    json.dump(doc, f, indent=2); f.write("\n")
PY
}
mk_planner() { local p="$1"; shift; forge_planner "$p" "cwd=$wt" "createdAt=$NOW" \
  "promptSha256=$TPL_SHA" "headShaAtCreate=$HEAD1" "$@"; }

# Call shape for the spine. route <role> <step> <meta> <key> <run> <runner> \
#   <psha> <wt> <lineage_head> <transcript> <lease_key> <base_sha> [paths...]
route() { gluerun_ctx_route "$@"; }

# Direct decider calls (for OFF-parity byte-equality).
task_decide() { # <meta> <lineage_head>
  gluerun_session_resume_decide "$1" implementer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$2"
}
planner_decide() { # <meta> <lineage_head>
  GLUERUN_PLANNER_SESSION=1 gluerun_planner_resume_decide "$1" node-1 codex-run.sh "$wt" "$2"
}

# =============================================================================
# 1. OFF-parity — router == decider byte-for-byte, no gates, no independence pin
# =============================================================================
m="$tmp/off-task.json"; mk_task "$m"
want="$(task_decide "$m" "$HEAD2")"
assert_eq "$want" "resume SID-T" "sanity: task decider resumes on a good meta"
got="$(GLUERUN_CTX_ROUTING=0 route implementer implement "$m" TASK-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" TASK-1 "$HEAD1")"
assert_eq "$got" "$want" "OFF-parity: task resume byte-for-byte"
got="$(route implementer implement "$m" TASK-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" TASK-1 "$HEAD1")"   # unset flag defaults 0
assert_eq "$got" "$want" "OFF-parity: task resume with flag unset (default 0)"

# A fresh decider verdict passes through verbatim too.
m="$tmp/off-task-fresh.json"; mk_task "$m" "runner=other-run.sh"
want="$(task_decide "$m" "$HEAD2")"
assert_eq "$want" "fresh runner-changed" "sanity: task decider fresh reason"
got="$(GLUERUN_CTX_ROUTING=0 route implementer implement "$m" TASK-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" TASK-1 "$HEAD1")"
assert_eq "$got" "$want" "OFF-parity: task fresh reason byte-for-byte"

# Planner role OFF-parity.
m="$tmp/off-planner.json"; mk_planner "$m"
want="$(planner_decide "$m" "$HEAD2")"
assert_eq "$want" "resume SID-P" "sanity: planner decider resumes on a good meta"
got="$(GLUERUN_CTX_ROUTING=0 GLUERUN_PLANNER_SESSION=1 route planner plan "$m" node-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" node-1 "$HEAD1")"
assert_eq "$got" "$want" "OFF-parity: planner resume byte-for-byte"

# OFF ignores the independence pin: a would-be resume at final-audit still
# passes through as the decider's resume (OFF is byte-identical to legacy).
m="$tmp/off-indep.json"; mk_task "$m"
got="$(GLUERUN_CTX_ROUTING=0 route implementer final-audit "$m" TASK-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" TASK-1 "$HEAD1")"
assert_eq "$got" "resume SID-T" "OFF-parity: independence pin NOT applied when flag off"
pass "OFF-parity: router == decider byte-for-byte (task+planner), no gate/pin applied"

# =============================================================================
# 2. ON — per-role strategy table + the three resume gates
# =============================================================================
lease_task="$(gluerun_ctx_route_session_lease_path implementer TASK-1)"
lease_planner="$(gluerun_ctx_route_session_lease_path planner node-1)"
rm -f "$lease_task" "$lease_planner"

# 2a. All gates pass -> the decider's resume stands (task role).
m="$tmp/on-task.json"; mk_task "$m"
got="$(GLUERUN_CTX_ROUTING=1 route implementer implement "$m" TASK-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" TASK-1 "$HEAD1")"
assert_eq "$got" "resume SID-T" "ON task: all gates pass -> resume"

# 2b. Window pressure refusal -> fresh window-pressure (missing transcript).
got="$(GLUERUN_CTX_ROUTING=1 route implementer implement "$m" TASK-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$tmp/no-such-transcript" TASK-1 "$HEAD1")"
assert_eq "$got" "fresh window-pressure" "ON task: window refusal downgrades to fresh window-pressure"

# 2c. Diff volume refusal -> fresh diff-volume (churn>0 with threshold 0).
got="$(GLUERUN_CTX_ROUTING=1 GLUERUN_SESSION_DIFF_MAX_LINES=0 route implementer implement "$m" \
  TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" TASK-1 "$HEAD1")"
assert_eq "$got" "fresh diff-volume" "ON task: diff refusal downgrades to fresh diff-volume"

# 2d. Live generalized session lease -> fresh session-lease (first refusal wins:
# even with window+diff also refusing, the lease fires first).
mkdir -p "$(dirname "$lease_task")"
printf '{"pid": %s}\n' "$$" > "$lease_task"
got="$(GLUERUN_CTX_ROUTING=1 GLUERUN_SESSION_DIFF_MAX_LINES=0 route implementer implement "$m" \
  TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2" "$tmp/no-such-transcript" TASK-1 "$HEAD1")"
assert_eq "$got" "fresh session-lease" "ON task: live lease refusal wins first -> fresh session-lease"
rm -f "$lease_task"

# 2e. A would-be-fresh decider decision is NOT rerouted to resume by any gate
# (gates only ADD refusals). Router emits the decider's fresh verdict verbatim.
mf="$tmp/on-task-fresh.json"; mk_task "$mf" "runner=other-run.sh"
got="$(GLUERUN_CTX_ROUTING=1 route implementer implement "$mf" TASK-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" TASK-1 "$HEAD1")"
assert_eq "$got" "fresh runner-changed" "ON task: gates never turn fresh into resume"
pass "ON task-role table: pass->resume; window/diff/lease each downgrade to their fresh reason"

# 2f. Planner role: the same gate table over the planner decider.
mp="$tmp/on-planner.json"; mk_planner "$mp"
got="$(GLUERUN_CTX_ROUTING=1 GLUERUN_PLANNER_SESSION=1 route planner plan "$mp" node-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" node-1 "$HEAD1")"
assert_eq "$got" "resume SID-P" "ON planner: all gates pass -> resume"
got="$(GLUERUN_CTX_ROUTING=1 GLUERUN_PLANNER_SESSION=1 route planner plan "$mp" node-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$tmp/no-such-transcript" node-1 "$HEAD1")"
assert_eq "$got" "fresh window-pressure" "ON planner: window refusal -> fresh window-pressure"
got="$(GLUERUN_CTX_ROUTING=1 GLUERUN_PLANNER_SESSION=1 GLUERUN_SESSION_DIFF_MAX_LINES=0 route planner plan \
  "$mp" node-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" node-1 "$HEAD1")"
assert_eq "$got" "fresh diff-volume" "ON planner: diff refusal -> fresh diff-volume"
# The generalized session-lease path for role=planner, key=<node> coincides with
# the integrated planner decider's own per-node lease path (the generalized lease
# generalizes it), so the decider's lease gate names the reason first: a live
# lease -> fresh with the lease reason (`leased`), still proving lease refusal
# downgrades resume to fresh for the planner role.
assert_eq "$lease_planner" "$GLUERUN_STATE_DIR/sessions/planner/node-1.lease" \
  "generalized planner lease path == integrated planner lease path"
mkdir -p "$(dirname "$lease_planner")"
printf '{"pid": %s}\n' "$$" > "$lease_planner"
got="$(GLUERUN_CTX_ROUTING=1 GLUERUN_PLANNER_SESSION=1 route planner plan "$mp" node-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" node-1 "$HEAD1")"
assert_eq "$got" "fresh leased" "ON planner: live lease -> fresh (lease reason)"
assert_ne "${got%% *}" "resume" "ON planner: live lease never resumes"
rm -f "$lease_planner"
pass "ON planner-role table: pass->resume; window/diff/lease each downgrade to their fresh reason"

# =============================================================================
# 3. Taint / independence pin — structurally unreachable by resume/rehydrate
# =============================================================================
m="$tmp/indep.json"; mk_task "$m"
# The decider WOULD resume here; the pin must still force fresh at both steps.
sanity="$(task_decide "$m" "$HEAD2")"
assert_eq "$sanity" "resume SID-T" "sanity: decider would resume at the independence fixture"
for step in final-audit paired-audit; do
  got="$(GLUERUN_CTX_ROUTING=1 route implementer "$step" "$m" TASK-1 RUN-1 codex-run.sh \
    "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" TASK-1 "$HEAD1")"
  assert_eq "$got" "fresh tainted" "$step: pinned to fresh tainted"
  assert_ne "${got%% *}" "resume" "$step: never resume"
  assert_ne "${got%% *}" "rehydrate" "$step: never rehydrate"
done

# No knob relaxes the pin: set a wide spread of permissive-looking routing knobs
# and re-assert. Diff/window knobs set to values that would otherwise allow
# resume; the pin fires before any gate.
knob_out="$(env \
    GLUERUN_CTX_ROUTING=1 \
    GLUERUN_SESSION_AFFINITY=1 \
    GLUERUN_PLANNER_SESSION=1 \
    GLUERUN_SESSION_DIFF_MAX_LINES=999999 \
    GLUERUN_SESSION_WINDOW_MAX_PCT=100 \
    GLUERUN_ROUTE_FORCE=resume \
    GLUERUN_ROUTE_ALLOW_TAINTED=1 \
    bash -c '
      source "'"$LIB"'"; source "'"$CTX_ROUTE"'"
      for step in final-audit paired-audit; do
        gluerun_ctx_route implementer "$step" "'"$m"'" TASK-1 RUN-1 codex-run.sh \
          "'"$PSHA"'" "'"$wt"'" "'"$HEAD2"'" "'"$TRANSCRIPT"'" TASK-1 "'"$HEAD1"'"
      done')"
expected=$'fresh tainted\nfresh tainted'
assert_eq "$knob_out" "$expected" "no knob relaxes the independence pin"

# A step that is already fresh at an independence step keeps the decider's reason
# (the pin admits fresh; it only refuses resume/rehydrate).
mfresh="$tmp/indep-fresh.json"; mk_task "$mfresh" "runner=other-run.sh"
got="$(GLUERUN_CTX_ROUTING=1 route implementer final-audit "$mfresh" TASK-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" TASK-1 "$HEAD1")"
assert_eq "$got" "fresh runner-changed" "final-audit: an already-fresh decider verdict keeps its reason"
pass "independence pin: final-audit/paired-audit never resume/rehydrate under any knobs"

# =============================================================================
# 4. Contract — exactly one line, exit 0, decision always carries a reason/id,
#    and every emitted strategy is in the five-strategy alphabet.
# =============================================================================
check_one_line() { # <output> <label>
  [[ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" == "1" ]] || fail "$2: expected exactly one line"
  # <strategy> <arg-or-reason>: two+ fields, strategy in the alphabet, arg non-empty.
  local strat="${1%% *}" rest="${1#* }"
  case "$strat" in
    continue|resume|fork|fresh|rehydrate) ;;
    *) fail "$2: strategy [$strat] not in {continue,resume,fork,fresh,rehydrate}" ;;
  esac
  [[ -n "$rest" && "$rest" != "$1" ]] || fail "$2: decision carries no reason/id: [$1]"
}
m="$tmp/contract.json"; mk_task "$m"
rc=0; out="$(GLUERUN_CTX_ROUTING=1 route implementer implement "$m" TASK-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" TASK-1 "$HEAD1")" || rc=$?
assert_eq "$rc" "0" "router exit 0 (resume path)"
check_one_line "$out" "resume path"
rc=0; out="$(GLUERUN_CTX_ROUTING=1 route implementer final-audit "$m" TASK-1 RUN-1 codex-run.sh \
  "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" TASK-1 "$HEAD1")" || rc=$?
assert_eq "$rc" "0" "router exit 0 (pinned path)"
check_one_line "$out" "pinned path"
pass "contract: exactly one line, exit 0, strategy in alphabet, reason/id present"

echo "ctx-route tests passed"
