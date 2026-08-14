# Reliability Sprint 01 — dogfood field report

- Status: active; `rel-00-contract`, `rel-01-per-try-logs`, and `rel-02-try-hygiene` are
  integrated/promoted; TASK-0109 is
  integrated as merge `9d9c41f2223cd35b634a7c722ee4cb5ed9ca620a`, and its authoritative gate was
  recorded at exact checkpoint head `9c1f2e7b5703d00f476b2115442938c57779f813`
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
- Initial targeted `rel-01-per-try-logs` run: 2026-08-13T20:34:31Z–20:54:39Z; packet quarantined
- Amended `rel-01-per-try-logs` retry: 2026-08-13T21:10:09Z–21:34:27Z; STOP retained after quarantine
- Seed-restored `rel-01-per-try-logs` retry: 2026-08-13T21:39:39Z–22:06:25Z; STOP retained before integration
- Literal-contract `rel-01-per-try-logs` retry: 2026-08-13T22:13:59Z–22:50:16Z; natively accepted;
  STOP restored before import/integration
- Native TASK-0109 import/integration: 2026-08-13T22:58:43Z–23:50:12Z; exact staged merge passed
  195/195 and was committed; STOP retained before `rel-01-per-try-logs` promotion
- Native `rel-01-per-try-logs` promotion: 2026-08-13T23:57:54Z–2026-08-14T00:47:13Z; fresh
  195/195 proof passed and the v1 gate was recorded; STOP retained before runtime-overlay activation
- Successor runtime overlay verification: 2026-08-14T00:52:43Z–00:56:27Z; immutable rel-01 controller
  bundle verified behind STOP
- Successor runtime overlay activated by environment: 2026-08-14T01:00:43Z; clean status/health/DAG
  preflight completed, with no install, symlink, or default-version change
- First successor-runtime autonomous wave: `ORIGIN-20260814T010413Z-73798`; exact frontier tasks
  TASK-0110/TASK-0115/TASK-0116 launched in parallel, STOP restored at the contract hold, and no packet was
  imported or integrated
- Operator-proxy contract correction: 2026-08-14T01:47:45Z; all three wave results rejected as integration
  inputs, evidence snapshots and candidate refs retained, and rel-99 kept blocked
- Fresh amended successor-runtime wave: 2026-08-14T02:21:34Z–03:10:54Z; supported direct
  `drive --reset` runs for TASK-0110/TASK-0115/TASK-0116 started together from exact head
  `97862d9370649c90ae67c825ed5d14ca3d37e530` under the immutable rel-01 overlay
- Fresh-wave operator hold: STOP restored at 2026-08-14T02:31:24Z; TASK-0110 and TASK-0116 packets were
  quarantined before import/integration, TASK-0115 terminalized on the 147,124-token primary-audit canary,
  and all three exact candidate refs were retained as evidence only
- Fresh v3 TASK-0110 rerun: 2026-08-14T04:15:47Z–04:38:28Z (binding record completed 04:40:33Z);
  exact candidate `7ca9c5c1` passed its
  worker gate and three raw verifier executions, the primary and manually forced fresh paired auditors both
  accepted with no findings, and STOP retained the manifest-bound inbox packet before import/integration
- Native TASK-0110 import and first integration attempt: 2026-08-14T04:47:50Z–05:13:05Z; exact packet/audit
  imported under STOP, but the staged integration failed closed at 194/195 solely because the host Data volume
  rounded to the console server's 99% disk-watch threshold. Scoped disposable-fixture cleanup restored the
  application metric to 98%, and the isolated 275-test console suite then passed before any retry
- Native TASK-0110 integration retry: 2026-08-14T05:32:40Z–05:55:27Z; supported staged gate passed 195/195
  with verified source integrity and exact three-path merge `1b69af277f96f3f1b5cf3c904abebddfa4074469`;
  STOP retained before rel-02 promotion and composite-runtime handoff
