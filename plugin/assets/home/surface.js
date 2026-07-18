/* home/surface.js — the Home surface (0.7.0 workspace polish).

   The default landing surface: a 16:9 glance canvas over GET /api/home
   (gluerun.codex.home.v0, 10s aggregate). Top→bottom: a hero health + attention
   row, a gates block with per-stage bars (from the shared plan/data.js dag), the
   relocated live event feed side-by-side with a dependency-free 14-day activity
   sparkline, a throughput/limits tile row, and quick links into Plan/Consoles.

   Home owns an independent 10s /api/home poll (paused while hidden) and also
   re-renders on the shared snapshot tick for immediacy. Render is signature-gated
   so a quiet poll produces zero rebuilds. The live feed itself is painted by the
   relocated overlay poll in app.js (renderActivityFeed) into #home-activity-feed,
   so it stays out of the Home signature and updates on its own 2s cadence. */

import { S, esc, escAttr, icon, toneOf, relTime, select, navigateToTask, renderActivityFeed } from "../app.js";
import { getDag, fetchDag, onDag } from "../plan/data.js";
import { feedState, subscribe as subscribeSessions } from "../core/sessions-feed.js";
import { apiFetch, isHistorical, switchPlan } from "../core/api.js";
import { fetchPlans, plansList, activePlanEntry, fmtDate } from "../core/plans.js";

const POLL_MS = 10000;
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const HOME = {
  started: false,
  visible: false,
  data: null,          // last /api/home payload
  inflight: false,
  timer: null,
  sig: null,
  dagUnsub: null,
};

const HEALTH_TONE = { ok: "success", healthy: "success", watch: "warn", blocker: "error" };
const HEALTH_LABEL = { ok: "all clear", healthy: "all clear", watch: "watch", blocker: "blocker" };

// ------------------------------------------------------------- data fetch -----
async function fetchHome() {
  // Historical Home renders from the /api/plans registry entry + the archived dag
  // (never /api/home, which is a live-only digest). Handled in setHomeActive/render.
  if (isHistorical() || HOME.inflight) return;
  HOME.inflight = true;
  try {
    const res = await apiFetch("/api/home", { cache: "no-store" });
    if (res.ok) { HOME.data = await res.json(); }
    await fetchPlans();   // feeds the "Previous plans" card (folded into signature())
    render();
  } catch (e) { /* keep last good; a transient miss must not blank Home */ }
  finally { HOME.inflight = false; }
}

// ------------------------------------------------------------- signature ------
function signature() {
  const d = HOME.data;
  if (!d) return "nohome";
  const abd = (d.activityByDay || []).map((x) => [x.dispatches, x.integrations, x.failures]).join(",");
  const gates = d.gates ? `${d.gates.passed}/${d.gates.total}` : "-";
  const dag = getDag();
  const stages = dag ? (dag.stages || []).map((s) => `${s.id}:${s.passed}/${s.total}`).join("|") : "-";
  const snapExtra = S.snap ? [
    (S.snap.git && S.snap.git.drift && (S.snap.git.drift.left + "/" + S.snap.git.drift.right)) || "-",
    (S.snap.disk && S.snap.disk.capacityPercent) || "-",
  ].join(",") : "-";
  const pl = plansList();
  const plansSig = pl == null ? "np" : pl.map((p) => p.id + ":" + ((p.gates && p.gates.passed) != null ? p.gates.passed : "?")).join(",");
  return [d.health, (d.attention || []).length, gates, JSON.stringify(d.taskCounts || {}),
    JSON.stringify(d.dispatch || {}), d.stop, d.breaker && d.breaker.consecFails,
    d.backoff && d.backoff.active, d.lastActivityAt, abd, stages, snapExtra,
    (d.frontier && d.frontier.count) || 0, plansSig].join("::");
}

// ------------------------------------------------------------- render ---------
function render() {
  if (!HOME.visible) return;
  const host = document.getElementById("home-body");
  if (!host) return;
  if (isHistorical()) { renderHistorical(host); return; }
  const sig = signature();
  if (sig === HOME.sig) return;
  HOME.sig = sig;
  const d = HOME.data;
  if (!d) { host.innerHTML = `<div class="home-loading">loading digest…</div>`; return; }
  host.innerHTML =
    `<div class="home-canvas">
       ${heroHtml(d)}
       ${gatesHtml(d)}
       ${activityHtml(d)}
       ${tilesHtml(d)}
       ${linksHtml(d)}
       ${prevPlansHtml()}
     </div>`;
  // Repaint the relocated event feed into its freshly-rebuilt host.
  renderActivityFeed();
}

