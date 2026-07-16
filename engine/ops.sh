#!/usr/bin/env bash
set -euo pipefail

# Operator verbs (0.5.0). The field run's every recovery was raw file surgery
# — hand-editing task files, leases, decisions.md, dispatch records, deleting
# planner-backoff.json, killing sleep children — repeated ~15 times. These
# verbs make each of those a single audited command.
#
#   ops.sh supersede TASK-XXXX [--by TASK-YYYY] [--reason TEXT] [--force]
#   ops.sh clear-backoff
#   ops.sh breaker [show|reset]
#   ops.sh stop [--wait[=SECS]]
#   ops.sh resume
#   ops.sh wake
#   ops.sh gates [--json]
#   ops.sh health [--json]
#   ops.sh gc [--dry-run]

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "ops.sh requires bash >= 4" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

verb="${1:-}"
shift || true

# --- supersede ----------------------------------------------------------------
# The "four resurrection surfaces" atomically: decisions.md entry, task file
# (Superseded by: header + Status + move to tasks/superseded/), lease status,
# dispatch record finalize + inbox quarantine. Idempotent; refuses a live
# dispatch without --force.
ops_supersede() {
  local task_id="" by="" reason="" force="no"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by) by="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      --force) force="yes"; shift ;;
      TASK-*) task_id="$1"; shift ;;
      *) echo "usage: gluerun supersede TASK-XXXX [--by TASK-YYYY] [--reason TEXT] [--force]" >&2; return 2 ;;
    esac
  done
  [[ -n "$task_id" ]] || { echo "usage: gluerun supersede TASK-XXXX [--by TASK-YYYY] [--reason TEXT] [--force]" >&2; return 2; }

  local superseded_dir="$GLUERUN_TASKS_DIR/superseded"
  if [[ -f "$superseded_dir/$task_id.md" ]]; then
    echo "supersede: $task_id already superseded (idempotent no-op)"
    return 0
  fi
  local task_file="$GLUERUN_TASKS_DIR/$task_id.md"
  [[ -f "$task_file" ]] || { echo "supersede: no task file $task_file" >&2; return 2; }
  if [[ -n "$by" ]]; then
    [[ -f "$GLUERUN_TASKS_DIR/$by.md" || -f "$superseded_dir/$by.md" ]] \
      || { echo "supersede: successor $by not found" >&2; return 2; }
    [[ "$by" != "$task_id" ]] || { echo "supersede: task cannot supersede itself" >&2; return 2; }
  fi

  # Live-dispatch guard.
  local drec dpid dstart dpgid drun
  drec="$(gluerun_dispatch_record_path "$task_id")"
  if [[ -f "$drec" && "$(gluerun_json_field "$drec" state 2>/dev/null || true)" == "launched" ]]; then
    dpid="$(gluerun_json_field "$drec" pid 2>/dev/null || true)"
    dstart="$(gluerun_json_field "$drec" pidStart 2>/dev/null || true)"
    dpgid="$(gluerun_json_field "$drec" pgid 2>/dev/null || true)"
    drun="$(gluerun_json_field "$drec" runId 2>/dev/null || true)"
    if gluerun_dispatch_tree_alive "$task_id" "$dpid" "$dstart" "$drun" "${dpgid:-0}"; then
      if [[ "$force" != "yes" ]]; then
        echo "supersede: $task_id has a LIVE dispatch (pid $dpid); rerun with --force to terminate it" >&2
        return 2
      fi
      echo "supersede: --force terminating live dispatch tree (pid $dpid)"
      gluerun_kill_dispatch_pgroup "$task_id" || gluerun_kill_tree "$dpid" || true
      sleep 1
    fi
  fi

  local run_id
  run_id="$(gluerun_run_id)"
  gluerun_acquire_lock "$run_id" || { echo "supersede: origin lock busy" >&2; return 2; }
  # shellcheck disable=SC2064
  trap "gluerun_release_lock '$run_id' 2>/dev/null || true" EXIT

  local rationale="${reason:-superseded${by:+ by $by} via gluerun supersede}"
  # Surface 1 — decisions (durable intent first).
  "$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision supersede \
    --rationale "$rationale" --run "$run_id" --authority operator 2>/dev/null \
    && echo "supersede: decision recorded" || echo "supersede: decision record FAILED (continuing)" >&2
  # Surface 2 — task file.
  if [[ -n "$by" ]] && ! grep -q '^Superseded by:' "$task_file"; then
    python3 - "$task_file" "$by" <<'PY'