- Native `rel-02-try-hygiene` promotion: 2026-08-14T05:59:43Z–06:21:45Z; fresh 195/195 proof passed at
  clean checkpoint `93b13a47497d5ed179247ed4b4434a043cd63f3e`, authoritative v1 gate validated, and STOP retained
  before composite-runtime construction

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
| 2026-08-13T20:34:31Z | `RUN-20260813T203430Z-96335` | TASK-0109 attempt 1 dispatched alone under STOP | Codex implementer ran fresh and produced six-scope commit `e5aa5a1e`; the authored gate passed at 20:42:35Z | Run root, worktree provision record, attempt index, commit and gate report |
| 2026-08-13T20:42:37Z | same run, attempt 1 host verification | Exact-head gate was already green | All three disposable verification executions passed but failed strict normalization, adding about 39 seconds before evidence-only fallback | `audit-verification-1-{0,1,2}.log`, matching normalization errors, event slice |
| 2026-08-13T20:46:28Z | same run, attempt 1 audit | Auditor verdict `needs-fix`; eight ledger entries open | Auditor caught four substantive coverage gaps: byte-exact retry/order, production-shaped sidecars, real-checkout lstat identity, and repeated detached recovery/drain. Policy correctly selected retry. | `attempts/1/audit.json`, `findings-status.json`, attempt index |
| 2026-08-13T20:46:30Z | same run, attempt 2 | Implementer session resumed | Worker strengthened only the owned tests, resolved all eight finding/required-fix entries, and committed exact head `08bcb2b0`; the authored gate passed at 20:50:52Z | Resume runner result, `reaudit-diff-attempt-2.patch`, gate artifacts |
| 2026-08-13T20:50:54Z | same run, attempt 2 host verification/audit | Exact-head gate green; reviewer selected fresh | Three more green reruns again failed strict normalization (about 66 seconds of redundant gate runtime). The known ctx-route transcript mismatch selected `fresh/tainted` rather than resuming the prior reviewer. | `audit-verification-2-{0,1,2}.log`, session-reviewer JSON, context-strategy event |
| 2026-08-13T20:54:38Z | same run, attempt 2 terminal handoff | Auditor `accepted`, all eight findings resolved; task then `escalate-infra` | Corrected Codex charging counted 76,916 + 62,600 fresh auditor input across both attempts = 139,516, exceeding the fixed 100,000 cumulative canary. Final refresh failed, policy parked TASK-0109, and no packet or integration followed. | Final audit, final-refresh log, four runner results, attempts index, run status, decision and lease |
| 2026-08-13T21:01:49Z | `RUN-20260813T210149Z-RECOVERY-TASK-0109-27742` | Deterministic recovery try 1 | Exact-head host revalidation correctly stopped before acceptance: a later successful packet command expected the earlier RED log, but the disposable worktree did not carry that expected-failure artifact | Recovery command results and command-5 log |
| 2026-08-13T21:03:41Z | `RUN-20260813T210341Z-RECOVERY-TASK-0109-29558` | Provenance-bound deterministic acceptance | Exact head `08bcb2b0`, scope, secrets, and current successful commands passed with zero model calls. Provenance retained both auditor results and the source run's real `139516 >= 100000` breach; the recovery manifest's zero means zero new audit input, not a reset | Recovery provenance, manifest, deterministic audit, source-run snapshot |
| 2026-08-13T21:05:30Z | operator quarantine | Accepted recovery packet withheld before integration | A stricter evidence review made FR-029 blocking for this candidate. The packet/audit were moved intact to a recoverable ignored quarantine, lease returned to blocked, exact candidate retained under `refs/singular-evidence/TASK-0109/attempt-2`, and TASK-0109 was amended to require hostile-environment event/state hermeticity | Quarantine manifest and hashes, `quarantine-retry` decision, amended task contract |
| 2026-08-13T21:09:23Z | control commits `e656070c` / `014466d5` | TASK-0109 amended and returned to the frontier | Quarantined the non-hermetic packet, preserved its exact candidate ref, added hostile-state acceptance criteria, and deliberately unparked only the amended task | Commits, decisions, amended task/DAG, first quarantine manifest |
| 2026-08-13T21:10:09Z | `RUN-20260813T211009Z-78320` | Amended TASK-0109 attempt 1 dispatched alone under STOP | Generated worker context omitted the authored `Recovery seed:` paragraph and exact `08bcb2b0` ref. The fresh implementer rebuilt from target head and committed weaker candidate `6fd30118`; its five-test gate still passed | `l2-prompt.md` SHA-256 `6fe20dd8...`, authored task, worker result, commit and gate report |
| 2026-08-13T21:17:00Z | same run, attempt 1 host verification/audit | Exact-head gate green; auditor verdict `needs-fix` | Three more green executions again failed strict normalization. The auditor correctly rejected four explicit proof gaps, opening eight finding/fix ledger entries; its provider-correct charge was 82,896 fresh input tokens | `audit-verification-1-{0,1,2}.log`, attempt-1 audit, findings ledger, auditor runner result |
| 2026-08-13T21:20:38Z | same run, attempt 2 | Implementer session resumed | The worker resolved all eight ledger entries and committed `ed8fc1bc`. Its hostile fixture ran twice, and the authoritative event-log count stayed at exactly the original eight fabricated entries through the worker gate plus three host reruns | Resume/session metadata, `reaudit-diff-attempt-2.patch`, gate logs, event evidence |
| 2026-08-13T21:26:12Z | same run, attempt 2 host verification/audit | Exact-head gate green; reviewer again selected `fresh/tainted` | Another three green executions normalized zero times. The fresh Codex auditor again hit the read-only `evidence-show.sh` lock failure, worked around it, marked all eight entries resolved, and returned `accepted` | `audit-verification-2-{0,1,2}.log`, context event, final audit and runner result |
| 2026-08-13T21:29:03Z | same run, attempt 2 terminal handoff | Accepted audit terminalized as `escalate-infra` | Final refresh summed 82,896 + 68,806 provider-correct auditor input = `151702 >= 100000`; policy parked the accepted result and STOP remained in place | Final-refresh log, attempts index, run status, decision and lease |
| 2026-08-13T21:29:41Z | `RUN-20260813T212941Z-RECOVERY-TASK-0109-19936` | Deterministic zero-model recovery accepted/imported `ed8fc1bc` | Exact head, clean merge tree, six-file scope, secrets, current successful commands, and syntax proof passed. Provenance explicitly retained the source breach rather than resetting it | Recovery manifest/provenance, packet SHA-256 `4259ed45...`, audit SHA-256 `c79ba4c1...` |
| 2026-08-13T21:34:00Z | independent exact-contract review | Second accepted packet quarantined before integration | Review found three regressed proofs the accepted audit missed: status used a synthetic repository/direct reconcile instead of real-checkout CLI `status` plus full lstat; low-disk coverage fell from ten cycles to one; and live rc-86 resume-refusal/fallback execution was replaced by a fabricated archive file. The packet/audit were preserved intact and TASK-0109 was hardened for mandatory seed restoration | Second quarantine manifest, `quarantine-retry`/`escalate-parked` decisions, hardened task contract |
| 2026-08-13T21:37:57Z | control commits `af17357e` / `fffb91fc` | TASK-0109 hardened and deliberately returned to the frontier | Moved mandatory `08bcb2b0` restoration into the rendered Objective, made all three regressed proofs literal/numeric acceptance terms, and unparked only TASK-0109 under STOP | Commits, task contract, `ORIGIN-20260813T213804Z-23950` decision |
| 2026-08-13T21:39:39Z | `RUN-20260813T213939Z-24911` | Seed-restored TASK-0109 attempt 1 dispatched alone | Worker restored the exact seed: five owned paths remained byte-identical to `08bcb2b0` and only `test-per-try-artifacts.sh` gained the hermeticity work. Candidate `4815b9e4` passed the five-test gate, including real-checkout full-lstat status and ten detached cycles | Worker audit log, seed diff, commit and gate report |
| 2026-08-13T21:48:17Z | same run, attempt 1 host verification/audit | Exact-head gate green; auditor verdict `needs-fix` | All three host executions passed and all normalizations failed again. Auditor correctly caught that live rc-86 resume/fallback did not emit/assert result/envelope names or exact aggregate ordering/bytes; it charged 47,825 fresh input tokens | `audit-verification-1-{0,1,2}.log`, attempt-1 audit, findings ledger and runner result |
| 2026-08-13T21:51:48Z | same run, attempt 2 | Implementer session resumed | Worker added 36 lines only to `test-per-try-artifacts.sh`, resolved all four product finding/fix entries, and committed `ede05b0e`; the authored gate passed and the original authoritative event log still contained exactly eight `resume-run` fixtures—no ninth fake event | Resume result, re-audit diff, gate log, event count |
| 2026-08-13T21:54:56Z | same run, attempt 2 host verification/audit | Exact-head gate green; reviewer selected `fresh/tainted` | Three more green executions normalized zero times. The fresh reviewer hit `evidence-show.sh`'s read-only lock failure again, accepted the candidate, and primary cumulative audit charge remained below the hard bound at 47,825 + 45,651 = 93,476 | `audit-verification-2-{0,1,2}.log`, context event, audit, final manifest and role results |
| 2026-08-13T22:01:42Z | same run, sampled paired audit | Primary and paired auditors both returned `accepted` | Paired review ran from an unresolved base `[TASK-ID]` prompt with no run-bound audit contract, missed that the fixture runs once against a synthetic caller root, then emitted eleven positive “findings”; the recorder marked `agreement:false`/`disagreement:true` despite matching accepted verdicts | `paired-audit-raw.json`, `paired-audit.json`, paired runner result, exact test lines |
| 2026-08-13T22:05:49Z | operator hold/quarantine | Accepted inbox packet stopped before import/integration | STOP prevented import/integration. Independent exact-contract review revoked acceptance: both auditors counted external gate reruns instead of the explicit `>=2` in-process fixture executions and accepted a synthetic `$tmp/invoking-checkout` guard rather than literal incoming caller checkout/state/event paths | Third quarantine manifest SHA-256 `c01d6384...`, clarified decision, candidate ref |
| 2026-08-13T22:13:59Z | `RUN-20260813T221358Z-8581`, attempt 1 | Literal-contract TASK-0109 retry | Fresh implementer produced the requested exact proof, but the worker gate failed because its strict incoming-state inventory observed the gate's own live `.singular-state` log activity; policy archived the attempt as `gate-red` | `attempts/1/{gate-check.log,gate-report.json}`, attempt index |
| 2026-08-13T22:23:51Z | same run, attempt 2 | Policy retry selected `fresh/role-mismatch` for the same implementer role | Gate-red returned before host session metadata finalization, so the valid prior implementer session could not resume. The fresh worker retained the exact contract and committed `b874a874`; provider command lifecycle overlap briefly inspected a still-running partial regression log, then bounded reruns established all five terminal green markers | Context-strategy event; `worker-codex.log` items 36–42; candidate commit and packet |
| 2026-08-13T22:40:26Z | same run, host verification | Exact candidate gate already green | Three additional verifier executions were also green but all failed strict normalization because the focused gate chain does not write the observation file; evidence-only fallback completed after about 6m57s | `audit-verification-2-{0,1,2}.log`, normalization errors and final verification record |
| 2026-08-13T22:50:15Z | same run, native audit | TASK-0109 accepted with no findings or fixes | Auditor verified the direct parent, exact six-file scope, exact seed retention, literal two-iteration hostile-state contract, green commands, and hashes. Usage was 562,461 input / 476,160 cached / 7,496 output; canary charge 86,301 < 100,000. The historical `resume-run` identity remained exactly eight events—no ninth fake event. | `audit.json`, final evidence manifest, runner result, inbox packet |
| 2026-08-13T22:50:44Z | operator quiescence | Accepted packet awaiting import/integration | STOP was written after native acceptance and before any import, exact-tree integration, rel-01 promotion, or runtime activation | `.singular-state/STOP`, inbox packet, event slice |
| 2026-08-13T22:58:43Z | `ORIGIN-20260813T225843Z-71671` | Accepted TASK-0109 packet imported under STOP | Reconcile imported the sole active packet, committed its packet/audit and control state as `de7e9d52`, dispatched nothing, and left the exact worker head unchanged | Imported packet/audit, commits `8c99e896` and `de7e9d52`, reconcile event slice |
| 2026-08-13T23:00:00Z–23:50:12Z | `ORIGIN-20260813T230100Z-TASK0109-NATIVE` | Native TASK-0109 integration completed; rel-01 not yet promoted | The staged merge changed exactly `engine/l1-drive.sh`, `engine/lib.sh`, `engine/reconcile.sh`, `tests/test-executable-resolution.sh`, `tests/test-per-try-artifacts.sh`, and `tests/test-reconcile-low-disk.sh`. The full suite passed 195/195 in 3,010,561ms with `sourceIntegrity.status=verified`, `changedPaths=[]`, log SHA-256 `8646d137c1b11a96a89bd34bcb897ebcd55bc279a95cec190a9f34cb9310d4c1`, and the authoritative fake-event count still exactly eight. Merge `9d9c41f2` has parents `de7e9d52` then `b874a874` and tree `bf6553eb58227f1ae86fcdeb0728fc6fc6512cef`. | Integration run/gate report and log, merge object, event slice |
| 2026-08-13T23:57:54Z–2026-08-14T00:47:13Z | `ORIGIN-20260813T235754Z-8483` | Native `rel-01-per-try-logs` promotion completed under STOP | Exact checkpoint head `9c1f2e7b`/tree `af2f0cce` remained frozen while the fresh suite passed 195/195 in 2,959s; `test-per-try-artifacts.sh` consumed about 26m25s. Gate-result SHA-256 is `a2a13d96c0735b441bc46ecd8f2498968eead794098b0f0fe641fc1ec8da74d8`, strict report SHA-256 `eab36f165117de1518bf7f9aadd60d9a0445cd7f7f94847d718d4c3b107fe0ab`, and log SHA-256 `8646d137c1b11a96a89bd34bcb897ebcd55bc279a95cec190a9f34cb9310d4c1`. Independent source/task-set/command/log/report/evidence-binding hashes passed; `singular gate validate` and both rel-00/rel-01 `area-gate` checks passed. | `docs/orchestration/gates/rel-01-per-try-logs.gate-result.json`, its three evidence files, promotion events, launch/terminal identity snapshots |
| 2026-08-14T00:52:43Z–00:56:27Z | operator overlay `singular-0.18.0-canary-rel01-v2-b874a874` | Verified successor runtime prepared; activation not performed | Built at exact path `/Users/alejandro/Desktop/999. PROJECTS/pmgo-orchestration-engine/.singular-state/operator-engine-overlays/singular-0.18.0-canary-rel01-v2-b874a874` from the prior Codex-cache overlay. The type/mode/hash diff contains exactly `engine/l1-drive.sh` (`65a8d761f20ab9073bf839d936f3e4f794f65cc36ef26462f216567a39beb069`), `engine/lib.sh` (`54eb097871a0750adae372d767f22a185ed006a373562d67cb5f55a5b9076476`), and `engine/reconcile.sh` (`8e9989bc154416dc5f7f1f95dee27279ad63c9d92e64f4339b8c43bd62eb7e4b`); preserved `engine/evidence-manifest.sh` is `aabfd6d9b868cbeb12816b25a12477761b95b862f4be245e0c8311a3ee3ce25d`. Bundle-manifest SHA-256 is `eb42e919a61232473f28a97c3370fa3925d589988fd8ae3023698e112cfcf25c`, metadata SHA-256 is `df2a56ffa8ae99fe260046dd6ed94a3cb02d205ec5a4492f52a472cc3398f80c`, and delta-record SHA-256 is `c3a1ea4ce94400b67b5f97e30173afb9a4ffe1cdccf3257077c583c90558ffc1`. The focused five-command gate passed in 58s with log SHA-256 `d3a7ec08539ef0b0df46377456d8606259c5e90b955629c9a38e72c7af58d49f`; binding SHA-256 `a37fb394c5f79a0e9cc4acde2266d232f5ca802858c27bf60d43d794870ef637` ties it to worker `b874a87466e118eef167190a66e048d944ab7544`/tree `3efce762d9018fdf73b0b550db9e83941dc82e59`. Full-suite binding SHA-256 `71959703760326110695a514c064440f05e71e8e1ed0616a0fd51c335a849e98` ties the bundle to the prior 195/195 integration and passed promotion. All 301 filesystem objects, including the root, carry `uchg`. STOP stayed present; the predecessor overlay is superseded for the next activation but retained intact rather than deleted. | `.singular-state/operator-engine-overlay-records/singular-0.18.0-canary-rel01-v2-b874a874/{overlay-metadata.json,overlay-bundle.type-mode-sha256.tsv,predecessor-to-overlay.diff.tsv,focused-gate.log,focused-gate-binding.tsv,full-suite-promotion-binding.tsv}` |
| 2026-08-14T01:00:43Z | environment-only runtime activation | Successor overlay active behind STOP | Pinned `SINGULAR_ENGINE_HOME` to the verified successor's absolute path without installing a bundle or changing any symlink/current/default version. `singular status`, `singular health`, and DAG inspection resolved the new runtime cleanly and preserved tracked scaffold metadata; health reported 3 configured/effective slots and 34.3 GB free. Activation record SHA-256 is `b4eb1d08e1e7ecf06fff1082b0fdd809dc32f53d8f66c52d8bf941c258b55588`. The predecessor overlay remains intact as the superseded rollback artifact, and STOP prevented dispatch during the handoff. | `.singular-state/operator-engine-overlay-records/singular-0.18.0-canary-rel01-v2-b874a874/activation-20260814T010043Z.json`, clean Git status apart from this report, both immutable overlay paths |
| 2026-08-14T01:04:13Z–01:04:33Z | `ORIGIN-20260814T010413Z-73798` | First autonomous successor-runtime wave; exact tasks TASK-0110/TASK-0115/TASK-0116 | Removed STOP for the bounded wave. At checkpoint head `81f67e00183da8bbed298dfe3c313060fdcab86c`, configured/effective/available capacity was 3/3/3 and all three tasks dispatched under the activated `singular-0.18.0-canary-rel01-v2-b874a874` overlay with Codex `gpt-5.6-sol`. The completion event nevertheless reported `workersRunning=0`; no packet was imported or integrated. | Origin snapshot/events; worker runs `RUN-20260814T010432Z-76912`, `RUN-20260814T010432Z-76911`, and `RUN-20260814T010432Z-76945` |
| 2026-08-14T01:08:01Z–01:15:49Z | `RUN-20260814T010432Z-76945` | TASK-0116 attempts 1–2 | Attempt 1 gate passed but audit returned `needs-fix`: its mandatory RED stopped on a structural spy assertion before exercising live routing under window pressure. Attempt 2 corrected the RED and was accepted at candidate `98628d0d24474953980c43ad9416702ac7e66600`, then final refresh rejected cumulative fresh auditor input `101302 >= 100000`; no packet followed. | Attempt archives, final audit, final-refresh log, stale manifest, candidate ref |
| 2026-08-14T01:14:19Z | autonomous-loop hold | Contract review hold while all three detached workers continued | Restored STOP; `singular auto` exited after iteration 17. Across the 16 completed reconcile iterations, no import or integration occurred; the first iteration dispatched three workers and the next 15 observed them at full capacity. | STOP, auto log, origin completion events |
| 2026-08-14T01:16:55Z–01:41:57Z | `RUN-20260814T010432Z-76911` | TASK-0115 attempts 2–3 after an initial gate-red | Attempt 2 audit rejected unenforced same-UID host authority, no-control drift, and an inadequate RED. Attempt 3 strengthened the fixture but still used path hiding rather than an authority boundary; the second audit remained `needs-fix`. Final refresh then rejected cumulative fresh auditor input `178060 >= 100000`; candidate `68c48b4a209297db4778ad47095758ff52ec2fa6` was retained for evidence only. | Attempts index, both audits, final-refresh log, stale manifest, candidate ref |
| 2026-08-14T01:23:02Z–01:28:46Z | `RUN-20260814T010432Z-76912` | TASK-0110 deterministic gate-red retry and no-progress park | Both host gates failed only because TASK-0110's literal inventory of shared `.singular-state` observed concurrent TASK-0115 writes; both source-integrity reports remained verified with `changedPaths=[]`. Neither attempt was committed or assigned a `headSha`; the viable three-file attempt-2 diff survived only as a dirty base worktree, and the second identical terminal class triggered `escalate-parked`. No audit, packet, or candidate ref exists. | Attempt gate reports/logs, source-integrity bindings, worker RED/GREEN/regression logs, run status, worktree diff SHA-256 `e35b4160...` |
| 2026-08-14T01:43:00Z–01:47:45Z | operator evidence preservation and contract correction | Three wave tasks blocked; no integration | Preserved inventory-verified recovery snapshots for all three runs. With authority `operator-proxy:codex`, rejected every wave result as an integration input, amended TASK-0110 to require concurrency-safe causal leakage proof, TASK-0115 to require externally signed Ed25519 v1 control, and TASK-0116 to distinguish artifact routing from intentionally fresh final/paired audits. The amendments and candidate refs are operator evidence, not acceptance or promotion. | Recovery snapshot inventories, decision/task/DAG amendments, `refs/singular/operator-candidates/TASK-011{5,6}/...` |
| 2026-08-14T02:06:49Z | restart preflight | No controller or worker live; STOP immediately restored | A read-only syntax probe invoked `singular resume --help`; the CLI forwarded the unused argument and executed resume, removing STOP and appending one event. The sentinel was recreated immediately before any controller existed, so no reconcile, dispatch, import, integration, or tracked write occurred. | `operator.resume_requested` event, restored STOP, empty locks/inbox/process scan |
| 2026-08-14T02:21:34Z–02:24:23Z | amended-wave reset handoff | TASK-0110/TASK-0115/TASK-0116 unparked; old blocked worktrees still retained | The frozen entry point exits before `--reset`, while auto cannot request reset for retained blocked worktrees. The operator therefore preserved the old evidence, briefly removed STOP, and launched three supported direct `drive TASK --reset` calls. Each old worktree/branch was removed and recreated from exact base `97862d9370649c90ae67c825ed5d14ca3d37e530`; the new leases bound the amended owned scope and batch `ORIGIN-20260814T022500Z-AMENDED-batch`. | Unpark/resume/stop event slice, new leases, worktree reflogs, `RUN-20260814T022422Z-{15250,15249,15254}` provision records |
| 2026-08-14T02:24:23Z–02:31:07Z | `RUN-20260814T022422Z-15254` | Fresh amended TASK-0116 attempt 1 | Candidate `c5a2842a72faa9b6f84c313febb509217f2d9630`/tree `ebd986e7ea1841200110c78fd0294e2869ff413d` passed its 4,112ms gate and three raw-green verifier reruns, then the primary auditor accepted it using 52,620 fresh input and 5,291 output tokens. Exact-contract review found that the asserted RED/GREEN used step `review`, not the contract's literal unpinned `probe`, so the accepted packet was quarantined at 02:33:43Z before import/integration. | Run root, primary audit/result, quarantine manifest SHA-256 `03301456a85784352b32558b8429d8db3411bba23c2589674b7211056582990b`, candidate ref |
| 2026-08-14T02:31:24Z | operator contract hold | Three direct L1 drivers still winding down | STOP was restored immediately after the first accepted primary audit. It prevented reconcile/import/integration while the already-running TASK-0110/TASK-0115 drives completed; no new driver was authorized afterward. | `operator.stop_requested` event, STOP sentinel, process/event slice |
| 2026-08-14T02:31:58Z–02:44:43Z | `RUN-20260814T022422Z-15250` | Fresh amended TASK-0110 attempt 1 plus sampled paired audit | Candidate `fa95b8dcc7e5c7f75b8a355135ea09bdcbf49456`/tree `6987d2152fdbf519829c96b124a9e9c2808bad27` passed its 36,252ms gate and three raw-green verifier reruns. The primary auditor accepted with 58,625 fresh input/7,401 output; the post-accept paired auditor used 237,616 fresh input/15,442 output and returned `needs-fix` with four blockers. STOP held the inbox until the packet/audits were quarantined at 02:44:43Z. | Primary/paired results, `paired-audit.json`, quarantine manifest SHA-256 `af62da87fa1f925151343b01a4e35047bd25a8df8342850b0a3b633ef7b93f27`, candidate ref |
| 2026-08-14T02:35:29Z–02:39:40Z | `RUN-20260814T022422Z-15249` attempt 1 | Fresh amended TASK-0115 first implementation/audit | Candidate `f89692bb13754ad18e6c92233980a6aa3759d44d` passed its 20,227ms gate and three raw-green verifier reruns. The auditor correctly returned `needs-fix`: the RED stopped because the new helper was absent rather than proving baseline behavior, the eight-loop behavioral golden was missing, and the live attacker matrix was incomplete. Fresh audit input was 73,767; output was 8,045. Policy selected one resumed product retry. | Attempt-1 archive, audit SHA-256 `6e3b554af31212dea84188e26351c9587124ee8f34ed994ca494ce0963b758c7`, runner result, gate evidence |
| 2026-08-14T02:39:41Z–03:10:54Z | same run, attempt 2 | TASK-0115 resumed implementation/audit terminal handoff | Resumed candidate `032a32c018d8d83c1702991fdbda115b94ab8bca`/tree `6ad309c3f20dc57b7ca36f873b465a662c7093b0` passed its 78,562ms gate and three more raw-green verifier reruns. The auditor accepted using 73,357 fresh input/11,283 output, but missed that the retry RED was post-production and sentinel-driven and that signed control changes Codex's timeout-0 path. Final refresh correctly summed primary auditor input-minus-cache only, `73767 + 73357 = 147124 >= 100000`, and terminalized `audit-infra`; output remained separate. No accepted/inbox packet or paired audit followed; the needs-review root packet remains evidence only. | Attempt-2 archive, final audit SHA-256 `eaf5c4bdb87ae4106f8991476650d2d69d343f6a9db542a1d0fc87ef7bc8d039`, failed-refresh log, run status, candidate ref |
| 2026-08-14T03:15:00Z | fresh-wave operator-proxy disposition | All three L1 processes terminal; STOP retained | Rejected all three outputs as integration inputs. TASK-0110/TASK-0116 accepted packets remained recoverably quarantined; TASK-0115 had no accepted or inbox packet, and its needs-review root remained evidence-only. Exact heads were pinned under create-only operator-candidate refs, task contracts were re-amended for the escaped proofs, and no import, integration, gate promotion, push, or release action occurred. | Top decision entry, quarantine manifests, three candidate refs, amended task/DAG state |
| 2026-08-14T04:06:12Z | FR-050/FR-052 operator-overlay checkpoint | One-file v3 runtime independently verified and recursively frozen; not activated | Predecessor canaries reproduced both stale accepted-packet binding and import of a secret-bearing inbox after root quarantine. V10 then passed 14/14 clean/secret/scanner-source/stamp/refresh/binding/interruption cases; the exact-byte six-suite compatibility run passed. The 300-entry overlay differs from frozen rel-01-v2 only at executable `engine/l1-drive.sh`; all 301 filesystem objects are `uchg`. Installed defaults, config, symlinks, tracked paths, predecessor bytes, and activation records remained unchanged. | Overlay l1 SHA-256 `ebec05d7...`; bundle `79d255df...`; metadata `71c08fd0...`; V10 summary `cf1cd004...`; post-freeze verification `53cd2874...` |
| 2026-08-14T04:15:47Z–04:38:28Z | `RUN-20260814T041625Z-15168` | Fresh TASK-0110 reset and acceptance under the per-process v3 overlay | Exact base `9487683176cd5a93abddae9ffdce9b84532e0ac2`/tree `949e77752af11ca4ba277b14203a50405fb86cf3` produced candidate `7ca9c5c14a5816516c4d9769241e8c87f29122ee`/tree `4143c92c9bc40ca839a937eeb8fcbe800ba2acb9` in exactly the three owned paths. A genuine stale-output RED preceded the exact two-line production cleanup; the synchronized sibling-writer harness proved ready, overlap with both archive calls, final write, exact count, and zero exit. The 38,299ms host gate and all three raw verifier gates were green; the known missing strict-observation artifact selected hash-bound `not-rerun-evidence-verified`. Primary audit accepted at 79,338 fresh input. V3 then bound root, manifest, and inbox to packet SHA-256 `264577d68716db44262779dd1ea1d19b511aa5cba7da0d3840b52f99d6bbfcc9`. STOP was restored at 04:28:25Z. After config load, the operator forced paired sampling from 25% to 100%; the fresh pass completed at 04:38:28Z and accepted with no findings and agreement, using 115,981 fresh input and 12,250 output. Its read-only local gate rerun was inconclusive because `mktemp` was denied, so it accepted the exact SHA-bound host gate evidence instead. No import or reconcile ran; the exact candidate was pinned at `refs/singular/operator-candidates/TASK-0110/RUN-20260814T041625Z-15168-attempt-1`; the hash-binding record completed at 04:40:33Z. | Run gate/RED/GREEN/regression/audit/manifest evidence; paired binding record SHA-256 `7020332ce3aa9e415232c174df58eb30724d34769415cd6f50280192f342fed4`; paired raw/result/summary/envelope SHA-256 `8aa7ca1a...` / `f333205c...` / `7fadb975...` / `4fecb7b0...` |
| 2026-08-14T04:12:04Z | tracked recovery-contract checkpoint | Contract audit PASS; control branch clean except this report | Committed the independently audited rel-02/rel-05/rel-06/rel-07/rel-08/rel-99 recovery amendments, DAG ownership, plan, and counter-decisions as `03a66438`/tree `b8fba8c2`. The contract now covers native/waiver/existing-packet finalization, STOP-safe reset-only cleanup, frozen-base run-control proof, literal reviewer `probe`, and paired-audit operator disposition. STOP remained present; no inbox, activation, rerun, import, integration, or promotion occurred. | Commit `03a66438d24431fb62427b336aeabd68df2b3019`; final amendment audit; DAG/task/parser/layout/planning/diagnostic checks |
| 2026-08-14T04:47:50Z–04:49:16Z | TASK-0110 acceptance/import checkpoint | Exact accepted packet and audit imported under STOP | Committed the acceptance/report evidence as `b042f8c4`, then native reconcile imported packet SHA-256 `264577d6...` and audit SHA-256 `40cb23e2...` byte-for-byte in control commit `72726cee`; inbox became empty and task/lease remained accepted. | Control commits, imported packet/audit, root packet and manifest binding |
| 2026-08-14T04:51:00Z–05:13:05Z | `ORIGIN-20260814T045100Z-TASK0110-NATIVE` | First native TASK-0110 integration failed closed at 194/195 | The exact staged merge retained expected three-path tree `38df7285...`; TASK-0110's two candidate tests passed and source integrity was verified with `changedPaths=[]`. Only `test-console-server.sh` failed: verbose replay identified `CollectHomeTests.test_empty_repo_zeros_ok`, where the Data volume rounded to 99% and correctly returned health `watch` instead of expected `ok`. Integration aborted with HEAD `72726cee`, no merge/index residue, STOP present, and one decider-authored rerun decision. | Gate log/report SHA-256 `110d1b9e...` / `da9a377e...`; failed method replay; exact abort-state audit |
| 2026-08-14T05:13:05Z–05:26:33Z | operator environmental recovery | Disk-watch precondition restored without product changes | Removed only 3,787 abandoned synthetic engine-test fixture directories under the user TMPDIR (1,017,040 KiB; two target-manifest SHAs `4b126b0f...` and `28e49dfc...`). Zero selected fixtures remain; unrelated Axon/Spokit/EAS/browser/cache roots, videos, Git/control state, packets, events, and frozen overlays were independently verified intact. The application capacity metric became 98%; an isolated verbose rerun passed all 275 console tests in 17.470s, including the exact former failure. | Ignored cleanup record SHA-256 `96239033...`; console log SHA-256 `53777ccd...`; independent cleanup audit |
| 2026-08-14T05:32:40Z–05:55:27Z | `ORIGIN-20260814T053240Z-TASK0110-NATIVE-R2` | Native TASK-0110 integration retry completed | Exact pre-head `3a104dce` staged only the accepted three paths and produced expected tree `923a88ca445c0684f66905f9ee8ab0cb3f483baf`. The supported gate passed 195/195 in 1,323,329ms; `test-console-server.sh` and both TASK-0110 tests passed, source integrity was `verified` with `changedPaths=[]`, and final application capacity rounded to 98%. A single read-only guard sample briefly rounded to 99% later in the suite, but no gate/control/source drift occurred and the metric returned to 98%. Merge `1b69af277f96f3f1b5cf3c904abebddfa4074469` has parents `[3a104dce,7ca9c5c1]`, exact tree `923a88ca...`, and exact three-path first-parent delta. | Gate log/report SHA-256 `8646d137...` / `65710a7d...`; merge object; source snapshots; terminal guard audit |
| 2026-08-14T05:59:43Z–06:21:45Z | `ORIGIN-20260814T055942Z-33888` | `rel-02-try-hygiene` promoted authoritatively | At clean checkpoint `93b13a47`/tree `2f30b30f`, the configured promoter SHA-256 `53cf46c8...` ran a fresh `bash tests/run.sh`: 195/195 passed, including console and both TASK-0110 regressions. Gate-result v1 is `passed`, `authoritative`, and `deterministic-proof`; task set is exactly TASK-0110, upstream exactly rel-01, source/task/log/report hashes match, and both `singular gate validate` and `singular area-gate` passed. The disk metric briefly crossed the rounding boundary during L1 tests and ended at 98.512% (rounded 99), but no gate/control/source binding failed. STOP and the empty inbox remained intact. | Regression/observation/report/result SHA-256 `8646d137...` / `dde079fb...` / `7bcda6c2...` / `842bbd60...`; validation outputs; guard audit |
| 2026-08-14T04:13:28Z | v3 per-process activation preflight | Frozen overlay selected without persistent default/config change | At clean head `2f0d5e62`, repeated frozen verification and L1 syntax, version, DAG validation, and read-only status all passed through the exact overlay environment. HEAD, tracked status, STOP, inbox, and authoritative events remained byte-identical. Existing-packet auto-heal is forced OFF until permanent rel-05; no task was unparked or run. | Activation record SHA-256 `4da4846e...`; status output `3998a3d0...`; frozen verification output `99d30ccb...`; unchanged event SHA `61ed7dd3...` |

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

