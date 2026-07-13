# Planner Contract — glueRun self-hosted (context-evolution plan)

Create small, canonical, strict-test-first tasks validated by their gate
command. Keep owned files narrow, declare dependencies explicitly, and never
broaden scope beyond the node's stage file in `docs/context-build-plan/`.

## Binding rules for this consumer (the engine repo itself)

1. **New-file convention.** All new logic goes in new `engine/ctx-*.sh` files
   plus new `tests/test-ctx-*.sh` tests. `engine/lib.sh` may be owned ONLY by
   the `ctx-loader` node's task; after that node is gated, no task may own
   `lib.sh` — extend behavior by wrapping existing functions from `ctx-*.sh`
   files.
2. **Driver-file hooks are scarce.** `l1-drive.sh`, `generate-tasks.sh`,
   `l1-plan-node.sh`, `reconcile.sh`, `cli/gluerun`, `secret-scan.sh` may only
   receive small call-site hooks, and only in tasks for the DAG node that owns
   that hook (see the node descriptions). Keep each hook to the minimum lines
   that delegate into a `ctx-*.sh` function.
3. **Feature-flag discipline.** Every behavior change is default-OFF behind a
   documented `GLUERUN_*` knob and byte-identical to current behavior when
   OFF. Default flips are separate tasks, only after the stage exit gate.
4. **Additive schemas only.** New schemas live in `schemas/` under the
   `gluerun.orchestration.*.v0` namespace; changes to existing schemas are
   optional fields only. Validation fails closed.
5. **Test-first is literal.** The red log is the new `tests/test-ctx-*.sh`
   failing before implementation; green is it passing after; regression is the
   task's gate command.
6. **Engine cleanliness.** `tests/test-engine-clean.sh` must stay green — no
   project-specific symbols in `engine/`.
7. **No tasks for `eval`-area nodes.** Those are operator-driven
   (kind: evaluation). Emit tasks only for nodes whose stage file defines
   code + tests deliverables.
8. **Respect the advocate/skeptic line and evidence invariance.** No task may
   introduce a path where a resumed/rehydrated (tainted) session satisfies an
   independence-required step, weaken a gate, or make the fresh implementation
   auditor bypassable.

## Task shape

- Owned files: typically one `engine/ctx-*.sh` (or one hook site) plus its
  `tests/test-ctx-*.sh` — 1–2 files per slice, under the node's stage-file
  deliverables.
- Gate command: `bash tests/run.sh` (or, if the operator has configured a
  scoped gate, the task's scoped test plus `tests/test-engine-clean.sh`).
- Acceptance criteria: behavior-level, checkable by the named test, mirroring
  the node's `requiredCompletion`.
- Worker branch: `agent/<area>/<task-id>-<kebab-slug>`.

9. **No temporal negative assertions in tests.** A slice's test asserts the
   behavior of what THAT slice ships — never the absence of future work
   ("X is out of scope so it must not be defined", "present-but-uncalled"
   greps). Such assertions are true only until the next slice legitimately
   lands and have twice broken integration (TASK-0024's workaround,
   TASK-0028's integrate-gate red). Slice-boundary state belongs in the task
   file, not in permanent tests; behavioral guarantees (e.g. "this function
   never appends events") must be pinned behaviorally, not by absence.
