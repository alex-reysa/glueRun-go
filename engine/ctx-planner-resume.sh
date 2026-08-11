#!/usr/bin/env bash
# ctx-planner-resume.sh — the planner-role resume decision behind the default-OFF
# SINGULAR_PLANNER_SESSION knob.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-planner-session.sh). The generate-tasks.sh call site that consults
# this decider only when SINGULAR_PLANNER_SESSION=1, the resume-refused rc-86 fresh
# fallback, the role=planner strategy events, and the finalize->decide TEMPLATE-sha
# round-trip are the sanctioned follow-up slices of this node and are OUT OF SCOPE
# here.
#
# singular_planner_resume_decide is the planner-role variant of the integrated
# task-role singular_session_resume_decide in lib.sh: the same single-line
# `resume <sessionId>` / `fresh <reason>` contract, ordered fail-closed gates
# where the FIRST failing gate names the reason, reusing the
# singular.orchestration.session-meta.v0 shape (planner writes an additive optional
# `node` field; all task-role fields remain valid).
#
# Gate order (first failure wins):
#   1. disabled              SINGULAR_PLANNER_SESSION unset/!=1 (default 0 = OFF)
#   2. no-session            meta missing / unparseable
#   3. no-session-id         empty provider or sessionId
#   4. role-mismatch         role is not exactly "planner"
#   5. node-mismatch         meta.node != target node          (replaces runId eq)
#   6. head-rewritten        meta.headShaAtCreate NOT an ancestor of target head
#   7. runner-changed        runner basename differs
#   8. prompt-template-changed  meta.promptSha256 != sha256(l1-planner.md TEMPLATE)
#   9. expired               age > SINGULAR_SESSION_MAX_AGE_SEC
#  10. worktree-moved        meta.cwd != worktree
#  11. leased                a LIVE lease held at the canonical planner lease path
#   -> resume <sessionId>    when every gate passes
#
# Evidence invariance: every gate fails closed. Any ambiguity — missing/unparseable
# meta, unreadable template, indeterminate ancestry, empty/absent fields, a lease
# whose holder cannot be proven dead — resolves to `fresh <reason>`, NEVER to
# `resume`. Routing never weakens a gate to make a fresh-required decision
# resumable. The function prints EXACTLY one line and never exits non-zero.

# Pure helper: canonical planner TEMPLATE path. The template-sha gate keys on the
# TEMPLATE file (NOT the rendered prompt, which varies per frontier by design).
# Override with SINGULAR_PLANNER_TEMPLATE; default lives under SINGULAR_ROOT.
singular_planner_resume_template_path() {
  if [[ -n "${SINGULAR_PLANNER_TEMPLATE:-}" ]]; then
    printf '%s' "$SINGULAR_PLANNER_TEMPLATE"; return 0
  fi
  printf '%s/docs/orchestration/prompts/l1-planner.md' "${SINGULAR_ROOT:-.}"
}

# Pure helper: canonical per-node planner session-lease path. A live lease here
# means another L1 fanout is (re)using this planner session; the decider must not
# resume it concurrently. Lives beside the planner session-meta under the runtime
# state dir, NEVER under docs/. Empty node -> empty (caller decides).
singular_planner_resume_lease_path() {
  local node="$1"
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }
  local state_dir="${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}"
  printf '%s/sessions/planner/%s.lease' "$state_dir" "$node"
}

