# Changelog

All notable changes to **glueRun-go** are recorded here. This project follows
semantic versioning. The `schemaVersion` (the `.vN` contract of the JSON schemas +
config shape) is called out separately from the package version, because consumers
and the plugin negotiate on `schemaVersion`.

---

## [0.11.1] — 2026-07-19 — Thread sub-menu; home flicker fix

- **IA**: the header surface-tab row is gone — Home / Plan / Consoles / Agents
  are now a vertical sub-menu nested under the ACTIVE thread in the sidebar
  (tree rail, 31px rows, existing-sprite icons, icon-only in rail mode; the
  consoles live badge rides along). Breadcrumb extends to
  `repo › thread › Surface`.
- **fix**: Home no longer flickers — dag/sessions events fed a signature
  bypass that rebuilt the page every ~2s and replayed the `arrive` entrance;
  live-session fields now fold into the signature, `arrive` plays only on
  route entry, chat bubbles animate only on first paint (CDP-verified: 10
  identical rebuilds per 20s → 0).
- **fix**: console answers HEAD probes for `/` and `/api/health` (was 501).

Suites: bash 157, python 206.

## [0.11.0] — 2026-07-19 — Quiet Instrument: console design-language overhaul

Visual/IA polish pass adopting the Singular "Quiet Instrument" design system
(normative spec: layered warm near-whites, hairline structure, ≤5% semantic
color, honest states). No engine behavior changes; one additive API field.

### Shell
- Full-height chrome rail (`#f7f6f3`) with the brand block moved into the
  sidebar; stage header gains a `repo › thread` breadcrumb; surface tabs
  restyled as a segmented control (white raised active pill).
- New persistent 32px **status dock** spanning the full width: loop cell
  (running / engine busy / stopped), active·ready tasks, gates, attention
  ("N needs you", ochre when nonzero), breaker (only when tripped), codex
  quota (hidden when unavailable), repo·branch, conn + updated age.
  Historical mode swaps the left cluster for "viewing archived plan" +
  back-to-live.
- Tokens reconciled to the Quiet Instrument palette with every legacy alias
  preserved (`--surface-*`, `--border-*`, `--tone-*`, `--n-*` remapped);
  coral retires → lavender (special/evaluation). Global `:focus-visible`
  ring, `::selection`, tabular numerals, `arrive`/`calm-pulse` keyframes,
  reduced-motion killswitch.

### Surfaces
- Home: card grammar (paper, hairline, radius 14–16, 42px headers, dashed
  action footers), calm sage "All clear" walk-away state, supervisor chat
  re-patterned to the AI-thread archetype (dark right-aligned user block,
  open-prose assistant with ink glyph + quiet provenance row), composer as a
  white radius-16 card with circular ink send, 3px steel quota/gauge tracks.
- Providers: interactive paper cards (hover border+shadow), 7px status dots
  with explicit words, tone-pair chips, lavender DEFAULT RUNNER badge.
- Consoles: the one routine dark surface formalized — `--term-*` island
  tokens, `#27272a` pane title bars with traffic dots, mint streaming cursor;
  recent rail as nav rows; light chrome around it.
- Plan: dotted-grid DAG canvas with running-node ring, lens nav rows +
  eyebrow, 36px muted table headers, filter-chip/quickfilter recipes,
  matrix Follow-diagonal adopts the shared button recipes.
- Agents: card grammar, 34px inputs, segmented toggles, tone-pair chips.

### Fixes
- Snapshot payload gains additive `loop: {pid, alive}` (autonomate pidfile +
  signal-0) so the dock never reads test-suite processes as the loop
  "running" (agents.l0.state counts processes; the dock now labels that
  state "engine busy").
- Terminal-island + shared grays tokenized (mechanical sweep; opencode k3
  was attempted twice and produced no edits — applied deterministically).

Suites: bash 157 (+ DOM shell test), python 203.

## [0.10.0] — 2026-07-18 — App shell (threads sidebar), matrix rebuild, provider quotas, supervisor briefing + chat

Four requests in one release, moving the console from viewer toward platform:
a two-level app shell (plan threads in a left sidebar, surfaces become
thread-scoped tabs), a rebuilt dependency matrix, subscription-quota gauges on
Home, and a supervisor presence — a periodic read-only briefing plus a
propose-only chat. `schemaVersion` stays **v1**; every engine addition is
byte-inert until its knob is set (a no-config reconcile cycle creates zero
supervisor artifacts).

### Console — app shell (left sidebar + plan threads)
- The four surfaces become **thread-scoped tabs** behind the slim header
  (Home, Plan, Consoles, Agents); a new **left sidebar** holds the plan-
  threads list (the live plan, highlighted, plus archived read-only threads —
  name · date · gates P/T) and an **app-level nav** into which **Providers
  moves out of the tab row**. Clicking an archived thread reloads into
  `?plan=` historical mode; "Current plan" returns to live.
- The rail collapses (persisted in localStorage; auto-rail under 1100px), and
  both navs drive `showSurface` with mirrored `aria-pressed`. The old header
  plan-switcher `<select>` is gone. Zero route/server changes — all asset
  hashes for the untouched modules are unaffected.

### Console — dependency matrix rebuilt
- **Sticky** column headers, row labels, and the top-left corner stay pinned
  (opaque) while scrolling. Row labels are now **readable two lines** (title
  over id) instead of the mono id bleeding under the title — fixes the
  id-overlap bug on names like `metrics-extract`.
- **Height-aware fit:** cell size is the min of the width- and height-fit
  (clamped 22–44px); when the grid fits an axis it centers on it.
- **Follow-diagonal scrolling** (toggle, persisted, default on): scrolling
  right walks the matrix down in lockstep so the gate-status diagonal stays in
  view; the y-axis stays free and the toolbar toggle decouples the axes. The
  floating detail card now stays in the pane corner instead of scrolling
  offscreen when the grid is taller than the pane.

### Engine + Console — supervisor briefing & ask
- New engine `engine/supervise.sh` (`--once`) and `engine/ask.sh` run a
  **read-only one-shot runner** over a state digest (STATUS.md, health,
  frontier, gates, recent events, config env{}, settings whitelist).
  `gluerun report` requests a briefing; `gluerun ask "<question>" [--wait]`
  asks the supervisor a question. Both are **propose-only** — the model never
  writes; it may only emit a `proposedSettings` map restricted to the settings
  whitelist.
