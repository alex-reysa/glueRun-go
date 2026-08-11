#!/usr/bin/env bash
# SINGULAR-owned module: storage-proof durable-proof regime.
#
# This is NOT part of the generic engine. It is loaded only by repos that list
# "storage-proof" in their config `modules` (SINGULAR_MODULES). It overrides the
# engine's generic extension hooks (singular_select_l2_runner, singular_packet_module_guard,
# singular_worker_contract_extra) to enforce that a durable storage proof carries a
# red "skip-guard" command proving the proof fails when real storage is stripped.
#
# Enable via singular.config.json:
#   "modules": ["storage-proof"],
#   "proofLayers": ["storage_proof"],
#   "proofGrandfather": ["D1.storage_proof", "D2.storage_proof"]

singular_task_requires_storage_proof_red_guard() {
  local task_file="$1"
  [[ -f "$task_file" ]] || return 1
  python3 - "$task_file" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()

def section(name):
    match = re.search(rf"^## {re.escape(name)}\n(?P<body>.*?)(?=^## |\Z)", text, re.M | re.S)
    return match.group("body") if match else ""

objective = section("Objective").lower()
criteria = section("Acceptance Criteria").lower()
required = section("Required Evidence").lower()
scope_text = "\n".join([objective, criteria, required])

is_storage_proof = (
    "storage_proof" in objective
    or "storage_proof_complete" in criteria
    or "storage_proof_complete" in required
)
requires_marked_red = (
    "skip-guard-red" in required
    or "marked nonzero" in criteria
    or "storage-stripped" in criteria
)
durable_proof = (
    "round-trip proof" in objective
    or "repository conformance proof" in objective
    or ("real postgresql" in scope_text and "proof" in objective)
)

sys.exit(0 if is_storage_proof and durable_proof and requires_marked_red else 1)
PY
}

# Override: route storage_proof tasks to a real-Postgres-capable (claude) runner;
# every other task keeps the default. An explicit SINGULAR_RUNNER override always wins.
singular_select_l2_runner() {
  local task_file="$1" default_runner="$2" claude_runner="${3:-}"
  if [[ -n "${SINGULAR_RUNNER:-}" ]]; then
    printf '%s\n' "$default_runner"; return 0
  fi
  if [[ -n "$claude_runner" && -x "$claude_runner" ]] \
     && singular_task_requires_storage_proof_red_guard "$task_file"; then
    printf '%s\n' "$claude_runner"; return 0
  fi
  printf '%s\n' "$default_runner"
}

# Override: red-evidence log path for storage_proof tasks. The skip-guard red
# artifact IS the task's single red log (one red artifact, not red.log plus a
# second skip-guard file); every other task keeps the prompt's default red log.
singular_worker_red_log() {
  local task_file="$1" task_id="${2:-}"
  singular_task_requires_storage_proof_red_guard "$task_file" || { printf ''; return 0; }
  printf '.singular-evidence/%s-skip-guard-red\n' "$task_id"
}

