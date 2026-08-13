# Reliability Sprint 01 — dogfood field report

- Status: active; deterministic bootstrap recovery completed, `rel-00-contract` integrated and promoted
- Engine under test: Singular 0.18.0 (self-hosted)
- Target release: 0.19.0
- Program: `rel-*` in `docs/orchestration/dag.v0.json`
- Driver branch: `agent/integration`
- Sprint launch commit: `99bf1df5f5aaf821beff317a2a2c99f298b2b62c`
- Provider: Codex via `codex-run.sh`
- Model: `gpt-5.6-sol` (`high` for L1/planner/auditor/critic/decider/readonly; `medium` for L2)
- Auto constraints: `maxConcurrent=3`, `SINGULAR_MAX_HOURS=20`, `SINGULAR_PUSH=0`, `BASH_COMPAT=52`
- Initialized: 2026-08-13T16:48:40Z
- Initial autonomous loop stopped: 2026-08-13T17:16:08Z (`STOP` retained during operator recovery)
- Bootstrap resumed: 2026-08-13T18:24:22Z; `rel-00-contract` promoted: 2026-08-13T20:27:09Z

## Operator boundaries

- No origin push, release promotion, version-default flip, or other release actuation is authorized.
- `rel-99-release` is operator-authority. This run stops and hands off when it is the only remaining frontier node.
- Human-decision parks are summarized for the operator and are never blindly unparked.
- Engine code is changed only by sprint workers in their own branches/worktrees, never by hand in the driver checkout.
- The unrelated video workstream is excluded from every sprint commit. Its committed source is preserved on
  `codex/singular-launch-v3`; ignored generated artifacts remain locally under `videos/`.

## Baseline

- `agent/integration` was fast-forwarded locally from `9b106e91` to local `main` at `2def444c` (15 commits,
  zero divergent commits), then the sprint was committed at `99bf1df5`.
- Singular CLI resolved engine 0.18.0 at `~/.singular/versions/0.18.0`.
- Codex CLI 0.145.0 was installed, authenticated through ChatGPT, and its local model inventory contained
  `gpt-5.6-sol`.
- The historical supervised suite run `.singular-state/test-runs/20260811T155846Z-b947/manifest.json`
  records 194/194 passing on engine 0.18.0 at `2def444c`.
- A pre-launch dry-run existed at `.singular-state/runs/ORIGIN-20260813T155136Z-44874/`; it ran from the
  video branch before the required target-branch checkout and dispatched no work. It is baseline evidence,
  not a sprint execution cycle.

## Cycle timeline

| UTC | Origin/run ID | Frontier / active work | Operator action | Evidence |
|---|---|---|---|---|
| 2026-08-13T15:51:36Z | `ORIGIN-20260813T155136Z-44874` | 18 ready, 0 leases, no worker | Pre-launch dry-run discovered during preflight | `.singular-state/runs/ORIGIN-20260813T155136Z-44874/reconcile-snapshot.md` |
| 2026-08-13T16:50:41Z | no run ID allocated | Pre-run initialization | Required post-commit dry-run was interrupted after about 210 seconds with no output or run/lock artifact | Operator timing observation; `engine/reconcile.sh:133` |
| 2026-08-13T17:07:03Z | `ORIGIN-20260813T170703Z-90233` | 18 ready, 0 leases, no worker | Required post-commit dry-run completed in 0.6s after local exclude and Bash compatibility mitigations; branch/head/provider boundary sane | `.singular-state/runs/ORIGIN-20260813T170703Z-90233/reconcile-snapshot.md` |
| 2026-08-13T17:08:15Z | `ORIGIN-20260813T170815Z-90711` | Frontier `rel-00`; 0 active -> `TASK-0108` dispatched | First actuated cycle; capacity 3/3; worker detached as PID/PGID 93704 | `.singular-state/runs/ORIGIN-20260813T170815Z-90711/`, worker `RUN-20260813T170836Z-93780` |
| 2026-08-13T17:10:19Z | `ORIGIN-20260813T171019Z-2540` | `TASK-0108` active; no other node frontier-ready | `singular auto` iteration 1; recovery correctly skipped the live process tree; capacity 2/3 available | `.singular-state/runs/ORIGIN-20260813T171019Z-2540/` |
| 2026-08-13T17:11:36Z | `RUN-20260813T170836Z-93780` | `TASK-0108` audit verification | The authored gate passed three disposable reruns, but all three strict normalizations failed; engine fell back to the worker's hash-bound gate evidence | `audit-verification-1-{0,1,2}.log`, `audit-gate-normalize-1-{0,1,2}.err` |
| 2026-08-13T17:14:02Z | `RUN-20260813T170836Z-93780` | `TASK-0108` auditor completed | Codex reviewer returned `accepted` with no findings after a successful worker and gate | `.singular-state/runs/RUN-20260813T170836Z-93780/audit.json` |
| 2026-08-13T17:14:03Z | `RUN-20260813T170836Z-93780` | `TASK-0108` terminal `escalate-infra`; 17 tasks still undispatched | Post-audit evidence refresh rejected cumulative auditor input usage at 283,064 against a hard 100,000 canary; task parked and no packet was integrated | `evidence-manifest-final-refresh.log`, `attempts/index.json`, `run-status.json` |
| 2026-08-13T17:15:58Z | `ORIGIN-20260813T171526Z-36914` | No live worker; 0/18 gates; `rel-00` blocked | Operator wrote `STOP`; auto exited cleanly at 17:16:08Z after nine iterations. No unpark attempted. | `.singular-state/STOP`, `.singular-state/STATUS.md`, `.singular-state/events.ndjson` |
| 2026-08-13T18:24:22Z | `RUN-20260813T182422Z-RECOVERY-TASK-0108-18915` | Deterministic recovery try 1 | Exact-head verification failed before acceptance because the disposable worktree lacked the packet-declared `.singular-evidence/` output parent; the original 76-file run was snapshotted and remained unchanged | Recovery run root and `.singular-state/recovery-snapshots/RUN-20260813T170836Z-93780/20260813T182422Z/` |
| 2026-08-13T18:25:50Z | `RUN-20260813T182550Z-RECOVERY-TASK-0108-12256` | `TASK-0108` deterministically accepted and imported | With a bounded prewarm creating the output parent, exact head `3fffc636`, clean merge tree `ed0e729b`, scope, secrets, and both current green commands passed in 98/267ms; no unpark or new model call | Recovery `evidence-manifest.json`, `audit.json`, `recovery-provenance.json`, imported packet and audit |
| 2026-08-13T18:26:15Z | `ORIGIN-20260813T182615Z-70987` | Integration attempt 1 | Full suite passed 194/194 in 1,435,948ms, but the gate rejected 37 metadata changes caused by the nominally read-only status path; decider chose `revalidate-evidence` | Integration `gate-report.json`, source snapshots, focused executable-resolution probe |
| 2026-08-13T18:58:30Z | focused operator probes | Attribution | `test-fresh-consumer.sh` changed no tracked source; `test-executable-resolution.sh` alone reproduced exactly `.gitignore` plus 36 schema-mirror lstat changes while terminal Git bytes were clean | `.singular-state/operator-probes/{fresh-consumer-20260813T185830Z-53948,executable-resolution-20260813T185936Z-57180}/` |
| 2026-08-13T19:08:53Z | `ORIGIN-20260813T190852Z-60011` | Integration attempt 2 | A one-shot gate override was overwritten by committed config, so the wrong full suite began; operator stopped it after four tests (32,226ms, exit 143), then the engine needlessly ran a Codex decider | Integration run/gate artifacts and `session-decider.json` |
| 2026-08-13T19:10:32Z | `ORIGIN-20260813T191032Z-64937` | Integration attempt 3 | The exact-tree adapter ran candidate `580787c3`/tree `90292d0d` terminal-clean; 193/194 passed, with one detached low-disk fixture race; decider chose `rerun-tests` | Integration run plus `.singular-state/operator-probes/low-disk-race-20260813T1936Z/` |
| 2026-08-13T19:19:29Z | operator overlay `singular-0.18.0-canary-codex-cache-v1-8de32121` | Live-run mitigation prepared | Immutable, one-path 0.18.0 overlay verified provider-correct Codex cached-input charging, malformed-data fallback, exact hard bound, multi-try summation, and legacy fixture compatibility | `.singular-state/operator-engine-overlay-records/singular-0.18.0-canary-codex-cache-v1-8de32121/` |
| 2026-08-13T19:36:54Z | low-disk focused probe | Flake isolated | Unchanged detached-mode fixture failed 3/10; synchronous control passed 3/3. The failed cleanup left only `dispatch/TASK-0001.exit` containing `137` | Probe `manifest.json`, `summary.md`, and `raw-results.log` |
| 2026-08-13T19:38:59Z | `ORIGIN-20260813T193859Z-52506` | Integration attempt 4 | One bounded exact-tree retry passed 194/194 in 1,518,821ms. Candidate `c650620e`/tree `4915b69a` was terminal-clean and matched merge commit `41380c1b` with parents `e0c15c9f` and `3fffc636` | Integration gate report and `operator-candidate.json` |
| 2026-08-13T20:04:59Z | `ORIGIN-20260813T200459Z-25969` | `rel-00-contract` promotion | Fresh disposable-tree proof passed 194/194 at head `41380c1b`, tree `4915b69a`; authoritative gate recorded at 20:27:09Z | `docs/orchestration/gates/rel-00-contract.gate-result.json`, gate evidence, operator proof directory |
| 2026-08-13T20:27:09Z | operator runtime activation | Subsequent lanes pinned to verified Codex overlay | `singular version` resolved the immutable overlay's absolute path; effective runner was overlay `codex-run.sh`, model `gpt-5.6-sol`, push `0`, and concurrency `3` | Overlay metadata plus activation preflight output |

