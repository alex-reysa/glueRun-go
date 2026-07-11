#!/usr/bin/env bash
# ctx-plan-revise-dispositions.sh — the plan-revision-loop per-finding DISPOSITION
# recorder: after a revision round produces a revised batch, classify each critique
# finding as `accepted-observation`, `rejected-observation`, or (for a silent drop)
# `accepted-but-unaddressed`, and record those dispositions as provenance events.
# This implements the still-untouched requiredCompletion predicate "per-finding
# accepted/rejected-observation dispositions evented" for the plan-revision-loop
# node (stage S3-plan-revision, area plancritic, layer engine_runtime).
#
# Per the stage file, the planner must state rejections explicitly in its batch
# output notes; findings it silently drops count as accepted-but-unaddressed and
# are RECORDED (never dropped) so they feed the Stage 6 graph.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-plan-revise.sh and the record-and-event shape of
# engine/ctx-critique-import-gate.sh). It never owns engine/lib.sh and adds no
# driver-file hook; it records/events only, mutating no outcome. It changes no
# outcome, promotes/quarantines no candidate, invokes no runner, and touches no
# lease.
#
# The GLUERUN_PLAN_CRITIQUE-gated resume-vs-fresh planner re-invocation (resuming
# the persisted node session via gluerun_planner_resume_decide, resume-refused
# rc-86 fresh fallback recorded) and the generate-tasks.sh / l1-plan-node.sh driver
# hooks with the test-ctx-plan-revision.sh full-walk are the sanctioned follow-up
# slices of this node and are OUT OF SCOPE here.
#
# Public entry points:
#   gluerun_plan_revise_classify <critique_record> <revised_batch>
#     PURE and READ-ONLY. Reads every `f-[0-9a-f]{12}` finding id from the
#     gluerun.orchestration.plan-critique.v0 record at <critique_record> and the
#     revised task batch at <revised_batch> (task-batch.v0 content / its rendered
#     notes); prints one TAB-separated `<finding-id>\t<disposition>` line per
#     finding in id-sorted order. Appends no events, mutates nothing, ALWAYS exits
#     0 (bad input yields the conservative default below, never a crash).
#       rejected-observation      — the revised batch EXPLICITLY marks that finding
#                                   id as rejected (the planner stated the rejection
#                                   referencing the id).
#       accepted-observation      — the id is otherwise referenced / addressed in
#                                   the revised batch.
#       accepted-but-unaddressed  — the id appears nowhere in the batch (a silent
#                                   drop, recorded rather than dropped); ALSO the
#                                   fail-closed default for any id whose disposition
#                                   cannot be positively established, including a
#                                   missing / unparseable record or batch. The
#                                   classifier NEVER fabricates a rejected-observation
#                                   or a clean accepted-observation on ambiguity.
#   gluerun_plan_revise_record_dispositions <node> <revises_run_id> \
#                                           <critique_record> <revised_batch>
#     Records ONLY: emits provenance through gluerun_append_event under event type
#     `plan.revised`, carrying `node`, `revisesRunId` (= <revises_run_id>), and the
#     full per-finding id->disposition set. Changes no outcome, promotes /
#     quarantines no candidate, invokes no runner, touches no lease. Events land
#     only in the pinned GLUERUN_EVENTS_FILE.