- Briefings are validated against
  `schemas/supervisor-report.v0.schema.json`
  (`gluerun.orchestration.supervisor-report.v0`) and written to
  `.gluerun-state/supervisor/latest.json` (+ pruned history); events
  `supervisor.report` / `.failed` / `.ask_started` / `.ask_answered` /
  `.ask_failed`. New knobs, all inert by default:
  `GLUERUN_SUPERVISOR_INTERVAL_MIN` (`0` = off; the L0 loop then auto-briefs at
  most once per interval, stamping before spawn so it cannot double-spawn),
  `GLUERUN_SUPERVISOR_TIMEOUT_SEC` (900), `GLUERUN_ASK_TIMEOUT_SEC` (600).
- Console: `POST /api/report` and `POST /api/ask` spawn the readonly runner
  (a second deliberate subprocess exception — the question is written to a
  file, never passed on argv; `start_new_session`; 429 while busy or inside
  the 60s report throttle); `GET /api/ask/<id>` and `GET /api/asks` read state
  pure-FS. `/api/home` gains `loop` (iteration/note from STATUS.md),
  `briefing` (latest report, narrative capped), and `supervisor`
  (`{intervalMin, enabled}`). Home renders a supervisor card (stage, loop
  note, briefing narrative + risks + next steps, refresh) and a propose-only
  chat with per-key **Apply chips** — a human click is the only write, through
  POST /api/settings. Ask/briefing runs stream in Consoles as `assistant`-kind
  sessions.

### Console — provider subscription quotas
- `/api/providers` gains an additive **`quota`** field (`gluerun.providers.v0`
  is unchanged otherwise). Codex exposes real usage: a bounded tail probe over
  its newest local rollout JSONL reads the last `rate_limits` (used-percent,
  window, reset time, plan type) — **rollout files only, never a credential**.
  Cursor reports tier-only; providers with no headless usage source report
  `not-exposed`; absent CLIs `cli-missing`.
- Home (above the links) and each Providers card render a **usage gauge** for
  Codex (percent used, window label, reset countdown, plan chip, staleness)
  and honest tier / not-exposed states for the rest; the section quiet-hides
  when nothing qualifies or `/api/providers` 404s. Live-only.

### Fixes
- Regenerated the engine console adapter
  (`plugin/adapters/console-adapter.v0.json`): its `logFileMaps.codexLogs` had
  drifted and, when loaded, stripped `auditor-codex.log` from the streamable
  set — restored, and the new `assistant-codex.log` / `supervisor-codex.log`
  names added, so adapter-loaded and adapter-less session streaming match.
- `test-autonomate-supervisor-gate.sh`'s cleanup trap no longer flakes on
  "Directory not empty" when the detached briefing tree is still writing under
  the fixture at exit (retry-tolerant `rm`).

### Tests
- Bash suite gains `test-supervise.sh`, `test-ask.sh`,
  `test-autonomate-supervisor-gate.sh` (stub-runner; byte-inert proof when the
  knob is unset), and `test-console-shell-dom.sh` — headless-Chrome
  `--dump-dom` assertions over the sidebar shell, the four-tab header, and the
  rebuilt matrix (skips cleanly when Chrome is absent).
- Python suite gains `CodexQuotaTests`, `ProvidersQuotaFieldTests`,
  `CollectHomeSupervisorTests`, `CollectAskTests`, `AskReportRouteTests`,
  `SessionsAssistantTests`; the no-subprocess and secret-leak guards are
  extended to the new collectors, and `/api/settings` stays byte-identical.

---

## [0.9.0] — 2026-07-18 — Providers: runtime status tab + Gemini/OpenCode/Cursor runners

See which agent CLIs are connected, at what version, under which account —
and switch the engine between them. Modeled on the multi-CLI provider
patterns of opencode / pi / t3code (probe → installed/version → auth status
→ ready/warning/error rollup with email · plan). `schemaVersion` stays v1.

### Engine — three new runners (six total)
- `engine/gemini-run.sh`, `engine/opencode-run.sh`, `engine/cursor-run.sh`
  join claude/codex/grok as full drop-in runners: same CLI surface, exit
  semantics (127 missing CLI, 124 timeout w/ process-tree kill, 86 resume
  refused, 3/4 parse/error), readonly restore guard, best-effort
  `--session-meta` (provider ids gemini/opencode/cursor; no session
  affinity v1). Headless invocations: `gemini -o json --yolo` (envelope
  accepted from stdout OR stderr — 0.42.x emits it on stderr behind
  warning lines), `opencode run --format json`, `cursor-agent -p
  --output-format json -f` (`--mode ask` for readonly). Flat model knobs
  `GLUERUN_{GEMINI,OPENCODE,CURSOR}_MODEL` (unset = the CLI's own default,
  flag omitted) + `_TIMEOUT_SEC` (default 1200).
- Switch runners with `GLUERUN_RUNNER` in config `env{}` (proven to
  override the top-level `runner` key on every lib.sh source) — the
  console's "Use as default runner" writes exactly that.
- `gluerun doctor` now checks all six provider CLIs on PATH with
  file/env-inference auth hints (warn-only, no subprocess probes) and
  model-prefix sanity for the new keys.

### Console — Providers surface + /api/providers
- New **Providers** tab (5th surface): a status card per provider —
  installed + version, auth line (email · plan when the CLI prints them;
  otherwise a one-line reason plus a copyable login command), env-key
  presence chips, runner script + "default runner" badge + roles using it
  + last-used/exit evidence from session metadata, an editable model knob,
  and a "Use as default runner" action (applies next cycle). Live-only;
  disabled while viewing an archived plan.
- `GET /api/providers` (`gluerun.providers.v0`) + `--providers` one-shot:
  per-provider probes (`claude auth status`, `codex login status`,
  `cursor-agent about --format json`, `opencode auth list`, env/file
  inference for gemini; `<bin> --version` for versions) run in a thread
  pool with 3s timeouts, cached 60s, `?refresh=1` re-probes. The payload
  never contains credential values — only presence, counts, and strings
  the CLIs themselves print. This collector is the deliberate
  subprocess exception (like the git-backed snapshot); everything else
  stays pure-FS.
