#!/usr/bin/env bash
# ctx-critic-recheck-classify.sh — the per-finding critic-recheck CLASSIFIER: the
# signature OUTPUT of the executable DAG node critic-carryover (stage
# S3-plan-revision, area plancritic, layer engine_runtime). Given a prior
# plan-critique.v0 record and a resumed critic's recheck self-report, map each
# prior finding id to a disposition in `addressed | survives | obsolete`, and emit
# the record-only `ctx.critic_recheck` provenance event named verbatim in the
# node's requiredCompletion.
#
# TASK-0027 integrated the deterministic post-acceptance sampling gate
# (engine/ctx-critic-recheck.sh, behind default-OFF GLUERUN_CRITIC_RECHECK_PCT)
# that decides WHETHER an accepted task is sampled; this brick supplies the node's
# signature output — the per-finding disposition set and the ctx.critic_recheck
# events — as a pure, side-effect-free primitive the later read-only
# critic-resume runner will consult.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# TASK-0027 and the classifier/record pairing of
# engine/ctx-plan-revise-dispositions.sh, TASK-0021). It never owns engine/lib.sh,
# adds no driver-file hook, invokes no runner, resumes no session, touches no
# lease, and writes no state other than the one provenance event the recorder
# appends.
#
# Advocate/skeptic line + evidence invariance: the recheck records ONLY — it never
# blocks or changes any accept/reject outcome, never weakens a gate, and never
# makes the fresh implementation auditor bypassable. The conservative `survives`
# default keeps the critic a skeptic (an unproven concern is assumed to persist).
# The whole recheck stays default-OFF behind GLUERUN_CRITIC_RECHECK_PCT
# (TASK-0027), consulted upstream by the follow-up runner. The read-only
# critic-session RESUME over the accepted diff, the skeptic role gate, and the
# l1-drive.sh post-acceptance hook are the sanctioned follow-up slices of
# critic-carryover and are OUT OF SCOPE here.
#
# Public entry points:
#   gluerun_ctx_critic_recheck_classify <prior_critique_record> <recheck_output>
#     PURE and READ-ONLY. Reads every `f-[0-9a-f]{12}` finding id from the prior
#     gluerun.orchestration.plan-critique.v0 record and the resumed critic's
#     recheck self-report at <recheck_output> (JSON: a `findings` array of
#     {id,status} objects, status in addressed|survives|obsolete). Prints one
#     TAB-separated `<finding-id>\t<disposition>` line per PRIOR finding in
#     id-sorted order; disposition in {addressed, survives, obsolete}. Conservative
#     skeptic-safe fail-closed default = `survives` for any id whose status cannot
#     be positively established — a missing/unparseable record or output, an
#     unknown/ambiguous status, or an id absent from the recheck output — NEVER
#     fabricating addressed or obsolete. Appends no event, mutates nothing, ALWAYS
#     exits 0.
#   gluerun_ctx_critic_recheck_record <node> <run_id> <task_id> \
#                                     <prior_critique_record> <recheck_output>
#     Records ONLY. Classifies (via the pure function above) and emits EXACTLY ONE
#     `ctx.critic_recheck` event through gluerun_append_event carrying node,
#     runId, taskId, role = plan-critic (skeptic), and the full id-sorted
#     per-finding id->disposition set. Changes no outcome, promotes/quarantines no
#     candidate, invokes no runner, touches no lease, never mutates any
#     accept/reject decision. Events land only in the pinned GLUERUN_EVENTS_FILE.

# Pure, read-only classifier. Prints `<finding-id>\t<disposition>` per prior
# finding in id-sorted order; always exits 0. See header for the full contract.
gluerun_ctx_critic_recheck_classify() {
  local critique_record="${1:-}" recheck_output="${2:-}"
  python3 - "$critique_record" "$recheck_output" <<'PY' 2>/dev/null || true
import json, re, sys

crit_path, out_path = sys.argv[1], sys.argv[2]
strict = re.compile(r"^f-[0-9a-f]{12}$")
VALID = {"addressed", "survives", "obsolete"}

# --- Prior finding ids from the plan-critique record (authoritative universe). A
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

# --- The resumed critic's recheck self-report: per prior finding id, a status. A
# missing / unparseable output degrades to NO statuses -> every prior finding
# defaults to `survives` (fail-closed, no fabricated addressed/obsolete). Only a
# positively-parsed status in {addressed, survives, obsolete} for a PRIOR id is
# honored; an unknown/ambiguous status, or an id absent from the output, defaults
# to `survives`. A status for a non-prior id is ignored.
status_of = {}
try:
    with open(out_path, "r", encoding="utf-8") as f:
        rdoc = json.load(f)
    if isinstance(rdoc, dict):
        rf = rdoc.get("findings")
        if isinstance(rf, list):
            for it in rf:
                if not isinstance(it, dict):
                    continue
                fid = it.get("id", "")
                st = it.get("status", "")
                if (isinstance(fid, str) and strict.match(fid)
                        and isinstance(st, str) and st in VALID):
                    # First positively-established status wins (deterministic).
                    status_of.setdefault(fid, st)
except Exception:
    pass

out = []
for fid in sorted(record_ids):
    disp = status_of.get(fid, "survives")
    out.append("{}\t{}".format(fid, disp))
sys.stdout.write("\n".join(out))
if out:
    sys.stdout.write("\n")
PY
  return 0
}

# Records ONLY. Emits exactly one `ctx.critic_recheck` provenance event carrying
# node, runId, taskId, role=plan-critic, and the full id-sorted per-finding
# id->disposition set. Mutates nothing else.
gluerun_ctx_critic_recheck_record() {
  local node="${1:-}" run_id="${2:-}" task_id="${3:-}" \
        critique_record="${4:-}" recheck_output="${5:-}"

  # Classify (pure/read-only); feed the deterministic id-sorted dispositions into
  # the event payload verbatim.
  local classified
  classified="$(gluerun_ctx_critic_recheck_classify "$critique_record" "$recheck_output")"

  # Build the deterministic (id-sorted) disposition payload. python turns the
  # TAB-separated classifier lines into the structured id->disposition set.
  local event_json
  event_json="$(python3 - "$node" "$run_id" "$task_id" <<PY
import json, sys
node, run_id, task_id = sys.argv[1], sys.argv[2], sys.argv[3]
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
    "runId": run_id,
    "taskId": task_id,
    "role": "plan-critic",
    "dispositions": dispositions,
}, separators=(",", ":")))
PY
)"

  # Exactly one ctx.critic_recheck provenance event. Records only — no lease, no
  # runner, no candidate promotion/quarantine, no accept/reject mutation.
  gluerun_append_event "ctx.critic_recheck" "per-finding critic recheck dispositions recorded" "$event_json"
  return 0
}
