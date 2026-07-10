# Decisions

## Decision Log

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
