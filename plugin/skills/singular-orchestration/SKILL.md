---
name: singular-orchestration
description: Operate Singular (repo "singular-lite", formerly glueRun-go; CLI command `gluerun`) — an autonomous multi-agent orchestration engine that drives parallel AI coding agents against a git repo through a three-tier L0/L1/L2 model with DAG plans, durable leases, gate pipelines, and worktree isolation. Use whenever the user wants to orchestrate agents on a repo, set up gluerun/Singular in a repo, create or edit an orchestration plan or DAG, decompose a project into parallel tasks, run/resume/stop an orchestration, drive a single task end-to-end, check what orchestration agents are doing, or open the orchestration console/dashboard/viewer/visualization UI — even if they just say "singular", "gluerun", "orchestrate this", "run agents in parallel on this repo", "show me the dashboard", or "show me the agent graph" without naming a command.
---

# Singular orchestration (`gluerun`)

Singular (repo `singular-lite`, formerly glueRun-go) is a bash + Python engine
that runs autonomous AI coding agents in parallel against a repository. You —
the agent reading this — are its operator: you author the plan, launch the
loop, keep parallelism high, and verify completion through gates. The CLI
command is `gluerun`; the engine installs once per machine under `~/.gluerun`
and each consumer repo pins a version in `.gluerun-version`.

| Tier | Role |
| --- | --- |
| **L0 origin** | The single scheduler. Each reconcile cycle: import staged L1 proposals → recover stale leases → integrate finished branches → dispatch frontier tasks → snapshot. |
| **L1 area planners** | One planner per ready DAG node. Reads the node's context, plans a batch of L2 tasks, stages them as proposals for L0 to import. |
| **L2 workers** | Each executes one task in an isolated git worktree on a per-task branch, then writes a state packet. An auditor reviews it; a decider routes retry/escalate/park. |

Operating defaults — apply these unless the user says otherwise:

- **Run autonomously.** Launch `gluerun auto` (or a supervised
  `reconcile --actuate` loop) and monitor; do not hand-drive tasks one at a
  time or ask permission between cycles.
- **Maximize parallelism.** Enable concurrent L1 planners
  (`GLUERUN_ENABLE_L1_PARALLEL=1`), size `GLUERUN_MAX_CONCURRENT` /
  `GLUERUN_MAX_DISPATCH` to the machine, and design the DAG for a wide
  frontier (section 2). Detached dispatch is already ON by default.
- **The installed pin drives.** Always run `~/.gluerun/bin/gluerun` (on
  `PATH`), never `engine/*.sh` scripts from a checkout — tree scripts bypass
  the version pin and config loading.
- **Gates are the only completion authority.** A DAG node is done when
  `docs/orchestration/gates/<node>.gate-result.json` says so — never because
  a dashboard, task file, or planner claims it.

## 1. Orient, install, set up

First figure out where you are:

```bash
gluerun version && gluerun doctor        # engine installed + repo healthy?
gluerun status                            # existing orchestration state
ls docs/orchestration/dag.v0.json         # is there a plan?
```

If `gluerun` is missing, install the engine:

```bash
git clone https://github.com/alex-reysa/singular-lite /path/to/singular-lite
cd /path/to/singular-lite && bash install.sh
export PATH="$HOME/.gluerun/bin:$PATH"
```

In a repo whose state you do not already know — never orchestrated, or on an
older pin or schema — run the one command that composes the whole lifecycle:

```bash
gluerun setup                 # -> a verified, STOPPED repo; ends with one Next: line
gluerun setup --no-test       # stop at `validated`, without the regression run
gluerun setup --test-async    # start the regression run detached, attach later
gluerun setup --json          # one gluerun.setup-report.v0 object on stdout
```

`gluerun setup` is idempotent and never actuates. It checks interpreter, repo
root, and git work tree; resolves the engine pin (naming the winner when
`.gluerun-version` and `gluerun.config.json` `engineVersion` disagree);
installs the pinned engine if absent — **only from a matching engine checkout
already on this machine, there is no download path**; writes
`.gluerun-state/STOP` as its first repo write; pins and scaffolds
(`gluerun init`) when needed; hashes every existing gate result; prints the
migration chain and then runs it (`gluerun migrate`); verifies those historical
verdicts survived; runs `gluerun doctor`; and records a supervised regression
run (`gluerun test`). Prerequisites fail *before* anything is mutated, each
with a stable code and one recovery instruction
(`gluerun.operator-failure.v0`); evidence lands in `.gluerun-state/setup/`.