# Override: extra worker-prompt contract text for storage_proof tasks. The base
# contract already names the red log (rewritten by singular_worker_red_log above);
# this only adds the skip-guard requirements that single red artifact must meet.
singular_worker_contract_extra() {
  local task_file="$1" task_id="${2:-}"
  singular_task_requires_storage_proof_red_guard "$task_file" || { printf ''; return 0; }
  cat <<EOF
- Storage-proof red guard: your red log \`.singular-evidence/${task_id}-skip-guard-red\`
  above is the ONLY red artifact; do not write any other red evidence file.
  Produce it by running a storage-stripped proof command with both
  \`SINGULAR_STORAGE_PROOF_DATABASE_URL\` and \`SINGULAR_DATABASE_URL\` unset; it must exit
  nonzero. In the final packet, include that exact path as a nonzero command
  \`logRef\`, a red test \`logRef\`, and an evidence \`ref\`; the ref must end
  exactly in \`-skip-guard-red\`.
EOF
}

# Override: enforce the storage-proof packet guard.
singular_packet_module_guard() {
  local packet="$1" task_file="$2" workspace="${3:-}" run_dir="${4:-}"
  if ! singular_task_requires_storage_proof_red_guard "$task_file"; then
    return 0
  fi
  python3 - "$packet" "$task_file" "$workspace" "$run_dir" <<'PY'
import json
import os
import sys

packet_path, task_path, workspace, run_dir = sys.argv[1:5]
with open(packet_path, "r", encoding="utf-8") as f:
    packet = json.load(f)

def fail(message):
    print(message, file=sys.stderr)
    sys.exit(2)

def as_int(value):
    try:
        return int(value)
    except Exception:
        return 999

def candidates(ref):
    if not ref:
        return []
    if os.path.isabs(ref):
        return [ref]
    out = []
    if workspace:
        out.append(os.path.join(workspace, ref))
    if run_dir:
        out.append(os.path.join(run_dir, ref))
        if ref.startswith(".singular-evidence/"):
            out.append(os.path.join(run_dir, "worker-evidence", os.path.basename(ref)))
    return out

def exists(ref):
    paths = candidates(ref)
    return bool(paths) and any(os.path.isfile(path) for path in paths)

marked_red_commands = []
for idx, command in enumerate(packet.get("commands", [])):
    ref = str(command.get("logRef", ""))
    if as_int(command.get("exitCode")) != 0 and ref.endswith("-skip-guard-red"):
        marked_red_commands.append((idx, command, ref))

if not marked_red_commands:
    fail(
        "storage_proof packet requires a nonzero command logRef ending in "
        "-skip-guard-red for the storage-stripped proof path"
    )

storage_stripped = []
for idx, command, ref in marked_red_commands:
    cmd = str(command.get("cmd", ""))
    lowered = cmd.lower()
    has_storage_envs = "singular_storage_proof_database_url" in lowered and "singular_database_url" in lowered
    strips_env = "env -u" in lowered or "unset " in lowered or "\nunset" in lowered
    if has_storage_envs and strips_env:
        storage_stripped.append((idx, command, ref))

if not storage_stripped:
    fail(
        "storage_proof skip-guard red command must visibly strip both "
        "SINGULAR_STORAGE_PROOF_DATABASE_URL and SINGULAR_DATABASE_URL"
    )

evidence_refs = {str(item.get("ref", "")) for item in packet.get("evidence", [])}
red_test_refs = {
    str(test.get("logRef", ""))
    for test in packet.get("tests", [])
    if "red" in str(test.get("phase", "")).lower()
}

missing = []
for _, _, ref in storage_stripped:
    if not exists(ref):
        missing.append(f"storage_proof skip-guard red evidence missing: {ref}")
    if ref not in evidence_refs:
        missing.append(f"storage_proof skip-guard red command logRef is not declared in evidence: {ref}")
    if ref not in red_test_refs:
        missing.append(f"storage_proof skip-guard red command logRef is not declared as red test evidence: {ref}")

if missing:
    fail("\n".join(missing))

print("ok")
PY
}

# Override: external-resource blocker (real PostgreSQL proof env required).
singular_gate_red_external_proof_env_blocker() {
  local context_file="$1"
  [[ -f "$context_file" ]] || return 1
  [[ -z "${SINGULAR_STORAGE_PROOF_DATABASE_URL:-}" && -z "${SINGULAR_DATABASE_URL:-}" ]] || return 1
  grep -Eq 'SINGULAR_STORAGE_PROOF_DATABASE_URL|SINGULAR_DATABASE_URL' "$context_file" || return 1
  grep -Eiq 'real PostgreSQL|PostgreSQL database' "$context_file" || return 1
  grep -Eiq 'must not silently skip|no silent skip|in-memory/SQLite substitute' "$context_file" || return 1
}

# Override: detect a skipped proof path (Go t.Skip in an owned *_test.go).
singular_strict_proof_skip_detected() {
  local task_file="$1" worktree="$2" path full_path
  shift 2
  [[ -f "$task_file" && -d "$worktree" ]] || return 1
  grep -Eiq 'must not silently skip|no silent skip|non-skipped durable|must not pass through .*skipped' "$task_file" || return 1
  for path in "$@"; do
    case "$path" in
      *_test.go)
        full_path="$worktree/$path"
        [[ -f "$full_path" ]] || continue
        grep -Eq '(^|[^[:alnum:]_])t[.][[:space:]]*Skip(f|Now)?[[:space:]]*[(]' "$full_path" && return 0
        ;;
    esac
  done
  return 1
}

# Override: terminal parking rationale for proof-related failure classes.
singular_terminal_blocker_rationale() {
  local failure_class="$1" ctx="${2:-/dev/null}"
  case "$failure_class" in
    gate-red)
      if singular_gate_red_external_proof_env_blocker "$ctx"; then
        printf '%s' "gate-red requires a real PostgreSQL proof environment, but neither SINGULAR_STORAGE_PROOF_DATABASE_URL nor SINGULAR_DATABASE_URL is set; parking instead of retrying L2 so the proof cannot be weakened or skipped"
      fi
      ;;
    proof-skip-detected)
      printf '%s' "strict proof task introduced a skipped proof path; parking instead of retrying because the acceptance criteria require a non-skipped real-store proof"
      ;;
  esac
}
