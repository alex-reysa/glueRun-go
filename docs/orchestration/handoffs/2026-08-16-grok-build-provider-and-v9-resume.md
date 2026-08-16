# Session handoff — Grok Build bootstrap, then resume the paused V9 recovery

Date captured: 2026-08-16 (Europe/Madrid)

## First instruction to the next agent

Your **first implementation task** is a session-owned, strictly timeboxed
**25–30 minute Grok Build bootstrap**. Do not create a second adapter blindly:
this repository already contains `engine/grok-run.sh` and
`tests/test-grok-run.sh`. Inspect the installed CLI and the existing adapter,
then finish or harden only the gaps needed to use Grok as a Singular provider.
The timebox also includes a truthful operator-visible quota/availability
indication.

After that timebox, stop Grok work, report its exact result, and resume the
paused V9 recovery only if the adapter's focused tests and one bounded live
probe pass. Do not turn this into a provider-framework refactor or a wholesale
third-party import.

There is one mandatory read-only safety check before editing: confirm the STOP
sentinel and the partial V9 freeze described below. That check is not a competing
task; it protects the paused recovery while the Grok bootstrap is performed.

## Current repository and host facts

- Repository root:
  `/Users/alejandro/Desktop/999. PROJECTS/pmgo-orchestration-engine`
- Pinned recovery base commit:
  `442dd014ba630f023faed346f66acbaa150959cd`
- Pinned base tree:
  `ca52635540811b1440019db3e0bef63cee885f29`
- Current branch: `agent/integration`.
- Only the main repository worktree is registered.
- Existing unrelated tracked edits must be preserved:
  `docs/orchestration/decisions.md`, `TASK-0112.md`, `TASK-0115.md`, and
  `TASK-0120.md`.
- `.singular-state/STOP` was a real empty mode-0644 file at handoff time.
- `.singular-state/locks/` was empty at handoff time.
- Disk was critically tight: about 2.1 GiB free. Do not clone large reference
  repositories or create a new worktree unless space has first been recovered.
- Installed Grok executable: `/Users/alejandro/.grok/bin/grok`.
- Installed Grok version: `grok 1.0.4 (d846eb93d94d)`.
- The installed CLI supports `--prompt-file`, `-p/--single`, `--cwd`,
  `--output-format`, `--model`, `--reasoning-effort`/`--effort`,
  `--sandbox`, `--allow`, `--deny`, `--always-approve`,
  `--system-prompt-override`, `--max-turns`, `--no-memory`, and
  `--no-subagents`.

Re-run these facts rather than trusting them blindly:

```bash
git status --short
git worktree list --porcelain
stat -f '%N|%HT|%z|%Lp|%Sf' .singular-state/STOP
find .singular-state/locks -mindepth 1 -maxdepth 1 -print
grok --no-auto-update version
grok --no-auto-update --help
df -h .
```

Keep STOP present throughout the Grok bootstrap. Do not launch TASK-0112 or
TASK-0115 during the timebox.

## The 25–30 minute Grok Build bootstrap

Start a wall-clock timer. The goal is a usable, evidence-backed adapter, not
perfect abstraction.

### Minute 0–5: audit what already exists

1. Read `engine/grok-run.sh`, `tests/test-grok-run.sh`, the Grok sections of
   `engine/lib.sh`, and Grok checks in `engine/doctor.py`.
2. Capture `grok --no-auto-update version` and the relevant help flags.
3. Confirm authentication without exposing tokens. Prefer an official,
   non-mutating CLI probe such as `grok models`; do not read or print credential
   files. A failure is a real failed/unknown authentication state.
4. Note that `engine/doctor.py` currently treats Grok authentication as
   unconditionally true. That is a concrete hardening candidate.
5. Confirm the existing adapter's runner contract with
   `engine/grok-run.sh --describe-contract` and its provider selection with an
   explicit `SINGULAR_RUNNER` path.

### Minute 5–20: make the smallest useful corrections

Prioritize these in order:

1. **Installed CLI compatibility.** Use only flags confirmed by the installed
   CLI and official documentation. Keep `--no-auto-update` on diagnostic/live
   probes so the bootstrap cannot change the executable mid-run. The current
   installed CLI does support `--prompt-file`; retain it unless an actual test
   proves it defective.
2. **Structured result correctness.** Preserve the provider's raw JSON envelope
   and normalize `.text` into the Singular last-message contract. Never infer
   status from model-authored prose, repository text, or stderr banners.
3. **Quota and overload truth.** Reuse the existing `runner-result.v0` and
   `provider-error.v0` machinery in `engine/lib.sh`:
   - HTTP 429 from a terminal provider envelope means `usage-limit` / `quota`.
   - A provider-controlled 403 entitlement denial is distinct but also blocks
     useful work.
   - HTTP 503/529 means provider overload, not quota.
   - Token counters may be recorded only when the Grok envelope supplies them.
   - Never manufacture a remaining percentage, reset time, or token count.
