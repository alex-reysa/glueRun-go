# Operations — knobs, autonomy runbook, troubleshooting

Read this when tuning a run, supervising a long autonomous loop, or
debugging a stuck/misbehaving orchestration. Everything here reflects
engine 0.5.x behavior and lessons from production runs (including the
singular-frontend field audit that drove the 0.5.0 hardening).

## Core env knobs

Set durable values in `gluerun.config.json` `env{}`; use shell env for
one-off overrides. Operator secrets/overrides go in
`.gluerun-state/config.local.sh` (gitignored).

| Knob | Default | Effect |
| --- | --- | --- |
| `GLUERUN_MAX_CONCURRENT` | `5` | Max L2 workers running concurrently. |
| `GLUERUN_MAX_DISPATCH` | `5` | Max tasks dispatched per reconcile cycle. |
| `GLUERUN_ENABLE_L1_PARALLEL` | `0` | `1` runs one L1 planner per frontier node concurrently. Turn this ON for parallel planning. |
| `GLUERUN_DETACHED_DISPATCH` | `1` | Reconcile pre-leases and spawns workers in their own sessions, returning in seconds; a reaper attributes outcomes on later cycles. `0` = legacy synchronous wait. |
| `GLUERUN_AUTO_INTEGRATE` | `1` | Merge completed worker branches during actuate cycles. |
| `GLUERUN_PUSH` | `0` / `1` | Push integrated branches to the remote. Defaults to `0` for directly-invoked engine commands (`gluerun reconcile` etc.) and `1` under `gluerun auto` and launchd. |
| `GLUERUN_MAX_HOURS` | `12` | Wall-clock budget for `gluerun auto`. |
| `GLUERUN_MAX_CONSEC_FAILS` | `5` | Circuit breaker: consecutive no-progress cycles before `gluerun auto` halts. |
| `GLUERUN_MAX_RETRIES` | `3` | Per-task worker retries before the decider escalates. |
| `GLUERUN_STALE_MINUTES` | `60` | Lease age before a task without a live dispatch pid is reclaimed. |
| `GLUERUN_TARGET_BRANCH` | (config) | Integration target branch. |
| `GLUERUN_BASH_BIN` | `bash` / current fallback | Absolute Bash ≥4 path set in the shell/service environment before launch. Bootstrap-only; committed repo config is ignored. |
| `GLUERUN_CODEX_BIN` | first `codex` on `PATH` | Absolute Codex executable used identically by doctor and `codex-run.sh`; an explicit broken path never falls back. |
| `GLUERUN_SESSION_AFFINITY` | `1` | Reuse a role's prior runtime session when staleness gates pass. |
| `GLUERUN_FIX_PROMPT_STRUCTURED` | `1` | Structured fix prompt (authoritative open findings) on retries. |
| `GLUERUN_DECIDER_FAST` | `1` | Clear-cut failure classes resolved by host policy table without a model round-trip. |
| `GLUERUN_WORKER_INFRA_MAX` / `GLUERUN_AUDIT_INFRA_MAX` | `1` / `2` | Extra re-runs on infra failures before surfacing them. |
| `GLUERUN_PREFLIGHT_REQUIRE_ACCEPTANCE` | `1` | Preflight rejects tasks without acceptance criteria. |
| `GLUERUN_CONSOLE_PORT` | `8765` (free-port fallback) | Port for `gluerun console`. |
| `GLUERUN_MAX_L1_CONCURRENT` | `3` | L1 planner fan-out cap when `GLUERUN_ENABLE_L1_PARALLEL=1` — raise it alongside worker concurrency or parallelism pins at this cap. |
| `GLUERUN_DECIDER_TIMEOUT_SEC` | `1200` | Wall-clock bound on a model decider run. |
| `GLUERUN_CLAUDE_TIMEOUT_SEC` | `1200` | claude runner kill-tree timeout (`0` off). |
| `GLUERUN_CODEX_TIMEOUT_SEC` | `2400` | codex runner kill-tree timeout (`0` off; new 0.5.0 — codex runs were unbounded). |
| `GLUERUN_CODEX_IDLE_SEC` | `0` (off) | Kill a codex run whose JSONL output stops growing for this long; `600` recommended for long autonomous runs. |
| `GLUERUN_L1_STALE_MINUTES` | `60` | L1 planning-lease age before `recover` reclaims it (`GLUERUN_RECOVER_L1=1`). |
| `GLUERUN_STALE_HARD_MINUTES` | `240` | Tree-liveness conservatism cap: past this lease age a dispatch is reaped regardless of surviving processes. |
| `GLUERUN_QUOTA_SLEEP_CAP` / `GLUERUN_QUOTA_WAIT_BUDGET` | `300` / `10800` | Per-nap cap and total budget for quota-window sleeps (budget exhaustion writes STOP). |
| `GLUERUN_LIMIT_SLEEPTHROUGH` | `1` | Sleep through provider limit windows instead of tripping the breaker — 0.5.0 requires structured evidence (a runner-log marker with a logRef); repo prose can no longer arm a false backoff. |
| planner backoff accounting | — | A valid backoff defers only planning for non-quota classes and is neutral to the no-progress breaker; unrelated failures still count. Quota retains full sleep-through. |
| `GLUERUN_AUTO_PROMOTE_GATES` | `1` | Promote gates at integrate time + on empty-queue cycles (0.4.0 default was 0). |
| `GLUERUN_PROMOTE_TOLERATE_TERMINAL` | `1` | Superseded/blocked predecessors with an integrated successor count as satisfied for promotion. |
| `GLUERUN_SUPPRESS_UNPROMOTED_REPLAN` | `1` | Never re-plan a node whose tasks are complete but whose gate is unpublished (a published failed gate keeps the node plannable). |
| `GLUERUN_AUTO_ACCEPT_EXISTING` | `1` | A dispatch against an accepted lease auto-heals via accept-existing-packet. |
| `GLUERUN_REFUSAL_PARK_THRESHOLD` | `3` | Consecutive dispatch refusals before the task is parked instead of starving the loop. |
| `GLUERUN_RECOVER_L1` | `1` | `recover` reclassifies stale L1 planning leases (report-only in 0.4.0). |
| `GLUERUN_AUTO_PRUNE` | `0` | `recover --scan` prunes integrated+merged+clean worktrees. |
| `GLUERUN_INTEGRATE_REBASE` | `0` | Rebase-and-regate the audited branch once on merge conflict instead of parking. |
| `GLUERUN_LEGACY_SCHEMA_MODE` | `warn` | Legacy `pmgo.*` verdict schema ids tolerated with a warning; `reject` after running `migrations/v0-to-v1.sh`. |
| `GLUERUN_AUDIT_VERDICT_VALIDATE` | `warn` | Central schema validation of auditor verdicts; `strict` re-runs the auditor on an invalid verdict. |
| `GLUERUN_REVIEW_MAX_AGE_HOURS` | `168` | Max age of gate-review.v0 evidence for evaluation-node promotion (`0` off). |
| `GLUERUN_RUNS_KEEP` / `GLUERUN_EVENTS_MAX_MB` | `200` / `64` | `gluerun gc` runs-history cap per bucket and events rotation threshold. |
| `GLUERUN_SLEEP_POLL_SEC` | `10` | Interruptible-sleep chunk: STOP/`gluerun wake` take effect within this. |
| `GLUERUN_SUPERVISOR_INTERVAL_MIN` | `0` | Minutes between automatic read-only supervisor briefings from the L0 loop; `0`/unset = off (byte-inert). |
| `GLUERUN_SUPERVISOR_TIMEOUT_SEC` | `900` | Wall-clock bound on a briefing runner (`gluerun report` / an auto-briefing). |
| `GLUERUN_ASK_TIMEOUT_SEC` | `600` | Wall-clock bound on an ask runner (`gluerun ask`). |

