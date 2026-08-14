# Reliability Program Contract

This document is the single authoritative statement of scope and safety invariants for the
reliability program represented by the `rel-*` DAG nodes. Later implementation tasks and their
auditors must cite this contract and must not re-derive or widen the program from the source
plan.

## Safety invariants

These eight invariants are release blockers.

1. **checkpoint-never-acceptance:** A checkpoint must preserve bytes only; it must never mean
   accepted, audited, integrated, or promotable. A checkpoint must never satisfy packet, audit,
   gate-result, integration, or promotion checks.
2. **advocate/skeptic separation:** A resumed advocate session must never serve as an auditor or
   any other independence-required reviewer. The existing advocate/skeptic separation invariant
   must remain green.
3. **exact job identity:** Reattachment and result reuse must require exact job identity: task,
   canonical argv, effective environment allowlist, workspace, head/input identity, and engine
   contract version.
4. **evidence binding unchanged:** Gate evidence must remain bound to the exact tested tree,
   command, inputs, and log hashes under the existing `evidenceBindingSha256` regime. New job
   identity must complement this binding and must never replace or weaken it.
5. **checkpoint scope fail-closed:** Only task-owned paths may enter a checkpoint. Forbidden,
   generated, secret-bearing, and unrelated dirty paths must fail closed, reusing
   `scope-check.sh` and `secret-scan.sh`.
6. **evidence-remedies-never-implement:** Evidence remedies must never invoke the implementer and
   must never consume product retry budget.
7. **no auto-redispatch of known ambiguous external effects:** No engine path may ever
   auto-redispatch work that it knows performed an ambiguous external effect. The full effect
   contract is deferred, and this sprint must never weaken this guard.
8. **recovery-never-kills-live-work:** Recovery must never restore or kill work while the
   supervised process tree is provably live. The existing five-way liveness probe must remain
   authoritative, and the hard cap must gain a liveness escape hatch.

## Audited baseline failure modes

The program fixes the following audited baseline failures. Each item identifies the code anchor
against which the implementing task and its auditor must verify the change.

- **Worker log truncation per infrastructure try.** In `engine/l1-drive.sh`, `run_worker_phase`
  uses the `>"$run_dir/worker-codex.log"` redirect on every try, destroying the prior try's log.
- **Stale worker last-message across tries.** In the same `run_worker_phase` function, the
  `--output-last-message` path for `last-message.json` is never cleared between tries, unlike the
  auditor record's explicit `rm -f`; stale try output can therefore mask a later empty output.
- **Evidence revalidation shares product retry behavior.** In `engine/l1-drive.sh`, the terminal
  `case "$action"` block sends `revalidate-evidence` through the same branch as `retry`, rerunning
  the implementer and consuming the product lease counter.
- **Overloaded audit-infra classification.** `audit-infra` has 13 emitter sites spanning distinct
  failure domains. In particular, the source-integrity emitter site is a correctness event, not
  an infrastructure event, and must not be routed as infrastructure.
- **Frozen deadlines.** Every runner and `gate-check.sh` computes
  `deadline=$((SECONDS + budget))` only once at spawn, so a mid-flight budget raise cannot affect
  the active deadline.
- **EXIT-trap-only terminal handoff.** Terminal handoff exists only in the in-process
  `l1_on_exit` EXIT trap. A SIGKILL bypasses that trap and leaves a stale `active` run-status
  record.
- **Planning-lease reclaim without liveness.** The L1 planning-lease reclaim path
  `singular_l1_reclaim_stale` performs wall-clock reclaim without first probing process-tree
  liveness.
- **Unpinned reviewer transcript mapping defect.** `engine/ctx-route-drive.sh` reads
  `audit-codex.log`, while the driver writes `auditor-codex.log`; with context routing enabled,
  an ordinary unpinned reviewer therefore fails closed instead of resuming. Final-audit and
  paired-audit are deliberately fresh-pinned and were never made fresh by this mismatch;
  master-off behavior remains the legacy path.

## Explicit deferrals

The following work is outside this reliability program. Workers and auditors must not widen a
`rel-*` task to implement any of it:

- checkpoint grades beyond snapshot: `validated` and `candidate`, restore lineage policy, and
  checkpoint garbage collection.
- A full at-most-once effect ledger, wrapper, or receipt system; effect receipts remain in the
  consumer product layer.
- a production run-control writer, signing-key provisioning, or cross-process/run persistent
  high-water ledger. `rel-07-run-control` permits only externally pre-signed, exact-run records
  and per-bounded-invocation monotonic deadline/cancel re-read behavior.
- cross-run resume after an `escalate-infra` unpark cycle.
- budget heuristics derived from historical timing, including minimum multiples of p95; these
  remain console or consumer policy.
