---
name: singular-orchestration
description: Operate Singular (repo "singular-lite", formerly glueRun-go; CLI command `gluerun`) — an autonomous multi-agent orchestration engine that drives parallel AI coding agents against a git repo through a three-tier L0/L1/L2 model with DAG plans, durable leases, gate pipelines, and worktree isolation. Use whenever the user wants to orchestrate agents on a repo, set up gluerun/Singular in a repo, create or edit an orchestration plan or DAG, decompose a project into parallel tasks, run/resume/stop an orchestration, drive a single task end-to-end, check what orchestration agents are doing, or open the orchestration console — even if they just say "singular", "gluerun", "orchestrate this", "run agents in parallel on this repo", or "show me the agent graph" without naming a command.
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

In a repo that has never been orchestrated:

```bash
gluerun init      # scaffolds gluerun.config.json, docs/orchestration/, .gluerun-version
```

Then edit `gluerun.config.json` before anything will run:

- `targetBranch` — the integration branch workers merge into (use a working
  branch like `agent/integration`, not `main`; promote to `main` manually at
  milestones).
- `gateCommand` — the command that proves the repo healthy (e.g.
  `bash tests/run.sh`, `npm test`). The scaffold ships `false` on purpose so
  an unconfigured repo fails closed — replace it.
- `runner` — `claude-run.sh` or `codex-run.sh` (switchable later, e.g. on
  provider quota walls).
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

```bash
gluerun status                  # orchestration status (incl. inbox/imported packet counts)
gluerun metrics                 # read-only per-task/aggregate context metrics
gluerun console                 # browser console on a free local port
gluerun console --snapshot      # one-shot JSON health snapshot, no browser
gluerun console --task TASK-0042   # one-shot task detail JSON
```

The console is a read-only web UI (L0→L1→L2 graph, task inspector, events,
JSON API); the `--snapshot`/`--task` one-shot modes print JSON and exit
without starting a server. Ground rules: durable
state is authoritative, "active" is derived from live facts (pids, active
leases, worktrees) — never from markdown claims or bare lease-file existence.
Full console usage, all API endpoints, and derived-state rules:
[references/console.md](references/console.md).

While a run is live, watch for: worker liveness vs lease count, planner
failures (only fatal when a cycle produced nothing), and **free disk** — a
full volume shows up as confusing all-red gate runs, not as a disk error.

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

Promotion discipline (these have each caused real incidents):

- Promote only when the packet inbox is empty and every one of the node's
  task files is integrated — a lingering packet means work is still in
  flight. Concrete check: `gluerun status` reports the inbox/imported packet
  counts (inbox = `.gluerun-state/inbox/*.json`); it must read 0.
- Never run `promote-gate` concurrently with a live reconcile cycle: the
  cycle's git operations clobber uncommitted gate files. Promote in a
  wait/drain window.
- Never auto-promote evaluation/operator-driven nodes (`kind: evaluation`) —
  those need human or explicit-operator judgment.
- A planner's "this node is already complete" refusal may be premature;
  re-read the claim after the last integration before promoting on it.

Recovery: `gluerun recover --scan` (report) / `--prune` (reclaim orphans).
Escalated or parked tasks need four state surfaces in agreement before
resurrection — task-file Status, packet status, run-dir audit verdict, and
lease status. The full knob tables, autonomy-supervisor runbook, and
troubleshooting pitfalls are in
[references/operations.md](references/operations.md) — read it before
debugging a stuck or misbehaving run.

## Invariants — do not weaken

- `gateCommand` and gate results are the floor of truth; never bypass or
  soften them to make progress.
- The advocate/skeptic line: planner/implementer sessions never satisfy
  critic/auditor steps, and resumed sessions never satisfy an
  independence-required step.
- `.gluerun-state/`, `.worktrees/`, and `.gluerun-evidence/` are runtime
  state — never commit them, never hand-edit them except for documented
  levers (STOP file, clearing `planner-backoff.json` after a runner switch).
- Singular executes repo-configured shell commands and launches coding
  agents; review `gluerun.config.json` and task files before running it in a
  repo you don't trust.