Model/effort selection per role: `GLUERUN_CLAUDE_MODEL`,
`GLUERUN_CLAUDE_{L1,L2,PLANNER,AUDITOR,DECIDER}_MODEL`;
`GLUERUN_CODEX_MODEL`,
`GLUERUN_CODEX_{L1,L2,PLANNER,AUDITOR,CRITIC,DECIDER,READONLY}_REASONING_EFFORT`.

## Doctor, capability profiles, and operator gates

Run `gluerun doctor` before an unattended cycle and use
`gluerun doctor --json` in automation. The JSON report is
`gluerun.doctor-report.v1`; every check includes stable `id`, `status`,
`severity`, `requiredFor`, `remediation`, and `dedupeKey` fields. A non-zero
exit means at least one required preflight failed. Warnings cover optional
dependencies and do not block a run.

Doctor verifies the exact selected Bash, runner, and provider executable; the
runner contract; provider authentication and model inventory where available;
schema fixtures and mirrors; disposable worktree support; lazy role capability
profiles; bootstrap/lockfiles; adaptive disk capacity; and Codex cache
compatibility. Deployment credentials are deliberately skipped until a
deployment-capable node enters the ready DAG frontier.

Declare profiles with top-level `capabilityProfiles{}` and map roles with
`roleProfiles{}`. Profiles accept `required[]`, `optional[]`, and
`"startup": "lazy"`. Built-ins are `filesystem`, `git`, `schemas`, `skills`,
`runner-contract`, and `provider-executable`; external IDs use `mcp:NAME`,
`plugin:NAME`, `executable:NAME`, or `file:PATH`. A missing shared optional
capability is reported once with all affected roles in `requiredFor`.
Strict external activation must be declared under
`capabilityArgs.<exact-capability>` with provider-specific literal argv.
Profile-wide `providerArgs` cannot satisfy a named capability, and legacy
free-form provider extra-argument environment variables are disabled in
strict profiles.

