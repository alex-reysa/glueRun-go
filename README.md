https://github.com/user-attachments/assets/43bffbc9-8c57-4fe0-aad4-f7a7aea4beb4

# Singular

**Controlled autonomy for software repositories.**

Singular is a local, open-source orchestration engine for autonomous AI software delivery.
It turns a software objective into a bounded, inspectable workflow:

```text
plan → challenge → implement → test → audit → recover → integrate
```

The engine coordinates parallel coding agents without treating model output as proof.
Every task has explicit ownership, runs in an isolated Git worktree, produces durable
state and evidence, passes repository-defined gates, and is reviewed before integration.
Failures are retried, rescoped, escalated, or parked through controlled recovery paths.

**Speed is not control.** Singular is designed to provide both: parallel execution when it
is safe, and durable control when agents fail, disappear, exceed scope, lose context, or
confidently claim work is complete when the repository says otherwise.

Singular is written in Bash + Python, installed once per machine, and pinned independently
by each consumer repository.

## Video overview

[![Singular — 60-second overview: Speed is not control](docs/assets/singular-orchestration-poster.jpg)](docs/assets/singular-orchestration.mp4)

*Click the frame to play the 60-second overview with sound.*

## What Singular provides

- **Controlled autonomy** — run one task, one reconcile cycle, or a bounded self-driving
  loop without removing gates, stop controls, or human approval points.
- **Safe parallelism** — workers execute on per-task branches in isolated Git worktrees
  rather than editing one shared checkout.
- **Durable coordination** — leases, run records, state packets, events, and snapshots make
  ownership and recovery explicit.
- **Evidence-backed completion** — repository tests, scope checks, state packets, audits,
  and artifact hashes determine whether work advances.
- **Structured recovery** — failures route to retry, amend scope, escalate, infrastructure
  recovery, or parking instead of restarting the whole project blindly.
- **Context continuity** — findings, attempt archives, context packets, and role-keyed
  sessions preserve useful knowledge across retries without collapsing reviewer independence.
- **Provider flexibility** — supported local coding-agent CLIs can participate behind the
  same runner contract; provider choice does not change what counts as evidence.

## How it works

### Three orchestration tiers

| Tier | Responsibility |
| --- | --- |
| **L0 origin** | The single control loop. Imports plans, recovers interrupted work, integrates accepted branches, dispatches ready tasks, and snapshots project state. |
| **L1 planners** | One planner per DAG node or project area. Converts a larger objective into bounded L2 task proposals. |
| **L2 workers** | Execute one task in an isolated worktree, produce code and evidence, and enter the gate/audit/recovery pipeline. |

A typical path looks like this:

```text
source objective
  ↓
L1 planner
  ↓
plan critic
  ↓
L2 worker in an isolated worktree
  ↓
repository gate
  ↓
independent auditor
  ↓
decider / recovery policy
  ↓
controlled integration
```

### The reconcile cycle

Each `singular reconcile --actuate` performs one control cycle:

1. **Import** staged L1 task proposals.
2. **Recover** stale or interrupted leases and detached runs.
3. **Integrate** accepted worker branches under the Git-operation lock.
4. **Dispatch** ready frontier tasks within concurrency and resource limits.
5. **Snapshot** the resulting project state.

Detached dispatch is enabled by default. Long-running workers execute in their own process
sessions while the origin loop remains responsive to new plans, integrations, recovery,
status updates, and cooperative STOP.

### Leases and state packets

Every in-flight task holds a durable lease recording ownership, retry state, and expiry.
A completed worker produces a state packet describing:

- files it owned and changed;
- commands it ran;
- tests and their outcomes;
- evidence artifacts and references;
- the resulting branch and task state.

The packet is not accepted merely because the agent emitted valid JSON. The host verifies
scope, artifacts, repository state, and configured gates before the work can advance.

### Gates, audits, and decisions

After implementation, Singular runs the consumer repository's configured gate command.
A simple command is sufficient: exit `0` passes and non-zero fails. Repositories may also
write a structured gate observation through `SINGULAR_GATE_REPORT_FILE` to identify stable
failure signatures or distinguish product defects from infrastructure failures.

