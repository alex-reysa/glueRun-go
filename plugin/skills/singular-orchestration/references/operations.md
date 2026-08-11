# Operations — knobs, autonomy runbook, troubleshooting

Read this when tuning a run, supervising a long autonomous loop, or
debugging a stuck/misbehaving orchestration. Everything here reflects
engine 0.5.x behavior and lessons from production runs (including the
singular-frontend field audit that drove the 0.5.0 hardening).

## Core env knobs

Set durable values in `singular.config.json` `env{}`; use shell env for
one-off overrides. Operator secrets/overrides go in
`.singular-state/config.local.sh` (gitignored).

| Knob | Default | Effect |
| --- | --- | --- |
| `SINGULAR_MAX_CONCURRENT` | `5` | Max L2 workers running concurrently. |
| `SINGULAR_MAX_DISPATCH` | `5` | Max tasks dispatched per reconcile cycle. |
| `SINGULAR_ENABLE_L1_PARALLEL` | `0` | `1` runs one L1 planner per frontier node concurrently. Turn this ON for parallel planning. |
| `SINGULAR_DETACHED_DISPATCH` | `1` | Reconcile pre-leases and spawns workers in their own sessions, returning in seconds; a reaper attributes outcomes on later cycles. `0` = legacy synchronous wait. |
| `SINGULAR_AUTO_INTEGRATE` | `1` | Merge completed worker branches during actuate cycles. |
| `SINGULAR_PUSH` | `0` / `1` | Push integrated branches to the remote. Defaults to `0` for directly-invoked engine commands (`singular reconcile` etc.) and `1` under `singular auto` and launchd. |
| `SINGULAR_MAX_HOURS` | `12` | Wall-clock budget for `singular auto`. |
| `SINGULAR_MAX_CONSEC_FAILS` | `5` | Circuit breaker: consecutive no-progress cycles before `singular auto` halts. |
| `SINGULAR_MAX_RETRIES` | `3` | Per-task worker retries before the decider escalates. |
| `SINGULAR_STALE_MINUTES` | `60` | Lease age before a task without a live dispatch pid is reclaimed. |
| `SINGULAR_TARGET_BRANCH` | (config) | Integration target branch. |
| `SINGULAR_BASH_BIN` | `bash` / current fallback | Absolute Bash ≥4 path set in the shell/service environment before launch. Bootstrap-only; committed repo config is ignored. |
| `SINGULAR_CODEX_BIN` | first `codex` on `PATH` | Absolute Codex executable used identically by doctor and `codex-run.sh`; an explicit broken path never falls back. |
| `SINGULAR_SESSION_AFFINITY` | `1` | Reuse a role's prior runtime session when staleness gates pass. |
| `SINGULAR_FIX_PROMPT_STRUCTURED` | `1` | Structured fix prompt (authoritative open findings) on retries. |
| `SINGULAR_DECIDER_FAST` | `1` | Clear-cut failure classes resolved by host policy table without a model round-trip. |
| `SINGULAR_WORKER_INFRA_MAX` / `SINGULAR_AUDIT_INFRA_MAX` | `1` / `2` | Extra re-runs on infra failures before surfacing them. |
| `SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE` | `1` | Preflight rejects tasks without acceptance criteria. |
| `SINGULAR_CONSOLE_PORT` | `8765` (free-port fallback) | Port for `singular console`. |
| `SINGULAR_MAX_L1_CONCURRENT` | `3` | L1 planner fan-out cap when `SINGULAR_ENABLE_L1_PARALLEL=1` — raise it alongside worker concurrency or parallelism pins at this cap. |
| `SINGULAR_DECIDER_TIMEOUT_SEC` | `1200` | Wall-clock bound on a model decider run. |
| `SINGULAR_CLAUDE_TIMEOUT_SEC` | `1200` | claude runner kill-tree timeout (`0` off). |
| `SINGULAR_CODEX_TIMEOUT_SEC` | `2400` | codex runner kill-tree timeout (`0` off; new 0.5.0 — codex runs were unbounded). |
| `SINGULAR_CODEX_IDLE_SEC` | `0` (off) | Kill a codex run whose JSONL output stops growing for this long; `600` recommended for long autonomous runs. |
| `SINGULAR_L1_STALE_MINUTES` | `60` | L1 planning-lease age before `recover` reclaims it (`SINGULAR_RECOVER_L1=1`). |
| `SINGULAR_STALE_HARD_MINUTES` | `240` | Tree-liveness conservatism cap: past this lease age a dispatch is reaped regardless of surviving processes. |
| `SINGULAR_QUOTA_SLEEP_CAP` / `SINGULAR_QUOTA_WAIT_BUDGET` | `300` / `10800` | Per-nap cap and total budget for quota-window sleeps (budget exhaustion writes STOP). |
| `SINGULAR_PLANNER_BACKOFF_SECONDS` | `900` | Wait after an ordinary planner error before re-planning. |
| `SINGULAR_PLANNER_QUOTA_BACKOFF_SECONDS` | `1800` | Wait after a usage-limit (429) or entitlement (403) rejection — a window the account has to sit out. |
| `SINGULAR_PLANNER_OVERLOAD_BACKOFF_SECONDS` | `180` | Wait after a provider 503/529 (0.15.1). Overload is transient capacity, not a usage limit; before it had its own class a single 529 bought the 1800s quota window and, because the nap skips reconcile, idled the whole graph for half an hour. |
| `SINGULAR_OVERLOAD_WAIT_BUDGET` | `3600` | Total overload sleep-through before STOP. Separate from the quota budget so a burst of 529s cannot spend the usage-limit allowance. |
| `SINGULAR_LIMIT_SLEEPTHROUGH` | `1` | Sleep through provider limit windows instead of tripping the breaker — 0.5.0 requires structured evidence (a runner-log marker with a logRef); repo prose can no longer arm a false backoff. |
| planner backoff accounting | — | A valid backoff defers only planning for classes outside the two provider-window classes, and is neutral to the no-progress breaker; unrelated failures still count. `quota` and `provider-overloaded` retain full sleep-through, differing only in window length and budget. |
| `SINGULAR_AUTO_PROMOTE_GATES` | `1` | Promote gates at integrate time + on empty-queue cycles (0.4.0 default was 0). |
| `SINGULAR_PROMOTE_TOLERATE_TERMINAL` | `1` | Superseded/blocked predecessors with an integrated successor count as satisfied for promotion. |
| `SINGULAR_SUPPRESS_UNPROMOTED_REPLAN` | `1` | Never re-plan a node whose tasks are complete but whose gate is unpublished (a published failed gate keeps the node plannable). |
| `SINGULAR_AUTO_ACCEPT_EXISTING` | `1` | A dispatch against an accepted lease auto-heals via accept-existing-packet. |
| `SINGULAR_REFUSAL_PARK_THRESHOLD` | `3` | Consecutive dispatch refusals before the task is parked instead of starving the loop. |
| `SINGULAR_RECOVER_L1` | `1` | `recover` reclassifies stale L1 planning leases (report-only in 0.4.0). |
| `SINGULAR_AUTO_PRUNE` | `0` | `recover --scan` prunes integrated+merged+clean worktrees. |
| `SINGULAR_INTEGRATE_REBASE` | `0` | Rebase-and-regate the audited branch once on merge conflict instead of parking. |
| `SINGULAR_LEGACY_SCHEMA_MODE` | `warn` | Legacy `pmgo.*` verdict schema ids tolerated with a warning; `reject` after running `migrations/v0-to-v1.sh`. |
| `SINGULAR_AUDIT_VERDICT_VALIDATE` | `warn` | Central schema validation of auditor verdicts; `strict` re-runs the auditor on an invalid verdict. |
| `SINGULAR_REVIEW_MAX_AGE_HOURS` | `168` | Max age of gate-review.v0 evidence for evaluation-node promotion (`0` off). |
| `SINGULAR_RUNS_KEEP` / `SINGULAR_EVENTS_MAX_MB` | `200` / `64` | `singular gc` runs-history cap per bucket and events rotation threshold. |
| `SINGULAR_SLEEP_POLL_SEC` | `10` | Interruptible-sleep chunk: STOP/`singular wake` take effect within this. |
| `SINGULAR_SUPERVISOR_INTERVAL_MIN` | `0` | Minutes between automatic read-only supervisor briefings from the L0 loop; `0`/unset = off (byte-inert). |
| `SINGULAR_SUPERVISOR_TIMEOUT_SEC` | `900` | Wall-clock bound on a briefing runner (`singular report` / an auto-briefing). |
| `SINGULAR_ASK_TIMEOUT_SEC` | `600` | Wall-clock bound on an ask runner (`singular ask`). |