4. **Operator-visible indication.** Add the narrowest surface that reports:
   installed version, authentication/model probe result, last structured Grok
   state (`available`, `quota-limited`, `entitlement-denied`, `overloaded`, or
   `unknown`), evidence timestamp/reference, and exact remaining/reset data only
   when the provider supplied it. `unknown` is the correct value when the CLI
   exposes no machine-readable quota total. A successful bounded live request
   proves availability now; it does not prove an unlimited or known remaining
   quota.
5. **Containment.** Preserve session/process-group timeout cleanup, the
   read-only journal restore, exact worktree targeting, and output capture.
   Do not weaken these to make a live smoke pass.

Prefer changes to these already-scoped files:

- `engine/grok-run.sh`
- `tests/test-grok-run.sh`
- `engine/doctor.py` and its focused test only if the authentication/availability
  indication can be added safely inside the timebox
- the provider failure-contract test only for exact Grok envelope shapes

Avoid editing `engine/lib.sh`, the frozen engine overlays, V7/V8/V9 authorities,
or recovery task documents unless a demonstrated compatibility bug makes it
unavoidable. Do not change `singular.config.json`'s default provider during this
bootstrap.

### Minute 20–27: focused proof and one bounded live probe

At minimum run:

```bash
bash -n engine/grok-run.sh
bash tests/test-grok-run.sh
bash tests/test-provider-failure-contract.sh
```

Run the relevant doctor test if `engine/doctor.py` changed. Keep any live probe
to one cheap, single-turn request, with `--no-auto-update`, no subagents, no
memory, a bounded turn count/timeout, and no write permissions. Retain the raw
provider envelope and normalized runner result in a disposable evidence
directory, redact secrets from the report, and delete only disposable probe
state after its hashes/result have been recorded.

The live probe must demonstrate all of the following before Grok is used for a
recovery lane:

- executable and authentication/model access are real rather than assumed;
- output JSON is parsed into a valid Singular message;
- runner result identifies `provider: grok` and the correct success/failure
  class;
- a quota/overload failure, if encountered, is reported from structured
  provider evidence and causes no retry storm;
- read-only containment leaves the target tree byte-identical.

### Minute 27–30: hard stop and hand back to recovery

At 30 minutes, stop even if optional polish remains. Report:

- files changed;
- exact Grok version/model and authentication probe outcome;
- focused test results;
- live probe result and structured quota/availability state;
- whether Grok is safe to use now;
- any deferred issue.

If the core path is not green, keep STOP present and resume the recovery with
the previously proven provider rather than extending the Grok task. If it is
green, use the adapter by absolute path for the resumed invocation:

```bash
SINGULAR_RUNNER="$PWD/engine/grok-run.sh"
```

Do not commit, rebase, or advance HEAD before the pinned V9 recovery completes.
V9 and the recovery snapshots bind commit `442dd014...`. Keep the Grok patch
scoped and uncommitted, record its diff/hash, and invoke it by its absolute root
path. Integrate/commit it after the recovery boundary has been completed and
re-audited.

## Acceptance criteria for the Grok quick task

The quick task is complete only when:

- the session recognized and audited the existing adapter instead of adding a
  duplicate;
- installed Grok 1.0.4 command construction is covered by a deterministic
  argv test;
- success, malformed JSON, terminal provider error, timeout/descendant cleanup,
  signal cleanup, and read-only restoration remain green;
- structured Grok 429 quota and 503/529 overload classification are proven and
  kept distinct;
- missing quota totals render as `unknown`, never as a guessed number;
- doctor/health does not claim Grok authentication merely because the provider
  name is `grok`;
- one bounded live read-only probe succeeds, or the session explicitly records
  the structured reason it could not run;
- no frozen authority, snapshot, overlay, STOP state, or unrelated dirty file
  changed.

## Source/reference policy

Use the sources in this order:

1. [xAI Grok Build overview](https://docs.x.ai/build/overview)
2. [xAI headless and scripting guide](https://docs.x.ai/build/cli/headless-scripting)
3. [xAI CLI reference](https://docs.x.ai/build/cli/reference)
4. [xAI Grok Build source](https://github.com/xai-org/grok-build)
5. [OpenCode](https://github.com/anomalyco/opencode/)
6. [create-t3-app](https://github.com/t3-oss/create-t3-app)

The xAI source is the primary implementation reference for CLI/ACP behavior.
OpenCode is the more relevant secondary reference for provider abstraction,
process handling, and OpenAI-compatible/xAI integration patterns.
create-t3-app is useful mainly for CLI UX, validation, modular command layout,
and test organization; it is not a provider adapter to transplant wholesale.

Direct copying/importing is allowed only when it saves time and remains small:

- pin the exact upstream commit and source file;
- record whether code was copied, adapted, or merely inspired;
- preserve required copyright/license notices;
- add the minimal attribution required by the upstream license;
- adapt code to Singular's runner/result/containment contracts rather than
  importing a second framework.

License check performed for this handoff: xAI Grok Build uses Apache-2.0;
OpenCode and create-t3-app use MIT. Recheck the exact pinned revision before
copying because upstream files and licenses can change. Do not clone any of
these repositories during the quick task while disk remains near the reserve;
inspect individual files remotely or use a very narrow, disposable sparse
checkout only after confirming adequate free space.

## Paused V9 recovery boundary

V9 was deliberately paused after all 13 files in its module were frozen but
before the module directory itself was frozen. Do not rebuild or edit these
bytes.

Module:

`/Users/alejandro/Desktop/999. PROJECTS/pmgo-orchestration-engine/.singular-state/operator-configs/recovery-contract-v9`

Expected state:

- geometry: 13 regular files plus the module directory, zero links;
- all 13 files: `uchg`;
- module directory: not yet `uchg`;
- manifest: 12,523 bytes, SHA-256
  `c4bc6d7eaccb703d411c58d6c1170eec0715070309e6855a49713db203fa4f7a`;
- payload projection:
  `ab6e01c953040c7329450e22e35e514f2ca0b430ad1a77b8341339accea06fb4`;
- semantic projection:
  `6c46bf419ffdd7074419ba740e9e537029159dec2ca0fc854a1b4bd17e018f51`.

External V9 objects were already created, verified, and frozen:

- `/private/tmp/singular-recovery-verifier-v9.sh`
  - 2,832 bytes, mode 0755, nlink 1, `uchg`
  - SHA-256 `e2b523aa69d56b1b4c7ff610c3f1d4f2838995bf3eca355ace32d8206e3a2818`
- `/private/tmp/singular-recovery-guard-v9.py`
  - 2,686 bytes, mode 0755, nlink 1, `uchg`
  - SHA-256 `5956f6612d03998e504c616f986be9d3ca94bea5fe75683520716db9005a363f`
- `/private/tmp/singular-recovery-prompt-v9.sh`
  - 13,671 bytes, mode 0755, nlink 1, `uchg`
  - SHA-256 `41baadcdac2eff18ac50fbe2164f617248500d1497d947104c926df0f8487172`

After the Grok timebox, the next V9 action is narrowly defined:

1. Reconfirm STOP, empty locks, no active Singular/L1/provider lane, the exact
   manifest hash, all 13 file flags, and the three external object hashes.
2. Set `uchg` on the V9 **module directory only**. On macOS use
   `chflags uchg "$V9_MODULE"`; do not pass GNU-style `--` to `chflags`.
3. Verify the exact 14-object geometry and `14/14 uchg`.
4. Invoke the immutable verifier directly:

   ```bash
   /private/tmp/singular-recovery-verifier-v9.sh --require-frozen
   ```

5. Require its exact verified-frozen PASS before sourcing the active prompt or
   launching a recovery lane.

Any mismatch means HOLD: keep STOP present, do not unfreeze/rebuild, and report
the exact drift.

## Preserved recovery evidence

The last TASK-0115 recovery attempt was contained and snapshotted at:

`.singular-state/recovery-snapshots/RUN-20260815T113002Z-77339/20260815T113942Z-unnumbered-post-marker-composite-inspection-hold`

Expected frozen state:

- 135/135 objects `uchg`;
- inventory SHA-256
  `81759781a43c0ad91563c83904de58bf479e2652ca009b40441de4230596ca7c`;
- `snapshot.json` SHA-256
  `22e609287cfb25d9ce3c0a646bfae511ab2079318fc9bd66a6b93ab64be3d7b4`.

The TASK-0115 worktree and its R10B seed-lock were already removed only after
that snapshot passed its post-freeze audit. The branch and live run/lease/event
records were retained. TASK-0112 remains paused and must not be launched under
V8; V9 is the authority intended to remove the ambiguous unnumbered-inspection
exception.

## Space discipline

The previous session removed obsolete worktrees, including TASK-0120's
registered worktree and four disposable `task0279-controller.*` nested
worktrees, while preserving their branches/commits and evidence. At this
handoff, `git worktree list` showed only the main repository. There is therefore
no known extra registered worktree to delete.

Before deleting anything else:

1. use `git worktree list --porcelain`, `du`, and process/handle checks;
2. distinguish frozen recovery evidence from disposable caches;
3. never delete `.singular-state/recovery-snapshots`, live run records, V7/V8/V9
   authorities, retained branches, or the three frozen V9 external objects;
4. prefer pruning disposable caches or clearly orphaned temp directories;
5. report exactly what was removed and the recovered space.

## Resume decision

The intended order for the next session is:

1. read-only STOP/V9 safety preflight;
2. 25–30 minute Grok adapter + quota indication bootstrap;
3. hard stop and focused evidence report;
4. finish the one remaining V9 directory freeze and verifier step;
5. only after the V9 verifier passes, resume the recovery flow, using
   `SINGULAR_RUNNER="$PWD/engine/grok-run.sh"` if the Grok bootstrap passed;
6. keep the dispatch base pinned to `442dd014...` and retain STOP during all
   setup/checkpoint work.

Do not silently substitute a new base, commit the Grok patch early, resume via
V8, or continue Grok polishing past the timebox.