// U4 — "Previous plans" card (live mode). Hidden when the endpoint is unavailable
// (older server → plansList() null); an empty registry shows a run-hint.
function prevPlansHtml() {
  const list = plansList();
  if (list == null) return "";   // endpoint absent → feature quietly hidden
  const body = list.length
    ? list.map((p) => {
        const g = p.gates || {};
        const gp = g.passed != null ? g.passed : "?";
        const gt = g.total != null ? g.total : "?";
        return `<button class="home-plan-chip" data-plan-switch="${escAttr(p.id)}" title="switch to ${escAttr(p.name || p.id)}">
          <span class="hpc-name">${esc(p.name || p.id)}</span>
          <span class="hpc-meta mono">${esc(fmtDate(p.archivedAt))} · gates ${esc(gp + "/" + gt)} · ${esc((p.taskCount != null ? p.taskCount : 0) + " tasks")}</span>
        </button>`;
      }).join("")
    : `<div class="home-empty">No archived plans yet — run <code>gluerun plan archive</code> when a DAG completes.</div>`;
  return `<section class="home-block home-prevplans">
    <div class="home-block-head"><span class="home-eyebrow">previous plans</span></div>
    <div class="home-plan-list">${body}</div>
  </section>`;
}

// Archived Home variant: a hero card for the archived plan (from the /api/plans
// registry entry), per-stage gate bars (from the archived dag), and quick links
// into the Plan lenses + Consoles. No /api/home, no live tiles/attention/activity.
function renderHistorical(host) {
  const e = activePlanEntry();
  const dag = getDag();
  const stagesSig = dag ? (dag.stages || []).map((s) => `${s.id}:${s.passed}/${s.total}`).join("|") : "-";
  const sig = "hist::" + (e ? e.id + ":" + JSON.stringify(e.gates || {}) : "-") + "::" + stagesSig;
  if (sig === HOME.sig) return;
  HOME.sig = sig;
  host.innerHTML = `<div class="home-canvas">
    ${histHeroHtml(e)}
    ${histGatesHtml(e)}
    ${histLinksHtml()}
  </div>`;
}

function histHeroHtml(e) {
  if (!e) return `<section class="home-hero"><div class="home-hero-head"><span class="home-headline">loading archived plan…</span></div></section>`;
  const g = e.gates || {};
  const gp = g.passed != null ? g.passed : "?";
  const gt = g.total != null ? g.total : "?";
  const meta = (label, value) => `<div class="home-hist-meta"><span class="hhm-k">${esc(label)}</span><span class="hhm-v mono">${esc(value)}</span></div>`;
  return `<section class="home-hero home-hist-hero">
    <div class="home-hero-head">
      <span class="home-health status-chip" data-tone="idle"><span class="tone-dot" data-tone="idle"></span><span>archived</span></span>
      <span class="home-headline">${esc(e.name || e.id)}</span>
      <span class="home-hero-age mono">${esc(fmtDate(e.archivedAt))}</span>
    </div>
    <div class="home-hist-metarow">
      ${meta("gates", gp + "/" + gt)}
      ${meta("tasks", e.taskCount != null ? e.taskCount : 0)}
      ${meta("head", e.headSha ? String(e.headSha).slice(0, 12) : "—")}
      ${meta("branch", e.branch || "—")}
    </div>
  </section>`;
}

function histGatesHtml(e) {
  const g = (e && e.gates) || {};
  const dag = getDag();
  const stages = dag ? (dag.stages || []) : [];
  const bars = stages.map((s) => {
    const pct = s.total ? Math.round(100 * s.passed / s.total) : 0;
    const done = s.total && s.passed === s.total;
    const shortStage = String(s.id || "").split("-")[0];
    return `<button class="home-stage-bar" data-stage="${escAttr(s.id)}" title="${escAttr(s.id + " · " + s.passed + "/" + s.total)}">
      <span class="hsb-label mono">${esc(shortStage)}</span>
      <span class="hsb-track"><span class="hsb-fill${done ? " is-done" : ""}" style="width:${pct}%"></span></span>
      <span class="hsb-count mono">${s.passed}/${s.total}</span>
    </button>`;
  }).join("") || `<div class="home-empty">gate detail is loading…</div>`;
  return `<section class="home-block home-gates">
    <div class="home-block-head"><span class="home-eyebrow">gates</span>
      <span class="home-gates-val mono">${g.passed != null ? g.passed : "?"}/${g.total != null ? g.total : "?"}</span></div>
    <div class="home-stage-bars">${bars}</div>
  </section>`;
}