- First seen: 2026-08-13T17:08:15Z; frequency: 26 full-history scans through the first autonomous wave.
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
  again for `ORIGIN-20260813T182615Z-70987`, then 107 more in each of 16 distinct first-wave origins from
  `ORIGIN-20260814T010413Z-73798` through `ORIGIN-20260814T011342Z-62886`: 2,782 redundant events/lines
  in total. The current corpus contains 109
  product packets plus 109 audit sidecars; TASK-0108 and TASK-0109 are integrated terminal packets and did
  not emit the historical branch-already-merged line in those automatic iterations. Explicit `--task`
  integration retries correctly skipped the historical scan.
- Operator cost/action: roughly 17 seconds and 107 lines/events per general cycle at current history size;
  no state deletion was attempted because the packets are tracked provenance.
- Resolution: open for a future sprint.

### FR-011 — running-worker telemetry is phase-skewed at both launch and terminal handoff

- First seen: 2026-08-13T17:08:35Z; frequency: both launch and first terminal handoff, plus the first successor
  launch completion (1/16; all 16 expose that the field has pre-dispatch semantics).
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
  `ORIGIN-20260813T171401Z-29802`, the 17:14:44 `origin.dispatch_reaped` event, TASK-0108 lifecycle events,
  and the 16-origin completion-event slice from `ORIGIN-20260814T010413Z-73798` through
  `ORIGIN-20260814T011342Z-62886`. The first successor completion recorded
  `workersRunning=0` immediately after launching three detached workers; the next 15 recorded
  `workersRunning=3`.
- Operator cost/action: one manual PID and health check before starting auto.
- Resolution: open for a future sprint.

### FR-012 — host audit reruns a passing gate three times because strict observations are absent

- First seen: 2026-08-13T17:11:36Z; frequency: 48/48 disposable verification tries across sixteen audited
  attempts (TASK-0108 once, TASK-0109 seven times, TASK-0110 once, TASK-0115 four times, and TASK-0116 three
  times). Every three-try group was entirely green and still
  fell back to evidence-only verification.
- Classification: new; severity: high for expensive gates; impact: degraded cost and audit evidence; did not
  itself block this task.
- Symptom: each authored task gate passed on all three host reruns, but every normalization failed with
  `gate-report: strict gate observation missing`. The engine classified this structural report mismatch as
  retryable verification infrastructure, reran the same passing command twice more, then used an
  evidence-only fallback. TASK-0109 reproduced this identically before all six of its audits across three runs.
- Expected: an ordinary authored gate command is adapted into the strict observation contract once, or its
  first successful hash-bound result is reused. Missing structural metadata must not trigger three complete
  deterministic gate executions.
- Code anchor (0.18.0): retry/fallback loop at `engine/l1-drive.sh:1237-1310`; strict normalization check at
  `engine/audit-verify.sh:378-387`.
- Evidence: TASK-0108's `audit-verification-1-{0,1,2}.log`; TASK-0109's
  `RUN-20260813T203430Z-96335/audit-verification-{1,2}-{0,1,2}.log` and
  `RUN-20260813T211009Z-78320/audit-verification-{1,2}-{0,1,2}.log` and
  `RUN-20260813T213939Z-24911/audit-verification-{1,2}-{0,1,2}.log` and
  `RUN-20260813T221358Z-8581/audit-verification-2-{0,1,2}.log`; TASK-0115 attempts 2/3 and TASK-0116
  attempts 1/2 under the first-wave run roots; and all four audited attempts under fresh runs
  `RUN-20260814T022422Z-{15250,15249,15254}`; matching normalization errors. Every first-wave error has
  SHA-256 `c5938eec90b6280613edebc25b0b10ae3b6f11b9496107005173635435798a7f`.
- Operator cost/action: about six seconds for TASK-0108, then roughly 39 seconds on TASK-0109 attempt 1 and
  66 seconds on its strengthened attempt 2. The amended retry added about 40 and 43 seconds for attempts 1
  and 2. The seed-restored run added about 75 and 77 seconds for attempts 1 and 2. All three TASK-0109 host
  executions in every group were redundant with the already-green worker gate. The literal-contract run added
  about 417 seconds for one three-try group, and reviewer input remained only evidence-verified. The
  successor-runtime wave added about 146 seconds from already-green worker gates to evidence-only verification:
  TASK-0116 attempts 1/2 took 18s/16s and TASK-0115 attempts 2/3 took 48s/64s.
  The amended wave added another 416.7 seconds of raw repeated gate runtime: three runs each of the
  4,112ms TASK-0116 gate, 36,252ms TASK-0110 gate, 20,227ms TASK-0115 attempt-1 gate, and 78,562ms TASK-0115
  attempt-2 gate. All twelve were green before normalization rejected the absent strict observation.
- Resolution: open for a future sprint.

### FR-013 — the prescribed bounded evidence reader is unusable in the Codex auditor sandbox

- First seen: 2026-08-13T17:12:38Z; frequency: 16/16 primary audited attempts that invoked bounded retrieval
  (TASK-0108, all seven TASK-0109 audits, four first-wave successor audits, and four amended-wave audits).
- Classification: new environment/engine interaction; severity: medium; impact: degraded audit access and
  annoyed; non-blocking only because the auditor worked around it with direct reads.
- Symptom: `evidence-show.sh` failed while reading `packet.json` with `PermissionError: [Errno 1] Operation
  not permitted` on `/tmp/singular-evidence-retrieval-v0/<sha>.lock`. Repeated Git calls also emitted macOS
  `confstr`/xcrun cache-write warnings for `/tmp/xcrun_db-*` although Git itself succeeded.
- Expected: the evidence helper advertised to a sandboxed reviewer uses a writable per-run lock/cache path,
  and routine read-only Git evidence commands do not flood the reviewer transcript with host cache errors.
- Code anchor (0.18.0): installed `engine/evidence-show.sh` temporary retrieval lock; auditor prompt/tool
  contract assembled by `engine/l1-drive.sh`.
- Evidence: TASK-0108, all three TASK-0109 run roots, both first-wave successor run roots, and all three
  amended-wave run roots' auditor logs and verdict rationales. Every reviewer recorded the read-only
  cache-lock failure and used immutable Git/manifest inspection instead.
- Operator cost/action: every audit had to fall back to raw/direct inspection, expanding context and weakening
  the intended bounded-evidence boundary. TASK-0109's reviewers still completed valid direct hash/diff checks.
- Resolution: open for a future sprint.

### FR-014 — Codex model-cache schema mismatch produces repeated non-fatal provider errors

- First seen: pre-launch Doctor; frequency: 108 cache load/renew errors across the first four worker/auditor
  runs. The seed-restored TASK-0109 run added 20 unique root-artifact occurrences (11 implementer, eight
  primary reviewer, one paired-review envelope) to the prior 88.
- Classification: new compatibility near-miss; severity: low; impact: degraded provider signal / annoyed;
  non-blocking in this run.
- Symptom: Codex CLI 0.145.0 reads a cache written for 0.147 and repeatedly reports a missing
  `base_instructions` field. Doctor warns about the newer cache; both model calls nevertheless completed.
- Expected: an older client ignores or safely refreshes an incompatible cache once, and Doctor distinguishes
  a noisy recoverable mismatch from an execution risk.
- Code anchor: Codex client model-cache loader; no Singular source anchor identified.
- Evidence: real-environment Doctor warning plus implementer and auditor logs under the TASK-0108 and
  TASK-0109 run roots; every diagnostic names missing `base_instructions` at the same cache location.
- Operator cost/action: inspected authentication/model availability and confirmed the provider results rather
  than mutating user-level Codex state during a live run.
- Resolution: tolerated; open compatibility friction.

### FR-015 — completed audit is terminalized as infrastructure failure by hard token-canary accounting

- First seen: 2026-08-13T17:14:03Z; frequency: 6 final-refresh failures—five audits that returned
  `accepted` at a task-final handoff plus one `needs-fix` handoff; classification: new reproduction of the
  terminal handoff/budget failure family targeted by this sprint.
- Severity: critical; impact: blocked the entire DAG first at `rel-00-contract`, then blocked TASK-0109 after
  the bootstrap recovery had advanced the serial lane.
- Symptom: TASK-0108's worker committed the correct owned file, its gate passed, and the Codex auditor returned
  `accepted` with zero findings. The subsequent evidence-manifest refresh exited 4 because reviewer usage was
  `283064 >= 100000`; `l1-drive.sh` changed the successful audit into `audit-infra`, and policy parked the task
  as `escalate-infra`. No packet, integration, or gate promotion followed.
- TASK-0109 reproduced the same terminal reversal under the activated provider-correct overlay. Attempt 1's
  auditor correctly returned `needs-fix`; attempt 2's auditor accepted the repaired exact head `08bcb2b0`.
  Both individual Codex reviewers were under the limit at 76,916 and 62,600 fresh input, but the final refresh
  summed them to `139516 >= 100000`, reclassified the accepted result as `audit-infra`, and parked the task.
- The amended retry reproduced it again. Its first auditor rejected `6fd30118` using 539,600 raw / 456,704
  cached / 82,896 fresh input and 9,236 output tokens. Its second auditor accepted `ed8fc1bc` using 523,462 /
  454,656 / 68,806 / 6,388, then final refresh summed the two fresh charges to `151702 >= 100000` and parked it.
- The seed-restored retry was the first needs-fix cycle to fit: reviewers used 292,561/244,736/47,825/6,362
  and 364,627/318,976/45,651/7,266 raw/cached/fresh/output. Their cumulative 93,476 stayed below 100,000,
  final refresh succeeded, and the engine accepted the packet normally. Independent product review—not the
  canary—later caused its quarantine.
- The first successor-runtime wave added both terminal shapes. TASK-0116's two reviewers used 52,782 and
  48,520 fresh input; the second accepted the corrected artifact-routing candidate, but final refresh rejected
  `101302 >= 100000` and terminalized it as `audit-infra`. TASK-0115's attempt-2 and attempt-3 reviewers used
  83,297 and 94,763 fresh input; the second correctly returned `needs-fix`, yet final refresh still rejected
  `178060 >= 100000` and replaced the product disposition with `audit-infra`. Reviewer output—TASK-0116's
  7,697 + 6,217 and TASK-0115's 14,109 + 10,905—remains separate from the input canary.
- The amended direct wave produced two below-canary primary audits and one repeat reversal. TASK-0116 used
  269,708 raw / 217,088 cached / 52,620 fresh input plus 5,291 output; TASK-0110 used
  332,033 / 273,408 / 58,625 plus 7,401. Both final refreshes succeeded, though both accepted packets were
  later quarantined for proof defects. TASK-0110's sampled paired auditor was post-acceptance and outside the
  primary policy canary; it separately used 1,511,728 / 1,274,112 / 237,616 input plus 15,442 output and found
  four blockers. TASK-0115's primary reviewers used 463,655 / 389,888 / 73,767 / 8,045 and
  399,501 / 326,144 / 73,357 / 11,283 raw/cached/fresh/output. Final refresh summed only their input-minus-cache,
  `147124 >= 100000`, and again reversed an accepted verdict to `audit-infra`; the 19,328 output total stayed
  separate.
- Expected: durable accounting cannot reverse an accepted verdict into a terminal infrastructure park.
  Budget enforcement must use the intended quantity and provide a supported recovery/remedy path.
- Code anchor (0.18.0): hard defaults/max and bounded config in `engine/evidence-manifest.sh:55-87`; cumulative
  runner-result summation and exit at `:431-459`; post-verdict reclassification at
  `engine/l1-drive.sh:1674-1687`. The schema also caps `auditInputTokenCanary` at 100,000.
- Budget evidence: auditor input 283,064, cached input 244,736, output 5,713; fresh input delta was only 38,328.
  Implementer input 438,115, cached 390,912, output 8,119. Total provider usage was 721,179 input, 635,648
  cached, and 13,832 output; total fresh-input delta 85,531. The successful audit took about 2m15s.
- TASK-0109 budget evidence: attempt 1 implementer raw/cached/fresh/output was
  2,221,136/2,121,472/99,664/15,992; attempt 1 auditor 546,164/469,248/76,916/8,857; resumed attempt 2
  implementer 3,825,524/3,623,936/201,588/24,566; fresh attempt 2 auditor
  465,544/402,944/62,600/6,793. All four calls completed with Codex `gpt-5.6-sol`; no mid-run budget raise was
  requested or available. Raw input across the four calls was 7,058,368, of which 6,617,600 was cached.