# Liveness of a planner session-lease. Returns 0 (held/live) fail-closed:
#   - no lease file            -> 1 (free)
#   - file present, live PID    -> 0 (held)
#   - file present, dead PID    -> 1 (free; a crashed holder is not concurrency)
#   - file present, no PID found -> 0 (held; cannot prove it is free -> fail closed)
singular_planner_resume_lease_live() {
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

# Decide whether the next planner run may resume the recorded session. Prints
# EXACTLY one line: `resume <sessionId>` or `fresh <reason>`. Never exits non-zero.
#   singular_planner_resume_decide <meta_path> <node> <runner_basename> \
#                                 <worktree> <lineage_head>
singular_planner_resume_decide() {
  local meta_path="$1" node="$2" runner="$3" worktree="$4" lineage_head="$5"

  # Gate 1: feature-flag disabled (default 0 = OFF).
  if [[ "${SINGULAR_PLANNER_SESSION:-0}" != "1" ]]; then
    printf 'fresh disabled\n'; return 0
  fi
  # Gate 2: meta missing.
  if [[ ! -f "$meta_path" ]]; then
    printf 'fresh no-session\n'; return 0
  fi
  # Parse all fields in one python pass; one field per line (empty values read
  # cleanly into an array, unlike a tab-delimited `read`). Parse failure ->
  # "__UNPARSEABLE__" -> no-session. Values are session ids / shas / paths and
  # never contain newlines.
  local parsed
  parsed="$(python3 - "$meta_path" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        m = json.load(f)
    assert isinstance(m, dict)
except Exception:
    print("__UNPARSEABLE__")
    sys.exit(0)
def g(k):
    v = m.get(k, "")
    return "" if v is None else str(v).replace("\n", " ")
for val in (g("provider"), g("sessionId"), g("role"), g("node"),
            g("runner"), g("promptSha256"), g("createdAt"),
            g("headShaAtCreate"), g("cwd")):
    print(val)
PY
)"
  if [[ -z "$parsed" || "$parsed" == "__UNPARSEABLE__"* ]]; then
    printf 'fresh no-session\n'; return 0
  fi
  local m_fields=()
  while IFS= read -r line; do m_fields+=("$line"); done <<<"$parsed"
  local m_provider="${m_fields[0]:-}" m_sid="${m_fields[1]:-}" m_role="${m_fields[2]:-}"
  local m_node="${m_fields[3]:-}" m_runner="${m_fields[4]:-}" m_psha="${m_fields[5]:-}"
  local m_created="${m_fields[6]:-}" m_head="${m_fields[7]:-}" m_cwd="${m_fields[8]:-}"

  # Gate 3: provider or sessionId empty.
  if [[ -z "$m_provider" || -z "$m_sid" ]]; then
    printf 'fresh no-session-id\n'; return 0
  fi
  # Gate 4: planner-role gate (advocate/skeptic line). Resume ONLY a meta whose
  # role is exactly "planner"; any other role is a different lineage.
  if [[ "$m_role" != "planner" ]]; then
    printf 'fresh role-mismatch\n'; return 0
  fi
  # Gate 5: node-lineage — target node equality (replaces the task-role runId eq).
  if [[ "$m_node" != "$node" ]]; then
    printf 'fresh node-mismatch\n'; return 0
  fi
  # Gate 6: node-lineage — headShaAtCreate must be an ancestor of the current
  # target-branch head. Fail closed: empty stored head, empty lineage head, or
  # indeterminate ancestry all resolve to head-rewritten (never resume).
  if [[ -z "$m_head" || -z "$lineage_head" ]] \
     || ! git -C "$worktree" merge-base --is-ancestor "$m_head" "$lineage_head" 2>/dev/null; then
    printf 'fresh head-rewritten\n'; return 0
  fi
  # Gate 7: runner changed.
  if [[ "$m_runner" != "$runner" ]]; then
    printf 'fresh runner-changed\n'; return 0
  fi
  # Gate 8: prompt-template changed. Key on the TEMPLATE sha (NOT the rendered
  # prompt). An unreadable template -> empty sha -> mismatch (fail closed).
  local tpl_path tpl_sha
  tpl_path="$(singular_planner_resume_template_path)"
  tpl_sha="$(singular_sha256_file "$tpl_path" 2>/dev/null || printf '%s' "")"
  if [[ -z "$tpl_sha" || "$m_psha" != "$tpl_sha" ]]; then
    printf 'fresh prompt-template-changed\n'; return 0
  fi
  # Gate 9: expired per SINGULAR_SESSION_MAX_AGE_SEC. Missing/unparseable createdAt
  # -> EXPIRED (fail closed).
  local max_age="${SINGULAR_SESSION_MAX_AGE_SEC:-14400}"
  local age_ok
  age_ok="$(python3 - "$m_created" "$max_age" <<'PY' 2>/dev/null || true
import sys
from datetime import datetime, timezone
created, max_age = sys.argv[1], sys.argv[2]
try:
    max_age = int(max_age)
except Exception:
    max_age = 14400
if not created:
    print("EXPIRED"); sys.exit(0)
s = created.strip().replace("Z", "+00:00")
try:
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
except Exception:
    print("EXPIRED"); sys.exit(0)
age = (datetime.now(timezone.utc) - dt).total_seconds()
print("OK" if age <= max_age else "EXPIRED")
PY
)"
  if [[ "$age_ok" != "OK" ]]; then
    printf 'fresh expired\n'; return 0
  fi
  # Gate 10: worktree moved.
  if [[ "$m_cwd" != "$worktree" ]]; then
    printf 'fresh worktree-moved\n'; return 0
  fi
  # Gate 11: session-lease. A live lease at the canonical planner lease path means
  # a parallel L1 fanout is already using this planner session — never resume it
  # concurrently.
  local lease_path
  lease_path="$(singular_planner_resume_lease_path "$node")"
  if singular_planner_resume_lease_live "$lease_path"; then
    printf 'fresh leased\n'; return 0
  fi

  printf 'resume %s\n' "$m_sid"
}