Model/effort selection per role: `SINGULAR_CLAUDE_MODEL`,
`SINGULAR_CLAUDE_{L1,L2,PLANNER,AUDITOR,DECIDER}_MODEL`;
`SINGULAR_CODEX_MODEL`,
`SINGULAR_CODEX_{L1,L2,PLANNER,AUDITOR,CRITIC,DECIDER,READONLY}_REASONING_EFFORT`.

## Doctor, capability profiles, and operator gates

Run `singular doctor` before an unattended cycle and use
`singular doctor --json` in automation. The JSON report is
`singular.doctor-report.v1`; every check includes stable `id`, `status`,
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

`singular doctor` never mutates the Codex model cache. If compatibility is
warned, either update the selected CLI or explicitly run
`singular doctor --repair-model-cache`; repair atomically renames the original
to a timestamped, SHA-tagged backup and lets Codex regenerate it on its next
run.

`singular setup` (below) runs the same doctor invocation and keeps the report as
evidence instead of printing it and losing it.

Human approvals use `singular human-gate request|approve|status`. Requests bind
an owner, expiry, required questions, blocked nodes, and exact artifact hashes.
Approvals must link the exact request path and hash, answer exactly its
mandatory question set, and bind at least one evidence file. Approval is
invalid as soon as the request, an artifact, or evidence bytes change. Schema
v2 rejects the old unbound `promote-gate --operator --evidence` route unless
`legacyCompatibility.unboundWaivers` is explicitly enabled for migration.

