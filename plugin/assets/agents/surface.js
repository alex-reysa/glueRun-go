/* agents/surface.js — the Agents surface (0.6.0 console redesign).

   Ported from PMGO's AgentRoleGrid.tsx into pm-go tokens. Two live levels:
     L1  a responsive grid of role cards (avatar + corner status glyph, name,
         active/idle pill, current-work rows, model chip, last-activity age),
         with a dimmed "declared roles" strip below for catalog-only roles.
     L2  a role detail (breadcrumb back, identity + contract, Processes list, and
         READ-ONLY settings with env-key provenance). Level 3 is a JUMP to the
         Consoles surface (#consoles/<sessionId>) — no embedded terminal here.

   Data join (client-side): the declared role catalog (/api/roles), the resolved
   per-role config (/api/config), the 10s state snapshot (S.snap.agents), and the
   2s shared sessions feed (core/sessions-feed.js). The grid re-render is
   signature-gated and does zero work while the surface is hidden. */

import { S, esc, escAttr, icon, relTime } from "../app.js";
import { subscribe as subscribeSessions, feedState } from "../core/sessions-feed.js";
import { writeRoute } from "../core/router.js";

const shortRun = (r) => String(r || "").replace(/^ORIGIN-|^RUN-/, "").slice(0, 16);

// The eight cards with runtime evidence, in grid order. eyebrow layer follows the
// operating model (planner/integration/auditor are L1; the rest L2). configRole maps
// a card to its /api/config role for the model chip + settings provenance.
const CARDS = [
  { id: "origin", name: "origin", initials: "OR", tone: "ink", eyebrow: "L0 · SUPERVISOR", configRole: null },
  { id: "planner", name: "planner", initials: "PL", tone: "blue", eyebrow: "L1 · ORCHESTRATION", configRole: "planner", limits: true },
  { id: "developer", name: "developer", initials: "DV", tone: "soft", eyebrow: "L2 · WORKER", configRole: "implementer", limits: true },
  { id: "auditor", name: "auditor", initials: "AU", tone: "blue", eyebrow: "L1 · AUDIT", configRole: "auditor" },
  { id: "reviewer", name: "reviewer", initials: "RV", tone: "soft", eyebrow: "L2 · REVIEW", configRole: "auditor" },
  { id: "integration-worker", name: "integration", initials: "IG", tone: "blue", eyebrow: "L1 · INTEGRATION", configRole: null },
  { id: "recovery-worker", name: "recovery", initials: "RC", tone: "soft", eyebrow: "L2 · WORKER", configRole: "implementer" },
  { id: "decider", name: "decider", initials: "DC", tone: "soft", eyebrow: "L2 · WORKER", configRole: "decider" },
];
const CARD_BY_ID = Object.fromEntries(CARDS.map((c) => [c.id, c]));
// catalog roles with no runtime evidence → dimmed, non-drillable declared strip
const DECLARED_ONLY = ["test-engineer", "documentation-worker"];

const AG = {
  started: false,
  visible: false,
  config: null, configInflight: false,
  roles: null, rolesInflight: false,
  sessions: [], byId: new Map(), generatedAt: null,
  level: 1,               // 1 = grid, 2 = detail
  roleId: null,           // detail role
  highlightSession: null, // deep-link process highlight
  sig: null,
};

// ------------------------------------------------------------- data fetch -----
async function fetchConfig(force) {
  if (AG.configInflight || (AG.config && !force)) return;
  AG.configInflight = true;
  try { const r = await fetch("/api/config", { cache: "no-store" }); if (r.ok) AG.config = await r.json(); }
  catch (e) { /* leave last good */ } finally { AG.configInflight = false; render(); }
}
function ensureRoles() {
  if (AG.roles) return;
  if (S.roleCatalog) { AG.roles = S.roleCatalog; return; }
  if (AG.rolesInflight) return;
  AG.rolesInflight = true;
  fetch("/api/roles", { cache: "no-store" }).then((r) => r.ok ? r.json() : null).then((j) => { if (j) { AG.roles = j; S.roleCatalog = S.roleCatalog || j; } })
    .catch(() => {}).finally(() => { AG.rolesInflight = false; render(); });
}
function workerCatalog(id) { return ((AG.roles && AG.roles.workers) || []).find((w) => w.id === id) || null; }