## Finding ledger

Impact labels: **blocked** means progress stopped; **degraded** means correctness, evidence, cost, or operator
trust was reduced; **annoyed** means avoidable manual or cognitive cost without outcome risk.

### FR-001 — dry-run doubles the imported-packet count

- First seen: 2026-08-13T15:51:36Z; frequency: 1/1 observed dry-runs at report initialization.
- Classification: new; severity: low; impact: degraded observability / annoyed; non-blocking.
- Symptom: the dry-run snapshot and `reconcile.completed` event report 214 imported packets while
  `.singular-state/origin-state.json` reports 107. The filesystem contains 107 packet JSON files plus 107
  sibling audit JSON files.
- Expected: every operator surface reports the same count of imported task packets and does not count audit
  sidecars as additional packets.
- Code anchor (0.18.0): `engine/reconcile.sh:136` initializes the dry-run count from all `*.json`; the later
  non-audit recount at `engine/reconcile.sh:194` is not reached on dry-run. `engine/reconcile.sh:70` and
  `engine/lib.sh:7754` exclude `*.audit.json`.
- Evidence: `.singular-state/runs/ORIGIN-20260813T155136Z-44874/reconcile-snapshot.md`,
  `.singular-state/events.ndjson`, `.singular-state/origin-state.json`, and
  `docs/orchestration/packets/imported/`.
- Operator cost/action: manual reconciliation of the two counts; no intervention.
- Resolution: open for a future sprint.

### FR-002 — archived program gates contaminate current-program origin telemetry

- First seen: 2026-08-13T15:51:36Z; frequency: baseline origin snapshot.
- Classification: new; severity: medium; impact: degraded operator observability; non-blocking unless a
  consumer trusts the contaminated snapshot for decisions.
- Symptom: `.singular-state/origin-state.json` reports `22/18` gates and lists the 22 completed nodes from the
  archived context-continuity program before any `rel-*` node has completed.
- Expected: current-program telemetry intersects gate artifacts and completed nodes with the active DAG.
- Code anchor (0.18.0): `engine/lib.sh:7790-7800` and `engine/lib.sh:7834-7835`, plus
  `engine/reconcile.sh:581-606`, scan all gate-result files. `singular gates` appears separately DAG-filtered.
- Evidence: `.singular-state/origin-state.json`, `docs/orchestration/gates/`,
  `docs/orchestration/dag.v0.json`.
- Operator cost/action: treat origin gate totals/completed-node lists as untrusted and cross-check with
  `singular gates`; no scheduling intervention.
- Resolution: open for a future sprint.

### FR-003 — reconcile snapshot recommends obsolete Phase 2/3 actions

- First seen: 2026-08-13T15:51:36Z; frequency: 1/1 inspected dry-run snapshots.
- Classification: new; severity: low; impact: annoyed / degraded guidance; non-blocking.
- Symptom: the snapshot advises keeping L1/L2 launch disabled during Phase 2/3 scaffolding and continuing
  toward a manual artifact-area proof loop, although 0.18.0 exposes the actuated reconcile and auto workflow.
- Expected: next actions describe the installed engine's supported operator flow and current run state.
- Code anchor (0.18.0): hardcoded snapshot actions in `engine/reconcile.sh:545-550`.
- Evidence: `.singular-state/runs/ORIGIN-20260813T155136Z-44874/reconcile-snapshot.md`.
- Operator cost/action: ignore the stale actions and follow the audited sprint launch sequence.
- Resolution: open for a future sprint.

### FR-004 — untracked ignored-workstream files make reconcile's status scan effectively hang

- First seen: 2026-08-13T16:50:41Z; frequency: 1/1 post-checkout dry-run attempts.
- Classification: new; severity: medium; impact: blocked launch pending mitigation / degraded operator UX.
- Symptom: after the required checkout removed the video branch's private ignore rules, the generated
  `videos/` tree surfaced as untracked. `singular reconcile` produced no output and created no run directory
  or origin lock in about 210 seconds; it was interrupted cleanly before actuation.
- Expected: reconciliation should either bound/stream the pre-run worktree scan, respect repository-local
  exclude mechanisms for unrelated workstreams, or surface what it is waiting on.
- Code anchor (0.18.0): `engine/reconcile.sh:133` calls unrestricted `git status --short` before the first
  reconcile event/output. The current tree contains roughly 28,713 ignored/generated video paths when the
  video-only `.gitignore` rules are present, and about 3.2 GiB under `videos/`.