## One-command setup (`singular setup`)

The recommended entry point into a repository whose state you do not already
know. It COMPOSES the individual verbs rather than replacing them —
`singular init` scaffolds, `singular migrate` migrates, `singular doctor`
validates, `singular test` runs the suite — and contributes the order, the
evidence, and the contract.

```bash
singular setup                 # full path; ends at stopped-ready
singular setup --no-test       # stop at `validated`, no regression run
singular setup --test-async    # start the suite detached; attach with singular test --wait
singular setup --json          # one singular.setup-report.v0 on stdout, narration on stderr
```

The order is the point — every prerequisite fails before the repository is
mutated:

1. Interpreter (Bash >= 4), repository root, and a git work tree whose `HEAD`
   resolves to a commit.
2. Pin resolution said out loud: both sources are printed, and a
   `.singular-version` vs `singular.config.json` `engineVersion` disagreement is
   a named `SINGULAR_PIN_CONFLICT` warning, not a silent precedence rule.
3. Engine presence. An absent pinned engine is installed **only** from a
   matching engine checkout already on this machine — there is no download
   mechanism, and the failure says so instead of implying a fetch.
4. `.singular-state/STOP` — the FIRST repo write, so everything after it happens
   in a repo that cannot dispatch a worker. Mirrored into `.pmgo-state/` only
   when that legacy root already exists; never created.
5. Version pin, then scaffold (skipped when `singular.config.json` exists).
6. A hash snapshot of every gate result, written fresh each run to
   `.singular-state/setup/gates-pre-migrate.json` — a stale snapshot can never
   bless a rewrite it did not see.
7. The migration chain printed first (`singular migrate --dry-run`), then run.
8. Gate preservation verified **semantically**: `node`, `status`,
   `authoritative`, and `recordedAt` must survive. A byte-rewritten file (the
   v0→v1 namespace rebrand) is informational; a changed verdict — or a check
   that did not complete — is `SINGULAR_GATE_PRESERVATION_FAILED`.
9. `singular doctor`, report kept at `.singular-state/setup/doctor.json`.
10. A supervised regression run (next section).

State ladder, recorded in `.singular-state/setup/state.json` and never claiming
a state that was not reached: `installed → migrated → validated →
stopped-ready`. Then exactly one next action:

```text
State: stopped-ready (STOP active; no workers dispatched)
Next: singular resume
```

