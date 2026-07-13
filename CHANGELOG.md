# Changelog

All notable changes to **glueRun-go** are recorded here. This project follows
semantic versioning. The `schemaVersion` (the `.vN` contract of the JSON schemas +
config shape) is called out separately from the package version, because consumers
and the plugin negotiate on `schemaVersion`.

---

## [0.4.0] — 2026-07-13 — Context-aware orchestration (self-hosted S0–S7 complete)

Completes the context-evolution plan the engine built against itself: 107
worker-implemented, independently audited, gate-promoted tasks across 20
executable DAG nodes, closed by an operator-authored experiment report
(`docs/context-build-plan/experiment-report.md`). Additive and default-OFF at
the raw engine level; the **shipped config flips five knobs ON per the
report's per-knob decisions** (see below). Raw-default flips are deferred to
0.5 with a test-migration slice (OFF-parity tests pin unset == legacy).

- **Context packets + assumption ledger** (`GLUERUN_CTX_PACKET`): planner
  reasoning residue (decisions / assumptions / rejected alternatives /
  inspected symbols) rides task files into worker, fix, and audit prompts;
  per-run assumption ledger with host-derived status transitions in the
  assumption grammar `[open|validated|violated]`.
- **Artifact secret scan + quarantine** (`GLUERUN_CTX_ARTIFACT_SCAN`):
  `secret-scan.sh --artifacts` covers capsules, session meta, packets,
  critique and paired-audit records; hits rename to `.quarantined`, emit
  `ctx.artifact_secret`, and are excluded from every prompt-assembly and
  rehydration path without changing task outcomes.
- **Explicit session routing** (`GLUERUN_CTX_ROUTING`): one dispatcher
  (`gluerun_ctx_route`) returning `continue|resume|fork|fresh|rehydrate`
  with a reason code; window-pressure and diff-volume refusal gates;
  generalized session leases; structural taint marking makes
  independence-pinned steps (final + paired audits) unreachable by resumed or
  rehydrated sessions; per-role strategy/outcome metrics splits.
- **Rehydration** (`GLUERUN_REHYDRATE`): deterministic, capped,
  quarantine-aware packets assembled from durable artifacts (packets,
  capsules, ledgers, critiques, decision records) injected on refused-resume
  lineage steps, with the packet manifest recorded in strategy events.
  Optional authored-knowledge manifest ingestion (`GLUERUN_CTX_MANIFEST` +
  additive `contextManifest` config field): select → eligibility
  (`load-when` across role/step/node/task) → compose → inject → record,
  fixture-contract only (singular-brain bridge, no runtime dependency).
- **Context graph** (`GLUERUN_CTX_GRAPH`): `context-graph.v0` schema
  (append-only JSONL nodes/edges, full edge taxonomy,
  `evidenceClass: authoritative|claim`, provenance refs) + S0–S5
  event-to-graph mapping; deterministic projector over all record families;
  incremental sync ≡ rebuild; loss-free delete/rebuild; query read API
  (neighbors, lineage walk, open-contradictions); `gluerun graph
  rebuild|sync|query` CLI. Subgraph-selected rehydration (lineage-walk
  selection, rejected observations excluded, contradictions surfaced first)
  with a flat-vs-subgraph A/B arm.
- **Experiment toolchain** (`GLUERUN_CTX_EXPERIMENT` /
  `GLUERUN_CTX_ARMSTATE`): per-arm aggregators (escape-rate, cost, bias,
  attempts-to-accept, findings-per-attempt, resume/rehydrate hit-rates,
  refusal reason mix), treatment-vs-control delta, knob-state provenance
  recording + consistency audit, markdown renderers, composed report body,
  `gluerun experiment-report` CLI, operator hand-off record.
- **Shipped-config defaults per the experiment report**: `PLANNER_SESSION`,
  `PLAN_CRITIQUE`, `CTX_PACKET`, `CTX_ROUTING`, `CTX_ARTIFACT_SCAN` ON and
  `PAIRED_AUDIT_PCT=25` in the self-dock config; `REHYDRATE`,
  `CTX_MANIFEST`, `CTX_GRAPH`, `CTX_EXPERIMENT` stay opt-in pending
  live-scale / consumer evidence.
- New event types: `context.strategy_selected`, `context.resume_failed`,
  `ctx.arm_assigned`, `ctx.artifact_secret`, `ctx.paired_audit`,
  `ctx.critic_recheck`, `ctx.packet_malformed`, `plan.critiqued`,
  `plan.revised`, `plan.revise_parked`, `planner.backoff_active`.

