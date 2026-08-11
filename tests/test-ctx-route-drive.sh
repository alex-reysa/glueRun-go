#!/usr/bin/env bash
# Covers the driver-facing routing adapter engine/ctx-route-drive.sh:
#   singular_ctx_route_decide <role> <step> <meta> <key> <run_id> <runner> \
#                            <prompt_sha> <worktree> <lineage_head>
#
# The adapter is the minimal seam the l1-drive.sh implementer (:436) and reviewer
# (:675) session-decision sites delegate into. It assembles the per-role routing
# context (session transcript path, generalized session-lease key, diff base sha)
# and returns the decision by delegating to singular_ctx_route. It adds NO new
# decision logic: OFF/ON gating and the wrapped legacy decider already live inside
# singular_ctx_route.
#
# Contract asserted here:
#   - OFF-parity: with SINGULAR_CTX_ROUTING unset/!=1 (default 0) the adapter's line
#     equals singular_session_resume_decide's line for that role byte-for-byte
#     (resume <id> or fresh <reason>) — even at an independence-required step.
#   - ON routing: with SINGULAR_CTX_ROUTING=1 the gates assembled by the adapter can
#     downgrade a would-be `resume` to `fresh <reason>` at the live sites (window
#     pressure, generalized session lease), and with every gate passing the
#     decider's `resume <id>` stands.
#   - Reviewer independence pin: with SINGULAR_CTX_ROUTING=1 the reviewer/auditor
#     decision at an independence-required step resolves to `fresh` regardless of
#     routing knob values (structural taint pin), never resume/rehydrate.
#   - Line shape: exactly one `<strategy> <arg-or-reason>` line, exit 0, strategy
#     in the five-strategy alphabet, reason/id always present.
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-route-drive.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_ADAPTER="$ENGINE_HOME/engine/ctx-route-drive.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }
assert_ne() { [[ "$1" != "$2" ]] || fail "$3: expected NOT [$2], got [$1]"; }
pass() { echo "ok: $*"; }

# --- Isolated state ----------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
export SINGULAR_TARGET_BRANCH="target"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The adapter must exist and define singular_ctx_route_decide (RED before written).
[[ -f "$CTX_ADAPTER" ]] || fail "adapter not present yet: $CTX_ADAPTER"
# shellcheck disable=SC1090
source "$CTX_ADAPTER" || fail "sourcing $CTX_ADAPTER failed"
[[ "$(type -t singular_ctx_route_decide)" == "function" ]] \
  || fail "singular_ctx_route_decide not defined by $CTX_ADAPTER"
# It delegates into the integrated spine + the wrapped decider.
[[ "$(type -t singular_ctx_route)" == "function" ]] \
  || fail "singular_ctx_route missing (routing spine)"
[[ "$(type -t singular_session_resume_decide)" == "function" ]] \
  || fail "singular_session_resume_decide missing (legacy decider)"

# --- A real worktree so the lineage / diff gates exercise real git -----------
wt="$tmp/wt"; mkdir -p "$wt"
git -C "$wt" init -q
git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
echo a > "$wt/a"; git -C "$wt" add a; git -C "$wt" commit -qm c1
HEAD1="$(git -C "$wt" rev-parse HEAD)"
echo b > "$wt/b"; git -C "$wt" add b; git -C "$wt" commit -qm c2
HEAD2="$(git -C "$wt" rev-parse HEAD)"