That line is a pending `singular human-gate status <id>` when one is waiting,
`singular test --wait` after `--test-async`,
`SINGULAR_ENGINE_HOME=<engine checkout> singular test` when the resolved engine
cannot host the suite, `singular test` when the suite has simply not passed yet,
and `singular resume` only at `stopped-ready`. Setup never removes STOP —
actuation stays a separate, explicit operator action.

Step 10 is where a consumer on an INSTALLED engine stops. The suite runs only
from a checkout (next section), which is a fact about the engine, not a defect
in the repository — so setup records `SINGULAR_TEST_SUITE_UNAVAILABLE` (or
`SINGULAR_TEST_SOURCE_UNSUPPORTED`) as a **warning** in the report, skips the
step, and finishes at `validated` with the checkout as its next action. It does
not fail a repository whose own steps all passed, and it never claims
`stopped-ready` without a passing run.

Failures carry a stable code and one recovery instruction
(`singular.operator-failure.v0`, mirrored into
`.singular-state/setup/last-result.json`): `SINGULAR_NOT_A_REPOSITORY`,
`SINGULAR_TEST_SOURCE_UNSUPPORTED` (as a failure: the *repository* is not a Git
work tree), `SINGULAR_ENGINE_NOT_INSTALLED`, `SINGULAR_REPO_UNWRITABLE`,
`SINGULAR_MIGRATION_MISSING`, `SINGULAR_MIGRATION_FAILED`,
`SINGULAR_GATE_PRESERVATION_FAILED`, `SINGULAR_DOCTOR_BLOCKED`,
`SINGULAR_TEST_RUN_FAILED`. Re-running is safe: no migration repeats, no config
is rewritten, no second suite starts.

## Supervised regression runs (`singular test`)

The engine's own suite is a long job (`<engine home>/tests/run.sh`, ~185 test
files) that outlives the session which started it. `singular test` makes it a
supervised, attachable run whose evidence lands in the current repo under
`.singular-state/test-runs/<runId>/` (`manifest.json`, `suite.log`, `logs/`,
`progress.jsonl`).

**The engine home must be a checkout.** Most tests build disposable Git
worktrees of `HEAD`, so `tests/run.sh` opens with a source preflight requiring
real history — which an installed version (a plain copy under
`~/.singular/versions/`) cannot satisfy, and which is why installed versions ship
no `tests/` at all. Run it from the consumer repo against a checkout; the
evidence still lands in the repo you are in:

```bash
SINGULAR_ENGINE_HOME=/path/to/engine-checkout singular test
```

```bash
singular test                    # start a run and attach — or attach to the live one
singular test --no-wait          # start detached; the run id goes to stdout
singular test --wait             # attach to the live (or last recorded) run
singular test --status [--json]  # report on the current run
singular test --new-run          # deliberately start a concurrent second run
singular test --rerun-failures   # re-run only the last completed run's failures
```

Liveness is proved, not guessed. The detached supervisor holds an exclusive
`flock` on `supervisor.lock` for its entire life, and the kernel releases that
lock on ANY death — crash, `kill -9`, power loss — so a non-blocking shared
probe answers "is it still running?" without consulting `ps` and without
trusting a pid that may have been recycled. A supervisor that died mid-run
reconciles the manifest to `interrupted` **with the counts it reached**, so a
killed suite never reads as finished or as a silent pass — and reconciliation
kills the run's recorded process group, because the suite is a child of the
supervisor and outlives it: left alone it keeps appending results to a run
already declared dead, and the next `singular test` starts a duplicate.

One live run at a time: a second invocation attaches instead of starting a
duplicate, and `--new-run` is the only way to say otherwise.

Starting a run on an engine home that cannot host the suite fails once, by name,
**before any run directory, manifest, lock or supervisor is created** —
`SINGULAR_TEST_SUITE_UNAVAILABLE` when there is no `tests/run.sh`,
`SINGULAR_TEST_SOURCE_UNSUPPORTED` when there is one but the tree is not a Git
checkout. `--status` and `--wait` are exempt in both cases: reporting on a past
run needs no runnable suite.

## Context knobs (0.4.x)

Raw engine defaults stay `0` for back-compat; the recommended production
set (validated by the 0.4.0 experiment: 75 treatment tasks, 0 escaped
defects vs 1/30 control; median task wall-clock 9.6 min vs 19.1 min):

