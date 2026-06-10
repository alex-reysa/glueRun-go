#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "accept-existing-packet.sh requires bash >= 4 (mapfile); install via 'brew install bash'" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  echo "usage: $0 path/to/state-packet.json" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
packet="$1"
[[ -f "$packet" ]] || { echo "packet not found: $packet" >&2; exit 2; }

scope_worktree=""
cleanup() {
  if [[ -n "$scope_worktree" ]]; then
    git -C "$GLUERUN_ROOT" worktree remove --force "$scope_worktree" >/dev/null 2>&1 || rm -rf "$scope_worktree"
  fi
}
trap cleanup EXIT

gluerun_ensure_state_dirs
gluerun_require_target_branch
gluerun_validate_packet_basic "$packet" >/dev/null

task_id="$(gluerun_json_field "$packet" taskId)"
run_id="$(gluerun_json_field "$packet" runId)"
branch="$(gluerun_json_field "$packet" branch)"
head_sha="$(gluerun_json_field "$packet" headSha)"
base_ref="$(gluerun_json_field "$packet" baseRef)"
workspace="$(gluerun_json_field "$packet" workspace)"
run_dir="$GLUERUN_RUNS_DIR/$run_id"
audit_record="$(gluerun_audit_record_path "$run_id")"
task_file="$GLUERUN_TASKS_DIR/$task_id.md"

[[ -f "$task_file" ]] || { echo "task file not found: $task_file" >&2; exit 2; }
[[ -d "$workspace" ]] || { echo "packet workspace not found: $workspace" >&2; exit 2; }
[[ -d "$run_dir" ]] || { echo "run dir not found: $run_dir" >&2; exit 2; }

if find "$GLUERUN_ORCH_DIR/packets/imported/$task_id" -maxdepth 1 -name '*.json' -not -name '*.audit.json' -type f 2>/dev/null | grep -q .; then
  echo "task already imported: $task_id" >&2
  exit 2
fi
if [[ -f "$GLUERUN_INBOX_DIR/$run_id.json" ]]; then
  echo "packet already queued in inbox: $GLUERUN_INBOX_DIR/$run_id.json" >&2
  exit 2
fi
if find "$GLUERUN_INBOX_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null \
  | while IFS= read -r p; do [[ "$(gluerun_json_field "$p" taskId 2>/dev/null || true)" == "$task_id" ]] && echo "$p"; done \
  | grep -q .; then
  echo "task already queued in inbox: $task_id" >&2
  exit 2
fi

if ! git -C "$GLUERUN_ROOT" rev-parse --verify --quiet "$branch" >/dev/null; then
  echo "packet branch not found: $branch" >&2
  exit 2
fi
actual_head="$(git -C "$GLUERUN_ROOT" rev-parse "$branch")"
if [[ "$actual_head" != "$head_sha" ]]; then
  echo "packet headSha $head_sha does not match branch head $actual_head" >&2
  exit 2
fi
workspace_head="$(git -C "$workspace" rev-parse HEAD)"
if [[ "$workspace_head" != "$actual_head" ]]; then
  echo "packet workspace HEAD $workspace_head does not match branch head $actual_head" >&2
  exit 2
fi
if ! git -C "$workspace" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null; then
  echo "packet baseRef is not available in workspace: $base_ref" >&2
  exit 2