- Amended-retry implementer attempt 1 was 2,244,161/2,153,472/90,689/14,063; resumed attempt 2 was
  4,091,847/3,893,760/198,087/25,792. Across its four role calls, raw/cached/fresh/output totals were
  7,399,070/6,958,592/440,478/55,479. No mid-run raise was requested or available.
- Seed-restored implementer attempt 1 was 1,622,737/1,553,664/69,073/19,331; resumed attempt 2 was
  2,441,469/2,312,448/129,021/25,596. Its four primary calls totaled
  4,721,394/4,429,824/291,570/58,555. The sampled paired auditor separately used
  397,886/315,392/82,494/8,150.
- Evidence: the six affected run roots' `audit.json`, `attempts/index.json`, `run-status.json`,
  `evidence-manifest-final-refresh.log`, and per-role runner-result JSON files. TASK-0109's final refresh states
  the corrected cumulative values exactly: `139516 >= 100000` and `151702 >= 100000`; the first-wave logs
  state `101302 >= 100000` and `178060 >= 100000`; amended TASK-0115 states `147124 >= 100000`.
- Operator cost/action: diagnosed before any unpark and stopped auto. A provenance-bound recovery copied the
  original run byte-for-byte, reran its successful commands at exact head `3fffc636`, and accepted/imported
  `RUN-20260813T182550Z-RECOVERY-TASK-0108-12256` without a new model call. Imported packet/audit hashes are
  `9d6a4470...` and `62c15ef4...`.
- Resolution: TASK-0108 was operationally recovered; both TASK-0109 canary parks were recovered without a
  new model call, but their packets were later quarantined for independent product-evidence findings and
  the third TASK-0109 run demonstrated that a two-review cycle can fit when cumulative fresh input is 93,476.
  TASK-0109 nevertheless remains blocked on product proof. The immutable overlay
  activated for TASK-0109 and proved the provider-correct charging rule works, while also demonstrating that
  a fixed cumulative-across-attempts hard bound can still reverse an accepted retry even when every reviewer
  call fits individually. The permanent accounting/remedy work remains bound to TASK-0113/TASK-0114. Evidence:
  `.singular-state/operator-engine-overlay-records/singular-0.18.0-canary-codex-cache-v1-8de32121/`.

### FR-016 — failed final refresh leaves a stale, apparently valid evidence manifest

- First seen: 2026-08-13T17:14:03Z; frequency: 6/6 final-refresh failures.
- Classification: new; severity: high; impact: degraded/misleading evidence; blocking recovery.
- Symptom: `evidence-manifest.json` remains the pre-audit snapshot with `actualAuditInputTokens: 0`, only
  implementer usage, no audit/auditor artifacts, and the hash of the earlier 5,011-byte packet. The current
  post-audit packet is 5,343 bytes with a different hash. The manifest carries no internal invalidation marker.
- TASK-0109's surviving manifest is likewise the pre-attempt-2-audit snapshot: it reports
  `actualAuditInputTokens: 76916` and provider totals through the second implementer, while omitting the
  accepted second auditor whose fresh input raised the cumulative value to 139,516. It remains syntactically
  valid and carries no marker that `evidence-manifest-final-refresh.log` rejected it.
- The amended retry repeats the stale shape: its surviving manifest reports 82,896 actual audit input and
  provider usage only through the resumed implementer, omitting the accepted second auditor that raised the
  true cumulative charge to 151,702.
- TASK-0116's surviving manifest likewise omits the second accepted reviewer that raised the true charge to
  101,302. TASK-0115's surviving 01:37 manifest reports only 83,297 fresh audit input and binds the superseded
  attempt-2 audit, while the current attempt-3 `needs-fix` audit and the true 178,060 cumulative charge exist
  only in the later role result, audit, and failed-refresh log.
- Fresh TASK-0115 repeats the same stale-valid shape. Its surviving manifest reports only attempt-1 audit input
  73,767, binds superseded attempt-1 audit SHA-256
  `6e3b554af31212dea84188e26351c9587124ee8f34ed994ca494ce0963b758c7`, and omits the accepted attempt-2 audit
  `eaf5c4bdb87ae4106f8991476650d2d69d343f6a9db542a1d0fc87ef7bc8d039` plus the true 147,124 canary. The
  stale manifest itself is `d7f7cba4f0b4079ff26db6984dab97176a64662e38151afb86641bcaa9db99a0`.
- Expected: a failed final refresh either atomically invalidates/removes the pre-audit manifest or leaves an
  explicit status that no consumer can mistake for final evidence.
- Code anchor (0.18.0): pre-audit/final-refresh lifecycle in `engine/l1-drive.sh:1677-1687` and manifest write
  sequence in `engine/evidence-manifest.sh`.
- Evidence: current `packet.json`, `evidence-manifest.json`, `audit.json`, and final-refresh log in
  `RUN-20260813T170836Z-93780`, `RUN-20260813T203430Z-96335`, `RUN-20260813T211009Z-78320`,
  `RUN-20260814T010432Z-76945`, `RUN-20260814T010432Z-76911`, and
  `RUN-20260814T022422Z-15249`.
- Operator cost/action: consumers must cross-check terminal state and refresh log rather than trusting the
  manifest alone. Before recovery, all 76 source-run files were preserved in
  `.singular-state/recovery-snapshots/RUN-20260813T170836Z-93780/20260813T182550Z/`. Key original hashes are
  packet `d356c461...`, audit `5d0a7338...`, stale manifest `711f2a0e...`, and refresh failure `aeda0b38...`;
  recovery provenance/manifest hashes are `87a363bb...` and `f63733c1...`.
- Resolution: unresolved.

### FR-017 — attempt archive omits the artifacts needed to diagnose an audit-infra terminal

- First seen: 2026-08-13T17:14:03Z; frequency: 7/7 archived product attempts (TASK-0108 once, TASK-0109 six times).
- Classification: new/broader evidence-retention defect adjacent to the known per-try log-loss issue;
  severity: high; impact: degraded evidence and unsafe retry/GC exposure.
- Symptom: each attempt directory copied the compatibility worker log but omitted `auditor-codex.log`, role
  runner-result JSON files, raw provider envelopes, verification artifacts, and the final-refresh failure.
  They survive only at the run root. TASK-0109's active controller was still the old 0.18.0 runtime, so both
  attempt directories contain only the legacy subset even though both worker candidates expand the future copy set.
- Expected: the attempt archive is self-contained for every artifact that determined the terminal outcome,
  especially the accepted verdict and the accounting failure that later overrode it.
- Code anchor (0.18.0): copy selection in `engine/lib.sh:6567-6618`; TASK-0109 changes this function on its
  unintegrated worker branch.
- Evidence: all seven attempt directories, their run roots, and all three TASK-0109 runs' runner-result/envelope sets.
  TASK-0109 attempt 1's archived worker log did preserve its exact 303,036 bytes (SHA-256 `e72b0ca1...`) before
  attempt 2 truncated the root compatibility log to a new 49,556-byte stream, but none of its reviewer or
  accounting sidecars were co-located with that archive.
- Operator cost/action: STOP was retained and complete run roots were preserved. TASK-0108 was separately
  snapshotted; TASK-0109 must not be garbage-collected before deterministic recovery.
- Resolution: implementation remains unintegrated; the latest accepted candidate was quarantined after its
  exact-contract proof regressions were found.

### FR-018 — park guidance says the gate could not run although it passed four times

- First seen: 2026-08-13T17:14:03Z; frequency: 3/3 `audit-infra` terminal parks.
- Classification: new observation of overloaded `audit-infra`; severity: high; impact: degraded/unsafe
  operator guidance.
- Symptom: `docs/orchestration/decisions.md` tells the operator that the workspace could not run the gate and
  to repair the environment then unpark. The gate passed once for the worker and three times for the host;
  the actual failure was post-audit token accounting. Following the advice would discard/recreate work and
  probabilistically repeat the same failure.
- TASK-0109 received the same advice after its authored gate passed on both product attempts and six more
  times during host verification. Its actual failure was the corrected cumulative token canary after an
  accepted audit, so “repair the environment, then unpark” is again causally wrong.
- The amended retry repeated the same advice after two more worker passes and six more green host executions;
  the actual terminal cause was `151702 >= 100000`.
- Expected: park rationale reports the precise failing phase/artifact and recommends only recovery actions
  that can address that failure class.
- Code anchor (0.18.0): final-refresh mapping at `engine/l1-drive.sh:1681-1687` and audit-infra fast-path
  decision/bootstrap text.
- Evidence: the first decision block for each task, both sets of gate logs, accepted audits, and final-refresh
  logs. TASK-0109's terminal decision is at the top of `docs/orchestration/decisions.md`.
- Operator cost/action: manual forensic correction; no blind unpark. STOP remains while a deterministic
  exact-head recovery is prepared.
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

