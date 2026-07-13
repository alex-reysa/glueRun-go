# Stage 2 — First-class plan critique (M2)

> **Gate-passed** — this stage's nodes are complete; evidence in `../orchestration/gates/`.

Purpose: plans get reviewed before they become work. This wires the role the
orphaned `templates/prompts/reviewer.md` was evidently meant for.

## Node `plan-critique-contract` (area: plancritic, layer: contract, single-slice)

Design task — operator reviews the diff before integration.

- `schemas/plan-critique.v0.schema.json`
  (`gluerun.orchestration.plan-critique.v0`): node, runId, batch task ids,
  verdict (`approve | revise | park`), findings[] — each with a stable finding
  id (reuse the normalized-hash identity of `gluerun_finding_id`), severity
  (`blocking | should-fix | note`), the claim, the evidence pointer, and an
  optional suggested change. Plus assumptionsChallenged[], rationale.
  Additional top-level fields forbidden.
- `templates/prompts/plan-critic.md`: adapted from `reviewer.md`. The critic is
  a SKEPTIC: read-only repo access; challenges slicing, dependency claims,
  owned-file scoping, acceptance-criteria testability, duplicate/overlap risk
  against existing tasks, and hidden coupling between batch tasks. It must
  hunt for the batch's *unstated assumptions*. Final message: one JSON object
  per the schema, nothing else.
- Verdict semantics doc section in this file's task: `approve` → import;
  `revise` → Stage 3 loop (until then treated as `park`); `park` → candidates
  parked with findings recorded, node lease released as failed-planning.

Exit gate: schema validates fixtures (valid + each invalid class rejected);
prompt file exists and is referenced by nothing yet; suite green.

## Node `plan-critic-driver` (area: plancritic, layer: engine_runtime)

- `engine/ctx-plan-critic.sh`: runs the critic over a STAGED candidate set
  (node-local stage dir + rendered candidate task files + existing-task summary
  + the node's stage file from `docs/context-build-plan/`), read-only, fresh
  session, on the default runner (`GLUERUN_RUNNER_BIN` — keep the
  cross-provider independence property: module-routed planners still get a
  default-runner critic).
- Robust JSON extraction via `gluerun_extract_json`; unparseable critic output
  after `GLUERUN_AUDIT_INFRA_MAX`-style bounded retries → treat as `approve`
  with a `ctx.plan_critique_infra` event (fail OPEN here by design: the critic
  is an added safety layer; its infrastructure failing must not deadlock
  planning — the un-bypassable safety layer remains the implementation
  auditor).
- Persist the critique JSON next to the staged candidates and record
  `plan.critiqued` events with verdict + finding count.
- Critic session meta persisted per node under
  `.gluerun-state/sessions/plan-critic/<node>.json` (used by Stage 3
  carry-over; role `plan-critic`).
- Test `tests/test-ctx-plan-critic.sh` with stub runners for all verdicts +
  the infra fail-open path.

Exit gate: suite green; stub-driven staged batch produces persisted critique +
events for each verdict class.

## Node `critique-import-gate` (area: plancritic, layer: engine_runtime)

Owns the import-path hook (`reconcile.sh` / the L0 import step).

- Behind `GLUERUN_PLAN_CRITIQUE=0`: when ON, L0 imports a staged batch only
  with an `approve` critique record; `revise`/`park` → candidates are NOT
  imported; findings and disposition recorded (`origin.l1_import_rejected`
  reason `plan-critique`), node lease handled as planning-failed so the
  frontier can be re-planned.
- When OFF: import path byte-identical to today (critique may still run and
  record, verdict not enforced — observe-only mode is the intended first
  rollout).
- Test `tests/test-ctx-critique-import.sh`: OFF observe-only; ON enforces all
  three verdicts; missing critique record with knob ON fails closed (no
  import, reason recorded).

Exit gate: suite green; enforcement matrix covered by tests.
