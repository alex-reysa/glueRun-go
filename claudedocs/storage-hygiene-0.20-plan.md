# Storage hygiene 0.20 — fail-closed admission and bounded automatic cleanup

Status: planned backlog contract; not part of the active 0.19 DAG
Reserved task/node: `TASK-0126` / `rel-17-storage-hygiene`
Activation boundary: open only after the operator-authority `TASK-0125` release decision

## Why this is a separate release slice

The 0.19 dogfood run proved two distinct storage failures:

- the engine's resource plan considered free bytes but did not stop every expanding action when
  the console-equivalent used percentage rounded to 99; and
- disposable proof roots copied a roughly 1.8 GiB Git object store three times before cleanup,
  driving the host to a rounded 100% used state.

The existing `singular gc` can cap run history, prune clean integrated worktrees, and rotate the
event journal. It cannot safely reclaim arbitrary temporary roots because those roots have no
owner manifest, and its run-retention proof does not yet cover every packet, gate, checkpoint,
decision, and operator-evidence reference. Extending that behavior inside TASK-0111..TASK-0125
would overlap most active runtime owners and weaken the 0.19 release proof. Storage hygiene is
therefore an independently gated 0.20 feature.

## Required behavior

### 1. Admission happens before expansion

A shared capacity preflight records total/free bytes, reserve compliance, console-equivalent
rounded used percentage, and `hardStop`. Reconcile runs it before integration or promotion, and
every direct expanding entry point uses the same helper before creating a worktree, disposable
gate checkout, audit checkout, provider scratch tree, or test process.

At hard stop, reconcile may run exactly one bounded pressure cleanup, remeasure, and then:

- continue only if the resume threshold is satisfied; or
- perform no integration, promotion, planning, dispatch, worktree creation, provider launch,
  gate, or test command and emit `origin.disk_hard_stop`.

Read-only status plus non-expanding recovery/import inspection remain available.

### 2. Engine-owned scratch is registered before bytes expand

Every engine-created temporary root lives below
`.singular-state/tmp/<kind>/<uuid>/` and contains an atomically written `owner.json` before the
expanding child starts. The record binds:

- repository identity and canonical relative path;
- kind, task ID, run ID, and retention class;
- owner PID, PID start time, and process group;
- creation/touch timestamps and lifecycle state; and
- the command/evidence identity that can prove the root is no longer referenced.

No automatic cleaner may infer ownership from a basename, glob, age alone, `$TMPDIR`, or a
process name.

### 3. Automatic deletion has a closed allowlist

Pressure cleanup may remove only:

1. manifested `scratch` roots whose owner identity is provably dead, minimum age has elapsed,
   and no live lease, job, run-status, packet, gate, checkpoint, or operator record references
   the root; and
2. registered worktrees that are exact descendants of `SINGULAR_WORKTREES_DIR`, clean, merged
   into the target, integrated, process-dead, and past their retention window.

TASK-0114's STOP-held `drive --reset-only` remains separate and is the only cleanup path allowed
to remove a non-integrated terminal task's exact worktree and worker branch.

Automatic cleanup must never delete branches, run/evidence directories, packets, audits, gates,
decisions, checkpoints, readonly journals, operator records, shared caches/object stores, videos,
external caches, `$TMPDIR`, `$HOME`, unmanifested paths, or any symlink escape.

### 4. Cleanup is bounded and auditable

The real command atomically writes
`.singular-state/storage-cleanups/<id>/plan.json` before deletion and `result.json` afterward.
It emits `storage.cleanup_planned` and `storage.cleanup_completed`; interrupted cleanup is
idempotently reconcilable from the plan. `--dry-run` executes the identical selector but creates
or mutates nothing.

Each pass is bounded by path count, total bytes, and wall time. It stops when the resume threshold
is met; it does not chase a target percentage by broadening scope.

## Initial knobs

