# glueRun-go

```text
      _          ___
 __ _| |_  _ ___| _ \_  _ _ _ ___ __ _ ___
/ _` | | || / -_)   / || | ' \___/ _` / _ \
\__, |_|\_,_\___|_|_\\_,_|_||_|  \__, \___/
|___/                            |___/
```

**Autonomous multi-agent orchestration for software repos. One engine, many consumers.**

glueRun-go is a bash + Python orchestration engine that drives autonomous AI coding agents
in parallel against a repository. It implements a three-tier scheduling model
(L0 origin loop → L1 area planners → L2 worker agents) with durable leases, state packets,
gate/audit pipelines, and git-worktree isolation. The engine is installed once per machine
and pinned per consumer repo — improvements propagate by bumping a version pin, not by
re-copying scripts.

## How it works

### Agent tiers

| Tier | Role |
| --- | --- |
| **L0 origin** | The single scheduler. Runs the reconcile cycle: import → recover → integrate → dispatch → snapshot. Holds the origin lock only during control work. |
| **L1 area planners** | One planner per DAG node (area). Reads the node's context, plans a batch of L2 tasks, and stages them as proposals for L0 to import. |
| **L2 workers** | Execute a single task in an isolated git worktree on a per-task branch. Produce a state packet (owned files, changes, evidence). An auditor reviews the packet; the decider routes the outcome. |

### Reconcile cycle

Each `gluerun reconcile --actuate` runs:

1. **Import** — pull staged L1 task proposals into the DAG under the origin lock.
2. **Recover** — reclaim stale leases whose workers have exited or timed out.
3. **Integrate** — merge completed worker branches into the target branch under the git-op lock.
4. **Dispatch** — pre-lease frontier tasks and spawn L2 workers.
5. **Snapshot** — write a human-readable project state snapshot.

### Leases and packets

Every in-flight task holds a **lease** (a JSON file in `.gluerun-state/leases/`) that records
ownership, retry count, and expiry. When a worker finishes it writes a **state packet**
(`state-packet.v0.schema.json`) enumerating owned files, changed files, commands, tests, and
evidence. The auditor validates the packet; the reaper attributes outcomes on later cycles.

### Gates and audits

After each L2 worker run the host executes the configured **gate command** (e.g. `npm test`).
A gate result (`gate-result.v0.schema.json`) feeds the **auditor** model, which returns an
audit verdict (`audit-verdict.v0.schema.json`). The **decider** maps the
`(failure-class, retries-left)` pair to a recovery action — retry, amend-scope, escalate, or
park — using a deterministic fast-path table before falling back to a model round-trip.

## Dispatch model

**Detached dispatch is ON by default.** When `GLUERUN_DETACHED_DISPATCH=1` (the default),
`reconcile` pre-leases each frontier task and spawns the worker in its own session via
`dispatch-wrap.sh`, then returns within seconds. The origin lock is held only for the cycle's
control work. A **reaper** (`gluerun_reap_dispatches`) runs at the top of every
apply/actuate cycle and attributes completions, failures, and crashes by checking dispatch
records + worker exit files (pid liveness defeats pid reuse; crash detection drops from the
60-min stale-lease window to ~one cycle).

This is what keeps import, integrate, recover, STATUS, and STOP responsive while long
workers run in the background.

Set `GLUERUN_DETACHED_DISPATCH=0` to restore the legacy synchronous batch path, where
`reconcile` waits for every worker before returning.

## Install

Prerequisites:

- Bash >= 4, `python3`, and `git`.
- At least one supported runner CLI on `PATH` (`claude`, `codex`, or another
  configured runner).
- macOS users may need `brew install bash` and a `PATH` entry that resolves
  `bash` to the Homebrew version before `/bin/bash`.

```bash
# Clone and install the engine to ~/.gluerun
git clone https://github.com/alex-reysa/glueRun-go /path/to/glueRun-go
cd /path/to/glueRun-go
bash install.sh
# -> ~/.gluerun/versions/<ver>/  ~/.gluerun/current  ~/.gluerun/bin/gluerun

export PATH="$HOME/.gluerun/bin:$PATH"
```

In each consumer repo:

```bash
gluerun init      # scaffold gluerun.config.json, docs/orchestration/, .gluerun-version
gluerun doctor    # check deps, engine resolution, repo config
```

Each repo pins its engine version in `.gluerun-version` (overrides `gluerun.config.json`
`engineVersion`). The `gluerun` launcher resolves that version from `~/.gluerun/versions/<ver>`,
binds `GLUERUN_ROOT` to the current repo, loads its config, and execs the engine. Run
`gluerun update <ver>` to repin.

## Use

```bash
# Run one reconcile/actuate cycle (import → recover → integrate → dispatch → snapshot)
gluerun reconcile --actuate