# Pure, read-only classifier. Prints `<finding-id>\t<disposition>` per finding in
# id-sorted order; always exits 0. See header for the full contract.
gluerun_plan_revise_classify() {
  local critique_record="${1:-}" revised_batch="${2:-}"
  python3 - "$critique_record" "$revised_batch" <<'PY' 2>/dev/null || true
import json, re, sys

crit_path, batch_path = sys.argv[1], sys.argv[2]
idpat = re.compile(r"f-[0-9a-f]{12}")
strict = re.compile(r"^f-[0-9a-f]{12}$")

# --- Finding ids from the critique record (authoritative findings list). A
# missing / unparseable / schema-divergent record yields NO ids (no fabrication).
record_ids = set()
try:
    with open(crit_path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    if isinstance(doc, dict) and doc.get("schema") == "gluerun.orchestration.plan-critique.v0":
        findings = doc.get("findings")
        if isinstance(findings, list):
            for it in findings:
                if isinstance(it, dict):
                    fid = it.get("id", "")
                    if isinstance(fid, str) and strict.match(fid):
                        record_ids.add(fid)
except Exception:
    pass

# --- Revised batch text (task-batch.v0 content / its rendered notes). A missing /
# unparseable batch degrades to EMPTY text -> every finding defaults to
# accepted-but-unaddressed (fail-closed, no fabricated accepted/rejected).
batch_text = ""
try:
    with open(batch_path, "r", encoding="utf-8") as f:
        raw = f.read()
    try:
        bdoc = json.loads(raw)
    except Exception:
        bdoc = None
    if (isinstance(bdoc, dict)
            and bdoc.get("schema") == "gluerun.orchestration.task-batch.v0"
            and isinstance(bdoc.get("tasks"), list)):
        # Structured task-batch.v0: the searchable notes are the task markdown
        # (and taskIds) the planner wrote.
        parts = []
        for t in bdoc["tasks"]:
            if isinstance(t, dict):
                for k in ("taskId", "markdown"):
                    v = t.get(k)
                    if isinstance(v, str):
                        parts.append(v)
        batch_text = "\n".join(parts)
    elif bdoc is None:
        # Not JSON: treat as unparseable -> no evidence (fail-closed).
        batch_text = ""
    else:
        # Parseable JSON but not a task-batch.v0 envelope: no trustworthy notes.
        batch_text = ""
except Exception:
    batch_text = ""

lines = batch_text.splitlines()
# An id is EXPLICITLY rejected when it appears on a line that also states a
# rejection (planner stated the rejection referencing the id).
rejpat = re.compile(r"reject", re.IGNORECASE)
rejected_ids = set()
mentioned_ids = set()
for ln in lines:
    hits = idpat.findall(ln)
    if not hits:
        continue
    line_rejects = bool(rejpat.search(ln))
    for h in hits:
        mentioned_ids.add(h)
        if line_rejects:
            rejected_ids.add(h)

# Universe of ids: those named by the critique record AND any f-id referenced in
# the revised batch, per the contract ("reads every finding id from the record and
# the revised task batch").
universe = record_ids | mentioned_ids

out = []
for fid in sorted(universe):
    if fid in rejected_ids:
        disp = "rejected-observation"
    elif fid in mentioned_ids:
        disp = "accepted-observation"
    else:
        disp = "accepted-but-unaddressed"
    out.append("{}\t{}".format(fid, disp))
sys.stdout.write("\n".join(out))
if out:
    sys.stdout.write("\n")
PY
  return 0
}

# Records ONLY. Emits exactly one `plan.revised` provenance event carrying node,
# revisesRunId, and the full per-finding id->disposition set. Mutates nothing else.
gluerun_plan_revise_record_dispositions() {
  local node="${1:-}" revises_run_id="${2:-}" critique_record="${3:-}" revised_batch="${4:-}"

  # Classify (pure/read-only); feed the deterministic id-sorted dispositions into
  # the event payload verbatim.
  local classified
  classified="$(gluerun_plan_revise_classify "$critique_record" "$revised_batch")"

  # Build the deterministic (id-sorted) disposition payload. python turns the
  # TAB-separated classifier lines into the structured id->disposition set.
  local event_json
  event_json="$(python3 - "$node" "$revises_run_id" <<PY
import json, sys
node, revises_run_id = sys.argv[1], sys.argv[2]
classified = """$classified"""
dispositions = []
for line in classified.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) != 2:
        continue
    dispositions.append({"id": parts[0], "disposition": parts[1]})
dispositions.sort(key=lambda x: x["id"])
print(json.dumps({
    "node": node,
    "revisesRunId": revises_run_id,
    "dispositions": dispositions,
}, separators=(",", ":")))
PY
)"

  # Exactly one plan.revised provenance event. Records only — no lease, no runner,
  # no candidate promotion/quarantine.
  gluerun_append_event "plan.revised" "per-finding revision dispositions recorded" "$event_json"
  return 0
}
