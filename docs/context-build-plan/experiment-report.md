# Context-evolution experiment report (S7 / `experiment-run`)

Operator-authored 2026-07-13 from the self-hosting run's durable records.
Companion to `00-overview.md` and the operator hand-off at
`../orchestration/handoffs/experiment-run.operator-handoff.md`. This report
plus the per-knob decision record in `../orchestration/decisions.md` is the
evidence attached to `docs/orchestration/gates/experiment-run.gate-result.json`.

## 1. Method and validity

This is an **observational before/after comparison over one real backlog**
(this repo's own context-evolution build, 105 integrated tasks with full
lifecycle records in `.gluerun-state/events.ndjson` — the arms-analyzed
corpus; the finished plan totals 107, the last two release-phase tasks
landing after this analysis was cut), not a randomized
concurrent A/B. Arms are defined by knob-state era, matching the DAG's
`control = M0 knob-state` framing:

- **Arm A (control era)** — tasks first dispatched before
  `2026-07-11T14:46Z`, the commit that flipped `GLUERUN_PLAN_CRITIQUE=1` and
  `GLUERUN_PAIRED_AUDIT_PCT=25` (M0/M1 knob-state: continuity mostly OFF;
  planner sessions landed mid-era).
- **Arm B (treatment era)** — tasks first dispatched after that flip
  (critique + revision + context packets live; routing and rehydration landed
  progressively as the run built them).

**Confounds, stated plainly:** the treatment era also saw (a) scoped task
gates replacing full-suite gates for new-file tasks, (b) slice folding /
task-width increases (budget 1→2→3), (c) runner changes
(opus→codex→opus) driven by provider quotas, and (d) the suite growing from
~60 to ~115 tests (which lengthens full-suite tasks in arm B, biasing
*against* the treatment on wall-clock). Direction-of-effect on the primary
metrics is discussed inline. A controlled, concurrently-randomized A/B (plus
the singular-brain manifest arm) is the recorded follow-on in the consumer of
record — this repo has no curated authored-knowledge corpus and its backlog
is now exhausted.

## 2. Primary measurements

| Metric | Arm A (control era) | Arm B (treatment era) | Delta (B−A) |
| --- | --- | --- | --- |
| Integrated tasks | 30 | 75 | +45 |
| Audit escapes (defect passed audit, found later) | 1 (TASK-0003) | 0 | −1 |
| Escape rate per accepted task | 3.3% | 0% | −3.3 pp |
| Attempts-to-accept (mean) | 1.20 | 1.15 | −0.05 |
| Wall-clock per task, median (dispatch→accept) | 19.1 min | 9.6 min | −9.5 min (−50%) |
| Wall-clock per task, mean | 71.6 min¹ | 18.9 min | −52.7 min |

¹ Arm A's mean is dominated by two environmental incidents (a 25-hour mock-CLI
stdin hang and long recovery cycles), which is itself part of the honest
baseline: the guardrails that prevent such hangs (hermetic stdin, env scrub,
detached dispatch) were built during the run.

**Cost note:** per-task token counts were not instrumented in this run
(added to the backlog); wall-clock is the cost proxy. The provider-side
mitigation was measured separately during M1: planner runs read ~200k cached
tokens vs ~10k fresh, so the docs corpus was not re-paid per call even before
session resume landed.

**Bias measurement:** in arm B, 25% of acceptances were independently
paired-audited by a fresh session with no lineage (structurally guaranteed by
the taint rule — resumed/rehydrated sessions are unreachable for
independence-pinned steps, `tests/test-ctx-route-taint.sh`). **Zero
paired-audit disagreements were recorded.** One governance escalation
(TASK-0067, `needs-human`) was an authority question — a worker-disclosed
scope expansion the auditor refused to ratify — not a correctness defect; the
decider ruled `amend-scope` and the re-audit accepted the unchanged code.
Arm A had no paired audits (knob was off) — a stated limitation of the
before/after design.

## 3. Secondary measurements

**Session routing over the run (364 recorded strategy decisions):**

| Role | resume | fresh | Resume rate |
| --- | --- | --- | --- |
| planner | 99 | 32 | 76% |
| implementer | 1 | 126 | by design ~0% |
| reviewer/auditor | 0 | 106 | pinned 0% (independence) |

- Planner continuity was the run's workhorse: 76% of planner invocations
  resumed a persisted session, including sessions that decomposed entire
  multi-slice nodes across consecutive resumes. Zero session-affinity
  incidents after the fail-closed gates landed.