// ------------------------------------------------- session → card mapping -----
function cardIdsForSession(s) {
  const out = [];
  if (s.kind === "origin" || s.id === "origin") { out.push("origin"); return out; }
  const role = String(s.role || "");
  if (s.kind === "planner" || role === "planner") out.push("planner");
  else if (s.kind === "integration" || role === "integration-worker") out.push("integration-worker");
  else if (s.kind === "audit") { if (role === "session-decider" || role === "decider") out.push("decider"); else out.push("auditor"); }
  else if (role === "recovery-worker") out.push("recovery-worker");
  else if (role === "session-decider" || role === "decider") out.push("decider");
  else if (s.kind === "worker" || role === "l2-developer") out.push("developer");
  // a run with a paired reviewer also counts toward the reviewer card
  if (s.sessionMeta && s.sessionMeta.reviewer) out.push("reviewer");
  return out;
}
function sessionsForCard(id) {
  return AG.sessions.filter((s) => cardIdsForSession(s).includes(id))
    .sort((a, b) => String(b.updatedAt || "").localeCompare(String(a.updatedAt || "")));
}
function liveCountForCard(id) { return sessionsForCard(id).filter((s) => s.live).length; }

// snapshot-derived binding: is this role currently bound/active (not just live)?
function cardBound(id) {
  const ag = (S.snap && S.snap.agents) || {};
  if (id === "origin") { const l0 = ag.l0; return !!l0 && l0.state === "active" && !l0.stop; }
  if (id === "planner" || id === "integration-worker") return (ag.l1 || []).some((a) => a.l1Active || a.l1Lease);
  if (id === "developer" || id === "recovery-worker") return (ag.l2 || []).some((t) => t.state === "active" || (t.leaseStatus && t.leaseStatus !== "none"));
  return liveCountForCard(id) > 0;
}
function cardActive(id) { return liveCountForCard(id) > 0 || cardBound(id); }

// current-work rows for a card (≤3)
function cardWork(id) {
  const ag = (S.snap && S.snap.agents) || {};
  const rows = [];
  if (id === "planner" || id === "integration-worker") {
    for (const a of (ag.l1 || [])) if (a.l1Active) rows.push({ label: a.area, state: "active" });
  } else if (id === "developer" || id === "recovery-worker") {
    for (const t of (ag.l2 || [])) if (t.state === "active" || t.state === "blocked" || t.state === "failed") rows.push({ label: t.title || t.id || t.area, state: t.state });
  }
  // fall back to (or augment with) live sessions' idents
  for (const s of sessionsForCard(id)) {
    if (!s.live) continue;
    const label = s.taskId || s.node || s.area || shortRun(s.runId);
    if (label && !rows.some((r) => r.label === label)) rows.push({ label, state: s.state });
  }
  return rows.slice(0, 3);
}

// model chip text for a card (from /api/config)
function cardConfigRole(card) { return card.configRole; }
function cardModel(card) {
  const role = cardConfigRole(card);
  if (!role || !AG.config || !AG.config.roles) return null;
  const r = AG.config.roles[role];
  if (!r || !r.model) return null;
  return r.effort ? r.model + " · " + r.effort : r.model;
}
function lastActivity(id) {
  const list = sessionsForCard(id);
  return list.length ? relTime(list[0].updatedAt, AG.generatedAt) : "—";
}