| Knob | Recommended | Effect |
| --- | --- | --- |
| `SINGULAR_PLANNER_SESSION` | `1` | Per-node planner session persistence/resume behind fail-closed lineage gates. |
| `SINGULAR_PLAN_CRITIQUE` | `1` | Fresh read-only skeptic critic over staged planner batches before import. |
| `SINGULAR_PLAN_REVISE_MAX` | `2` | Bounded revise→re-critique loop for `revise` verdicts. |
| `SINGULAR_CTX_PACKET` | `1` | Planner context packets flow into worker/fix/audit prompts. |
| `SINGULAR_CTX_ROUTING` | `1` | Explicit 5-strategy session routing with reason-coded events. |
| `SINGULAR_CTX_ARTIFACT_SCAN` | `1` | Secret scan over durable artifacts; hits quarantine out of prompts. |
| `SINGULAR_PAIRED_AUDIT_PCT` | `25` | Sampled post-acceptance fresh audits (bias measurement). |
| `SINGULAR_REHYDRATE`, `SINGULAR_CTX_MANIFEST`, `SINGULAR_CTX_GRAPH`, `SINGULAR_CTX_EXPERIMENT`, `SINGULAR_CTX_ARMSTATE` | opt-in | Rehydration packets, authored-knowledge manifests, context graph (`singular graph`), experiment reporting (`singular experiment-report`), arm provenance. |

Key events (in `.singular-state/events.ndjson`, countable via
`singular metrics`): `context.strategy_selected`, `context.resume_failed`,
`plan.critiqued`, `plan.revised`, `plan.revise_parked`,
`planner.backoff_active`, `ctx.paired_audit`, `ctx.artifact_secret`.

## Supervisor briefing & ask (0.10.0)

A read-only overseer that narrates the run and answers operator questions. It
is propose-only — it can suggest settings but never writes them:

```bash
singular report                       # one-shot briefing -> .singular-state/supervisor/latest.json
singular ask "where are we?" --wait   # ask a question; --wait tails until the answer lands
```

Enable automatic briefings with `SINGULAR_SUPERVISOR_INTERVAL_MIN` (minutes;
`0`/unset = off) — set it either in `singular.config.json` `env{}` or from the
console (the Providers-tab settings channel and the Home supervisor card's
enable chip both write it through `POST /api/settings`). The L0 loop then
briefs at most once per interval and stays byte-inert when the knob is unset.
Bound the runners with `SINGULAR_SUPERVISOR_TIMEOUT_SEC` (900) and
`SINGULAR_ASK_TIMEOUT_SEC` (600). Both verbs spawn a readonly one-shot agent
over a state digest; the ask/briefing runs appear in the console **Consoles**
surface as assistant-kind sessions, and Home renders the latest briefing plus a
propose-only chat (per-key Apply chips are the only write path).

## Autonomy runbook

`singular auto` halts on: STOP sentinel, wall-clock budget
(`SINGULAR_MAX_HOURS`), circuit breaker (`SINGULAR_MAX_CONSEC_FAILS`
consecutive no-progress cycles), or DAG exhaustion. `--once` runs a single
iteration. Note the STOP asymmetry: a STOP file makes reconcile cycles skip
dispatch (a pause), but makes a running `singular auto` loop *exit* — after
`singular resume` you must relaunch the loop. Since 0.5.0 STOP takes effect
mid-nap (within `SINGULAR_SLEEP_POLL_SEC`), `singular stop --wait` blocks until
the loop exits, and `singular auto --detach` is the supported daemonized
launch (setsid double-fork, `.singular-state/autonomate.log`, pidfile
liveness check) — never hand-roll nohup. For always-on operation there is
a launchd template under `templates/launchd/` (macOS).

When supervising a long run yourself (an agent driving repeated
`reconcile --actuate` cycles), the proven loop shape is:

1. **Actuate** with `SINGULAR_AUTO_INTEGRATE=1`.
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
   successor should own its scope. Verify: `singular health --json | jq
   .tasks` and read the task file. A task parked on an ENVIRONMENT failure
   (`escalate-infra`, or `escalate-parked` after `audit-infra`/`worker-infra`)
   is not broken work — repair the environment, then `singular unpark TASK-XXXX`
   to return it to the frontier with its retry budget reset. Supersede is for
   work that should be replaced, not for work that was blocked. Run:
   `singular supersede TASK-XXXX --by
   TASK-YYYY --reason "…"` (add `--force` only if a live dispatch must die).
   Expect: `task.superseded` event; file in `tasks/superseded/`; lease
   superseded; queued packets quarantined. All four surfaces in one command.
