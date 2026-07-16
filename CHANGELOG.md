# Changelog

All notable changes to **glueRun-go** are recorded here. This project follows
semantic versioning. The `schemaVersion` (the `.vN` contract of the JSON schemas +
config shape) is called out separately from the package version, because consumers
and the plugin negotiate on `schemaVersion`.

---

## [0.5.0] — 2026-07-17 — Field-hardening from the first external consumer run

Every change in this release traces to the singular-frontend V1 field run
(Jul 13–16, codex session 019f5ce7): a 4-day, 78-dispatch, 47-node run that
converged but lost ~40 of ~96 hours to engine defects and needed ~15 manual
state surgeries. `schemaVersion` stays **v1** — all schema changes are
additive (`authority` node field; new `gate-review.v0`), so `gluerun migrate`
is a no-op for 0.4.0 consumers.

### Autonomy & failure classification
- **Limit/quota windows require structured evidence**: only engine-written
  runner logs are scanned (never `.md`/model artifacts — repo prose like a
  "quota-banner" feature armed ≥13 false 30-minute backoffs in the field),
  markers are word-boundary contextual regexes, quota backoffs refuse to arm
  without a `logRef`, and import rejections are excluded from limit
  eligibility. **`GLUERUN_LIMIT_SLEEPTHROUGH`** (default 1) supersedes the
  deprecated `GLUERUN_DISABLE_LIMIT_SLEEPTHROUGH`.
- **Monotonic task ids**: durable counter seeded from every surface (tasks
  incl. `superseded/`, leases, dispatch records, worktrees, imported packets,
  `agent/*` branches). Archived ids can never be recycled (4 field
  collisions, 2 breaker halts); collisions reject the batch instead of
  overwriting, and `gluerun_lease_write` refuses to clobber
  accepted/integrated leases.
- **Duplicate guard v2**: status-aware (terminal tasks never block a
  successor — the blocked-task deadlock killed a whole night), keyed on the
  new `DAG node:` task header (legacy `S#/D#` token regex is fallback only),
  `Supersedes:` header bypasses the guard, and unknown-node matches require a
  full signature. Empty planner batches (`{"tasks": []}`) are a first-class
  no-op (`planner.no_tasks`), not invalid output.
- **Exit-code contract**: dispatch exit 2 = refusal (never breaker input),
  3 = decided-terminal, other = crash. Repeated refusals park the task
  (**`GLUERUN_REFUSAL_PARK_THRESHOLD`**=3) instead of starving the loop.
- **Whole-tree reap liveness**: descendants, process group, run-id command
  lines, and recent run-dir writes all count as alive
  (**`GLUERUN_STALE_HARD_MINUTES`**=240 caps the conservatism). The 0.4.0
  root-pid check destroyed accepted work under a live auditor.
- **Accepted-work auto-heal** (**`GLUERUN_AUTO_ACCEPT_EXISTING`**=1): a
  dispatch against an `accepted` lease re-accepts the stranded packet
  deterministically and enqueues it; a new `accept-pending` trap state means
  a post-acceptance crash never fails the lease.

### Runners & retries
- **`GLUERUN_CODEX_TIMEOUT_SEC`** (default 2400; 0 disables) bounds codex
  runs with a kill-tree, and opt-in **`GLUERUN_CODEX_IDLE_SEC`** kills runs
  whose JSONL output stops growing — field hangs ran 28–380 minutes
  unbounded. rc 124 classifies as timeout/infra everywhere already.
- **Empty-diff retries reconcile**: a retry whose content was committed by a
  prior attempt (gate green, owned files differ from base) proceeds instead
  of parking fully green work as `no-changes`.
- **Audit-verdict validation** joins decider-verdict validation
  (**`GLUERUN_AUDIT_VERDICT_VALIDATE`**=warn; `strict` re-runs the auditor).
  Legacy `pmgo.*` schema ids are tolerated-with-warning
  (**`GLUERUN_LEGACY_SCHEMA_MODE`**=warn; `reject` post-migration) — the
  0.4.0 hard rejection parked every decision in consumers scaffolded with
  legacy prompts (18.5h halt).

### Promotion & governance
- **Auto-promotion actually fires**: **`GLUERUN_AUTO_PROMOTE_GATES`** now
  defaults to 1; gates promote at integrate time (`promote-gate --if-ready`)
  the moment a node's last task lands, and the empty-queue reconcile pass no
  longer requires a free dispatch slot. Promotions count as loop progress.
- **`gluerun promote-gate` honors the config `promoter` key** (new
  `engine/promote-gate.sh` wrapper sources lib.sh; explicit env still wins);
  actionable errors; stderr progress heartbeat
  (**`GLUERUN_PROMOTE_PROGRESS_SECS`**=15).
- **Terminal-predecessor tolerance** (**`GLUERUN_PROMOTE_TOLERATE_TERMINAL`**=1):
  superseded/blocked predecessors with an integrated successor count as
  satisfied; `tasks/superseded/` is scanned.