- First seen: pre-launch configuration verification; frequency: three distinct override failures or
  near-misses (provider selection, integration gate selection, and TASK-0109's low-disk fixture).
- Classification: launch configuration near-miss; severity: high for provenance; impact: potentially degraded
  provider compliance; mitigated before actuation.
- Symptom: `singular.config.json` still specifies `runner: claude-run.sh`; its Codex model/effort variables are
  inert under that runner. A one-shot `SINGULAR_RUNNER` prefix is overwritten when JSON is loaded. The same
  precedence trap affected a one-shot `SINGULAR_DEFAULT_GATE_CMD`: integration
  `ORIGIN-20260813T190852Z-60011` started committed `bash tests/run.sh` instead of the intended bounded
  exact-tree adapter. During TASK-0109, its low-disk fixture's process-local `SINGULAR_PROMOTER` was similarly
  overwritten by the inherited live `SINGULAR_LOCAL_CONFIG_FILE`, so the fixture initially invoked the
  sprint promoter instead of its stub and reported the synthetic node unregistered.
- Expected: the committed execution config names the provider intended for the sprint, or the CLI clearly
  reports the final effective provider before dispatch.
- Code anchor (0.18.0): increasing-precedence config load in `engine/lib.sh` (JSON, shell config, then local
  config) and runner dispatch.
- Evidence: committed `singular.config.json`, `.singular-state/config.local.sh`, both role session/result
  records, the 32,226ms aborted integration gate, and TASK-0109 attempt 1's worker log/diff. The worker made
  the fixture deterministic by rebinding all three config-file paths to its synthetic repository.
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
- Resolution: fixed by exact TASK-0109 candidate `b874a874`, integrated in merge `9d9c41f2`, and exercised
  by both green 195/195 integration and promotion suites.

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
- Resolution: diagnosis and permanent acceptance criteria were committed in `e0c15c9f`; the repeated
  ten-cycle bounded-drain fix landed in exact TASK-0109 merge `9d9c41f2` and passed both 195/195 suites.

### FR-027 — promotion gate report drops duration, integrity, and wrapper-manifest binding

- First seen: 2026-08-13T20:27:09Z; frequency: 2/2 `rel-*` promotions.
- Classification: new evidence near-miss; severity: high; impact: degraded proof fidelity; promotion itself
  remained independently inspectable and exact-head green.
- Symptom: the promotion wrapper ran from 20:04:59Z to 20:27:07Z, verified candidate-clean source integrity,
  and wrote a detailed operator manifest at head `41380c1b`/tree `4915b69a`. The authoritative gate report,
  however, records `durationMs: 0` and `sourceIntegrity.status: not-checked`. The gate result hash-binds the
  suite log and gate report but neither references nor hashes the operator manifest that contains the missing
  facts. The native rel-01 promoter repeated the telemetry loss: promotion events prove 2,959s elapsed at
  exact head `9c1f2e7b`, while its strict report again records `durationMs: 0` and
  `sourceIntegrity.status: not-checked`; read-only supervision independently froze HEAD/tree/index/STOP.
- Expected: the normalized report carries real elapsed duration and terminal integrity, and the authoritative
  gate evidence binds the wrapper manifest (including exact head/tree, start/end, summary, and exception).
- Code anchor: local promoter/adapter boundary in `.singular-state/operator-promotion-gate.sh`, direct command
  execution in `.singular-state/reliability-promoter.sh:1831-1854`, and strict normalization without duration
  or integrity arguments at `:221-280`.
- Evidence: `.singular-state/operator-promotion-proofs/rel-00-contract/20260813T200459Z-26026/manifest.json`,
  `docs/orchestration/gates/evidence/rel-00-contract.gate-report.json`, and
  `docs/orchestration/gates/rel-00-contract.gate-result.json`; rel-01 promotion events and
  `docs/orchestration/gates/evidence/rel-01-per-try-logs.gate-report.json`.
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

### FR-029 — focused archive test leaks synthetic lifecycle events into the live driver log

- First seen: 2026-08-13T20:42:23Z; frequency: eight escapes in the first eight TASK-0109 gate executions;
  zero new escapes in the next 16 executions across two amended runs. The authoritative count remains eight.
- Classification: new test-isolation defect and audit near-miss; severity: high; impact: blocked integration
  and degraded durable telemetry/provenance; unsafe to treat as genuine lifecycle history.
- Symptom: the real `.singular-state/events.ndjson` gained eight fabricated `l1.attempt_archived` events for
  `taskId=TASK-0109`, `runId=resume-run`, attempt 1, `failureClass=worker-infra`, verdict `unknown`. No such
  real run or infra failure occurred. The timestamps are 20:42:23, 20:42:37, 20:42:50, 20:43:03, 20:50:31,
  20:50:54, 20:51:18, and 20:51:42Z.
- Expected: focused fixtures bind every state/event output to their temporary root and cannot append synthetic
  lifecycle records to the supervising repository, regardless of inherited `SINGULAR_*` variables.
- Code anchor at worker head `08bcb2b0`: `tests/test-per-try-artifacts.sh:67` stubs
  `singular_append_event`, but `:145` later sources `engine/lib.sh`, overwriting that stub while the live
  `SINGULAR_STATE_DIR` remains inherited; `:158` calls `singular_attempt_archive`. The real implementation
  resets the events path at `engine/lib.sh:201` and emits at `:6653-6655`.
- Evidence: `.singular-state/events.ndjson` entries 1184, 1188, 1190, 1192, 1202, 1206, 1208, and 1210;
  TASK-0109 gate/verification timestamps; and the accepted six-file worker diff.
- Operator cost/action: identify and quarantine the eight records mentally during event/health analysis; no
  live log was rewritten or deleted. The attempt-1 auditor caught four important coverage gaps but did not
  catch this test isolation problem, and the attempt-2 auditor accepted the revised head with it still present.
- Resolution: exact behavioral containment is now natively accepted at `b874a874`: the fixture invokes the
  production archive helper exactly twice in one process against distinct roots, checks the literal incoming
  caller checkout/state/event inventories after each iteration and a bounded final drain, and produced no ninth
  fake event. The eight historical fake events remain immutable evidence and must be filtered by exact identity.

### FR-030 — exact-head deterministic acceptance cannot detect prior host-state leakage

- First seen: 2026-08-13T21:04:20Z; frequency: 2/2 TASK-0109 deterministic acceptance runs that completed.
- Classification: new evidence-boundary near-miss; severity: high; impact: blocked integration until operator
  review. The acceptance mechanism behaved as authored but its isolation boundary cannot prove absence of a
  side effect that occurred earlier in the supervising checkout.
- Symptom: exact-head reruns, scope, secrets, gate commands, clean merge-tree checks, and deterministic audit
  all passed for `08bcb2b0`, so `accept-existing-packet.sh` accepted it. Those reruns used disposable state and
  therefore could not reproduce or discover the eight authoritative event-log writes made by the original L1
  worker/host executions. The recovered packet reached the imported directory before a separate forensic
  review countermanded it; STOP prevented integration.
- Expected: recovery readiness surfaces unresolved operator findings and external-state deltas associated with
  the source run, or requires an explicit disposition for them before publishing an accepted import.
- Code anchor: exact-head disposable worktree/state preparation and command reruns in
  `engine/accept-existing-packet.sh:200-466`; import publishes after packet-local validation in
  `engine/import-packet.sh:82-101`.
- Evidence: source event lines and hashes from FR-029; recovery runs
  `RUN-20260813T210149Z-RECOVERY-TASK-0109-27742` and
  `RUN-20260813T210341Z-RECOVERY-TASK-0109-29558`; recovery provenance; quarantine manifest.
- Operator cost/action: first recovery stopped because a successful command depended on an uncopied RED log;
  the second preserved that expected-failure artifact and passed. Operator then revoked acceptance, moved the
  packet/audit intact to recoverable quarantine, preserved the candidate ref, and amended the task/DAG.
- Resolution: contained for this run. A general recovery contract should bind source-run external-state
  findings and their dispositions rather than relying only on candidate-tree re-execution.

### FR-031 — no supported verb revokes or quarantines an accepted imported packet

- First seen: 2026-08-13T21:05:30Z; frequency: 3/3 accepted packets requiring pre-integration revocation.
- Classification: new operator-control friction; severity: medium; impact: degraded/near-miss, with STOP as the
  only reason the weak packet could not race into integration.
- Symptom: `singular supersede` quarantines inbox packets only by burying the whole canonical task, while
  `singular unpark` resets a task for retry but does not revoke an already imported packet. There is no
  task-preserving `packet quarantine/revoke` operation for an accepted import discovered unsafe before merge.
- Expected: an audited, atomic operator verb moves exact packet/audit bytes out of the integration scan,
  records their hashes/reason, restores task and lease to a deliberate parked state, and remains reversible.
- Code anchor: `engine/ops.sh:121-225` supersede path and `engine/import-packet.sh:82-101` publication; integration
  scans every task directory under `docs/orchestration/packets/imported` in `engine/integrate.sh:129-135`.
- Evidence: all three ignored operator quarantine manifests and their packet/audit hashes, plus the
  `quarantine-retry` and `escalate-parked` counter-decisions. The third preserves packet `f8a39a9e...`, primary
  audit `be47766c...`, paired record `f8b36cd7...`, and paired raw verdict `afd04580...`.
- Operator cost/action: held STOP, verified quiescence, recoverably moved exact artifacts by explicit path, restored the
  lease to blocked, created a durable candidate ref, and verified no active TASK-0109 import/inbox remained.
- Resolution: open engine feature request; the manual quarantine is hash-bound and reversible for this run.

### FR-032 — rendered worker prompt drops an authored recovery seed and enables coverage regression

- First seen: 2026-08-13T21:10:10Z; frequency: 1/2 relevant task retries. The first relied on a standalone
  `Recovery seed:` field and dropped it; the next duplicated mandatory restoration into the rendered Objective.
- Classification: new task-rendering and audit near-miss; severity: high; impact: blocked and degraded. No weak
  packet integrated because operator supervision compared the accepted candidate to the preserved seed.
- Symptom: TASK-0109 named exact recovery ref `08bcb2b0` and instructed the worker to restore its six owned
  paths, but the generated L2 prompt omitted that field. The worker did not read the full task and rebuilt from
  target head. Attempt 1's auditor caught four missing proofs. Attempt 2 resolved its ledger but still removed
  three seed guarantees: real-checkout CLI status/full-lstat proof became a synthetic direct-reconcile fixture,
  ten low-disk cycles became one, and live rc-86 resume/fallback execution became an archive-only fake file.
  The second auditor returned `accepted`; independent exact-contract review caught the regressions.
- Expected: all operator-authored recovery constraints are rendered into the worker prompt or the renderer
  rejects unknown authoritative fields. Audit must compare a retry against both the current acceptance text and
  the explicitly named preserved seed, not only against findings generated from the weaker attempt.
- Code anchor: task-to-prompt field extraction in `engine/lib.sh`/L2 prompt rendering; emitted
  `RUN-20260813T211009Z-78320/l2-prompt.md` and worker log; candidate diffs `08bcb2b0..ed8fc1bc`.
- Evidence: authored TASK-0109 at control commit `014466d5`, generated prompt, attempt-1 and final audits,
  candidate commits `6fd30118`/`ed8fc1bc`, second quarantine manifest, and exact review line anchors.
- Operator cost/action: two implementer calls, two fresh reviewers, twelve redundant host gate reruns across
  the two TASK-0109 runs, another deterministic recovery, and a second manual quarantine. The task now places
  mandatory seed restoration inside its rendered Objective and makes each regressed proof numerically explicit.
- Resolution: the seed-restored run proved local containment: five owned paths remained byte-identical to the
  seed and only the intended test was additive, preserving the exact real-checkout, ten-cycle, and live-fallback
  proofs. General unknown-field/rendered-authority validation remains open.

### FR-033 — two accepted auditors overlook literal hermeticity acceptance terms

- First seen: 2026-08-13T22:01:42Z; frequency: 2/2 auditors reviewing seed-restored candidate `ede05b0e`.
- Classification: new audit-quality defect; severity: high; impact: blocked integration. STOP prevented the
  accepted packet from reaching integration.
- Symptom: the primary attempt-2 auditor and sampled independent paired auditor both returned `accepted` and
  claimed complete acceptance coverage. The candidate invokes `singular_attempt_archive` once, not at least
  twice as the task explicitly requires; its file/hash comparison also targets a synthetic
  `$tmp/invoking-checkout`, not the literal invoking checkout named by the contract. The paired rationale claims
  “repeated” hermetic execution even though it counted external worker/host gate invocations, which the task
  explicitly does not permit as a substitute.
- Expected: audit maps each explicit acceptance term to a concrete assertion and fails closed when a numeric
  repetition bound or named trust boundary is absent; external repeated gate executions do not substitute for
  repetition inside the fixture being tested.
- Code anchor at `ede05b0e`: `tests/test-per-try-artifacts.sh:13-29` creates/snapshots the synthetic host root;
  `:197-261` sources helpers and archives exactly once. Acceptance text is TASK-0109 lines 133-136.
- Evidence: `RUN-20260813T213939Z-24911/{audit.json,paired-audit-raw.json,paired-audit.json}`, exact candidate
  source, task contract, six green host-verification logs, and clarified quarantine manifest SHA-256
  `c01d63842a1cbe74f8b9e30d9e171b118a266d2be4bc7077054b4626c792ff31`.
- Operator cost/action: manually cross-walked every acceptance clause after three model reviews and eight
  green gate executions, held STOP, revoked acceptance, and quarantined the packet before integration.
- Resolution: candidate `ede05b0e` rejected. The terminal retry produced exact successor `b874a874`, whose
  authored gate and fresh native audit verified exactly two helper invocations against distinct roots in one
  process plus literal incoming caller checkout/state/event inventories after each and final drain.

### FR-034 — paired-audit agreement flag contradicts matching accepted verdicts

- First seen: 2026-08-13T22:01:42Z; frequency: 1/1 sampled paired audits in this sprint.
- Classification: new experiment/observability defect; severity: medium; impact: degraded audit telemetry;
  non-blocking relative to the separate FR-033 product-proof block.
- Symptom: primary and paired auditors both returned `accepted`, and the paired audit reported no required
  fixes. Its `findings` array contained eleven positive verification statements, yet the recorder emitted
  `agreement:false` and `disagreement:true`. The record therefore contradicts both verdict comparison and its
  own accepted rationale, falsely counting an audit escape/directional disagreement.
- Expected: agreement compares the primary and paired verdict/fix disposition, while positive evidence notes
  are not treated as adverse findings. If any non-empty `findings` array intentionally flags disagreement,
  the auditor contract must reserve that field for actionable defects and reject positive observations there.
- Code anchor (0.18.0): `engine/ctx-paired-audit.sh:112-156` defines disagreement as paired verdict not accepted
  **or any non-empty findings**, without reading the primary verdict or distinguishing positive notes.
- Evidence: `RUN-20260813T213939Z-24911/{audit.json,paired-audit-raw.json,paired-audit.json}` and event line 1305.
- Operator cost/action: manually interpreted the raw paired verdict rather than trusting its agreement flag;
  downstream experiment/escape metrics for this sample must exclude or correct the false disagreement.
- Resolution: open for a future sprint.

### FR-035 — paired audit launches with an unresolved generic prompt

- First seen: 2026-08-13T22:01:42Z; frequency: 1/1 sampled paired audits in this sprint.
- Classification: new audit-context defect; severity: high; impact: degraded evidence quality and cost;
  non-blocking only because the hook is post-acceptance/observability and operator review remained active.
- Symptom: the paired hook passes `docs/orchestration/prompts/auditor.md` unchanged, leaving `[TASK-ID]`
  unresolved and appending none of the primary auditor's run-bound task, scope, manifest-reader, host-
  classification, or output-schema contract. The reviewer had to discover TASK-0109 and its artifacts by broad
  repository search. It nevertheless returned accepted, missed FR-033, and spent 397,886 raw / 315,392 cached /
  82,494 fresh input plus 8,150 output tokens.
- Expected: the independent pass is fresh in session identity but receives an immutable run-bound prompt with
  exact task/run/branch, owned scope, compact manifest, host verification, bounded evidence reader, and verdict
  schema. Freshness must not mean context-free discovery.
- Code anchor (0.18.0): `engine/ctx-paired-audit.sh:84-105` selects the base prompt and invokes the runner
  directly; unlike `engine/l1-drive.sh:232-295`, it performs no placeholder substitution or audit-contract append.
- Evidence: the base auditor prompt, paired provider envelope/commands, `paired-audit-raw.json`, and its broad
  `rg` discovery transcript under `RUN-20260813T213939Z-24911`.
- Operator cost/action: manually reconstructed the missing run binding and treated the paired result as weak
  observability evidence rather than independent approval.
- Resolution: open; bind the paired prompt before using paired results for audit-quality metrics.

### FR-036 — strict caller-state proof can observe its own gate log

- First seen: 2026-08-13T22:23:50Z; frequency: 1/1 first attempts in the literal-contract run.
- Classification: new test/harness-boundary defect; severity: medium; impact: degraded and caused one
  product retry, but did not block the run.
- Symptom: attempt 1's gate ended `failed-product` with `after archive iteration 1: incoming state inventory
  changed: .../.singular-state`. The hostile-state proof included the live caller state root in its recursive
  inventory, so activity produced by the enclosing gate could be mistaken for product leakage.
- Expected: the proof remains strict over the literal incoming checkout/state/event paths while its baseline
  and observation window cannot include writes owned by the enclosing gate itself.
- Code/evidence anchor: candidate `tests/test-per-try-artifacts.sh:5-66,234-366`; attempt-1
  `gate-check.log` and `gate-report.json` in `RUN-20260813T221358Z-8581`.
- Operator cost/action: one 9m52s failed attempt and a full fresh retry; no assertion exclusion or weakened
  inventory was accepted. Resolution: exact attempt-2 candidate passed the authored gate and native audit.

### FR-037 — gate-red skips implementer session finalization and forces a role-mismatch restart

- First seen: 2026-08-13T22:23:51Z; frequency: 1/1 same-role retry after a worker gate failure.
- Classification: new session-lifecycle defect; severity: medium; impact: degraded cost/context continuity.
- Symptom: attempt 2 selected `fresh role-mismatch` although attempt 1 had completed a valid implementer call
  for the same task/run/role. The gate-red path returns before host-authority fields are merged into the
  implementer session metadata, leaving the next routing decision unable to resume it.
- Expected: every completed provider call is finalized before any later product-gate return, or a gate-red
  retry receives an explicit usable same-role session record.
- Code anchor (0.18.0): early gate returns at `engine/l1-drive.sh:912-916`; finalization only at
  `:1027-1031`; role-mismatch decision at `engine/lib.sh:6493-6496`.
- Evidence/cost: attempt index, session metadata, and context-strategy event in the terminal run; the entire
  second implementer pass ran fresh. Resolution: open for a future sprint.

### FR-038 — provider command lifecycle allowed a dependent read before its regression command completed

- First seen: 2026-08-13T22:38Z; frequency: 1 observed overlap in the accepted attempt-2 implementer call.
- Classification: new provider/tool lifecycle near-miss; severity: medium; impact: degraded evidence and
  cost; non-blocking because the worker detected the partial result and re-established terminal evidence.
- Symptom: provider command item 36 started the grouped regression, while items 37–38 inspected the same
  evidence log before item 36 completed and saw only two of five terminal markers. After item 36 reported
  green, the worker reran the focused low-disk test and full group (items 40–41); item 42 then confirmed all
  five markers and bound hashes.
- Expected: a dependent inspection cannot run until its foreground command has a terminal lifecycle result,
  or concurrency is explicit and partial evidence is marked non-terminal.
- Code/evidence anchor: no engine product-code anchor identified; `worker-codex.log` items 36–42 and the final
  packet's command-log hashes in `RUN-20260813T221358Z-8581`.
- Operator cost/action: duplicate regression work and manual transcript review. Resolution: contained in this
  attempt; investigate provider command serialization/completion signaling.

### FR-039 — focused green gate and strict-observation verifier contract are structurally incompatible

- First seen in this exact form: 2026-08-13T22:42:46Z; frequency: 3/3 verifier tries in the accepted attempt.
- Classification: new anchor for the recurring FR-012 twin drift; severity: medium; impact: degraded time,
  compute, and audit evidence; non-blocking after evidence-only fallback.
- Symptom: all three exact-head verifier reruns produced the same green 1,004-byte log, but each normalization
  failed `gate-report: strict gate observation missing`. The focused TASK-0109 gate is a direct chain of five
  test scripts; only the aggregate `tests/run.sh` harness writes the exported observation contract.
- Expected: `gate-check` adapts any authored green gate to the strict observation schema, or verification
  recognizes a hash-identical focused gate without classifying absent harness-specific metadata as infra.
- Code anchor: export at `engine/gate-check.sh:70-72,102`; strict requirement/fallback at
  `engine/audit-verify.sh:240-249,370-388`; the sole writer at `tests/run.sh:111-135`.
- Evidence/cost: `audit-verification-2-{0,1,2}.log` and matching normalization errors; about 417 seconds
  elapsed from the already-green worker gate to evidence-only verification. Resolution: open; this occurrence
  raises FR-012 to 24/24 redundant green verification tries across eight audited attempts.

### FR-040 — native integration gate binds the pre-merge target HEAD instead of the staged merge tree

- First seen: 2026-08-13T23:50:11Z; frequency: 1/1 native staged integrations inspected in this sprint.
- Classification: new evidence-binding defect; severity: high; impact: degraded integration-proof trust;
  non-blocking here because the operator independently cross-bound the staged paths, final tree, parents, and log.
- Symptom: the integration gate report says `headSha=de7e9d52d98b3dd54f98215c61bdbc3ef19bb3b0`, the
  target commit before the merge. The suite actually ran against the uncommitted staged merge of audited worker
  `b874a874`, later finalized as `9d9c41f2` with tree `bf6553eb58227f1ae86fcdeb0728fc6fc6512cef`.
  Neither the tested tree nor the resulting merge commit is therefore named by the report's primary identity field.
- Expected: a staged-merge gate binds the exact tested tree object and both intended parents, and finalization
  proves that the committed merge has that same tree; a pre-merge target SHA alone must not identify merged bytes.
- Code anchor: `engine/integrate.sh:287` creates an uncommitted merge, `:366-371` gates it, and `:394-401`
  commits only afterward; `engine/gate-check.sh:34` records `git rev-parse HEAD`, which still resolves the target.
- Evidence/cost: integration `gate-report.json`, source snapshots, merge object, and six-path diff in
  `ORIGIN-20260813T230100Z-TASK0109-NATIVE-integrate-TASK-0109`. No product bytes escaped review, but the
  operator had to reconstruct the missing identity binding manually. Resolution: open for a future sprint.

### FR-041 — literal caller inventory makes one focused test consume almost half the gate deadline

- First seen: 2026-08-13T23:50:11Z; frequency: 2/2 full-suite executions of the terminal TASK-0109 test.
- Classification: new test-scaling/timeout near-miss; severity: high; impact: degraded integration latency and
  almost blocked the gate; the run completed green.
- Symptom: `test-per-try-artifacts.sh` took about 26m40s during a 3,010,561ms (50m10.561s) integration suite,
  then about 26m25s during the 2,959s (49m19s) native promotion suite. The default gate deadline is 3,600s,
  leaving only about 9m49s and 10m41s respectively for host variance or future suite growth when this command
  runs through the bounded gate path. The test
  recursively enumerates and byte-hashes the literal caller checkout before the fixture, after each of two archive
  iterations, and after final drain, so cost scales with unrelated ignored/generated checkout content.
- Expected: hostile-state proof remains byte- and path-exact while its cost is bounded independently of total
  checkout size, and test/gate telemetry exposes per-test elapsed time before the overall deadline is at risk.
- Code anchor: recursive hashing at `tests/test-per-try-artifacts.sh:13-35`, repeated checkout/state comparison
  at `:46-60,64-66,336,366`; default deadline at `engine/gate-check.sh:61`.
- Evidence/cost: live process timing observation plus integration and promotion timestamps/reports/logs. Both
  runs stayed correct and passed 195/195; the integration gate verified source integrity, while read-only
  supervision froze all rel-01 promotion identities. Each run occupied its only control path for about 50 minutes.
  Resolution: assigned to amended TASK-0110 as a descendant harness repair. Replace whole-tree equality with
  nonce-attributed leakage, private decoy state, and fixed protected caller files; do not serialize the lanes or
  weaken `gate-check` source integrity. Fresh candidate `7ca9c5c1` implements that bounded proof: its complete
  three-command host gate took 38,299ms with source integrity verified. The repair is accepted under STOP but is
  not yet imported or integrated, so the promoted rel-01 baseline remains unchanged.

### FR-042 — whole shared-state equality makes the promoted rel-01 fixture incompatible with concurrency three

- First seen: 2026-08-14T01:23:01Z; frequency: 2/2 TASK-0110 host gates while TASK-0115 was live.
- Classification: promoted test-harness concurrency defect; severity: critical; impact: deterministically
  blocked an otherwise green rel-02 candidate and consumed both product attempts before any audit.
- Symptom: the promoted `test-per-try-artifacts.sh` recursively fingerprints the literal incoming
  `.singular-state` tree and requires byte equality after each fixture archive. During both TASK-0110 host
  gates, TASK-0115 legitimately updated its own run artifacts in that shared tree. The first gate ran 68,402ms;
  the second ran 72,420ms and observed only TASK-0115's `worker-attempt-3-try-0.log` changing. Both TASK-0110
  source-integrity reports were `verified` with `changedPaths=[]`, yet both gates returned product red.
- Expected: a test intended to run at `maxConcurrent=3` attributes leakage causally—using a private hostile
  state tree, unique run/event nonce, exact protected caller files, and targeted absence from the authoritative
  namespace—without requiring unrelated shared control state to stop changing.
- Evidence/cost: `RUN-20260814T010432Z-76912` attempts 1/2, gate logs/reports, and concurrent TASK-0115 event
  timestamps. The second log is `cd18177aa1e4c708eb8d1e454d75b997265b8d3e118f57ed2b5b6d445200e93e`;
  its binding is `de8e8130...`. Resolution: assigned as a descendant repair in amended TASK-0110/rel-02. The
  promoted rel-01 result remains historical; serialization and shared-tree exclusions are explicitly rejected.
  Fresh run `RUN-20260814T041625Z-15168` passed a causal replacement with a PID-bound sibling writer ready before
  both archive calls, acknowledged overlap during each call, an acknowledged final write, exactly three writes,
  zero exit, independent nonce-free decoys, fixture-local events, and a bounded final drain. Primary and forced
  paired review accepted that proof; import/integration is still held behind STOP.

### FR-043 — a gate-red candidate has no durable commit identity before retry cleanup

- First seen: 2026-08-14T01:23:02Z; frequency: 2/2 TASK-0110 gate-red attempts.
- Classification: evidence-preservation/recovery defect; severity: high; impact: degraded recovery and risk of
  losing valid product work for an unrelated gate failure.
- Symptom: both workers produced the intended two-line production fix and green focused evidence, but host-gate
  failure occurred before a commit or packet. `attempts/index.json` records `headSha: ""` for both attempts.
  After terminal park the task branch still points to base `81f67e00`; the exact 137-insertion/2-deletion
  three-file attempt-2 result exists only as a dirty worktree plus runner logs, not as an immutable candidate.
- Expected: before destructive retry/reset, L1 creates a content-bound candidate commit or complete immutable
  diff snapshot and records that identity in the attempt archive, even when the gate is red.
- Evidence/cost: worktree diff SHA-256
  `e35b4160be8164285dc39509aad1065642ae01084c018584e90e95820f9acd0b`, attempt index, RED/GREEN/regression
  logs, and the 54-file recovery snapshot whose inventory SHA is
  `b018356be73ce3b3b5b23d8e8a63e64076ac36fe2cd2cdc067337116602e12fd`. Resolution: open as engine work;
  the old dirty diff remains evidence only—not approval. TASK-0110 subsequently reconstructed test-first from
  exact base `94876831` and created durable clean candidate `7ca9c5c1` plus its private ref before audit. That
  successful path does not itself prove generic preservation of future gate-red candidates, so the engine-level
  recovery defect remains open.

### FR-044 — rel-08's authored causal claim contradicted the independence-pinned reviewer policy

- First seen: 2026-08-14T01:08:01Z; frequency: 1/1 rel-08 contracts inspected against the live route order.
- Classification: task/DAG specification defect plus audit-quality escape; severity: high; impact: an accepted
  candidate could not satisfy the outcome its task claimed to repair.
- Symptom: TASK-0116 said the stale `audit-codex.log` adapter path structurally forced live final reviewers
  fresh. With context routing enabled, `final-audit` and `paired-audit` are deliberately pinned to
  `fresh tainted` before the transcript-window gate; they never consume either transcript filename. Candidate `98628d0d` correctly aligns
  the latent adapter and proves an unpinned reviewer route, but attempt-2 audit accepted it without identifying
  the false live-resume causal claim.
- Expected: task, DAG, plan, tests, and auditor distinguish admissible non-independence reviewer routing from the
  enabled-routing safety policy that intentionally keeps final/paired audits fresh, while preserving the
  legacy-identical master-off path.
- Code/evidence: route ordering in `engine/ctx-route.sh`, independence assertions in
  `tests/test-ctx-route-taint.sh`, run `RUN-20260814T010432Z-76945`, accepted audit, and candidate ref
  `refs/singular/operator-candidates/TASK-0116/RUN-20260814T010432Z-76945-attempt-2`. Resolution: contract
  corrected under operator-proxy authority; preserve the pin, rebind the candidate only as a recovery seed, and
  require a fresh run/audit against the amended artifact-alignment objective.

### FR-045 — same-UID path hiding cannot enforce host-only run-control authority

- First seen: 2026-08-14T01:16:55Z; frequency: 2/2 TASK-0115 auditors rejected the attempted boundary.
- Classification: task-contract/authority design defect; severity: critical; impact: blocked rel-07 and would
  allow a supervised child to grant itself time under the attempted design.
- Symptom: candidate `68c48b4a` moves observation bytes and removes several environment hints, but arbitrary
  gate/provider children still run as the same UID from a linked worktree. They can derive the repository/common
  directory from `PWD`, enumerate writable `.singular-state/runs`, and create or replace `run-control.json`.
  The adversarial tests attacked only disclosed report-adjacent or environment paths; no-control runs also lost
  five inherited `SINGULAR_*` variables, so parity was not byte-identical.
- Expected: authorization is cryptographic rather than positional. A v1 record binds exact `runId`, increasing
  `generation`, bounded extension/cancel fields, signer key, and a canonical domain-separated Ed25519 signature.
  The supervised UID receives only a pinned public key; the private signer remains outside its filesystem,
  environment, argv, and authority. Invalid, modified, replayed, wrong-run/key, negative, and oversized records
  are absent; extension is monotonic, cancel sticky, and no-control execution byte-identical.
- Evidence/cost: both TASK-0115 audits, same-UID path derivation, failed nested `sandbox-exec` probe, candidate
  ref `refs/singular/operator-candidates/TASK-0115/RUN-20260814T010432Z-76911-attempt-3`, and 132-file snapshot
  inventory `0aa2e4b4166d42c528c0d11982a22a38a8772c16c5706f02d08967501236e3e2`. Final audit correctly remained
  `needs-fix`; cumulative fresh auditor input was 178,060. Resolution: TASK-0115/DAG/plan amended for signed
  authority and a fresh RED-first implementation; the path-hiding candidate is retained as evidence only.

### FR-046 — `singular resume --help` performs the destructive resume action

- First seen: 2026-08-14T02:06:49Z; frequency: 1/1 syntax probes.
- Classification: CLI argument-validation defect; severity: high; impact: removed a safety sentinel during
  stopped-state preflight, but caused no actuation because no controller existed and STOP was restored at once.
- Symptom: `cli/singular` forwards all trailing arguments for `resume`; `ops_resume` ignores them, removes STOP,
  appends `operator.resume_requested`, and only then reports that autonomate is not running. A conventional
  `--help` request is therefore indistinguishable from explicit authorization to resume.
- Expected: mutating verbs reject unknown arguments and implement non-mutating `--help`; no help, version, or
  syntax query may remove STOP or append an operational event.
- Code anchor: `cli/singular:2341` forwards `resume "$@"`; `engine/ops.sh:279-292` does not parse or reject
  arguments before deleting the sentinel.
- Evidence/cost: the single 02:06:49Z event, empty process/lock/inbox checks, and restored empty STOP sentinel.
  Resolution: open for a later CLI-safety task; every remaining operator procedure uses bare `singular resume`
  only after an explicit preflight.

### FR-047 — retained worktrees and the frozen pre-lease reset order deadlock a supported rerun

- First seen: 2026-08-14T02:21:34Z; frequency: 3/3 amended-wave tasks retained a blocked worktree that had
  to be reset before a clean rerun.
- Classification: new operator-control/worktree-lifecycle defect; severity: high; impact: degraded safety and
  required a carefully bounded unfrozen dispatch interval; no evidence was lost in this occurrence.
- Symptom: `drive --reset` is the supported way to replace a retained task worktree/branch, but the L1 entry
  point checks STOP and exits before it reaches reset. Auto/reconcile cannot pass `--reset`; without reset its
  child drive refuses an existing running/accepted worktree and can repeat that refusal. Thus a task whose
  prior worktree is intentionally retained for evidence cannot be cleaned while frozen, yet removing STOP also
  authorizes dispatch.
- Expected: a frozen, cleanup-only verb can resolve and remove one exact retained worktree/branch after
  evidence preservation, without creating a lease, allocating a run, dispatching a worker, or requiring a
  global resume. Dispatch should consume the already-clean result in a separate authorized step.
- Code anchor (rel-01 overlay): STOP exits at `engine/l1-drive.sh:55-60`; reset occurs only at `:334-346`;
  retained-worktree refusal is `:411-421`. The ordering makes reset unreachable behind STOP.
- Evidence/cost: the 02:21:34 unpark events, 02:22:48 resume/02:23:06 stop guard cycle, 02:24:12 bounded
  resume, and 02:24:23 worktree reflogs. The operator first preserved all old evidence, then launched exactly
  three direct `drive TASK --reset` calls from base `97862d9370649c90ae67c825ed5d14ca3d37e530`; STOP was restored
  at 02:31:24Z. All new leases/scopes were correct and no unrelated path was reset.
- Resolution: assigned to TASK-0114/rel-06. Its STOP-safe `drive TASK --reset-only` contract proves the
  exact retained process dead and removes only that task's worktree/worker branch without allocating a run,
  mutating the lease/task, or dispatching a provider. Until rel-06 is integrated, reset remains destructive and
  must follow an explicit inventory snapshot.

### FR-048 — TASK-0116's accepted proof used `review` instead of the contract's exact `probe` step

- First seen: 2026-08-14T02:33:43Z; frequency: 1/1 fresh amended TASK-0116 primary audits.
- Classification: new exact-contract test/audit escape; severity: high; impact: accepted and queued a packet
  without proving the literal route named by acceptance; STOP prevented import/integration.
- Symptom: the task requires an unpinned reviewer `probe` fixture, but
  `tests/test-ctx-route-drive.sh:213-217` calls the adapter with step `review`. Both steps happen to be unpinned
  today, so the RED still showed `fresh window-pressure` and GREEN showed `resume SID-reviewer`; that behavioral
  similarity does not prove the required route identity or protect against future step-specific policy. The
  primary auditor nevertheless stated that the exact amended reviewer case had been proven and returned
  `accepted` with no findings.
- Expected: literal enumerated identities in an acceptance criterion are asserted directly, and the auditor
  cross-checks the invoked argv/fixture against that identity rather than accepting an adjacent equivalent.
- Evidence/cost: RED SHA-256 `f992701bd4e1af4605f3dc1a0760519748643cf91120b228fd305d9f184af03a`,
  GREEN `59a4f5d5c83fa30c10c8eef7542b67e3041ccae81236a1b8a911391750a278be`, accepted audit
  `c05c09b67211f0553da523d1f636b3a9a1bcfe89e3bb432e053cfd7378da5a32`, and primary auditor usage
  269,708 raw / 217,088 cached / 52,620 fresh input plus 5,291 output.
- Resolution: operator-proxy review quarantined the packet before import/integration; quarantine manifest
  `03301456a85784352b32558b8429d8db3411bba23c2589674b7211056582990b` preserves candidate
  `c5a2842a72faa9b6f84c313febb509217f2d9630` under its create-only evidence ref. The task is re-amended for a
  literal `probe` RED/GREEN; the candidate is a seed, not approval.

### FR-049 — sampled paired audit is post-accept observability, not an acceptance guard

- First seen: 2026-08-14T02:43:57Z; frequency: 2/2 TASK-0110 post-accept paired audits inspected—one
  probabilistically sampled rejection and one manually forced acceptance after a fresh reset.
- Classification: known observability design with a live quality escape; severity: high; impact: a useful
  independent rejection cannot itself prevent the accepted packet it reviews from being imported.
- Symptom: TASK-0110's primary auditor returned `accepted` with no findings and L1 stamped the root packet,
  set task/lease accepted, and atomically queued it in the inbox at 02:38:07Z. The sampled fresh paired auditor
  then returned `needs-fix` at 02:43:57Z with four blockers: unproven sibling-writer overlap/exit, archive nonce
  reuse in five decoy contents, no stale-output seed proving the same-try rc86 fallback cleanup, and stale
  manifest-to-packet provenance. Its disagreement is observability only and cannot change exit status or recall
  the packet.
- Expected: paired audit is not represented as acceptance authority. Every sampled result is surfaced for
  operator disposition, and rel-99 refuses approval when any non-accepted verdict, disagreement, or finding is
  unresolved or when a paired-rejected packet entered imported/integrated history.
- Code anchor (rel-01 overlay): acceptance stamping/inbox placement occurs at
  `engine/l1-drive.sh:2030-2056`; comments and the hook at `:2099-2104` explicitly make paired audit
  post-acceptance and non-authoritative.
- Evidence/cost: primary fresh input/output was 58,625/7,401; the paired pass separately used
  1,511,728 raw / 1,274,112 cached / 237,616 fresh input plus 15,442 output. `paired-audit.json` recorded
  `needs-fix`, four findings, and `disagreement=true`. STOP, already present since 02:31:24Z, was the only reason
  the inbox packet could be removed safely at 02:44:43Z.
- Resolution: packet/audits recoverably quarantined under manifest
  `af62da87fa1f925151343b01a4e35047bd25a8df8342850b0a3b633ef7b93f27`; exact candidate
  `fa95b8dcc7e5c7f75b8a355135ea09bdcbf49456` remains evidence-only. Fresh reset candidate `7ca9c5c1`
  addressed all four blockers; after configuration loaded the normal 25% rate, the operator set the in-process
  rate to 100% and invoked the built-in recorder. Its fresh paired verdict was `accepted`, findings count zero,
  `agreement=true`, `disagreement=false`, with 115,981 fresh input and 12,250 output. Binding-record/raw/
  runner-result/summary/envelope SHA-256 values are `7020332c...`, `8aa7ca1a...`, `f333205c...`,
  `7fadb975...`, and `4fecb7b0...`. The paired-audit runner result records `model:null`; the invocation record
  independently binds provider `codex`, model `gpt-5.6-sol`, and high effort, so model-null result observability
  is recorded but is not treated as a finding. Its read-only local gate rerun was inconclusive because `mktemp`
  was denied; the auditor instead accepted the exact SHA-bound, source-clean host gate evidence. The sprint explicitly
  keeps the hook sampled/non-authoritative; TASK-0125/rel-99 still requires a complete paired-result/operator-
  disposition inventory and blocks human approval on any unresolved or historically integrated rejection.

### FR-050 — a successful final manifest refresh still binds the pre-accept packet

- First seen: 2026-08-14T02:31:07Z; frequency: 2/2 successful predecessor refreshes in the amended wave were
  stale (TASK-0116 and TASK-0110); the first fresh v3 native acceptance was correctly bound 1/1.
- Classification: new provenance-binding defect distinct from FR-016's failed-refresh staleness; severity:
  high; impact: a syntactically final manifest names bytes that are no longer the authoritative root packet.
- Symptom: final refresh runs while the packet is still `needs-review`. Acceptance later rewrites the root
  packet's status/next action and queues it, without refreshing the manifest. TASK-0110's manifest declares
  3,554-byte packet SHA-256 `0b59d8242ac21cde8add233c89d0a0b3d69a15e5d697ff52bbe129e57cbe27ed`, exactly
  `attempts/1/packet.json`; the accepted root is 3,497 bytes and
  `729ec7b7d4e3fb8c1da17f6ad5d1e20b087c0b2789fa39363e5a25091692eed0`. TASK-0116 likewise declares the
  3,207-byte attempt packet `e28e0164b617724bfb16c5247afef4811b5cbc87669ccd85dac73540f5c77ed5`, while its accepted
  2,986-byte root packet is `0bbb5a21a4ddbfeda093ee3927aa6fc0c77bbf6c433076544e5941bcc74d99d6`.
- Expected: the final manifest binds an immutable explicitly named attempt packet, or acceptance stamping is
  completed before the final atomic manifest is generated and validated. A bare `packet.json` ref must resolve
  to the authoritative bytes at the time downstream consumers receive it. The deterministic
  `accept-existing-packet.sh` recovery publisher must use the same finalizer rather than refreshing evidence
  before its own accepted stamp.
- Code anchor (rel-01 overlay): final refresh at `engine/l1-drive.sh:1687-1697`; packet mutation and inbox copy
  only at `:2030-2051`; alternate deterministic recovery refreshes before stamping in
  `engine/accept-existing-packet.sh`, then L1 auto-heal copies that accepted root into inbox.
- Evidence/cost: both successful refresh logs, root/attempt packet sizes and hashes, manifests
  `016cdd92f33f99ab1998fb6ac09fe6fc2f7efe0afef19d363a48feebfc3f8227` (TASK-0110 quarantine copy) and
  `15cba7ab9650809a987131438d7b88bd2cce0ffd90c072e1cc0753b0d5e40483` (TASK-0116), and the paired finding.
- Resolution: open permanently for TASK-0113/TASK-0114; both predecessor packets were quarantined for
  independent blockers, so no stale binding entered tracked control state. The active per-process v3 mitigation
  contained the fresh native TASK-0110 path: accepted root and inbox are byte-identical at SHA-256
  `264577d68716db44262779dd1ea1d19b511aa5cba7da0d3840b52f99d6bbfcc9`, and the final manifest's sole
  `packet.json` artifact matches those exact bytes. STOP retained that correctly bound packet before import.

### FR-051 — a resumed retry cannot repair strict-RED lineage, and the accepted proof masked timeout-0 drift

- First seen: 2026-08-14T02:39:40Z; frequency: 1/1 resumed TASK-0115 strict-test-first retries.
- Classification: new test-policy lineage defect plus primary-audit/product escape; severity: critical; impact:
  accepted unsupported proof and left a timeout-0 behavior regression in the evidence-only candidate.
- Symptom: attempt 1 had already committed production integration as `f89692bb` before the auditor rejected its
  RED. Attempt 2 resumed that session/head. Its replacement RED first ran the current production-modified
  `cursor-run.sh` with authority variables unset, then deliberately failed on a “behavioral golden ... is not
  implemented” sentinel. It was not a run against unmodified base `97862d93`, and the same real behavior did not
  flip from RED to GREEN. Nevertheless the final auditor called it a fresh baseline RED and accepted.
- The accepted candidate also violates the literal unbounded-path rule. With
  `SINGULAR_CODEX_TIMEOUT_SEC=0`, default completion grace 10 still selects `run_codex_guarded`; its spawn
  deadline remains zero, but a valid signed record sets `effective_deadline=0+extend`, making an unbounded run
  finite, and signed cancel exits 143. The golden forces completion grace and idle to zero, bypasses the guarded
  loop, and compares current absent-control bytes only with current malformed-control bytes; it never presents a
  valid signed record to timeout 0. The other seven loops poll only inside a bounded-timeout branch.
- Expected: strict-test-first evidence binds each RED command to the exact pre-production tree object. A retry
  that inherits production must use an isolated frozen-base fixture/worktree or restart from base; an intentional
  TODO sentinel cannot substitute for the specified behavioral failure. Every valid-control case must also prove
  timeout 0 is byte/exit/lifecycle identical and never polls or honors control.
- Code/evidence anchor: candidate `engine/codex-run.sh:433-465,525-526` and
  `tests/test-run-control.sh:81-111,245-320`; attempt-2 RED
  `2552935ad3f8d8c1f16d86db8bc2569267991a26d614f66e8a2e8f64fcc5e4ce`; final audit
  `eaf5c4bdb87ae4106f8991476650d2d69d343f6a9db542a1d0fc87ef7bc8d039`.
- Cost/disposition: attempt-1/2 implementers used 101,920 and 235,556 fresh input plus 23,845 and 52,072
  output. Primary auditors used 73,767 and 73,357 fresh input plus 8,045 and 11,283 output; only input-minus-cache
  formed the failed `147124 >= 100000` canary. No accepted/inbox packet or paired audit existed; the
  needs-review root packet remains non-importable evidence. Operator retained exact head
  `032a32c018d8d83c1702991fdbda115b94ab8bca`/tree `6ad309c3f20dc57b7ca36f873b465a662c7093b0`
  at `refs/singular/operator-candidates/TASK-0115/RUN-20260814T022422Z-15249-attempt-2`, blocked the task, and
  re-amended it for a genuinely fresh RED plus valid-control timeout-0 tests.

### FR-052 — the live post-accept secret scan can leave an importable inbox copy behind

- First seen: 2026-08-14 fresh-wave acceptance-order review; frequency: 1/1 enabled artifact-scan acceptance
  paths inspected. No current packet is alleged to contain a real secret; this is a reachable release-blocking
  ordering defect.
- Classification: cross-feature containment/acceptance defect; severity: critical; impact: a packet rejected by
  the durable-artifact secret policy can remain accepted and importable.
- Symptom: this repository runs with `SINGULAR_CTX_ARTIFACT_SCAN=1`. The rel-01 L1 stamps the root packet
  accepted, marks task/lease accepted, and copies it into the inbox before invoking the non-fatal artifact
  quarantine hook. If `packet.json` matches a secret pattern, that hook renames only the run-root artifact to
  `packet.json.quarantined` and excludes the canonical path from later durable context. The already-copied inbox
  packet remains byte-for-byte accepted, is not recalled or rescanned, and reconcile can import it; FR-050 also
  leaves its manifest binding stale.
- Expected: the exact packet receives a read-only, packet-only secret scan before any acceptance stamp, control-
  state status change, or inbox publication. A hit or scanner failure blocks before inbox with durable evidence;
  the post-accept hook may remain non-fatal only for artifacts that cannot authorize import. Native and
  deterministic existing-packet recovery publication share this same rule.
- Code anchor (active rel-01-v2 overlay): acceptance/inbox at `engine/l1-drive.sh:2030-2056`, then the
  explicitly non-fatal artifact hook at `:2058-2097`; paired audit begins later still. The configuration enables
  the hook at `singular.config.json:190`.
- Evidence/containment: static ordering and the integrated quarantine contract were sufficient to construct the
  predecessor escape. The two earlier accepted packets were manually removed for independent findings, not by
  the artifact scan. Fresh TASK-0110's v3 preflight loaded six quiet patterns, reported zero hits, and published
  only after the atomic acceptance stamp and binding check. That clean packet was subsequently imported under
  STOP; the inbox is now empty and root/imported/manifest binding remains exact.
- Resolution: release-blocking. A verified, recursively frozen v3 operator overlay is now selected per process
  and adds a
  quiet packet-only read-only scan before
  atomic acceptance stamping, refreshes/verifies the accepted packet manifest binding, and publishes inbox only
  afterward for fresh native L1 acceptance; all pre-rel-05 drives explicitly disable unsafe existing-packet
  auto-heal. The permanent TASK-0113 contract now converges native and deterministic recovery publication on
  the same finalizer. Predecessor import reproduction, V10's 14/14 patched cases, six compatibility suites,
  exact one-file inventory, recursive `uchg`, no-activation snapshot, and per-process read-only activation
  preflight all passed independently. Fresh TASK-0110 now demonstrates the clean native path, but permanent
  rel-05 integration and deterministic-recovery parity remain mandatory; rel-99 stays blocked regardless of the
  rest of the wave.

### FR-053 — integration reaches a deterministic console disk-watch failure without a matching preflight

- First seen: 2026-08-14T05:13:04Z; frequency: 1/2 native integration attempts failed, and 1/1 launched while
  the application disk metric rounded to 99%. The post-cleanup focused replay and full integration retry both
  passed at a 98% launch/final metric.
- Classification: environmental readiness/diagnostic defect; severity: medium; impact: one 22-minute native
  integration was safely aborted after 194 otherwise-green tests. This was not a TASK-0110 source regression.
- Symptom: `test-console-server.sh` failed only `CollectHomeTests.test_empty_repo_zeros_ok`: the console's
  `collect_home` health calculation correctly returned `watch` at the configured 99% capacity threshold, while
  the fixture expected `ok`. The integration wrapper retained only the nested suite tail, so the exact assertion
  required a separate verbose replay to recover.
- Expected: long integration/promotion entry points should evaluate the same application-level capacity metric
  before staging or running the full suite and report a reversible environmental hold. Failing test wrappers
  should preserve the full method/assertion output in durable gate evidence.
- Evidence: failed integration gate log/report SHA-256 `110d1b9e...` / `da9a377e...`, source integrity
  `verified` with `changedPaths=[]`, exact abort-state audit, and focused verbose log SHA-256 `53777ccd...`.
- Resolution for this run: operationally resolved without code changes. Two exact, validated cleanup manifests
  removed 3,787 abandoned synthetic test-fixture directories (1,017,040 KiB) and nothing else; zero selected
  fixtures remain. Independent audit preserved 2,182 unrelated `tmp.*` directories, protected large temp
  families, all videos, packets/events, Git/control state, and both frozen overlays. The application metric
  fell to 98% and all 275 console tests passed. Cleanup record SHA-256 is `96239033...`. The supported full
  integration retry then passed 195/195 with `test-console-server.sh` green and source integrity verified;
  merge `1b69af27` is exact. Fresh rel-02 promotion independently passed 195/195 with the console green again.
  Guard samples later straddled the 98.5% rounding boundary without a gate failure or persisted drift, so every
  later drive still requires the same explicit capacity preflight. This observation is not a new rel-99 release
  blocker.

## Known-issue observation log

These are cost/frequency measurements, not new discoveries.

| Known issue | Occurrences | Time/token/evidence cost | Run/attempt evidence |
|---|---:|---|---|
| Enabled-routing final-audit independence pin forces a fresh reviewer on every product retry | 3/3 TASK-0109 attempt-2 final reviews | All three correctly selected `fresh/tainted` despite valid prior reviewer sessions. The fresh reviews charged 62,600, 68,806, and 45,651 input; the first two pushed cumulative canaries over 100,000, while the third pair remained under at 93,476. The stale transcript filename was not causal; this is the measured cost of the intentional advocate/skeptic pin. | Context events, route ordering, and reviewer results in all three TASK-0109 run roots |
| Worker per-try logs overwritten on infra retry | 0 worker-infra retries; 4 adjacent policy retries | No infra retry fired. All four TASK-0109 attempt-2 policy retries used the old controller's compatibility-log lifecycle; the latest gate-red archive again ran before TASK-0109's product fix could become active. | All four TASK-0109 `attempts/1/` directories versus run roots |
| 240-minute stale hard cap reclaims live work | 0 occurrences | No worker approached 240 minutes; the cap did not fire | TASK-0108 and all three TASK-0109 run-status/event slices |

## Active dogfood questions

| Question | Evidence to collect | Current answer |
|---|---|---|
| Does self-hosted audit catch weak worker output before integration? | Worker packet, audit verdict/findings, gate result, integration event | Not reliably. Fresh TASK-0115 attempt 1 correctly caught three proof gaps, but its resumed attempt-2 auditor accepted non-fresh sentinel RED evidence and missed the Codex timeout-0 regression. TASK-0116's primary accepted a `review` fixture while claiming the required `probe` was proven. TASK-0110's earlier primary accepted with no findings; its sampled paired auditor found four blockers, but only after the packet was accepted and queued. The exact fresh reset addressed those blockers and both its primary and forced paired reviews accepted with no findings. Its packet/audit are now imported under STOP; the first integration safely rejected only the unrelated console disk-watch environment. Earlier TASK-0109 remains the clean promoted example after multiple similar escapes. |
| Are role budgets realistic; were mid-run raises needed and honored? | Session/run-control files, timeout events, operator actions, elapsed time | No. In the amended wave TASK-0116 implementer/primary-auditor fresh input was 54,806/52,620; TASK-0110 was 107,227/58,625, plus a separate post-accept paired 237,616; TASK-0115's implementers were 101,920 + 235,556 and its primary auditors were 73,767 + 73,357. Only the latter primary sum formed the policy breach `147124 >= 100000`; all output is separate. The fresh TASK-0110 reset used 108,161 implementer, 79,338 primary-auditor, and 115,981 paired-auditor fresh input; the paired output was 12,250. No canary was raised mid-run: primary stayed below 100,000, while the post-accept paired pass was separately forced after config load and remains observability. The candidate run-control feature was not active in the supervising overlay and its timeout-0 proof is itself defective. |
| Is dispatch fair across parallel lanes at concurrency 3? | Ready time, dispatch time, start time, completion time per node | The fresh direct wave started all three L1 drivers at 02:24:23Z from the same base/scope batch. The amended TASK-0110 causal fixture passed while its two siblings wrote shared state, confirming the earlier red was harness coupling rather than lane unfairness. The remaining dispatch defect is operational: retained blocked worktrees cannot be reset behind STOP, so the operator had to use a bounded resume plus three direct `drive --reset` calls instead of ordinary auto dispatch. |
| What manual operator work should the engine perform or surface? | Every intervention and missing/ambiguous status signal | The amended wave added evidence-preserving worktree reset coordination, exact lease/base/scope verification, STOP restoration while existing drives wound down, primary-versus-paired contract review, two recoverable packet quarantines, three create-only candidate refs, stale-manifest packet cross-binding, strict-RED lineage reconstruction, timeout-0 code review, and provider-correct canary arithmetic. These should be native frozen cleanup/checkpoint, provisional acceptance, quarantine/recall, exact-contract audit, and manifest-finalization workflows. |

## Task outcomes and attempts

Product attempts and audit/recovery/integration tries are recorded separately. A dash means the node has not run yet.

| Task | Node | Outcome | Product attempts | Audit / recovery / integration tries | Worker run IDs | Gate / packet evidence |
|---|---|---|---:|---:|---|---|
| TASK-0108 | rel-00-contract | integrated as `41380c1b`; authoritative gate passed at 20:27:09Z | 1 | 4 / 2 / 4 | `RUN-20260813T170836Z-93780`; recovery `RUN-20260813T182550Z-RECOVERY-TASK-0108-12256` | Immutable source snapshot; accepted imported packet/audit; final exact-tree 194/194; `rel-00-contract.gate-result.json` |
| TASK-0109 | rel-01-per-try-logs | integrated as `9d9c41f2`; authoritative gate passed at 00:47:13Z under STOP | 8 | 7 / 3 / 1 (+1 promotion) | Prior three run IDs plus terminal `RUN-20260813T221358Z-8581`; accepted recoveries `...210341...`, `...212941...`; integration `ORIGIN-20260813T230100Z-TASK0109-NATIVE`; promotion `ORIGIN-20260813T235754Z-8483` | Exact six-file `b874a874` accepted with no findings and charge 86,301; native staged integration and exact-head promotion each passed 195/195; v1 gate/hash bindings validate, fake events still eight |
| TASK-0110 | rel-02-try-hygiene | integrated as exact merge `1b69af27`; authoritative rel-02 gate passed | 4 | 2 primary (+2 paired) / 0 / 2 (1 environmental red, 1 green) + 1 promotion | `RUN-20260814T010432Z-76912`; rejected `RUN-20260814T022422Z-15250`; accepted `RUN-20260814T041625Z-15168`; integrations `ORIGIN-20260814T045100Z-TASK0110-NATIVE` and `...053240Z...R2`; promotion `ORIGIN-20260814T055942Z-33888` | Exact three-file candidate and packet/audit bindings retained; first staged gate was 194/195 only on unchanged console health at 99% disk; cleanup restored 98%; retry and promotion each passed fresh 195/195; exact merge parents/tree/delta and v1 gate/task/upstream/source/log/report bindings all validate |
| TASK-0111 | rel-03-integrity-reclass | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0112 | rel-04-evidence-remedy | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0113 | rel-05-manifest-remedy-bound | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0114 | rel-06-terminal-handoff | ready; not dispatched, dependency-blocked | 0 | 0 | — | — |
| TASK-0115 | rel-07-run-control | blocked; fresh retry added signed v1 authority but did not satisfy fresh-RED or timeout-0 parity; no accepted/inbox packet | 5 | 4 / 0 / 0 | `RUN-20260814T010432Z-76911`; fresh `RUN-20260814T022422Z-15249` | Old `68c48b4a` threat-model ref/snapshot retained; fresh `032a32c0` gate green but final refresh failed `147124 >= 100000`; accepted audit escaped FR-051; needs-review packet and create-only candidate ref retained as evidence |
| TASK-0116 | rel-08-route-transcript | blocked; fresh accepted packet revoked because `review` did not prove the literal unpinned `probe`; quarantined | 3 | 3 / 0 / 0 | `RUN-20260814T010432Z-76945`; fresh `RUN-20260814T022422Z-15254` | Old `98628d0d` seed retained; fresh `c5a2842a` gate green/source clean and primary 52,620 fresh, but FR-048 escaped; quarantine/candidate ref retained, no import |
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
| 2026-08-13T20:54:39Z | TASK-0109 / rel-01-per-try-logs | `escalate-infra` | Attempt-2 auditor accepted with all eight prior findings resolved; corrected cumulative auditor fresh input then failed `139516 >= 100000` | Deterministic, not a transient environment failure. Retained STOP, did not blind-unpark, and preserved exact worker head/run evidence for bounded recovery. | `RUN-20260813T203430Z-96335/{audit.json,evidence-manifest-final-refresh.log,attempts/index.json,run-status.json}`, decision and lease |
| 2026-08-13T21:04:21Z | TASK-0109 / rel-01-per-try-logs | operator recovery | Exact-head deterministic reruns passed with no new model call; source breach stayed explicit in provenance | Accepted/imported only into the stopped control plane, then immediately re-evaluated before any integration | Recovery run, provenance, immutable source snapshot |
| 2026-08-13T21:05:30Z | TASK-0109 / rel-01-per-try-logs | operator quarantine | Accepted audit had missed FR-029's authoritative event-log pollution | Quarantined packet/audit intact, restored blocked lease, preserved candidate ref, and amended the task for a fresh hermetic retry; no integration attempted | `.singular-state/operator-quarantined-imports/TASK-0109/RUN-20260813T210341Z-RECOVERY-TASK-0109-29558/manifest.json` |
| 2026-08-13T21:29:03Z | TASK-0109 / rel-01-per-try-logs | `escalate-infra` | Amended attempt-2 audit accepted; final refresh then failed provider-correct cumulative `151702 >= 100000` | Deterministic budget park. Stopped, preserved exact head `ed8fc1bc`, and used zero-model exact-head recovery with the breach explicit | `RUN-20260813T211009Z-78320` audit, attempts, final-refresh log, source snapshot |
| 2026-08-13T21:34:00Z | TASK-0109 / rel-01-per-try-logs | operator quarantine | Accepted audit missed real-checkout lstat, ten-cycle low-disk, and live resume-fallback proof regressions | Quarantined second packet/audit intact, preserved candidate ref for evidence only, and hardened the task to mandate seed `08bcb2b0`; no integration attempted | `.singular-state/operator-quarantined-imports/TASK-0109/RUN-20260813T212941Z-RECOVERY-TASK-0109-19936/manifest.json` |
| 2026-08-13T22:05:49Z | TASK-0109 / rel-01-per-try-logs | operator quarantine | Primary and paired accepted audits both missed explicit in-process fixture repetition `>=2` and literal incoming caller checkout/state/event identity | Retained STOP, revoked the third accepted result, preserved exact candidate `ede05b0e`, and quarantined its inbox packet before import/integration | Clarified third quarantine manifest `c01d6384...`, paired audit, exact-contract review |
| 2026-08-13T22:50:44Z | TASK-0109 / rel-01-per-try-logs | accepted hold | Native audit accepted exact candidate `b874a874` with no findings; provider-correct charge 86,301 remained below the hard bound | Wrote STOP before import/integration so control state can be checkpointed and the exact-tree adapter/runtime overlay handoff remain quiescent | Terminal run audit, final manifest, inbox packet, STOP |
| 2026-08-13T23:50:12Z | TASK-0109 / rel-01-per-try-logs | integration resolved | Imported native packet and staged exact candidate passed 195/195 with verified source integrity; merge `9d9c41f2` has the expected parents/tree | Kept STOP after integration; did not publish the rel-01 gate or activate a new runtime until the evidence checkpoint is committed | Integration run, gate report/log SHA, merge object, lease/task status |
| 2026-08-14T00:47:13Z | TASK-0109 / rel-01-per-try-logs | promotion resolved | Fresh 2,959s proof passed 195/195 at exact head `9c1f2e7b`; every v1 evidence hash/binding, gate validation, and rel-01 `area-gate` passed | Retained STOP; deferred activation of TASK-0109's controller bytes until a new immutable overlay is built and verified | `ORIGIN-20260813T235754Z-8483`, rel-01 gate result/evidence, launch/terminal identity snapshots |
| 2026-08-14T01:15:49Z | TASK-0116 / rel-08-route-transcript | `escalate-infra` | Attempt-2 audit accepted `98628d0d`, then final refresh failed cumulative fresh input `101302 >= 100000`; source contract also falsely claimed the filename controlled live final-review resume | Deterministic budget/contract failure, not transient infra. Kept STOP, preserved candidate as evidence-only seed, corrected task/DAG/plan for enabled-routing artifact alignment, and required a fresh run/audit. | Run, accepted audit, failed-refresh log, 117-file snapshot inventory, private candidate ref |
| 2026-08-14T01:28:46Z | TASK-0110 / rel-02-try-hygiene | `escalate-parked` | Both product gates observed only legitimate concurrent TASK-0115 state writes; source integrity stayed verified and no audit ran | Classified as a promoted parallel-test defect, not a product failure. Preserved the exact uncommitted diff, amended rel-02 for causal nonce proof at concurrency three, and required a fresh RED-first run. | Two gate reports/logs, attempts index, 54-file snapshot inventory, uncommitted-diff manifest `8ba10933...` |
| 2026-08-14T01:41:57Z | TASK-0115 / rel-07-run-control | `escalate-infra` | Attempt-3 auditor correctly returned `needs-fix` for same-UID path hiding and no-control drift; final refresh then failed `178060 >= 100000` and obscured that disposition | Did not recover or reuse the candidate. Preserved it as threat-model evidence, amended rel-07 for externally signed run-bound v1 records, and required a clean test-first implementation. | Both audits, failed-refresh log, 132-file snapshot inventory, private candidate ref |
| 2026-08-14T01:47:45Z | TASK-0110/TASK-0115/TASK-0116 | operator contract hold | Three terminal runs represented three distinct causes: parallel-unsafe promoted test, unimplementable path-authority contract, and false reviewer-routing causal claim | With `operator-proxy:codex` authority, rejected all three as integration inputs, retained STOP, corrected task/DAG/plan/report, and prepared supported unpark only after a clean control checkpoint. | Top decision entry, seven-file amendment diff, validated DAG, snapshots and candidate refs |
| 2026-08-14T02:21:34Z–02:24:23Z | TASK-0110/TASK-0115/TASK-0116 | frozen reset handoff | All three amended tasks were ready, but their evidence-retained blocked worktrees could not be reset while STOP was present | Preserved old inventories, used a bounded bare resume, then launched exactly three supported direct `drive --reset` calls from frozen head `97862d93`; verified new branches/leases/scopes before continuing | Unpark/resume/stop events, worktree reflogs, new lease JSON, batch id |
| 2026-08-14T02:33:43Z | TASK-0116 / rel-08-route-transcript | operator quarantine | Primary accepted `c5a2842a`, but exact-contract review found `review` was tested instead of literal `probe` | Removed accepted inbox packet before import/integration, blocked lease, retained exact candidate/tree and full audit evidence, and amended the literal fixture | Quarantine manifest `03301456...`, candidate ref, RED/GREEN hashes |
| 2026-08-14T02:44:43Z | TASK-0110 / rel-02-try-hygiene | paired-audit quarantine | Primary accepted `fa95b8dc`; post-accept paired audit returned `needs-fix` with four blockers | STOP prevented the queued packet from racing reconcile. Removed packet before import, blocked lease, retained both audits and exact candidate, and amended all four proofs | Quarantine manifest `af62da87...`, primary/paired runner results, candidate ref |
| 2026-08-14T03:10:54Z–03:15:00Z | TASK-0115 / rel-07-run-control | `escalate-infra` plus operator rejection | Attempt-2 auditor accepted, final refresh failed `147124 >= 100000`; operator review also found non-fresh RED lineage and a valid-control timeout-0 regression | Did not recover as accepted; the root packet stayed `needs-review` and never entered inbox. Pinned exact candidate `032a32c0` as evidence, kept task/lease blocked, and amended for a truly fresh base plus timeout-0 proof | Final-refresh log, attempts index/run status, audit, needs-review packet, candidate ref, FR-051 |
| 2026-08-14T04:15:47Z–04:38:28Z (binding record 04:40:33Z) | TASK-0110 / rel-02-try-hygiene | fresh v3 accepted hold | Fresh candidate `7ca9c5c1` passed exact scope/source checks, the genuine RED-to-GREEN contract, host gate, three raw verifier executions, primary audit, and a manually forced independent paired audit with no findings/agreement | Restored STOP immediately after native acceptance, preserved the one inbox packet without import/reconcile, verified root/manifest/inbox SHA `264577d6...`, and pinned the exact candidate under a create-only private ref | Run/attempt evidence, primary audit, paired record `7020332c...`, raw/result/summary/envelope hashes, STOP and inbox |
| 2026-08-14T05:13:04Z | TASK-0110 / rel-02-try-hygiene | `integration-gate-red` / `rerun-tests` | Exact staged integration was 194/195; only unchanged `test-console-server.sh` failed because host capacity rounded to its 99% watch threshold. Source integrity remained verified and both TASK-0110 tests passed. | Accepted the decider's reversible rerun disposition, retained STOP, performed exact disposable-fixture cleanup, independently verified protected paths/control state, and required focused 275/275 plus a fresh full integration before merge. | Failed gate/report `110d1b9e...` / `da9a377e...`, decisions entry, cleanup record `96239033...`, console replay `53777ccd...` |

## Evidence capture checklist

For each worker, retain or reference the run directory, `attempts/index.json`, attempt archive, worker/auditor
logs, per-try runner results and provider envelopes, `audit.json`, gate-check artifacts, run-status records,
session metadata, dispatch/lease records, imported packet and audit packet, and the relevant event-log slice.
Capture failing worker traces before any 0.18.0 infra retry can overwrite them.

## Current active-state snapshot

- The fresh TASK-0110 reset ran from exact control checkpoint
  `9487683176cd5a93abddae9ffdce9b84532e0ac2`/tree
  `949e77752af11ca4ba277b14203a50405fb86cf3`. Acceptance/report evidence was checkpointed as
  `b042f8c4`, and native import produced control checkpoint `72726cee`. After one environmental red and its
  recorded recovery, retry pre-head `3a104dce6ec2d38757bbc8cffc6a8cf92194d551` merged exact worker
  `7ca9c5c1` as current product head `1b69af277f96f3f1b5cf3c904abebddfa4074469`/tree
  `923a88ca445c0684f66905f9ee8ab0cb3f483baf` on `agent/integration`. It descends from the v3
  activation-decision checkpoint `2bf02d3a935bf89c7630caf4d9bf9e15a66e95b1`, recovery-contract checkpoint
  `03a66438d24431fb62427b336aeabd68df2b3019`, amended-wave launch
  `97862d9370649c90ae67c825ed5d14ca3d37e530`, and first-wave control
  head `9f460e09bcca91ec9ee3446896edc5340a0ed1ae`. Ancestor merge `9d9c41f2`
  has the exact TASK-0109 tree, expected parents, and six owned paths; rel-01 promotion remains bound to
  exact launch checkpoint `9c1f2e7b`/tree-index `af2f0cce`.
- STOP remained present through the 05:55:27Z successful native integration retry. No Singular auto, reconcile,
  drive/worker writer, integration/gate process, origin lock, or Git-operation lock remains. The earlier paired
  pass was read-only with respect to the accepted candidate; no post-integration reconcile or promotion ran.
- Gates are now 3/18. TASK-0108/TASK-0109/TASK-0110 are `integrated`, and rel-00/rel-01/rel-02 are
  authoritatively passed under STOP;
  TASK-0115/TASK-0116 remain `blocked` under explicit amended contracts; the other 13 sprint tasks are
  `ready`—12 non-release tasks plus rel-99.
- The imported corpus is now 110 product packets plus 110 audit sidecars. The active inbox is empty; imported
  `RUN-20260814T041625Z-15168.json` remains byte-identical to its accepted root at SHA-256 `264577d6...`, and
  its imported audit is SHA-256 `40cb23e2...`.
  Five packets are recoverably quarantined: three superseded TASK-0109 recoveries plus the earlier rejected
  TASK-0110 and TASK-0116 packets. Rejected exact candidates `fa95b8dc`, `032a32c0`, and `c5a2842a` remain under create-only
  operator refs alongside the two first-wave refs; accepted exact candidate `7ca9c5c1` is separately pinned at
  `refs/singular/operator-candidates/TASK-0110/RUN-20260814T041625Z-15168-attempt-1`. TASK-0110's old
  uncommitted diff and all first-wave snapshots remain inventory-bound. The older artifacts are not acceptance,
  import, integration, or promotion authority; only the current exact packet/audit were imported. The first
  staged integration created no merge commit; retry merge `1b69af27` has exact parents/tree/three-path delta.
  The authoritative event log has 3,373 lines and still contains exactly the original eight `resume-run`
  fixture events.
- Configured/effective capacity remains 3/3. The earlier direct wave launched TASK-0110/TASK-0115/TASK-0116
  from one exact base in the same second. The later TASK-0110-only reset ran from exact base `94876831` under v3,
  stayed source/scope clean, and produced accepted `7ca9c5c1`. Its exact packet is imported; the first integration
  failed only the environmental console disk-watch condition, and the retry passed 195/195/source clean before
  creating exact merge `1b69af27`.
- Runtime is now the absolute, recursively `uchg` v3 overlay
  `singular-0.18.0-canary-rel01-v3-manifest-bind-fr050-20260814t025814z`, selected only through
  `SINGULAR_ENGINE_HOME` with existing-packet auto-heal OFF. It differs from the frozen rel-01-v2 predecessor
  only at `engine/l1-drive.sh`; the other 299 entries, including the provider-correct
  `evidence-manifest.sh`, are byte-identical. Its bundle is `79d255df...`; activation record is
  `4da4846e...`. Both waves verified that
  Codex cached-input charging is correct, while reproducing the fixed cumulative canary's terminal-handoff
  defect at 101,302, 178,060, and now 147,124 fresh primary-reviewer input. The active per-process v3
  mitigation is independently verified and recursively frozen: l1 SHA `ebec05d7...`, bundle `79d255df...`,
  metadata `71c08fd0...`, and post-freeze proof `53cd2874...`. The fresh native acceptance exercised that
  overlay's clean path end-to-end and left root/manifest/inbox correctly bound at `264577d6...`. V3 deliberately
  remains frozen and lacks TASK-0110's two integrated cleanup lines; rel-02 promotion is now exact and green,
  but no later L1 drive may start until a new independently verified composite overlay is frozen and selected
  per process. The disk metric ended promotion at 98.512% (rounded 99), so that handoff also requires a fresh
  below-threshold capacity preflight.
- No push, tag, publish, install, current-symlink/default flip, blind unpark, old-candidate cherry-pick, or
  tracked driver engine patch occurred. All exceptional recovery and exact-tree proof actions remain in
  ignored, hash-indexed operator evidence.

## `rel-99-release` readiness and operator handoff

- [ ] All non-release nodes have terminal acceptable outcomes.
- [ ] All parked tasks have explicit operator disposition.
- [ ] Full release task evidence and compatibility checks are present.
- [ ] Field-report canary is green and this report is complete.
- [ ] No unresolved finding makes promotion unsafe.
- [ ] Operator has reviewed the exact release diff and evidence.

Recommendation: **not yet ready for rel-99 promotion**. Bootstrap recovery is complete and rel-00/rel-01/rel-02
are green, but 15 sprint tasks remain unfinished: TASK-0115/TASK-0116 are blocked under corrected contracts,
12 other non-release tasks are ready/dependency-
blocked, and rel-99 is ready but operator-gated.
No release-candidate evidence exists. Five packets remain quarantined: three superseded TASK-0109 packets and
the earlier rejected TASK-0110/TASK-0116 acceptances. Exact candidate
`b874a874` is integrated as merge `9d9c41f2` after a 195/195 staged-tree gate and promoted by a fresh 195/195
exact-head proof at `9c1f2e7b`. The immutable successor runtime is verified and active by environment behind
STOP. Neither three-lane wave produced an import or integration. The fresh wave's three exact candidates are
preserved and rejected as authority; its two accepted packets were quarantined, while TASK-0115 produced no
accepted or inbox packet and retained only a needs-review evidence root. The later TASK-0110 reset produced
accepted candidate `7ca9c5c1`; its manifest-bound packet/audit were imported under STOP with primary and paired
agreement. Its first staged integration failed closed at 194/195 only on the environmental 99% console disk
watch, then left no merge residue. Exact fixture cleanup restored the application metric to 98% and the focused
console suite passed 275/275; the fresh full integration then passed 195/195 and created exact merge
`1b69af27`. Rel-02 promotion independently passed another 195/195 and its authoritative v1 gate validates.
A frozen composite runtime remains required before later drives. FR-047 is
assigned to rel-06 and FR-049 to the rel-99 operator-disposition
inventory; FR-048/FR-051 and the permanent FR-050/FR-052 remedies remain release blockers. FR-053 is
operationally resolved for this retry and is not a new release blocker. V3 now contains the
fresh native L1 binding/secret-ordering path, but rel-05 has not yet shipped the shared native/deterministic
finalizer. Rel-99 must remain
pending until every non-release gate is
authoritative/passed, every park and material finding has explicit disposition, the exact release diff and
synchronized version surfaces are green, the field-report canary and fresh-consumer proof pass, and the
hash-bound human-gate request is reviewed. No push, tag, publish, install, default flip, or release promotion
has occurred.
