# Context-routing audit — verdicts, decisions, and what shipped

**Audit reviewed:** `claudedocs/context-routing-audit-and-proposals.md` (commit `7ea1ffd2`)
**Implemented at:** VERSION `0.20.0`, branch `agent/integration`
**Method:** every claim re-derived from source and, where it made a behavioral
assertion, reproduced at runtime before any code changed.

---

## 1. Verdicts

| # | Verdict | Note |
|---|---|---|
| F1 | **Confirmed — understated** | The audit hedged that the remaining gates "may well block it in practice". They do not. |
| F2 | **Confirmed** | Planner has no window or churn gate in any configuration. |
| F3 | **Substance confirmed, premise overstated** | Gate is provider-blind; the "engine routes roles to providers" premise is not shipped behavior. |
| F4 | **Confirmed — incomplete** | There are two inert skeptic-resume deciders, not one. |
| F5 | **Confirmed — stronger than written** | A new install ships `env: {}`; this repo's own config runs fully governed. |

### F1 — the independence pin was inactive by default

Reproduced against a reviewer session-meta that satisfies every gate of the legacy
decider:

```
SINGULAR_CTX_ROUTING=unset -> resume SESS-REVIEWER-123
SINGULAR_CTX_ROUTING=0     -> resume SESS-REVIEWER-123
SINGULAR_CTX_ROUTING=1     -> fresh tainted
```

Three facts make this the designed path rather than an incidental leak:

- `SINGULAR_SESSION_AFFINITY` defaults to `1` (`engine/lib.sh:6774`) — the legacy
  resume path is ON by default while the pin over it was OFF by default.
- `run_id` is fixed once per driver invocation (`engine/l1-drive.sh:113`), so the
  run-mismatch gate passes on every retry attempt.
- `engine/l1-drive.sh:1666` finalizes the reviewer meta with the stated intent
  "so a later audit try (this run) can resume it".

The auditor that rejected attempt 1 resumed its own session to grade attempt 2.

### F2 — planner resume bypasses the composed router

`engine/generate-tasks.sh:333` called the planner decider directly; the ladder has
no context-size and no churn gate. Confirmed as written.

### F3 — one global window constant

**Confirmed:** the gate takes `<role>` and discards it (`: "$role"`,
`engine/ctx-route-window.sh:44`); no provider lookup exists anywhere near it.

**Overstated, twice:**

1. "the engine deliberately routes different roles to different providers" —
   the base engine does not. `singular_select_l2_runner` (`engine/lib.sh:1422`)
   is a stub returning the default runner. The grok/claude split comes from the
   operator's gitignored `.singular-state/config.local.sh` plus a
   `singular-ext/grok-implementer` module. `providers.json` carries no role map.
2. "the error is not bounded in the safe direction" implies a systematic
   under-estimate. The measured file is the *cumulative* run log (appended with
   `>>`, `engine/l1-drive.sh:813`) carrying all runner stdout across attempts —
   plausibly a superset of session context. The error is unbounded in both
   directions. Real sample: a 654 KB auditor log estimates 163 k tokens and
   already trips the 140 k threshold.

### F4 — asymmetric skeptic independence

Confirmed, and the audit found one of two. `singular_ctx_critic_recheck_resume_decide`
(`engine/ctx-critic-recheck-resume.sh:137`) is the post-acceptance recheck over an
**accepted diff** — more independence-sensitive than in-loop re-critique, because
it is literally re-auditing accepted work. Neither decider is called by any engine
path; only tests reference them.

### F5 — governance ships default-OFF

Confirmed from source, and worse in what ships: `templates/singular.config.json`
carries `"env": {}`, so a new install gets zero governance, while this repo's own
`singular.config.json` sets all four knobs to `1`. Minor citation error: the audit
cited `ctx-critique-import-gate.sh:33` for the `SINGULAR_PLAN_CRITIQUE` default;
that line is a doc comment — the read is at `ctx-critique-import.sh:74`.

### Findings the audit missed

- **N1 — the pin's `paired-audit` arm is unreachable.** No call site passes
  `paired-audit` as a routing step, and `engine/ctx-paired-audit.sh:107` invokes
  its runner with no `--session-meta` and no `--resume-session`. Paired audit is
  structurally fresh; the entire live guarantee rested on `final-audit` — the arm
  that was disabled.
- **N2 — `singular_ctx_route_strategy_classify` is never called.** The spine
  derives strategy from `${baseline%% *}`, so `continue` never occurs at runtime.
  Fails safe, but §6 reads as though the classifier is live.
- **N3 — README's raw-default column was wrong.** `SINGULAR_PLAN_REVISE_MAX` is
  documented as default `0`; the code default is `1` (`ctx-plan-revise.sh:43`).
  Fortunate: it means enabling `PLAN_CRITIQUE` cannot strand a `revise` verdict.
