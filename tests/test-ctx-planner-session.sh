#!/usr/bin/env bash
# Covers the planner session-meta library brick engine/ctx-planner-session.sh:
# a pure per-node path helper + a default-OFF SINGULAR_PLANNER_SESSION finalize
# wrapper that reuses the singular.orchestration.session-meta.v0 shape (via
# singular_session_meta_finalize) adding role "planner" and an additive optional
# `node` field. Asserts:
#   (path) the canonical path is .singular-state/sessions/planner/<node>.json under
#          the runtime state dir (SINGULAR_STATE_DIR) and never under docs/;
#   (a) success (rc 0) + knob ON -> a valid finalized meta at the canonical path
#       with role "planner", node == target node, and headShaAtCreate == the head
#       sha passed at planning time;
#   (b) planner-failed (rc != 0) + knob ON -> NO finalized meta at the canonical
#       path (evidence invariance: a rejected planner lineage is not extended);
#   (c) knob OFF (unset AND =0) -> no-op / no file written, independent of rc.
# The functions are additive; no existing engine path invokes them, so with the
# file present-but-uncalled the engine is byte-identical to prior behavior.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_PS="$ENGINE_HOME/engine/ctx-planner-session.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its state dir --------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the planner-session functions (RED before
# it is written). lib.sh auto-sources it; source again defensively.
[[ -f "$CTX_PS" ]] || fail "engine not present yet: $CTX_PS"
# shellcheck disable=SC1090
source "$CTX_PS" || fail "sourcing $CTX_PS failed"
[[ "$(type -t singular_ctx_planner_session_path)" == "function" ]] \
  || fail "singular_ctx_planner_session_path not defined by $CTX_PS"
[[ "$(type -t singular_ctx_planner_session_finalize)" == "function" ]] \
  || fail "singular_ctx_planner_session_finalize not defined by $CTX_PS"

NODE="planner-session-meta"
HEAD_SHA="1d593959e95783c627cd00888a05558368458d58"

# ---------------------------------------------------------------------------
# (path) Canonical per-node path under the runtime state dir, never under docs/.
# ---------------------------------------------------------------------------
canon="$(singular_ctx_planner_session_path "$NODE")"
[[ "$canon" == "$SINGULAR_STATE_DIR/sessions/planner/$NODE.json" ]] \
  || fail "path: expected $SINGULAR_STATE_DIR/sessions/planner/$NODE.json, got $canon"
[[ "$canon" == *"/.singular-state/"* || "$canon" == "$SINGULAR_STATE_DIR/"* ]] \
  || fail "path: not under the runtime state dir: $canon"
[[ "$canon" != *"/docs/"* ]] || fail "path: session-meta placed under docs/ (runtime state, not repo truth): $canon"

# ---------------------------------------------------------------------------
# (a) success (rc 0) + knob ON -> valid finalized meta with role/node/headSha.
# ---------------------------------------------------------------------------
export SINGULAR_PLANNER_SESSION=1
rm -f "$canon"
singular_ctx_planner_session_finalize "$NODE" 0 "TASK-0007" "RUN-1" \
  "codex-run.sh" "deadbeef" "$HEAD_SHA" 1 \
  || fail "success+ON: finalize crashed"
[[ -f "$canon" ]] || fail "success+ON: no finalized meta at $canon"
python3 - "$canon" "$NODE" "$HEAD_SHA" <<'PY' || fail "success+ON: finalized meta invalid"
import json, sys
path, node, head = sys.argv[1:4]
doc = json.load(open(path))
assert doc.get("schema") == "singular.orchestration.session-meta.v0", doc
assert doc.get("role") == "planner", doc
assert doc.get("node") == node, doc
assert doc.get("taskId") == "TASK-0007", doc
assert doc.get("runId") == "RUN-1", doc
assert doc.get("headShaAtCreate") == head, doc
print("success-ok")
PY

# ---------------------------------------------------------------------------
# (b) planner-failed (rc != 0) + knob ON -> NO finalized meta (evidence
#     invariance: a rejected planner lineage is not extended).
# ---------------------------------------------------------------------------
rm -f "$canon"
singular_ctx_planner_session_finalize "$NODE" 1 "TASK-0007" "RUN-2" \
  "codex-run.sh" "deadbeef" "$HEAD_SHA" 1 \
  || fail "failed+ON: finalize crashed"
[[ ! -e "$canon" ]] || fail "failed+ON: a resumable meta was written for a failed planner run"

# ---------------------------------------------------------------------------
# (c) knob OFF (unset AND =0) -> no-op / no file written, independent of rc.
# ---------------------------------------------------------------------------
unset SINGULAR_PLANNER_SESSION
rm -f "$canon"
singular_ctx_planner_session_finalize "$NODE" 0 "TASK-0007" "RUN-3" \
  "codex-run.sh" "deadbeef" "$HEAD_SHA" 1 \
  || fail "OFF(unset): finalize crashed"
[[ ! -e "$canon" ]] || fail "OFF(unset): finalized meta written while knob OFF"

export SINGULAR_PLANNER_SESSION=0
rm -f "$canon"
singular_ctx_planner_session_finalize "$NODE" 0 "TASK-0007" "RUN-4" \
  "codex-run.sh" "deadbeef" "$HEAD_SHA" 1 \
  || fail "OFF(=0): finalize crashed"
[[ ! -e "$canon" ]] || fail "OFF(=0): finalized meta written while knob OFF"

# OFF is a no-op independent of rc (a failed run under OFF is still a no-op).
rm -f "$canon"
singular_ctx_planner_session_finalize "$NODE" 1 "TASK-0007" "RUN-5" \
  "codex-run.sh" "deadbeef" "$HEAD_SHA" 1 \
  || fail "OFF(=0, rc!=0): finalize crashed"
[[ ! -e "$canon" ]] || fail "OFF(=0, rc!=0): finalized meta written while knob OFF"

echo "ctx-planner-session tests passed"
