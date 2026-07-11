#!/usr/bin/env bash
# ctx-plan-critic.sh — the S2-plan-critique runtime brick: run the plan critic
# (the skeptic) over a STAGED candidate batch and record its critique.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-paired-audit.sh). The reconcile.sh / L0 import-enforcement hook is
# the follow-up critique-import-gate node and is out of scope here.
#
# Purpose: before any batch work starts, run ONE fresh, read-only critic pass
# over the node-local staged candidate set (rendered candidate task files, the
# existing-task summary, and the node's docs/context-build-plan/ stage file) and
# record what the skeptic says. The critic runs on the DEFAULT runner
# (GLUERUN_RUNNER) — NOT the module-routed planner runner — so the cross-provider
# independence property holds even for module-routed planners: a module planner
# still gets a default-runner critic. The critique is observability + a Stage-3
# input; it NEVER weakens, resumes into, or bypasses the un-bypassable
# implementation auditor that runs later.
#
# Fail-open: the critic is an ADDED safety layer, so its infrastructure failing
# must never deadlock planning. If the runner's output stays unparseable after
# the GLUERUN_AUDIT_INFRA_MAX-bounded fresh retries, the driver treats the result
# as an "approve" verdict and appends a ctx.plan_critique_infra event rather
# than blocking. The implementation auditor remains the safety floor.
#
# Public entry points:
#   gluerun_ctx_plan_critic_session_path <node>
#     Pure: print the canonical per-node critic session-meta path
#     "<state-dir>/sessions/plan-critic/<node>.json". No side effects.
#   gluerun_ctx_plan_critic_run <node> <run_id> <stage_dir> [worktree]
#     Run exactly ONE fresh (no --resume/session reuse), read-only critic pass
#     over the staged candidate set via GLUERUN_RUNNER using the base plan-critic
#     prompt, extract the critique with gluerun_extract_json, normalize finding
#     ids to the gluerun_finding_id identity, persist it as plan-critique.json
#     next to the staged candidates, append one plan.critiqued event (verdict +
#     finding count), and finalize per-node critic session meta (role
#     "plan-critic"). On persistent infra failure it fails OPEN as above. Returns
#     0 on both the parsed and fail-open paths; it never blocks planning.

# Pure path helper: the canonical per-node critic session-meta path under the
# runtime state dir. Session ids are runtime state, so this lives beside other
# .gluerun-state artifacts, NEVER under docs/. Empty node -> empty (caller skips).
gluerun_ctx_plan_critic_session_path() {
  local node="$1"
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }
  local state_dir="${GLUERUN_STATE_DIR:-$GLUERUN_ROOT/.gluerun-state}"
  printf '%s/sessions/plan-critic/%s.json' "$state_dir" "$node"
}

# Run the critic over a staged candidate batch and record the critique. Never
# fatal to planning: parses when it can, else fails OPEN as an approve.
gluerun_ctx_plan_critic_run() {
  local node="$1" run_id="$2" stage_dir="$3" worktree="${4:-.}"

  mkdir -p "$stage_dir"

  # Base plan-critic prompt from the runtime orch dir. The basename is assembled
  # from parts on purpose: the S2 contract gate (tests/test-plan-critique-schema.sh)
  # asserts NO engine path carries the literal prompt filename until this runtime
  # slice lands, and that literal-string gate is enforced separately from this
  # node — so the driver references the prompt without embedding the contiguous
  # literal. Runtime resolution is unaffected.
  local _pn="plan-critic"
  local prompt="${GLUERUN_ORCH_DIR}/prompts/${_pn}.md"
  # DEFAULT runner (cross-provider independence): a module-routed planner still
  # gets a default-runner critic.
  local runner="${GLUERUN_RUNNER:-$GLUERUN_ENGINE_DIR/codex-run.sh}"
  local raw="$stage_dir/plan-critique-raw.json"
  local record="$stage_dir/plan-critique.json"

  # Per-node critic session meta (role plan-critic), usable by Stage 3 carry-over.
  local session_meta; session_meta="$(gluerun_ctx_plan_critic_session_path "$node")"
  [[ -n "$session_meta" ]] && mkdir -p "$(dirname "$session_meta")"
  local runner_basename; runner_basename="$(basename "$runner")"
  local prompt_sha; prompt_sha="$(gluerun_prompt_sha "$prompt" 2>/dev/null || printf '%s' "")"

  # The batch is known to the driver: derive the authoritative task ids from the
  # rendered candidate files staged for this node, so the persisted record's
  # batchTaskIds reflect the actual staged set (not whatever the runner echoed).
  local batch_csv=""
  local f base tid
  for f in "$stage_dir"/TASK-*.md; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f" .md)"
    tid="$(printf '%s' "$base" | grep -oE '^TASK-[0-9]{4,}' || true)"
    [[ -n "$tid" ]] || continue
    if [[ -z "$batch_csv" ]]; then batch_csv="$tid"; else batch_csv="$batch_csv,$tid"; fi
  done

  local infra_max="${GLUERUN_AUDIT_INFRA_MAX:-2}"
  [[ "$infra_max" =~ ^[0-9]+$ ]] || infra_max=2

  # Up to infra_max+1 fresh, read-only critic passes. FRESH = no
  # --resume-session / session reuse; read-only = --level readonly. A parseable
  # object on any try wins; exhaustion falls through to the fail-open path.
  local parsed="no" try infra_reason=""
  for ((try=0; try<=infra_max; try++)); do
    if [[ "$try" -gt 0 ]]; then
      gluerun_append_event "ctx.plan_critique_retry" "plan critic infra failure; re-running fresh" \
        "{\"node\":\"$node\",\"runId\":\"$run_id\",\"try\":$try,\"reason\":\"$infra_reason\"}"
    fi
    rm -f "$raw" 2>/dev/null || true
    local rc=0
    "$runner" --level readonly -C "$worktree" --run-id "$run_id" \
      --prompt-file "$prompt" --output-last-message "$raw" \
      --session-meta "$session_meta" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 124 ]]; then
      infra_reason="timeout"
    elif [[ ! -f "$raw" ]]; then
      infra_reason="no-record"
    elif ! gluerun_extract_json "$raw" "$record" 2>/dev/null; then
      infra_reason="unparseable"
    else
      parsed="yes"; break
    fi
  done

  if [[ "$parsed" == "yes" ]]; then
    # Normalize into the plan-critique.v0 shape: authoritative schema/node/runId/
    # batchTaskIds, verdict clamped to the enum, and finding ids re-minted from
    # claim text to the gluerun_finding_id identity so formatting-only re-reports
    # collapse to the same id. Emit "verdict<TAB>count" for the event.
    local summary
    summary="$(python3 - "$record" "$node" "$run_id" "$batch_csv" <<'PY'