| Knob | Initial default | Contract |
|---|---:|---|
| `SINGULAR_DISK_HARD_STOP_ROUNDED_PERCENT` | `99` | Default-on admission stop. |
| `SINGULAR_DISK_RESUME_ROUNDED_PERCENT` | `98` | Hysteresis before expansion resumes. |
| `SINGULAR_AUTO_STORAGE_CLEANUP` | `0` | Destructive sweeper is opt-in for 0.20. |
| `SINGULAR_STORAGE_CLEANUP_SCRATCH_MIN_AGE_HOURS` | `24` | Minimum dead-scratch age. |
| `SINGULAR_STORAGE_CLEANUP_WORKTREE_MIN_AGE_HOURS` | `1` | Minimum integrated-worktree age. |
| `SINGULAR_STORAGE_CLEANUP_MAX_PATHS` | `64` | Per-pass path ceiling. |
| `SINGULAR_STORAGE_CLEANUP_MAX_BYTES` | `8589934592` | Per-pass byte ceiling (8 GiB). |
| `SINGULAR_STORAGE_CLEANUP_MAX_SECONDS` | `30` | Per-pass wall-clock ceiling. |

The hard stop ships enabled. Automatic deletion ships disabled until its first consumer soak has
zero false selections.

## Proposed implementation scope

New files:

- `engine/storage-cleanup.py`
- `schemas/storage-root.v0.schema.json`
- `schemas/storage-cleanup.v0.schema.json`
- `tests/test-storage-cleanup.sh`
- `tests/test-storage-preflight.sh`

Existing runtime owners:

- `engine/resource-plan.sh`, `engine/ops.sh`, `engine/reconcile.sh`, `engine/lib.sh`
- `engine/l1-drive.sh`, `engine/integrate.sh`, `engine/promote-gate.sh`
- `engine/gate-check.sh`, `engine/audit-verify.sh`, `engine/accept-existing-packet.sh`
- `engine/git-preflight.sh`, `engine/doctor.py`, `tests/run.sh`

Regression owners:

- `tests/test-gc.sh`, `tests/test-resource-bootstrap.sh`, `tests/test-reconcile-low-disk.sh`
- `tests/test-l1-parallel.sh`, `tests/test-terminal-handoff.sh`
- `tests/test-audit-verification.sh`, `tests/test-accept-existing-packet.sh`
- `tests/test-doctor-json.sh`, `tests/test-config-conflict.sh`, `tests/test-engine-clean.sh`

## Focused gate

```sh
bash tests/test-storage-preflight.sh &&
bash tests/test-storage-cleanup.sh &&
bash tests/test-gc.sh &&
bash tests/test-reconcile-low-disk.sh &&
bash tests/test-l1-parallel.sh &&
bash tests/test-terminal-handoff.sh &&
bash tests/test-audit-verification.sh &&
bash tests/test-accept-existing-packet.sh &&
bash tests/test-doctor-json.sh &&
bash tests/test-engine-clean.sh
```

## Acceptance criteria

- Exact threshold-boundary tests prove hard stop at rounded 99 and hysteretic resume at 98.
- No integration, promotion, planning, dispatch, worktree, gate, audit, provider, or test process
  starts while the post-cleanup preflight remains stopped.
- PID reuse, EPERM/unknown liveness, a live process group, a young root, an invalid manifest, a
  symlink escape, or any reference ambiguity fails closed.
- Dry-run and real cleanup use the byte-identical plan selector; dry-run is pure.
- The plan is durable before the first deletion; crash recovery is idempotent.
- Path/byte/time ceilings and stop-on-resume behavior are mutation-sensitive.
- Decoy tests prove user temp roots, caches, videos, packets, audits, gates, checkpoints,
  branches, shared object stores, operator records, and unrelated worktrees remain unchanged.
- A soak at configured concurrency three leaves zero unregistered engine scratch roots and zero
  false cleanup selections.

## Promotion into an active task

After the 0.19 operator release decision, copy this contract into `TASK-0126`, register
`rel-17-storage-hygiene` in the next-version DAG, assign its full exact-file scope, and run a
fresh independent contract audit before dispatch. Do not silently append it to the current 0.19
release dependency chain.