# Drive a single task through L1 → L2 → audit
gluerun drive TASK-0001

# Self-driving autonomy loop (wall-clock budget: GLUERUN_MAX_HOURS)
gluerun auto

# Block until all detached workers finish (useful in CI or clean shutdown)
gluerun reconcile --drain
```

## Configuration

All per-repo variation lives in the consumer repo, never in engine files:

- **`gluerun.config.json`** — declarative: `targetBranch`, `gateCommand`, `runner`,
  `areas{}`, `areaPrefix`, `prewarm`, `modules[]`, `identity{}`, `env{}`,
  `provisionFiles[]`, `envAllowlist[]`.
- **`gluerun.config.sh`** — optional shell extras (computed values, functions).
- **`.gluerun-state/config.local.sh`** — gitignored operator overrides and secrets.

The starter config deliberately sets `gateCommand` to `false` so a newly
scaffolded repo fails closed until you replace it with the command that proves
the repo is healthy.

`provisionFiles` entries copy repo-local, gitignored files into each worker
worktree after `git worktree add`: `{ "source": ".env.local", "target":
".env.local", "required": true }`. The source and target must both be ignored
or provisioning fails closed. `envAllowlist` accepts exact env names or prefix
patterns ending in `*`; allowed values are written to
`worktree/.gluerun-state/worktree-env.sh` and sourced for prewarm/gate phases.

### Operator env knobs

| Env knob | Default | Effect |
| --- | --- | --- |
| `GLUERUN_MAX_CONCURRENT` | `5` | Maximum L2 workers running concurrently. |
| `GLUERUN_MAX_DISPATCH` | `5` | Maximum tasks dispatched per reconcile cycle. |
| `GLUERUN_DETACHED_DISPATCH` | `1` | **Default ON.** Reconcile spawns workers in their own session and returns in seconds; the reaper attributes outcomes on later cycles. Set `0` for the legacy synchronous batch wait. |
| `GLUERUN_AUTO_INTEGRATE` | `1` | Automatically integrate (merge) completed worker branches in direct `reconcile --actuate`, `gluerun auto`, launchd, and console-driven cycles. |
| `GLUERUN_PUSH` | `0` direct / `1` auto | Push integrated branches to the remote. Direct engine commands default local-only; `gluerun auto`/launchd set `1` unless overridden. |
| `GLUERUN_MAX_HOURS` | `12` | Wall-clock budget for the autonomy loop (`gluerun auto`). |
| `GLUERUN_MAX_RETRIES` | `3` | Per-task worker retries before the decider escalates. |
| `GLUERUN_STALE_MINUTES` | `60` | Lease age (minutes) before a task without a live dispatch pid is reclaimed by the reaper. |
| `GLUERUN_TARGET_BRANCH` | _(required)_ | Integration target branch in the consumer repo. |
| `GLUERUN_SESSION_AFFINITY` | `1` | Reuse a role's prior runtime session when all staleness gates pass; `0` always runs fresh. |
| `GLUERUN_FIX_PROMPT_STRUCTURED` | `1` | Structured fix prompt on retries (authoritative findings); `0` = legacy `fix_hints` tail. |
| `GLUERUN_DECIDER_FAST` | `1` | Resolve clear-cut failure classes by host policy table; `0` routes every failure through the model decider. |
| `GLUERUN_WORKER_INFRA_MAX` | `1` | Extra worker re-runs on an infra failure before surfacing `worker-infra`. |
| `GLUERUN_AUDIT_INFRA_MAX` | `2` | Extra auditor re-runs on an infra failure before surfacing `audit-infra`. |
| `GLUERUN_CONTEXT_SECTION_MAX_CHARS` | `4000` | Per-section cap on continuity content appended to prompts. |
| `GLUERUN_PREFLIGHT_REQUIRE_ACCEPTANCE` | `1` | Preflight requires non-empty `acceptanceCriteria` on a task. |

## Context continuity

Between retry attempts glueRun-go carries authoritative state forward rather than
re-deriving it from a log tail:

- **Context capsules** — hash-stamped `implementer-capsule.json` and
  `reviewer-capsule.json` per attempt.
- **Findings ledger** — `findings-status.json` upserted from each audit verdict, with
  stable finding ids tracked open/resolved across retries.
- **Structured fix prompts** — the worker receives authoritative open findings on retry
  (set `GLUERUN_FIX_PROMPT_STRUCTURED=0` to revert to the legacy byte-tail).
- **Re-audit delta prompts** — the auditor receives prior findings + fix diff +
  per-id verification targets.
- **Attempt archive** — each attempt's artifacts are copied (never moved) under
  `runs/<id>/attempts/<n>/` with an `attempts/index.json`.

### Session affinity and routing

Role-keyed runtime session resume (`codex exec resume`, `claude -r`) behind ordered
fail-closed staleness gates, for three roles:

- **Implementer/reviewer** (within one drive): defaulting ON
  (`GLUERUN_SESSION_AFFINITY=1`); any gate failure or runner refusal degrades
  silently to a fresh run within the same attempt.
- **Planner** (across planning runs, per DAG node): behind
  `GLUERUN_PLANNER_SESSION` — persisted per-node session meta, node-lineage and
  template-sha gates, session leases against concurrent resume, rc-86 fresh
  fallback. A planner session can decompose a multi-slice node across
  consecutive resumes.
- **Plan critic** (re-critique of a revised batch): the skeptic may be offered
  its own prior session — never an advocate's.

Every routing decision is reason-coded as a `context.strategy_selected` event
(`strategy` + the exact gate reason) and countable via `gluerun metrics`.

> **Invariant (evidence invariance):** routing never changes what counts as
> evidence. Gates, red/green proofs, scope checks, and the fresh implementation
> auditor are identical under every strategy — `fresh` or `resume`. Outcomes MAY
> improve with continuity (that is the point), and the improvement is measured,
> not assumed: per-strategy outcomes flow into the attempts index and
> `gluerun metrics`.

> **Advocate/skeptic line:** a session never crosses between advocate roles
> (planner, implementer) and skeptic roles (plan critic, auditor), in either
> direction. Per-role session-meta files make violations structural, not merely
> checked. Resumed or rehydrated sessions never satisfy an independence-required
> step.

### Plan critique and revision

Behind `GLUERUN_PLAN_CRITIQUE` (default OFF; flip only with the revision loop in
service): staged planner batches are reviewed by a fresh, read-only plan critic
on the default runner before L0 import. Verdicts follow `plan-critique.v0`:
`approve` → import; `revise` → the node's planner session is resumed with the
critic's structured findings (bounded by `GLUERUN_PLAN_REVISE_MAX`), records
per-finding dispositions (accepted/rejected-observation; silent drops are
recorded as unaddressed), and re-enters the critic; `park` / budget exhaustion →
candidates never reach import (fail closed). Critic infrastructure failure fails
OPEN with an event — the critic is an added safety layer; the un-bypassable
implementation auditor remains the floor.

## Modules

The generic `engine/` references **zero** project-specific symbols — enforced by
`tests/test-engine-clean.sh` (the abstraction gate test). All per-project logic lives in
opt-in modules:

```
gluerun-ext/
  storage-proof.sh    # example: durable-proof regime
  promote-gate.sh     # example: gate promoter