2. **Clear a false/stale planner backoff.** Symptom: `health` shows
   `backoff` active but the provider is fine (0.5.0 backoffs always carry a
   `logRef` — read it). Run: `singular clear-backoff`. Expect:
   `backoff.cleared` event; a sleeping loop wakes within
   `SINGULAR_SLEEP_POLL_SEC`.
3. **Breaker open after a fixed fault.** Verify the failing class is
   actually fixed (events tail), then `singular breaker reset` — or
   `singular wake` to clear backoff+breaker+STOP+nap in one shot. Expect:
   `breaker.reset`; next `singular auto` cycle proceeds.
4. **Stale L1 planning lease excluding a node.** Symptom:
   `next-areas --explain` shows the node ready but fanout skips it;
   `health` shows `l1Stale > 0`. Run: `singular recover --scan`. Expect:
   `recover.l1_lease_reclaimed`; node re-enters the frontier next cycle.
5. **Accepted work stranded (driver died after acceptance).** Usually
   self-heals: the next dispatch auto-runs accept-existing-packet
   (`l1.auto_accepted_existing`). Manual path: `singular accept-packet
   .singular-state/runs/<RUN>/packet.json` — it re-validates branch head,
   scope, secrets, and green commands deterministically.
6. **Merge conflict parked an audited branch.** Opt-in auto path: set
   `SINGULAR_INTEGRATE_REBASE=1` (rebase in the worktree, re-gate, one merge
   retry, `integration.rebased` decision). Manual path: supersede with a
   fresh task planned against the current target head.

## Troubleshooting

**Parallelism pinned at 1 task per batch.** Batch width =
`SINGULAR_MAX_CONCURRENT − active leases`. Stale non-terminal leases
silently eat the budget: inspect `.singular-state/leases/*.json` statuses,
then `singular recover --scan` / `--prune`.

**Task parked/escalated and needs resurrection.** Four state surfaces must
agree before it will dispatch and integrate again: (1) task-file `Status`,
(2) packet status in `.singular-state/inbox/`, (3) the run-dir `audit.json`
verdict — import cross-checks it; supersede honestly rather than editing
history, (4) `.singular-state/leases/<task>.json` status (integrate
early-skips blocked leases). `singular supersede` mutates all four
atomically — use it (recipe 1) instead of editing them by hand. The
imported-packet audit sidecar must read accepted.

**Content merged but task/lease never flipped to integrated.** Later cycles
skip it as "already-merged" and the promotion guard deadlocks. Fix the
bookkeeping (task-file Status + lease status) to match reality.

**Worker killed externally, no exit file.** If its branch finished the
work, the reaper + decider will rule integrate on a later cycle — verify
before intervening.

**Provider quota wall.** Switch runners: use the console Providers tab's
"Use as default runner", or set `SINGULAR_RUNNER` in `singular.config.json`
`env{}` (any of `claude-run.sh`, `codex-run.sh`, `gemini-run.sh`,
`opencode-run.sh`, `cursor-run.sh`, `grok-run.sh` — check auth first via
`singular console --providers`). Delete
`.singular-state/planner-backoff.json` if its premise died with the switch;
session-affinity's runner-changed gate correctly degrades persisted
sessions to fresh.

**Gate suddenly all-red across unrelated tasks.** Check free disk first,
then whether stray `SINGULAR_*` env leaked into the gate command's
environment (the test suite scrubs `SINGULAR_*` and runs with
stdin `</dev/null` for a reason).

**Engine vs repo drift.** `.singular-version` (repo pin) wins over
`singular.config.json` `engineVersion`; `singular doctor` warns on
disagreement, fails on schema mismatch (`singular migrate` upgrades).
`singular update <ver>` repins. `singular setup` resolves the pin, migrates, and
re-validates in one pass when you would otherwise be running those verbs in
sequence. Remember: the installed `~/.singular/bin/singular` drives — never run
engine tree scripts directly.
