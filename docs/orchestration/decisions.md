# Decisions

## Decision Log

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
