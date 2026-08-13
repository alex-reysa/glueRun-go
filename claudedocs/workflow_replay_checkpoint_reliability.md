# Singular replay, checkpoint, and supervised-job reliability plan

Status: implementation plan only  
Target: the first post-0.18 Singular reliability release  
Source: static inspection of the AXON B211 run and the current Singular 0.18 checkout

## Outcome

Reduce the dominant retry cost: losing validated work and gate progress inside a long-running worker attempt. The engine should preserve task-owned bytes, attach to identical in-flight jobs, resume safe infrastructure failures, and route evidence defects without restarting implementation.

This work is for a new Singular campaign after the active AXON beta. It is not a reason to migrate the current 0.16 campaign to Singular 0.18, and it does not create a legacy state-import path.

## Current-state findings confirmed in this checkout

- Worker infrastructure retries are forced fresh in `engine/l1-drive.sh`; only try 0 can receive `--resume-session`.
- Every worker try redirects to the same `runs/<runId>/worker-codex.log`, replacing the previous try.
- `engine/run-status.sh` writes `lastProgressAt` on every status update, so liveness/activity and material progress are not independent facts.
- Attempt archives are post-attempt copies of mutable root artifacts. They do not protect mid-attempt work.
- `singular test` already has most of the correct generic job semantics in `cli/singular`: durable manifests, an exclusive kernel lock, attach, progress, process-group ownership, and interrupted reconciliation. Gate execution does not reuse that abstraction.
- Gate infrastructure failures, evidence binding/recapture failures, and auditor infrastructure failures can all surface as `audit-infra`.
- `revalidate-evidence` enters the same retry branch as product fixes and therefore starts another worker attempt.
- Provider and gate timeouts are read once and converted to fixed in-process deadlines.
- Recovery judges staleness solely by lease `updatedAt` age (default 60 minutes), and nothing writes liveness during a blocking runner call, so a healthy multi-hour worker is indistinguishable from an abandoned one.
- Run status records only the controller PID; the actual runner and provider-session identities never appear in the authoritative record.
- A run can terminalize as `escalate-infra` after both worker and auditor exit 0, and a driver killed mid-handoff leaves `L1 driver exited before a durable terminal handoff` with no resumable terminal state.
- No task-level at-most-once external-effect declaration or receipt protocol exists.

## Observed cost in the AXON B211 run (2026-08-12)

One day of the pinned-0.16 campaign, reconstructed read-only from run state; these are the baselines phase 0 should reproduce as fixtures:

- 13 TASK-0280 drive runs and ~11h50m of wall clock before the first accepted-quality GREEN proof.
- 3 timeout kills, each at exactly the then-current budget (2400 s, 7200 s, 7200 s). The budget was raised 2400 → 7200 → 14400 across the day and every raise landed after the kill it was meant to prevent, because deadlines are computed once at spawn.
- Every kill triggered a fresh-session replay; the shared log redirect let try 1 truncate try 0's entire trace, leaving only the provider envelope.
- `run-status.json`, the lease, and `events.ndjson` sat 4h22m stale during a healthy try — inside the default staleness window that would have let recovery reclassify live work.
- The only mid-task byte preservation was an operator hand-mirroring two untracked files into a recovery directory 9 s–2 min after each edit; the engine owned none of it.
- 4 runs ended `L1 driver exited before a durable terminal handoff`; 1 run terminalized `escalate-infra` after worker and auditor both exited 0.
- While a ~10–15 minute gate executed, the worker spent roughly one provider round-trip per minute on sleep/poll babysitting at maximum reasoning effort.

## Safety invariants

These are release blockers, not implementation preferences:

1. A checkpoint preserves bytes; it never means accepted, audited, integrated, or promotable.
2. A resumed advocate session can never serve as an auditor or other independence-required reviewer.
3. Reattach and result reuse require exact job identity: task, command argv, effective environment, workspace, input/head identity, and engine contract version.
4. Gate evidence remains bound to the exact tested Git tree, command, inputs, and log hashes.
5. Only task-owned paths may enter a task checkpoint. Forbidden, generated state, and unrelated dirty paths fail closed.
6. Product, evidence, infrastructure, and worker-runtime remedies have separate budgets. One domain cannot silently consume another's budget.
7. A task declaring a non-idempotent effect is never replayed after an ambiguous outcome without either proof of no effect or an idempotency-bound receipt.
8. Recovery never restores or kills work while the corresponding supervised job is provably live.

## Release strategy

Keep `schemaVersion: v2` if all new records are additive and readers continue to accept existing v0 records. Introduce new record IDs instead of changing closed v0 shapes in place:

- `singular.orchestration.run-status.v1`
- `singular.orchestration.job.v0`
- `singular.orchestration.job-progress.v0`
- `singular.orchestration.checkpoint.v0`
- `singular.orchestration.failure.v0`
- `singular.orchestration.effect-receipt.v0`

Write new records behind narrow feature flags during dogfooding, but do not maintain two competing execution paths after promotion. Compatibility mirrors may exist for console/readers; they must not remain authoritative.

## Dependency order

| Phase | Deliverable | Depends on | Exit gate |
|---|---|---|---|
| 0 | Baseline and contracts | none | fixtures reproduce the known failure modes |
| 1 | Immutable tries and honest progress | 0 | retries cannot destroy logs; liveness and progress diverge correctly |
| 2 | Generic supervised jobs | 0; phase 1 for engine integration | identical gates attach; interrupted jobs reconcile without duplication |
| 3 | Git-backed checkpoints | 1, 2 | focused-green bytes survive timeout and restore hash-identically |
| 4 | Infrastructure resume | 3 | safe failures resume; unsafe/refused resumes rehydrate from checkpoint |
| 5 | Failure/remedy routing | 1-4 | evidence defects never restart implementation |
| 6 | At-most-once effects | 2, 5 | ambiguous effects park; receipts permit safe continuation |
| 7 | Rollout and removal of flags | all | AXON-scale soak and upgrade gates pass |

Phase 1 and extraction of the phase 2 core can proceed in parallel after phase 0; gate integration waits for phase 1's identity/progress records. Checkpoint implementation and failure-taxonomy design can also proceed in parallel, but failure routing should not become authoritative until supervised-job and checkpoint remedies exist.

## Phase 0 — Baseline, schemas, and executable failure fixtures

### Work

1. Capture an AXON-like hermetic fixture with:
   - a worker that writes useful task-owned bytes and then times out;
   - two worker infrastructure tries;
   - a long gate that emits progress before its launching client disappears;
   - an evidence hash/binding failure after a green product gate;
   - an ambiguous external effect;
   - a timeout budget raised mid-flight that must take effect within one poll interval;
   - a worker+auditor success that must not terminalize as an infrastructure park;
   - a driver killed between gate completion and terminal handoff.
2. Define one canonical identity algorithm for jobs and checkpoints. Use canonical JSON plus SHA-256; never shell-joined text.
3. Define the new schemas and their forward/unknown-field policy.
4. Record baseline measures: duplicate jobs, lost validated bytes, fresh-session infra retries, product attempts consumed by non-product defects, and time from interruption to safe recovery.

### Primary files

- `schemas/`
- `tests/field-report-canary.sh`
- new focused tests under `tests/`
- `README.md` contract sections

### Acceptance

- Every source finding has a failing focused test before behavior changes.
- Identity is byte-stable across process restarts and rejects any changed argv, environment allowlist, head/input hash, workspace, model, effort, role, or prompt.
- Existing v0 fixtures remain readable.

## Phase 1 — Immutable per-try artifacts and honest run status

### Work

1. Make per-try paths canonical:
   - `worker-attempt-<n>-try-<m>.log`
   - `worker-attempt-<n>-try-<m>-last-message.json`
   - `worker-attempt-<n>-try-<m>-runner-result.json`
   - equivalent auditor and gate paths.
2. Keep `worker-codex.log` only as a compatibility view. Prefer an append-only aggregate with explicit attempt/try headers; readers must use the per-try index as authority.
3. Add an atomic `tries/index.json` containing identity, start/end times, result/failure class, session strategy, log hash, output hash, and checkpoint reference.
4. Introduce run-status v1:
   - `processAliveAt` changes only after a liveness probe;
   - `lastProgressAt` changes only when material JSONL/log/evidence/checkpoint progress advances;
   - `progressSeq` is monotonic;
   - `updatedAt` remains the last metadata write;
   - `processes` records controller, runner, and provider-session identity (v0 records only the controller PID, so the authoritative record has never named the process actually doing the work).
5. Teach console and recovery readers to dual-read v0/v1 while writers emit v1 under the feature flag.
6. Stage terminal handoff atomically: write the terminal record to a `terminal-pending` marker before the driver's final transition, so a driver killed mid-handoff reconciles to the recorded outcome instead of a bare `failed`.

### Primary files

- `engine/l1-drive.sh`
- `engine/run-status.sh`
- `schemas/run-status.v1.schema.json`
- `engine/recover.sh`
- console state readers and timeline projections
- `tests/test-run-status.sh`
- `tests/test-continuity-core.sh`

### Acceptance

