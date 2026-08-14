# Reliability Sprint 01 — dogfood field report

- Status: active; `rel-00-contract` and `rel-01-per-try-logs` are integrated/promoted; TASK-0109 is
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

- First seen: 2026-08-13T17:11:36Z; frequency: 24/24 disposable verification tries across eight audited
  attempts (TASK-0108 once and TASK-0109 seven times). Every three-try group was entirely green and still
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
  `RUN-20260813T221358Z-8581/audit-verification-2-{0,1,2}.log`; matching normalization errors.
- Operator cost/action: about six seconds for TASK-0108, then roughly 39 seconds on TASK-0109 attempt 1 and
  66 seconds on its strengthened attempt 2. The amended retry added about 40 and 43 seconds for attempts 1
  and 2. The seed-restored run added about 75 and 77 seconds for attempts 1 and 2. All three TASK-0109 host
  executions in every group were redundant with the already-green worker gate. The literal-contract run added
  about 417 seconds for one three-try group, and reviewer input remained only evidence-verified.
- Resolution: open for a future sprint.

### FR-013 — the prescribed bounded evidence reader is unusable in the Codex auditor sandbox

- First seen: 2026-08-13T17:12:38Z; frequency: 8/8 audited attempts that invoked bounded retrieval
  (TASK-0108 plus all seven TASK-0109 audits).
- Classification: new environment/engine interaction; severity: medium; impact: degraded audit access and
  annoyed; non-blocking only because the auditor worked around it with direct reads.
- Symptom: `evidence-show.sh` failed while reading `packet.json` with `PermissionError: [Errno 1] Operation
  not permitted` on `/tmp/singular-evidence-retrieval-v0/<sha>.lock`. Repeated Git calls also emitted macOS
  `confstr`/xcrun cache-write warnings for `/tmp/xcrun_db-*` although Git itself succeeded.
- Expected: the evidence helper advertised to a sandboxed reviewer uses a writable per-run lock/cache path,
  and routine read-only Git evidence commands do not flood the reviewer transcript with host cache errors.
- Code anchor (0.18.0): installed `engine/evidence-show.sh` temporary retrieval lock; auditor prompt/tool
  contract assembled by `engine/l1-drive.sh`.
- Evidence: TASK-0108 and all three TASK-0109 run roots' auditor logs and verdict rationales. Both
  seed-restored-run reviewers again recorded the read-only cache-lock failure and used immutable Git/manifest
  inspection.
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

### FR-015 — accepted audit is terminalized as infrastructure failure by hard token-canary accounting

- First seen: 2026-08-13T17:14:03Z; frequency: 3/4 audits that returned `accepted` at a task-final handoff;
  classification: new reproduction of the terminal handoff/budget failure family targeted by this sprint.
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
- Evidence: all three run roots' `audit.json`, `attempts/index.json`, `run-status.json`,
  `evidence-manifest-final-refresh.log`, and per-role runner-result JSON files. TASK-0109's final refresh states
  the corrected cumulative values exactly: `139516 >= 100000` and `151702 >= 100000`.
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

- First seen: 2026-08-13T17:14:03Z; frequency: 3/3 final-refresh failures.
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
- Expected: a failed final refresh either atomically invalidates/removes the pre-audit manifest or leaves an
  explicit status that no consumer can mistake for final evidence.
- Code anchor (0.18.0): pre-audit/final-refresh lifecycle in `engine/l1-drive.sh:1677-1687` and manifest write
  sequence in `engine/evidence-manifest.sh`.
- Evidence: current `packet.json`, `evidence-manifest.json`, `audit.json`, and final-refresh log in
  `RUN-20260813T170836Z-93780`, `RUN-20260813T203430Z-96335`, and `RUN-20260813T211009Z-78320`.
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
  Resolution: open; optimize the exact inventory proof or isolate it behind a bounded fixture without weakening
  literal incoming-path assertions.

## Known-issue observation log

These are cost/frequency measurements, not new discoveries.