// --------------------------------------------------------------- glyph --------
function statusGlyph(id) {
  if (liveCountForCard(id) > 0) return `<span class="ag-glyph ag-glyph-run" title="running">◔</span>`;
  if (cardBound(id)) return `<span class="ag-glyph ag-glyph-on" title="active"><span class="tone-dot" data-tone="success"></span></span>`;
  return `<span class="ag-glyph ag-glyph-idle" title="idle"></span>`;
}

// ------------------------------------------------------------ level 1 grid ----
function cardHtml(card) {
  const active = cardActive(card.id);
  const running = liveCountForCard(card.id);
  const work = cardWork(card.id);
  const model = cardModel(card);
  const workRows = work.map((w) =>
    `<div class="ag-work-row"><span class="tone-dot" data-tone="${esc(toneForState(w.state))}"></span><span class="mono ag-work-id">${esc(w.label)}</span></div>`).join("");
  return `<button class="ag-card" data-role="${escAttr(card.id)}" data-active="${active}" aria-label="${escAttr(card.name)} role — ${active ? "active" : "idle"}">
    <div class="ag-avatar-wrap">
      <span class="ag-avatar" data-tone="${card.tone}">${esc(card.initials)}</span>
      <span class="ag-avatar-glyph">${statusGlyph(card.id)}</span>
    </div>
    <span class="co-eyebrow ag-eyebrow">${esc(card.eyebrow)}</span>
    <span class="ag-name">${esc(card.name)}</span>
    <span class="ag-pill" data-active="${active}">${active ? "active" : "idle"}${running ? ` · ${running} running` : ""}</span>
    ${workRows ? `<div class="ag-work">${workRows}</div>` : ""}
    ${model ? `<span class="ag-model mono">${esc(model)}</span>` : ""}
    <span class="ag-lastact mono">${esc(lastActivity(card.id))} ago</span>
  </button>`;
}

function toneForState(state) {
  const st = String(state || "");
  if (st === "failed" || st === "blocked") return "error";
  if (st === "awaiting" || st === "stale") return "warn";
  if (st === "active") return "active";
  if (st === "integrated") return "success";
  return "idle";
}

function declaredHtml(id) {
  const w = workerCatalog(id);
  const name = w ? (w.label || w.id) : id;
  return `<div class="ag-declared-tile" title="declared role — no runtime evidence"><span class="ag-declared-initials">${esc((name || "").slice(0, 2).toUpperCase())}</span><span class="ag-declared-name">${esc(name)}</span></div>`;
}

function renderGrid() {
  const host = document.getElementById("ag-body");
  if (!host) return;
  host.innerHTML =
    `<div class="ag-grid" id="ag-grid">${CARDS.map(cardHtml).join("")}</div>
     <div class="ag-declared">
       <div class="co-eyebrow">declared roles</div>
       <div class="ag-declared-row">${DECLARED_ONLY.map(declaredHtml).join("")}</div>
     </div>`;
}