It reports a state ladder — `installed → migrated → validated → stopped-ready`
— claiming only what it reached, then exactly one next action:

```text
State: stopped-ready (STOP active; no workers dispatched)
Next: gluerun resume
```

Do what that line says and nothing else. Setup never removes STOP: lifting it
is the separate, explicit actuation step, and when a human gate is pending the
one next action is that gate instead. Full step order, failure codes, and the
`gluerun test` contract: [references/operations.md](references/operations.md).

`gluerun init` on its own still scaffolds `gluerun.config.json`,
`docs/orchestration/`, and `.gluerun-version` when scaffolding is all you want.

Either way, edit `gluerun.config.json` before anything will run:

- `targetBranch` — the integration branch workers merge into (use a working
  branch like `agent/integration`, not `main`; promote to `main` manually at
  milestones).
- `gateCommand` — the command that proves the repo healthy (e.g.
  `bash tests/run.sh`, `npm test`). The scaffold ships `false` on purpose so
  an unconfigured repo fails closed — replace it.
- `runner` — which agent CLI drives the roles: `claude-run.sh`,
  `codex-run.sh`, `gemini-run.sh`, `opencode-run.sh`, `cursor-run.sh`, or
  `grok-run.sh` (0.9.0; switchable later, e.g. on provider quota walls —
  from the console's Providers tab, or by writing `GLUERUN_RUNNER` to config
  `env{}`, which overrides the top-level key). Check install/auth status per
  provider with `gluerun doctor` or `gluerun console --providers`; the
  claude/codex runners keep per-role model+effort knobs, the others take a
  flat `GLUERUN_<PROVIDER>_MODEL` (unset = the CLI's own default) and have
  no session affinity yet.
- `areas{}` — named file-scope groups: each key maps to an array of path
  prefixes, e.g. `"areas": {"api": ["src/api/", "tests/api/"], "core":
  ["src/core/", "tests/core/"]}`. DAG nodes reference an area by key and
  worker owned-file scopes are checked against its prefixes.
- `env{}` — pin the parallelism and context knobs here so every entry point
  gets them (recommended production set):

```json
"env": {
  "GLUERUN_ENABLE_L1_PARALLEL": "1",
  "GLUERUN_MAX_CONCURRENT": "5",
  "GLUERUN_MAX_DISPATCH": "5",
  "GLUERUN_PLANNER_SESSION": "1",
  "GLUERUN_PLAN_CRITIQUE": "1",
  "GLUERUN_CTX_PACKET": "1",
  "GLUERUN_CTX_ROUTING": "1",
  "GLUERUN_CTX_ARTIFACT_SCAN": "1",
  "GLUERUN_PAIRED_AUDIT_PCT": "25"
}
```

Also rewrite the scaffolded role prompts in `docs/orchestration/prompts/`
for the repo's stack, and customize `docs/orchestration/planner-contract.md`
(section 2). Re-run `gluerun doctor` until clean.

The engine's own regression suite — the last thing `gluerun setup` does, and
the way to re-verify an engine after an environment change — is a supervised
job rather than a foreground command:

```bash
gluerun test                    # start a run, or attach to the live one
gluerun test --status [--json]  # what the current run is doing
gluerun test --wait             # attach to the live (or last recorded) run
gluerun test --rerun-failures   # re-run only the last completed run's failures
```

One live run at a time: a second `gluerun test` attaches instead of starting a
duplicate (`--new-run` is the explicit override). Liveness is proved by a lock
the kernel releases on any death, never guessed from a pid, so a supervisor
killed mid-run reconciles to `interrupted` with the counts it reached rather
than looking finished. Evidence survives the session that started it, under
`.gluerun-state/test-runs/<runId>/`.

The suite runs only from an engine **checkout**: most tests build disposable Git
worktrees of `HEAD`, and an installed engine (`~/.gluerun/versions/<ver>/`) is a
plain copy with no history — it ships no `tests/`. On one, `gluerun test` refuses
before creating anything (`GLUERUN_TEST_SUITE_UNAVAILABLE`, or
`GLUERUN_TEST_SOURCE_UNSUPPORTED` for a suite in a non-checkout tree), and
`gluerun setup` reports the same code as a warning and finishes at `validated`
instead of failing a repository that is otherwise correctly prepared. Record the
run from the consumer repo against a checkout — the evidence still lands in the
repo you are in:

```bash
GLUERUN_ENGINE_HOME=/path/to/engine-checkout gluerun test
```

## 2. Author the plan (DAG)

The plan is `docs/orchestration/dag.v0.json` (schema
`gluerun.orchestration.dag.v0`). `gluerun init` scaffolds it with a single
starter node — replace that with your real graph. Each node needs `id`,
`stage`, `area`, `layer`, `kind`, `dependsOn`, `requiredCompletion`
(+ optional `description`):

```json
{
  "id": "api-contract",
  "stage": "S1",
  "area": "api",
  "layer": "contract",
  "kind": "contract",
  "dependsOn": ["scaffold"],
  "requiredCompletion": "OpenAPI schema validates fixtures; contract tests green",
  "description": "Owns schemas/api/*; later api nodes build on this."
}
```

Design the graph for parallelism — the dispatch frontier is every node whose
dependencies have all gate-passed, and with L1 fanout enabled every frontier
node plans concurrently:

- **Minimal, honest `dependsOn`.** Every edge you add narrows the frontier.
  Depend on a node only when its output is genuinely consumed.
- **Non-overlapping areas.** Nodes running in parallel should own disjoint
  file scopes so their L2 workers integrate without conflicts. Give each node
  a clear file-ownership boundary in its description.
- **Small nodes, behavior-level `requiredCompletion`.** State it as a
  checkable outcome ("test X green", "command Y emits Z") — it becomes the
  gate promotion criterion.
- **Stages are waves, not locks.** `stage` groups nodes for humans; only
  `dependsOn` constrains scheduling.

Validate and inspect the frontier:

```bash
gluerun validate-dag
gluerun next-areas       # every currently-ready node
```

**Tasks are normally authored by L1 planners, not by you.** The planner for
each frontier node decomposes it into small strict-test-first tasks under
`docs/orchestration/tasks/TASK-XXXX.md` and stages them for L0 import. Your
lever over task quality is `docs/orchestration/planner-contract.md` — binding
rules the planners must follow (file conventions, scope discipline,
test-first policy, bundling of small dependent slices). To hand-author a task
(rare — hotfixes, seeding), copy `docs/orchestration/tasks/TEMPLATE.md`.

For the full DAG field semantics, task-file format, planner-contract
patterns, and a parallelism design checklist, read
[references/plan-authoring.md](references/plan-authoring.md).

## 3. Run — autonomous by default

The default way to run is the self-driving loop, `gluerun auto` — it loops
reconcile cycles until DAG exhaustion, the wall-clock budget
(`GLUERUN_MAX_HOURS`), a STOP sentinel, or the consecutive-no-progress
breaker, and it sets `GLUERUN_AUTO_INTEGRATE=1` and `GLUERUN_PUSH=1` by
default. Launch it detached so it survives your shell, then monitor
(section 4) instead of blocking on it:

```bash
# normal terminal:
nohup gluerun auto >> .gluerun-state/autonomate.out.log 2>&1 & disown
# agent harness that kills its process group at turn end — detach into a new session:
python3 -c 'import os,subprocess
if os.fork()==0:
    os.setsid()
    out=open(".gluerun-state/autonomate.out.log","ab")
    subprocess.Popen(["gluerun","auto"],stdout=out,stderr=out)
    os._exit(0)'
```

For finer control, run cycles yourself — with detached dispatch (the
default) each cycle returns in seconds while workers run in background
sessions, so a supervisor loop is just:

```bash
gluerun reconcile --actuate    # one cycle: import → recover → integrate → dispatch
gluerun reconcile --drain      # block until all detached workers exit
gluerun drive TASK-0042        # exception path: one task through L1→L2→audit
```

Control and safety:

- **Stop:** `touch .gluerun-state/STOP` — reconcile cycles observe it and
  skip dispatch (running workers finish), and a live `gluerun auto` loop
  exits on it. To resume: remove the file, then relaunch `gluerun auto` if
  it had exited. Never remove a STOP file you didn't create without asking
  the user.
- **Budget:** `GLUERUN_MAX_HOURS` caps the auto loop's wall-clock (default
  12h); the breaker trips after `GLUERUN_MAX_CONSEC_FAILS` (default 5)
  consecutive no-progress cycles.
