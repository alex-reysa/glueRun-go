# Orchestration console — monitoring UI, JSON API, snapshot modes

A read-only local web console over Singular's durable state: a top
status/control bar, a main L0 → L1 → L2 node-edge graph (nodes carry deployed
agent state) with a list view, and an inspector drawer for drilling into a
single task. The graph pans/zooms; click a node to inspect it; dependency
edges highlight on selection.

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
filters, lane expansion, or graph pan/zoom. Deep links: `#TASK-0309` opens a
task in the inspector, `#TASK-0309:work` (or `#L0:roles`) opens a specific
inspector tab, and `?view=graph|list` selects the main view.

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
```

Use these to summarize orchestration health or inspect one task from a
terminal-only context.

## Read-only rules

The console (and any agent using it for monitoring) observes; it never
steers:

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
it from durable facts only: the plural DAG frontier marks every ready node's
area with the violet ◆ (not just the first); the top-bar frontier pill reads
`N ready · M` (M = live planners); an area with an *active*
`.gluerun-state/l1-leases/<node>.json` (status `proposed|planning|active`)
gets a cobalt **L1** badge + ring and an **L1-lease** inspector tab
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
/assets/styles.css      → stylesheet
/assets/app.js          → client
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
/api/sessions           → runtime session inventory (planner/worker session-meta
                          discovered from durable records; cached)
/api/session/<id>       → paged session transcript reader
                          (?cursor=N&limit=N&file=<name>&raw=1)
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
