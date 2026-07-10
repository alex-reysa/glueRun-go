#!/usr/bin/env bash
set -euo pipefail

# Consumer gate promoter for the glueRun-go self-dock (context-evolution plan).
#
#   tools/promote-gate.sh NODE [EVIDENCE_CMD]
#
# The operator runs this AFTER a node's stage-file exit gate holds (all tasks
# integrated + operator review). It runs the evidence command at the current
# HEAD, hashes the log, and writes the authoritative gate-result.v0 record that
# dag.sh treats as node-completion authority. dag.sh re-hashes the log on every
# frontier read, so the log file and the gate record MUST be committed together
# and never edited afterwards; re-promotion regenerates both.
#
# GLUERUN_PROMOTER can point at this script so `gluerun promote-gate NODE` works.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node="${1:?usage: tools/promote-gate.sh NODE [EVIDENCE_CMD]}"
cmd="${2:-bash tests/run.sh}"

gates_dir="$ROOT/docs/orchestration/gates"
logs_dir="$gates_dir/logs"
mkdir -p "$logs_dir"
log_rel="docs/orchestration/gates/logs/${node}-gate.log"
log_abs="$ROOT/$log_rel"
out="$gates_dir/${node}.gate-result.json"

echo "promote-gate: node=$node cmd=[$cmd]"
ec=0
( cd "$ROOT" && bash -c "$cmd" ) >"$log_abs" 2>&1 </dev/null || ec=$?
echo "promote-gate: evidence command exit=$ec log=$log_rel"

head_sha="$(git -C "$ROOT" rev-parse HEAD)"
log_sha="$(python3 -c '
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
print(h.hexdigest())' "$log_abs")"

python3 - "$out" "$node" "$ec" "$cmd" "$log_rel" "$log_sha" "$head_sha" <<'PY'
import json, sys
from datetime import datetime, timezone

out, node, ec, cmd, log_rel, log_sha, head_sha = sys.argv[1:8]
ec = int(ec)
status = "passed" if ec == 0 else "failed"
doc = {
    "schema": "gluerun.orchestration.gate-result.v0",
    "node": node,
    "status": status,
    "authoritative": True,
    "evidenceClass": "deterministic-proof",
    "evidence": [
        {
            "kind": "command-log",
            "ref": f"{node}-gate",
            "description": "node exit-gate evidence run at the integrated head",
            "command": cmd,
            "exitCode": ec,
            "logRef": log_rel,
            "sha256": log_sha,
            "headSha": head_sha,
        }
    ],
    "decidedBy": "operator:tools/promote-gate.sh",
    "rationale": f"stage-file exit gate verified for {node}; evidence command exited {ec} at head {head_sha[:12]}",
    "recordedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print(f"promote-gate: wrote {out} (status={status})")
PY

[[ "$ec" -eq 0 ]] || { echo "promote-gate: evidence RED — gate recorded as failed, node NOT complete" >&2; exit 1; }
