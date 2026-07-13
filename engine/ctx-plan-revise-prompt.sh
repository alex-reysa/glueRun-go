#!/usr/bin/env bash
# ctx-plan-revise-prompt.sh — assemble the read-only structured-findings REVISION
# PROMPT the plan-revision-loop node (stage S3-plan-revision, area plancritic,
# layer engine_runtime) feeds a `revise` decision.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-plan-critic-context.sh, whose read-only assembler this brick
# parallels). It never owns engine/lib.sh and adds no driver-file hook.
#
# The integrated bound authority gluerun_plan_revise_decide (engine/ctx-plan-revise.sh)
# already decides revise / park / import; this brick builds the INPUT a `revise`
# decision consumes. It implements the stage phrasing "a revision prompt = base
# planner prompt + the structured critique findings (per-id) + the prior candidate
# set". Because resume-refused falls back to "a fresh planner with the SAME
# revision prompt", both the resume and the fresh-fallback paths consume exactly
# this one composed prompt.
#
# The assembler is PURE and READ-ONLY: it reads the base planner TEMPLATE, the
# gluerun.orchestration.plan-critique.v0 record, and the prior candidate set; it
# writes ONLY its single output file, appends no events, spawns no runner, and
# mutates nothing else. Fail-safe without fabrication (evidence invariance): a
# missing/unreadable template, a missing/unparseable/schema-divergent record, or an
# empty candidate directory each degrade to that section being present but explicitly
# marked empty rather than crashing; the assembler NEVER fabricates findings or
# candidates and never silently emits a prompt with the findings section absent, so
# a downstream planner is never flown blind under the guise of a normal prompt.
#
# The GLUERUN_PLAN_CRITIQUE-gated planner re-invocation resuming the persisted node
# session via gluerun_planner_resume_decide, the rc-86 fresh-fallback record, the
# per-finding accepted-observation / rejected-observation disposition events
# (plan.revised with revisesRunId), and the generate-tasks.sh / l1-plan-node.sh
# driver hooks with the test-ctx-plan-revision.sh full-walk are the sanctioned
# follow-up slices of this node and are OUT OF SCOPE here.
#
# Public entry point (pure; no side effects, no events, no state writes):
#   gluerun_plan_revise_prompt <node> <critique_record> <stage_dir> <out_file> \
#                              [template_file]
#     Compose the revision prompt into <out_file>: (a) the base planner TEMPLATE
#     body verbatim (from template_file, else the canonical template resolved by
#     gluerun_planner_resume_template_path — GLUERUN_PLANNER_TEMPLATE or
#     docs/orchestration/prompts/l1-planner.md); (b) every findings[] entry of the
#     record rendered with its exact id / severity / claim / evidence (+
#     suggestedChange when present), sorted by id; (c) every *.candidate.md body in
#     <stage_dir> in sorted glob order. Writes ONLY <out_file>. Empty <out_file>
#     returns non-zero (usage).

# Pure assembler. Reads only its inputs; writes ONLY <out_file>. Deterministic:
# id-sorted findings, sorted candidate glob, no timestamps. See header for the
# full contract.
gluerun_plan_revise_prompt() {
  local node="$1" critique_record="${2:-}" stage_dir="${3:-}" out_file="${4:-}"
  local template_file="${5:-}"
  [[ -n "$out_file" ]] || return 2

  # Resolve the base planner TEMPLATE path. An explicit arg wins; otherwise fall
  # back to the integrated canonical resolver (GLUERUN_PLANNER_TEMPLATE or the
  # docs default). Readability is checked below so a missing file degrades to a
  # marked-empty section rather than crashing.
  local tpl_path
  if [[ -n "$template_file" ]]; then
    tpl_path="$template_file"
  elif [[ "$(type -t gluerun_planner_resume_template_path)" == "function" ]]; then
    tpl_path="$(gluerun_planner_resume_template_path)"
  else
    tpl_path="${GLUERUN_PLANNER_TEMPLATE:-${GLUERUN_ROOT:-.}/docs/orchestration/prompts/l1-planner.md}"
  fi

  mkdir -p "$(dirname "$out_file")"

  # Render the structured findings section body via python (robust JSON parse,
  # id-sorted, verbatim per-id ids preserved for the later disposition slice). A
  # missing / unparseable / schema-divergent record, or a record with no valid
  # findings, yields empty output -> the caller substitutes the marked-empty
  # marker below. NEVER fabricates a finding.
  local findings_body
  findings_body="$(python3 - "$critique_record" <<'PY' 2>/dev/null || true
import json, re, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    assert isinstance(doc, dict)
    assert doc.get("schema") == "gluerun.orchestration.plan-critique.v0"
    findings = doc.get("findings")
    assert isinstance(findings, list)
except Exception:
    sys.exit(0)

idpat = re.compile(r"^f-[0-9a-f]{12}$")
valid = []
for it in findings:
    if not isinstance(it, dict):
        continue
    fid = it.get("id", "")
    if not isinstance(fid, str) or not idpat.match(fid):
        continue
    valid.append(it)

valid.sort(key=lambda x: x["id"])

def s(v):
    return "" if v is None else str(v)

lines = []
for it in valid:
    lines.append("### {}".format(it["id"]))
    lines.append("")
    lines.append("- severity: {}".format(s(it.get("severity"))))
    lines.append("- claim: {}".format(s(it.get("claim"))))
    lines.append("- evidence: {}".format(s(it.get("evidence"))))
    sc = it.get("suggestedChange")
    if sc is not None and str(sc) != "":
        lines.append("- suggestedChange: {}".format(s(sc)))
    lines.append("")
sys.stdout.write("\n".join(lines).rstrip("\n"))
PY
)"

  {
    printf '# Plan Revision Prompt: %s\n\n' "$node"
    printf 'Revision prompt = base planner TEMPLATE + structured critique findings (per-id) + prior candidate set.\n\n'

    printf '## Base Planner Template\n\n'
    if [[ -n "$tpl_path" && -f "$tpl_path" ]]; then
      cat "$tpl_path"
      printf '\n\n'
    else
      printf '_no planner template available_\n\n'
    fi

    printf '## Critique Findings\n\n'
    if [[ -n "$findings_body" ]]; then
      printf '%s\n\n' "$findings_body"
    else
      printf '_no parseable findings_\n\n'
    fi

    printf '## Prior Candidate Set\n\n'
    local had_candidate=0 c
    for c in "$stage_dir"/*.candidate.md; do
      [[ -e "$c" ]] || continue
      had_candidate=1
      printf '### %s\n\n' "$(basename "$c")"
      cat "$c"
      printf '\n'
    done
    (( had_candidate )) || printf '_no prior candidates_\n\n'
  } > "$out_file"

  return 0
}
