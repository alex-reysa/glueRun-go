---
name: gluerun-orchestration-graph
description: Open or refresh a read-only glueRun-go orchestration console showing L0 origin, L1 areas, L2 tasks and deployed sub-agents, STOP state, DAG frontier, gates, drift, events, and disk pressure. Use when the user asks to see what glueRun-go agents are doing, asks for an L0/L1/L2 graph, wants to inspect a task, or wants glueRun-go orchestration visibility in Codex.
---

# glueRun-go orchestration console

Use this skill to show glueRun-go orchestration state as a local browser console — a
top status/control bar, a main L0 → L1 → L2 node-edge graph (the graph is the agent
map: nodes carry deployed L0/L1/L2 state) with a list view, and a bottom inspector
drawer for drilling into a single task. The graph pans/zooms; click a node to inspect
it; dependency edges highlight on selection.

## Rules

- Treat glueRun-go durable state as authoritative.
- Do not mutate the repo, `.gluerun-state`, worktrees, leases, tasks, packets, gates, or branches.
- Do not remove `.gluerun-state/STOP` or resume L0.
- "Deployed/active" is derived from durable facts only (live pid/process, active
  origin lock, non-terminal lease, existing worktree, recent dispatch events, run
  metadata). Accepted markdown alone never reads as active. Lease-file existence
  is not activity. `origin-state.extraWorktrees` is surfaced as a divergence note
  when it disagrees with what is on disk, never rendered as agents.
- Read from:
  - `docs/orchestration/tasks/*.md`
  - `docs/orchestration/areas/*/state.md`
  - `docs/orchestration/gates/*.gate-result.json`
  - `.gluerun-state/origin-state.json`
  - `.gluerun-state/events.ndjson`
  - `.gluerun-state/autonomate.out.log`
  - `.gluerun-state/leases/*.json`
  - `.gluerun-state/inbox/*.json` (state packets) and `.gluerun-state/runs/*` (run/audit artifacts)
  - `.worktrees/`
- Completion authority comes from `docs/orchestration/gates/*.gate-result.json`, not Markdown area dashboards.
- Storage-proof completion remains delegated to `dag.sh`/gate-result validation.
  The console should expose command-log evidence refs and exit codes, including
  marked `*-skip-guard-red` logs, but must not independently decide whether a
  storage proof is valid.

## Layout

The plugin is a zero-dependency Python HTTP server that serves a static asset
triad opened in the Codex Browser panel:

- `assets/index.html` — shell + custom 16px icon sprite
- `assets/styles.css` — app-shell design system (warm off-white + dotted grid, glass panels, six-tone signal language)
- `assets/app.js` — client logic (views, filters, search, pin, inspector, auto-refresh)
- `scripts/gluerun_graph_server.py` — read-only snapshot + JSON API

## Start the console

From the glueRun-go repo root, run:

```bash
python3 "${PLUGIN_ROOT}/scripts/gluerun_graph_server.py" \
  --repo "/path/to/your/repo" \
  --host 127.0.0.1 \
  --port 8765
```

If port `8765` is already in use, use the next free local port.

Open the console in the Codex Browser panel:

```text
http://127.0.0.1:8765
```

The page auto-refreshes every 10 seconds without losing the current selection,
pin, filters, lane expansion, or graph pan/zoom. Deep links are supported:
`#TASK-0309` opens a task in the inspector, `#TASK-0309:work` (or `#L0:roles`)
opens a specific inspector tab, and `?view=graph|list` selects the main view.

Skills are surfaced two ways (glueRun-go stores no literal skill registry): the L0
inspector `roles` tab shows the declared role/skill catalog (from the operating
model), and each task's `work` tab shows the roles that touched it and the
commands/tools they actually ran.

L1 parallelism (when the opt-in fanout runs) is surfaced from durable facts only:
the **plural DAG frontier** marks every ready node's area with the violet ◆ (not
just the first), the top-bar frontier pill reads `N ready · M` (M = live planners),
and an area with a live L1 planner — an *active* `.gluerun-state/l1-leases/<node>.json`
(status `proposed|planning|active`) — gets a cobalt **L1** badge + ring and an
**L1-lease** inspector tab (node/status/runId/baseSha/scopes). A `released`/`failed`
lease is history, never a live agent, and never "complete" — gate-result.v0 remains
the sole completion authority. Lease-file existence alone is not activity.

## API

```text
GET /                      → console UI (assets/index.html)
GET /assets/styles.css     → stylesheet
GET /assets/app.js         → client
GET /api/state             → full orchestration snapshot (add ?fresh=1 to bypass the ~6s cache)
GET /api/task/TASK-0309    → full read-only task detail (objective, scope, acceptance,
                             required evidence, lease, run id, worktree path + existence,
                             packets, integration audit, gate refs, task-scoped events,
                             gate command-log evidence summaries,
                             plus agentsInvolved + toolsUsed observed for the run)
GET /api/roles             → declared role/skill catalog (static reference, cached)
GET /api/health            → liveness
GET /api/overview          → plan overview (DAG stages/nodes with gate status)
GET /api/node/<node-id>    → single DAG node detail (requiredCompletion, gate
                             result, tasks attributed to the node)
GET /api/area/<area>/nodes → all DAG nodes for one area
GET /api/events?cursor=N   → paged event-log reader over .gluerun-state/events.ndjson
                             (returns a next cursor; poll-friendly)
GET /api/sessions          → runtime session inventory (cached; planner/worker
                             session-meta discovered from durable records)
GET /api/session/<id>      → paged session transcript reader
                             (?cursor=N&limit=N&file=<name>&raw=1)
```

The snapshot also carries L1-parallelism facts (read-only): `orchestration.nextAreas`
(plural frontier `{frontier:[{node,area,...}],allComplete?}`), top-level `l1Leases[]`
(every `.gluerun-state/l1-leases/<node>.json` with an `active` flag), `agents.l1[]`
gains `l1Active`+`l1Lease`, and `summary` gains `l1PlannersActive`+`frontierCount`.

The snapshot adds an `agents` block (`l0`, `l1[]`, and notable non-terminal `l2[]`),
a derived `state` on every task/area, and `summary.stateCounts`.

## Snapshot / task modes (no server)

For non-server read-only checks:

```bash
python3 "${PLUGIN_ROOT}/scripts/gluerun_graph_server.py" --repo "/path/to/your/repo" --snapshot
python3 "${PLUGIN_ROOT}/scripts/gluerun_graph_server.py" --repo "/path/to/your/repo" --task TASK-0309
```

Use these to summarize health or inspect one task without opening a browser.