- Provider identity generalized: the runner→provider mapping is a
  registry lookup (was a hardcoded claude-else-codex guess), and
  `/api/config` + `/api/providers` honor env{} `GLUERUN_RUNNER`.
  POST /api/settings whitelist gains `GLUERUN_RUNNER` (validated
  `*-run.sh` name only) + the new model/timeout keys.

### Tests
- Bash 153/153 (new: test-gemini-run.sh / test-opencode-run.sh /
  test-cursor-run.sh incl. the stderr-envelope quirk case; doctor
  updated). Python 166/166 (new: CollectProvidersTests,
  ProvidersRouteTests — fake-binary PATH fixtures, secret-leak guard,
  cache TTL/refresh, runner-switch round-trip + rejection). Real
  end-to-end runner smokes on this machine: cursor pong/exit 0; gemini
  error-path surfaces the CLI's own auth message; opencode correctly
  reports not-connected. Headless-Chrome UI verification: 80/80
  assertions across real-repo and POST-fixture contexts at 1920×1080
  and 1280×700, zero pageerrors.

---

## [0.8.0] — 2026-07-18 — Plan threads: chat-style sequential plans

One repo no longer means one plan forever. When a DAG completes, archive it
as a browsable thread and start a fresh one — like chats in an LLM app: one
active plan, older plans read-only. `schemaVersion` stays **v1** (all
additions are new verbs/endpoints; archived plans are served from mini-repo
snapshots by the existing collectors).

### Engine — `gluerun plan archive` / `gluerun plan list`
- `gluerun plan archive [--name <display name>] [--force] [--no-commit]`
  moves the finished plan's durable record into
  `.gluerun-state/plans/<plan-id>/` laid out as a **mini-repo**
  (`docs/orchestration/{dag.v0.json,tasks,gates,areas,packets}` moved;
  `prompts/`, `planner-contract.md`, `decisions.md` copied so they stay
  live; `.gluerun-state/{events.ndjson,runs,sessions,leases,l1-leases,
  dispatch,inbox,origin-state.json,STATUS.md,circuit.json,
  planner-backoff.json,task-id-counter}` moved), writes a
  `manifest.json` (`gluerun.plan.manifest.v0`: name, archivedAt,
  engineVersion, branch, headSha, gates passed/total, taskCount, event
  span) and upserts the `plans/index.json` registry
  (`gluerun.plans.index.v0`, newest first).
- Safety: refuses (each override-able only with `--force`) while the
  autonomate loop is alive, the origin lock is held, a launched dispatch
  tree is still running, the DAG frontier is not `allComplete`, or
  `.worktrees/` still has entries (worktrees are never moved — run
  `gluerun gc` first). Runs under the origin lock.
- Reset: after archiving, the repo returns to the init starter DAG
  (`M0.scaffold`), a fresh `events.ndjson` seeded with a `plan.archived`
  event, and a cleared task-id counter (next thread numbers from
  TASK-0001); `docs/orchestration` is committed by default
  (`--no-commit` to skip). Config, secrets, locks, console files and
  `STOP` handling are never touched.
- `gluerun plan list [--json]` prints the registry (self-heals from
  per-plan manifests if the index is missing).

### Console — thread switcher + read-only historical mode
- `GET /api/plans` (`gluerun.plans.v0`) lists archived plans; `--plans`
  one-shot flag added.
- `?plan=<plan-id>` on the read endpoints (`/api/dag`, `/api/timeline`,
  `/api/overview`, `/api/task`, `/api/node`, `/api/area`, `/api/events`,
  `/api/sessions`, `/api/session`, `/api/prompts`, `/api/prompt`,
  `/api/raw`) serves the archived plan's snapshot — ids are validated
  against the registry and path-contained; unknown ids 404. `/api/state`,
  `/api/home`, `/api/config`, `/api/settings` ignore the param, and any
  POST carrying `?plan=` is rejected 400: **archived plans are
  read-only**.
- The compute cache is now multi-slot (LRU, capacity 4) so browsing an
  archived plan doesn't evict the live plan's cached views.
- UI: a plan switcher in the header lists the current plan and archived
  threads (name · date · gates); Home gains a "Previous plans" card.
  Selecting a thread reloads into `?plan=<id>` historical mode: a
  persistent "viewing archived plan — read-only" banner, all four Plan
  lenses + Consoles transcripts rendered from the archive, Agents (live
  settings) disabled, live polling frozen (immutable data is fetched
  once), and pin writes suppressed. "Back to live" returns to the active
  thread.

### Tests
- New `tests/test-plan-archive.sh` (preconditions, archive layout,
  reset, registry ordering, `--no-commit`, list `--json`); bash suite
  150/150.
- New `CollectPlansTests`, `PlanParamRoutingTests` (HTTP-layer:
  archived-vs-live payloads, traversal/malformed-id 404s, POST 400,
  `/api/state` param ignored), `ComputeCacheMultiSlotTests`;
  `collect_plans` added to the no-subprocess guard; python suite
  152/152. Headless-Chrome verification: 76 assertions across live +
  historical modes at 1920×1080 and 1280×700, zero pageerrors.

---

## [0.7.0] — 2026-07-17 — Workspace polish: Home, full-bleed canvas, editable settings, developer primitives

Field feedback on 0.6.0 ("half way there"): the dashboard should feel like a
full canvas per tab, the timeline garbled overlapping labels on dense lanes,
the matrix didn't use wide screens, settings were read-only, and the system
felt like a black box. `schemaVersion` stays **v1**; `POST /api/settings` is
the console's first write path and it only touches `gluerun.config.json`
`env{}` — orchestration state remains read-only.

### Workspace shell
- **Home** is a new landing surface (default route): health verdict +
  attention feed (STOP, breaker, planner backoff, stale L1 leases, disk,
  stale loop pidfile), per-stage gate progress, live event feed, a 14-day
  activity sparkline (dispatches/integrations/failures), throughput tiles,
  and quick links into the other tabs.
- The header slims to a single 44px row (brand, Home·Plan·Consoles·Agents
  nav, health, stop, conn, Refresh); the stat strip and plan pill retire —
  their content lives on Home, and the actionable status filters moved into
  the Plan workbench header. The bottom dock is deleted; every surface is a
  full-bleed workspace with hairline dividers.