PROMPT="$tmp/prompt.md"; printf 'base prompt\n' > "$PROMPT"
PSHA="$(singular_prompt_sha "$PROMPT")"
[[ -n "$PSHA" ]] || fail "prompt sha came back empty"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Fixture builder: a per-role session meta at <run_dir>/session-<role>.json.
# The adapter derives run_dir = dirname(meta), so the meta MUST live at that name.
forge_meta() { # <path> <role> <sid> [k=v ...]
  local path="$1" role="$2" sid="$3"; shift 3
  python3 - "$path" "$role" "$sid" "$@" <<'PY'
import json, sys
path, role, sid = sys.argv[1], sys.argv[2], sys.argv[3]
doc = {
    "schema": "singular.orchestration.session-meta.v0",
    "provider": "codex", "sessionId": sid, "model": "m", "effort": "e",
    "cwd": "__WT__", "exitCode": 0, "createdAt": "__NOW__",
    "role": role, "taskId": "TASK-1", "runId": "RUN-1",
    "runner": "codex-run.sh", "promptSha256": "__PSHA__",
    "headShaAtCreate": "__HEAD1__", "lastUsedAttempt": 1,
}
for kv in sys.argv[4:]:
    k, v = kv.split("=", 1)
    doc[k] = v
with open(path, "w") as f:
    json.dump(doc, f, indent=2); f.write("\n")
PY
}
mk_meta() { local p="$1" role="$2" sid="$3"; shift 3; \
  forge_meta "$p" "$role" "$sid" "cwd=$wt" "createdAt=$NOW" "promptSha256=$PSHA" \
    "headShaAtCreate=$HEAD1" "$@"; }

# Legacy decider (for OFF-parity byte-equality).
legacy_decide() { # <meta> <role> <lineage_head>
  singular_session_resume_decide "$1" "$2" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$3"
}
# Adapter call. decide <role> <step> <meta> <key> <run> <runner> <psha> <wt> <lineage>
decide() { singular_ctx_route_decide "$@"; }

# =============================================================================
# 1. OFF-parity — adapter == legacy decider byte-for-byte, no gate/pin applied
# =============================================================================
rd="$tmp/run-off"; mkdir -p "$rd"
m="$rd/session-implementer.json"; mk_meta "$m" implementer SID-T
want="$(legacy_decide "$m" implementer "$HEAD2")"
assert_eq "$want" "resume SID-T" "sanity: legacy decider resumes on a good meta"
got="$(SINGULAR_CTX_ROUTING=0 decide implementer implement "$m" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$got" "$want" "OFF-parity: implementer resume byte-for-byte (flag=0)"
got="$(decide implementer implement "$m" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$got" "$want" "OFF-parity: implementer resume with flag unset (default 0)"

# A fresh decider verdict passes through verbatim too (runner changed -> fresh).
mf="$rd/session-implementer-fresh.json"; mk_meta "$mf" implementer SID-T "runner=other-run.sh"
want="$(legacy_decide "$mf" implementer "$HEAD2")"
assert_eq "$want" "fresh runner-changed" "sanity: legacy decider fresh reason"
got="$(SINGULAR_CTX_ROUTING=0 decide implementer implement "$mf" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$got" "$want" "OFF-parity: implementer fresh reason byte-for-byte"

# OFF ignores the independence pin: a would-be resume at final-audit (reviewer)
# still passes through as the decider's resume (OFF is byte-identical to legacy).
mr="$tmp/run-off-rev"; mkdir -p "$mr"
rev="$mr/session-reviewer.json"; mk_meta "$rev" reviewer SID-R "role=reviewer"
want="$(legacy_decide "$rev" reviewer "$HEAD2")"
assert_eq "$want" "resume SID-R" "sanity: legacy decider resumes reviewer meta"
got="$(SINGULAR_CTX_ROUTING=0 decide reviewer final-audit "$rev" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$got" "$want" "OFF-parity: reviewer independence pin NOT applied when flag off"
pass "OFF-parity: adapter == legacy decider byte-for-byte (implementer+reviewer), no gate/pin"

# =============================================================================
# 2. ON routing — the assembled gates can downgrade a would-be resume
# =============================================================================
rd="$tmp/run-on"; mkdir -p "$rd"
m="$rd/session-implementer.json"; mk_meta "$m" implementer SID-T
lease="$(singular_ctx_route_session_lease_path implementer TASK-1)"
rm -f "$lease"

# 2a. All gates pass -> the decider's resume stands. The adapter assembles the
# implementer transcript path as <run_dir>/worker-codex.log; make it small so the
# window gate passes.
printf 'small transcript\n' > "$rd/worker-codex.log"
got="$(SINGULAR_CTX_ROUTING=1 decide implementer implement "$m" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$got" "resume SID-T" "ON implementer: all gates pass -> resume"

# 2b. Window pressure -> fresh window-pressure (transcript missing = fail-closed).
rm -f "$rd/worker-codex.log"
got="$(SINGULAR_CTX_ROUTING=1 decide implementer implement "$m" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$got" "fresh window-pressure" "ON implementer: missing transcript downgrades to fresh window-pressure"