| Known issue | Occurrences | Time/token/evidence cost | Run/attempt evidence |
|---|---:|---|---|
| Context-route reviewer transcript mismatch causes fresh reviewer sessions | 3/3 reviewer resume opportunities | All TASK-0109 attempt-2 reviews selected `fresh/tainted` despite valid attempt-1 reviewer sessions. The fresh reviews charged 62,600, 68,806, and 45,651 input; the first two pushed their cumulative canaries over 100,000, while the third remained under at 93,476. | Context events and reviewer results in all three TASK-0109 run roots |
| Worker per-try logs overwritten on infra retry | 0 worker-infra retries; 4 adjacent policy retries | No infra retry fired. All four TASK-0109 attempt-2 policy retries used the old controller's compatibility-log lifecycle; the latest gate-red archive again ran before TASK-0109's product fix could become active. | All four TASK-0109 `attempts/1/` directories versus run roots |
| 240-minute stale hard cap reclaims live work | 0 occurrences | No worker approached 240 minutes; the cap did not fire | TASK-0108 and all three TASK-0109 run-status/event slices |

## Active dogfood questions

| Question | Evidence to collect | Current answer |
|---|---|---|
| Does self-hosted audit catch weak worker output before integration? | Worker packet, audit verdict/findings, gate result, integration event | Mixed. Three earlier final auditors accepted packets later revoked by exact-contract review. In the fourth run, the native auditor accepted `b874a874` only after the authored gate and independent contract checks agreed on the direct parent, exact six-file tree, literal two-iteration hostile-state proof, and no ninth event. That exact candidate then passed native staged integration 195/195 and became `9d9c41f2`; this is one clean end-to-end acceptance, not enough to erase the prior audit escapes. |
| Are role budgets realistic; were mid-run raises needed and honored? | Session/run-control files, timeout events, operator actions, elapsed time | Variable. The first two TASK-0109 reviewer pairs charged 139,516 and 151,702 and terminalized accepted results. The seed-restored pair fit at 93,476. The terminal native auditor used 562,461 input / 476,160 cached / 7,496 output for a canary charge of 86,301, so no raise was needed. No deadline raise was requested; the hard canary has no supported raise. |
| Is dispatch fair across parallel lanes at concurrency 3? | Ready time, dispatch time, start time, completion time per node | Not yet evaluable: recovery has advanced the serial lane through authoritative rel-01 promotion, but the updated immutable runtime has not been activated and autonomous dispatch has not resumed. Parallel-lane measurement begins after that quiescent handoff. |
| What manual operator work should the engine perform or surface? | Every intervention and missing/ambiguous status signal | In addition to launch work, deterministic packet recovery, immutable snapshotting, exact-tree integration, status-mutation attribution, flaky-test isolation, proof cross-binding, long-job polling, cumulative-token reconstruction, false-event attribution, staged-tree identity reconstruction, and per-test timeout-margin monitoring all required manual operator work. |

## Task outcomes and attempts

Product attempts and audit/recovery/integration tries are recorded separately. A dash means the node has not run yet.

