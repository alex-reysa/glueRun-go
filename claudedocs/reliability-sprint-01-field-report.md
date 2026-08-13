# Reliability Sprint 01 — dogfood field report

- Status: stopped at deterministic bootstrap blocker; operator decision required
- Engine under test: Singular 0.18.0 (self-hosted)
- Target release: 0.19.0
- Program: `rel-*` in `docs/orchestration/dag.v0.json`
- Driver branch: `agent/integration`
- Sprint launch commit: `99bf1df5f5aaf821beff317a2a2c99f298b2b62c`
- Provider: Codex via `codex-run.sh`
- Model: `gpt-5.6-sol` (`high` for L1/planner/auditor/critic/decider/readonly; `medium` for L2)
- Auto constraints: `maxConcurrent=3`, `SINGULAR_MAX_HOURS=20`, `SINGULAR_PUSH=0`, `BASH_COMPAT=52`
- Initialized: 2026-08-13T16:48:40Z
- Stopped: 2026-08-13T17:16:08Z (`STOP` sentinel retained; no live worker or origin lock)

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
- Operator cost/action: multiple silent diagnostics and one required dry-run lost about 10 minutes; known
  hung read-only process groups were terminated. The live run exports `BASH_COMPAT=52` before the CLI so all
  child shells inherit the Bash 5.2 compatibility behavior. No engine file was patched.
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

- First seen: 2026-08-13T17:08:15Z; frequency: 2/2 actuated/auto cycles so far.
- Classification: new; severity: medium; impact: degraded latency and operator signal; non-blocking.
- Symptom: pre-dispatch integration emits 107 `integration.skipped` events and 107 console lines for
  TASK-0001..TASK-0107 on every cycle, even though every packet branch head is already an ancestor of
  `agent/integration`. In the first actuated cycle this phase took about 17 seconds before capacity/frontier
  calculation; it dominated an otherwise sub-second reconcile path.
- Expected: terminal already-merged packets are indexed/cached or compactly summarized so unchanged history
  is not re-proven and reprinted each polling cycle.
- Code anchor (0.18.0): pre-dispatch auto-integration in `engine/reconcile.sh` and packet enumeration/ancestor
  checks in `engine/integrate.sh`.
- Evidence: 107 `integration.skipped` events between `origin.reconcile_started` and `integration.completed` in
  `.singular-state/events.ndjson`; console output and snapshots for `ORIGIN-20260813T170815Z-90711` and
  `ORIGIN-20260813T171019Z-2540`.
- Operator cost/action: roughly 17 seconds and 107 lines/events per cycle at current history size; no state
  deletion was attempted because the packets are tracked provenance.
- Resolution: open for a future sprint.

### FR-011 — first detached-dispatch completion reports zero running workers

- First seen: 2026-08-13T17:08:35Z; frequency: first detached dispatch.
- Classification: new; severity: low; impact: degraded observability / near-miss; non-blocking.
- Symptom: the first actuated cycle successfully launched PID 93704 and reported `dispatched_this_run=1`, but
  its final summary/event recorded `workers_running=0`. Two seconds later the worker emitted
  `l1.dispatch_started`; live health then correctly showed one active implementer.
- Expected: end-of-cycle running-worker telemetry either includes newly detached dispatches or labels the
  field as pre-dispatch/reaped-worker count so an operator does not infer that the launch vanished.
- Code anchor (0.18.0): `workers_running` is populated by the pre-dispatch reap in `engine/reconcile.sh`, then
  emitted unchanged after detached dispatch.
- Evidence: `ORIGIN-20260813T170815Z-90711` snapshot/completion event and
  `RUN-20260813T170836Z-93780` lifecycle/dispatch events.
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
- Operator cost/action: diagnosed before any unpark and stopped auto. No supported configuration can raise the
  canary: values over 100,000 fall back to 100,000. Existing-packet acceptance calls the same failing manifest
  refresh; ordinary unpark starts a new probabilistic model run and reclaims the old worker worktree/branch.