function histLinksHtml() {
  const link = (hash, label) => `<button class="home-link-chip" data-hist-link="${escAttr(hash)}"><span class="tone-dot" data-tone="idle"></span>${esc(label)}</button>`;
  return `<section class="home-block home-links home-hist-links">
    <div class="home-links-col">
      <div class="home-eyebrow">browse this plan</div>
      <div class="home-link-row">
        ${link("#plan/timeline", "Timeline")}
        ${link("#plan/dag", "DAG")}
        ${link("#plan/matrix", "Matrix")}
        ${link("#plan/tasks", "Tasks")}
        ${link("#consoles", "Consoles")}
      </div>
    </div>
  </section>`;
}

// 1. Hero — health chip + headline count summary + attention list.
function heroHtml(d) {
  const tone = HEALTH_TONE[d.health] || "warn";
  const label = HEALTH_LABEL[d.health] || d.health || "—";
  const tc = d.taskCounts || {};
  const headline = `${tc.integrated || 0} integrated · ${tc.active || 0} active · ${tc.ready || 0} ready`;
  const att = (d.attention || []);
  const attList = att.length
    ? att.map((a) => {
        const sev = a.severity === "blocker" ? "error" : "warn";
        const raw = a.link ? rawBtnFromLink(a.link) : "";
        return `<div class="home-att-row" data-sev="${esc(a.severity)}">
          <span class="tone-dot" data-tone="${sev}"></span>
          <span class="home-att-text">${esc(a.text)}</span>${raw}</div>`;
      }).join("")
    : `<div class="home-att-clear"><span class="tone-dot" data-tone="success"></span>all clear — no attention items</div>`;
  return `<section class="home-hero">
    <div class="home-hero-head">
      <span class="home-health status-chip" data-tone="${tone}"><span class="tone-dot" data-tone="${tone}"></span><span>${esc(label)}</span></span>
      <span class="home-headline">${esc(headline)}</span>
      <span class="home-hero-age mono">${d.lastActivityAt ? relTime(d.lastActivityAt) + " ago" : "—"}</span>
    </div>
    <div class="home-attention">${attList}</div>
  </section>`;
}

// A quiet {} raw-view button wired to an /api/raw/<root>/<name> link (E-style).
function rawBtnFromLink(link) {
  const m = /\/api\/raw\/([^/]+)\/(.+)$/.exec(link || "");
  if (!m) return "";
  return `<button class="home-raw-btn" data-raw-root="${escAttr(m[1])}" data-raw-name="${escAttr(m[2])}" title="view source">{ }</button>`;
}

// 2. Gates block — gates X/Y headline + per-stage bars (from the shared dag).
function gatesHtml(d) {
  const g = d.gates || {};
  const dag = getDag();
  const stages = dag ? (dag.stages || []) : [];
  const bars = stages.map((s) => {
    const pct = s.total ? Math.round(100 * s.passed / s.total) : 0;
    const done = s.total && s.passed === s.total;
    const shortStage = String(s.id || "").split("-")[0];
    return `<button class="home-stage-bar" data-stage="${escAttr(s.id)}" title="${escAttr(s.id + " · " + s.passed + "/" + s.total)}">
      <span class="hsb-label mono">${esc(shortStage)}</span>
      <span class="hsb-track"><span class="hsb-fill${done ? " is-done" : ""}" style="width:${pct}%"></span></span>
      <span class="hsb-count mono">${s.passed}/${s.total}</span>
    </button>`;
  }).join("") || `<div class="home-empty">no stages</div>`;
  return `<section class="home-block home-gates">
    <div class="home-block-head"><span class="home-eyebrow">gates</span>
      <span class="home-gates-val mono">${g.passed != null ? g.passed : "?"}/${g.total != null ? g.total : "?"}</span></div>
    <div class="home-stage-bars">${bars}</div>
  </section>`;
}