- A retry leaves every prior try's log, last message, runner result, and hashes unchanged.
- Activity heartbeats advance `processAliveAt` without advancing `lastProgressAt`.
- Appending a progress event, changing a declared evidence artifact, or creating a checkpoint advances `lastProgressAt` exactly once.
- Recovery uses liveness to avoid reclamation and progress age to diagnose a stuck live job.
- A driver killed between gate completion and terminal handoff reconciles to the recorded outcome, and a worker+auditor success can never terminalize as an infrastructure park.

### Rollback

Disable v1 writes and return readers to the v0 compatibility record. Immutable try files are additive and need no rollback.

## Phase 2 — Extract a generic supervised-job primitive

### Work

1. Extract the proven machinery embedded in `cli/singular` into a reusable host-owned component, for example `engine/supervised_job.py`.
2. Define the job identity as a hash of:
   - task/run/role and engine contract version;
   - canonical argv (not a shell string);
   - selected effective environment values and their source;
   - workspace identity and Git head/tree;
   - declared input/evidence hashes.
3. Persist per-job:
   - manifest and identity document;
   - exclusive supervisor lock;
   - append-only stdout/stderr log;
   - generic `progress.jsonl`;
   - process-group record;
   - result and interruption reconciliation.
4. Support `start`, `status`, `attach`, `wait`, and `cancel`. A second identical request attaches. A different identity starts a different job or fails if policy permits only one active gate for the task.
5. Let consumer commands emit optional generic progress events through an engine-provided path. Suggested phases are opaque strings such as `preflight`, `candidate`, `reproducibility`, and `acceptance`; the engine stores but does not interpret them.
6. Move `singular test` onto the primitive, then integrate worker gates and disposable audit gates.

### Primary files

- `cli/singular`
- new `engine/supervised_job.py`
- `engine/gate-check.sh`
- `engine/audit-verify.sh`
- `schemas/job.v0.schema.json`
- `schemas/job-progress.v0.schema.json`
- `tests/test-cli-test-run.sh`
- new `tests/test-supervised-job.sh`
- new `tests/test-gate-attach.sh`

### Acceptance

- Two identical gate launches execute the consumer command once and both attach to the same result.
- A worker waiting on a supervised job spends zero provider turns while waiting: `wait` is one blocking engine call with a bounded server-side timeout, not model-driven sleep/poll loops.
- Command, environment, head/tree, input, or engine-contract drift prevents attachment/reuse.
- Killing the launcher does not kill a detached job; killing the supervisor reconciles it to `interrupted` and terminates its owned process group.
- `ps` denial does not cause duplicate launch or false-dead reporting.
- A completed result is reused only when policy explicitly permits it and every identity/evidence hash still matches.

### Rollback

Gate integration can fall back to direct `gate-check.sh`; the generic job records remain inert evidence. Keep `singular test` on the extracted primitive once parity tests pass.

## Phase 3 — Git-backed checkpoint protocol

### Work

1. Add host-owned commands:
   - `singular checkpoint create`
   - `singular checkpoint show/list`
   - `singular checkpoint verify`
   - `singular checkpoint restore`
2. Build checkpoint commits with a temporary Git index and a private ref such as `refs/singular/checkpoints/<task>/<run>/<sequence>`. Do not move the worker branch or disturb its index.
3. Include only task-owned paths after scope and secret checks. Record rejected/unowned paths without capturing their bytes.
4. Persist a hash-bound manifest containing:
   - task, run, attempt, try, role, provider/model/effort, prompt identity, and session lineage;
   - worktree HEAD, checkpoint commit/tree, parent checkpoint, owned-file set, and diff hash;
   - validation argv, exit code, log ref/hash, and tested tree when known;
   - phase, job identity, progress sequence, evidence refs/hashes, and creation reason.
5. Treat checkpoints in three grades:
   - `snapshot`: bytes preserved; validation unknown or red;
   - `validated`: a declared focused gate passed and is bound to the checkpoint tree;
   - `candidate`: full task gate passed, still not audited/accepted.
6. Add two capture paths:
   - explicit worker milestone capture after a focused-green validation;
   - automatic emergency capture after controlled timeout/runtime failure and at safe quiescent points. A live snapshot must verify identical pre/post worktree fingerprints or be discarded as incoherent.
7. Restore only into the same task scope and compatible lineage. Default to a clean recovery worktree; never overwrite unrelated local changes.
8. Add garbage collection that preserves every checkpoint referenced by a run, try, finding, or effect receipt.

### Primary files

