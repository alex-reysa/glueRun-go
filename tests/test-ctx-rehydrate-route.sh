#!/usr/bin/env bash
# test-ctx-rehydrate-route.sh — the routing-integration slice of the executable
# DAG node `rehydrate-path` (stage S5-routing, layer engine_runtime). It exercises
# the wire-in of the rehydrate composition into the engine/ctx-route.sh spine: on
# a refused-resume lineage-continuation step (the lease/window/diff resume gates),
# and behind SINGULAR_REHYDRATE=1 with a run_dir = dirname(meta) holding at least
# one durable artifact, the spine emits `rehydrate <reason>` instead of the bare
# `fresh <reason>` it emits today. Only those three resume-gate refusals are
# upgraded; the independence pin, the baseline-fresh pass-through, and the
# resume-stands line are unchanged.
#
# Contract asserted here:
#   - ON upgrade (SINGULAR_CTX_ROUTING=1, SINGULAR_REHYDRATE=1, durable artifact in
#     run_dir): lease/window/diff refusals emit `rehydrate session-lease`,
#     `rehydrate window-pressure`, `rehydrate diff-volume`.
#   - OFF-parity (SINGULAR_REHYDRATE unset/!=1): the same fixtures emit
#     `fresh session-lease` / `fresh window-pressure` / `fresh diff-volume`,
#     byte-identical to pre-wire behavior.
#   - OFF-parity (SINGULAR_CTX_ROUTING!=1): the spine returns the wrapped decider's
#     line verbatim, unchanged by this wire-in.
#   - Independence pin unbroken: final-audit/paired-audit yield `fresh tainted`
#     even with SINGULAR_REHYDRATE=1 and a non-empty run_dir (pin returns first).
#   - Empty-packet degrade: SINGULAR_REHYDRATE=1 but run_dir holds no durable
#     artifact -> each gate refusal stays `fresh <reason>`.
#   - Baseline-fresh untouched: a wrapped-decider baseline fresh (no resumable
#     session) passes through unchanged even under SINGULAR_REHYDRATE=1.
#   - Contract: exactly one line, exit 0, and `rehydrate` stays tainted.
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-rehydrate-route.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_ROUTE="$ENGINE_HOME/engine/ctx-route.sh"

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
export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
export SINGULAR_TARGET_BRANCH="target"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

[[ -f "$CTX_ROUTE" ]] || fail "engine not present yet: $CTX_ROUTE"
# shellcheck disable=SC1090
source "$CTX_ROUTE" || fail "sourcing $CTX_ROUTE failed"
[[ "$(type -t singular_ctx_route)" == "function" ]] \
  || fail "singular_ctx_route not defined by $CTX_ROUTE"

# The rehydrate leaves the spine composes must be present (wire-in wraps them).
for fn in singular_ctx_rehydrate_sources singular_ctx_rehydrate_manifest \
          singular_ctx_route_rehydrate_decide singular_ctx_route_strategy_tainted; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn missing (rehydrate leaf)"
done

# --- A real worktree so the lineage / diff gates exercise real git -----------
wt="$tmp/wt"; mkdir -p "$wt"
git -C "$wt" init -q
git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
echo a > "$wt/a"; git -C "$wt" add a; git -C "$wt" commit -qm c1
HEAD1="$(git -C "$wt" rev-parse HEAD)"
echo b > "$wt/b"; git -C "$wt" add b; git -C "$wt" commit -qm c2
HEAD2="$(git -C "$wt" rev-parse HEAD)"

TRANSCRIPT="$tmp/session.jsonl"; printf 'a small transcript\n' > "$TRANSCRIPT"
NOTRANS="$tmp/no-such-transcript"

