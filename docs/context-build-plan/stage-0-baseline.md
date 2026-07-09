# Stage 0 — Baseline and instrumentation (M0)

Purpose: make the current engine measurable and create the single structural
hook every later stage builds on. Nothing in this stage changes task outcomes.

## Node `ctx-loader` (area: foundation, layer: contract, single-slice)

The only task in the entire plan allowed to own `engine/lib.sh`.

- Add one guarded loader block near the end of `lib.sh`: source every
  `engine/ctx-*.sh` file (sorted, if any exist) exactly once. No ctx files
  present → byte-identical behavior. A ctx file that fails to source must fail
  loudly (fail closed), not silently skip.
- Document the convention in a header comment: all context-evolution logic
  lives in `engine/ctx-*.sh`; `lib.sh` is frozen for this plan.
- Test `tests/test-ctx-loader.sh`: (a) no ctx files → engine functions
  unchanged; (b) a fixture ctx file's function becomes available; (c) a broken
  fixture fails the source loudly.

Exit gate: `bash tests/run.sh` green including `test-ctx-loader.sh`;
`test-engine-clean.sh` green; diff to `lib.sh` is the single loader block.

## Node `metrics-extract` (area: foundation, layer: harness)

- `engine/ctx-metrics.sh`: read-only extractor over `runs/*/attempts/index.json`
  and the event log. Emits per-task and aggregate JSON: attempts-to-accept,
  failure classes, audit verdicts, `workerStrategy`/`reviewerStrategy` mix,
  `context.strategy_selected` reasons, decider authority mix.
- `cli/gluerun` gains a `metrics` subcommand delegating to it (small hook; this
  node owns the `cli/gluerun` edit).
- Test `tests/test-ctx-metrics.sh` over fixture run dirs.

Exit gate: `gluerun metrics --json` produces stable, documented fields from
fixtures; suite green.

## Node `ab-harness` (area: foundation, layer: harness)

- `engine/ctx-ab.sh`: deterministic arm assignment — hash(taskId) → arm A/B —
  behind `GLUERUN_CTX_AB=0`. Assignment recorded as an `ctx.arm_assigned` event
  at dispatch; NO behavior differs between arms in this stage (arms gain meaning
  as later stages key their knobs off the arm).
- Determinism requirement: same task id → same arm, machine-independent.
- Test `tests/test-ctx-ab.sh`: determinism, distribution sanity on a fixture id
  set, OFF → no events.

Exit gate: suite green; with the knob OFF, zero new events.

## Node `paired-audit` (area: foundation, layer: engine_runtime)

The bias-measurement instrument. Owns the FIRST `l1-drive.sh` hook of the plan
(later routing nodes chain behind this node for that file).

- `engine/ctx-paired-audit.sh` + one post-acceptance hook in `l1-drive.sh`:
  with probability `GLUERUN_PAIRED_AUDIT_PCT` (default 0), after a task is
  ACCEPTED, run one additional auditor pass — always FRESH session, base auditor
  prompt, read-only — and record its verdict + findings as
  `ctx.paired_audit` events and a `paired-audit.json` in the run dir.
- MUST NOT change the task outcome, lease, packet, or inbox placement — it runs
  strictly after acceptance and only records.
- Disagreement definition: paired verdict != accepted, or paired findings
  non-empty. `ctx-metrics.sh` learns to report disagreement rate.
- Test `tests/test-ctx-paired-audit.sh` with a stub runner: sampling honors the
  knob; acceptance flow byte-identical with knob 0; disagreement recorded.

Exit gate: suite green; a stub-driven accepted task with PCT=100 produces the
paired record and an unchanged acceptance outcome.