- Evidence: operator timing observation, absence of a new `.singular-state/runs/ORIGIN-*` directory, and
  `git status --short --branch` showing `?? videos/`.
- Operator cost/action: about 3.5 minutes plus manual interruption; launch paused. Preserve the workstream and
  use a local-only Git exclude rather than committing its ignore rules into the sprint.
- Resolution: mitigated with a repository-local `core.excludesFile` pointing to the gitignored
  `.singular-state/operator-git-excludes`; the video tree itself was not changed. The next dry-run completed
  in 0.6 seconds. Engine behavior remains open for a future sprint.

### FR-005 — resource guard finds zero worker capacity only after launch preparation

- First seen: 2026-08-13T16:49:51Z; frequency: current host preflight.
- Classification: environment-triggered engine friction; severity: high for this run; impact: blocked.
- Symptom: `singular doctor --json` reports `effectiveSlots: 0` because only about 340 MiB is free while the
  configured reserve is 2 GiB and each worker is estimated at 256 MiB.
- Expected: the operator should receive a clear capacity warning before a long launch sequence; actuation
  must remain fail-closed at zero slots.
- Code anchor (0.18.0): resource planning and degraded-low-disk event path in
  `engine/reconcile.sh:291-343`; configuration in `singular.config.json` `resources`.
- Evidence: Doctor report emitted at 2026-08-13T16:49:51Z; `df` showed roughly 335 MiB available.
- Operator cost/action: launch paused for safe non-video cache reclamation. The 3.2 GiB unrelated video tree
  and repository history remain untouched.
- Resolution: operator removed only four verified redownloadable caches outside the repo (Sparkle update
  staging, npm cache, npx cache, Whisper models). No video, Git, Codex-session, or engine-state data was
  removed. Free space rose to 6.4 GiB and real-environment Doctor passed the resource check for three slots.

### FR-006 — Doctor reports all non-release sprint nodes as unpromotable

- First seen: 2026-08-13T16:49:51Z; frequency: current DAG/config preflight.
- Classification: launch/configuration near-miss; severity: high until resolved; impact: potentially blocked.
- Symptom: `graph.promotability` warns that 17 `rel-*` nodes are absent from the installed default promoter;
  `rel-99-release` correctly defaults to operator authority.
- Expected: the audited execution configuration should define a promotion path for every agent-governed node
  while retaining the operator-only release boundary.
- Code anchor: installed `singular-ext/promote-gate.sh`, promotion dispatch in engine 0.18.0, and the missing
  `promoter` setting in `singular.config.json`.
- Evidence: Doctor report emitted at 2026-08-13T16:49:51Z (`unregisteredNodes` lists rel-00 through rel-16).
- Operator cost/action: actuation paused while the exact promoter contract is diagnosed; no blind override.
- Resolution: mitigated with the gitignored `.singular-state/reliability-promoter.sh`, an exact copy of the
  installed 0.18.0 promoter plus a 17-node allowlist mapping each `rel-00..16` node to its single task and DAG
  prerequisites. It runs the full configured regression and writes the installed strict, hash-bound v1 gate
  artifacts. `--registers` passes for all 17 nodes and fails for `rel-99-release` as required.

### FR-007 — Doctor's disposable-worktree probe is not sandbox-aware

- First seen: 2026-08-13T16:49:51Z; frequency: 1/1 in-app Doctor runs.
- Classification: environment interaction; severity: medium; impact: degraded preflight / potentially blocked.
- Symptom: Doctor reports `git.disposable-worktree` failed while preparing a detached worktree. The same app
  sandbox initially prevented direct writes to `.git` until an approved unsandboxed Git operation was used.
- Expected: distinguish a repository defect from host-policy denial and report actionable evidence; the actual
  engine process should be verified in the execution context it will use.
- Code anchor: installed `engine/doctor.py` disposable-worktree probe and Git metadata permissions.
- Evidence: Doctor report and the earlier `Operation not permitted` errors for `.git/index.lock` and branch
  lock creation inside the app sandbox.
- Operator cost/action: an unsandboxed, read-only/temporary worktree probe is required before actuation.
- Resolution: the real-environment Doctor worktree and process probes passed. This was an app-sandbox false
  failure, not a repository failure; engine launch uses the approved execution context.

### FR-008 — Bash 5.3 here-document pipe behavior deadlocks engine library loading

- First seen: 2026-08-13T16:50:41Z; frequency: every unmitigated shell-based Singular command in this host
  environment (`reconcile`, `status`, `health`, `gates`, and direct promoter queries).
- Classification: new; severity: critical for operability; impact: blocked.
- Symptom: shell-based commands remain silent indefinitely before allocating an origin run or lock. Process
  sampling shows Homebrew Bash 5.3.9 blocked in `heredoc_write(2)` while sourcing `engine/lib.sh`; nested shell
  children wait on the same pipe. Direct Python and Git operations are healthy.
- Expected: a supported Bash >=4 loads the engine library and every CLI command reaches bounded output.
- Code anchor (0.18.0): large embedded Python here-documents in `engine/lib.sh`, first notably
  `engine/lib.sh:2080-2411` (12,704 bytes), `:2607-2971` (13,241 bytes), and `:3425-3748` (11,668 bytes).
  Bash 5.1+ uses pipes for here-documents below its pipe-size threshold; this host deadlocks during that write
  unless an explicit compatibility level is selected.
- Evidence: one-second process sample at `/tmp/singular-sample-88424.txt`, process tree captured during the
  hang, and direct A/B: unset `BASH_COMPAT` hung; `BASH_COMPAT=50`, `51`, `52`, or `53` loaded immediately.
  A later audit found orphaned PIDs 84657/84662/84663, launched at 16:53:57Z and still present more than two
  hours later: their root had been reparented to `launchd`, one shell waited in command-substitution input,
  and the leaf was blocked in `heredoc_write`.
- Operator cost/action: multiple silent diagnostics and one required dry-run lost about 10 minutes, followed
  by a separate process-tree audit and termination of the orphan group. Samples are retained at
  `/private/tmp/bash_2026-08-13_205914_nHlW.sample.txt` and
  `/private/tmp/bash_2026-08-13_205915_tZ47.sample.txt`. The live run exports `BASH_COMPAT=52` before the CLI
  so all child shells inherit Bash 5.2 compatibility behavior. No tracked engine file was patched.
- Resolution: run-level mitigation active; high-priority future engine/installer compatibility defect.

### FR-009 — Doctor ignores the local-config promoter when assessing graph promotability

- First seen: 2026-08-13T17:04:00Z; frequency: 1/1 Doctor calls relying only on local config.
- Classification: new; severity: medium; impact: degraded/false warning; non-blocking with explicit env.
- Symptom: runtime local config selected the Reliability Sprint promoter, but Doctor still reported the
  installed default promoter and all 17 nodes unregistered. Exporting the exact same `SINGULAR_PROMOTER`
  before invoking Doctor made its promoter check pass.
- Expected: Doctor assesses the same increasing-precedence configuration as the shell runtime, including
  `.singular-state/config.local.sh`.