The auditor evaluates the implementation and its evidence. The decider then maps the
failure class and remaining retry budget to a recovery action. Clear cases use deterministic
host policy before Singular spends another model round-trip.

This keeps three separate questions separate:

1. Did the agent finish running?
2. Did the repository checks pass?
3. Is the result sufficiently evidenced and safe to integrate?

## Autonomy without surrendering control

Singular exposes autonomy at several scopes:

```bash
singular drive TASK-0001           # drive one task through implementation and audit
singular reconcile --actuate       # perform one control cycle
singular auto                      # run the bounded autonomy loop
singular reconcile --drain         # wait for detached workers to finish
```

The autonomy loop is bounded by operator configuration such as wall-clock budget,
concurrency, retry limits, provider backoff, gate timeout, disk reserve, and human gates.
`singular setup` leaves a repository in a verified **STOPPED** state; setup never actuates
work implicitly.

Human approvals can be bound to exact owners and artifact hashes:

```bash
singular human-gate request --help
singular human-gate approve --help
singular human-gate status --help
```

## Recovery and context continuity

Retries should not mean "send the same prompt again and hope." Singular carries forward
verified state through:

- hash-stamped implementer and reviewer context capsules;
- an open/resolved findings ledger;
- structured fix prompts built from authoritative findings;
- re-audit delta prompts with per-finding verification targets;
- immutable attempt archives;
- planner context packets and assumption records;
- role-keyed session metadata and explicit routing decisions.

Context routing can select `continue`, `resume`, `fork`, `fresh`, or `rehydrate` and records
why the strategy was chosen.

Two invariants remain fixed:

> **Evidence invariance:** continuity strategy never changes what counts as proof. Gates,
> red/green evidence, scope checks, and audit requirements remain the same.

> **Advocate / skeptic separation:** sessions do not cross between planner/implementer
> roles and critic/auditor roles. A model does not gain reviewer independence by reviewing
> its own resumed implementation session.

## Provider support

Provider support is a useful execution capability, not the organizing principle of
Singular. The orchestration, evidence, recovery, and integration contracts remain host-side
regardless of which runner performs a role.

Singular includes adapters for the local CLIs of **Claude Code, Codex, Grok, Gemini,
OpenCode, and Cursor**. A repository selects a default runner, and provider-specific model,
reasoning, effort, timeout, and sandbox controls are available where supported.

The Providers surface reports locally provable status such as CLI installation/version,
authentication or account information exposed by the CLI, configured model, selected
default runner, recent usage, and quota data when a safe headless source exists. Singular
does not proxy credentials, resell access, or combine provider billing.

### Current split-provider routing

Version 0.19.0 includes one proven opt-in split: `grok-implementer` routes L2 implementation
to Grok while the selected default runner continues to handle planning, criticism, audit,
decisions, integration, supervision, and assistant work.

```json
{
  "runner": "codex-run.sh",
  "modules": ["grok-implementer"],
  "env": {
    "SINGULAR_CODEX_PLANNER_REASONING_EFFORT": "high",
    "SINGULAR_CODEX_AUDITOR_REASONING_EFFORT": "high",
    "SINGULAR_GROK_L2_MODEL": "grok-4.6"
  }
}
```

This is intentionally narrower than an arbitrary provider-per-role matrix. Generic
role-level provider assignment is a natural extension of the runner seam, but it is not the
current public configuration contract.

## Install

### Prerequisites

- Bash 4 or newer;
- `python3` and `git`;
- at least one supported coding-agent CLI on `PATH`.

macOS users may need a newer Bash:

```bash
brew install bash
export SINGULAR_BASH_BIN=/opt/homebrew/bin/bash
```

Install Singular:

```bash
git clone https://github.com/alex-reysa/singular-lite /path/to/singular-lite
cd /path/to/singular-lite
bash install.sh

export PATH="$HOME/.singular/bin:$PATH"
```

The installer keeps versioned engine copies under `~/.singular/versions/` and exposes the
launcher through `~/.singular/bin/singular`.

## Start a consumer repository

Inside the repository Singular should control:

```bash
singular setup
```

`singular setup` is the idempotent path from an ordinary repository to a verified,
**STOPPED** Singular repository. It resolves the engine pin, scaffolds configuration,
checks schema and gate state, runs doctor, and can record a supervised regression run.
Prerequisite failures occur before actuation.

Useful variants:

```bash
singular setup --no-test
singular setup --test-async
singular setup --json
```

Each consumer pins its engine in `.singular-version`. Change that pin explicitly:

```bash
singular update <version>
```

## Configuration

Per-repository variation belongs in:

- `singular.config.json` — declarative configuration;
- `singular.config.sh` — optional computed shell configuration;
- `.singular-state/config.local.sh` — gitignored operator overrides and secrets.

Important `singular.config.json` fields include:

- `targetBranch`, `gateCommand`, `runner`, `areas`, and `areaPrefix`;
- `modules`, `promoter`, `identity`, and `controlState`;
- `worktreeCopyPaths`, `bootstrap`, `provisionFiles`, and `envAllowlist`;
- `capabilities`, `capabilityProfiles`, and `roleProfiles`;
- `evidence`, `resources`, and `legacyCompatibility`.

The starter config deliberately sets `gateCommand` to `false`. A newly scaffolded repo
fails closed until you replace it with the command that proves the repository is healthy.

### Worktree environment

`worktreeCopyPaths` copies dependency trees into worker, auditor, and deterministic
acceptance worktrees through the same preparation path. `node_modules` is included by
default; monorepos can add nested stores.

`provisionFiles` copies explicitly declared, gitignored local files into worktrees.
`envAllowlist` exposes only approved environment names or prefixes. Missing required files,
unsafe targets, or undeclared environment access fail closed.

### Promoters and DAG gates

`promoter` names the script that decides when a DAG node's gate may advance. A bare name
resolves under `singular-ext/`; a path is resolved relative to the consumer repo.
`singular doctor` reports graphs that cannot advance under their current promoter and
authority configuration.

Validate a gate result and report all detectable contract violations:

```bash
singular gate validate docs/orchestration/gates/<node>.gate-result.json
```

## Operations and diagnostics

```bash
singular doctor
singular doctor --json
singular report
singular ask "What is blocking this plan?" --wait
singular test --status
singular test --wait
```

`doctor` checks the machine, repository, selected engine, runner contracts, process cleanup,
provider readiness, graph configuration, and required capabilities before unattended work.
The supervisor commands are read-only and propose-only: they can explain state and suggest
settings, but do not silently mutate the repository.

## Modules

The generic `engine/` remains project-agnostic. Consumer-specific behavior belongs in
opt-in modules under `singular-ext/` or in the consumer repository.

```text
singular-ext/
  grok-implementer.sh   # optional split-provider L2 routing
  storage-proof.sh      # example durable-storage proof regime
  promote-gate.sh       # example gate promoter
```

Modules load only when listed in `singular.config.json` → `modules[]`.

## Versioning and schemas

Two versions move independently:

- `.singular-version` pins the engine used by a consumer repository;
- `schemaVersion` records the repository's orchestration data contract.

`singular doctor` reports mismatches. `singular migrate` executes the shipped migration
chain; it does not silently reinterpret incompatible state.

## Development and tests

```bash
bash tests/run.sh      # full regression suite (190+ tests)
singular test         # supervised, durable test run
```

Most engine tests require a real Git checkout because they build disposable worktrees.
Installed engine snapshots intentionally do not ship the full development test tree.

Before contributing, keep the generic engine free of project-specific rules and do not
commit generated `.singular-state/`, `.worktrees/`, `.singular-evidence/`, local secrets,
or run artifacts.

## Security

Singular executes repository-configured shell commands and launches local coding agents in
Git worktrees. Review `singular.config.json`, optional modules, task files, provisioned
files, and allowed environment access before running an untrusted repository.

Report vulnerabilities through GitHub's private vulnerability reporting. If that is not
available, open a minimal public issue requesting a private channel and do not include
exploit details.

## License

Licensed under GPL-3.0 — see [LICENSE](LICENSE).