PROMPT="$tmp/prompt.md"; printf 'base prompt\n' > "$PROMPT"
PSHA="$(singular_prompt_sha "$PROMPT")"
[[ -n "$PSHA" ]] || fail "prompt sha came back empty"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Task-role base-good meta (all decider gates pass -> resume SID-T).
forge_task() { # <path> [k=v ...]
  local path="$1"; shift
  python3 - "$path" "$@" <<'PY'
import json, sys
path = sys.argv[1]
doc = {
    "schema": "singular.orchestration.session-meta.v0",
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

task_decide() { # <meta> <lineage_head>
  singular_session_resume_decide "$1" implementer TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$2"
}

route() { singular_ctx_route "$@"; }

# run_dir WITH a durable artifact (packet.json is a source-class the resolver maps).
RUN_FULL="$tmp/run-full"; mkdir -p "$RUN_FULL"
META_FULL="$RUN_FULL/session-meta.json"; mk_task "$META_FULL"
printf '{"schema":"singular.orchestration.task-packet.v0","taskId":"TASK-1"}\n' \
  > "$RUN_FULL/packet.json"

# run_dir WITHOUT any durable artifact (only the meta itself, which is NOT a
# rehydration source class) -> empty-packet degrade.
RUN_EMPTY="$tmp/run-empty"; mkdir -p "$RUN_EMPTY"
META_EMPTY="$RUN_EMPTY/session-meta.json"; mk_task "$META_EMPTY"

lease_task="$(singular_ctx_route_session_lease_path implementer TASK-1)"
rm -f "$lease_task"
arm_lease()   { mkdir -p "$(dirname "$lease_task")"; printf '{"pid": %s}\n' "$$" > "$lease_task"; }
clear_lease() { rm -f "$lease_task"; }

# route call helpers pinned to the durable / empty run_dir metas.
# route <meta> <transcript> [DIFF_MAX override via env by caller]
route_full()  { route implementer implement "$META_FULL"  TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2" "$1" TASK-1 "$HEAD1"; }
route_empty() { route implementer implement "$META_EMPTY" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2" "$1" TASK-1 "$HEAD1"; }

# Sanity: the wrapped decider WOULD resume for the durable meta, so every refusal
# below is a genuine refused-resume lineage step (not a baseline fresh).
assert_eq "$(task_decide "$META_FULL" "$HEAD2")" "resume SID-T" \
  "sanity: decider resumes on the durable-run meta"

# =============================================================================
# 1. ON upgrade — refused resume + REHYDRATE=1 + durable artifact -> rehydrate
# =============================================================================
# (a) live session lease -> rehydrate session-lease (first refusal wins).
arm_lease
got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_SESSION_DIFF_MAX_LINES=0 \
  route_full "$NOTRANS")"
assert_eq "$got" "rehydrate session-lease" "ON upgrade: lease refusal -> rehydrate session-lease"
clear_lease
# (b) window pressure -> rehydrate window-pressure (missing transcript).
got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 route_full "$NOTRANS")"
assert_eq "$got" "rehydrate window-pressure" "ON upgrade: window refusal -> rehydrate window-pressure"
# (c) diff volume -> rehydrate diff-volume (churn>0 with threshold 0).
got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_SESSION_DIFF_MAX_LINES=0 \
  route_full "$TRANSCRIPT")"
assert_eq "$got" "rehydrate diff-volume" "ON upgrade: diff refusal -> rehydrate diff-volume"
pass "ON upgrade: lease/window/diff refusals emit rehydrate <reason> with a durable packet"

# =============================================================================
# 2. OFF-parity (SINGULAR_REHYDRATE) — byte-identical to pre-wire fresh <reason>
# =============================================================================
arm_lease
got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_SESSION_DIFF_MAX_LINES=0 route_full "$NOTRANS")"
assert_eq "$got" "fresh session-lease" "OFF-parity(REHYDRATE unset): lease -> fresh session-lease"
got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=0 SINGULAR_SESSION_DIFF_MAX_LINES=0 route_full "$NOTRANS")"
assert_eq "$got" "fresh session-lease" "OFF-parity(REHYDRATE=0): lease -> fresh session-lease"
clear_lease
got="$(SINGULAR_CTX_ROUTING=1 route_full "$NOTRANS")"
assert_eq "$got" "fresh window-pressure" "OFF-parity(REHYDRATE unset): window -> fresh window-pressure"
got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_SESSION_DIFF_MAX_LINES=0 route_full "$TRANSCRIPT")"
assert_eq "$got" "fresh diff-volume" "OFF-parity(REHYDRATE unset): diff -> fresh diff-volume"
pass "OFF-parity(SINGULAR_REHYDRATE): refusals stay fresh <reason> byte-for-byte"

# =============================================================================
# 3. OFF-parity (SINGULAR_CTX_ROUTING) — wrapped decider verbatim, no wire-in
# =============================================================================
want="$(task_decide "$META_FULL" "$HEAD2")"
got="$(SINGULAR_CTX_ROUTING=0 SINGULAR_REHYDRATE=1 route_full "$NOTRANS")"
assert_eq "$got" "$want" "OFF-parity(CTX_ROUTING=0): decider verbatim even with REHYDRATE=1"
got="$(SINGULAR_REHYDRATE=1 route_full "$NOTRANS")"   # flag unset -> default 0
assert_eq "$got" "$want" "OFF-parity(CTX_ROUTING unset): decider verbatim even with REHYDRATE=1"
pass "OFF-parity(SINGULAR_CTX_ROUTING): spine returns the wrapped decider line verbatim"