// 3. Activity — relocated live feed (left) + 14-day sparkline (right).
function activityHtml(d) {
  return `<section class="home-block home-activity">
    <div class="home-activity-events">
      <div class="home-block-head">
        <span class="home-eyebrow">activity</span>
        <span class="home-activity-pulse" id="home-activity-pulse" data-state="idle"><span class="tone-dot" data-tone="idle"></span><span id="home-activity-pulse-text">—</span></span>
        <span class="home-activity-rate mono" id="home-activity-rate"></span>
      </div>
      <div class="home-feed ov-feed" id="home-activity-feed" role="log" aria-live="polite" aria-label="Live orchestration events"></div>
    </div>
    <div class="home-activity-chart">
      <div class="home-block-head"><span class="home-eyebrow">last 14 days</span></div>
      ${sparklineHtml(d.activityByDay || [])}
    </div>
  </section>`;
}

// 4. Dependency-free stacked-bar sparkline over activityByDay (A4).
function sparklineHtml(days) {
  const max = Math.max(1, ...days.map((x) => (x.dispatches || 0) + (x.integrations || 0) + (x.failures || 0)));
  const cols = days.map((x) => {
    const di = x.dispatches || 0, ig = x.integrations || 0, fa = x.failures || 0;
    const total = di + ig + fa;
    const dt = new Date((x.date || "") + "T00:00:00Z");
    const lbl = isNaN(dt) ? (x.date || "") : `${MON[dt.getUTCMonth()]} ${dt.getUTCDate()}`;
    const seg = (n, cls) => n > 0 ? `<span class="hspark-seg ${cls}" style="height:${(n / max * 100).toFixed(1)}%"></span>` : "";
    return `<span class="hspark-col" title="${escAttr(lbl + " · " + di + " dispatch · " + ig + " integ · " + fa + " fail")}">
      <span class="hspark-stack">${total ? seg(fa, "s-fail") + seg(ig, "s-integ") + seg(di, "s-disp") : `<span class="hspark-seg s-zero"></span>`}</span>
    </span>`;
  }).join("");
  return `<div class="home-spark">${cols}</div>
    <div class="home-spark-caption"><span>14d ago</span><span>today</span></div>
    <div class="home-spark-legend">
      <span><span class="hspark-key s-disp"></span>dispatch</span>
      <span><span class="hspark-key s-integ"></span>integrated</span>
      <span><span class="hspark-key s-fail"></span>failure</span>
    </div>`;
}

// 5. Throughput / limits tiles. Task counts deep-link into Plan filters; drift +
// disk come from the shared state snapshot (not in the home payload).
function tilesHtml(d) {
  const tc = d.taskCounts || {};
  const dp = d.dispatch || {};
  const drift = (S.snap && S.snap.git && S.snap.git.drift) || null;
  const disk = (S.snap && S.snap.disk) || null;
  const tile = (label, value, opts) => {
    const o = opts || {};
    const attr = o.filter ? ` data-plan-filter="${escAttr(o.filter)}" role="button" tabindex="0"` : "";
    const tone = o.tone ? ` data-tone="${o.tone}"` : "";
    return `<div class="home-tile${o.filter ? " is-link" : ""}"${attr}${tone}>
      <span class="home-tile-num mono">${esc(value)}</span>
      <span class="home-tile-label">${esc(label)}</span></div>`;
  };
  return `<section class="home-block home-tiles">
    <div class="home-block-head"><span class="home-eyebrow">throughput &amp; limits</span></div>
    <div class="home-tile-row">
      ${tile("dispatched", `${dp.launched != null ? dp.launched : 0}`)}
      ${tile("pid alive", `${dp.pidAlive != null ? dp.pidAlive : 0}`)}
      ${tile("active", `${tc.active || 0}`, { filter: "active", tone: (tc.active || 0) > 0 ? "active" : "" })}
      ${tile("ready", `${tc.ready || 0}`)}
      ${tile("blocked", `${tc.blocked || 0}`, { filter: "blocked", tone: (tc.blocked || 0) > 0 ? "error" : "" })}
      ${tile("failed", `${tc.failed || 0}`, { filter: "failed", tone: (tc.failed || 0) > 0 ? "error" : "" })}
      ${tile("drift", drift ? `${drift.left} · ${drift.right}` : "—")}
      ${tile("disk", disk && disk.capacityPercent != null ? disk.capacityPercent + "%" : "—", { tone: disk && disk.watch ? "warn" : "" })}
    </div>
  </section>`;
}