| Task | Node | Outcome | Product attempts | Audit / recovery / integration tries | Worker run IDs | Gate / packet evidence |
|---|---|---|---:|---:|---|---|
| TASK-0108 | rel-00-contract | integrated as `41380c1b`; authoritative gate passed at 20:27:09Z | 1 | 4 / 2 / 4 | `RUN-20260813T170836Z-93780`; recovery `RUN-20260813T182550Z-RECOVERY-TASK-0108-12256` | Immutable source snapshot; accepted imported packet/audit; final exact-tree 194/194; `rel-00-contract.gate-result.json` |
| TASK-0109 | rel-01-per-try-logs | integrated as `9d9c41f2`; authoritative gate passed at 00:47:13Z under STOP | 8 | 7 / 3 / 1 (+1 promotion) | Prior three run IDs plus terminal `RUN-20260813T221358Z-8581`; accepted recoveries `...210341...`, `...212941...`; integration `ORIGIN-20260813T230100Z-TASK0109-NATIVE`; promotion `ORIGIN-20260813T235754Z-8483` | Exact six-file `b874a874` accepted with no findings and charge 86,301; native staged integration and exact-head promotion each passed 195/195; v1 gate/hash bindings validate, fake events still eight |
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
| 2026-08-13T20:54:39Z | TASK-0109 / rel-01-per-try-logs | `escalate-infra` | Attempt-2 auditor accepted with all eight prior findings resolved; corrected cumulative auditor fresh input then failed `139516 >= 100000` | Deterministic, not a transient environment failure. Retained STOP, did not blind-unpark, and preserved exact worker head/run evidence for bounded recovery. | `RUN-20260813T203430Z-96335/{audit.json,evidence-manifest-final-refresh.log,attempts/index.json,run-status.json}`, decision and lease |
| 2026-08-13T21:04:21Z | TASK-0109 / rel-01-per-try-logs | operator recovery | Exact-head deterministic reruns passed with no new model call; source breach stayed explicit in provenance | Accepted/imported only into the stopped control plane, then immediately re-evaluated before any integration | Recovery run, provenance, immutable source snapshot |
| 2026-08-13T21:05:30Z | TASK-0109 / rel-01-per-try-logs | operator quarantine | Accepted audit had missed FR-029's authoritative event-log pollution | Quarantined packet/audit intact, restored blocked lease, preserved candidate ref, and amended the task for a fresh hermetic retry; no integration attempted | `.singular-state/operator-quarantined-imports/TASK-0109/RUN-20260813T210341Z-RECOVERY-TASK-0109-29558/manifest.json` |
| 2026-08-13T21:29:03Z | TASK-0109 / rel-01-per-try-logs | `escalate-infra` | Amended attempt-2 audit accepted; final refresh then failed provider-correct cumulative `151702 >= 100000` | Deterministic budget park. Stopped, preserved exact head `ed8fc1bc`, and used zero-model exact-head recovery with the breach explicit | `RUN-20260813T211009Z-78320` audit, attempts, final-refresh log, source snapshot |
| 2026-08-13T21:34:00Z | TASK-0109 / rel-01-per-try-logs | operator quarantine | Accepted audit missed real-checkout lstat, ten-cycle low-disk, and live resume-fallback proof regressions | Quarantined second packet/audit intact, preserved candidate ref for evidence only, and hardened the task to mandate seed `08bcb2b0`; no integration attempted | `.singular-state/operator-quarantined-imports/TASK-0109/RUN-20260813T212941Z-RECOVERY-TASK-0109-19936/manifest.json` |
| 2026-08-13T22:05:49Z | TASK-0109 / rel-01-per-try-logs | operator quarantine | Primary and paired accepted audits both missed explicit in-process fixture repetition `>=2` and literal incoming caller checkout/state/event identity | Retained STOP, revoked the third accepted result, preserved exact candidate `ede05b0e`, and quarantined its inbox packet before import/integration | Clarified third quarantine manifest `c01d6384...`, paired audit, exact-contract review |
| 2026-08-13T22:50:44Z | TASK-0109 / rel-01-per-try-logs | accepted hold | Native audit accepted exact candidate `b874a874` with no findings; provider-correct charge 86,301 remained below the hard bound | Wrote STOP before import/integration so control state can be checkpointed and the exact-tree adapter/runtime overlay handoff remain quiescent | Terminal run audit, final manifest, inbox packet, STOP |
| 2026-08-13T23:50:12Z | TASK-0109 / rel-01-per-try-logs | integration resolved | Imported native packet and staged exact candidate passed 195/195 with verified source integrity; merge `9d9c41f2` has the expected parents/tree | Kept STOP after integration; did not publish the rel-01 gate or activate a new runtime until the evidence checkpoint is committed | Integration run, gate report/log SHA, merge object, lease/task status |
| 2026-08-14T00:47:13Z | TASK-0109 / rel-01-per-try-logs | promotion resolved | Fresh 2,959s proof passed 195/195 at exact head `9c1f2e7b`; every v1 evidence hash/binding, gate validation, and rel-01 `area-gate` passed | Retained STOP; deferred activation of TASK-0109's controller bytes until a new immutable overlay is built and verified | `ORIGIN-20260813T235754Z-8483`, rel-01 gate result/evidence, launch/terminal identity snapshots |

## Evidence capture checklist

For each worker, retain or reference the run directory, `attempts/index.json`, attempt archive, worker/auditor
logs, per-try runner results and provider envelopes, `audit.json`, gate-check artifacts, run-status records,
session metadata, dispatch/lease records, imported packet and audit packet, and the relevant event-log slice.
Capture failing worker traces before any 0.18.0 infra retry can overwrite them.

## Current active-state snapshot

