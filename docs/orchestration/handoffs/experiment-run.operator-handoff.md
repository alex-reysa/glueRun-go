# Operator hand-off — `experiment-run` (area: eval, kind: evaluation)

Status: **operator-blocked, planner-cannot-advance.** This record surfaces the
hand-off; it does not and cannot declare the node complete. Completion authority
for this area is the manually-published gate result
(`docs/orchestration/gates/experiment-run.gate-result.json`), which does not yet
exist.

## Why there is no L2 worker slice

`experiment-run` is a `kind: evaluation` node. Per
`docs/orchestration/planner-contract.md` rule 7 ("No tasks for `eval`-area
nodes. Those are operator-driven") and `docs/context-build-plan/stage-7-eval.md`
("Both nodes are operator-driven — reports and doc rewrites don't fit
strict-test-first mechanics"), the L1 planner must not generate an L2 worker
task here. The node's `requiredCompletion` (dag.v0.json) is an operator-run A/B
experiment plus an authored report and per-knob decisions — it has no code +
tests deliverable a strict-test-first worker could satisfy.

## The supporting toolchain is already integrated (no further brick applies)

Every measurement/rendering brick the report needs is built and merged; any
additional engine/CLI task would duplicate integrated work:

- Raw-metric aggregators — escape-rate/cost/bias (TASK-0077),
  resume/rehydrate hit-rate + gate-refusal reason-mix (TASK-0079),
  attempts-to-accept + findings-per-attempt (TASK-0081).
- Treatment-vs-control arm-delta (TASK-0089); composed summary bundle
  (TASK-0083).
- Renderers — per-arm tables (TASK-0085), corpus pipeline (TASK-0087),
  result-section delta+audit (TASK-0098), full report body (TASK-0100).
- Provenance + validity — per-run knob-state emitter (TASK-0093), l1-drive
  recording hook (TASK-0095), per-arm knob-state consistency audit (TASK-0097).
- Operator CLI surface `gluerun experiment-report` behind
  `GLUERUN_CTX_EXPERIMENT` (TASK-0091).

The `ab-harness` gate is already published
(`docs/orchestration/gates/ab-harness.gate-result.json`), so the harness to run
both arms is in place.

## Operator completion path (the node's only remaining path)

1. **Run the paired-audited A/B experiment** on a real backlog (≥ 40 accepted
   tasks per arm where feasible), via `GLUERUN_CTX_AB`:
   - Arm A (control) = M0 knob-state, continuity knobs OFF.
   - Arm B (treatment) = critique+revision + context packets + routing +
     rehydrate ON.
   - `GLUERUN_PAIRED_AUDIT_PCT=25` in **both** arms;
     `GLUERUN_CRITIC_RECHECK_PCT=25` in **arm B**.
2. **Author `docs/context-build-plan/experiment-report.md`** from the integrated
   tooling above: primary escape-rate, cost, and bias measurements plus the
   secondary (attempts-to-accept, findings-per-attempt, tokens/wall-clock,
   resume/rehydrate hit rates + gate-refusal reason mix) and treatment-effect
   (arm-delta) tables, with the raw-metric artifacts referenced.
3. **Record the per-knob default decisions** in
   `docs/orchestration/decisions.md` (which knobs flip default-ON, which stay
   opt-in, whether the Stage 6 graph earns further investment or is frozen).
4. **Publish `docs/orchestration/gates/experiment-run.gate-result.json`**
   manually with the evidence attached (schema
   `gluerun.orchestration.gate-result.v0`, matching the existing gate results in
   `docs/orchestration/gates/`).

Until step 4 is published with the report and per-knob decisions attached, the
node stays incomplete. No engine code, schema, or CLI hook moves the unpublished
gate.

## Follow-on (recorded, not part of this node's gate)

The singular-brain manifest arm cannot run in this repo (no curated
authored-knowledge corpus exists here); it runs in the consumer of record after
the 0.2.0 resync, per `docs/context-build-plan/stage-7-eval.md`. The S5
`contextManifest` hook ships fixture-tested regardless, so that consumer
experiment needs no engine change.
