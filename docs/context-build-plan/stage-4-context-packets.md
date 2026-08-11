# Stage 4 — Rich context packets (M4)

> **Gate-passed** — this stage's nodes are complete; evidence in `../orchestration/gates/`.

Purpose: the handoff artifact carries the planner's reasoning residue —
decisions, assumptions, rejected alternatives, inspected symbols — so a fresh
implementer (and later, rehydration) loses less. This is the enriched-artifact
alternative to owner-sessions, and the A/B arms compare exactly this.

## Node `context-packet-contract` (area: packets, layer: contract, single-slice)

Design task — operator reviews the diff before integration.

- Define the context-packet block: OPTIONAL, additive sections in the task
  markdown (`## Context packet` with `Decisions`, `Assumptions`,
  `Rejected alternatives`, `Inspected symbols`) parsed tolerantly — absent
  sections are valid forever (old tasks keep validating).
- Assumption entry grammar: `- [open|validated|violated] <claim> — <basis>`.
- Extend `templates/prompts/l1-planner.md` (and the docked
  `docs/orchestration/prompts/l1-planner.md`) to request the block, capped and
  concrete: decisions with why, alternatives with why-not, assumptions the
  implementer must not silently violate. Rule: never restate what the repo can
  answer (no symbol inventories — only symbols whose ROLE in the plan is
  non-obvious).
- Parser helpers in `engine/ctx-packet.sh` (`singular_ctx_packet_json <task>` →
  normalized JSON or `{}`).
- Test `tests/test-ctx-packet.sh`: parse fixtures (present, absent, malformed
  → fail closed to `{}` + warning event).

Exit gate: suite green; existing TEMPLATE-based tasks unaffected; fixtures
parse.

## Node `assumption-ledger` (area: packets, layer: engine_runtime)

- `engine/ctx-assumptions.sh`: per-run assumption ledger seeded from the task's
  context packet; carried across attempts like the findings ledger.
- Wire-in (behind `SINGULAR_CTX_PACKET=0`):
  - Implementer prompts (base + structured fix prompt) gain an assumptions
    section: violated assumptions are called out like open findings.
  - Auditor prompt gains: "verify these assumptions were not silently
    violated; flag violations as findings."
  - Implementer capsule records assumption statuses per attempt.
- Status transitions are HOST-derived where possible (e.g. a violated
  assumption = auditor finding referencing its id); model-asserted transitions
  are recorded as claims.
- Test `tests/test-ctx-assumptions.sh`: seeding, carry-across-attempts, prompt
  injection when ON, byte-identical prompts when OFF.

Exit gate: suite green; a stub retry run shows the ledger flowing into fix and
audit prompts under the knob.

## Node `artifact-secret-scan` (area: packets, layer: engine_runtime)

Durable context artifacts get the same secret hygiene as commits.

- Extend `secret-scan.sh` (this node owns that file) with an `--artifacts`
  mode scanning capsules, session-meta files, context packets, critique
  records, paired-audit records, and (later) graph files.
- Hook the scan where these artifacts are finalized; a hit quarantines the
  artifact (rename `.quarantined`, event `ctx.artifact_secret`), never blocks
  the task outcome, and the quarantined file is excluded from all later prompt
  assembly and rehydration.
- Test `tests/test-ctx-artifact-scan.sh` with seeded fake secrets.

Exit gate: suite green; seeded secret in a capsule is quarantined and never
reaches a rendered prompt.
