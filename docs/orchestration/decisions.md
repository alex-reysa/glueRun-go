# Decisions

## Decision Log

### 2026-07-11T00:34:25Z — TASK-0004 — integrate

- Run: `ORIGIN-20260711T003109Z-57904`
- Branch: `agent/foundation/TASK-0004-ctx-ab-arm-assign`
- Authority: origin
- Rationale: merged agent/foundation/TASK-0004-ctx-ab-arm-assign (8881207c2a9b2d0fd1e6082fbd9020b066c055e7) into agent/integration as 4938204e561797828742de0c5864ae0ea0d376b2; gate green; acceptance=accepted

### 2026-07-11T00:26:56Z — TASK-0003 — integrate

- Run: `ORIGIN-20260711T002339Z-82854`
- Branch: `agent/foundation/TASK-0003-gluerun-metrics-cli`
- Authority: origin
- Rationale: merged agent/foundation/TASK-0003-gluerun-metrics-cli (3e13d6e81ed99a6313394b1b0d3583d035771c6d) into agent/integration as 5193434e14da1b56204433d700f991fa3daa1709; gate green; acceptance=accepted

### 2026-07-11T00:26:15Z — TASK-0004 — accept

- Run: `RUN-20260711T001014Z-75963`
- Branch: `agent/foundation/TASK-0004-ctx-ab-arm-assign`
- Authority: origin
- Rationale: auditor accepted; regression gate green; scope clean

### 2026-07-11T00:04:53Z — TASK-0003 — decide:retry

- Run: `ORIGIN-20260711T000113Z-13926`
- Branch: `agent/foundation/TASK-0003-gluerun-metrics-cli`
- Authority: decider
- Rationale: integration-gate-red -> retry: Single deterministic failure (test-ctx-metrics-cli.sh): the metrics CLI writes a real .gluerun-state artifact, violating its no-side-effect contract — an in-scope, worker-fixable defect, not a transient flake or missing proof environment. Retries remain (0/3), so send it back to the worker to make the CLI honor the contract (no real state write) and re-run the gate.

### 2026-07-11T00:00:32Z — TASK-0003 — accept

- Run: `RUN-20260710T234736Z-29359`
- Branch: `agent/foundation/TASK-0003-gluerun-metrics-cli`
- Authority: origin
- Rationale: auditor accepted; regression gate green; scope clean

### 2026-07-10T23:44:21Z — TASK-0002 — integrate

- Run: `ORIGIN-20260710T234103Z-93793`
- Branch: `agent/foundation/TASK-0002-ctx-metrics-extractor`
- Authority: origin
- Rationale: merged agent/foundation/TASK-0002-ctx-metrics-extractor (83183ca8cbdb6afe208a16d1ec3658b79b0b19e9) into agent/integration as 416e0d5dd91b2bafdd59ba2cd257392b29e1e167; gate green; acceptance=accepted

### 2026-07-10T23:40:19Z — TASK-0002 — accept

- Run: `RUN-20260710T231904Z-27968`
- Branch: `agent/foundation/TASK-0002-ctx-metrics-extractor`
- Authority: origin
- Rationale: auditor accepted; regression gate green; scope clean

### 2026-07-10T23:04:27Z — TASK-0001 — integrate

- Run: `ORIGIN-20260710T230049Z-13462`
- Branch: `agent/foundation/TASK-0001-ctx-loader`
- Authority: origin
- Rationale: merged agent/foundation/TASK-0001-ctx-loader (efae80eb1daed91b699e79567f1b000975f8e318) into agent/integration as f4fe5f2120505653801e9ae1c71e9e6c57f20f50; gate green; acceptance=accepted

### 2026-07-10T22:56:00Z — TASK-0001 — accept

- Run: `RUN-20260710T224233Z-95503`
- Branch: `agent/foundation/TASK-0001-ctx-loader`
- Authority: origin
- Rationale: auditor accepted; regression gate green; scope clean

### 2026-07-10T22:29:49Z — TASK-0001 — decide:retry