`gluerun doctor` never mutates the Codex model cache. If compatibility is
warned, either update the selected CLI or explicitly run
`gluerun doctor --repair-model-cache`; repair atomically renames the original
to a timestamped, SHA-tagged backup and lets Codex regenerate it on its next
run.

Human approvals use `gluerun human-gate request|approve|status`. Requests bind
an owner, expiry, required questions, blocked nodes, and exact artifact hashes.
Approvals must link the exact request path and hash, answer exactly its
mandatory question set, and bind at least one evidence file. Approval is
invalid as soon as the request, an artifact, or evidence bytes change. Schema
v2 rejects the old unbound `promote-gate --operator --evidence` route unless
`legacyCompatibility.unboundWaivers` is explicitly enabled for migration.

## Context knobs (0.4.x)

Raw engine defaults stay `0` for back-compat; the recommended production
set (validated by the 0.4.0 experiment: 75 treatment tasks, 0 escaped
defects vs 1/30 control; median task wall-clock 9.6 min vs 19.1 min):

| Knob | Recommended | Effect |
| --- | --- | --- |
| `GLUERUN_PLANNER_SESSION` | `1` | Per-node planner session persistence/resume behind fail-closed lineage gates. |
| `GLUERUN_PLAN_CRITIQUE` | `1` | Fresh read-only skeptic critic over staged planner batches before import. |
| `GLUERUN_PLAN_REVISE_MAX` | `2` | Bounded revise→re-critique loop for `revise` verdicts. |
| `GLUERUN_CTX_PACKET` | `1` | Planner context packets flow into worker/fix/audit prompts. |
| `GLUERUN_CTX_ROUTING` | `1` | Explicit 5-strategy session routing with reason-coded events. |
| `GLUERUN_CTX_ARTIFACT_SCAN` | `1` | Secret scan over durable artifacts; hits quarantine out of prompts. |
| `GLUERUN_PAIRED_AUDIT_PCT` | `25` | Sampled post-acceptance fresh audits (bias measurement). |
| `GLUERUN_REHYDRATE`, `GLUERUN_CTX_MANIFEST`, `GLUERUN_CTX_GRAPH`, `GLUERUN_CTX_EXPERIMENT`, `GLUERUN_CTX_ARMSTATE` | opt-in | Rehydration packets, authored-knowledge manifests, context graph (`gluerun graph`), experiment reporting (`gluerun experiment-report`), arm provenance. |

