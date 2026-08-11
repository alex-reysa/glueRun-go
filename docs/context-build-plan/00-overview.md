# Context-Aware Orchestration — Build Plan (self-hosted)

> **STATUS: COMPLETE 2026-07-13** — all 22 DAG nodes gate-passed
> (`../orchestration/gates/`), 107 tasks integrated, 0.4.0 released.
> Knob-default decisions: `experiment-report.md` §5.

This plan evolves singular from "session continuity as a token-cost optimization"
to "context as a first-class, routed, measured capability" — while preserving the
engine's design center: reproducibility, durable authoritative state, role
isolation, parallelism, independent review, and recovery without hidden provider
memory.

It is written to be **docked with the engine itself**: the DAG manifest at
`docs/orchestration/dag.v0.json` references these stage files, and each area has a
`docs/orchestration/areas/<AREA>/state.md`. The L1 planner reads the stage file for
its node and emits strict-test-first task slices against `engine/` and `tests/`.

## Findings this plan responds to

From the architecture review (2026-07-09):

1. Session affinity today is *strictly intra-run*: gate 5 of
   `singular_session_resume_decide` requires runId equality, and every
   `l1-drive.sh` invocation mints a new run id. Resume only ever helps attempts
   2..N of one drive. Planner sessions are never persisted at all.
2. `templates/prompts/reviewer.md` exists and is wired to nothing — a plan-review
   role was contemplated but never built. There is no plan-critique →
   plan-revision stage; planner output is only mechanically validated.
3. The durable-truth layer partially exists (event log, decision records, gate
   results, attempt archive, capsules, findings ledger) but nothing *routes* on
   it, and it has no plan-level nodes (plan versions, critiques, assumptions,
   rejected alternatives).
4. The README invariant "session resume never changes a task outcome" is
   incompatible with intentional context continuity and must be redefined (see
   Stage 3): the durable property is **resume never changes what counts as
   evidence** — gates, required proofs, and independent audits are identical
   regardless of routing; outcomes may improve.
5. Role separation is a security boundary (injection persistence), not only a
   bias control. The fresh independent auditor must remain un-bypassable, and
   durable context artifacts need the same secret hygiene as commits.

## Target end state

- Planner sessions persist per DAG node and can be resumed across runs under
  explicit lineage gates.
- Every imported task batch has passed a first-class plan-critique stage with
  structured findings; the planner revises in-lineage before import.
- Task handoffs carry a context packet: decisions, assumptions (with lifecycle
  status), rejected alternatives, inspected symbols.
- Session routing is an explicit, reason-coded decision among five named
  strategies — `continue`, `resume`, `fork`, `fresh`, `rehydrate` — implemented
  as ordered fail-closed gates (never a numeric score), with model-decider
  fallback only where judgment is genuinely required.
- A provenance graph exists as a **pure projection** of the event log and
  decision records (rebuildable at any time; never a source of truth), and
  rehydration packets are assembled from selected subgraphs.
- Continuity value and reviewer bias are *measured*: A/B arms per task, paired
  fresh-vs-context-aware audits, escape-rate tracking.
- All of it behind default-OFF flags until each stage's exit gate, then flipped
  ON with the evidence recorded.

## Design principles (binding on every task)

1. **Feature-flag discipline.** Every behavior change ships default-OFF behind a
   `SINGULAR_*` knob and is byte-identical to current behavior when OFF. A
   separate small task flips the default after the stage exit gate passes.
   (Precedent: `SINGULAR_FIX_PROMPT_STRUCTURED`, `SINGULAR_DECIDER_FAST`.)
2. **New-file convention.** All new logic lands in new `engine/ctx-*.sh` files.
   `engine/lib.sh` is touched exactly once in this whole plan (Stage 0 loader
   hook). Existing driver files (`l1-drive.sh`, `generate-tasks.sh`,
   `l1-plan-node.sh`, `reconcile.sh`, `cli/singular`, `secret-scan.sh`) may only
   gain small call-site hooks, and nodes owning the same driver file are
   serialized via `dependsOn` in the DAG.
3. **Additive schemas only.** New schemas use the existing
   `singular.orchestration.*.v0` namespace; extensions to existing schemas are
   optional fields only. Fail closed on validation.
4. **Event-sourced everything.** New state is appended as events/records first;
   the graph (Stage 6) is a projection of those records, never written directly
   by models.
5. **The advocate/skeptic line.** No session ever crosses from an advocate role
   (planner, implementer) to a skeptic role (critic, auditor) or back. Per-role
   session-meta files remain the structural enforcement. The fresh independent
   auditor cannot be disabled by any new knob.