- **Planner suppression** (**`GLUERUN_SUPPRESS_UNPROMOTED_REPLAN`**=1): nodes
  whose tasks are complete but whose gate is unpublished are not re-planned
  (the field's duplicate-churn source); a published failed gate keeps the
  node plannable.
- **Evaluation-gate governance**: DAG nodes may declare
  `authority: operator | agent-review-allowed` (additive). `kind: evaluation`
  nodes promote via `promote-gate --operator --evidence REF`, or — when
  opted in — via a valid PASSING **`gate-review.v0`** file at
  `gates/evidence/<node>.review.json` (independent reviewer identity,
  evidence refs, headSha ancestor check,
  **`GLUERUN_REVIEW_MAX_AGE_HOURS`**=168). The dag schema file drops 0.4.0's
  project-specific layer/kind enums to match the engine validator.

### Recovery becomes verbs
- New CLI: **`supersede`** (all four resurrection surfaces atomically, live-
  dispatch guard, `--force`), **`clear-backoff`**, **`breaker show|reset`**,
  **`stop [--wait]`**, **`resume`**, **`wake`**, **`gates [--json]`**,
  **`health [--json]`** (sub-2s digest with a stable hash field for cheap
  heartbeats + `attention[]`), **`gc [--dry-run]`**
  (**`GLUERUN_RUNS_KEEP`**=200 runs-history cap with reference protection,
  integrated-worktree pruning, events rotation at
  **`GLUERUN_EVENTS_MAX_MB`**=64), plus `lease` and `accept-packet` wiring.
- `next-areas --explain` emits per-node exclusion reasons; a corrupt gate
  file no longer crashes the frontier computation.
- `recover` reclassifies stale **L1 planning leases**
  (**`GLUERUN_RECOVER_L1`**=1; report-only before), reports orphaned
  worktrees **once** (`recover-orphans.json`), and can auto-prune clean
  integrated worktrees (**`GLUERUN_AUTO_PRUNE`**, default 0).
- Opt-in **`GLUERUN_INTEGRATE_REBASE`**: rebase-and-regate an audited branch
  once on merge conflict instead of terminally parking.
- Detached workers' process groups are killed on supersede `--force`
  (**`GLUERUN_KILL_ORPHAN_PGROUP`**=1) so gate webservers stop leaking.

### Lifecycle & loop
- **`gluerun auto --detach`**: supported daemonized launch (setsid
  double-fork, `.gluerun-state/autonomate.log`, post-launch liveness check).
- Interruptible naps: STOP takes effect mid-sleep within
  **`GLUERUN_SLEEP_POLL_SEC`**=10; `gluerun wake` / `clear-backoff` end naps
  early — killing sleep children (which killed the whole loop in the field)
  is never needed. Quota budget counts only actually-slept seconds.

### Console & observability
- `/api/state` no longer shells `make orch-*` probes or a blocking `du`: the
  snapshot is assembled natively from durable files, disk usage samples on
  its own 5-minute background cache, and a stale-but-marked snapshot
  (`stale`/`computing`/`snapshotAgeSeconds`) is served instantly while a
  refresh runs (`?fresh=1` still blocks). Snapshot keys `gateD0`/`gateD1`
  are replaced by `orchestration.gates {passed,total,byNode}`.
- `gluerun console --ensure | --status | --stop`; the URL/pid persist at
  `.gluerun-state/console.url`/`console.pid`; the banner moved to stderr
  (one-shot JSON is pipe-pure); default port **8765** with free-port
  fallback; `gluerun status` prints the live console URL.
- `origin-state.json` gains `gates{passed,total}`, `completedNodes`,
  per-status `taskCounts`, and writer provenance; STATUS.md states its
  staleness contract.

### Doctor & skill
- Doctor preflights: model-prefix sanity, `~/.codex/hooks.json` parse (FAIL),
  MCP server fan-out count, legacy `pmgo.*` id scan (FAIL + migrate pointer),
  stale pidfiles, disk floor, `.worktrees` size, console-port availability.
- Skill rewritten for cheap monitoring: a `gluerun health --json`
  digest-compare heartbeat loop, a full 0.5.0 knob table, six numbered
  recovery recipes, the operator-gate escalation contract, and a new
  `references/artifacts.md` (canonical field names per artifact + jq
  cookbook). Console trigger words (dashboard/viewer/visualization/UI) added
  to the skill and plugin manifest.

### Migrating from 0.4.0
- **No schema migration**: `schemaVersion` stays v1; `authority` and
  `gate-review.v0` are additive.
- **Behavior flips (opt out in config `env{}` if needed)**:
  `GLUERUN_AUTO_PROMOTE_GATES=1` (was 0), codex runs bounded at 2400s (set
  `GLUERUN_CODEX_TIMEOUT_SEC=0` to restore unbounded), exit-2 refusals no
  longer feed the breaker, planner suppression of pending-promotion nodes,
  stale L1 lease reclassification (`GLUERUN_RECOVER_L1=0` restores
  report-only), duplicate guard ignores terminal tasks, legacy `pmgo.*`
  verdict ids tolerated (`GLUERUN_LEGACY_SCHEMA_MODE=reject` restores strict).
- **Console**: default port is 8765; the launch banner moved to stderr —
  update any script that parsed it from stdout; `gateD0`/`gateD1` snapshot
  keys are gone.
- **New state files**: `.gluerun-state/task-id-counter`, `WAKE`,
  `console.url`/`console.pid`, `recover-orphans.json`,
  `dispatch/<task>.refusals`. Task-id sequences may show gaps (intentional).
- **Consumer templates**: add `DAG node: <node-id>` to `tasks/TEMPLATE.md`
  and planner prompts (scaffold only creates-if-missing; new consumers get
  it automatically).

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