Key events (in `.gluerun-state/events.ndjson`, countable via
`gluerun metrics`): `context.strategy_selected`, `context.resume_failed`,
`plan.critiqued`, `plan.revised`, `plan.revise_parked`,
`planner.backoff_active`, `ctx.paired_audit`, `ctx.artifact_secret`.

## Supervisor briefing & ask (0.10.0)

A read-only overseer that narrates the run and answers operator questions. It
is propose-only — it can suggest settings but never writes them:

```bash
gluerun report                       # one-shot briefing -> .gluerun-state/supervisor/latest.json
gluerun ask "where are we?" --wait   # ask a question; --wait tails until the answer lands
```

Enable automatic briefings with `GLUERUN_SUPERVISOR_INTERVAL_MIN` (minutes;
`0`/unset = off) — set it either in `gluerun.config.json` `env{}` or from the
console (the Providers-tab settings channel and the Home supervisor card's
enable chip both write it through `POST /api/settings`). The L0 loop then
briefs at most once per interval and stays byte-inert when the knob is unset.
Bound the runners with `GLUERUN_SUPERVISOR_TIMEOUT_SEC` (900) and
`GLUERUN_ASK_TIMEOUT_SEC` (600). Both verbs spawn a readonly one-shot agent
over a state digest; the ask/briefing runs appear in the console **Consoles**
surface as assistant-kind sessions, and Home renders the latest briefing plus a
propose-only chat (per-key Apply chips are the only write path).

## Autonomy runbook

`gluerun auto` halts on: STOP sentinel, wall-clock budget
(`GLUERUN_MAX_HOURS`), circuit breaker (`GLUERUN_MAX_CONSEC_FAILS`
consecutive no-progress cycles), or DAG exhaustion. `--once` runs a single
iteration. Note the STOP asymmetry: a STOP file makes reconcile cycles skip
dispatch (a pause), but makes a running `gluerun auto` loop *exit* — after
`gluerun resume` you must relaunch the loop. Since 0.5.0 STOP takes effect
mid-nap (within `GLUERUN_SLEEP_POLL_SEC`), `gluerun stop --wait` blocks until
the loop exits, and `gluerun auto --detach` is the supported daemonized
launch (setsid double-fork, `.gluerun-state/autonomate.log`, pidfile
liveness check) — never hand-roll nohup. For always-on operation there is
a launchd template under `templates/launchd/` (macOS).

When supervising a long run yourself (an agent driving repeated
`reconcile --actuate` cycles), the proven loop shape is:

1. **Actuate** with `GLUERUN_AUTO_INTEGRATE=1`.
2. **Always wait on dispatched task exits first** before evaluating the
   cycle — a standing planner refusal on one node must not short-circuit
   waiting on workers that are still running.
3. **Promote gates on node-complete signals only when** the proposal inbox
   is empty AND all of the node's task files are integrated (a
   duplicate-candidate with an un-integrated packet once nearly produced a
   false gate).
4. **Evaluation nodes promote only by authority** — `--operator` or an
   `agent-review-allowed` node with a valid review file (enforced by the
   engine since 0.5.0; see SKILL.md §5).
5. **Planner failures count toward loop exit only when the cycle produced
   nothing** (no imports, no integrations, no dispatches).
6. Launch the supervisor detached in its own session (e.g. a
   setsid/double-fork wrapper) — plain backgrounded shells die with the
   parent. Log to a file and monitor the file.
7. Health checks each pass: supervisor pid alive, worker pids vs leases,
   **free disk** (a 100%-full volume manifests as all-tests-red gate runs,
   not a disk error).

## Recovery recipes (0.5.0 verbs)

One numbered recipe per incident class: symptom → verify → command →
expected outcome. Never hand-edit state files; every recipe is a verb.

1. **Supersede a doomed task.** Symptom: task terminally blocked/parked, a
   successor should own its scope. Verify: `gluerun health --json | jq
   .tasks` and read the task file. Run: `gluerun supersede TASK-XXXX --by
   TASK-YYYY --reason "…"` (add `--force` only if a live dispatch must die).
   Expect: `task.superseded` event; file in `tasks/superseded/`; lease
   superseded; queued packets quarantined. All four surfaces in one command.
