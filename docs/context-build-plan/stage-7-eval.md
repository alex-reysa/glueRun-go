# Stage 7 — Evaluation and polish (M7)

Purpose: prove it, write it down, ship it. Both nodes are operator-driven
(kind: evaluation — reports and doc rewrites don't fit strict-test-first
mechanics); gate results are published manually with the evidence attached.

## Node `experiment-run` (area: eval, kind: evaluation — operator-driven)

- Corpus: a real consumer backlog (or this repo's remaining Stage 6/7 tasks
  plus a consumer), ≥ 40 accepted tasks per arm where feasible.
- Arms via `GLUERUN_CTX_AB`:
  - A (control): engine as of M0 knob-state (continuity features OFF).
  - B (treatment): plan critique+revision ON, context packets ON, routing +
    rehydrate ON.
  - Paired audits at `GLUERUN_PAIRED_AUDIT_PCT=25` in BOTH arms;
    `GLUERUN_CRITIC_RECHECK_PCT=25` in arm B.
- Report `docs/context-build-plan/experiment-report.md`:
  - Primary: escape rate per arm (paired-audit confirmed disagreements,
    integration failures, reverts).
  - Secondary: attempts-to-accept, findings per attempt, tokens and wall-clock
    per accepted task, resume/rehydrate hit rates and their gate-refusal
    reason mix.
  - Bias measurement: context-aware (critic recheck / resumed reviewer)
    approval of changes that fresh paired audits flag — the directional
    disagreement rate IS the bias estimate.
  - Decision: which knobs flip default-ON, which stay opt-in, whether Stage 6
    graph earns further investment (multi-critic `fork` panels, relevance
    selection) or is frozen as-is.

Exit gate: report merged with raw metrics artifacts referenced; per-knob
default decisions recorded in `docs/orchestration/decisions.md`.

### Follow-on experiment (recorded, runs in the consumer of record)

The singular-brain manifest arm (integration point 4 of
`singular-brain-integration.md`) cannot run in THIS repo's experiment — no
curated authored-knowledge corpus exists here. It runs in PMGO-launch after
the 0.2.0 resync and dock wiring: arm A injects `docs/KNOWLEDGE.md` into
planner/worker prompts, arm B does not; same metrics (tokens/accepted task,
attempts-to-accept, escape rate). The S5 `contextManifest` hook ships
fixture-tested either way, so the consumer experiment needs no engine change.

## Node `polish-release` (area: eval, kind: evaluation — operator-driven)

- README: continuity + routing + graph sections rewritten around the shipped
  reality; knob table complete; the evidence-invariance principle stated where
  the old token-cost invariant lived.
- `CHANGELOG.md`, `VERSION` bump, migration notes (any `.gluerun-state` layout
  additions are new-dir-only; confirm no `SCHEMA_VERSION` bump is needed — all
  schema changes in this plan are additive/new).
- Knob-default flips decided by the experiment report, each as its own small
  reviewed change.
- Sweep: every `ctx.*` / `plan.*` event type documented; `gluerun metrics` and
  `gluerun graph` covered in the CLI docs; stale references to the retired
  invariant removed.

Exit gate: `gluerun doctor` + full suite green on a fresh clone at the release
tag; docs describe shipped behavior only.
