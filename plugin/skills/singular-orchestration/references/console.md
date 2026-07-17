# Orchestration console — monitoring UI, JSON API, snapshot modes

A local web console over Singular's durable state. Since 0.7.0 it is a
full-bleed workspace (slim 44px header, no dock) with four surfaces:

- **Home** (default) — system at a glance: health verdict + attention feed
  (STOP, breaker, planner backoff, stale L1 leases, disk, stale loop
  pidfile), per-stage gate progress, live event feed, 14-day activity
  sparkline, throughput tiles, quick links.
- **Plan** — a workbench over the orchestration DAG with four lenses:
  Timeline (real execution Gantt: per-task attempt bars on compressed real
  time, gate diamonds, L0 cycle strip, retry chains; labels are
  collision-placed and never overlap), Matrix (N×N dependency matrix,
  cell size adapts to the pane width, gate-status diagonal, acyclicity
  proof), DAG (layered stage graph with collapse + hover tracing), and
  Tasks (the sortable task table + the status quick-filters). A right-hand
  aside drills into the selected DAG node; the bottom-sheet inspector owns
  full task detail.
- **Consoles** — a live operations room: the L0 supervisor as a persistent
  left pane (semantic events + raw supervisor log), and a dynamic region
  where labeled agent consoles (role · task/area · phase · model) pop in as
  the system spawns planners/workers/auditors and linger→collapse into a
  recent rail when they finish. Finished sessions reopen with full parsed
  scrollback; a prompt chip opens the exact rendered prompt of the run.
- **Agents** — a role card grid (avatar, live glyph, current work, model ·
  effort) with per-role detail: processes (jump to their console), the
  role's prompt template, and **editable settings** (see below).

**Write scope (0.7.0):** the console's only write path is
`POST /api/settings`, which edits whitelisted `GLUERUN_*` knobs in
`gluerun.config.json` `env{}` (atomic; secrets and unknown keys untouched).
Most changes apply on the next loop cycle; `GLUERUN_SLEEP`/`GLUERUN_MAX_HOURS`
need a loop restart (the UI labels each). Orchestration state — tasks,
leases, gates, STOP, worktrees — remains read-only from the console.
Developer primitives: `{}` view-source buttons open the raw durable file
behind any entity in the inspector.

## Start it

Preferred — idempotent (0.5.0): reuse a live console or start one detached,
then print the URL:

```bash
gluerun console --ensure     # prints http://127.0.0.1:<port>; safe to re-run
gluerun console --status     # running/not-running (exit 0/1); --json available
gluerun console --stop       # terminate and clean up
```

While serving, the URL and pid persist at `.gluerun-state/console.url` /
`console.pid` (removed on exit), and `gluerun status` prints the live URL.
The default port is **8765** (free-port fallback; pin with
`GLUERUN_CONSOLE_PORT`). Foreground mode is still `gluerun console` — its
banner goes to **stderr**, so one-shot JSON modes are pipe-pure. If you must
run the server directly, use the installed engine's copy (never a source
checkout — respect the version pin):

```bash
python3 ~/.gluerun/current/plugin/scripts/gluerun_graph_server.py \
  --repo /path/to/repo --host 127.0.0.1 --port 8765
```

The page auto-refreshes every 10 seconds without losing selection, pin,
filters, or lane expansion. Deep links (0.6.0 grammar
`#<surface>/<lens>/<selection>[:tab]`): `#plan/timeline`, `#plan/matrix`,
`#plan/dag/NODE:<node-id>`, `#plan/tasks/TASK-0309:work`,
`#consoles/<session-id>` (pins + solos that console), `#agents/<role-id>`.
Legacy hashes (`#TASK-0309[:tab]`, `#NODE:<id>`, `#L1:<area>`, `#PLAN`,
`?list=1`) are migrated automatically.

## One-shot modes (no browser)

`gluerun console` forwards extra flags to the server, and every one-shot
flag prints JSON and exits without binding a port:

```bash
gluerun console --snapshot            # full health snapshot (same shape as /api/state)
gluerun console --task TASK-0309      # one task's detail
gluerun console --overview            # plan overview (DAG stages/nodes + gate status)
gluerun console --node <node-id>      # one DAG node's provenance
gluerun console --area <area>         # all DAG nodes for one area
gluerun console --sessions            # live session inventory
gluerun console --session <run-id>    # one session's terminal lines
gluerun console --events              # live event overlay
gluerun console --dag                 # full DAG view: nodes+gates+task rollups+edges (0.6.0)
gluerun console --timeline            # execution timeline: task intervals+gates+cycles (0.6.0)
gluerun console --config              # resolved per-role model/effort + limits (0.6.0)
gluerun console --home                # at-a-glance digest: health+attention+activity (0.7.0)
gluerun console --prompts             # role prompt library listing (0.7.0)
gluerun console --prompt <name>.md    # one prompt template's content (0.7.0)
gluerun console --raw <root>/<name>   # raw durable file behind an entity (0.7.0)
```

Use these to summarize orchestration health or inspect one task from a
terminal-only context.

## Read-only rules

The console (and any agent using it for monitoring) observes; it never
steers. The single exception since 0.7.0 is the settings write path above
(whitelisted config env{} knobs). Everything else:

- Treat Singular durable state as authoritative.
- Do not mutate the repo, `.gluerun-state`, worktrees, leases, tasks,
  packets, gates, or branches from the console context.
- Do not remove `.gluerun-state/STOP` or resume L0 as a side effect of
  "refreshing" — stopping/resuming is an operator action (see SKILL.md §3).