---

## [0.4.0-m1] — 2026-07-11 — Context-evolution M0–M3 (self-hosted, unreleased dev pin)

Built by the engine itself under `docs/context-build-plan/` (self-docked, all
tasks worker-implemented, independently audited, and gate-promoted with hashed
evidence). Everything below is additive and default-OFF unless noted.

- **Self-measurement**: `gluerun metrics --json` over the attempts index +
  event log; deterministic per-task A/B arms (`GLUERUN_CTX_AB`); sampled
  post-acceptance paired fresh audits (`GLUERUN_PAIRED_AUDIT_PCT`).
- **Planner session persistence and resume** (`GLUERUN_PLANNER_SESSION`):
  per-node session meta, node-lineage + template-sha gates, session leases,
  rc-86 fresh fallback, reason-coded `context.strategy_selected` events.
- **Plan critique** (`GLUERUN_PLAN_CRITIQUE`): `plan-critique.v0` schema,
  fresh read-only skeptic critic over staged batches, critique-aware L0
  import (approve/revise/park, fail-closed on missing record, fail-open on
  critic infra).
- **Plan revision loop** (`GLUERUN_PLAN_REVISE_MAX`): bounded
  revise → (resume|fresh) → re-critique with per-finding dispositions and
  `plan.revised` provenance events; critic re-critique may resume the
  critic's own session (skeptic-only).
- **Invariant redefined**: the old "resume is a token-cost optimization that
  never changes a task outcome" is replaced by **evidence invariance** —
  routing never changes what counts as evidence; outcomes may improve with
  continuity and the improvement is measured. Advocate/skeptic line documented.
- Hermeticity hardening from self-docking: suite scrubs inherited GLUERUN_*
  env and runs tests with stdin from /dev/null.

---

## [0.3.0] — 2026-06-10 — Initial public release of glueRun-go

This is the first public release of glueRun-go. It ships detached dispatch **ON by
default** (`GLUERUN_DETACHED_DISPATCH=1`): the reconcile cycle no longer blocks on
its worker batch. The legacy batch barrier held the origin lock across every worker
(minutes to hours), freezing packet import, integration of already-finished work,
recovery, STATUS, and STOP responsiveness until the slowest worker finished. With
detached dispatch on, reconcile pre-leases each frontier task, spawns the worker in
its own session, and returns within seconds; the reaper attributes outcomes on later
cycles via dispatch records + exit files.

### Detached dispatch (default ON: `GLUERUN_DETACHED_DISPATCH=1`)

- Reconcile pre-leases each frontier task (`status=planned`, scope published) and
  spawns the worker in its own session via `dispatch-wrap.sh`, then returns within
  seconds; the origin lock is held for the cycle's control work only. Set
  `GLUERUN_DETACHED_DISPATCH=0` to restore the legacy batch wait path.
- **Dispatch records** (`.gluerun-state/dispatch/<taskId>.json`) + worker exit
  files; a **reaper** (`gluerun_reap_dispatches`, run at the top of every
  apply/actuate cycle before recovery) attributes completions, failures, and
  crashes (pid + `ps lstart` liveness, defeating pid reuse). Crash detection
  drops from the 60-min stale-lease window to ~one cycle.
- `reconcile.sh --drain` blocks until no launched dispatch records remain
  (tests, clean shutdown). New stdout fields `reaped_ok=`, `reaped_failures=`,
  `workers_running=`, `detached_dispatch=` (additive; legacy fields intact).
- Autonomy accounting (flag-gated): a dispatch alone is no longer progress —
  progress is an observed completion, an integration, or newly planned work;
  reap failures count toward the circuit breaker. Batch-mode accounting unchanged.
- `recover.sh`: pid-aware fast-stale backstop — an active lease whose dispatch
  pid is gone is reclassified immediately instead of after the stale window.
- New events: `origin.dispatch_reaped`, `origin.worker_reaped` (in-cycle wait
  now also records per-worker exit + duration for utilization baselines).

### Concurrency hardening (always on)

- Lease/task state writes (`gluerun_lease_write`, `gluerun_lease_set_status`,
  `gluerun_lease_bump_retry`, `gluerun_lease_update_owned`,
  `gluerun_task_set_status`) are now tmp+rename atomic — no torn reads while
  workers and reconcile mutate control state concurrently.
- `integrate.sh` merge/abort/finalize and reconcile's control-state `add`+`commit`
  now run under the repo-wide git-op lock shared with worker git operations
  (the regression gate still runs outside the lock).