### Plan surface fixes
- **Timeline**: per-lane label placement with measured text (inline /
  right-outside only when it fits before the next bar / hidden with hover +
  tooltip) and lanes clip overflow — overlapping garbled labels are gone.
  Real bar widths (6px min, adjacent slivers merged) replace the 18px blob
  floor; retry chips move to row ends; collapsed areas take one 30px row
  with the heat strip inline; sticky day labels; denser rows (20px bars).
- **Matrix**: cell size now derives from the pane width
  (`clamp(22..44px)`), so the grid uses a 16:9 screen instead of rendering
  a fixed 774px square; marks and diagonal pills scale with the cell.

### Agents: editable settings
- Role detail and a new System settings panel (all 23 knobs in 4 groups)
  edit model/effort/concurrency/safety knobs with kind-typed validation and
  per-key "applies next cycle" / "needs loop restart" labels. Saves go
  through **`POST /api/settings`** → atomic write into
  `gluerun.config.json` `env{}` (the layer the engine actually re-reads
  each cycle; `.env` is only read at loop launch). Whitelisted keys only —
  secrets and unknown config keys are never touched; derived knobs render
  read-only. `/api/settings` rows overlay config env{} so saved values are
  visible immediately.

### Developer primitives (no black boxes)
- **Prompts**: `GET /api/prompts` + `/api/prompt/<name>` serve the role
  prompt library (`docs/orchestration/prompts/`); the Agents role detail
  shows each role's template, and Consoles panes/rows carry a prompt chip
  opening the EXACT rendered prompt of that run (rendered `*-prompt.md`
  files now stream through the session reader as `kind:"prompt"`).
- **Raw view-source**: `GET /api/raw/<root>/<name>` (tasks incl.
  superseded, gates + reviews, leases, L1 leases, dispatch records, inbox
  packets, origin-state/circuit/planner-backoff/STATUS, config, DAG) with
  per-root allowlists and containment; quiet `{}` buttons on tasks, nodes,
  Home breaker/backoff, and Agents config open the underlying file in the
  inspector (pretty-printed JSON, path, size, mtime).
- **`GET /api/home`** (`gluerun.codex.home.v0`, `--home`): the at-a-glance
  digest powering Home — first server-side read of dispatch records and
  planner-backoff.json, pid-liveness without subprocesses.

### Migrating from 0.6.0
- No action required. The dock and `#dock` sizing knobs are gone; the event
  feed lives on Home. Bare URLs land on `#home` (all 0.6.0 routes and
  legacy deep links still work). New one-shot flags: `--home`, `--prompts`,
  `--prompt <name>`, `--raw <root>/<name>`.

---

## [0.6.0] — 2026-07-17 — Three-surface console redesign (Plan · Consoles · Agents)

A full information-architecture redesign of the read-only console, replacing
the static L0→L1→L2 column canvas with three purpose-built surfaces, plus the
server/engine data layer to power them. `schemaVersion` stays **v1** — every
API change is additive (three new endpoints, new fields on existing ones);
`gluerun migrate` is a no-op for 0.5.0 consumers.

### Plan surface (workbench over the DAG)
- Four lenses behind a vertical lens nav: **Timeline** (execution Gantt on
  compressed real time — per-attempt task bars with retry chains, gap-break
  glyphs for idle hours, hour/day gridlines, NOW line, coral gate diamonds,
  L0 reconcile-cycle strip, dependency hover tracing, CPM-projected region
  for ungated future nodes), **Matrix** (N×N dependency matrix, gate-status
  diagonal pills, blue-deps/green-dependents hover tracing, real topo-sort
  acyclicity footer), **DAG** (layered stage graph: collapsible S-stage
  ribbons, bezier edges, transitive ancestor/descendant tracing), and
  **Tasks** (the sortable task table, now with a DAG-node column).
- Right-hand node drilldown aside (gate, requiredCompletion, deps as chips,
  task rollup); the bottom-sheet inspector still owns full task detail.
- Hash router `#<surface>/<lens>/<selection>[:tab]`; all legacy deep links
  (`#TASK-…`, `#NODE:…`, `#L1:…`, `#PLAN`, `?list=1`) migrate automatically.

### Consoles surface (live operations room)
- Persistent **L0 supervisor pane** (semantic events stream + raw
  autonomate log, collapsible) with the highest visual weight; a dynamic
  region where role/task/area/phase/model-labeled agent consoles pop in as
  sessions go live (L1 panes span full width, L2 tile 2-up, cap 4), linger
  with their final state on completion (45s for failures), then collapse
  into a **recent rail** — which doubles as the idle/historical browser
  (finished sessions reopen with full parsed scrollback). Pin/solo/raw per
  pane; single 2s poll scheduler with an in-flight cap; `#consoles/<id>`
  deep links.

### Agents surface (role grid)
- Cards per runtime role (avatar + live glyph, active pill, current
  tasks/areas, model · effort chip, last-activity age) + a dimmed
  declared-roles strip; role detail with processes (jump to their console)
  and **read-only** settings showing env-key provenance
  (`model → claude-opus-4-8 (GLUERUN_CLAUDE_L2_MODEL)`) plus concurrency
  limits — the console observes, it never writes.

### Design system
- Adopted the warm-neutral **pm-go token layer** (`tokens.css`): warm paper
  + 24px printer's line grid, flat white panels (glass/backdrop-blur
  retired), six-tone signal language with **coral replacing violet** as the
  attention accent, Inter + Roboto Mono. Legacy token names alias to the new
  system, so retained chrome re-skinned without markup churn.
- Client rebuilt as ES modules (`main.js` + `core/` + `plan/` + `consoles/`
  + `agents/`), served by an extension-allowlisted asset route with
  resolved-path containment (subdirectories supported, no per-file registry).

### Server API (all additive)
- **`/api/dag`** (`gluerun.codex.dag.v0`, `--dag`): registry nodes merged
  with gate results, per-node task rollups (events-attributed with the
  `DAG node:` header fallback), L1 leases, frontier flags, `edges[]`, and
  stage/area swimlane metadata.
- **`/api/timeline`** (`gluerun.codex.timeline.v0`, `--timeline`,
  `?since=`): per-task attempt intervals reconstructed from events
  (dispatch records are overwritten per attempt — history lives in the
  journal), `liveNow` for running bars, gate marks, L0 reconcile cycle
  spans.