fi
non_generated_dirty="$(
  git -C "$workspace" status --porcelain --untracked-files=all \
    | sed 's/^...//' \
    | while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        p="${p##* -> }"
        case "$p" in
          .gluerun-cache|.gluerun-cache/*|.gluerun-state|.gluerun-state/*|.gluerun-evidence|.gluerun-evidence/*) ;;
          *) printf '%s\n' "$p" ;;
        esac
      done
)"
if [[ -n "$non_generated_dirty" ]]; then
  echo "workspace has uncommitted non-generated changes; refusing deterministic acceptance:" >&2
  printf '  %s\n' $non_generated_dirty >&2
  exit 2
fi

mapfile -t owned_files < <(python3 - "$packet" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
for path in data["ownedFiles"]:
    print(path)
PY
)
[[ "${#owned_files[@]}" -gt 0 ]] || { echo "packet declares no owned files" >&2; exit 2; }

task_json="$(gluerun_task_json "$task_file")"
mapfile -t forbidden_files < <(printf '%s' "$task_json" | python3 -c 'import json,sys
data=json.load(sys.stdin)
for path in data.get("forbiddenFiles", []):
    if "/" in path and " " not in path:
        print(path)
')

scope_log="$run_dir/accept-existing-packet-scope.log"
scope_worktree="$(mktemp -d "$run_dir/accept-existing-packet-scope.XXXXXX")"
rmdir "$scope_worktree"
git -C "$GLUERUN_ROOT" worktree add --detach -q "$scope_worktree" "$actual_head"
scope_args=(--worktree "$scope_worktree" --base "$base_ref")
for f in "${owned_files[@]}"; do scope_args+=(--allow-prefix "$f"); done
for f in "${forbidden_files[@]}"; do scope_args+=(--forbid-prefix "$f"); done
if ! "$SCRIPT_DIR/scope-check.sh" "${scope_args[@]}" >"$scope_log" 2>&1; then
  cat "$scope_log" >&2
  exit 2
fi

secret_log="$run_dir/accept-existing-packet-secret-scan.log"
if ! "$SCRIPT_DIR/secret-scan.sh" --worktree "$workspace" --range "$base_ref..HEAD" >"$secret_log" 2>&1; then
  cat "$secret_log" >&2
  exit 2
fi

cmd_list="$run_dir/accept-existing-packet-commands.jsonl"
python3 - "$packet" "$workspace" "$run_dir" "$cmd_list" <<'PY'
import json
import os
import sys

packet_path, workspace, run_dir, cmd_list = sys.argv[1:5]
with open(packet_path, encoding="utf-8") as f:
    packet = json.load(f)

def candidates(ref):
    if not ref:
        return []
    if os.path.isabs(ref):
        return [ref]
    out = [
        os.path.join(workspace, ref),
        os.path.join(run_dir, ref),
    ]
    if ref.startswith(".gluerun-evidence/"):
        out.append(os.path.join(run_dir, "worker-evidence", os.path.basename(ref)))
    if ref.startswith("runs/"):
        out.append(os.path.join(os.path.dirname(os.path.dirname(run_dir)), ref))
    return out

def exists(ref):
    return any(os.path.isfile(path) for path in candidates(ref))

phases = {"red": False, "green": False, "regression": False}
missing = []
for test in packet.get("tests", []):
    phase = str(test.get("phase", "")).lower()
    ref = test.get("logRef", "")
    for key in list(phases):
        if key in phase:
            phases[key] = True
            if not exists(ref):
                missing.append(f"{key} evidence missing: {ref}")

for key, seen in phases.items():
    if not seen:
        missing.append(f"{key} test evidence not declared")

rerun = []
for idx, command in enumerate(packet.get("commands", [])):
    ref = command.get("logRef", "")
    if ref and not exists(ref):
        missing.append(f"command evidence missing: {ref}")
    if int(command.get("exitCode", 999)) == 0:
        rerun.append({"idx": idx, "cmd": command.get("cmd", "")})

if not rerun:
    missing.append("no successful packet commands available to rerun")
if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(2)

with open(cmd_list, "w", encoding="utf-8") as f:
    for command in rerun:
        f.write(json.dumps(command, separators=(",", ":")) + "\n")
PY

storage_guard_log="$run_dir/accept-existing-packet-module-guard.log"
if ! gluerun_packet_module_guard "$packet" "$task_file" "$workspace" "$run_dir" >"$storage_guard_log" 2>&1; then
  cat "$storage_guard_log" >&2
  exit 2
fi

rerun_logs="$run_dir/accept-existing-packet-rerun-logs.txt"
: >"$rerun_logs"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  idx="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["idx"])' "$line")"
  cmd="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["cmd"])' "$line")"
  log="$run_dir/accept-existing-packet-command-$idx.log"
  if ! (cd "$workspace" && bash -lc "$cmd") >"$log" 2>&1; then
    echo "packet command failed during deterministic acceptance: $cmd (log: $log)" >&2
    cat "$log" >&2
    exit 2
  fi
  printf '%s\n' "$log" >>"$rerun_logs"
done <"$cmd_list"

python3 - "$packet" "$audit_record" "$scope_log" "$secret_log" "$cmd_list" "$rerun_logs" "$GLUERUN_AUDIT_SCHEMA" <<'PY'
import json
import os
import sys

packet_path, audit_path, scope_log, secret_log, cmd_list, rerun_logs, schema_path = sys.argv[1:8]
with open(packet_path, encoding="utf-8") as f:
    packet = json.load(f)
with open(cmd_list, encoding="utf-8") as f:
    commands = [json.loads(line)["cmd"] for line in f if line.strip()]
with open(rerun_logs, encoding="utf-8") as f:
    logs = [line.strip() for line in f if line.strip()]

evidence = [
    packet_path,
    scope_log,
    secret_log,
    *logs,
]
for item in packet.get("evidence", []):
    ref = item.get("ref")
    if ref:
        evidence.append(ref)

audit = {
    "schema": "gluerun.orchestration.audit-verdict.v0",
    "taskId": packet["taskId"],
    "runId": packet["runId"],
    "branch": packet["branch"],
    "verdict": "accepted",
    "evidenceReviewed": evidence,
    "commandsRun": [
        "scope-check.sh " + " ".join(packet.get("ownedFiles", [])),
        "secret-scan.sh --range " + packet["baseRef"] + "..HEAD",
        *commands,
    ],
    "findings": [
        "deterministic acceptance for an existing stranded packet",
        "packet branch head matched packet headSha",
        "scope check, secret scan, and current successful packet commands passed",
    ],
    "requiredFixes": [],
    "rationale": "Existing worker output was accepted deterministically because the packet is valid, branch head matches, scope is clean, evidence is present, and successful packet commands pass when rerun.",
}

with open(schema_path, encoding="utf-8") as f:
    schema = json.load(f)
missing = [key for key in schema["required"] if key not in audit]
extra = sorted(set(audit) - set(schema["properties"]))
if missing or extra:
    raise SystemExit(f"audit schema validation failed; missing={missing} extra={extra}")
if audit["schema"] != schema["properties"]["schema"]["const"]:
    raise SystemExit("audit schema validation failed; wrong schema")
if audit["verdict"] not in schema["properties"]["verdict"]["enum"]:
    raise SystemExit("audit schema validation failed; wrong verdict")

os.makedirs(os.path.dirname(audit_path), exist_ok=True)
with open(audit_path, "w", encoding="utf-8") as f:
    json.dump(audit, f, indent=2)
    f.write("\n")
PY

python3 - "$packet" "$run_id" <<'PY'
import json
import sys

packet_path, run_id = sys.argv[1:3]
with open(packet_path, encoding="utf-8") as f:
    packet = json.load(f)
packet["status"] = "accepted"
packet["nextAction"] = "import into control state and reconcile"
audit_ref = f"runs/{run_id}/audit.json"
if not any(item.get("kind") == "audit" and item.get("ref") == audit_ref for item in packet["evidence"]):
    packet["evidence"].append({"kind": "audit", "ref": audit_ref})
with open(packet_path, "w", encoding="utf-8") as f:
    json.dump(packet, f, indent=2)
    f.write("\n")
PY
gluerun_validate_packet_basic "$packet" >/dev/null

if ! gluerun_lease_set_status "$task_id" "accepted"; then
  echo "lease not found for task: $task_id" >&2
  exit 2
fi
gluerun_task_set_status "$task_file" "accepted"
"$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "accept" \
  --rationale "deterministic acceptance of existing stranded packet; branch head matches packet; scope, secret scan, evidence, and rerun commands passed" \
  --run "$run_id" --branch "$branch" --authority origin >/dev/null
gluerun_append_event "packet.accepted_existing" "existing state packet accepted deterministically" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"branch\":\"$branch\",\"headSha\":\"$head_sha\",\"audit\":\"$audit_record\"}"

echo "accepted existing packet: $packet (audit: $audit_record)"