- **Throughput check:** effective batch width is
  `GLUERUN_MAX_CONCURRENT − active leases`. If parallelism looks pinned at 1,
  sweep `.gluerun-state/leases/*.json` for stale non-terminal leases and run
  `gluerun recover --scan`.

## 4. Monitor

**Heartbeat loop (use this for periodic supervision — do NOT re-read this
skill or run a full command battery per poll):**

```bash
gluerun console --ensure   # once: prints the dashboard URL (idempotent)
prev=""
while sleep 60; do
  d="$(gluerun health --json)"          # <2s digest: gates, frontier, leases,
  cur="$(jq -r .digest <<<"$d")"        # backoff, breaker, STOP, disk, attention[]
  [[ "$cur" == "$prev" ]] && continue   # digest unchanged -> nothing to do
  prev="$cur"
  jq '{ok, gates, attention}' <<<"$d"
  # attention[] non-empty or ok:false -> read the Recovery recipes in
  # references/operations.md and act; otherwise keep looping.
done
```

The `digest` field hashes everything except the timestamp — comparing it is
the whole cheap-poll contract. `attention[]` names exactly what needs an
operator (STOP present, backoff active, breaker open, stale L1 leases, disk
below floor, autonomate dead).

Deeper inspection when something changed:

```bash
gluerun status                  # orchestration status (incl. console URL when live)
gluerun gates                   # per-node gate table
gluerun next-areas --explain    # frontier + per-node exclusion reasons
gluerun metrics                 # read-only per-task/aggregate context metrics
gluerun console --snapshot      # one-shot JSON health snapshot, no browser
gluerun console --task TASK-0042   # one-shot task detail JSON
```