- **N4 — `singular.config.json`'s `env{}` overrides the process environment**
  (`engine/lib.sh:118-131`). In a repo that pins a knob there, `VAR=0 singular …`
  does not override it. Relevant to documenting any escape hatch.

---

## 2. Decisions

| Proposal | Decision | Reason |
|---|---|---|
| P1 flip `SINGULAR_CTX_ROUTING` | **Take** | — |
| P2 pin unconditional | **Take** — centerpiece | A safety property behind a flag is not a safety property. |
| P3 regression test | **Take** | Extended to 4 steps × 3 flag states, plus mutation checks. |
| P4 route planner through the router | **Reject** | Would impose the diff gate; see P6. |
| P5 window gate on planner ladder | **Take** — larger than "S" | Required a persisted cross-run transcript. |
| P6 diff gate for planner | **Reject gate, take "document it"** | Churn is the planner's job, not its staleness signal. |
| P7 per-provider window | **Take, modified** | Seam wired; values seeded conservatively, not invented. |
| P8 overhead allowance | **Take, modified** | Hard-wired, not a new knob. |
| P9 provider usage metadata | **Reject (defer)** | Unverifiable in this cycle; no adapter surfaces it. |
| P10 decide F4 | **Take, modified** | Pin *both* skeptic paths, not just re-critique. |
| P11 promote defaults | **Take** | All four, matching the README's own recommendation. |
| P12 self-diagnosing deps | **Take** | — |
| P13 doctor posture | **Take** | — |

### Why P4 and P6's diff gate were rejected

Routing the planner through `singular_ctx_route` would impose the diff-volume
gate. For a task role, churn under a live session means the ground moved beneath
work in progress. For a planner, churn *is* the job: it plans against a tree that
advances while it works, and gate 5 keys on node lineage rather than run id
precisely so one session can span runs. A 400-line churn refusal would neuter the
feature. The correct churn guard is the ancestry check the planner already has,
which proves the tree was extended and not rewritten — volume of extension is not
staleness. Forcing one router over two different risk profiles buys uniformity at
the cost of correctness. Recorded as a decision, per P6's own alternative.

### Why P7 ships seeded rather than populated

Real context windows are vendor facts not verifiable from inside this repo, and
guessing **high** is the unsafe direction — it permits a resume that is genuinely
over budget, while guessing low only costs a fresh run. Three shipped providers
(`opencode`, `openrouter`, `cursor`) proxy an arbitrary operator-selected model,
so for those the window is not a property of the provider at all. The seam,
resolution, and conformance pin ship now; the values are a conservative engine
budget that a deployment raises deliberately once it has verified its own window.

### Where P5 exceeded its estimate

The audit rated P5 "Effort: S". Implementing it revealed the planner has no
measurable transcript: its session outlives the run, so the per-run planner log
does not exist at decide time and measuring it fails the gate closed on every
fresh run — disabling planner resume entirely. The fix required a canonical
per-node transcript accumulating across runs beside the session meta, truncated
whenever the decision is fresh. This was caught by an existing test, not by
reading.

---

## 3. What shipped

- **The independence pin is structural.** Evaluated above the routing flag in
  `engine/ctx-route.sh`, so it binds with `SINGULAR_CTX_ROUTING` unset, `0`, or
  `1`. The set grew from two steps to four: `final-audit`, `paired-audit`,
  `re-critique`, `critic-recheck`.
- **Four governance knobs default to `1`,** centralized in `engine/lib.sh`.
  `SINGULAR_REHYDRATE` and `SINGULAR_CTX_GRAPH` stay opt-in pending the
  per-section truncation fix.
- **Planner gate 12 (window-pressure)** plus a canonical per-node planner
  transcript with a defined lifecycle.
- **`contextWindowTokens` per provider**, resolved runner → provider →
  `providers.json`, plus a hard-wired overhead allowance in the estimate.
- **`singular doctor` reports the governance posture** and warns on unmet
  feature dependencies.
- **`tests/test-ctx-governance-defaults.sh`**, mutation-checked against five
  independent regressions.

---

## 4. What the film can now claim

- **"Audits always start fresh" — true, unconditionally.** Four steps are pinned
  and no knob reaches them.
- **"Resume/fresh/pinned routing is what a default install does" — true.**

One precision worth keeping the narration honest about: the pin removes *session*
carry-over, not knowledge. A fresh audit still receives prior findings through the
re-audit delta prompt (`engine/l1-drive.sh:1223`). The guarantee is that no
auditor grades work from inside a session that already formed a verdict on it —
not that the auditor is ignorant of previous attempts. If the narration implies
the latter, it overclaims.