- Resolution: unresolved and blocking. Explicit operator choice/program amendment is required; blind unpark
  is unsafe.

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
  manifest alone.
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
- Evidence: directory comparison between `RUN-20260813T170836Z-93780/attempts/1/` and its run root. Important
  run-root hashes were captured during supervision; the auditor log is SHA-256 `e1d3df43...` and the final
  refresh log `aeda0b38...`.
- Operator cost/action: STOP retained and no retry/GC performed; run-root artifacts must be preserved before
  any future unpark.
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

### FR-020 — authored provider setting would silently select Claude without a higher-precedence override

- First seen: pre-launch configuration verification; frequency: current sprint config.
- Classification: launch configuration near-miss; severity: high for provenance; impact: potentially degraded
  provider compliance; mitigated before actuation.
- Symptom: `singular.config.json` still specifies `runner: claude-run.sh`; its Codex model/effort variables are
  inert under that runner. A one-shot `SINGULAR_RUNNER` prefix is overwritten when JSON is loaded.
- Expected: the committed execution config names the provider intended for the sprint, or the CLI clearly
  reports the final effective provider before dispatch.
- Code anchor (0.18.0): increasing-precedence config load in `engine/lib.sh` (JSON, shell config, then local
  config) and runner dispatch.
- Evidence: committed `singular.config.json`, `.singular-state/config.local.sh`, and both role session/result
  records showing provider Codex and model `gpt-5.6-sol`.
- Operator cost/action: created a gitignored local config selecting `codex-run.sh`, `gpt-5.6-sol`, and
  `SINGULAR_PUSH=0`; verified every actual model result. No Claude session was launched.
- Resolution: run-level mitigation succeeded; durable config clarity remains open.

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
| Does self-hosted audit catch weak worker output before integration? | Worker packet, audit verdict/findings, gate result, integration event | Inconclusive on weak-output detection: the first small contract document passed and the auditor accepted it with no findings. No weak packet integrated; accounting blocked the accepted packet first. |
| Are role budgets realistic; were mid-run raises needed and honored? | Session/run-control files, timeout events, operator actions, elapsed time | No. The first high-effort auditor finished correctly but cumulative input accounting (mostly cached replay) exceeded a non-raisable 100k canary and terminalized the run. No mid-run deadline raise was needed; the sprint stopped before rel-07 could exercise that path. |
| Is dispatch fair across parallel lanes at concurrency 3? | Ready time, dispatch time, start time, completion time per node | Not evaluable: only serial bootstrap node rel-00 became runnable, then blocked before parallel lanes opened. Capacity remained 3. |
| What manual operator work should the engine perform or surface? | Every intervention and missing/ambiguous status signal | Provider override, promoter registration, disk diagnosis/cache reclamation, unrelated-workstream exclusion, Bash compatibility selection, telemetry reconciliation, raw artifact forensics, failure reclassification, and the clean STOP all required manual action or cross-checks. |

## Task outcomes and attempts

Product attempts and infra/audit tries are recorded separately. A dash means the node has not run yet.

| Task | Node | Outcome | Product attempts | Infra/audit tries | Worker run IDs | Gate / packet evidence |
|---|---|---|---:|---:|---|---|
| TASK-0108 | rel-00-contract | blocked `escalate-infra` after accepted audit; not integrated | 1 | 4 (3 host verification tries + 1 auditor) | `RUN-20260813T170836Z-93780` | Run root; `audit.json`; `attempts/index.json`; `evidence-manifest-final-refresh.log`; packet remains `needs-review` |
| TASK-0109 | rel-01-per-try-logs | ready; not dispatched, dependency-blocked by rel-00 | 0 | 0 | — | — |
| TASK-0110 | rel-02-try-hygiene | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0111 | rel-03-integrity-reclass | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0112 | rel-04-evidence-remedy | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0113 | rel-05-manifest-remedy-bound | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0114 | rel-06-terminal-handoff | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0115 | rel-07-run-control | ready; not dispatched, dependency-blocked by rel-00 | 0 | 0 | — | — |
| TASK-0116 | rel-08-route-transcript | ready; not dispatched, dependency-blocked by rel-00 | 0 | 0 | — | — |
| TASK-0117 | rel-09-l1-lease-liveness | ready; not dispatched, dependency-blocked by rel-00 | 0 | 0 | — | — |
| TASK-0118 | rel-10-failure-domains | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0119 | rel-11-supervised-job | ready; not dispatched, dependency-blocked by rel-00 | 0 | 0 | — | — |
| TASK-0120 | rel-12-identity-canon | ready; not dispatched, dependency-blocked by rel-00 | 0 | 0 | — | — |
| TASK-0121 | rel-13-gate-attach | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0122 | rel-14-run-status-v1 | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0123 | rel-15-snapshot-checkpoint | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0124 | rel-16-infra-try-resume | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0125 | rel-99-release | authored/ready but dependency-blocked; operator-authority | 0 | 0 | — | — |