- Code anchor (0.18.0): `engine/doctor.py:_resolve_promoter` reads `os.environ` or JSON `self.config`, while
  `_promoter_registers` separately passes `self.runtime_env`; the resolver never consults that merged runtime
  environment.
- Evidence: paired Doctor reports before and after the explicit process export; runtime local config at
  `.singular-state/config.local.sh`.
- Operator cost/action: extra diagnosis and an explicit promoter export added to every launch/supervision
  command. Final real-environment Doctor: 38 passed, 0 failed, one unrelated model-cache warning.
- Resolution: run-level mitigation active; open for a future sprint.

### FR-010 — every cycle rescans and prints all 107 already-integrated historical packets

- First seen: 2026-08-13T17:08:15Z; frequency: 10 full-history scans through bootstrap recovery.
- Classification: new; severity: medium; impact: degraded latency and operator signal; non-blocking.
- Symptom: pre-dispatch integration emits 107 `integration.skipped` events and 107 console lines for
  TASK-0001..TASK-0107 on every cycle, even though every packet branch head is already an ancestor of
  `agent/integration`. In the first actuated cycle this phase took about 17 seconds before capacity/frontier
  calculation; it dominated an otherwise sub-second reconcile path.
- Expected: terminal already-merged packets are indexed/cached or compactly summarized so unchanged history
  is not re-proven and reprinted each polling cycle.
- Code anchor (0.18.0): pre-dispatch auto-integration in `engine/reconcile.sh` and packet enumeration/ancestor
  checks in `engine/integrate.sh`.
- Evidence: exactly 107 `integration.skipped` events for each of the nine 17:08–17:15 reconcile cycles and
  again for `ORIGIN-20260813T182615Z-70987`: 1,070 redundant events/lines in total. Explicit `--task`
  integration retries correctly skipped the historical scan.
- Operator cost/action: roughly 17 seconds and 107 lines/events per general cycle at current history size;
  no state deletion was attempted because the packets are tracked provenance.
- Resolution: open for a future sprint.

### FR-011 — running-worker telemetry is phase-skewed at both launch and terminal handoff

- First seen: 2026-08-13T17:08:35Z; frequency: both launch and first terminal handoff.
- Classification: new; severity: low; impact: degraded observability / near-miss; non-blocking.
- Symptom: the first actuated cycle successfully launched PID 93704 and reported `dispatched_this_run=1`, but
  its final summary/event recorded `workers_running=0`. At the other edge, the 17:14:23 cycle still reported
  one running worker about 20 seconds after TASK-0108 terminalized, while simultaneously reporting all three
  slots available; reap finally changed the count to zero at 17:14:44.
- Expected: end-of-cycle running-worker telemetry either includes newly detached dispatches or labels the
  field as pre-dispatch/reaped-worker count so an operator does not infer that the launch vanished.
- Code anchor (0.18.0): `workers_running` is populated by the pre-dispatch reap in `engine/reconcile.sh`, then
  emitted unchanged after detached dispatch.
- Evidence: completion events for `ORIGIN-20260813T170815Z-90711` and
  `ORIGIN-20260813T171401Z-29802`, the 17:14:44 `origin.dispatch_reaped` event, and TASK-0108 lifecycle events.
- Operator cost/action: one manual PID and health check before starting auto.
- Resolution: open for a future sprint.

### FR-012 — host audit reruns a passing gate three times because strict observations are absent

- First seen: 2026-08-13T17:11:36Z; frequency: 3/3 disposable verification tries for TASK-0108.
- Classification: new; severity: high for expensive gates; impact: degraded cost and audit evidence; did not
  itself block this task.
- Symptom: the authored task gate passed on all three host reruns, but every normalization failed with
  `gate-report: strict gate observation missing`. The engine classified this structural report mismatch as
  retryable verification infrastructure, reran the same passing command twice more, then used an
  evidence-only fallback.
- Expected: an ordinary authored gate command is adapted into the strict observation contract once, or its
  first successful hash-bound result is reused. Missing structural metadata must not trigger three complete
  deterministic gate executions.
- Code anchor (0.18.0): retry/fallback loop at `engine/l1-drive.sh:1237-1310`; strict normalization check at
  `engine/audit-verify.sh:378-387`.
- Evidence: `.singular-state/runs/RUN-20260813T170836Z-93780/audit-verification-1-{0,1,2}.log`, matching
  `audit-gate-normalize-1-{0,1,2}.err`, and two `audit.verification_infra_retry` events.
- Operator cost/action: about six seconds for this small documentation gate; the same behavior could run an
  expensive full suite three times and weaken the reviewer's input to evidence-only verification.
- Resolution: open for a future sprint.

### FR-013 — the prescribed bounded evidence reader is unusable in the Codex auditor sandbox

- First seen: 2026-08-13T17:12:38Z; frequency: 1/1 bounded retrieval attempts in the first audit.
- Classification: new environment/engine interaction; severity: medium; impact: degraded audit access and
  annoyed; non-blocking only because the auditor worked around it with direct reads.
- Symptom: `evidence-show.sh` failed while reading `packet.json` with `PermissionError: [Errno 1] Operation
  not permitted` on `/tmp/singular-evidence-retrieval-v0/<sha>.lock`. Repeated Git calls also emitted macOS
  `confstr`/xcrun cache-write warnings for `/tmp/xcrun_db-*` although Git itself succeeded.
- Expected: the evidence helper advertised to a sandboxed reviewer uses a writable per-run lock/cache path,
  and routine read-only Git evidence commands do not flood the reviewer transcript with host cache errors.
- Code anchor (0.18.0): installed `engine/evidence-show.sh` temporary retrieval lock; auditor prompt/tool
  contract assembled by `engine/l1-drive.sh`.
- Evidence: `.singular-state/runs/RUN-20260813T170836Z-93780/auditor-codex.log`.
- Operator cost/action: audit had to fall back to raw/direct inspection, expanding context and weakening the
  intended bounded-evidence boundary.
- Resolution: open for a future sprint.

### FR-014 — Codex model-cache schema mismatch produces repeated non-fatal provider errors

- First seen: pre-launch Doctor; frequency: 19 cache load/renew errors across the first worker/auditor run.
- Classification: new compatibility near-miss; severity: low; impact: degraded provider signal / annoyed;
  non-blocking in this run.
- Symptom: Codex CLI 0.145.0 reads a cache written for 0.147 and repeatedly reports a missing
  `base_instructions` field. Doctor warns about the newer cache; both model calls nevertheless completed.
- Expected: an older client ignores or safely refreshes an incompatible cache once, and Doctor distinguishes
  a noisy recoverable mismatch from an execution risk.
- Code anchor: Codex client model-cache loader; no Singular source anchor identified.
- Evidence: real-environment Doctor warning plus implementer and auditor logs under
  `.singular-state/runs/RUN-20260813T170836Z-93780/`.
- Operator cost/action: inspected authentication/model availability and confirmed the provider results rather
  than mutating user-level Codex state during a live run.
- Resolution: tolerated; open compatibility friction.

### FR-015 — accepted audit is terminalized as infrastructure failure by hard token-canary accounting

- First seen: 2026-08-13T17:14:03Z; frequency: 1/1 completed audits; classification: new reproduction of the
  terminal handoff/budget failure family targeted by this sprint.