The console is a web UI over orchestration state — an app shell whose left
sidebar lists plan threads (live + archived) plus an app-level Providers nav,
with Home/Plan/Consoles/Agents as thread-scoped tabs; Home also carries the
supervisor briefing/chat and provider quota gauges. Orchestration state stays
read-only (the sole write path is the whitelisted settings knobs). Start/reuse
it with `gluerun console --ensure` (URL persists in
`.gluerun-state/console.url`; `--status`/`--stop` manage it). Ground rules:
durable state is authoritative, "active" is derived from live facts (pids,
active leases, worktrees) — never from markdown claims or bare lease-file
existence. Full console usage, all API endpoints, and derived-state rules:
[references/console.md](references/console.md). Canonical artifact file map +
jq cookbook (exact field names per artifact):
[references/artifacts.md](references/artifacts.md).

While a run is live, watch for: worker liveness vs lease count, planner
failures (only fatal when a cycle produced nothing), and **free disk** — a
full volume shows up as confusing all-red gate runs, not as a disk error.

### Supervisor briefing & ask (0.10.0)

A read-only overseer can narrate the run and answer questions. It is
propose-only: it may suggest settings but never writes them — a human applies
them (the console's Apply chips write through the settings whitelist).

```bash
gluerun report                       # request a one-shot briefing (stage, risks, next steps)
gluerun ask "where are we?" --wait   # ask the supervisor; --wait tails to the answer
```

Both spawn a readonly one-shot agent over a state digest (STATUS, health,
frontier, gates, recent events, config). Auto-briefings are off by default; set
a cadence with `GLUERUN_SUPERVISOR_INTERVAL_MIN` (minutes, `0` = off — the L0
loop then briefs at most once per interval), and bound the runners with
`GLUERUN_SUPERVISOR_TIMEOUT_SEC` (900) / `GLUERUN_ASK_TIMEOUT_SEC` (600).
Briefings land in `.gluerun-state/supervisor/latest.json`; the console Home
shows the latest one plus a propose-only chat, and ask/report runs appear in
Consoles. See [references/console.md](references/console.md).

## 5. Completion, gates, recovery

When all of a node's tasks are integrated and its `requiredCompletion` is
demonstrably met, promote its gate:

```bash
gluerun area-gate <node-id>      # check gate status
gluerun promote-gate <node-id>   # write the gate result
```

`promote-gate` runs the repo's promoter script (`GLUERUN_PROMOTER`, default
`<engine>/gluerun-ext/promote-gate.sh`), which validates the evidence it is
configured to demand and writes `gates/<node>.gate-result.json`. You are
responsible for verifying the evidence is real before invoking it.

Since 0.5.0, gates auto-promote at integrate time (`GLUERUN_AUTO_PROMOTE_GATES=1`
default) — manual promotion is the exception, not the routine.