- `agent/integration` contains promotion-evidence commit `6b102c54d464a27085913a19becafe4b9ee85bdd`,
  tree `b043797894233fd7d413fe19407494eaa692be98`; the field-report checkpoint descends from it.
  The gate itself binds exact launch checkpoint
  `9c1f2e7b5703d00f476b2115442938c57779f813`/tree-index `af2f0cce5c9df22524a7297a8fa03013e62fa4a8`,
  whose committed field-report blob matched the launch checkout. Ancestor merge `9d9c41f2` has the exact
  TASK-0109 tree, expected parents, and six owned paths.
- STOP remains present after TASK-0109's native promotion handoff; origin and Git-operation
  locks are absent and no worker process remains. The general autonomous loop has not yet been restarted.
- Gates: 2/18. `rel-00-contract` and `rel-01-per-try-logs` are authoritative/passed; TASK-0108 and
  TASK-0109 are `integrated`. The other 16 task files remain `ready`: 15 non-release tasks plus rel-99.
- Packets: the imported corpus is 109 product packets—the historical 107 plus TASK-0108 and TASK-0109—with
  their audit sidecars; the active inbox is empty. Three earlier TASK-0109 packets remain recoverably
  quarantined. The terminal packet, native audit, 195/195 integration log, and exact merge object are retained;
  the authoritative event log still contains exactly the original eight `resume-run` fixture events.
- Resources: configured/effective slots are 3/3; current filesystem headroom is about 39 GiB with no capacity
  pressure.
- Provider/runtime proof: the predecessor immutable 0.18.0 overlay changes only
  `engine/evidence-manifest.sh`, keeps raw provider usage, charges coherent Codex cached replay correctly,
  and was active for all twelve primary earlier TASK-0109 role calls plus the sampled paired review.
  Effective runner/model were Codex and `gpt-5.6-sol`; the terminal native auditor's corrected charge was
  86,301. Verified successor `singular-0.18.0-canary-rel01-v2-b874a874` exists at the exact ignored overlay
  path, differs from that predecessor in exactly the three promoted rel-01 controller paths, preserves the
  evidence-manifest fix, and has 300 manifest entries / 301 recursively immutable (`uchg`) filesystem objects.
  Its bundle manifest is `eb42e919a61232473f28a97c3370fa3925d589988fd8ae3023698e112cfcf25c`
  and metadata file is `df2a56ffa8ae99fe260046dd6ed94a3cb02d205ec5a4492f52a472cc3398f80c`;
  its 58-second focused gate and the existing 195/195 full-suite/promotion proof are hash-bound in the overlay
  record. The successor is now selected through `SINGULAR_ENGINE_HOME` only. Its immutable metadata retains
  the pre-activation build status `verified-not-activated`; the later environment activation passed status,
  health, and DAG preflight without altering tracked scaffolds. Its activation record is hash-bound as
  `b4eb1d08e1e7ecf06fff1082b0fdd809dc32f53d8f66c52d8bf941c258b55588`. STOP remains present,
  health reports 3/3 slots and 34.3 GB free, and the predecessor is retained intact as a superseded rollback
  artifact rather than deleted. No install, symlink/current pointer, default-version, or push change occurred.
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

Recommendation: **not yet ready for rel-99 promotion**. Bootstrap recovery is complete and rel-00/rel-01 are
green, but 16 tasks remain (15 non-release tasks plus rel-99) and no release-candidate evidence exists. Three superseded TASK-0109 packets remain
quarantined; the fourth candidate `b874a874` is natively accepted and integrated as exact merge `9d9c41f2`
after a 195/195 staged-tree gate, then promoted by a fresh 195/195 exact-head proof at `9c1f2e7b`. Its literal contract includes two same-process archive invocations against
distinct roots, recursive literal caller checkout/state/event guards after each and final drain, and no ninth
fake event. The immutable successor runtime is fully verified and activated by environment behind STOP; it is
ready for resumed frontier dispatch—not for release promotion. Rel-99 must remain pending until every non-release gate is
authoritative/passed, every park and material finding has explicit disposition, the exact release diff and
synchronized version surfaces are green, the field-report canary and fresh-consumer proof pass, and the
hash-bound human-gate request is reviewed. No push, tag, publish, install, default flip, or release promotion
has occurred.