- Severity: critical; impact: blocked the entire DAG at `rel-00-contract`.
- Symptom: TASK-0108's worker committed the correct owned file, its gate passed, and the Codex auditor returned
  `accepted` with zero findings. The subsequent evidence-manifest refresh exited 4 because reviewer usage was
  `283064 >= 100000`; `l1-drive.sh` changed the successful audit into `audit-infra`, and policy parked the task
  as `escalate-infra`. No packet, integration, or gate promotion followed.
- Expected: durable accounting cannot reverse an accepted verdict into a terminal infrastructure park.
  Budget enforcement must use the intended quantity and provide a supported recovery/remedy path.
- Code anchor (0.18.0): hard defaults/max and bounded config in `engine/evidence-manifest.sh:55-87`; cumulative
  runner-result summation and exit at `:431-459`; post-verdict reclassification at
  `engine/l1-drive.sh:1674-1687`. The schema also caps `auditInputTokenCanary` at 100,000.
- Budget evidence: auditor input 283,064, cached input 244,736, output 5,713; fresh input delta was only 38,328.
  Implementer input 438,115, cached 390,912, output 8,119. Total provider usage was 721,179 input, 635,648
  cached, and 13,832 output; total fresh-input delta 85,531. The successful audit took about 2m15s.
- Evidence: `.singular-state/runs/RUN-20260813T170836Z-93780/audit.json`, `attempts/index.json`,
  `run-status.json`, `evidence-manifest-final-refresh.log`, and the two role runner-result JSON files.
- Operator cost/action: diagnosed before any unpark and stopped auto. A provenance-bound recovery copied the
  original run byte-for-byte, reran its successful commands at exact head `3fffc636`, and accepted/imported
  `RUN-20260813T182550Z-RECOVERY-TASK-0108-12256` without a new model call. Imported packet/audit hashes are
  `9d6a4470...` and `62c15ef4...`.
- Resolution: operationally recovered, product defect open. The permanent provider-correct rule is bound to
  TASK-0113. A verified-but-not-activated immutable overlay proves that Codex charges fresh input only when
  counters are coherent (38,328 here), preserves raw provider usage, falls back safely for malformed data,
  charges non-Codex input raw, sums multiple tries, and still fails at the exact 100,000 bound. Evidence:
  `.singular-state/operator-engine-overlay-records/singular-0.18.0-canary-codex-cache-v1-8de32121/`.

### FR-016 — failed final refresh leaves a stale, apparently valid evidence manifest

- First seen: 2026-08-13T17:14:03Z; frequency: 1/1 final-refresh failures.
- Classification: new; severity: high; impact: degraded/misleading evidence; blocking recovery.
- Symptom: `evidence-manifest.json` remains the pre-audit snapshot with `actualAuditInputTokens: 0`, only
  implementer usage, no audit/auditor artifacts, and the hash of the earlier 5,011-byte packet. The current
  post-audit packet is 5,343 bytes with a different hash. The manifest carries no internal invalidation marker.
- Expected: a failed final refresh either atomically invalidates/removes the pre-audit manifest or leaves an
  explicit status that no consumer can mistake for final evidence.
- Code anchor (0.18.0): pre-audit/final-refresh lifecycle in `engine/l1-drive.sh:1677-1687` and manifest write
  sequence in `engine/evidence-manifest.sh`.
- Evidence: current `packet.json`, `evidence-manifest.json`, `audit.json`, and
  `evidence-manifest-final-refresh.log` in `RUN-20260813T170836Z-93780`.
- Operator cost/action: consumers must cross-check terminal state and refresh log rather than trusting the
  manifest alone. Before recovery, all 76 source-run files were preserved in
  `.singular-state/recovery-snapshots/RUN-20260813T170836Z-93780/20260813T182550Z/`. Key original hashes are
  packet `d356c461...`, audit `5d0a7338...`, stale manifest `711f2a0e...`, and refresh failure `aeda0b38...`;
  recovery provenance/manifest hashes are `87a363bb...` and `f63733c1...`.
- Resolution: unresolved.

### FR-017 — attempt archive omits the artifacts needed to diagnose an audit-infra terminal

- First seen: 2026-08-13T17:14:03Z; frequency: 1/1 archived attempts.
- Classification: new/broader evidence-retention defect adjacent to the known per-try log-loss issue;
  severity: high; impact: degraded evidence and unsafe retry/GC exposure.
- Symptom: `attempts/1/` copied the worker log but omitted `auditor-codex.log`, both role runner-result JSON
  files, both raw provider envelopes, verification artifacts, and the final-refresh failure. They survive only
  at the run root.
- Expected: the attempt archive is self-contained for every artifact that determined the terminal outcome,
  especially the accepted verdict and the accounting failure that later overrode it.
- Code anchor (0.18.0): attempt archive selection in `engine/l1-drive.sh`; exact copy list to be fixed by the
  sprint's evidence-retention work.
- Evidence: the attempt archive has only 11 root files and omits runner results/envelopes, auditor log,
  normalization/verification artifacts, and final-refresh evidence. Important run-root hashes were captured;
  the auditor log is SHA-256 `e1d3df43...` and the final refresh log `aeda0b38...`.
- Operator cost/action: STOP was retained and the complete 76-file run root was snapshotted before recovery.
- Resolution: unresolved.

### FR-018 — park guidance says the gate could not run although it passed four times

- First seen: 2026-08-13T17:14:03Z; frequency: 1/1 terminal parks.
- Classification: new observation of overloaded `audit-infra`; severity: high; impact: degraded/unsafe
  operator guidance.
- Symptom: `docs/orchestration/decisions.md` tells the operator that the workspace could not run the gate and
  to repair the environment then unpark. The gate passed once for the worker and three times for the host;
  the actual failure was post-audit token accounting. Following the advice would discard/recreate work and
  probabilistically repeat the same failure.
- Expected: park rationale reports the precise failing phase/artifact and recommends only recovery actions
  that can address that failure class.
- Code anchor (0.18.0): final-refresh mapping at `engine/l1-drive.sh:1681-1687` and audit-infra fast-path
  decision/bootstrap text.
- Evidence: `docs/orchestration/decisions.md:5-17`, gate logs, accepted `audit.json`, and final-refresh log.
- Operator cost/action: manual forensic correction; no unpark.
- Resolution: unresolved; rel-03/rel-06 are intended to improve this family but could not run.

### FR-019 — health omits the blocking task failure and reports it as generic info

- First seen: 2026-08-13T17:19:01Z; frequency: 1/1 final health snapshots.
- Classification: new; severity: high for supervision; impact: degraded operator observability.
- Symptom: health reports 500 diagnostics across 17 groups, all classified `info`, with zero orchestration,
  provider, product, or infrastructure failures. Its attention list contains only the intentional STOP and
  dead auto process, even though TASK-0108 is blocked `escalate-infra`, 0/18 gates have passed, and the run's
  accepted audit was overridden. It also reports a frontier count of one without explaining that its only task
  is blocked. The read-only health command took about 53 seconds to complete on this small active program.
- Expected: the required health surface names terminal blocked tasks, precise failure classes, and the reason
  the frontier cannot dispatch; routine checks complete quickly enough for periodic supervision.