```

Modules are listed in `gluerun.config.json` → `modules[]`. A repo that doesn't list them
never loads them. The `GLUERUN_MODULES` env var is the runtime list (set by the JSON
config loader).

## Versioning and schema

Two versions move independently:

- **Engine pin** — `.gluerun-version` is the canonical per-repo pin (overrides
  `gluerun.config.json` `engineVersion`; if they disagree `.gluerun-version` wins and
  `gluerun doctor` warns). `gluerun update <ver>` rewrites it.
- **Schema** — `SCHEMA_VERSION` (repo root) holds the data-contract version (`v1` today).
  A repo records the schema it was scaffolded against in `gluerun.config.json` →
  `schemaVersion`. `gluerun doctor` fails on a schema mismatch; `gluerun migrate` runs
  the shipped `migrations/<from>-to-<to>.sh` chain and rewrites `schemaVersion`.
  All runtime JSON schema identifiers follow the namespace `gluerun.orchestration.*.v0`.

## Development and tests

```bash
bash tests/run.sh    # 23 regression tests
```

The test suite uses no live state — all fixtures use a generic layer vocabulary. The
`tests/test-engine-clean.sh` gate enforces the abstraction contract on `engine/`.

## Contributing

Run `bash tests/run.sh` before opening a PR. Keep `engine/` generic: project-specific
rules belong in opt-in modules under `gluerun-ext/` or in a consumer repo's config.
Do not commit `.gluerun-state/`, `.worktrees/`, `.gluerun-evidence/`, local env
files, or generated run artifacts.

## Security

glueRun-go executes repo-configured shell commands and launches local coding
agents in git worktrees. Review `gluerun.config.json`, `gluerun.config.sh`, and
task files before running it in an untrusted repo. Report vulnerabilities through
GitHub's private vulnerability reporting for this repository; if that is
unavailable, open a minimal public issue asking for a private channel and do not
include exploit details.

## License

Licensed under GPL-3.0 — see [LICENSE](LICENSE).