# 2c. Live generalized session lease -> fresh session-lease (first refusal wins).
printf 'small transcript\n' > "$rd/worker-codex.log"
mkdir -p "$(dirname "$lease")"
printf '{"pid": %s}\n' "$$" > "$lease"
got="$(SINGULAR_CTX_ROUTING=1 decide implementer implement "$m" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$got" "fresh session-lease" "ON implementer: live lease downgrades to fresh session-lease"
rm -f "$lease"

# 2d. A would-be-fresh decision is NEVER rerouted to resume by any gate.
got="$(SINGULAR_CTX_ROUTING=1 decide implementer implement "$mf" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
assert_eq "$got" "fresh runner-changed" "ON implementer: gates never turn fresh into resume"
pass "ON routing: pass->resume; window/lease each downgrade to their fresh reason"

# =============================================================================
# 3. Reviewer independence pin — the live audit site never resumes
# =============================================================================
mr="$tmp/run-on-rev"; mkdir -p "$mr"
rev="$mr/session-reviewer.json"; mk_meta "$rev" reviewer SID-R "role=reviewer"
sanity="$(legacy_decide "$rev" reviewer "$HEAD2")"
assert_eq "$sanity" "resume SID-R" "sanity: decider would resume at the reviewer fixture"
for step in final-audit paired-audit; do
  got="$(SINGULAR_CTX_ROUTING=1 decide reviewer "$step" "$rev" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")"
  assert_eq "$got" "fresh tainted" "$step: reviewer pinned to fresh tainted"
  assert_ne "${got%% *}" "resume" "$step: reviewer never resume"
  assert_ne "${got%% *}" "rehydrate" "$step: reviewer never rehydrate"
done

# No knob relaxes the reviewer pin: permissive routing knobs, still fresh.
knob_out="$(env \
    SINGULAR_CTX_ROUTING=1 \
    SINGULAR_SESSION_AFFINITY=1 \
    SINGULAR_SESSION_DIFF_MAX_LINES=999999 \
    SINGULAR_SESSION_WINDOW_MAX_PCT=100 \
    bash -c '
      source "'"$LIB"'"; source "'"$CTX_ADAPTER"'"
      for step in final-audit paired-audit; do
        singular_ctx_route_decide reviewer "$step" "'"$rev"'" TASK-1 RUN-1 codex-run.sh \
          "'"$PSHA"'" "'"$wt"'" "'"$HEAD2"'"
      done')"
expected=$'fresh tainted\nfresh tainted'
assert_eq "$knob_out" "$expected" "no knob relaxes the reviewer independence pin"
pass "reviewer independence pin: final-audit/paired-audit never resume under any knobs"

# =============================================================================
# 4. Line shape — exactly one line, exit 0, strategy in alphabet, reason present
# =============================================================================
check_one_line() { # <output> <label>
  [[ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" == "1" ]] || fail "$2: expected exactly one line"
  local strat="${1%% *}" rest="${1#* }"
  case "$strat" in
    continue|resume|fork|fresh|rehydrate) ;;
    *) fail "$2: strategy [$strat] not in {continue,resume,fork,fresh,rehydrate}" ;;
  esac
  [[ -n "$rest" && "$rest" != "$1" ]] || fail "$2: decision carries no reason/id: [$1]"
}
rd="$tmp/run-shape"; mkdir -p "$rd"
m="$rd/session-implementer.json"; mk_meta "$m" implementer SID-T
printf 'small transcript\n' > "$rd/worker-codex.log"
rc=0; out="$(SINGULAR_CTX_ROUTING=1 decide implementer implement "$m" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")" || rc=$?
assert_eq "$rc" "0" "adapter exit 0 (resume path)"
check_one_line "$out" "resume path"
rc=0; out="$(SINGULAR_CTX_ROUTING=1 decide reviewer final-audit "$rev" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2")" || rc=$?
assert_eq "$rc" "0" "adapter exit 0 (pinned path)"
check_one_line "$out" "pinned path"
pass "line shape: exactly one line, exit 0, strategy in alphabet, reason/id present"

echo "ctx-route-drive tests passed"