- Code anchor (0.18.0): `engine/ops.sh:ops_health` and event grouping/classification in
  `engine/health_details.py`.
- Evidence: final `singular health --json` generated 2026-08-13T17:19:01Z, `run-status.json`, task/lease state,
  and gate output.
- Operator cost/action: cross-checked status, gates, run-status, attempts index, decisions, and raw events by
  hand. Health alone was not sufficient to diagnose or even identify the park.
- Resolution: unresolved.

### FR-020 — one-shot provider and gate overrides are silently overwritten by authored config

- First seen: pre-launch configuration verification; frequency: current sprint config.
- Classification: launch configuration near-miss; severity: high for provenance; impact: potentially degraded
  provider compliance; mitigated before actuation.
- Symptom: `singular.config.json` still specifies `runner: claude-run.sh`; its Codex model/effort variables are
  inert under that runner. A one-shot `SINGULAR_RUNNER` prefix is overwritten when JSON is loaded. The same
  precedence trap affected a one-shot `SINGULAR_DEFAULT_GATE_CMD`: integration
  `ORIGIN-20260813T190852Z-60011` started committed `bash tests/run.sh` instead of the intended bounded
  exact-tree adapter.
- Expected: the committed execution config names the provider intended for the sprint, or the CLI clearly
  reports the final effective provider before dispatch.
- Code anchor (0.18.0): increasing-precedence config load in `engine/lib.sh` (JSON, shell config, then local
  config) and runner dispatch.
- Evidence: committed `singular.config.json`, `.singular-state/config.local.sh`, both role session/result
  records, and the 32,226ms aborted integration gate, which reached four passing tests before exit 143.
- Operator cost/action: created gitignored local configs selecting `codex-run.sh`, `gpt-5.6-sol`,
  `SINGULAR_PUSH=0`, and the intended gate. No Claude session was launched. The misconfigured retry also
  triggered a needless Codex decider call (18,106 input / 11,008 cached / 165 output tokens).
- Resolution: run-level mitigation succeeded; durable config clarity remains open.

### FR-021 — deterministic acceptance does not create packet-declared output parents

- First seen: 2026-08-13T18:24:22Z; frequency: 1/2 deterministic recovery runs.
- Classification: new; severity: medium; impact: blocked the first recovery try.
- Symptom: exact-head verification failed in 25ms because the packet's green command redirects to
  `.singular-evidence/green.log`, but the pristine disposable worktree did not contain that ignored directory.
- Expected: the shared preparer or command adapter creates declared output parents, or captures redirected
  evidence without requiring a worker-private ignored directory to pre-exist.
- Code anchor (0.18.0): disposable setup and rerun loop in `engine/accept-existing-packet.sh:195-245` and
  `:431-466`; the shared preparer notes this parity requirement in `engine/lib.sh:7644-7651`.
- Evidence: `RUN-20260813T182422Z-RECOVERY-TASK-0108-18915/accept-existing-packet-command-1.log` and
  `accept-existing-packet-command-results.jsonl`.
- Operator cost/action: one failed recovery run and forensic check. A bounded, gitignored prewarm creating
  only `.singular-evidence/` enabled the successful second run; no product source was changed.
- Resolution: run-level mitigation; permanent preparer/output-parent behavior remains open.

### FR-022 — deterministic acceptance preserves a stale lease run identity

- First seen: 2026-08-13T18:25:52Z; frequency: 1/1 accepted recovery packets.
- Classification: new; severity: medium; impact: degraded provenance; non-blocking.
- Symptom: the lease became `accepted` at the recovery time but still names source run
  `RUN-20260813T170836Z-93780`, not accepted recovery run
  `RUN-20260813T182550Z-RECOVERY-TASK-0108-12256`.
- Expected: terminal lease provenance identifies the run that made the terminal decision, while retaining the
  source run as a separate lineage field if needed.
- Code anchor (0.18.0): `engine/accept-existing-packet.sh:797` calls
  `singular_lease_set_status`; `engine/lib.sh:4358-4379` updates only `status` and `updatedAt`.
- Evidence: `.singular-state/leases/TASK-0108.json`, recovery packet, and acceptance event.
- Operator cost/action: manual correlation across lease, packet, decision, and recovery provenance.
- Resolution: open.

### FR-023 — redirected successful recovery output is absent from the durable host log

- First seen: 2026-08-13T18:25:52Z; frequency: 1/2 successful acceptance reruns.
- Classification: new; severity: medium; impact: degraded evidence; non-blocking because the command exit and
  original packet evidence were independently bound.
- Symptom: the required-content command passed in 98ms, but its durable
  `accept-existing-packet-command-1.log` is empty (`e3b0c442...`). The actual text was redirected to the
  disposable worktree's `.singular-evidence/green.log` and disappeared when that worktree was removed.
- Expected: a successful rerun durably captures its actual output or copies the declared output artifact
  before disposing of the verification worktree.
- Code anchor (0.18.0): the rerun wrapper captures only process stdout/stderr in
  `engine/accept-existing-packet.sh:442-466`; shell-internal redirection bypasses it.
- Evidence: recovery `evidence-manifest.json`, empty command-1 log, and the 74-byte command-2 log.
- Operator cost/action: manual comparison with the original green artifact and command-result record.
- Resolution: open.

### FR-024 — long integration and promotion jobs publish no progress heartbeat

- First seen: 2026-08-13T18:26:31Z; frequency: every long integration/promotion proof observed.
- Classification: new; severity: high for supervision; impact: degraded observability.
- Symptom: integration writes active run status once, then remains unchanged for roughly 24–25 minutes while
  the suite runs. During `ORIGIN-20260813T193859Z-52506`, run status stayed at 19:39:00, origin-state still
  named the prior failed run/head, and `STATUS.md` still described the 17:16 stopped bootstrap. The 22-minute
  promotion similarly exposed only a growing log and live process tree.
- Expected: long control-plane jobs heartbeat current test/progress, last-output time, and authoritative
  run/head into status surfaces without mutating product source.
- Code anchor (0.18.0): `engine/integrate.sh:268-270` writes the initial activity and `:457` refreshes
  origin-state only at terminal completion.
- Evidence: run-status files for the four integration attempts, `.singular-state/origin-state.json`, stale
  `.singular-state/STATUS.md`, and timestamps in the integration/promotion suite logs.
- Operator cost/action: periodic PID/process-tree, log-tail, and artifact polling by hand.
- Resolution: open; TASK-0122 addresses the broader run-status contract.

### FR-025 — read-only status mutates tracked scaffolds and rejects an otherwise green integration

- First seen: 2026-08-13T18:50:27Z; frequency: deterministic reproduction in 1/1 focused probes.
- Classification: new; severity: critical; impact: blocked normal integration.
- Symptom: `ORIGIN-20260813T182615Z-70987` completed all 194 tests with raw exit 0 in 1,435,948ms, but strict
  source integrity saw lstat changes to `.gitignore` and all 36 orchestration schema mirrors and returned
  `inconclusive-infrastructure`. Terminal Git bytes and status were unchanged.