- Run: `RUN-20260710T215122Z-1960`
- Branch: `agent/foundation/TASK-0001-ctx-loader`
- Authority: policy
- Rationale: fast-path: gate-red -> retry

### 2026-07-10T22:07:06Z — TASK-0001 — decide:retry

- Run: `RUN-20260710T215122Z-1960`
- Branch: `agent/foundation/TASK-0001-ctx-loader`
- Authority: decider
- Rationale: worker-no-packet -> retry: The L2 worker ended its turn with 'Suite is running. Waiting for completion notification from the monitor' — it kicked off the ctx-loader shell suite but returned before the monitor reported results, so no packet was emitted. This is a procedural stall (result subtype success, no error, no permission denials), not a real gate failure and not a missing external proof environment (the suite is pure bash: engine/lib.sh + tests/test-ctx-loader.sh, no DB). One retry remains (2 of 3 used), so re-run the worker and require it to block until the monitor delivers completion, then emit the packet honestly — do not weaken or skip the suite.

### 2026-07-10T22:02:35Z — TASK-0001 — decide:retry

- Run: `RUN-20260710T215122Z-1960`
- Branch: `agent/foundation/TASK-0001-ctx-loader`
- Authority: policy
- Rationale: fast-path: worker-no-packet -> retry

### 2026-07-09T20:15:36Z — TASK-0001 — decide:retry

- Run: `RUN-20260709T200707Z-7121`
- Branch: `agent/foundation/TASK-0001-ctx-loader`
- Authority: policy
- Rationale: fast-path: worker-no-packet -> retry


- 2026-07-10 (operator): TASK-0001 drive #2 hung ~25h in the regression gate —
  `test-codex-run-session.sh`'s mock codex `cat` blocked on inherited stdin
  under the detached l1-drive gate (passes when stdin is /dev/null). Fixed
  fail-closed in tests/run.sh (`</dev/null` per test). Engine gap noted for a
  future hardening task: the gate command runs UNBOUNDED — no
  GLUERUN_GATE_TIMEOUT_SEC analog to the worker's 1200s runner timeout, so a
  hung gate stalls a drive forever. Candidate: small engine_runtime task after
  S0 (not hand-patched now; engine/ changes go through the task pipeline).

- 2026-07-11 (operator): TASK-0001 drive #3 diagnosis. (a) worker-no-packet
  x2: the L2 model backgrounds the ~4.5min gate and ends its turn "waiting
  for the monitor" — fatal in one-shot claude -p. Fixed with an explicit
  single-turn/no-background hard rule in the docked L2 prompt. (b) gate-red:
  the drive exports consumer config into env; lib.sh ${VAR:-default}
  fallbacks keep leaked values inside sandboxed gate tests (env channel of
  the earlier config-file leak; leaked GLUERUN_RUNNER even replaced test
  stubs with the real CLI). Fixed fail-closed in tests/run.sh (scrub
  GLUERUN_* before running tests). Engine hardening candidates recorded:
  gate timeout + env-scrubbed gate invocation (future task with the
  gate-timeout item).

- 2026-07-11 (operator): FIRST AUDIT ESCAPE (S0 evidence). TASK-0003's CLI
  test asserted `! -e $ENGINE_HOME/.gluerun-state` — vacuously true in the
  pristine worker worktree, always false in the ops tree. Worker gate AND
  fresh auditor both passed it (both ran in the pristine environment);
  the integrate gate on the merged tree caught it red. Operator fixup
  3e13d6e (hermetic engine-home skeleton). Escape class: environment-
  dependent test assertions — invisible to any reviewer sharing the
  author's environment; exactly what paired audits in a DIFFERENT context
  are for (stage-0/7 metrics should count integrate-gate reds as escapes).
  Secondary operator error, also recorded: the completion chain piped
  engine commands through grep/tail (exit codes swallowed) and promoted
  the metrics-extract gate before verifying integration — gate was
  falsely green for ~20 min until re-promotion below. Chains must check
  integrated_this_run/exit codes; promotion only after verified merge +
  smoke test.
