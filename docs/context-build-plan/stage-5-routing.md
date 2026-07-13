# Stage 5 — Explicit session routing (M5)

Purpose: one routing module, five named strategies, every decision
reason-coded. Ordered fail-closed gates — NOT a numeric score. Judgment calls go
to the model decider with recorded rationale; arithmetic never trades away an
independence constraint.

## Node `routing-module` (area: routing, layer: engine_runtime)

Chains behind `paired-audit` for the `l1-drive.sh` hook file.

- `engine/ctx-route.sh`: `gluerun_ctx_route <role> <ctx…>` returning exactly one
  line: `continue|resume|fork|fresh|rehydrate <arg-or-reason>`.
  - `continue` — same session, same lineage, next phase (planner revision is
    the current instance; implementer retry-resume maps here too).
  - `resume` — a persisted specialist re-engaged (critic recheck, reviewer
    re-audit).
  - `fork` — reserved: shared foundation, divergent roles (schema slot +
    events now; first consumer is future multi-critic panels; may be a no-op
    strategy this stage).
  - `fresh` — new session, no injected context (independence-required paths
    are PINNED here: final audit, paired audit — no knob may reroute them).
  - `rehydrate` — fresh session + injected durable context (next node).
- Implementation: wrap (do not rewrite) `gluerun_session_resume_decide` and
  `gluerun_planner_resume_decide`; add two gates available to all roles:
  **window pressure** (estimated session tokens from provider session files >
  `GLUERUN_SESSION_WINDOW_MAX_PCT` → refuse resume) and **diff volume**
  (churn in the role's relevant files since `headShaAtCreate` above a
  threshold → refuse; wall-clock age alone under-measures staleness).
- Generalize the session-lease discipline (Stage 1) to every persisted
  session; taint framing: any resumed/rehydrated session is `tainted=1` in its
  strategy event — tainted sessions can never satisfy an
  independence-required step (structural, tested).
- Behind `GLUERUN_CTX_ROUTING=0`; OFF → legacy decide paths byte-identical.
- `ctx-metrics.sh` learns strategy/outcome splits per role.
- Tests `tests/test-ctx-route.sh`: strategy table per role fixture; both new
  gates; taint exclusion; OFF-parity.

Exit gate: suite green; every emitted strategy+reason enumerated by tests;
independence-pinned paths provably unreachable by resume/rehydrate.

## Node `rehydrate-path` (area: routing, layer: engine_runtime)

- `engine/ctx-rehydrate.sh`: assemble a rehydration packet — deterministic,
  capped (`GLUERUN_CONTEXT_SECTION_MAX_CHARS` per section) — from durable
  artifacts only: task context packet, implementer/reviewer capsules,
  findings + assumption ledgers, critique records, relevant decision records.
  Quarantined artifacts excluded. Injected as a prompt section on an otherwise
  fresh run.
- Routing integration: when `resume` is refused for a lineage-continuation
  step and `GLUERUN_REHYDRATE=1`, route `rehydrate` instead of bare `fresh`;
  record packet manifest (which artifacts, which hashes) in the strategy
  event.
- Rehydrated sessions are tainted (see above) — never eligible for
  independence-required steps.
- Tests `tests/test-ctx-rehydrate.sh`: packet assembly determinism given fixed
  artifacts; caps enforced; quarantine exclusion; OFF-parity.
- OPTIONAL ADDITIVE SLICE — authored-knowledge manifest ingestion (see
  `../context-build-plan/singular-brain-integration.md`, integration point 3):
  when `gluerun.config.json` declares an optional `contextManifest` path
  (additive field) AND `GLUERUN_CTX_MANIFEST=1` (default 0), the rehydration
  packet may additionally ingest entries from that machine-readable JSON
  manifest (contract: entries carry ids, `load-when` triggers, freshness
  state). Rules: entries flagged `description_unverified` are injected with
  the flag or skipped, never as current; quarantined artifacts excluded; the
  packet manifest records injected entry ids like any other source. The
  manifest is AUTHORED-KNOWLEDGE class — human-curated repo content, distinct
  from host-verified evidence AND from model-authored (tainted) records; it
  must never be recorded as `authoritative` evidence. Implement and test
  against FIXTURE manifests only — no dependency on the singular-brain
  runtime (the JSON contract is the interface; bundling is a separate
  post-plan track).