- Expected: `singular status` is observational; a green suite cannot be rejected because its status test
  rewrites byte-identical tracked scaffold files.
- Code anchor (0.18.0): `tests/test-executable-resolution.sh:25-33` invokes CLI status; installed
  `engine/reconcile.sh:46-47` creates state/scaffold before the status return at `:49`. The integrity guard in
  `engine/gate-check.sh:43,108-134` correctly observed the mutation.
- Evidence: first integration gate report/source snapshots; `test-fresh-consumer.sh` produced no changes,
  while `.singular-state/operator-probes/executable-resolution-20260813T185936Z-57180/changes.txt` alone
  reproduced exactly the same 37 paths (SHA-256 `4e89b584...`).
- Operator cost/action: one discarded 194/194 suite, a Codex decider call (20,153 input / 11,008 cached / 202
  output), focused attribution, and a bounded exact-tree adapter. The adapter synthesizes the exact staged
  merge with both parents, verifies tree/path identity, runs in a disposable linked worktree, permits only the
  proven 37-path metadata set, verifies every terminal blob/mode and Git-clean state, and leaves the outer
  driver-integrity guard active.
- Resolution: bootstrap mitigated and integrated; permanent read-only status fix is bound to TASK-0109.

### FR-026 — low-disk recovery regression races detached dispatch completion

- First seen: 2026-08-13T19:33:56Z; frequency: 3/10 detached focused reruns; 0/3 synchronous controls.
- Classification: new test-contract race; severity: high; impact: blocked one exact-tree integration and
  reduced trust in single-sample suite results.
- Symptom: exact candidate `580787c3`/tree `90292d0d` finished terminal-clean at 193/194. The only failure was
  `test-reconcile-low-disk.sh`, which observes dispatch open and immediately requires a completion marker even
  though production-default dispatch is detached. Cleanup raced the child and retained only
  `dispatch/TASK-0001.exit` containing `137`.
- Expected: the fixture keeps detached semantics but uses a bounded wait for terminal evidence and drains all
  children before assertion/cleanup.
- Code anchor (0.18.0): detached default in `engine/lib.sh:300-308`, non-waiting return in
  `engine/reconcile.sh:479-485`, immediate assertion in `tests/test-reconcile-low-disk.sh:145-150`.
- Evidence: failed integration `ORIGIN-20260813T191032Z-64937`; focused probe
  `.singular-state/operator-probes/low-disk-race-20260813T1936Z/{manifest.json,summary.md,raw-results.log}`.
- Operator cost/action: another 1,404,144ms full suite, a Codex decider call (20,276 input / 11,008 cached /
  162 output), ten detached and three synchronous focused reruns, and one bounded full-suite retry.
- Resolution: diagnosis and permanent acceptance criteria committed in `e0c15c9f`; code fix bound to TASK-0109.

### FR-027 — promotion gate report drops the wrapper's duration, integrity, and manifest binding

- First seen: 2026-08-13T20:27:09Z; frequency: 1/1 `rel-*` promotions.
- Classification: new evidence near-miss; severity: high; impact: degraded proof fidelity; promotion itself
  remained independently inspectable and exact-head green.
- Symptom: the promotion wrapper ran from 20:04:59Z to 20:27:07Z, verified candidate-clean source integrity,
  and wrote a detailed operator manifest at head `41380c1b`/tree `4915b69a`. The authoritative gate report,
  however, records `durationMs: 0` and `sourceIntegrity.status: not-checked`. The gate result hash-binds the
  suite log and gate report but neither references nor hashes the operator manifest that contains the missing
  facts.
- Expected: the normalized report carries real elapsed duration and terminal integrity, and the authoritative
  gate evidence binds the wrapper manifest (including exact head/tree, start/end, summary, and exception).
- Code anchor: local promoter/adapter boundary in `.singular-state/operator-promotion-gate.sh` and strict
  report normalization in installed `engine/gate-report.sh`/promoter flow.
- Evidence: `.singular-state/operator-promotion-proofs/rel-00-contract/20260813T200459Z-26026/manifest.json`,
  `docs/orchestration/gates/evidence/rel-00-contract.gate-report.json`, and
  `docs/orchestration/gates/rel-00-contract.gate-result.json`.
- Operator cost/action: manually cross-bound the manifest, suite log, gate report, gate result, head, and tree
  before treating rel-00 as promoted.
- Resolution: open; exact identity/attach work in TASK-0120/TASK-0121 is the natural permanent home.

### FR-028 — field-report canary reports a stale capture as a bare assertion

- First seen: 2026-08-13T20:28Z; frequency: 1/1 post-bootstrap canary runs.
- Classification: new diagnostic friction; severity: low; impact: annoyed and degraded release triage;
  the canary correctly remained red.
- Symptom: after the sprint's intentional DAG amendments, `tests/field-report-canary.sh` stopped at
  `captured-26-node-replay` with only a Python traceback and `AssertionError`. It did not name the stale DAG
  ref, print expected versus actual SHA-256, or state whether the capture metadata should be regenerated.
- Expected: a stale captured artifact fails closed with its repo-relative ref, expected/actual hashes, and a
  concise refresh instruction; the remaining canary cases must still not run after a failed capture preflight.
- Code anchor: hash assertions in `tests/field_report_canary_replay.py:106-107` and the first-stage wrapper in
  `tests/field-report-canary.sh:17-25`.
- Evidence: the 20:28Z canary output and the amended `docs/orchestration/dag.v0.json`; the failure occurred
  before any focused case ran.
- Operator cost/action: manually traced the assertion to distinguish an expected stale-fixture gate from an
  engine regression. The canary remains a rel-99 blocker until the canonical capture is intentionally updated
  and the full canary passes.
- Resolution: open; best folded into TASK-0123 snapshot/checkpoint work or TASK-0125 release preparation.

## Known-issue observation log

These are cost/frequency measurements, not new discoveries.

| Known issue | Occurrences | Time/token/evidence cost | Run/attempt evidence |
|---|---:|---|---|
| Context-route reviewer transcript mismatch causes fresh reviewer sessions | 0 resume-path occurrences | Implementer and reviewer both selected `fresh/no-session`; no prior reviewer session existed, so the filename mismatch was not exercised | `RUN-20260813T170836Z-93780` context-strategy events and session JSON |
| Worker per-try logs overwritten on infra retry | 0 worker infra retries | No overwrite fired. A broader attempt-archive omission was observed separately as FR-017; run root was preserved before any retry | `RUN-20260813T170836Z-93780/attempts/1/` versus run root |
| 240-minute stale hard cap reclaims live work | 0 occurrences | First worker ran about 5m26s; cap did not fire | `RUN-20260813T170836Z-93780/run-status.json` |

## Active dogfood questions

