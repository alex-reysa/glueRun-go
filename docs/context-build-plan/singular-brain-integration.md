# singular-brain × singular — integration decision record

Working handoff, written 2026-07-09, to persist the conclusions of the
singular-brain audit + integration assessment so work resumes with zero prior
context. Companion to `00-overview.md`; **not a stage file** — Stage 0/5/6
tasks reference it where noted below.

Repos on this machine:

- engine (this repo): `~/Desktop/999. PROJECTS/pmgo-orchestration-engine`
- singular-brain: `~/Desktop/999. PROJECTS/singular-brain`
  (remote: `github.com/alex-reysa/singular-brain`, private)
- consumer of record: `~/Desktop/999. PROJECTS/PMGO-launch`

## Where things stand (2026-07-09)

- singular-brain was audited (architecture + implementation; brief at its
  `docs/AUDIT-BRIEF.md`). Verdict: approach sound; seven confirmed defects.
  All seven fixed and verified in **0.2.0** (commit `e05f259`, 98/98 tests,
  abstraction gate clean, real-corpus `check` green). Freshness is now
  honestly framed as a *review ratchet*; the sidecar is documented as the one
  committed **ledger** (not a rebuildable projection), guarded against silent
  wipe (`SidecarMissingError`; `bless --all` is the explicit override).
- **PMGO-launch still vendors 0.1.0** — resync to 0.2.0 is the first task
  before building anything on top (see checklist).
- Integration assessment concluded: the two tools are complementary layers of
  one context architecture. This doc records the boundaries, join points, and
  the distribution decision.

## Division of labor

|  | context build plan (S0–S7) | singular-brain |
| --- | --- | --- |
| Routes over | run-time records: sessions, critiques, packets, event log | durable authored knowledge: docs, handoffs, skills |
| Projection of | event log + decision records (Stage 6 graph) | artifact frontmatter |
| Answers | what happened in this lineage; what carries forward | what durable knowledge exists; when to load it |

`00-overview.md` finding 3 — "the durable-truth layer partially exists but
nothing routes on it" — is exactly the gap singular-brain fills for the
*authored* half. The Stage 6 graph routes the *event-sourced* half. They meet
at rehydration (Stage 5).

## Boundaries (binding on the integration)

1. **Never index model-authored artifacts.** Capsules, critique records,
   context packets are model-written; singular-brain's tier-2 excerpts are
   auto-derived from bodies, so indexing them would propagate model-authored
   text into a manifest loaded by every role — an injection-persistence
   channel (violates plan principle 5 and the graph's `authoritative`/`claim`
   line). singular-brain indexes human-authored/curated durable docs only;
   model-authored records are graph territory, with taint. The manifest may
   be injected into all roles — including fresh auditors — *only while this
   boundary holds*, because a committed human-authored index is repo content
   like a README, not session context.
2. **Freshness scopes exclude engine-generated churn.** Tier-1 freshness on
   files the engine rewrites would bury operators in `bless`. The
   orchestration control tree (`docs/orchestration/`, `.singular-state/`) is
   `noEntries`/excluded in any scope config (PMGO-launch already does this).
3. **Engine cleanliness both ways.** No singular tokens in singular-brain's
   `engine/`; no consumer tokens in either engine. All integration specifics
   live in the consumer dock (prompts, Makefile, `singular-brain.config.json`)
   or behind generic, additive, default-OFF engine hooks.
4. **Config is consumer-owned.** Bundling ships the singular-brain *engine*
   only; every repo owns its `singular-brain.config.json`. The engine never
   ships or infers a config.
5. **Docs-vs-code line.** Manifests index understanding artifacts, never raw
   code. "Which module implements X" is answered by an architecture doc
   entry, not a code entry.
6. **Generated projections are regenerated, never merged.** Parallel L2
   workers each regenerating a manifest guarantees merge conflicts at
   integrate. Resolution is always: post-merge `gen` at the L0 integrate
   step; never hand-merge a generated file.
7. **Quarantine wins.** Once `artifact-secret-scan` (Stage 4) exists, any
   `.quarantined` artifact is excluded from manifest generation the same way
   it is excluded from prompt assembly and rehydration.

## Integration points (ranked; 1–2 need no engine change)