## Parks and operator interventions

| UTC | Task/node | Park class | Reason / verdict artifact | Operator decision | Evidence |
|---|---|---|---|---|---|
| 2026-08-13T17:14:03Z | TASK-0108 / rel-00-contract | `escalate-infra` | Auditor `accepted`; final manifest refresh then failed `283064 >= 100000` and was reclassified as audit-infra | Deterministic, not transient. Did not unpark. Wrote STOP at 17:15:58Z; auto exited cleanly. Requires explicit operator decision/program amendment. | `.singular-state/runs/RUN-20260813T170836Z-93780/{audit.json,attempts/index.json,run-status.json,evidence-manifest-final-refresh.log}` |

## Evidence capture checklist

For each worker, retain or reference the run directory, `attempts/index.json`, attempt archive, worker/auditor
logs, per-try runner results and provider envelopes, `audit.json`, gate-check artifacts, run-status records,
session metadata, dispatch/lease records, imported packet and audit packet, and the relevant event-log slice.
Capture failing worker traces before any 0.18.0 infra retry can overwrite them.

## Final stopped-state snapshot

- Last engine control-state commit: `98705e17` on `agent/integration`; it records TASK-0108 blocked and the
  two bootstrap decisions. Worker commit `3fffc6362347e21b83e76fa27a4732a72f589d7e` remains on
  `agent/eval/TASK-0108-reliability-contract` with its worktree intact.
- Auto: exited; STOP: present; origin lock: absent; active/stale leases: 0/0; breaker: 1/5 and closed.
- Gates: 0/18. Task files: 17 `ready`, one `blocked`. The one reported DAG frontier node is rel-00, whose task
  is blocked, so it is not dispatchable.
- Packets: inbox 0; historical imported packet corpus 107; TASK-0108 packet remains run-local
  `needs-review` and was neither enqueued nor integrated.
- Resources: configured/effective slots 3/3; final health reported 22 GiB free and no capacity pressure.
- Provider proof: implementer and reviewer session/result records identify Codex, `gpt-5.6-sol`, with medium
  implementer effort and high reviewer effort.
- No push, release promotion, default flip, manual packet acceptance, cherry-pick, engine-code patch, or
  unpark occurred.

## `rel-99-release` readiness and operator handoff

- [ ] All non-release nodes have terminal acceptable outcomes.
- [ ] All parked tasks have explicit operator disposition.
- [ ] Full release task evidence and compatibility checks are present.
- [ ] Field-report canary is green and this report is complete.
- [ ] No unresolved finding makes promotion unsafe.
- [ ] Operator has reviewed the exact release diff and evidence.

Recommendation: **not ready for operator promotion**. The program stopped at its bootstrap node with 0/18
gates passed; 17 tasks were never dispatched, `rel-99-release` is not frontier-ready, and no release evidence
exists. Keep STOP in place and preserve the full TASK-0108 run root. Before resuming, the operator must choose
between an explicitly authorized program/engine amendment that fixes the canary/terminal-handoff path, or a
fresh probabilistic unpark with reduced auditor effort after separately preserving the accepted worker ref and
run-root evidence. The latter is not recommended as a reliable fix. No push, promotion, release, or default flip
occurred.