// ------------------------------------------------------------ level 2 detail --
function detailHtml(card) {
  const w = workerCatalog(card.id);
  const layer = (AG.roles && AG.roles.layers || []).find((l) => card.eyebrow.startsWith(l.id));
  const contract = (w && (w.summary || (w.disciplines || []).join(" · "))) || (layer && layer.summary) || "";
  const active = cardActive(card.id);
  const running = liveCountForCard(card.id);
  const tools = (w && w.typicalTools) || [];
  const writes = w && w.writes;

  // processes: live first, then recent, ≤6
  const procs = sessionsForCard(card.id).sort((a, b) => (b.live - a.live) || String(b.updatedAt || "").localeCompare(String(a.updatedAt || ""))).slice(0, 6);
  const procRows = procs.map((s) => {
    const glyph = s.live ? `<span class="ag-glyph ag-glyph-run">◔</span>` : `<span class="tone-dot" data-tone="${esc(toneForState(s.state))}"></span>`;
    const model = s.model ? `<span class="ag-proc-model mono">${esc(s.model)}${s.effort ? " · " + esc(s.effort) : ""}</span>` : "";
    const tail = s.exitCode != null ? `exit ${esc(s.exitCode)}` : relTime(s.updatedAt, AG.generatedAt) + " ago";
    const hi = AG.highlightSession && AG.highlightSession === s.id ? " ag-proc-hi" : "";
    return `<button class="ag-proc-row${hi}" data-ag-proc="${escAttr(s.id)}" aria-label="open console for ${escAttr(s.taskId || shortRun(s.runId) || s.id)}">
      ${glyph}
      <span class="mono ag-proc-id">${esc(s.taskId || s.node || s.area || shortRun(s.runId) || s.id)}</span>
      ${s.phase ? `<span class="ag-proc-phase">${esc(s.phase)}</span>` : ""}
      ${model}
      <span class="ag-proc-tail mono">${esc(tail)}</span>
      ${icon("i-chev", "ag-proc-chev")}
    </button>`;
  }).join("") || `<div class="section-empty">no processes recorded</div>`;

  // settings — read-only, with env-key provenance
  const settings = settingsHtml(card);

  return `
    <nav class="ag-breadcrumb"><button class="ag-crumb" data-ag-back="1">Agents</button><span class="ag-crumb-sep">/</span><span class="ag-crumb-cur">${esc(card.name)}</span></nav>
    <div class="ag-detail-head">
      <span class="ag-avatar ag-avatar-lg" data-tone="${card.tone}">${esc(card.initials)}</span>
      <div class="ag-detail-idn">
        <span class="co-eyebrow">${esc(card.eyebrow)}</span>
        <div class="ag-detail-title"><span class="ag-detail-name">${esc(card.name)}</span><span class="ag-pill" data-active="${active}">${active ? "active" : "idle"}${running ? ` · ${running} running` : ""}</span></div>
        ${contract ? `<p class="ag-contract">${esc(contract)}</p>` : ""}
        <div class="ag-idn-meta">
          ${tools.length ? `<span class="ag-tools">${tools.map((t) => `<span class="ag-tool mono">${esc(t)}</span>`).join("")}</span>` : ""}
          ${writes != null ? `<span class="ag-writes" data-writes="${!!writes}">${writes ? "writes" : "read-only"}</span>` : ""}
        </div>
      </div>
    </div>
    <section class="ag-section"><div class="co-eyebrow">processes · ${procs.length}</div><div class="ag-procs">${procRows}</div></section>
    <section class="ag-section"><div class="co-eyebrow">settings</div>${settings}</section>`;
}

function settingsHtml(card) {
  const role = cardConfigRole(card);
  const rows = [];
  if (role && AG.config && AG.config.roles && AG.config.roles[role]) {
    const r = AG.config.roles[role];
    const src = r.source || {};
    if (r.model) rows.push(["model", r.model, src.model, src.modelTier]);
    if (r.effort) rows.push(["effort", r.effort, src.effort, src.effortTier]);
  }
  if (card.limits && AG.config && AG.config.limits) {
    const L = AG.config.limits;
    const lim = [["max concurrent", L.maxConcurrent], ["dispatch / cycle", L.maxDispatch], ["l1 parallel", L.l1Parallel]];
    for (const [k, v] of lim) if (v != null) rows.push([k, String(v), null, "config"]);
  }
  const body = rows.map(([k, v, key, tier]) =>
    `<div class="ag-set-row"><span class="ag-set-key">${esc(k)}</span><span class="ag-set-val mono">${esc(v)}</span>${key ? `<span class="ag-set-src mono" title="${esc(tier || "")}">${esc(key)}</span>` : `<span class="ag-set-src mono">${esc(tier || "")}</span>`}</div>`).join("");
  if (!rows.length) return `<div class="section-empty">no model settings for this role</div>`;
  return `<div class="ag-settings">${body}</div><div class="ag-set-foot">read-only · configured in gluerun.config.json — edit the file to change</div>`;
}

