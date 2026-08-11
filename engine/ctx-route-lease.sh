#!/usr/bin/env bash
# ctx-route-lease.sh — the generalized session-lease read helpers, generalizing
# the Stage-1 planner-only lease discipline (singular_planner_resume_lease_path /
# _live, hard-coded to sessions/planner/<node>.lease) to every persisted session
# of any role. A live lease here means another fanout is (re)using that role's
# session; a router of any role must not resume it concurrently.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# by construction, mirroring engine/ctx-route-window.sh). This is the READ side
# only — the lease-write/acquire/release lifecycle is a driver concern wired in a
# later slice, exactly as the planner lease lifecycle was. The SINGULAR_CTX_ROUTING
# wire-in and the engine/ctx-route.sh spine that composes these helpers are later
# slices of the routing-module node and are OUT OF SCOPE here.
#
# singular_ctx_route_session_lease_path <role> <key>
#
# Canonical role-generic lease path <state-dir>/sessions/<role>/<key>.lease with
# state-dir ${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}. Empty role OR
# empty key -> empty string (caller decides). This reduces to the integrated
# planner path for role `planner`, key `<node>`.
singular_ctx_route_session_lease_path() {
  local role="$1" key="$2"
  [[ -n "$role" && -n "$key" ]] || { printf '%s' ""; return 0; }
  local state_dir="${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}"
  printf '%s/sessions/%s/%s.lease' "$state_dir" "$role" "$key"
}

# singular_ctx_route_session_lease_live <lease-path>
#
# Liveness of a session-lease. Reproduces the integrated planner lease helper's
# fail-closed verdict table so a router of any role can refuse resume while
# another fanout holds the session. Returns 0 (held/live) or 1 (free/not-live) by
# RETURN STATUS; never exits the shell non-zero abnormally.
#   - no lease file             -> 1 (free)
#   - file present, live PID     -> 0 (held)
#   - file present, dead PID     -> 1 (free; a crashed holder is not concurrency)
#   - file present, no PID found -> 0 (held; cannot prove it is free -> fail closed)
singular_ctx_route_session_lease_live() {
  local lease_path="$1"
  [[ -n "$lease_path" && -f "$lease_path" ]] || return 1
  local pid
  pid="$(python3 - "$lease_path" <<'PY' 2>/dev/null || true
import json, re, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        raw = f.read()
except Exception:
    sys.exit(0)
pid = ""
try:
    doc = json.loads(raw)
    if isinstance(doc, dict) and doc.get("pid") is not None:
        pid = str(doc["pid"]).strip()
except Exception:
    pid = ""
if not pid:
    m = re.search(r"\d+", raw)
    pid = m.group(0) if m else ""
print(pid)
PY
)"
  # Fail closed: a lease file we cannot read a PID from is treated as held.
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then return 0; fi
  return 1
}