1. **Dock-level prompt injection — do first.** The docked
   `l1-planner.md`/`planner-contract.md` already list docs the planner must
   read; add the consumer's `docs/REGISTRY.md` + `docs/KNOWLEDGE.md`.
   Planners (and worker prompts, via the same dock) get prior-awareness of
   the durable corpus without searching for it.
2. **Gate wiring.** `singular-brain check` at node-gate promotion (not
   per-attempt, to respect the ~3-minute gate budget), plus `gen` in the L0
   integrate step per boundary 6.
3. **Stage 5 rehydrate ingestion (engine change, additive).**
   `ctx-rehydrate.sh` assembles packets from durable artifacts;
   `KNOWLEDGE.json` is the machine-readable bridge — entries carry
   `load-when` triggers and freshness state. Hook shape: optional
   `contextManifest` path in `singular.config.json` (additive schema field) +
   `SINGULAR_CTX_MANIFEST=0` knob. Rules: entries flagged
   `description_unverified` are never injected as current (inject with the
   flag, or skip); quarantined artifacts excluded; packet manifest records
   which entries were injected, like any other rehydration source.
4. **S0 A/B arm — the measurement singular-brain lacks.** Its core claim
   (less re-derivation, fewer blind greps) has never been measured. Define a
   manifest arm in the S0 harness: arm A gets the manifest injected into
   planner/worker prompts, arm B does not; compare tokens per accepted task,
   attempts-to-accept, escape rate. This decides how far integration goes —
   same evidence-gated discipline as the Stage 6 entry condition.

## Distribution: pre-bundle in singular (recommended)

**Decision: bundle the singular-brain engine inside the singular install;
do not require a separate install or per-repo vendoring for orchestration
use.** A separate install is a second version pin and a second setup step per
machine (the hassle is real); per-repo vendoring already drifted once
(PMGO-launch sat on 0.1.0 while 0.2.0 shipped).

Mechanics:

- Vendor singular-brain's `engine/` into this repo (e.g.
  `vendor/singular-brain/engine/` + its `VERSION`), so it ships inside
  `~/.singular/` via `install.sh` and versions through the existing
  `.singular-version` pin — improvements propagate by bumping the pin, same as
  everything else.
- Pin integrity like everything else: a `tests/test-vendor-sync.sh` that
  byte-compares the vendored copy against a recorded upstream version/hash,
  so drift is a red test, not a surprise.
- Thin CLI passthrough — `singular manifest <gen|check|lint|bless>` — invoking
  the bundled `cli.mjs` with the consumer's config. No reconcile-cycle step
  calls it unless the consumer config declares a manifest (default-OFF, plan
  principle 1).
- **The one real caveat: runtime.** singular is bash + Python;
  singular-brain needs Node (any modern Node, zero npm deps). Treat Node as
  an *optional* dependency: `singular doctor` checks for `node` only when the
  consumer config declares a manifest; without Node the manifest features
  report unavailable and nothing else degrades.
- Consumer-CI nuance: a repo that wants `singular-brain check` in its own CI
  without a singular install can still vendor per-repo (singular-brain's
  native model). If both bundle and vendored copy exist, `doctor` should
  compare their VERSIONs and warn on mismatch.

Rejected alternatives: separate machine install (second pin, second
installer, no benefit over bundling); per-repo vendoring as the *only*
channel (proven drift, and the engine's integrate-step `gen` hook shouldn't
depend on every consumer having vendored correctly).

## Checklist to resume

1. Resync PMGO-launch: copy singular-brain 0.2.0 `engine/` over
   `scripts/singular-brain/engine/`, run `check`, commit.
2. Dock edits (PMGO-launch): add REGISTRY.md/KNOWLEDGE.md to the docked
   planner prompt/contract; wire `check` into node-gate promotion.
3. Decide bundle layout (`vendor/singular-brain/`) and the passthrough
   command name; write the vendor-sync test; add the `doctor` Node check.
4. Add the integrate-step `gen` hook (behind the manifest-declared condition).
5. Write the S0 manifest A/B arm definition into `stage-0-baseline.md` (or a
   task under `ab-harness`).
6. Stage 5, when reached: `contextManifest` config field + `SINGULAR_CTX_MANIFEST`
   knob + freshness/quarantine injection rules (this doc, Integration point 3).