6. **Evidence invariance.** No routing strategy may weaken what counts as
   evidence: same gates, same red/green proofs, same audit requirement,
   regardless of `fresh`/`resume`/`rehydrate`.
7. **Engine cleanliness.** `tests/test-engine-clean.sh` must stay green: no
   project-specific symbols in `engine/`. Everything here is generic engine
   capability.

## Stages and milestones

| Stage | Milestone | Nodes | Est. tasks |
| --- | --- | --- | --- |
| S0 baseline | **M0 — Measured baseline.** Loader hook, metrics extractor, A/B arm assignment, paired-audit sampling. We can measure the current engine before changing it. | `ctx-loader`, `metrics-extract`, `ab-harness`, `paired-audit` | 6–9 |
| S1 planner persistence | **M1 — Planner survives planning.** Planner session meta persisted per node; planner-role resume gates (node lineage, not runId). | `planner-session-meta`, `planner-resume-gates` | 4–6 |
| S2 plan critique | **M2 — Plans are reviewed before import.** Critique schema + prompt, staged-candidate critic, import honors verdicts. | `plan-critique-contract`, `plan-critic-driver`, `critique-import-gate` | 5–8 |
| S3 plan revision | **M3 — Plans revise in-lineage.** Resume planner with findings; bounded revision loop; critic session carry-over; invariant redefinition in docs. | `plan-revision-loop`, `critic-carryover`, `invariant-docs` | 5–7 |
| S4 context packets | **M4 — Handoffs carry reasoning.** Task/capsule context-packet fields; assumption ledger wired into fix/re-audit prompts; secret-scan over durable context artifacts. | `context-packet-contract`, `assumption-ledger`, `artifact-secret-scan` | 5–7 |
| S5 routing | **M5 — Routing is explicit.** Five named strategies, reason-coded; window-pressure + diff-volume gates; session leases; rehydrate path. | `routing-module`, `rehydrate-path` | 5–8 |
| S6 graph | **M6 — Durable graph projection.** context-graph.v0; projector from events; subgraph-assembled rehydration packets. | `graph-contract`, `graph-projector`, `subgraph-rehydrate` | 5–8 |
| S7 evaluation | **M7 — Proven and polished.** Formal A/B + paired-audit experiment and report; README/CHANGELOG/knob docs; release. | `experiment-run`, `polish-release` | 3–5 |

Stage files: `stage-0-baseline.md` … `stage-7-eval.md` in this directory. Each
node's `requiredCompletion` in the DAG mirrors that stage file's exit gate.

Node completion is published as an authoritative `gate-result.v0` record under
`docs/orchestration/gates/` once the exit gate holds (evidence:
`bash tests/run.sh` command log at the integrated head). `proofLayers` stays
empty for this plan — the standard every-log-exit-0 deterministic-proof rule
applies, without the red skip-guard regime.

## New operator knobs introduced by this plan

| Knob | Stage | Default at intro | Meaning |
| --- | --- | --- | --- |
| `SINGULAR_CTX_AB` | S0 | `0` | Deterministic per-task arm assignment (hash of task id) recorded in events. |
| `SINGULAR_PAIRED_AUDIT_PCT` | S0 | `0` | Sampled second, fresh audit on accepted diffs; disagreements recorded, outcome unchanged. |
| `SINGULAR_PLANNER_SESSION` | S1 | `0` | Persist planner session meta per node; enable planner-role resume gates. |
| `SINGULAR_PLAN_CRITIQUE` | S2 | `0` | Run the plan critic over staged candidates before import. |
| `SINGULAR_PLAN_REVISE_MAX` | S3 | `1` | Max in-lineage plan revision cycles per batch. |
| `SINGULAR_CTX_PACKET` | S4 | `0` | Emit/consume context-packet fields in tasks and capsules. |
| `SINGULAR_CTX_ROUTING` | S5 | `0` | Route via the five-strategy module instead of the legacy resume decide. |
| `SINGULAR_SESSION_WINDOW_MAX_PCT` | S5 | `70` | Refuse resume above this estimated context-window usage. |
| `SINGULAR_REHYDRATE` | S5 | `0` | Allow capsule-injected fresh starts when resume is refused. |
| `SINGULAR_CTX_GRAPH` | S6 | `0` | Maintain the provenance-graph projection. |

## Docking checklist (operator, manual)