| Question | Evidence to collect | Current answer |
|---|---|---|
| Does self-hosted audit catch weak worker output before integration? | Worker packet, audit verdict/findings, gate result, integration event | Still inconclusive on weak-output detection: the first contract document passed and was correctly accepted. It eventually integrated only after deterministic revalidation and four integration attempts; no weak packet slipped through. |
| Are role budgets realistic; were mid-run raises needed and honored? | Session/run-control files, timeout events, operator actions, elapsed time | The first high-effort auditor completed correctly, but raw cumulative input accounting—mostly cached replay—exceeded the non-raisable canary. Provider-correct fresh input was 38,328. No mid-run deadline raise has yet been needed. |
| Is dispatch fair across parallel lanes at concurrency 3? | Ready time, dispatch time, start time, completion time per node | Not yet evaluable: recovery has only just promoted the serial bootstrap node. The parallel frontier is now eligible for the resumed autonomous loop. |
| What manual operator work should the engine perform or surface? | Every intervention and missing/ambiguous status signal | In addition to launch work, deterministic packet recovery, immutable snapshotting, exact-tree integration, status-mutation attribution, flaky-test isolation, proof cross-binding, and long-job progress polling all required manual operator work. |

## Task outcomes and attempts

Product attempts and audit/recovery/integration tries are recorded separately. A dash means the node has not run yet.

| Task | Node | Outcome | Product attempts | Audit / recovery / integration tries | Worker run IDs | Gate / packet evidence |
|---|---|---|---:|---:|---|---|
| TASK-0108 | rel-00-contract | integrated as `41380c1b`; authoritative gate passed at 20:27:09Z | 1 | 4 / 2 / 4 | `RUN-20260813T170836Z-93780`; recovery `RUN-20260813T182550Z-RECOVERY-TASK-0108-12256` | Immutable source snapshot; accepted imported packet/audit; final exact-tree 194/194; `rel-00-contract.gate-result.json` |
| TASK-0109 | rel-01-per-try-logs | ready; frontier-eligible after rel-00 promotion | 0 | 0 / 0 / 0 | — | — |
| TASK-0110 | rel-02-try-hygiene | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0111 | rel-03-integrity-reclass | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0112 | rel-04-evidence-remedy | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0113 | rel-05-manifest-remedy-bound | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0114 | rel-06-terminal-handoff | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0115 | rel-07-run-control | ready; frontier-eligible after rel-00 promotion | 0 | 0 / 0 / 0 | — | — |
| TASK-0116 | rel-08-route-transcript | ready; frontier-eligible after rel-00 promotion | 0 | 0 / 0 / 0 | — | — |
| TASK-0117 | rel-09-l1-lease-liveness | ready; frontier-eligible after rel-00 promotion | 0 | 0 / 0 / 0 | — | — |
| TASK-0118 | rel-10-failure-domains | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0119 | rel-11-supervised-job | ready; frontier-eligible after rel-00 promotion | 0 | 0 / 0 / 0 | — | — |
| TASK-0120 | rel-12-identity-canon | ready; frontier-eligible after rel-00 promotion | 0 | 0 / 0 / 0 | — | — |
| TASK-0121 | rel-13-gate-attach | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0122 | rel-14-run-status-v1 | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0123 | rel-15-snapshot-checkpoint | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0124 | rel-16-infra-try-resume | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0125 | rel-99-release | authored/ready but dependency-blocked; operator-authority | 0 | 0 | — | — |

## Parks and operator interventions

| UTC | Task/node | Park class | Reason / verdict artifact | Operator decision | Evidence |
|---|---|---|---|---|---|
| 2026-08-13T17:14:03Z | TASK-0108 / rel-00-contract | `escalate-infra` | Auditor `accepted`; final manifest refresh then failed `283064 >= 100000` and was reclassified as audit-infra | Deterministic, not transient. Did not unpark. Stopped auto, preserved the run, then used provenance-bound exact-head acceptance. | `.singular-state/runs/RUN-20260813T170836Z-93780/{audit.json,attempts/index.json,run-status.json,evidence-manifest-final-refresh.log}` |
| 2026-08-13T18:25:52Z | TASK-0108 / rel-00-contract | operator recovery | Scope, secrets, exact head, clean merge tree, and successful commands all revalidated | Accepted/imported existing output with authority `operator-proxy:codex`; original run unchanged; no probabilistic unpark | Recovery run, snapshot inventory, imported packet/audit, `recovery-provenance.json` |
| 2026-08-13T20:27:09Z | TASK-0108 / rel-00-contract | resolved | Integration commit `41380c1b`; fresh 194/194 promotion proof | Marked bootstrap park resolved; rel-00 authoritative gate passed | Integration and promotion artifacts |

## Evidence capture checklist

For each worker, retain or reference the run directory, `attempts/index.json`, attempt archive, worker/auditor
logs, per-try runner results and provider envelopes, `audit.json`, gate-check artifacts, run-status records,
session metadata, dispatch/lease records, imported packet and audit packet, and the relevant event-log slice.
Capture failing worker traces before any 0.18.0 infra retry can overwrite them.

## Current active-state snapshot

- `agent/integration` contains TASK-0108's exact product merge `41380c1b470585cbbbba2633a5fa564211893bff`.
  Its tree matches the independently tested candidate and its parents are the pre-integration target
  `e0c15c9f` plus audited worker `3fffc636` in that order.
- STOP remains present during the checkpoint and targeted TASK-0109 handoff; origin and Git-operation locks
  are absent. The general autonomous loop has not yet been restarted.
- Gates: 1/18. `rel-00-contract` is authoritative/passed; TASK-0108 is `integrated`; the remaining 17 task
  files are `ready`, with TASK-0109 and the independent rel-07/08/09/11/12 lanes now frontier-eligible.
- Packets: the historical imported corpus is 107 plus TASK-0108's accepted recovery packet/audit. The
  recovery packet, gate evidence, decision, and integrated task status are retained as control-state evidence.
- Resources: configured/effective slots are 3/3; current filesystem headroom is about 39 GiB with no capacity
  pressure.
- Provider/runtime proof: the immutable 0.18.0 overlay changes only `engine/evidence-manifest.sh`, keeps raw
  provider usage, charges coherent Codex cached replay correctly, and is active for subsequent commands.
  Effective runner/model are Codex and `gpt-5.6-sol`; push remains disabled.
- No push, tag, publish, install, current-symlink/default flip, blind unpark, cherry-pick, or tracked driver
  engine patch occurred. All exceptional recovery and exact-tree proof actions are preserved in ignored,
  hash-indexed operator evidence.

## `rel-99-release` readiness and operator handoff

- [ ] All non-release nodes have terminal acceptable outcomes.
- [ ] All parked tasks have explicit operator disposition.
- [ ] Full release task evidence and compatibility checks are present.
- [ ] Field-report canary is green and this report is complete.
- [ ] No unresolved finding makes promotion unsafe.
- [ ] Operator has reviewed the exact release diff and evidence.

Recommendation: **not yet ready for rel-99 promotion**. Bootstrap recovery is complete and rel-00 is green,
but 17 tasks remain and no release-candidate evidence exists. Continue with targeted TASK-0109 first so the
read-only-status and detached low-disk fixture fixes remove both bootstrap exceptions; then resume the eligible
parallel lanes under the immutable Codex overlay. Rel-99 must remain pending until every non-release gate is
authoritative/passed, the exact release diff and synchronized version surfaces are green, the field-report
canary and fresh-consumer proof pass, and the hash-bound human-gate request is reviewed. No push, tag, publish,
install, default flip, or release promotion has occurred.
