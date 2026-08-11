# Plan authoring — DAG, tasks, and the planner contract

How to turn a project goal into a Singular plan that the engine can execute
with maximum parallelism. Read this when creating or restructuring
`docs/orchestration/dag.v0.json`, writing `planner-contract.md`, or
hand-authoring task files.

## The DAG (`docs/orchestration/dag.v0.json`)

Schema: `singular.orchestration.dag.v0` (mirrored into the repo by
`singular init`; validate with `singular validate-dag`). Top level:

```json
{
  "schema": "singular.orchestration.dag.v0",
  "layers": ["contract", "runtime", "harness", "evaluation"],
  "kinds": ["contract", "runtime", "harness", "evaluation"],
  "nodes": [ ... ]
}
```

Node fields (all required except `description`; no extra fields allowed):

| Field | Meaning |
| --- | --- |
| `id` | Stable kebab-case identifier. Becomes the gate filename (`gates/<id>.gate-result.json`) and the argument to `area-gate` / `promote-gate`. |
| `stage` | Human grouping label (e.g. `S0-baseline`, `M1`). Does NOT constrain scheduling — only `dependsOn` does. |
| `area` | Must name a key in `singular.config.json` `areas{}`. Determines the file scopes workers for this node may own. |
| `layer` / `kind` | Must appear in the top-level `layers` / `kinds` arrays. Taxonomy for humans and tooling; `kind: evaluation` marks operator-driven nodes that planners must NOT emit tasks for. |
| `dependsOn` | Array of node ids. A node joins the frontier when every dependency has a passing gate result. |
| `requiredCompletion` | Behavior-level completion criterion, checkable by command/test. This is what the gate promoter certifies. |
| `description` | Context for the L1 planner: ownership boundary, pointers to design docs, hook budget. |

### Designing for a wide frontier

Wall-clock time ≈ the longest dependency chain, not the node count. Before
finalizing a DAG, check it:

1. **Count the frontier at each wave.** Simulate: which nodes are ready at
   t0? After those gate, which become ready? If any wave has one node, ask
   whether the chain is real or just cautious sequencing.
2. **Disjoint file ownership between concurrent nodes.** Two frontier nodes
   whose tasks own the same file will serialize at integration (or conflict).
   Put shared plumbing in an early "loader/contract" node everyone depends
   on, then fan out.
3. **Scarce hook files get an owner.** If many nodes must eventually touch
   one file (a dispatcher, a CLI entry, a lib loader), assign each hook site
   to exactly one node in its `description` and forbid the rest in the
   planner contract. This is the single most effective anti-conflict rule.
4. **Contract nodes before runtime nodes.** A cheap node that lands a schema
   or interface unlocks several implementation nodes in parallel.
5. **Keep evaluation/report nodes out of the critical path** (`kind:
   evaluation`, operator-driven) and depend them on the things they measure.

### Editing a live DAG

The DAG can be extended while orchestration runs — add nodes with correct
`dependsOn` and the next reconcile picks them up. Do not rename a node id
that already has tasks or a gate result; add a new node instead.

## Task files (`docs/orchestration/tasks/TASK-XXXX.md`)

Normally emitted by L1 planners (staged as
`singular.orchestration.task-batch.v0` JSON — `{taskId, markdown}` pairs —
then imported by L0). Hand-author only for seeding or hotfixes, using
`docs/orchestration/tasks/TEMPLATE.md`:

```markdown
# TASK-XXXX: <title>

Status: ready
Area: <area key from singular.config.json>
Target branch: `agent/integration`
Worker branch: `agent/<area>/TASK-XXXX-<kebab-slug>`
Test policy: `strict_test_first`
Gate command: `bash tests/run.sh`
Dispatch mode: canonical
Depends on: []

## Objective
Describe the smallest independently verifiable change.

## Scope
Owned files:
- `path/to/file`        (bare paths, one per bullet)

Forbidden files:
- Any file outside the owned scope.

## Acceptance Criteria
- Behavior-level, checkable by the named test; the gate command passes.
```

Field notes:

- `Status: ready` makes it dispatchable; the engine moves it through
  `leased → integrated` (or `parked`/`escalated`).
- `Worker branch` must be unique per task; the `agent/<area>/<task>-<slug>`
  convention keeps integration attribution clean.
- `Depends on` orders tasks *within* a node; keep it empty when possible —
  task-level dependencies serialize workers.
- Owned files are the enforced write scope (checked against the node's
  `area` scopes). Narrow scopes (1–2 files) parallelize best.
- `Gate command` — the per-task gate; it takes precedence over the config
  `gateCommand`, which is the fallback when the task field is absent. Tasks
  normally carry the same command as the config; a scoped gate (single test
  file + the invariant suite) is a legitimate speed optimization.

## The planner contract (`docs/orchestration/planner-contract.md`)

Scaffolded by the engine; the L1 planners read it as binding rules. This is
where you encode repo-specific discipline once instead of re-explaining it
every run. Rules that have proven their worth in production:

1. **New-file conventions.** "New logic goes in new `<prefix>-*.ext` files
   plus new `test-*` files" — new files can't conflict with parallel work.
2. **Scarce-hook discipline.** Name the driver files that may only receive
   minimal call-site hooks, and which DAG node owns each hook.
3. **Feature-flag discipline.** Behavior changes ship default-OFF behind a
   documented knob, byte-identical when OFF; default flips are separate
   tasks after the stage gate.
4. **Test-first is literal.** Red log from the new test before
   implementation; green after; the task's gate command as regression.
5. **Slice sizing and bundling.** 1–2 owned files per task, but bundle small
   *dependent* slices into one task up to the batch-width budget — each
   dispatched micro-task pays ~25 minutes of fixed overhead (worktree,
   session, audit).
6. **No temporal negative assertions in tests.** A test must pin what its
   slice ships, never the absence of future work ("X must not be defined
   yet", present-but-uncalled greps) — such tests break when the next slice
   legitimately lands.
7. **Sibling-test ownership.** A task that changes an invariant asserted by
   a sibling's test must own that test file too, at authoring time.
8. **No tasks for `kind: evaluation` nodes** — those are operator-driven.

## Prompts (`docs/orchestration/prompts/`)

`singular init` copies role skeletons (l0-origin, l1-planner,
l1-area-orchestrator, l2-test-first-developer, auditor, reviewer,
plan-critic, decider). Rewrite them for the repo's stack — language, test
runner, code conventions. Keep the auditor and plan-critic prompts skeptical
and independent; they are the quality floor.

## Checklist before first actuate

- [ ] `singular validate-dag` passes.
- [ ] `singular next-areas` shows the frontier you expect (wave 1 width ≥ 2
      unless the work is genuinely serial).
- [ ] Every node's `area` exists in `singular.config.json` `areas{}` and the
      scopes cover the files its tasks will own.
- [ ] `gateCommand` actually proves repo health (not `false`, not a no-op).
- [ ] `planner-contract.md` names the scarce hook files and slice rules.
- [ ] Prompts rewritten for the stack; `singular doctor` clean.