- **`/api/config`** (`gluerun.codex.config.v0`, `--config`): per-role
  model/effort resolved with the engine's own precedence (`.env` override >
  config `env{}` > runner default) with source-key provenance, plus limits
  and flags. Secrets in `.env` are never read (whitelisted parser).
- `/api/sessions`: rows gain durable `provider/model/effort/exitCode/
  attempt` + `sessionMeta{implementer,reviewer}` from session-meta files;
  `?limit=` (default 16, max 40); auditor logs discoverable.
- L0 supervisor log resolution: the server now follows whichever of
  `autonomate.out.log` / `autonomate.log` (the engine's actual `--detach`
  output) exists — the supervisor stream was previously invisible.
- `NODE_ID_RE` accepts slug node ids (`ctx-loader`) — `/api/node` 400'd
  every real consumer DAG id.

### Engine
- Auditor runner output → `$run_dir/auditor-codex.log` and decider output →
  `$run_dir/decider-codex.log` + `session-decider.json` (both previously
  `/dev/null`), so the two most watch-worthy roles stream in the console.

### Migrating from 0.5.0
- No action required. The old L0→L1→L2 graph canvas and the task-list
  drawer are gone; the task table lives at `#plan/tasks` and old deep links
  redirect. `?view=graph|list` is retired (hash routes replace it). The
  client is now ES-module based under `/assets/`.

---

## [0.5.0] — 2026-07-17 — Field-hardening from the first external consumer run

Every change in this release traces to the singular-frontend V1 field run
(Jul 13–16, codex session 019f5ce7): a 4-day, 78-dispatch, 47-node run that
converged but lost ~40 of ~96 hours to engine defects and needed ~15 manual
state surgeries. `schemaVersion` stays **v1** — all schema changes are
additive (`authority` node field; new `gate-review.v0`), so `gluerun migrate`
is a no-op for 0.4.0 consumers.

### Autonomy & failure classification
- **Limit/quota windows require structured evidence**: only engine-written
  runner logs are scanned (never `.md`/model artifacts — repo prose like a
  "quota-banner" feature armed ≥13 false 30-minute backoffs in the field),
  markers are word-boundary contextual regexes, quota backoffs refuse to arm
  without a `logRef`, and import rejections are excluded from limit
  eligibility. **`GLUERUN_LIMIT_SLEEPTHROUGH`** (default 1) supersedes the
  deprecated `GLUERUN_DISABLE_LIMIT_SLEEPTHROUGH`.
- **Monotonic task ids**: durable counter seeded from every surface (tasks
  incl. `superseded/`, leases, dispatch records, worktrees, imported packets,
  `agent/*` branches). Archived ids can never be recycled (4 field
  collisions, 2 breaker halts); collisions reject the batch instead of
  overwriting, and `gluerun_lease_write` refuses to clobber
  accepted/integrated leases.
- **Duplicate guard v2**: status-aware (terminal tasks never block a
  successor — the blocked-task deadlock killed a whole night), keyed on the
  new `DAG node:` task header (legacy `S#/D#` token regex is fallback only),
  `Supersedes:` header bypasses the guard, and unknown-node matches require a
  full signature. Empty planner batches (`{"tasks": []}`) are a first-class
  no-op (`planner.no_tasks`), not invalid output.
- **Exit-code contract**: dispatch exit 2 = refusal (never breaker input),
  3 = decided-terminal, other = crash. Repeated refusals park the task
  (**`GLUERUN_REFUSAL_PARK_THRESHOLD`**=3) instead of starving the loop.
- **Whole-tree reap liveness**: descendants, process group, run-id command
  lines, and recent run-dir writes all count as alive
  (**`GLUERUN_STALE_HARD_MINUTES`**=240 caps the conservatism). The 0.4.0
  root-pid check destroyed accepted work under a live auditor.
- **Accepted-work auto-heal** (**`GLUERUN_AUTO_ACCEPT_EXISTING`**=1): a
  dispatch against an `accepted` lease re-accepts the stranded packet
  deterministically and enqueues it; a new `accept-pending` trap state means
  a post-acceptance crash never fails the lease.

### Runners & retries
- **`GLUERUN_CODEX_TIMEOUT_SEC`** (default 2400; 0 disables) bounds codex
  runs with a kill-tree, and opt-in **`GLUERUN_CODEX_IDLE_SEC`** kills runs
  whose JSONL output stops growing — field hangs ran 28–380 minutes
  unbounded. rc 124 classifies as timeout/infra everywhere already.
- **Empty-diff retries reconcile**: a retry whose content was committed by a
  prior attempt (gate green, owned files differ from base) proceeds instead
  of parking fully green work as `no-changes`.
- **Audit-verdict validation** joins decider-verdict validation
  (**`GLUERUN_AUDIT_VERDICT_VALIDATE`**=warn; `strict` re-runs the auditor).
  Legacy `pmgo.*` schema ids are tolerated-with-warning
  (**`GLUERUN_LEGACY_SCHEMA_MODE`**=warn; `reject` post-migration) — the
  0.4.0 hard rejection parked every decision in consumers scaffolded with
  legacy prompts (18.5h halt).

### Promotion & governance
- **Auto-promotion actually fires**: **`GLUERUN_AUTO_PROMOTE_GATES`** now
  defaults to 1; gates promote at integrate time (`promote-gate --if-ready`)
  the moment a node's last task lands, and the empty-queue reconcile pass no
  longer requires a free dispatch slot. Promotions count as loop progress.
- **`gluerun promote-gate` honors the config `promoter` key** (new
  `engine/promote-gate.sh` wrapper sources lib.sh; explicit env still wins);
  actionable errors; stderr progress heartbeat
  (**`GLUERUN_PROMOTE_PROGRESS_SECS`**=15).
- **Terminal-predecessor tolerance** (**`GLUERUN_PROMOTE_TOLERATE_TERMINAL`**=1):
  superseded/blocked predecessors with an integrated successor count as
  satisfied; `tasks/superseded/` is scanned.