- **Fresh-fallback reason mix** (why an eligible resume was refused):
  `role-mismatch` 29, `prompt-template-changed` 3, `runner-changed` 1 (the
  codex switch — the affinity gate degraded every persisted session correctly
  in one cycle), `no-session-id` 1. Every refusal reason is enumerated and
  each occurrence was the correct call — no false refusals were found on
  review.
- Reviewer/implementer freshness is the designed independence spine, now
  structural (taint marking) rather than conventional.

**Rehydration:** the assembly→routing→injection→manifest pipeline is fully
built and fixture-proven (packets deterministic, capped, quarantine-aware;
injected ≡ recorded manifests asserted end-to-end), but `GLUERUN_REHYDRATE`
stayed OFF during this run's own execution, so no live hit-rate is claimable.
The flat-vs-subgraph rehydration A/B arm is wired (TASK-0104–0106) for the
consumer experiment.

**First-attempt acceptance streak:** the treatment era closed with 60+
consecutive first-attempt acceptances (TASK-0042 onward, zero worker-caused
rework), against a fine-decomposition discipline that kept tasks small. The
width-vs-yield trade-off is a plan-shape choice: this run sat at the
high-yield/high-latency end; the chained-slice bundling rule (added mid-run)
is the knob for moving along that curve.

## 4. Treatment-effect reading

The treatment era halved median per-task wall-clock while eliminating audit
escapes, at essentially unchanged attempts-to-accept. Because scoped gates
and task-width changes shared the era, the wall-clock delta cannot be
attributed to continuity features alone; the escape-rate and bias results
can be read more directly (critique + packets + paired audits were the era's
quality-side changes, and the era absorbed 2.5× the task volume with zero
escapes). The routing table is unconfounded evidence that session continuity
works mechanically at production rates (76% planner resume, zero incidents,
correct fail-closed refusals including a full runner swap).

## 5. Per-knob default decisions

Recorded, with rationale, in `docs/orchestration/decisions.md`
(2026-07-13 per-knob entry). Summary:

| Knob | Decision | Basis |
| --- | --- | --- |
| `GLUERUN_PLANNER_SESSION` | **default-ON** | 76% resume rate, zero affinity incidents, graceful quota/runner degradation |
| `GLUERUN_PLAN_CRITIQUE` | **default-ON** | treatment-era batch quality (60+ first-attempt streak); caught real plan gaps |
| `GLUERUN_CTX_PACKET` | **default-ON** | high-quality packets consumed by workers; no incidents; visible reasoning-residue value |
| `GLUERUN_PAIRED_AUDIT_PCT` | **keep 25** | zero disagreements = the independence spine is cheap insurance, not waste |
| `GLUERUN_CTX_ROUTING` | **default-ON** | 364 reason-coded decisions, enumerated refusal mix, structural taint rule |
| `GLUERUN_CTX_ARTIFACT_SCAN` | **default-ON** | quarantine + exclusion proven; negligible cost; security posture |
| `GLUERUN_REHYDRATE` | opt-in | mechanism proven on fixtures; no live-scale evidence yet |
| `GLUERUN_CTX_MANIFEST` | opt-in (default 0) | fixture-only by design; consumer corpus experiment pending |
| `GLUERUN_CTX_GRAPH` | opt-in | projector deterministic/loss-free per exit gate; not yet consumed by live routing long enough to earn ON |
| `GLUERUN_CTX_EXPERIMENT` / `GLUERUN_CTX_ARMSTATE` | opt-in | operator tooling, on-demand |

**Stage 6 graph investment verdict:** earn-in achieved for the projection
layer (schema, mappers, sync≡rebuild, query, CLI — all evidence-gated);
*further* graph investment (graph-driven routing beyond rehydration
selection) is frozen pending the consumer-run subgraph-vs-flat measurement.

## 6. Raw artifacts

- Event log: `.gluerun-state/events.ndjson` (3.7k events; the durable basis
  for every number above).
- Gate records + hashed evidence logs: `docs/orchestration/gates/`.
- Incident and decision trail: `docs/orchestration/decisions.md`.
- Toolchain used and its tests: `engine/ctx-experiment-*.sh`,
  `tests/test-ctx-experiment-*.sh` (TASK-0077→0103); arm-labeled pipeline
  ready for the controlled consumer experiment.
