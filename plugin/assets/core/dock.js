/* core/dock.js — the persistent bottom status dock (0.11.0 "Quiet Instrument").

   The ambient system-state layer. It renders honest cells from the app.js store
   ONLY — S.snap (/api/state, the same snapshot renderTop consumes) plus the
   already-polled S.overview (/api/overview, fetched every load() by app.js). It
   adds NO polling of its own: dockTick() is wired into the shared snapshot
   dispatcher in main.js (alongside homeTick/providersTick), so the dock repaints
   on each 10s snapshot. The relocated conn dot (#conn-dot) and updated-age
   (#refresh-age) keep their ids, so app.js's setConn/tickAge keep writing them
   wherever they render — the dock just hosts them now.

   Dependency-light, low in the graph: imports the app.js store (like the surface
   modules) + core/api.js + core/plans.js (for the archived-plan name). No import
   cycle (app.js never imports the dock).

   Cells (left→right): loop · tasks · gates · attention(needs-you) · breaker(only
   when tripped) · spacer · repo·branch · conn+age. Every value is snapshot-derived;
   nothing is fabricated. A codex-quota cell is intentionally OMITTED in Phase 1
   (the /api/providers quota payload isn't cached off the Home surface yet). */

import { S } from "../app.js";
import { isHistorical, activePlan, switchPlan } from "./api.js";
import { activePlanEntry } from "./plans.js";

const el = (id) => document.getElementById(id);
const setText = (id, t) => { const n = el(id); if (n) n.textContent = t; };
const toggleClass = (id, cls, on) => { const n = el(id); if (n) n.classList.toggle(cls, !!on); };
const basename = (p) => String(p || "").replace(/\/+$/, "").split("/").pop() || "";

// Ready-task count: the /api/state origin-state projection when present (it may be
// a list of ids OR a count, depending on the origin-state version), else the
// /api/overview loop status. Both are already in the store — no new fetch.
function readyCount(snap, ov) {
  const os = (snap.orchestration && snap.orchestration.originState) || {};
  const r = os.readyTasks;
  if (Array.isArray(r)) return r.length;
  if (typeof r === "number") return r;
  if (ov && ov.loop && typeof ov.loop.readyTasks === "number") return ov.loop.readyTasks;
  return null;
}

// Repo basename → the breadcrumb + rail brand caption (the dock owns the single
// snapshot→chrome-text write so app.js/renderTop stays untouched). Only writes when
// the live snapshot actually carries a repo path (the historical synthetic snapshot
// does not), so a live→historical switch keeps the last-known repo rather than "—".
function paintRepoChrome(snap) {
  const repo = snap && snap.repo ? basename(snap.repo) : "";
  if (!repo) return;
  setText("crumb-repo", repo);
  setText("brand-repo", repo);
}

function renderCells() {
  const snap = S.snap;
  const ov = S.overview;
  const hist = isHistorical();

  const liveEl = el("dock-live"), histEl = el("dock-hist");
  if (liveEl) liveEl.hidden = hist;
  if (histEl) histEl.hidden = !hist;

  // Right cluster: repo · branch (breadcrumb repo rides along).
  paintRepoChrome(snap);
  const entry = activePlanEntry();
  const repoBase = snap && snap.repo ? basename(snap.repo) : "";
  const branch = (snap && snap.targetBranch) || (entry && entry.branch) || "";
  setText("dock-repo-text", [repoBase, branch].filter(Boolean).join(" · ") || "—");

  // Historical mode: one muted "viewing archived plan <name>" cell + back-to-live;
  // the right cluster (repo·branch, conn, age) stays as painted above.
  if (hist) {
    const name = (entry && entry.name) || activePlan || "archived plan";
    setText("dock-hist-text", "viewing archived plan " + name);
    return;
  }
  if (!snap) return;

  const sc = (snap.summary && snap.summary.stateCounts) || {};
  const active = sc.active || 0;
  const blockedFailed = (sc.blocked || 0) + (sc.failed || 0);

  // loop — the honest "alive" authority is the L0 state (active = live origin
  // processes / lock; stopped = STOP sentinel + no processes; else idle). A calm
  // blue pulse-dot while alive, a flat dot otherwise; the iteration number rides
  // along from the overview loop status when it exists.
  const l0 = (snap.agents && snap.agents.l0) || {};
  const running = l0.state === "active";
  const iter = (ov && ov.pulse && ov.pulse.iteration != null) ? ov.pulse.iteration
    : (ov && ov.loop ? ov.loop.iteration : null);
  const loopDot = el("dock-loop-dot");
  if (loopDot) loopDot.className = running ? "pulse-dot" : "state-dot";
  setText("dock-loop-text", running
    ? ("running" + (iter != null ? " · iter " + iter : ""))
    : (l0.state === "stopped" ? "loop stopped" : "loop idle"));

  // tasks — active (snapshot state counts) · ready (origin state / loop status).
  const ready = readyCount(snap, ov);
  setText("dock-tasks-text", active + " active · " + (ready != null ? ready : "—") + " ready");

  // gates — passed/total; ochre when blocked/failed tasks stall gate progress.
  const g = (snap.orchestration && snap.orchestration.gates) || {};
  setText("dock-gates-text", "gates " + (g.passed != null ? g.passed : "?") + "/" + (g.total != null ? g.total : "?"));
  toggleClass("dock-gates", "attention-cell", blockedFailed > 0);

  // attention — the operator's action queue: blocked + failed tasks (the loop
  // cannot self-heal past retries). Ochre + amber dot when > 0, quiet at 0.
  const needs = blockedFailed;
  const attDot = el("dock-attention-dot");
  if (attDot) attDot.className = needs > 0 ? "state-dot needs-you" : "state-dot";
  toggleClass("dock-attention", "attention-cell", needs > 0);
  setText("dock-attention-text", needs > 0 ? (needs + " needs you") : "all clear");

  // breaker — shown ONLY when the loop reports consecutive failures (rose text).
  const cf = ov && ov.loop ? ov.loop.consecFails : null;
  const brEl = el("dock-breaker");
  if (brEl) {
    const tripped = typeof cf === "number" && cf > 0;
    brEl.hidden = !tripped;
    if (tripped) setText("dock-breaker-text", "breaker " + cf);
  }
}

export function initDock() {
  const dock = el("status-dock");
  if (!dock) return;
  dock.addEventListener("click", (e) => {
    if (e.target.closest("#dock-hist-back")) { switchPlan(null); return; }
    const cell = e.target.closest("[data-dock-nav]");
    if (cell) { location.hash = cell.dataset.dockNav; }
  });
  renderCells();   // paint immediately (pre-snapshot → placeholders; fills on first tick)
}

// Called from the shared snapshot dispatcher (main.js) — no independent polling.
export function dockTick() { renderCells(); }