- **Planner suppression** (**`GLUERUN_SUPPRESS_UNPROMOTED_REPLAN`**=1): nodes
  whose tasks are complete but whose gate is unpublished are not re-planned
  (the field's duplicate-churn source); a published failed gate keeps the
  node plannable.
- **Evaluation-gate governance**: DAG nodes may declare
  `authority: operator | agent-review-allowed` (additive). `kind: evaluation`
  nodes promote via `promote-gate --operator --evidence REF`, or — when
  opted in — via a valid PASSING **`gate-review.v0`** file at
  `gates/evidence/<node>.review.json` (independent reviewer identity,
  evidence refs, headSha ancestor check,
  **`GLUERUN_REVIEW_MAX_AGE_HOURS`**=168). The dag schema file drops 0.4.0's
  project-specific layer/kind enums to match the engine validator.

### Recovery becomes verbs
- New CLI: **`supersede`** (all four resurrection surfaces atomically, live-
  dispatch guard, `--force`), **`clear-backoff`**, **`breaker show|reset`**,
  **`stop [--wait]`**, **`resume`**, **`wake`**, **`gates [--json]`**,
  **`health [--json]`** (sub-2s digest with a stable hash field for cheap
  heartbeats + `attention[]`), **`gc [--dry-run]`**
  (**`GLUERUN_RUNS_KEEP`**=200 runs-history cap with reference protection,
  integrated-worktree pruning, events rotation at
  **`GLUERUN_EVENTS_MAX_MB`**=64), plus `lease` and `accept-packet` wiring.
- `next-areas --explain` emits per-node exclusion reasons; a corrupt gate
  file no longer crashes the frontier computation.
- `recover` reclassifies stale **L1 planning leases**
  (**`GLUERUN_RECOVER_L1`**=1; report-only before), reports orphaned
  worktrees **once** (`recover-orphans.json`), and can auto-prune clean
  integrated worktrees (**`GLUERUN_AUTO_PRUNE`**, default 0).
- Opt-in **`GLUERUN_INTEGRATE_REBASE`**: rebase-and-regate an audited branch
  once on merge conflict instead of terminally parking.
- Detached workers' process groups are killed on supersede `--force`
  (**`GLUERUN_KILL_ORPHAN_PGROUP`**=1) so gate webservers stop leaking.

### Lifecycle & loop
- **`gluerun auto --detach`**: supported daemonized launch (setsid
  double-fork, `.gluerun-state/autonomate.log`, post-launch liveness check).
- Interruptible naps: STOP takes effect mid-sleep within
  **`GLUERUN_SLEEP_POLL_SEC`**=10; `gluerun wake` / `clear-backoff` end naps
  early — killing sleep children (which killed the whole loop in the field)
  is never needed. Quota budget counts only actually-slept seconds.

### Console & observability
- `/api/state` no longer shells `make orch-*` probes or a blocking `du`: the
  snapshot is assembled natively from durable files, disk usage samples on
  its own 5-minute background cache, and a stale-but-marked snapshot
  (`stale`/`computing`/`snapshotAgeSeconds`) is served instantly while a
  refresh runs (`?fresh=1` still blocks). Snapshot keys `gateD0`/`gateD1`
  are replaced by `orchestration.gates {passed,total,byNode}`.
- `gluerun console --ensure | --status | --stop`; the URL/pid persist at
  `.gluerun-state/console.url`/`console.pid`; the banner moved to stderr
  (one-shot JSON is pipe-pure); default port **8765** with free-port
  fallback; `gluerun status` prints the live console URL.
- `origin-state.json` gains `gates{passed,total}`, `completedNodes`,
  per-status `taskCounts`, and writer provenance; STATUS.md states its
  staleness contract.

### Doctor & skill
- Doctor preflights: model-prefix sanity, `~/.codex/hooks.json` parse (FAIL),
  MCP server fan-out count, legacy `pmgo.*` id scan (FAIL + migrate pointer),
  stale pidfiles, disk floor, `.worktrees` size, console-port availability.
- Skill rewritten for cheap monitoring: a `gluerun health --json`
  digest-compare heartbeat loop, a full 0.5.0 knob table, six numbered
  recovery recipes, the operator-gate escalation contract, and a new
  `references/artifacts.md` (canonical field names per artifact + jq
  cookbook). Console trigger words (dashboard/viewer/visualization/UI) added
  to the skill and plugin manifest.

### Migrating from 0.4.0
- **No schema migration**: `schemaVersion` stays v1; `authority` and
  `gate-review.v0` are additive.
- **Behavior flips (opt out in config `env{}` if needed)**:
  `GLUERUN_AUTO_PROMOTE_GATES=1` (was 0), codex runs bounded at 2400s (set
  `GLUERUN_CODEX_TIMEOUT_SEC=0` to restore unbounded), exit-2 refusals no
  longer feed the breaker, planner suppression of pending-promotion nodes,
  stale L1 lease reclassification (`GLUERUN_RECOVER_L1=0` restores
  report-only), duplicate guard ignores terminal tasks, legacy `pmgo.*`
  verdict ids tolerated (`GLUERUN_LEGACY_SCHEMA_MODE=reject` restores strict).
- **Console**: default port is 8765; the launch banner moved to stderr —
  update any script that parsed it from stdout; `gateD0`/`gateD1` snapshot
  keys are gone.
- **New state files**: `.gluerun-state/task-id-counter`, `WAKE`,
  `console.url`/`console.pid`, `recover-orphans.json`,
  `dispatch/<task>.refusals`. Task-id sequences may show gaps (intentional).
- **Consumer templates**: add `DAG node: <node-id>` to `tasks/TEMPLATE.md`
  and planner prompts (scaffold only creates-if-missing; new consumers get
  it automatically).

---

## [0.4.0] — 2026-07-13 — Context-aware orchestration (self-hosted S0–S7 complete)

Completes the context-evolution plan the engine built against itself: 107
worker-implemented, independently audited, gate-promoted tasks across 20
executable DAG nodes, closed by an operator-authored experiment report
(`docs/context-build-plan/experiment-report.md`). Additive and default-OFF at
the raw engine level; the **shipped config flips five knobs ON per the
report's per-knob decisions** (see below). Raw-default flips are deferred to
0.5 with a test-migration slice (OFF-parity tests pin unset == legacy).

- **Context packets + assumption ledger** (`GLUERUN_CTX_PACKET`): planner
  reasoning residue (decisions / assumptions / rejected alternatives /
  inspected symbols) rides task files into worker, fix, and audit prompts;
  per-run assumption ledger with host-derived status transitions in the
  assumption grammar `[open|validated|violated]`.
- **Artifact secret scan + quarantine** (`GLUERUN_CTX_ARTIFACT_SCAN`):
  `secret-scan.sh --artifacts` covers capsules, session meta, packets,
  critique and paired-audit records; hits rename to `.quarantined`, emit
  `ctx.artifact_secret`, and are excluded from every prompt-assembly and
  rehydration path without changing task outcomes.
- **Explicit session routing** (`GLUERUN_CTX_ROUTING`): one dispatcher
  (`gluerun_ctx_route`) returning `continue|resume|fork|fresh|rehydrate`
  with a reason code; window-pressure and diff-volume refusal gates;
  generalized session leases; structural taint marking makes
  independence-pinned steps (final + paired audits) unreachable by resumed or
  rehydrated sessions; per-role strategy/outcome metrics splits.
- **Rehydration** (`GLUERUN_REHYDRATE`): deterministic, capped,
  quarantine-aware packets assembled from durable artifacts (packets,
  capsules, ledgers, critiques, decision records) injected on refused-resume
  lineage steps, with the packet manifest recorded in strategy events.
  Optional authored-knowledge manifest ingestion (`GLUERUN_CTX_MANIFEST` +
  additive `contextManifest` config field): select → eligibility
  (`load-when` across role/step/node/task) → compose → inject → record,
  fixture-contract only (singular-brain bridge, no runtime dependency).
- **Context graph** (`GLUERUN_CTX_GRAPH`): `context-graph.v0` schema
  (append-only JSONL nodes/edges, full edge taxonomy,
  `evidenceClass: authoritative|claim`, provenance refs) + S0–S5
  event-to-graph mapping; deterministic projector over all record families;
  incremental sync ≡ rebuild; loss-free delete/rebuild; query read API
  (neighbors, lineage walk, open-contradictions); `gluerun graph
  rebuild|sync|query` CLI. Subgraph-selected rehydration (lineage-walk
  selection, rejected observations excluded, contradictions surfaced first)
  with a flat-vs-subgraph A/B arm.
- **Experiment toolchain** (`GLUERUN_CTX_EXPERIMENT` /
  `GLUERUN_CTX_ARMSTATE`): per-arm aggregators (escape-rate, cost, bias,
  attempts-to-accept, findings-per-attempt, resume/rehydrate hit-rates,
  refusal reason mix), treatment-vs-control delta, knob-state provenance
  recording + consistency audit, markdown renderers, composed report body,
  `gluerun experiment-report` CLI, operator hand-off record.
- **Shipped-config defaults per the experiment report**: `PLANNER_SESSION`,
  `PLAN_CRITIQUE`, `CTX_PACKET`, `CTX_ROUTING`, `CTX_ARTIFACT_SCAN` ON and
  `PAIRED_AUDIT_PCT=25` in the self-dock config; `REHYDRATE`,
  `CTX_MANIFEST`, `CTX_GRAPH`, `CTX_EXPERIMENT` stay opt-in pending
  live-scale / consumer evidence.
- New event types: `context.strategy_selected`, `context.resume_failed`,
  `ctx.arm_assigned`, `ctx.artifact_secret`, `ctx.paired_audit`,
  `ctx.critic_recheck`, `ctx.packet_malformed`, `plan.critiqued`,
  `plan.revised`, `plan.revise_parked`, `planner.backoff_active`.

---

## [0.4.0-m1] — 2026-07-11 — Context-evolution M0–M3 (self-hosted, unreleased dev pin)

Built by the engine itself under `docs/context-build-plan/` (self-docked, all
tasks worker-implemented, independently audited, and gate-promoted with hashed
evidence). Everything below is additive and default-OFF unless noted.

- **Self-measurement**: `gluerun metrics --json` over the attempts index +
  event log; deterministic per-task A/B arms (`GLUERUN_CTX_AB`); sampled
  post-acceptance paired fresh audits (`GLUERUN_PAIRED_AUDIT_PCT`).
- **Planner session persistence and resume** (`GLUERUN_PLANNER_SESSION`):
  per-node session meta, node-lineage + template-sha gates, session leases,
  rc-86 fresh fallback, reason-coded `context.strategy_selected` events.
- **Plan critique** (`GLUERUN_PLAN_CRITIQUE`): `plan-critique.v0` schema,
  fresh read-only skeptic critic over staged batches, critique-aware L0
  import (approve/revise/park, fail-closed on missing record, fail-open on
  critic infra).
- **Plan revision loop** (`GLUERUN_PLAN_REVISE_MAX`): bounded
  revise → (resume|fresh) → re-critique with per-finding dispositions and
  `plan.revised` provenance events; critic re-critique may resume the
  critic's own session (skeptic-only).
- **Invariant redefined**: the old "resume is a token-cost optimization that
  never changes a task outcome" is replaced by **evidence invariance** —
  routing never changes what counts as evidence; outcomes may improve with
  continuity and the improvement is measured. Advocate/skeptic line documented.
- Hermeticity hardening from self-docking: suite scrubs inherited GLUERUN_*
  env and runs tests with stdin from /dev/null.

---

## [0.3.0] — 2026-06-10 — Initial public release of glueRun-go

This is the first public release of glueRun-go. It ships detached dispatch **ON by
default** (`GLUERUN_DETACHED_DISPATCH=1`): the reconcile cycle no longer blocks on
its worker batch. The legacy batch barrier held the origin lock across every worker
(minutes to hours), freezing packet import, integration of already-finished work,
recovery, STATUS, and STOP responsiveness until the slowest worker finished. With
detached dispatch on, reconcile pre-leases each frontier task, spawns the worker in
its own session, and returns within seconds; the reaper attributes outcomes on later
cycles via dispatch records + exit files.

### Detached dispatch (default ON: `GLUERUN_DETACHED_DISPATCH=1`)

- Reconcile pre-leases each frontier task (`status=planned`, scope published) and
  spawns the worker in its own session via `dispatch-wrap.sh`, then returns within
  seconds; the origin lock is held for the cycle's control work only. Set
  `GLUERUN_DETACHED_DISPATCH=0` to restore the legacy batch wait path.
- **Dispatch records** (`.gluerun-state/dispatch/<taskId>.json`) + worker exit
  files; a **reaper** (`gluerun_reap_dispatches`, run at the top of every
  apply/actuate cycle before recovery) attributes completions, failures, and
  crashes (pid + `ps lstart` liveness, defeating pid reuse). Crash detection
  drops from the 60-min stale-lease window to ~one cycle.
- `reconcile.sh --drain` blocks until no launched dispatch records remain
  (tests, clean shutdown). New stdout fields `reaped_ok=`, `reaped_failures=`,
  `workers_running=`, `detached_dispatch=` (additive; legacy fields intact).
- Autonomy accounting (flag-gated): a dispatch alone is no longer progress —
  progress is an observed completion, an integration, or newly planned work;
  reap failures count toward the circuit breaker. Batch-mode accounting unchanged.
- `recover.sh`: pid-aware fast-stale backstop — an active lease whose dispatch
  pid is gone is reclassified immediately instead of after the stale window.
- New events: `origin.dispatch_reaped`, `origin.worker_reaped` (in-cycle wait
  now also records per-worker exit + duration for utilization baselines).

### Concurrency hardening (always on)

- Lease/task state writes (`gluerun_lease_write`, `gluerun_lease_set_status`,
  `gluerun_lease_bump_retry`, `gluerun_lease_update_owned`,
  `gluerun_task_set_status`) are now tmp+rename atomic — no torn reads while
  workers and reconcile mutate control state concurrently.
- `integrate.sh` merge/abort/finalize and reconcile's control-state `add`+`commit`
  now run under the repo-wide git-op lock shared with worker git operations
  (the regression gate still runs outside the lock).
- Both dispatch modes spawn through `dispatch-wrap.sh`, which persists the
  driver's exit code and backstops a lease the driver never owned (or died
  holding) so it stops consuming a concurrency slot.