Promotion discipline (these have each caused real incidents):

- Promote only when the packet inbox is empty and every one of the node's
  task files is integrated or satisfied (superseded/blocked predecessors with
  an integrated successor count as satisfied since 0.5.0). Concrete check:
  `gluerun status` reports the inbox packet count; it must read 0.
- Never run `promote-gate` concurrently with a live reconcile cycle: the
  cycle's git operations clobber uncommitted gate files. Promote in a
  wait/drain window (`gluerun stop --wait` … `gluerun resume`).
- Evaluation nodes (`kind: evaluation`) are authority decisions. Under schema
  v2, record a first-class `human-gate` request and exact-artifact approval.
  The older `gluerun promote-gate <node> --operator --evidence <ref>` route is
  rejected unless `legacyCompatibility.unboundWaivers` is explicitly enabled.
  A node declaring `authority: agent-review-allowed` in the DAG may also
  promote on a valid PASSING review file at
  `gates/evidence/<node>.review.json` (gate-review.v0: independent reviewer
  identity, evidence refs, and headSha ancestor check). A failed review never
  writes a failed gate.
- A planner's "this node is already complete" refusal may be premature;
  re-read the claim after the last integration before promoting on it.

**Escalation contract:** when the frontier consists only of evaluation/
operator nodes, report ONCE to the operator with the exact required action
(the promote-gate command line or the review-file path), then idle — do not
re-notify every poll, do not silence the condition, and never weaken the gate
to make progress.

Recovery is CLI verbs since 0.5.0 — never hand-edit state files:

```bash
gluerun unpark TASK-XXXX                     # parked task -> frontier (status, lease, retry budget)
gluerun supersede TASK-XXXX --by TASK-YYYY   # all four surfaces atomically
gluerun clear-backoff                        # false/stale planner backoff
gluerun breaker reset                        # after fixing the failing class
gluerun wake                                 # backoff+breaker+STOP+nap, one shot
gluerun recover --scan                       # stale L2 + L1 leases, orphans
gluerun accept-packet <packet.json>          # stranded accepted work (usually automatic)
gluerun gc --dry-run                         # runs-history/worktrees/events hygiene
```

Numbered recipes per incident class (symptom → verify → command → expected
event) are in [references/operations.md](references/operations.md) — read it
before debugging a stuck or misbehaving run.

### Plan threads — finish one plan, start the next (0.8.0)

A repo holds one *active* plan; finished plans become read-only archived
threads (chat-style):

```bash
gluerun plan archive --name "Console redesign"   # snapshot + reset to starter DAG
gluerun plan list [--json]                       # registry of archived threads
```

`plan archive` refuses unless the run is truly finished: autonomate loop
stopped, origin lock free, no live dispatch trees, DAG frontier
`allComplete`, and `.worktrees/` empty (`gluerun gc` first). Each guard is
override-able with `--force`, but worktrees are never moved. It snapshots
the plan into `.gluerun-state/plans/<plan-id>/` (a mini-repo the console
can serve read-only: DAG, tasks, gates, areas, packets, events, runs,
leases, dispatch records + a `manifest.json`), keeps `prompts/`,
`planner-contract.md` and `decisions.md` live (copied into the archive),
then resets to the init starter DAG with a fresh event journal seeded by a
`plan.archived` event and commits the `docs/orchestration` reset
(`--no-commit` to skip). Task numbering restarts at TASK-0001. Author the
next plan exactly as in §2. Archived threads are browsable in the console
via the sidebar threads list / Home "Previous plans" card, or
`gluerun console --plans` (see [references/console.md](references/console.md)).

## Invariants — do not weaken

- `gateCommand` and gate results are the floor of truth; never bypass or
  soften them to make progress.
- The advocate/skeptic line: planner/implementer sessions never satisfy
  critic/auditor steps, and resumed sessions never satisfy an
  independence-required step.
- `.gluerun-state/`, `.worktrees/`, and `.gluerun-evidence/` are runtime
  state — never commit them, never hand-edit them. Every sanctioned mutation
  has a verb: `gluerun stop/resume`, `clear-backoff`, `breaker reset`,
  `supersede`, `unpark`, `wake`, `gc`.
- Singular executes repo-configured shell commands and launches coding
  agents; review `gluerun.config.json` and task files before running it in a
  repo you don't trust.
