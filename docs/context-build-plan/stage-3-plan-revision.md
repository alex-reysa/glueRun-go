# Stage 3 — In-lineage plan revision (M3)

Purpose: the planner that produced a critiqued batch revises it in the same
reasoning lineage, with provenance. This is the first stage where continuity is
*intended to change outcomes* — which is why the invariant redefinition ships
here, not later.

## Node `plan-revision-loop` (area: plancritic, layer: engine_runtime)

Chains behind `planner-session-meta` for the `generate-tasks.sh` /
`l1-plan-node.sh` files, and behind `critique-import-gate` for semantics.

- On a `revise` verdict (and `GLUERUN_PLAN_CRITIQUE=1`): re-invoke the planner
  RESUMING its persisted node session (via `gluerun_planner_resume_decide`),
  with a revision prompt = base planner prompt + the structured critique
  findings (per-id) + the prior candidate set. Resume-refused → fresh planner
  with the same revision prompt (rehydrate-by-prompt; record which happened).
- Bounded by `GLUERUN_PLAN_REVISE_MAX` (default 1). Exhausted budget with a
  still-non-approve verdict → `park`.
- Revised candidates re-enter the critic (same critic session where its gates
  allow — its prior concerns are the checklist). Approve → import.
- Provenance events: `plan.revised` with `revisesRunId`, and per finding id a
  disposition `accepted-observation | rejected-observation` (the planner must
  state rejections explicitly in its batch output notes; silent drops count as
  accepted-but-unaddressed and are recorded — they feed the Stage 6 graph).
- Test `tests/test-ctx-plan-revision.sh` with stub runners: revise→approve
  path; budget exhaustion → park; resume vs fresh-fallback both covered;
  disposition events recorded.

Exit gate: suite green; full critique→revise→approve→import walk passes on
stubs; every disposition observable in events.

## Node `critic-carryover` (area: plancritic, layer: engine_runtime)

- The persisted plan-critic session (Stage 2) is offered ONE later engagement:
  after a task from its critiqued batch is ACCEPTED, an optional
  post-acceptance check — resume the critic read-only over the accepted diff
  with its own prior findings: "which of your concerns are addressed, which
  survive?" Output: per-finding `addressed | survives | obsolete` +
  `ctx.critic_recheck` events. Behind the paired-audit sampling knob's sibling
  `GLUERUN_CRITIC_RECHECK_PCT` (default 0).
- Never blocks or changes the outcome (records only) — it is the
  resume-a-specialist probe from the review, instrumented as data: its
  survives-rate vs. the paired FRESH audit's findings is the
  context-aware-vs-independent comparison.
- Same session-lease discipline as planner sessions; skeptic role gate: this
  session may never be resumed as planner/implementer.
- Test with stubs: recheck records; no outcome mutation; role gate enforced.

Exit gate: suite green; stub recheck produces per-finding dispositions.

## Node `invariant-docs` (area: eval, kind: evaluation — operator-driven)

- Rewrite the README continuity section: the invariant becomes **"routing never
  changes what counts as evidence"** (gates, red/green proofs, audit
  requirement identical under every strategy); outcomes MAY improve with
  continuity, and that improvement is measured (M0 metrics).
- Document the advocate/skeptic line, the plan-critique/revision stages, all
  new knobs to date, and the observe-only → enforce rollout pattern.
- Update `CHANGELOG.md`.

Exit gate: docs merged; no code claims contradicted by tests (operator
review against the shipped behavior).