- Both dispatch modes spawn through `dispatch-wrap.sh`, which persists the
  driver's exit code and backstops a lease the driver never owned (or died
  holding) so it stops consuming a concurrency slot.

### Context continuity

- Host-built per-attempt **context capsules**: a hash-stamped
  `implementer-capsule.json` (what the worker was tasked with) and
  `reviewer-capsule.json` (what the auditor reviewed/concluded).
- A **findings ledger** (`findings-status.json`) upserted from each audit
  verdict, with stable finding ids (format-insensitive) tracked open/resolved.
- **Structured fix prompts** carry the authoritative open findings forward on
  retry, replacing the truncated byte-tail (`GLUERUN_FIX_PROMPT_STRUCTURED=0`
  restores the legacy `fix_hints` tail byte-for-byte).
- **Re-audit delta prompts**: prior findings + fix diff + per-id verification
  targets, requesting an additive `findingsStatus` map
  (`{<findingId>: "resolved" | "still-open"}`) alongside the normal verdict.
- **Per-attempt artifact archive** under `runs/<id>/attempts/<n>/` (root files
  copied, never moved) with an `attempts/index.json`.
- New events: `context.strategy_selected`, `findings.ledger_updated`,
  `l1.attempt_archived`.

### Session affinity

- Optional role-keyed runtime **session resume** (`codex exec resume`,
  `claude -r`) behind 10 staleness gates, defaulting ON
  (`GLUERUN_SESSION_AFFINITY=1`). Any gate failure — or a runner that refuses the
  resume — degrades to a fresh run within the same attempt. Session resume is a
  token-cost optimization that **never changes a task outcome**.
- New event: `context.resume_failed`.

### Reliability

- **Infra-failure isolation**: worker/auditor infrastructure failures (timeouts,
  unparseable verdicts) re-run only the failed role, bounded
  (`GLUERUN_WORKER_INFRA_MAX=1`, `GLUERUN_AUDIT_INFRA_MAX=2`) and *without*
  consuming the review/retry budget; on exhaustion they surface as `worker-infra`
  / `audit-infra`.
- **Decider fast-path** (`GLUERUN_DECIDER_FAST=1`): a deterministic host policy
  table resolves unambiguous `(failure-class, retries-left)` pairs; ambiguous
  cases still consult the model decider.
- **Host task preflight**: malformed tasks are blocked before any lease, worktree,
  or model run.
- New events: `audit.infra_retry`, `worker.infra_retry`, `decider.fast_path`,
  `l1.preflight_failed`.

### Versioning

- Root `SCHEMA_VERSION` file as the data-contract version (`v1` for this
  release); `.gluerun-version` is the canonical engine pin.
- `gluerun doctor` gains schema-mismatch (FAIL) and pin-disagreement (warn) checks;
  `gluerun migrate` + the `migrations/<from>-to-<to>.sh` contract bring a repo's
  `schemaVersion` forward (see `migrations/README.md`).
- Ships the `v0-to-v1` migration that backfills the current scaffold and rewrites
  legacy `pmgo.orchestration.*` namespace references.

### Console

- `schemaVersion`-keyed `plugin/adapters/console-adapter.v0.json` with per-key
  precedence: repo override > engine-shipped > built-in. Built-ins remain the
  no-adapter fallback.

### Back-compat

- With no adapter resolvable, every console endpoint behaves byte-identically to
  the pre-adapter console; a malformed adapter is ignored with a warning.
- All new behavior is gated behind env knobs at their historical-equivalent or
  opt-in defaults; `findingsStatus` is additive (never required) on the audit
  verdict.

schemaVersion: v1

---

## [0.1.0] — unreleased

Initial extraction of the bootstrap orchestration engine into a standalone,
installable package.

- Carved `engine/` (shell scripts) + `schemas/` (8 JSON contracts) out of the
  source repo, preserving exec bits.
- Schemas now ship **with** the engine and resolve relative to the install, not the
  consumer repo.
- Config contract (`gluerun.config.json` + `config.local.sh`) introduced so every
  per-repo knob lives in the consumer repo, never in engine files.
- `dag.sh` validator parameterized: layer/kind vocabulary and required nodes come
  from the DAG manifest; the storage-proof regime moved behind a module hook.
- Test suite abstraction-cleaned: live-state assertions removed; fixtures use a
  generic layer vocabulary.
- `gluerun` CLI + `install.sh` for install-once / run-anywhere with per-repo
  version pins.
- Visualization plugin vendored under `plugin/` and decoupled from project
  specifics.

schemaVersion: v0