// 6. Quick links — frontier nodes → Plan/dag; live sessions → Consoles.
function linksHtml(d) {
  const fr = (d.frontier && d.frontier.nodes) || [];
  const sessions = (feedState().sessions || []).filter((s) => s.live && s.id !== "origin").slice(0, 6);
  const frChips = fr.slice(0, 8).map((n) =>
    `<button class="home-link-chip" data-node-link="${escAttr(n)}"><span class="tone-dot" data-tone="integration"></span>${esc(n)}</button>`).join("")
    || `<span class="home-empty">no frontier nodes — plan gated complete</span>`;
  const sessChips = sessions.map((s) =>
    `<button class="home-link-chip" data-session-link="${escAttr(s.id)}"><span class="tone-dot" data-tone="success"></span>${esc(s.taskId || s.node || s.id)}</button>`).join("")
    || `<span class="home-empty">no live sessions</span>`;
  return `<section class="home-block home-links">
    <div class="home-links-col">
      <div class="home-eyebrow">frontier nodes</div>
      <div class="home-link-row">${frChips}</div>
    </div>
    <div class="home-links-col">
      <div class="home-eyebrow">live sessions</div>
      <div class="home-link-row">${sessChips}</div>
    </div>
  </section>`;
}

// ------------------------------------------------------------- nav ------------
// Deep-link a Home task-count tile into the Plan tasks lens with a status filter
// pre-applied (the Plan filter select owns the actual filtering).
function navToPlanFilter(status) {
  location.hash = "#plan/tasks";
  setTimeout(() => {
    const sel = document.getElementById("filter-status");
    if (sel) { sel.value = status; sel.dispatchEvent(new Event("change", { bubbles: true })); }
  }, 60);
}

function mount() {
  const surf = document.getElementById("surface-home");
  if (!surf) return;
  surf.addEventListener("click", (e) => {
    // Attention {} raw buttons carry [data-raw-root]; the app.js document handler
    // (viewRaw) opens them in the inspector file-view — no local wiring needed.
    const stage = e.target.closest("[data-stage]");
    if (stage) { location.hash = "#plan/matrix"; return; }
    const tile = e.target.closest("[data-plan-filter]");
    if (tile) { navToPlanFilter(tile.dataset.planFilter); return; }
    const node = e.target.closest("[data-node-link]");
    if (node) { location.hash = "#plan/dag/NODE:" + node.dataset.nodeLink; return; }
    const sess = e.target.closest("[data-session-link]");
    if (sess) { location.hash = "#consoles/" + sess.dataset.sessionLink; return; }
    const histLink = e.target.closest("[data-hist-link]");
    if (histLink) { location.hash = histLink.dataset.histLink; return; }
    const planSwitch = e.target.closest("[data-plan-switch]");
    if (planSwitch) { switchPlan(planSwitch.dataset.planSwitch); return; }
  });
  surf.addEventListener("keydown", (e) => {
    if ((e.key === "Enter" || e.key === " ")) {
      const tile = e.target.closest && e.target.closest("[data-plan-filter]");
      if (tile) { e.preventDefault(); navToPlanFilter(tile.dataset.planFilter); }
    }
  });
}

// ------------------------------------------------------------- exports --------
export function initHome() {
  if (HOME.started) return; HOME.started = true;
  mount();
  // Re-render when the shared dag (re)loads so per-stage bars fill in.
  HOME.dagUnsub = onDag(() => { HOME.sig = null; render(); });
  // A live-session change repaints the quick-links row (cheap; signature-gated).
  subscribeSessions(() => { if (HOME.visible) { HOME.sig = null; render(); } }, () => HOME.visible);
  // Independent 10s poll — only ticks while Home is visible + the tab is shown.
  HOME.timer = setInterval(() => { if (HOME.visible && !document.hidden) fetchHome(); }, POLL_MS);
}

export function setHomeActive(on) {
  HOME.visible = on;
  if (on) {
    HOME.sig = null;
    if (!getDag()) fetchDag();
    if (isHistorical()) {
      // Archived Home: registry entry (name/gates/tasks) + archived dag gate bars.
      fetchPlans().then(() => { HOME.sig = null; render(); });
      render();
    } else {
      fetchHome();
      render();
    }
  }
}

// Router hook — #home has no sub-route in v2.
export function homeRoute() { setHomeActive(true); }

// Called from the shared 10s snapshot dispatcher (main.js) — signature-gated,
// no-op while hidden. Reflects drift/disk/dag deltas immediately.
export function homeTick() { if (HOME.visible) render(); }