- new `engine/checkpoint.py` or `engine/checkpoint.sh`
- `cli/singular`
- `engine/l1-drive.sh`
- `engine/scope-check.sh`
- `engine/secret-scan.sh`
- `schemas/checkpoint.v0.schema.json`
- new `tests/test-checkpoint.sh`
- new `tests/test-checkpoint-recovery.sh`

### Acceptance

- A worker writes a useful owned change, records a focused-green validation, then times out; the validated checkpoint restores byte-identically in a new worktree.
- Unowned, forbidden, secret-bearing, or concurrently mutating content never enters a checkpoint.
- A checkpoint cannot satisfy packet, audit, gate-result, integration, or promotion checks.
- Tampering with the commit, manifest, validation log, evidence, or parent lineage makes verification fail closed.

### Rollback

Stop creating/restoring checkpoints. Private refs and manifests remain inspectable and are pruned only by explicit checkpoint GC.

## Phase 4 — Resume infrastructure retries and runtime controls

### Work

1. Replace the current `worker_try > 0 => fresh` rule with a host decision:
   - resume only for infrastructure or worker-runtime failures;
   - require role, session, provider/model/effort, prompt, job identity, worktree/checkpoint tree, and lease lineage to match;
   - never resume an advocate session as an auditor.
2. On safe resume, pass the same role session plus the latest verified checkpoint reference and an infrastructure-recovery prompt.
3. On resume refusal or unsafe lineage, start fresh but inject a compact checkpoint capsule: checkpoint hash, diff summary, validation result, open findings, and exact restore state.
4. Separate counters and limits for product attempts, infrastructure tries, worker-runtime resumes, evidence remedies, and provider-overload backoff.
5. Add an atomic `run-control.json` with generation and identity binding. Poll loops may re-read cancel/deadline changes. Record every control change as an event; do not let untrusted worker output edit it. The read-only half — deadline and cancel re-read in every provider poll loop — is independent of resume and can ship with phase 1; it closes the operator-ratchet trap (raise lands after the kill) on its own.
6. Prefer progress-aware diagnosis over automatic unlimited extension. A control-plane extension is explicit and bounded; lack of progress can still trigger checkpoint-then-timeout.
7. Record per-task worker and gate durations, and derive suggested budgets from history (for example ≥ 4× the observed p95 gate duration) instead of leaving operators to ratchet one global constant reactively.

### Primary files

- `engine/l1-drive.sh`
- all provider runner scripts
- session routing/meta helpers in `engine/lib.sh`
- new `schemas/run-control.v0.schema.json`
- `tests/test-session-affinity.sh`
- `tests/test-provider-failure-contract.sh`
- new timeout-control and checkpoint-resume tests

### Acceptance

- Timeout, transient transport exit, and provider overload resume when every gate matches and do not consume product retry budget.
- Changed model, effort, prompt, head/tree, role, task, command, or environment forces a fresh rehydrated run.
- Resume refusal performs one fresh fallback without losing the immutable prior try or checkpoint.
- Mid-run deadline extension takes effect in a bounded poll interval and is visible in the event log.

### Rollback

Set infrastructure retry strategy to fresh. Checkpoint rehydration remains available and preserves work even with session resume disabled.

## Phase 5 — Structured failure domains and remedy routing

### Work

1. Preserve specific `failureClass` codes but add a host-derived `failureDomain`:
   - `product`
   - `evidence`
   - `infrastructure`
   - `worker-runtime`
2. Split overloaded classes. At minimum distinguish:
   - gate product red;
   - gate execution infrastructure;
   - evidence missing/stale/hash-mismatch/bind/recapture;
   - auditor provider/runtime/structured-output failures;
   - worker timeout/provider/invalid-packet/runtime failures.
3. Make remedies domain-specific:
   - product: implementation retry, consumes product budget;
   - evidence: recapture, rebind, or re-audit from the same accepted candidate tree; never call the implementer automatically;
   - infrastructure: attach/backoff/resume, consumes infrastructure budget;
   - worker-runtime: checkpoint then resume/rehydrate, consumes runtime budget.
4. Replace the current shared retry case in `l1-drive.sh` with explicit remedy handlers. `revalidate-evidence` must not flow through `prepare_worker_prompt` or `run_worker_phase`.
5. Make deterministic host policy authoritative for known codes. Use the model decider only for genuinely ambiguous product/governance decisions.
6. Add domain and remedy counts to attempt/job metrics and the console.

### Primary files

- `engine/l1-drive.sh`
- `engine/lib.sh`
- `engine/decide.sh`
- `schemas/failure.v0.schema.json`
- `schemas/decider-verdict.v0.schema.json` or a new versioned record
- `tests/test-decider-fastpath.sh`
- new `tests/test-evidence-remedy-routing.sh`

### Acceptance

