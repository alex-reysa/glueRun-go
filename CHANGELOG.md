# Changelog

All notable changes to **glueRun-go** are recorded here. This project follows
semantic versioning. The `schemaVersion` (the `.vN` contract of the JSON schemas +
config shape) is called out separately from the package version, because consumers
and the plugin negotiate on `schemaVersion`.

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