### Context continuity

- Host-built per-attempt **context capsules**: a hash-stamped
  `implementer-capsule.json` (what the worker was tasked with) and
  `reviewer-capsule.json` (what the auditor reviewed/concluded).
- A **findings ledger** (`findings-status.json`) upserted from each audit
  verdict, with stable finding ids (format-insensitive) tracked open/resolved.
- **Structured fix prompts** carry the authoritative open findings forward on
  retry, replacing the truncated byte-tail (`GLUERUN_FIX_PROMPT_STRUCTURED=0`
  restores the legacy `fix_hints` tail byte-for-byte).
- **Re-audit delta prompts**: prior findings + fix diff + per-id verification
  targets, requesting an additive `findingsStatus` map
  (`{<findingId>: "resolved" | "still-open"}`) alongside the normal verdict.
- **Per-attempt artifact archive** under `runs/<id>/attempts/<n>/` (root files
  copied, never moved) with an `attempts/index.json`.
- New events: `context.strategy_selected`, `findings.ledger_updated`,
  `l1.attempt_archived`.

### Session affinity

- Optional role-keyed runtime **session resume** (`codex exec resume`,
  `claude -r`) behind 10 staleness gates, defaulting ON
  (`GLUERUN_SESSION_AFFINITY=1`). Any gate failure — or a runner that refuses the
  resume — degrades to a fresh run within the same attempt. Session resume is a
  token-cost optimization that **never changes a task outcome**.