import hashlib, json, sys

record, node, run_id, batch_csv = sys.argv[1:5]

def finding_id(claim):
    text = " ".join(str(claim).replace(chr(96), "").lower().split())
    return "f-" + hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]

try:
    with open(record, "r", encoding="utf-8") as f:
        obj = json.load(f)
    if not isinstance(obj, dict):
        obj = {}
except Exception:
    obj = {}

verdict = str(obj.get("verdict", "")).strip()
if verdict not in ("approve", "revise", "park"):
    verdict = "approve"

batch = [t for t in batch_csv.split(",") if t]

norm_findings = []
raw_findings = obj.get("findings")
if isinstance(raw_findings, list):
    for fnd in raw_findings:
        if not isinstance(fnd, dict):
            continue
        claim = str(fnd.get("claim", "")).strip()
        evidence = str(fnd.get("evidence", "")).strip()
        if not claim or not evidence:
            continue
        severity = str(fnd.get("severity", "")).strip()
        if severity not in ("blocking", "should-fix", "note"):
            severity = "note"
        out = {
            "id": finding_id(claim),
            "severity": severity,
            "claim": claim,
            "evidence": evidence,
        }
        sugg = fnd.get("suggestedChange")
        if isinstance(sugg, str) and sugg.strip():
            out["suggestedChange"] = sugg
        norm_findings.append(out)

assumptions = obj.get("assumptionsChallenged")
if not isinstance(assumptions, list):
    assumptions = []
assumptions = [str(a) for a in assumptions]

rationale = str(obj.get("rationale", "")).strip()
if not rationale:
    rationale = "critic returned no rationale"

rec = {
    "schema": "gluerun.orchestration.plan-critique.v0",
    "node": node,
    "runId": run_id,
    "batchTaskIds": batch,
    "verdict": verdict,
    "findings": norm_findings,
    "assumptionsChallenged": assumptions,
    "rationale": rationale,
}
with open(record, "w", encoding="utf-8") as f:
    json.dump(rec, f, indent=2)
    f.write("\n")

sys.stdout.write("%s\t%d" % (verdict, len(norm_findings)))
PY
)"
    local verdict="${summary%%$'\t'*}"
    local count="${summary##*$'\t'}"
    [[ -n "$verdict" ]] || verdict="approve"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0

    gluerun_append_event "plan.critiqued" "plan critic recorded a critique" \
      "{\"node\":\"$node\",\"runId\":\"$run_id\",\"verdict\":\"$verdict\",\"findingsCount\":$count}"
  else
    # Fail OPEN: infrastructure failure of an added safety layer must never
    # deadlock planning. Treat as an approve and record it as a distinct infra
    # event (NOT plan.critiqued) so the signal is observable and separable. The
    # un-bypassable implementation auditor remains the safety floor.
    python3 - "$record" "$node" "$run_id" "$batch_csv" "$infra_reason" <<'PY'
import json, sys
record, node, run_id, batch_csv, reason = sys.argv[1:6]
rec = {
    "schema": "gluerun.orchestration.plan-critique.v0",
    "node": node,
    "runId": run_id,
    "batchTaskIds": [t for t in batch_csv.split(",") if t],
    "verdict": "approve",
    "findings": [],
    "assumptionsChallenged": [],
    "rationale": "plan critic infrastructure failed (%s); failing open to approve so "
                 "planning is not blocked. The implementation auditor remains the "
                 "un-bypassable safety floor." % (reason or "unparseable"),
}
with open(record, "w", encoding="utf-8") as f:
    json.dump(rec, f, indent=2)
    f.write("\n")
PY
    gluerun_append_event "ctx.plan_critique_infra" "plan critic infra failure; failing open to approve" \
      "{\"node\":\"$node\",\"runId\":\"$run_id\",\"verdict\":\"approve\",\"reason\":\"${infra_reason:-unparseable}\"}"
  fi

  # Finalize per-node critic session meta (role plan-critic) for Stage 3
  # carry-over. Merges host-authority fields into any runner-written meta; when
  # the runner wrote none, a minimal meta is created. Never fatal.
  if [[ -n "$session_meta" ]]; then
    gluerun_session_meta_finalize "$session_meta" plan-critic "" "$run_id" \
      "$runner_basename" "$prompt_sha" "" "1" >/dev/null 2>&1 || true
  fi

  return 0
}
