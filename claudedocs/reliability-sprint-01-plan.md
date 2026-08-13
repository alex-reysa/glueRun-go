# Reliability Sprint 01 — audited, actionable plan (supersedes workflow_replay_checkpoint_reliability.md)

Status: ready to execute, self-hosted on Singular 0.18.0
Target release: 0.19.0
Source: independent third-party review (2026-08-13) of `claudedocs/workflow_replay_checkpoint_reliability.md`
against the 0.18.0 checkout at HEAD `2def444c`, plus forensics of the AXON B211 run state.
Execution: `docs/orchestration/dag.v0.json` (program `rel-*`), tasks `TASK-0108`..`TASK-0125`.

## What the audit changed

The original plan was reviewed claim-by-claim against the code. This plan keeps only what survived.

Confirmed and kept (with corrected scope):

- Worker per-try log destruction on infra retries (`engine/l1-drive.sh` redirects every try to the
  same `worker-codex.log` with `>`). The auditor log already appends with per-try separators and
  per-try runner results + raw provider envelopes already exist — so the fix is parity with
  existing conventions, not a new artifact scheme.
- `revalidate-evidence` is runtime-indistinguishable from `retry`: it bumps the product lease
  counter and re-runs the implementer. The verdict enum promises a remedy the engine does not
  implement.
- `audit-infra` is overloaded: 13 emitter sites spanning gate infra, evidence binding/recapture,
  auditor infra, host tooling, and one source-integrity violation; 8 of the sites park
  unconditionally with zero retries. The labeled taxonomy in `engine/infra-patterns.tsv` is
  computed and then discarded by routing.
- Provider/gate deadlines are frozen at spawn; a mid-flight budget raise has no effect
  (empirically confirmed: B211 kills at exactly the stale budget, three raises each landing
  after the kill they were meant to prevent).
- Terminal handoff is an in-process EXIT trap; SIGKILL leaves a permanently `active` run-status
  record. A worker+auditor double success can still terminalize `escalate-infra`
  (post-verdict manifest-refresh and model-reported-inconclusive sites).
- `singular test` already contains all six supervised-job properties (flock liveness, atomic
  manifest, attach, progress, process-group reaping, interrupted reconciliation) but is welded to
  one hardcoded suite; gates share only the pgid idiom via a duplicated implementation.
- No checkpoint/WIP-preservation mechanism exists; the only preservation is the end-of-attempt
  commit. `scope-check.sh` and `secret-scan.sh` are reusable for checkpoint scoping as-is.

Corrected or dropped from the original plan:

- Recovery does NOT judge staleness solely by lease age. `recover.sh` runs a five-way
  process-tree liveness probe and skips live runs; the streaming worker log keeps the run-dir
  mtime fresh. The real residues, now the actual scope: the 240-minute hard cap that overrides
  liveness (`SINGULAR_STALE_HARD_MINUTES`), the dispatch-record precondition, and L1 planning
  leases which have no liveness check at all.
- "Runner and provider-session identities never appear in the authoritative record" — they are
  durable in `runner-session.json`, the dispatch record, and `session-<role>.json`; run-status v1
  is a correlation fix (reference those records), not a rebuild.
- "Deterministic host policy for known codes" already shipped (`singular_decider_fast_action`,
  default on, with provenance and tests). Removed as a workstream.
- Infra tries already never consume product retry budget (tested invariant). The real budget
  defects are: evidence remedies draw from the product pool, and most `audit-infra` sites get
  zero retries.
- The full at-most-once external-effect ledger is deferred: every known consumer (Spokit,
  singular-frontend, AXON) is a code-change consumer; effect receipts live in consumer product
  layers. The engine keeps only invariant 7 as a fail-closed non-goal for now.
- Budget derivation heuristics (>= 4x p95) moved out of the engine (console/consumer policy).
- Checkpoint grades `validated`/`candidate`, lineage-bound restore, and GC are deferred pending
  a second consumer's field evidence; this sprint ships `snapshot`-grade capture + verify only.

Unclaimed defects found by the audit, added to this sprint:

- `engine/ctx-route-drive.sh` reads `audit-codex.log`; the driver writes `auditor-codex.log`.
  With `SINGULAR_CTX_ROUTING=1` (this repo's own config!) the reviewer window gate fails closed
  and reviewer resume is permanently disabled.
- Worker `last-message.json` is never cleared between tries (the auditor clears its record);
  a stale try-0 output can mask an `empty-output` classification on try 1.
- The attempt archive omits `auditor-codex.log` and all per-try runner-result/envelope sidecars.
- Untested invariants: try>0 must omit `--resume-session`; `recover.sh`'s skip-because-alive
  branch; the `SINGULAR_STALE_HARD_MINUTES` boundary.

## Safety invariants (release blockers, carried over and trimmed)

1. A checkpoint preserves bytes; it never means accepted, audited, integrated, or promotable.
   A checkpoint cannot satisfy packet, audit, gate-result, integration, or promotion checks.
2. A resumed advocate session never serves as an auditor or any independence-required reviewer.
   (Existing invariant — `README.md` advocate/skeptic line — must stay green.)
3. Reattach and result reuse require exact job identity: task, canonical argv, effective
   environment allowlist, workspace, head/input identity, engine contract version.
4. Gate evidence stays bound to the exact tested tree, command, inputs, and log hashes
   (existing `evidenceBindingSha256` regime; the new job identity complements, never replaces it).
5. Only task-owned paths enter a checkpoint; forbidden, generated, secret-bearing, and unrelated
   dirty paths fail closed (reuse `scope-check.sh` + `secret-scan.sh`).
6. Evidence remedies never invoke the implementer and never consume product retry budget.
7. Non-goal guard: no engine path may auto-redispatch work it knows performed an ambiguous
   external effect. (Full effect contract deferred; nothing in this sprint may weaken this.)
8. Recovery never restores or kills work while the supervised process tree is provably live
   (existing five-way probe stays authoritative; the hard cap gains a liveness escape hatch).

## Milestones -> DAG stages

Stage S1 ships alone as the minimum viable milestone. Every task is independently gateable and
carries its own strict-test-first RED before behavior changes.

### S1 — defect fixes, no competing execution paths (tasks 0109-0118)

| Task | Node | Fix |
|---|---|---|
| TASK-0109 | rel-01-per-try-logs | Worker log append + per-try artifacts parity; archive copy-set completed |
| TASK-0110 | rel-02-try-hygiene | Clear stale `last-message.json` between tries; test the try>0-fresh invariant |
| TASK-0111 | rel-03-integrity-reclass | Source-integrity violation gets its own class + parked-for-human routing |
| TASK-0112 | rel-04-evidence-remedy | `revalidate-evidence` gets a real evidence-only handler (zero implementer calls) |
| TASK-0113 | rel-05-manifest-remedy-bound | Bounded retry at the four one-shot evidence-manifest `audit-infra` emitters |
| TASK-0114 | rel-06-terminal-handoff | Durable terminal-pending handoff; double success can never park as infra |
| TASK-0115 | rel-07-run-control | Read-only run-control: deadline/cancel re-read inside every poll loop |
| TASK-0116 | rel-08-route-transcript | Fix the reviewer transcript filename in ctx routing (live bug in self-hosting) |
| TASK-0117 | rel-09-l1-lease-liveness | L1 planning-lease liveness probe before wall-clock reclaim |
| TASK-0118 | rel-10-failure-domains | Additive `failureDomain` + formalized attempts-index schema |

### S2 — supervised jobs (tasks 0119-0121)

Extract the proven `singular test` machinery into a generic primitive (parameterized command,
`cancel`, bounded `wait`); one shared identity canonicalizer for evidence binding and job
identity (three hand-rolled recomputations exist today — a fourth would guarantee drift); gates
attach by exact identity instead of re-running, with `gate-check.sh`'s result deletion moved
after the attach decision.

### S3 — honest status (task 0122)

run-status v1 as an additive record: `processAliveAt` vs `lastProgressAt` split, monotonic
`progressSeq`, and references to the existing identity records (runner-session, dispatch,
session meta). Dual-write v0 for compat. Recovery reads liveness/progress; the 240-minute hard
cap defers to fresh `processAliveAt`. Adds the missing live-tree and hard-cap boundary tests.

### S4 — preservation (tasks 0123-0124)

Snapshot-grade emergency checkpoint on controlled timeout (private ref, hash-bound manifest,
verify command, no automatic restore); infra-try session resume for timeout/transport classes
behind the existing ten identity gates, with a separate runtime-resume counter.

### S5 — release (task 0125)

CHANGELOG 0.19.0, README contract sections, full `bash tests/run.sh`, field-report canary,
fresh-consumer and migration compatibility green. Operator-authority release gate.

## Explicitly deferred (need a second consumer's evidence)

- `validated`/`candidate` checkpoint grades, restore lineage policy, checkpoint GC.
- Cross-run session resume after an `escalate-infra` unpark cycle.
- Writable run-control (extensions with generation/identity binding) beyond deadline/cancel re-read.
- Generic job progress as a consumer-facing interface.
- At-most-once effect ledger/wrapper/receipts (consumer product layer today).
- Budget heuristics derived from history.

## Success metrics (per release)

- Zero destroyed or overwritten try logs (fixture + soak).
- Zero evidence-domain failures that invoke the implementer.
- Zero product-budget consumption by infrastructure/runtime/evidence recovery.
- Zero timeout kills that fire after an operator raised the budget (bounded by one poll interval).
- Zero duplicate executions for identical supervised-job identities.
- Double success (worker + auditor exit 0) can never terminalize as an infrastructure park.
- Existing suites stay green: process containment, EPERM honesty, advocate/skeptic separation,
  exact-HEAD evidence, decider fastpath, field-report canary.

## Running the sprint (self-hosted)

The program DAG is installed as `docs/orchestration/dag.v0.json` (the completed 0.4.0
context-continuity program is archived at `docs/orchestration/archive/dag.ctx-continuity.v0.json`;
its gate records under `docs/orchestration/gates/` are historical provenance and are not read by
the new program). Tasks are `docs/orchestration/tasks/TASK-0108.md` through `TASK-0125.md`.

- Validate: `bash engine/dag.sh validate-dag`
- Preview (dry-run, the no-arg default): `singular reconcile`
- One real cycle: `singular reconcile --actuate`
- Autonomous: `singular auto` (respects `SINGULAR_MAX_HOURS`, maxConcurrent 3)
- The serial `rel-01`..`rel-06` lane intentionally chains the `l1-drive.sh`-owning tasks;
  `rel-07`..`rel-10` and the S2 extraction tasks run in parallel lanes.