1. Install/pin the engine: `bash install.sh`, then in this repo write
   `.singular-version` with the installed version. **All driving happens through
   the installed pin (`~/.singular/bin/singular`), never `engine/` from this
   working tree** — that is what makes self-hosting safe: workers modify
   `engine/*.sh` on task branches in worktrees while the frozen pinned copy
   drives. The modified engine only takes over when you deliberately
   `singular update` after a milestone.
2. `singular init` (scaffolds `docs/orchestration/` pieces that are missing), then
   copy `templates/prompts/*.md` into `docs/orchestration/prompts/` — the
   tailored `l1-planner.md` and `planner-contract.md` in this dock take
   precedence and must not be overwritten.
3. Create `singular.config.json` at the repo root:

   ```json
   {
     "schemaVersion": "v1",
     "engineVersion": "<installed version>",
     "targetBranch": "agent/integration",
     "gateCommand": "bash tests/run.sh",
     "runner": "claude-run.sh",
     "areaPrefix": "engine/",
     "areas": {
       "foundation": ["engine/", "tests/"],
       "session": ["engine/", "tests/"],
       "plancritic": ["engine/", "tests/", "schemas/", "templates/prompts/"],
       "packets": ["engine/", "tests/", "schemas/", "templates/prompts/"],
       "routing": ["engine/", "tests/"],
       "graph": ["engine/", "tests/", "schemas/", "cli/"],
       "eval": ["docs/", "README.md", "CHANGELOG.md"]
     },
     "proofLayers": [],
     "proofGrandfather": [],
     "prewarm": "",
     "identity": {
       "l0": { "name": "singular L0", "email": "l0@singular.local" },
       "l1": { "name": "singular L1", "email": "l1@singular.local" }
     },
     "env": {}
   }
   ```

4. Create the `agent/integration` branch from `main`. Promotion from
   `agent/integration` to `main` is a manual, per-milestone operator action.
5. `singular doctor`, then `SINGULAR_ROOT=$PWD engine/dag.sh validate-dag` (one-off
   check is fine from the tree; *driving* is not).
6. Timebox check: run `bash tests/run.sh` once and note the wall time. It runs on
   **every attempt** as the task gate. If it exceeds ~3 minutes, split: per-task
   `Gate command` scoped to the relevant `tests/test-ctx-*.sh` plus
   `test-engine-clean.sh`, with the full suite enforced at node-gate promotion.

## Engine-driven vs. operator-driven nodes

Default: **the engine drives.** Exceptions, on purpose:

- **`contract`-layer nodes** (`ctx-loader`, `plan-critique-contract`,
  `context-packet-contract`, `graph-contract`) are judgment-heavy, low-volume
  design work. They are single-slice by engine default
  (`SINGULAR_SINGLE_SLICE_LAYERS=contract`). Drive them through the engine if you
  like, but the operator reviews the diff before integration — set
  `SINGULAR_AUTO_INTEGRATE=0` while a contract node is in flight.
- **`evaluation`-kind nodes** (`invariant-docs`, `experiment-run`,
  `polish-release`) do not fit strict-test-first mechanics (reports, doc
  rewrites, an experiment run). Drive these manually; publish their gate results
  by hand with the evidence produced.

## Risks and mitigations

- **Self-modification hazard** → version pinning (checklist §1). Never point
  `SINGULAR_RUNNER`/drivers at the working tree.
- **`lib.sh` / driver-file contention** serializing parallelism → new-file
  convention + explicit `dependsOn` chains between nodes that hook the same
  driver file (encoded in the DAG). Expected parallelism is modest; this project
  is more serial than a greenfield consumer, and that is fine.
- **Gate wall-time** → checklist §6.
- **Distillation loss on design tasks** — the early stages are built by an
  engine that lacks the very continuity they add. That is why contract nodes get
  operator review. It is also the point: friction observed here is data for the
  experiment.
- **Injection persistence via resumed sessions** → advocate/skeptic line
  (principle 5), un-bypassable fresh auditor, taint framing in Stage 5, secret
  scanning of durable context artifacts in Stage 4.
- **Graph rot / wrong nodes propagating** → graph is a projection (principle 4);
  model-authored content enters as `claim`, only host-verified evidence as
  `authoritative`.

## Success metrics (tracked from M0 onward)

Primary: **escape rate** — defects surfacing after acceptance (integration
failures, paired-audit disagreements confirmed real, reverts) per accepted task,
split by arm/strategy. Secondary: attempts-to-accept, auditor findings per
attempt, tokens per accepted task, wall-clock per accepted task. The Stage 7
report answers: does in-lineage continuity reduce escapes and attempts at
acceptable cost, and what is the measured bias of context-aware review?