- Evidence recapture/rebind/re-audit completes with zero implementer invocations.
- Infrastructure and runtime recovery do not increment the lease's product retry count.
- A product assertion cannot be relabeled as infrastructure/evidence by model output.
- Unknown failure codes fail closed to a recorded parked state with the original evidence intact.

### Rollback

Keep the richer failure record but route through the previous decider behavior under one compatibility flag. Do not merge counters back together in persisted history.

## Phase 6 — At-most-once external-effect contract

### Work

1. Extend task metadata with an explicit effect policy:
   - `none` (default)
   - `idempotent` with required idempotency-key strategy
   - `at-most-once` with required receipt/no-effect proof contract
2. Add a host-owned effect ledger with states such as `prepared`, `executing`, `succeeded`, `no-effect-proven`, and `outcome-unknown`.
3. Require effectful operations to run through an engine wrapper or connector capable of binding request hash, idempotency key, provider receipt, and response hash. A prompt declaration alone is not enforcement.
4. Before retry:
   - reuse a success receipt for the same request/idempotency identity;
   - retry only after verified `no-effect-proven`;
   - park on `outcome-unknown`.
5. Bind effect receipts into packet and audit evidence without treating the receipt as product acceptance.

### Primary files

- task parser/generator and templates
- new `engine/effect.py`
- capability policy
- `schemas/effect-receipt.v0.schema.json`
- state packet/evidence manifest readers
- new `tests/test-external-effect-contract.sh`

### Acceptance

- An interrupted at-most-once effect with no receipt parks and cannot redispatch.
- A provider-supported idempotency key safely returns the same receipt without a second effect.
- A no-effect proof permits exactly one new execution.
- Changed request bytes or idempotency identity cannot reuse a prior receipt.

### Rollback

Tasks declaring an effect policy remain fail-closed. Disabling the feature must not silently execute them through the ordinary worker path.

## Phase 7 — Rollout, soak, and release gates

### Work

1. Dogfood on synthetic long-worker and long-gate fixtures, then on a fresh AXON-derived DAG after the current campaign finishes.
2. Run fault injection at every boundary: launcher death, supervisor death, process-inspection denial, provider timeout, resume refusal, disk-full/atomic-write failure, corrupted JSONL, Git ref tampering, and reboot-like stale PIDs.
3. Add console views for current job identity, liveness age, progress age, latest checkpoint grade, recovery strategy, and budget domain.
4. Publish operator commands for status, attach, checkpoint verification/restore, parked-effect inspection, and safe GC.
5. Remove feature flags only after the soak thresholds hold for two release candidates.

### Release gates

- Zero duplicate executions for identical supervised-job identities.
- Zero destroyed or overwritten try logs.
- Zero evidence-domain failures that invoke the implementer.
- Zero product-budget consumption by infrastructure/runtime/evidence recovery.
- Every injected timeout after a focused-green checkpoint restores the same tree hash.
- Every ambiguous non-idempotent effect parks.
- Existing process containment, EPERM honesty, advocate/skeptic separation, and exact-HEAD evidence suites remain green.
- Full `bash tests/run.sh`, field-report canary, fresh-consumer setup, migration compatibility, and an AXON-scale soak pass.

## Recommended first implementation milestone

Cut the first milestone after phases 0-2, before checkpointing:

1. immutable worker/auditor/gate try artifacts;
2. run-status v1 with separate liveness/progress clocks;
3. extracted supervised-job primitive;
4. worker and disposable audit gates attach by exact identity;
5. read-only run-control: mid-flight deadline/cancel re-read in every provider poll loop.

This milestone is independently valuable, low migration risk, and creates the trustworthy identity/progress substrate required by checkpoint restore and safe session resume.

## Success metrics

Measure per release and by provider/model:

- validated checkpoint restore rate;
- infrastructure resume hit/refusal/fallback rate;
- recovered validated bytes and estimated avoided worker tokens/time;
- duplicate-job prevention count;
- time since liveness vs time since progress;
- product attempts per accepted task;
- retries and budget consumption by failure domain;
- evidence-only recovery rate;
- timeout kills that fire after an operator had already raised the budget (target: zero);
- provider turns consumed while a supervised gate is executing (babysitting overhead, target: ~zero);
- ambiguous-effect park count and duplicate-effect count (target: zero).

## Explicit non-goals

- Migrating the live AXON 0.16 state into Singular 0.18.
- Treating a WIP commit or green focused test as acceptance.
- Reusing auditor sessions for independence-required final audits.
- Understanding Docker, Trivy, PostgreSQL, or product-specific gate phases in the generic job layer.
- Automatically retrying an ambiguous external effect.