// ------------------------------------------------------------- render ---------
function signature() {
  const sessSig = AG.sessions.map((s) => [s.id, s.state, s.live, s.updatedAt, s.model]).join("|");
  const snapSig = JSON.stringify((S.snap && S.snap.agents) ? { l0: (S.snap.agents.l0 || {}).state, l1: (S.snap.agents.l1 || []).map((a) => [a.area, a.l1Active]), l2: (S.snap.agents.l2 || []).length } : null);
  const cfgSig = AG.config ? AG.config.generatedAt : "nc";
  return [AG.level, AG.roleId, AG.highlightSession, sessSig, snapSig, cfgSig, AG.roles ? 1 : 0].join("::");
}

function render() {
  if (!AG.visible) return;
  const sig = signature();
  if (sig === AG.sig) return;
  AG.sig = sig;
  const host = document.getElementById("ag-body");
  if (!host) return;
  if (AG.level === 2 && AG.roleId && CARD_BY_ID[AG.roleId]) {
    host.innerHTML = detailHtml(CARD_BY_ID[AG.roleId]);
  } else {
    renderGrid();
  }
}

// ------------------------------------------------------------- nav ------------
function openRole(id, opts) {
  if (!CARD_BY_ID[id]) return;
  AG.level = 2; AG.roleId = id;
  AG.highlightSession = (opts && opts.session) || null;
  AG.sig = null;
  if (!opts || opts.route !== false) writeRoute("agents", id, AG.highlightSession || null, null);
  render();
}
function backToGrid() {
  AG.level = 1; AG.roleId = null; AG.highlightSession = null; AG.sig = null;
  writeRoute("agents", null, null, null);
  render();
}
function jumpToConsole(sessionId) {
  // Level 3 is a JUMP: push a Consoles deep link (new history entry so browser-back
  // returns to this #agents/<role> detail). The router opens it pinned + soloed.
  location.hash = "#consoles/" + sessionId;
}

// ------------------------------------------------------------- feed -----------
function onFeed(state) {
  AG.sessions = state.sessions || [];
  AG.byId = state.byId || new Map(AG.sessions.map((s) => [s.id, s]));
  AG.generatedAt = state.generatedAt || null;
  render();
}

// ------------------------------------------------------------- mount ----------
function mount() {
  const surf = document.getElementById("surface-agents");
  if (!surf) return;
  surf.innerHTML = "";
  surf.classList.add("ag-surface");
  surf.innerHTML = `<div class="ag-body" id="ag-body"></div>`;
  surf.addEventListener("click", (e) => {
    const back = e.target.closest("[data-ag-back]");
    if (back) { backToGrid(); return; }
    const proc = e.target.closest("[data-ag-proc]");
    if (proc) { jumpToConsole(proc.dataset.agProc); return; }
    const card = e.target.closest(".ag-card");
    if (card && card.dataset.active !== undefined) { openRole(card.dataset.role); return; }
  });
}

// ------------------------------------------------------------- exports --------
export function initAgents() {
  if (AG.started) return; AG.started = true;
  mount();
  subscribeSessions(onFeed, () => AG.visible);
}

export function setAgentsActive(on) {
  AG.visible = on;
  if (on) {
    ensureRoles();
    fetchConfig(false);
    AG.sig = null;
    onFeed(feedState());
    render();
  }
}

// Router hook — #agents[/<roleId>[/<sessionId>]]
export function agentsRoute(route) {
  const role = route && route.role;
  const session = route && route.session;
  if (role && CARD_BY_ID[role]) openRole(role, { session, route: false });
  else backToGridSilent();
}
function backToGridSilent() { AG.level = 1; AG.roleId = null; AG.highlightSession = null; AG.sig = null; render(); }

// Called from the 10s snapshot dispatcher (via main.js) — signature-gated, and a
// no-op while hidden. On Refresh the config is re-pulled.
export function agentsTick() {
  if (!AG.visible) return;
  fetchConfig(false);   // module-cached; loaded once
  render();
}