import sys
path, by = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines(keepends=True)
out, done = [], False
for line in lines:
    out.append(line)
    if not done and line.startswith("Status:"):
        out.append(f"Superseded by: {by}\n")
        done = True
open(path, "w").writelines(out)
PY
  fi
  gluerun_task_set_status "$task_file" "superseded" || true
  mkdir -p "$superseded_dir"
  mv "$task_file" "$superseded_dir/$task_id.md" \
    && echo "supersede: task file -> tasks/superseded/$task_id.md" \
    || echo "supersede: task file move FAILED" >&2
  # Surface 3 — lease.
  if gluerun_lease_set_status "$task_id" "superseded" 2>/dev/null; then
    echo "supersede: lease -> superseded"
  else
    echo "supersede: no lease (ok)"
  fi
  # Surface 4 — dispatch record + queued inbox packet.
  if [[ -f "$drec" && "$(gluerun_json_field "$drec" state 2>/dev/null || true)" == "launched" ]]; then
    gluerun_dispatch_record_finalize "$task_id" 0 "superseded" || true
    echo "supersede: dispatch record finalized"
  fi
  local pkt pkt_task
  mkdir -p "$GLUERUN_INBOX_DIR/superseded" 2>/dev/null || true
  for pkt in "$GLUERUN_INBOX_DIR"/*.json; do
    [[ -f "$pkt" ]] || continue
    pkt_task="$(gluerun_json_field "$pkt" taskId 2>/dev/null || true)"
    if [[ "$pkt_task" == "$task_id" ]]; then
      mv "$pkt" "$GLUERUN_INBOX_DIR/superseded/$(basename "$pkt")"
      echo "supersede: quarantined inbox packet $(basename "$pkt")"
    fi
  done
  gluerun_append_event "task.superseded" "task superseded via operator verb" \
    "{\"taskId\":\"$task_id\",\"by\":\"$by\",\"forced\":\"$force\"}"
  echo "superseded $task_id${by:+ -> $by}"
}

# --- breaker / stop / resume / wake -------------------------------------------
ops_breaker() {
  local sub="${1:-show}"
  case "$sub" in
    show)
      local n
      n="$(gluerun_breaker_count)"
      echo "breaker: $n/${GLUERUN_MAX_CONSEC_FAILS} ($([[ "$n" -ge "$GLUERUN_MAX_CONSEC_FAILS" ]] && echo OPEN || echo closed))"
      [[ -f "$GLUERUN_BREAKER_FILE" ]] && cat "$GLUERUN_BREAKER_FILE"
      ;;
    reset)
      local prev
      prev="$(gluerun_breaker_count)"
      gluerun_breaker_reset
      gluerun_append_event "breaker.reset" "circuit breaker reset by operator" "{\"previous\":$prev}"
      echo "breaker reset (was $prev/$GLUERUN_MAX_CONSEC_FAILS)"
      ;;
    *) echo "usage: gluerun breaker [show|reset]" >&2; return 2 ;;
  esac
}

ops_stop() {
  local wait_secs=""
  case "${1:-}" in
    --wait) wait_secs=300 ;;
    --wait=*) wait_secs="${1#--wait=}" ;;
    "") : ;;
    *) echo "usage: gluerun stop [--wait[=SECS]]" >&2; return 2 ;;
  esac
  gluerun_ensure_state_dirs
  : >"$GLUERUN_STOP_FILE"
  gluerun_append_event "operator.stop_requested" "STOP sentinel written by operator" "{}"
  echo "STOP written ($GLUERUN_STOP_FILE)"
  [[ -n "$wait_secs" ]] || return 0
  [[ "$wait_secs" =~ ^[0-9]+$ ]] || wait_secs=300
  local pidfile="$GLUERUN_STATE_DIR/autonomate.pid" pid waited=0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    echo "autonomate not running"
    return 0
  fi
  echo "waiting up to ${wait_secs}s for autonomate (pid $pid) to exit..."
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if (( waited >= wait_secs )); then
      echo "autonomate (pid $pid) still running after ${wait_secs}s; kill $pid to force" >&2
      return 1
    fi
  done
  echo "autonomate exited"
}

ops_resume() {
  if [[ -f "$GLUERUN_STOP_FILE" ]]; then
    rm -f "$GLUERUN_STOP_FILE"
    gluerun_append_event "operator.resume_requested" "STOP sentinel removed by operator" "{}"
    echo "STOP removed"
  else
    echo "no STOP sentinel present"
  fi
  local pid
  pid="$(cat "$GLUERUN_STATE_DIR/autonomate.pid" 2>/dev/null || true)"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    echo "hint: autonomate is not running — start it with: gluerun auto --detach"
  fi
}

ops_wake() {
  # One-shot "make the loop runnable": clear backoff, reset breaker, drop STOP,
  # then signal any live nap to end. Each step reports individually.
  gluerun_planner_backoff_clear
  ops_breaker reset
  if [[ -f "$GLUERUN_STOP_FILE" ]]; then
    rm -f "$GLUERUN_STOP_FILE"; echo "STOP removed"
  else
    echo "no STOP sentinel present"
  fi
  gluerun_request_wake
  gluerun_append_event "operator.wake" "wake verb completed" "{}"
}

# --- gates ----------------------------------------------------------------------
ops_gates() {
  local json="no"
  [[ "${1:-}" == "--json" ]] && json="yes"
  python3 - "${GLUERUN_DAG_FILE:-$GLUERUN_ORCH_DIR/dag.v0.json}" "$GLUERUN_ORCH_DIR/gates" "$json" <<'PY'
import json
import os
import sys

dag_file, gates_dir, as_json = sys.argv[1:4]
nodes = []
try:
    dag = json.load(open(dag_file))
    nodes = [(n.get("id", ""), n.get("kind", "")) for n in dag.get("nodes", [])]
except Exception:
    pass

rows, passed = [], 0
for node_id, kind in nodes:
    path = os.path.join(gates_dir, f"{node_id}.gate-result.json")
    if not os.path.isfile(path):
        rows.append({"node": node_id, "kind": kind, "status": "(no gate)", "authoritative": "",
                     "evidenceClass": "", "decidedBy": "", "recordedAt": "", "file": ""})
        continue
    try:
        g = json.load(open(path))
        status = str(g.get("status", "?"))
        if status == "passed":
            passed += 1
        rows.append({"node": node_id, "kind": kind, "status": status,
                     "authoritative": g.get("authoritative", ""),
                     "evidenceClass": g.get("evidenceClass", ""),
                     "decidedBy": g.get("decidedBy", ""),
                     "recordedAt": g.get("recordedAt", ""), "file": path})
    except Exception as exc:
        # A malformed gate is DISPLAYED, never fatal — operators need to see it.
        rows.append({"node": node_id, "kind": kind, "status": f"invalid ({exc})",
                     "authoritative": "", "evidenceClass": "", "decidedBy": "",
                     "recordedAt": "", "file": path})

if as_json == "yes":
    print(json.dumps({"gates": rows, "passed": passed, "total": len(nodes)}, indent=2))
else:
    widths = [max(len(str(r["node"])) for r in rows or [{"node": "NODE"}]) + 2, 12, 12]
    print(f"{'NODE':<{widths[0]}}{'KIND':<{widths[1]}}{'STATUS':<14}{'AUTH':<6}{'EVIDENCECLASS':<22}RECORDEDAT")
    for r in rows:
        print(f"{r['node']:<{widths[0]}}{r['kind']:<{widths[1]}}{str(r['status']):<14}"
              f"{str(r['authoritative']):<6}{str(r['evidenceClass']):<22}{r['recordedAt']}")
    print(f"passed {passed}/{len(nodes)}")
PY
}

# --- health ----------------------------------------------------------------------
ops_health() {
  local json="no"
  [[ "${1:-}" == "--json" ]] && json="yes"
  local gates_json frontier_json ready_count active_count l1_active l1_stale
  gates_json="$(ops_gates --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps({"passed":d["passed"],"total":d["total"]}))' 2>/dev/null || echo '{"passed":null,"total":null}')"
  frontier_json="$("$SCRIPT_DIR/dag.sh" next-areas 2>/dev/null | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d.get("frontier",[])))
except Exception:
    print("null")' || echo null)"
  ready_count="$(gluerun_list_ready_tasks 2>/dev/null | grep -c . || true)"
  active_count="$(gluerun_active_lease_count 2>/dev/null || echo 0)"
  l1_active="$(gluerun_l1_list_active 2>/dev/null | grep -c . || true)"
  l1_stale="$(gluerun_l1_list_stale 2>/dev/null | grep -c . || true)"
  local backoff_json breaker_n stop_present lock_present auto_pid auto_alive
  backoff_json="$(gluerun_planner_backoff_active_json 2>/dev/null || echo null)"
  breaker_n="$(gluerun_breaker_count)"
  stop_present="$([[ -f "$GLUERUN_STOP_FILE" ]] && echo true || echo false)"
  lock_present="$([[ -f "$GLUERUN_LOCK_FILE" ]] && echo true || echo false)"
  auto_pid="$(cat "$GLUERUN_STATE_DIR/autonomate.pid" 2>/dev/null || true)"
  auto_alive="false"
  [[ -n "$auto_pid" ]] && kill -0 "$auto_pid" 2>/dev/null && auto_alive="true"
  local disk_free wt_count console_url
  disk_free="$(gluerun_free_disk_gb 2>/dev/null || echo null)"
  wt_count="$(find "$GLUERUN_WORKTREES_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -c . || true)"
  console_url="$(head -1 "$GLUERUN_STATE_DIR/console.url" 2>/dev/null || true)"
  local head_sha
  head_sha="$(git -C "$GLUERUN_ROOT" rev-parse --short HEAD 2>/dev/null || echo null)"

  python3 - "$gates_json" "$frontier_json" "$ready_count" "$active_count" "$l1_active" "$l1_stale" \
    "$backoff_json" "$breaker_n" "${GLUERUN_MAX_CONSEC_FAILS:-5}" "$stop_present" "$lock_present" \
    "$auto_pid" "$auto_alive" "$disk_free" "${GLUERUN_MIN_DISK_GB:-2}" "$wt_count" "$console_url" \
    "${GLUERUN_TARGET_BRANCH:-}" "$head_sha" "$json" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone

(gates_raw, frontier, ready, active, l1a, l1s, backoff_raw, breaker, breaker_max,
 stop, lock, auto_pid, auto_alive, disk, min_disk, wt, console_url,
 target, head, as_json) = sys.argv[1:21]


def num(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return None


gates = json.loads(gates_raw)
try:
    backoff = json.loads(backoff_raw) if backoff_raw != "null" else None
except Exception:
    backoff = None

attention = []
if stop == "true":
    attention.append("STOP sentinel present")
if backoff:
    attention.append(f"planner backoff active ({backoff.get('failureClass')}, until {backoff.get('until')})")
if num(breaker) and num(breaker) >= num(breaker_max):
    attention.append(f"circuit breaker OPEN ({breaker}/{breaker_max})")
if num(l1s):
    attention.append(f"{l1s} stale L1 lease(s) (gluerun recover --scan)")
if num(disk) is not None and num(min_disk) is not None and num(disk) < num(min_disk):
    attention.append(f"disk below floor ({disk}GiB < {min_disk}GiB)")
if auto_alive != "true":
    attention.append("autonomate not running")

doc = {
    "ok": not attention,
    "gates": gates,
    "frontier": {"ready": num(frontier)},
    "tasks": {"ready": num(ready)},
    "leases": {"l2Active": num(active), "l1Active": num(l1a), "l1Stale": num(l1s)},
    "backoff": backoff,
    "breaker": {"consecFails": num(breaker), "threshold": num(breaker_max),
                "open": bool(num(breaker) and num(breaker) >= num(breaker_max))},
    "stop": stop == "true",
    "lock": lock == "true",
    "autonomate": {"pid": num(auto_pid), "alive": auto_alive == "true"},
    "diskFreeGb": num(disk),
    "worktrees": num(wt),
    "consoleUrl": console_url or None,
    "targetBranch": target or None,
    "head": head if head != "null" else None,
    "attention": attention,
}
# Digest over everything except generatedAt: the skill heartbeat compares
# ONLY this field to decide whether anything changed.
doc["digest"] = hashlib.sha256(
    json.dumps(doc, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()[:16]
doc["generatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

if as_json == "yes":
    print(json.dumps(doc, indent=2))
else:
    g = doc["gates"]
    print(f"ok:         {doc['ok']}")
    print(f"gates:      {g.get('passed')}/{g.get('total')}")
    print(f"frontier:   {doc['frontier']['ready']} ready node(s)")
    print(f"tasks:      {doc['tasks']['ready']} ready; leases l2={doc['leases']['l2Active']} l1={doc['leases']['l1Active']} (stale {doc['leases']['l1Stale']})")
    print(f"breaker:    {doc['breaker']['consecFails']}/{doc['breaker']['threshold']}"
          + (" OPEN" if doc["breaker"]["open"] else ""))
    print(f"backoff:    {'ACTIVE ' + str((doc['backoff'] or {}).get('failureClass')) if doc['backoff'] else 'none'}")
    print(f"stop:       {doc['stop']}   lock: {doc['lock']}")
    print(f"autonomate: pid={doc['autonomate']['pid']} alive={doc['autonomate']['alive']}")
    print(f"disk:       {doc['diskFreeGb']}GiB free; worktrees: {doc['worktrees']}")
    if doc["consoleUrl"]:
        print(f"console:    {doc['consoleUrl']}")
    for a in doc["attention"]:
        print(f"ATTENTION:  {a}")
    print(f"digest:     {doc['digest']}")
PY
}

# --- gc --------------------------------------------------------------------------
ops_gc() {
  local dry="no"
  [[ "${1:-}" == "--dry-run" ]] && dry="yes"
  local run_id
  run_id="$(gluerun_run_id)"
  if [[ "$dry" == "no" ]]; then
    gluerun_acquire_lock "$run_id" || { echo "gc: origin lock busy" >&2; return 2; }
    # shellcheck disable=SC2064
    trap "gluerun_release_lock '$run_id' 2>/dev/null || true" EXIT
  fi
  local prefix_word=""
  [[ "$dry" == "yes" ]] && prefix_word="would-"

  # 1. Runs-history cap: keep newest GLUERUN_RUNS_KEEP per prefix bucket;
  #    never delete runs referenced by live leases/dispatches/inbox packets or
  #    newer than GLUERUN_RUNS_MIN_AGE_HOURS.
  python3 - "$GLUERUN_RUNS_DIR" "$GLUERUN_LEASES_DIR" "$GLUERUN_DISPATCH_DIR" "$GLUERUN_INBOX_DIR" \
    "${GLUERUN_RUNS_KEEP:-200}" "${GLUERUN_RUNS_MIN_AGE_HOURS:-24}" "$dry" <<'PY'
import json
import os
import shutil
import sys
import time

runs_dir, leases_dir, dispatch_dir, inbox_dir, keep_raw, min_age_raw, dry = sys.argv[1:8]
keep = int(keep_raw)
min_age_s = int(min_age_raw) * 3600
now = time.time()

protected = set()
for base in (leases_dir, dispatch_dir, inbox_dir):
    if not os.path.isdir(base):
        continue
    for name in os.listdir(base):
        if not name.endswith(".json"):
            continue
        try:
            data = json.load(open(os.path.join(base, name)))
        except Exception:
            continue
        rid = data.get("runId")
        status = str(data.get("status", data.get("state", "")))
        if rid and status not in ("superseded", "cancelled"):
            protected.add(rid)

buckets = {}
if os.path.isdir(runs_dir):
    for name in os.listdir(runs_dir):
        path = os.path.join(runs_dir, name)
        if not os.path.isdir(path):
            continue
        bucket = name.split("-", 1)[0]
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        buckets.setdefault(bucket, []).append((mtime, name, path))

removed = kept = 0
for bucket, entries in buckets.items():
    entries.sort(reverse=True)
    for i, (mtime, name, path) in enumerate(entries):
        if i < keep or name in protected or (now - mtime) < min_age_s:
            kept += 1
            continue
        if dry == "no":
            shutil.rmtree(path, ignore_errors=True)
        removed += 1
prefix = "would-" if dry == "yes" else ""
print(f"gc: runs: {prefix}removed {removed} / kept {kept} (keep={keep}/bucket)")
PY

  # 2. Worktrees: prune integrated+merged+clean (same predicate as recover
  #    auto-prune), gated GLUERUN_GC_WORKTREES=1.
  local pruned=0 kept_wt=0 wt tid lease_status wt_head
  if [[ "${GLUERUN_GC_WORKTREES:-1}" == "1" && -d "$GLUERUN_WORKTREES_DIR" ]]; then
    for wt in "$GLUERUN_WORKTREES_DIR"/*; do
      [[ -d "$wt" ]] || continue
      tid="$(basename "$wt")"
      lease_status="$(gluerun_lease_status "$tid" 2>/dev/null || true)"
      if [[ "$lease_status" != "integrated" ]]; then
        kept_wt=$((kept_wt + 1)); continue
      fi
      wt_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
      if [[ -z "$wt_head" ]] \
        || ! git -C "$GLUERUN_ROOT" merge-base --is-ancestor "$wt_head" "$GLUERUN_TARGET_BRANCH" 2>/dev/null \
        || [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
        kept_wt=$((kept_wt + 1)); continue
      fi
      if [[ "$dry" == "no" ]]; then
        git -C "$GLUERUN_ROOT" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
        gluerun_record_recovery "gc pruned integrated worktree" "$tid" "" "prune" "operator" "" "operator" 2>/dev/null || true
      fi
      pruned=$((pruned + 1))
    done
    [[ "$dry" == "no" ]] && git -C "$GLUERUN_ROOT" worktree prune 2>/dev/null || true
  fi
  echo "gc: worktrees: ${prefix_word}pruned $pruned / kept $kept_wt"

  # 3. Events rotation.
  local max_mb="${GLUERUN_EVENTS_MAX_MB:-64}" rotate_keep="${GLUERUN_EVENTS_ROTATE_KEEP:-3}"
  if [[ -f "$GLUERUN_EVENTS_FILE" && "$max_mb" =~ ^[0-9]+$ && "$max_mb" -gt 0 ]]; then
    local size_mb
    size_mb="$(( $(wc -c <"$GLUERUN_EVENTS_FILE") / 1024 / 1024 ))"
    if (( size_mb >= max_mb )); then
      if [[ "$dry" == "no" ]]; then
        local i
        for ((i = rotate_keep - 1; i >= 1; i--)); do
          [[ -f "$GLUERUN_EVENTS_FILE.$i" ]] && mv "$GLUERUN_EVENTS_FILE.$i" "$GLUERUN_EVENTS_FILE.$((i + 1))"
        done
        mv "$GLUERUN_EVENTS_FILE" "$GLUERUN_EVENTS_FILE.1"
        : >"$GLUERUN_EVENTS_FILE"
        gluerun_append_event "gc.events_rotated" "events journal rotated" "{\"sizeMb\":$size_mb}"
      fi
      echo "gc: events: ${prefix_word}rotated (${size_mb}MB >= ${max_mb}MB)"
    else
      echo "gc: events: kept (${size_mb}MB < ${max_mb}MB)"
    fi
  fi

  # 4. Quarantine sweeps (>30 days).
  python3 - "$GLUERUN_LEASES_DIR/superseded" "$GLUERUN_INBOX_DIR/superseded" "$dry" <<'PY'
import os
import sys
import time

dirs = sys.argv[1:3]
dry = sys.argv[3]
now = time.time()
removed = 0
for base in dirs:
    if not os.path.isdir(base):
        continue
    for name in os.listdir(base):
        path = os.path.join(base, name)
        try:
            if now - os.path.getmtime(path) > 30 * 86400:
                if dry == "no":
                    os.remove(path)
                removed += 1
        except OSError:
            continue
prefix = "would-" if dry == "yes" else ""
print(f"gc: quarantine: {prefix}removed {removed} file(s) older than 30d")
PY
  [[ "$dry" == "no" ]] && gluerun_append_event "gc.completed" "gc run completed" "{}"
  return 0
}

case "$verb" in
  supersede)     ops_supersede "$@" ;;
  clear-backoff) gluerun_planner_backoff_clear ;;
  breaker)       ops_breaker "$@" ;;
  stop)          ops_stop "$@" ;;
  resume)        ops_resume "$@" ;;
  wake)          ops_wake ;;
  gates)         ops_gates "$@" ;;
  health)        ops_health "$@" ;;
  gc)            ops_gc "$@" ;;
  *)
    echo "usage: ops.sh supersede|clear-backoff|breaker|stop|resume|wake|gates|health|gc ..." >&2
    exit 2 ;;
esac