- New event: `context.resume_failed`.

### Reliability

- **Infra-failure isolation**: worker/auditor infrastructure failures (timeouts,
  unparseable verdicts) re-run only the failed role, bounded
  (`GLUERUN_WORKER_INFRA_MAX=1`, `GLUERUN_AUDIT_INFRA_MAX=2`) and *without*
  consuming the review/retry budget; on exhaustion they surface as `worker-infra`
  / `audit-infra`.
- **Decider fast-path** (`GLUERUN_DECIDER_FAST=1`): a deterministic host policy
  table resolves unambiguous `(failure-class, retries-left)` pairs; ambiguous
  cases still consult the model decider.
- **Host task preflight**: malformed tasks are blocked before any lease, worktree,
  or model run.
- New events: `audit.infra_retry`, `worker.infra_retry`, `decider.fast_path`,
  `l1.preflight_failed`.

### Versioning

- Root `SCHEMA_VERSION` file as the data-contract version (`v1` for this
  release); `.gluerun-version` is the canonical engine pin.
- `gluerun doctor` gains schema-mismatch (FAIL) and pin-disagreement (warn) checks;
  `gluerun migrate` + the `migrations/<from>-to-<to>.sh` contract bring a repo's
  `schemaVersion` forward (see `migrations/README.md`).
- Ships the `v0-to-v1` migration that backfills the current scaffold and rewrites
  legacy `pmgo.orchestration.*` namespace references.

### Console

- `schemaVersion`-keyed `plugin/adapters/console-adapter.v0.json` with per-key
  precedence: repo override > engine-shipped > built-in. Built-ins remain the
  no-adapter fallback.

### Back-compat

- With no adapter resolvable, every console endpoint behaves byte-identically to
  the pre-adapter console; a malformed adapter is ignored with a warning.
- All new behavior is gated behind env knobs at their historical-equivalent or
  opt-in defaults; `findingsStatus` is additive (never required) on the audit
  verdict.

schemaVersion: v1

---

## [0.1.0] — unreleased

Initial extraction of the bootstrap orchestration engine into a standalone,
installable package.

- Carved `engine/` (shell scripts) + `schemas/` (8 JSON contracts) out of the
  source repo, preserving exec bits.
- Schemas now ship **with** the engine and resolve relative to the install, not the
  consumer repo.
- Config contract (`gluerun.config.json` + `config.local.sh`) introduced so every
  per-repo knob lives in the consumer repo, never in engine files.
- `dag.sh` validator parameterized: layer/kind vocabulary and required nodes come
  from the DAG manifest; the storage-proof regime moved behind a module hook.
- Test suite abstraction-cleaned: live-state assertions removed; fixtures use a
  generic layer vocabulary.
- `gluerun` CLI + `install.sh` for install-once / run-anywhere with per-repo
  version pins.
- Visualization plugin vendored under `plugin/` and decoupled from project
  specifics.

schemaVersion: v0