2. **Clear a false/stale planner backoff.** Symptom: `health` shows
   `backoff` active but the provider is fine (0.5.0 backoffs always carry a
   `logRef` — read it). Run: `gluerun clear-backoff`. Expect:
   `backoff.cleared` event; a sleeping loop wakes within
   `GLUERUN_SLEEP_POLL_SEC`.
3. **Breaker open after a fixed fault.** Verify the failing class is
   actually fixed (events tail), then `gluerun breaker reset` — or
   `gluerun wake` to clear backoff+breaker+STOP+nap in one shot. Expect:
   `breaker.reset`; next `gluerun auto` cycle proceeds.
4. **Stale L1 planning lease excluding a node.** Symptom:
   `next-areas --explain` shows the node ready but fanout skips it;
   `health` shows `l1Stale > 0`. Run: `gluerun recover --scan`. Expect:
   `recover.l1_lease_reclaimed`; node re-enters the frontier next cycle.
5. **Accepted work stranded (driver died after acceptance).** Usually
   self-heals: the next dispatch auto-runs accept-existing-packet
   (`l1.auto_accepted_existing`). Manual path: `gluerun accept-packet
   .gluerun-state/runs/<RUN>/packet.json` — it re-validates branch head,
   scope, secrets, and green commands deterministically.
6. **Merge conflict parked an audited branch.** Opt-in auto path: set
   `GLUERUN_INTEGRATE_REBASE=1` (rebase in the worktree, re-gate, one merge
   retry, `integration.rebased` decision). Manual path: supersede with a
   fresh task planned against the current target head.

## Troubleshooting

**Parallelism pinned at 1 task per batch.** Batch width =
`GLUERUN_MAX_CONCURRENT − active leases`. Stale non-terminal leases
silently eat the budget: inspect `.gluerun-state/leases/*.json` statuses,
then `gluerun recover --scan` / `--prune`.

**Task parked/escalated and needs resurrection.** Four state surfaces must
agree before it will dispatch and integrate again: (1) task-file `Status`,
(2) packet status in `.gluerun-state/inbox/`, (3) the run-dir `audit.json`
verdict — import cross-checks it; supersede honestly rather than editing
history, (4) `.gluerun-state/leases/<task>.json` status (integrate
early-skips blocked leases). `gluerun supersede` mutates all four
atomically — use it (recipe 1) instead of editing them by hand. The
imported-packet audit sidecar must read accepted.

**Content merged but task/lease never flipped to integrated.** Later cycles
skip it as "already-merged" and the promotion guard deadlocks. Fix the
bookkeeping (task-file Status + lease status) to match reality.

**Worker killed externally, no exit file.** If its branch finished the
work, the reaper + decider will rule integrate on a later cycle — verify
before intervening.

**Provider quota wall.** Switch runners: use the console Providers tab's
"Use as default runner", or set `GLUERUN_RUNNER` in `gluerun.config.json`
`env{}` (any of `claude-run.sh`, `codex-run.sh`, `gemini-run.sh`,
`opencode-run.sh`, `cursor-run.sh`, `grok-run.sh` — check auth first via
`gluerun console --providers`). Delete
`.gluerun-state/planner-backoff.json` if its premise died with the switch;
session-affinity's runner-changed gate correctly degrades persisted
sessions to fresh.

**Gate suddenly all-red across unrelated tasks.** Check free disk first,
then whether stray `GLUERUN_*` env leaked into the gate command's
environment (the test suite scrubs `GLUERUN_*` and runs with
stdin `</dev/null` for a reason).

**Engine vs repo drift.** `.gluerun-version` (repo pin) wins over
`gluerun.config.json` `engineVersion`; `gluerun doctor` warns on
disagreement, fails on schema mismatch (`gluerun migrate` upgrades).
`gluerun update <ver>` repins. Remember: the installed
`~/.gluerun/bin/gluerun` drives — never run engine tree scripts directly.