- "Deployed/active" is derived from durable facts only: live pid/process,
  active origin lock, non-terminal lease, existing worktree, recent dispatch
  events, run metadata. Accepted markdown alone never reads as active.
  Lease-file existence is not activity. `origin-state.extraWorktrees` is
  surfaced as a divergence note when it disagrees with disk, never rendered
  as agents.
- Completion authority is `docs/orchestration/gates/*.gate-result.json`,
  not markdown area dashboards.
- Storage-proof validity stays delegated to `dag.sh`/gate-result validation;
  the console exposes command-log evidence refs and exit codes (including
  `*-skip-guard-red` logs) but never independently rules a proof valid.

## What it reads

- `docs/orchestration/tasks/*.md`, `docs/orchestration/areas/*/state.md`,
  `docs/orchestration/gates/*.gate-result.json`
- `.gluerun-state/origin-state.json`, `.gluerun-state/events.ndjson`,
  `.gluerun-state/autonomate.out.log`, `.gluerun-state/leases/*.json`,
  `.gluerun-state/l1-leases/*.json`, `.gluerun-state/inbox/*.json`
  (state packets), `.gluerun-state/runs/*` (run/audit artifacts)
- `.worktrees/`

## L1 parallelism surfacing

When the L1 fanout runs (`GLUERUN_ENABLE_L1_PARALLEL=1`), the console shows
it from durable facts only: the plural DAG frontier marks every ready node
with the coral ◆ (not just the first); the top-bar frontier pill reads
`N ready · M` (M = live planners); an area with an *active*
`.gluerun-state/l1-leases/<node>.json` (status `proposed|planning|active`)
gets a blue **L1** badge and an **L1-lease** inspector tab
(node/status/runId/baseSha/scopes). A `released`/`failed` lease is history —
never a live agent, never "complete"; gate-result.v0 remains the sole
completion authority.

Skills/roles are surfaced two ways (Singular stores no literal skill
registry): the L0 inspector `roles` tab shows the declared role catalog, and
each task's `work` tab shows the roles that touched it and the
commands/tools they actually ran.

## JSON API (all GET, read-only)

```text
/                       → console UI
/assets/**              → client modules (extension-allowlisted: .css/.js/.mjs/.svg)
/api/state              → full orchestration snapshot (?fresh=1 forces a blocking
                          recompute; otherwise a stale snapshot is served instantly
                          with stale/computing/snapshotAgeSeconds set while a
                          background refresh runs — 0.5.0)
/api/task/TASK-0309     → full task detail (objective, scope, acceptance, required
                          evidence, lease, run id, worktree path + existence, packets,
                          integration audit, gate refs, task-scoped events, gate
                          command-log evidence summaries, agentsInvolved, toolsUsed)
/api/roles              → declared role/skill catalog (static, cached)
/api/health             → liveness
/api/overview           → plan overview (DAG stages/nodes with gate status)
/api/node/<node-id>     → single DAG node detail (requiredCompletion, gate result,
                          tasks attributed to the node)
/api/area/<area>/nodes  → all DAG nodes for one area
/api/events?cursor=N    → paged reader over .gluerun-state/events.ndjson
                          (returns a next cursor; poll-friendly)
/api/sessions?limit=N   → runtime session inventory (planner/worker/auditor rows
                          incl. durable model/effort/exitCode session-meta;
                          default 16, max 40; origin always included)
/api/session/<id>       → paged session transcript reader
                          (?cursor=N&limit=N&file=<name>&raw=1)
/api/dag                → full DAG view (0.6.0): nodes merged with gate results,
                          per-node task rollups, L1 leases, frontier flags,
                          edges[], stage/area swimlane metadata
/api/timeline?since=T   → execution history (0.6.0): per-task attempt intervals
                          (reconstructed from events; liveNow for running bars),
                          gate marks, L0 reconcile cycle spans
/api/config             → resolved per-role model/effort with env-key provenance
                          + limits/flags (0.6.0; .env > config env{} > defaults)
/api/home               → at-a-glance digest (0.7.0): health, attention[],
                          gates, frontier, taskCounts, dispatch/autonomate
                          liveness, breaker/backoff, 14-day activityByDay
/api/settings           → GET: all knob rows (config env{} overlaid) + appliesAt;
                          POST {"changes":{KEY:value}} writes whitelisted keys
                          into gluerun.config.json env{} (the console's ONLY
                          write path; ""-value deletes a key)
/api/prompts            → role prompt library listing (0.7.0)
/api/prompt/<name>      → one prompt template's content
/api/raw/<root>/<name>  → raw durable file (roots: task, gate, gate-review,
                          lease, l1-lease, dispatch, inbox, state, config, dag)
```

Snapshot extras: `orchestration.gates` `{passed,total,byNode}` (replaces the
legacy `gateD0`/`gateD1` probes; the built-in status/frontier/validate probes
are native file reads since 0.5.0 — no `make orch-*` subprocesses unless a
console adapter explicitly configures commands), `orchestration.nextAreas`
(plural frontier
`{frontier:[{node,area,...}],allComplete?}`), top-level `l1Leases[]` (each
with an `active` flag), `agents` block (`l0`, `l1[]` with
`l1Active`+`l1Lease`, notable non-terminal `l2[]`), a derived `state` on
every task/area, and `summary` with `stateCounts`, `l1PlannersActive`,
`frontierCount`.

For scripted monitoring, `/api/events?cursor=N` + `/api/state` is the stable
poll pair; the `--snapshot` mode emits the same snapshot JSON without a
server.