# =============================================================================
# 4. Independence pin unbroken — final-audit/paired-audit never rehydrate
# =============================================================================
for step in final-audit paired-audit; do
  got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 route implementer "$step" "$META_FULL" \
    TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2" "$NOTRANS" TASK-1 "$HEAD1")"
  assert_eq "$got" "fresh tainted" "$step: pinned to fresh tainted even with REHYDRATE=1"
  assert_ne "${got%% *}" "rehydrate" "$step: never rehydrate"
done
pass "independence pin: final-audit/paired-audit stay fresh tainted, never rehydrate"

# =============================================================================
# 5. Empty-packet degrade — REHYDRATE=1 but no durable artifact -> fresh <reason>
# =============================================================================
arm_lease
got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_SESSION_DIFF_MAX_LINES=0 \
  route_empty "$NOTRANS")"
assert_eq "$got" "fresh session-lease" "empty-packet: lease refusal stays fresh (nothing to inject)"
clear_lease
got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 route_empty "$NOTRANS")"
assert_eq "$got" "fresh window-pressure" "empty-packet: window refusal stays fresh"
got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_SESSION_DIFF_MAX_LINES=0 \
  route_empty "$TRANSCRIPT")"
assert_eq "$got" "fresh diff-volume" "empty-packet: diff refusal stays fresh"
# run_dir absent entirely (meta under a nonexistent dir) also degrades to fresh.
got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 route implementer implement \
  "$tmp/no-such-run/session-meta.json" TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2" \
  "$NOTRANS" TASK-1 "$HEAD1")"
# With an absent meta the decider itself goes fresh (no-session); assert we never
# fabricate a rehydrate from a missing run_dir.
assert_ne "${got%% *}" "rehydrate" "absent run_dir: never rehydrate"
pass "empty-packet degrade: refusals stay fresh <reason> with no durable artifact"

# =============================================================================
# 6. Baseline-fresh untouched — a wrapped-decider fresh passes through unchanged
# =============================================================================
BASE_FRESH="$RUN_FULL/base-fresh.json"; mk_task "$BASE_FRESH" "runner=other-run.sh"
assert_eq "$(task_decide "$BASE_FRESH" "$HEAD2")" "fresh runner-changed" \
  "sanity: decider baseline-fresh reason"
got="$(SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 route implementer implement "$BASE_FRESH" \
  TASK-1 RUN-1 codex-run.sh "$PSHA" "$wt" "$HEAD2" "$TRANSCRIPT" TASK-1 "$HEAD1")"
assert_eq "$got" "fresh runner-changed" "baseline-fresh: passes through unchanged under REHYDRATE=1"
assert_ne "${got%% *}" "rehydrate" "baseline-fresh: never upgraded to rehydrate"
pass "baseline-fresh untouched: only the three resume-gate refusals are upgraded"

# =============================================================================
# 7. Contract — exactly one line, exit 0, and rehydrate stays tainted
# =============================================================================
check_one_line() { # <output> <label>
  [[ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" == "1" ]] || fail "$2: expected exactly one line"
  local strat="${1%% *}" rest="${1#* }"
  case "$strat" in
    continue|resume|fork|fresh|rehydrate) ;;
    *) fail "$2: strategy [$strat] not in the alphabet" ;;
  esac
  [[ -n "$rest" && "$rest" != "$1" ]] || fail "$2: decision carries no reason: [$1]"
}
arm_lease
rc=0; out="$(SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 route_full "$NOTRANS")" || rc=$?
clear_lease
assert_eq "$rc" "0" "spine exit 0 (rehydrate path)"
check_one_line "$out" "rehydrate path"
assert_eq "${out%% *}" "rehydrate" "rehydrate strategy emitted"
# Evidence invariance: rehydrate is tainted -> never eligible for independence.
assert_eq "$(singular_ctx_route_strategy_tainted rehydrate)" "1" \
  "rehydrate strategy remains tainted"
pass "contract: exactly one line, exit 0, rehydrate stays tainted"

echo "ctx-rehydrate-route tests passed"
