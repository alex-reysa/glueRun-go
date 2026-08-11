#!/usr/bin/env bash
# ctx-critic-recheck-context.sh — the pure, read-only assembler that composes the
# recheck context the RESUMED plan-critic reads: the ACCEPTED DIFF paired with the
# critic's OWN PRIOR FINDINGS as a per-concern checklist, framing the skeptic
# recheck question `for each of your prior concerns: addressed | survives | obsolete`.
# It advances the executable DAG node critic-carryover (stage S3-plan-revision, area
# plancritic, layer engine_runtime, kind runtime).
#
# It is the POST-ACCEPTANCE sibling of the integrated staged-candidate critic context
# assembler singular_ctx_plan_critic_context (TASK-0014, engine/ctx-plan-critic-context.sh):
# TASK-0014 composes the context for the PLANNING-time critique of staged candidate
# files; this brick composes the context for the post-acceptance recheck over the
# accepted diff. Different inputs (accepted diff + prior findings vs staged candidate
# files) and different purpose (addressed/survives/obsolete recheck vs initial
# critique), so it advances the stage rather than duplicating TASK-0014.
#
# Builds ONLY on already-integrated primitives — git (for the accepted diff), the
# singular.orchestration.plan-critique.v0 record shape (TASK-0012), the sampling knob
# (TASK-0027), and the classifier/recorder (TASK-0028). It does NOT depend on the
# resume authority decider (engine/ctx-critic-recheck-resume.sh, TASK-0029), which is
# accepted but NOT yet integrated.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# TASK-0014 / TASK-0027 / TASK-0028). This task does NOT own or edit lib.sh.
#
# Advocate/skeptic line + evidence invariance: the assembler reads staged inputs and
# writes ONLY its single composed output file. It changes no accept/reject outcome,
# weakens no gate, never lets a resumed context satisfy an independence-required step,
# and never makes the fresh implementation auditor bypassable. The whole recheck stays
# default-OFF behind SINGULAR_CRITIC_RECHECK_PCT (TASK-0027), consulted upstream by the
# follow-up runner. The read-only critic-resume RUNNER, the TASK-0029 resume authority,
# and the l1-drive.sh post-acceptance hook are sanctioned follow-up slices and are OUT
# OF SCOPE here.
#
# Public entry points:
#   singular_ctx_critic_recheck_accepted_diff <base_ref> <head_ref> [worktree]
#     PURE and READ-ONLY. Prints the accepted diff between the pre-acceptance base and
#     the accepted/merged head via `git diff` in [worktree] (default `.`). An empty /
#     indeterminate ref, or a non-repo worktree, yields empty output (fail-safe, never
#     a crash). Makes no commit/checkout/reset and mutates neither the worktree nor any
#     state. Always exits 0.
#   singular_ctx_critic_recheck_context <node> <task_id> <prior_critique_record> \
#                                      <accepted_diff_file> <out_file>
#     PURE assembler. Composes into <out_file>: (1) a header framing the skeptic recheck
#     question (per prior concern: addressed | survives | obsolete); (2) the id-sorted
#     per-finding checklist read from the prior plan-critique.v0 record (id, severity,
#     claim, evidence + the explicit per-finding recheck instruction); (3) the
#     accepted-diff content from <accepted_diff_file>. Writes ONLY <out_file>, appends
#     no event, invokes no runner, and mutates nothing else. Deterministic: findings
#     emit in id-sorted order so the composed context is byte-stable across runs.

# Pure/read-only accepted-diff reader. Prints `git diff <base> <head>` in the worktree;
# an empty/indeterminate ref or a non-repo worktree yields empty output. No mutation of
# worktree or state (no commit/checkout/reset). Always exits 0. See header for contract.
singular_ctx_critic_recheck_accepted_diff() {
  local base_ref="${1:-}" head_ref="${2:-}" worktree="${3:-.}"
  # Indeterminate/empty refs or a missing worktree -> empty output (fail-safe).
  [[ -n "$base_ref" && -n "$head_ref" ]] || return 0
  [[ -d "$worktree" ]] || return 0
  # Not a git repo -> empty output.
  git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1 || return 0
  # Both refs must resolve to commits, else empty output (never a crash).
  git -C "$worktree" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null 2>&1 || return 0
  git -C "$worktree" rev-parse --verify --quiet "${head_ref}^{commit}" >/dev/null 2>&1 || return 0
  # Read-only diff. `git diff <base> <head>` inspects committed trees only.
  git -C "$worktree" diff "$base_ref" "$head_ref" 2>/dev/null || true
  return 0
}

# Pure assembler: compose the read-only recheck context into <out_file>. Reads the
# prior plan-critique.v0 record and the accepted-diff file; writes ONLY the named output
# and mutates nothing else. Deterministic: findings emit id-sorted, so the output is
# byte-stable across runs for a fixed input set. A missing/unparseable record degrades
# to an empty checklist and a missing/empty diff file to an empty diff section (never a
# crash, never a fabricated finding).
singular_ctx_critic_recheck_context() {
  local node="${1:-}" task_id="${2:-}" prior_record="${3:-}" \
        diff_file="${4:-}" out_file="${5:-}"
  [[ -n "$out_file" ]] || return 2

  mkdir -p "$(dirname "$out_file")"

  {
    printf '# Critic Recheck Context: %s\n\n' "$node"
    printf 'Task: %s\n\n' "$task_id"
    printf 'Read-only post-acceptance recheck context for the resumed plan critic (skeptic).\n'
    printf 'For each of your prior concerns, answer: addressed | survives | obsolete.\n\n'

    printf '## Prior Findings Checklist\n\n'
    # Emit the id-sorted per-finding checklist from the plan-critique.v0 record. A
    # missing / unparseable / schema-divergent record yields NO findings (no
    # fabrication); the section header above still frames a well-formed context.
    python3 - "$prior_record" <<'PY' 2>/dev/null || true
import json, re, sys

path = sys.argv[1]
strict = re.compile(r"^f-[0-9a-f]{12}$")

def as_str(v):
    return v if isinstance(v, str) else ""

findings = []
try:
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    if isinstance(doc, dict) and doc.get("schema") == "singular.orchestration.plan-critique.v0":
        fl = doc.get("findings")
        if isinstance(fl, list):
            for it in fl:
                if not isinstance(it, dict):
                    continue
                fid = it.get("id", "")
                if isinstance(fid, str) and strict.match(fid):
                    findings.append({
                        "id": fid,
                        "severity": as_str(it.get("severity", "")),
                        "claim": as_str(it.get("claim", "")),
                        "evidence": as_str(it.get("evidence", "")),
                    })
except Exception:
    findings = []

findings.sort(key=lambda x: x["id"])
out = []
for it in findings:
    out.append("### {}".format(it["id"]))
    out.append("- severity: {}".format(it["severity"]))
    out.append("- claim: {}".format(it["claim"]))
    out.append("- evidence: {}".format(it["evidence"]))
    out.append("- recheck: is this prior concern addressed | survives | obsolete?")
    out.append("")
sys.stdout.write("\n".join(out))
if out:
    sys.stdout.write("\n")
PY

    printf '\n## Accepted Diff\n\n'
    # Embed the accepted-diff content. A missing/empty file degrades to an empty diff
    # section (no fabricated diff content).
    if [[ -n "$diff_file" && -f "$diff_file" ]]; then
      cat "$diff_file"
      printf '\n'
    fi
  } > "$out_file"

  return 0
}
