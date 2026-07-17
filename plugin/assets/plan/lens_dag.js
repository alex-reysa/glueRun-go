/* plan/lens_dag.js — the DAG lens as a card-based pipeline. White rounded pill
   cards on a dotted-grid canvas, each with a leading status glyph, the node id
   in confident mono, an optional ×N task-count badge, and an attribution line
   (owner-area dot + name) underneath. Stage columns keep the intra-stage
   longest-path layout; soft edge-to-edge bezier edges carry no arrowheads at
   rest and grow directional markers only under hover tracing (blue upstream ·
   green downstream). A sticky progress footer summarises gate coverage and a
   floating fit button scales the whole pipeline to the pane width. Layout is
   rebuilt only when the DAG or a stage-collapse changes (signature-gated);
   hover, selection and fit are attribute/style passes over the prebuilt DOM. */

import { esc, escAttr, icon, select } from "../app.js";
import { bus } from "../core/bus.js";
import { getDag } from "./data.js";

// card geometry — fixed-width cards, ellipsized ids
const NODE_W = 190;      // card width
const NODE_H = 40;       // card height (pill)
const ATTR_H = 18;       // attribution line under the card
const ROW_H = 84;        // vertical stride between rows in a column
const COLUMN_W = 260;    // horizontal stride between depth columns
const MARGIN_X = 40;     // left/right canvas pad
const CARD_TOP = 56;     // first card top (below the ribbon)
const RIBBON_TOP = 12;
const SUM_W = 210;       // collapsed-stage summary card width
const FIT_KEY = "gluerun.plan.dag.fit";

let pane = null;
let sigLast = null;
let selectedId = null;
let collapsed = new Set();     // collapsed stage ids
let fitOn = (() => { try { return localStorage.getItem(FIT_KEY) === "1"; } catch (e) { return false; } })();

// build artifacts
let nodesById = {}, positions = {}, zones = {}, ancestors = {}, descendants = {};
let stageOrder = [], nodeEls = {}, attrEls = {}, edgeEls = [], detailEl = null;
let scrollEl = null, stageEl = null, wrapEl = null, fitBtn = null;
let stageNatW = 0, stageNatH = 0, ro = null;

// --------------------------------------------------------------- layout ----
function computeAncestry(dag) {
  const byId = {}; for (const n of dag.nodes) byId[n.id] = n;
  const children = {};
  for (const n of dag.nodes) for (const d of n.dependsOn || []) (children[d] = children[d] || []).push(n.id);
  const walk = (start, next) => {
    const out = new Set(); const stack = [...next(start)];
    while (stack.length) { const id = stack.pop(); if (id && !out.has(id)) { out.add(id); stack.push(...next(id)); } }
    return out;
  };
  ancestors = {}; descendants = {};
  for (const n of dag.nodes) {
    ancestors[n.id] = walk(n.id, (id) => byId[id].dependsOn || []);
    descendants[n.id] = walk(n.id, (id) => children[id] || []);
  }
  nodesById = byId;
}

function computeLayout(dag) {
  stageOrder = (dag.stages || []).map((s) => s.id);
  const nodesByStage = {};
  for (const id of stageOrder) nodesByStage[id] = dag.nodes.filter((n) => n.stage === id);

  // intra-stage longest-path depth (same-stage deps only)
  const depth = {};
  const visit = (id) => {
    if (depth[id] != null) return depth[id];
    const n = nodesById[id];
    const same = (n.dependsOn || []).filter((d) => nodesById[d] && nodesById[d].stage === n.stage);
    depth[id] = same.length ? 1 + Math.max(...same.map(visit)) : 0;
    return depth[id];
  };
  for (const n of dag.nodes) visit(n.id);

  // per-stage column geometry
  const geom = {}; let col = 0;
  for (const id of stageOrder) {
    const ids = nodesByStage[id];
    const width = (ids.length ? Math.max(...ids.map((n) => depth[n.id])) : 0) + 1;
    geom[id] = { startCol: col, width };
    col += width;                                  // columns abut; stage bands read as groups
  }

  // group by (stage, depth) and find the tallest column to centre against
  const groups = {}; let maxRows = 1;
  for (const id of stageOrder) {
    for (const n of nodesByStage[id]) {
      const key = id + "|" + depth[n.id];
      (groups[key] = groups[key] || []).push(n.id);
    }
  }
  for (const ids of Object.values(groups)) maxRows = Math.max(maxRows, ids.length);
  const CY0 = CARD_TOP + NODE_H / 2 + ((maxRows - 1) * ROW_H) / 2;

  positions = {};
  for (const [key, ids] of Object.entries(groups)) {
    const [sid, dRaw] = key.split("|");
    ids.sort((a, b) => a.localeCompare(b));
    const k = ids.length;
    ids.forEach((nid, i) => {
      positions[nid] = {
        x: MARGIN_X + (geom[sid].startCol + Number(dRaw)) * COLUMN_W,
        cy: CY0 - ((k - 1) * ROW_H) / 2 + i * ROW_H,
      };
    });
  }

  zones = {};
  for (const id of stageOrder) {
    const ids = nodesByStage[id].map((n) => n.id);
    const lefts = ids.map((nid) => positions[nid].x);
    const passed = ids.filter((nid) => (nodesById[nid].gate || {}).status === "passed").length;
    if (ids.length) {
      const x0 = Math.min(...lefts), x1 = Math.max(...lefts) + NODE_W;
      zones[id] = { ids, x0, x1, cx: (x0 + x1) / 2, cy: CY0, passed, total: ids.length };
    } else {
      zones[id] = { ids: [], x0: MARGIN_X, x1: MARGIN_X + NODE_W, cx: MARGIN_X, cy: CY0, passed: 0, total: 0 };
    }
  }

  const maxLeft = Math.max(MARGIN_X, ...Object.values(positions).map((p) => p.x));
  stageNatW = maxLeft + NODE_W + MARGIN_X;
  stageNatH = CARD_TOP + (maxRows - 1) * ROW_H + NODE_H + ATTR_H + 28;
  return { stages: dag.stages || [] };
}

// classification of a node's resting status glyph per the shared vocabulary.
// passed wins (calm reference look), then hard failures, live work, frontier,
// evaluation kind, and finally the quiet queued ring.
function statusOf(n) {
  const g = n.gate || {};
  const c = (n.tasks && n.tasks.counts) || {};
  const status = g.status;
  const active = (c.active || 0) > 0;
  const isEval = n.kind === "evaluation";
  if (status === "passed") return "done";
  if (status === "failed" || status === "blocked" || status === "invalid") return "failed";
  if (active) return "active";
  if (!status && n.frontier) return "frontier";
  if (isEval) return "eval";
  return "queued";
}

function glyphHtml(kind) {
  if (kind === "done") return `<span class="pdc-glyph g-done">${icon("i-check")}</span>`;
  if (kind === "active") return `<span class="pdc-glyph g-active"><i class="pdc-pulse"></i></span>`;
  if (kind === "frontier") return `<span class="pdc-glyph g-frontier"><i></i></span>`;
  if (kind === "eval") return `<span class="pdc-glyph g-eval"><i></i></span>`;
  if (kind === "failed") return `<span class="pdc-glyph g-failed">&times;</span>`;
  return `<span class="pdc-glyph g-queued"><i></i></span>`;
}

const renderKey = (id) => (collapsed.has(nodesById[id].stage) ? "PH:" + nodesById[id].stage : id);
function effRect(id) {
  const st = nodesById[id].stage;
  if (collapsed.has(st)) { const z = zones[st]; return { left: z.cx - SUM_W / 2, right: z.cx + SUM_W / 2, cy: z.cy }; }
  const p = positions[id];
  return { left: p.x, right: p.x + NODE_W, cy: p.cy };
}

// card-edge to card-edge cubic bezier (right of source → left of target)
function curve(fromId, toId) {
  const a = effRect(fromId), b = effRect(toId);
  const fx = a.right, fy = a.cy, tx = b.left, ty = b.cy;
  const k = Math.max(40, (tx - fx) * 0.4);
  return `M${fx},${fy} C${fx + k},${fy} ${tx - k},${ty} ${tx},${ty}`;
}

// --------------------------------------------------------------- build -----
function build() {
  const dag = getDag();
  if (!pane) return;
  if (!dag || !(dag.nodes || []).length) { pane.innerHTML = `<div class="plan-lens-empty">no DAG nodes to graph</div>`; sigLast = "empty"; return; }
  if (ro) { try { ro.disconnect(); } catch (e) {} ro = null; }
  computeAncestry(dag);
  computeLayout(dag);

  // dedup edges under the current collapse state
  const seen = new Set(); const edges = [];
  for (const e of dag.edges || []) {
    const fk = renderKey(e.from), tk = renderKey(e.to);
    if (fk === tk) continue;
    const key = fk + "->" + tk;
    if (!seen.has(key)) { seen.add(key); edges.push({ from: e.from, to: e.to }); }
  }

  // ribbons (collapse toggles) + alternating full-height column tints
  let ribbons = "", tints = "";
  stageOrder.forEach((sid, i) => {
    const z = zones[sid];
    const left = z.x0 - 8, width = z.x1 - z.x0 + 16;
    const short = sid.split("-")[0];
    ribbons += `<button class="plan-dag-ribbon" data-stage="${escAttr(sid)}" style="left:${left}px;top:${RIBBON_TOP}px;width:${width}px" aria-expanded="${!collapsed.has(sid)}">
      <span class="pdr-chev">${icon("i-chev")}</span><span class="pdr-id">${esc(short)}</span>
      <span class="pdr-count mono">${z.passed}/${z.total}</span></button>`;
    if (i % 2 === 0) tints += `<div class="plan-dag-tint" style="left:${left}px;width:${width}px;top:${RIBBON_TOP + 30}px;bottom:12px"></div>`;
  });

  // svg edges — no markers at rest; hover tracing swaps them in
  const edgePaths = edges.map((e, i) => {
    const a = effRect(e.from), b = effRect(e.to);
    if (a.right === b.right && a.cy === b.cy && a.left === b.left) return "";
    return `<path data-edge="${i}" data-from="${escAttr(e.from)}" data-to="${escAttr(e.to)}" d="${curve(e.from, e.to)}" fill="none" stroke="var(--n-300)" stroke-width="1.5" opacity="0.7"/>`;
  }).join("");
  const svg = `<svg width="${stageNatW}" height="${stageNatH}" class="plan-dag-edges">
    <defs>
      <marker id="dag-up" markerWidth="9" markerHeight="9" refX="6" refY="4" orient="auto" markerUnits="userSpaceOnUse"><path d="M1,1.5 L6,4 L1,6.5" fill="none" stroke="var(--tone-blue-dot)" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></marker>
      <marker id="dag-dn" markerWidth="9" markerHeight="9" refX="6" refY="4" orient="auto" markerUnits="userSpaceOnUse"><path d="M1,1.5 L6,4 L1,6.5" fill="none" stroke="var(--tone-green-dot)" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></marker>
    </defs>${edgePaths}</svg>`;

  // cards (expanded stages only) — glyph + id + ×N badge, attribution line under
  let cards = "";
  for (const n of dag.nodes) {
    if (collapsed.has(n.stage)) continue;
    const p = positions[n.id];
    const top = p.cy - NODE_H / 2;
    const kind = statusOf(n);
    const c = (n.tasks && n.tasks.counts) || {};
    const badge = (c.total || 0) > 1 ? `<span class="pdc-badge mono">&times;${c.total}</span>` : "";
    const dotTone = n.kind === "evaluation" ? "coral" : "neutral";
    cards += `<div class="plan-dag-cardwrap" style="left:${p.x}px;top:${top}px">
      <button class="plan-dag-card" data-node="${escAttr(n.id)}" data-selected="false" data-status="${kind}">
        ${glyphHtml(kind)}<span class="pdc-name mono">${esc(n.id)}</span>${badge}</button>
      <div class="plan-dag-attr" data-attr="${escAttr(n.id)}"><span class="pdc-avatar" data-tone="${dotTone}"></span><span class="pdc-owner">${esc(n.area)}</span></div>
    </div>`;
  }

  // collapsed stage summaries (match the card look)
  let summaries = "";
  for (const sid of stageOrder) {
    if (!collapsed.has(sid)) continue;
    const z = zones[sid];
    summaries += `<button class="plan-dag-summary" data-stage="${escAttr(sid)}" style="left:${z.cx - SUM_W / 2}px;top:${z.cy - 26}px;width:${SUM_W}px">
      <span class="pds-eyebrow">${esc(sid.split("-")[0])}</span>
      <span class="pds-name">${esc(sid.replace(/^S\d+-/, ""))}</span>
      <span class="pds-meta mono">${z.total} nodes · ${z.passed}/${z.total} gated</span></button>`;
  }

  // progress footer dots (all nodes, stage order)
  let dots = "", pTotal = 0, pPassed = 0;
  for (const sid of stageOrder) {
    for (const nid of (zones[sid].ids || [])) {
      const n = nodesById[nid]; const g = n.gate || {}; const c = (n.tasks && n.tasks.counts) || {};
      pTotal++;
      let cls = "hollow";
      if (g.status === "passed") { cls = "pass"; pPassed++; }
      else if ((c.active || 0) > 0) cls = "active";
      dots += `<i class="pdf-dot ${cls}"></i>`;
    }
  }

  pane.style.overflow = "hidden";
  pane.innerHTML =
    `<div class="plan-scroll-host">
       <div class="plan-dag-scroll">
         <div class="plan-dag-stagewrap">
           <div class="plan-dag-stage" style="width:${stageNatW}px;height:${stageNatH}px">
             ${tints}${ribbons}${svg}${cards}${summaries}
             <div class="plan-detail-card plan-dag-detail" hidden></div>
           </div>
         </div>
       </div>
       <div class="plan-fade left"></div>
       <div class="plan-fade right"></div>
       <button class="plan-dag-fit" aria-pressed="${fitOn}" title="Fit to width">${icon("i-expand")}</button>
       <button class="plan-dag-progress" title="Plan overview">${dots}<span class="pdf-count mono">${pPassed}/${pTotal} gates</span></button>
     </div>`;

  // cache refs
  nodeEls = {}; attrEls = {}; edgeEls = [];
  pane.querySelectorAll(".plan-dag-card").forEach((el) => { nodeEls[el.dataset.node] = el; });
  pane.querySelectorAll(".plan-dag-attr").forEach((el) => { attrEls[el.dataset.attr] = el; });
  pane.querySelectorAll(".plan-dag-edges path[data-edge]").forEach((el) => edgeEls.push({ el, from: el.dataset.from, to: el.dataset.to }));
  detailEl = pane.querySelector(".plan-dag-detail");
  scrollEl = pane.querySelector(".plan-dag-scroll");
  stageEl = pane.querySelector(".plan-dag-stage");
  wrapEl = pane.querySelector(".plan-dag-stagewrap");
  fitBtn = pane.querySelector(".plan-dag-fit");

  wire();
  applyFit();
  repaint(null);
  if (window.ResizeObserver) { ro = new ResizeObserver(() => { if (fitOn) applyFit(); measureFades(); }); ro.observe(pane); }
}

// --------------------------------------------------------------- fit -------
function applyFit() {
  if (!stageEl || !wrapEl || !scrollEl) return;
  let k = 1;
  if (fitOn) {
    const paneW = scrollEl.clientWidth || stageNatW;
    // Lower legibility floor is 0.25 (not 0.45): this plan is a wide, near-linear
    // 19-column pipeline (~4950px), so a 0.45 floor could not remove horizontal
    // scroll on a ~1360px pane. 0.25 lets the whole graph fit while still guarding
    // against microscopic scaling on pathologically wide DAGs.
    k = Math.max(0.25, Math.min(paneW / stageNatW, 1));
  }
  stageEl.style.transformOrigin = "top left";
  stageEl.style.transform = k === 1 ? "none" : `scale(${k})`;
  wrapEl.style.width = stageNatW * k + "px";
  wrapEl.style.height = stageNatH * k + "px";
  if (fitBtn) fitBtn.setAttribute("aria-pressed", String(fitOn));
  measureFades();
}

// --------------------------------------------------------------- paint -----
function repaint(focusId) {
  const dag = getDag(); if (!dag) return;
  let up = null, down = null, all = null;
  if (focusId && nodeEls[focusId]) { up = ancestors[focusId]; down = descendants[focusId]; all = new Set([focusId, ...up, ...down]); }

  for (const [id, el] of Object.entries(nodeEls)) {
    let op = 1, ring = "hover", z = "3";
    if (all) {
      if (id === focusId) { ring = "focus"; z = "8"; }
      else if (up.has(id)) { ring = "up"; z = "6"; }
      else if (down.has(id)) { ring = "down"; z = "6"; }
      else { op = 0.28; ring = "none"; }
    } else if (id === selectedId) { ring = "sel"; z = "7"; }
    el.style.opacity = op;
    el.dataset.trace = ring;
    el.dataset.selected = String(id === selectedId);
    el.parentElement.style.zIndex = z;
  }
  for (const [id, el] of Object.entries(attrEls)) el.style.opacity = all && !all.has(id) ? "0.22" : "1";
  for (const e of edgeEls) {
    let stroke = "var(--n-300)", w = "1.5", op = "0.7", mk = "";
    if (all) {
      const upEdge = (e.to === focusId || up.has(e.to)) && (e.from === focusId || up.has(e.from));
      const dnEdge = (e.from === focusId || down.has(e.from)) && (e.to === focusId || down.has(e.to));
      if (upEdge) { stroke = "var(--tone-blue-dot)"; w = "1.8"; op = "0.95"; mk = "url(#dag-up)"; }
      else if (dnEdge) { stroke = "var(--tone-green-dot)"; w = "1.8"; op = "0.95"; mk = "url(#dag-dn)"; }
      else { op = "0.08"; }
    }
    e.el.setAttribute("stroke", stroke); e.el.setAttribute("stroke-width", w);
    e.el.setAttribute("opacity", op);
    if (mk) e.el.setAttribute("marker-end", mk); else e.el.removeAttribute("marker-end");
  }
  if (focusId && detailEl) showDetail(focusId); else if (detailEl) detailEl.hidden = true;
}

function showDetail(id) {
  const n = nodesById[id]; if (!n || !detailEl) return;
  const p = positions[id]; if (!p || collapsed.has(n.stage)) { detailEl.hidden = true; return; }
  const g = n.gate || {}; const c = (n.tasks && n.tasks.counts) || {};
  const deps = (n.dependsOn || []).join(" · ") || "—";
  detailEl.innerHTML =
    `<div class="plan-detail-head"><span class="mono" style="font-size:11px;color:var(--text-secondary)">${esc(n.id)}</span>
       <span class="plan-chip">${esc(n.area)}</span>
       <span style="margin-left:auto;font:600 9px var(--font-sans);letter-spacing:0.05em;text-transform:uppercase;color:var(--text-meta)">${esc(g.status || "absent")}</span></div>
     <div class="plan-detail-title">${esc(n.stage)}${n.kind ? " · " + esc(n.kind) : ""}</div>
     <div class="plan-detail-rule"></div>
     <div class="plan-detail-row"><span class="pdl">Depends on</span><span class="pdv mono" style="color:var(--tone-blue-fg)">${esc(deps)}</span></div>
     <div class="plan-detail-row"><span class="pdl">Unblocks</span><span class="pdv" style="color:var(--tone-green-fg)">${(descendants[id] || new Set()).size} downstream</span></div>
     <div class="plan-detail-row"><span class="pdl">Tasks</span><span class="pdv mono">${c.integrated || 0}/${c.total || 0}</span></div>`;
  const left = Math.min(Math.max(p.x - 40, 8), stageNatW - 272);
  detailEl.style.left = left + "px";
  detailEl.style.top = (p.cy > stageNatH / 2 ? p.cy - NODE_H / 2 - 12 - 176 : p.cy + NODE_H / 2 + ATTR_H + 12) + "px";
  detailEl.hidden = false;
}

// --------------------------------------------------------------- wire ------
function wire() {
  stageEl.addEventListener("click", (e) => {
    const ribbon = e.target.closest("[data-stage]");
    if (ribbon) { const s = ribbon.dataset.stage; if (collapsed.has(s)) collapsed.delete(s); else collapsed.add(s); sigLast = null; build(); return; }
    const node = e.target.closest("[data-node]");
    if (node && bus.onNodeSelect) bus.onNodeSelect(node.dataset.node);
  });
  stageEl.addEventListener("pointerover", (e) => { const node = e.target.closest("[data-node]"); if (node) repaint(node.dataset.node); });
  stageEl.addEventListener("pointerout", (e) => {
    const node = e.target.closest("[data-node]");
    if (node && !stageEl.contains(e.relatedTarget && e.relatedTarget.closest && e.relatedTarget.closest("[data-node]"))) repaint(null);
  });
  scrollEl.addEventListener("scroll", measureFades);
  if (fitBtn) fitBtn.addEventListener("click", () => {
    fitOn = !fitOn;
    try { localStorage.setItem(FIT_KEY, fitOn ? "1" : "0"); } catch (e) {}
    applyFit();
  });
  const prog = pane.querySelector(".plan-dag-progress");
  if (prog) prog.addEventListener("click", () => select("overview", "plan"));
}

function measureFades() {
  if (!scrollEl || !pane) return;
  const max = scrollEl.scrollWidth - scrollEl.clientWidth;
  const l = pane.querySelector(".plan-fade.left"), r = pane.querySelector(".plan-fade.right");
  if (l) l.dataset.show = String(scrollEl.scrollLeft > 1);
  if (r) r.dataset.show = String(max > 1 && scrollEl.scrollLeft < max - 1);
}

// --------------------------------------------------------------- iface -----
function currentSig() {
  const dag = getDag();
  if (!dag) return "nodag";
  return JSON.stringify({
    nodes: dag.nodes.map((n) => [n.id, (n.gate || {}).status, (n.tasks && n.tasks.counts && n.tasks.counts.active) || 0, (n.tasks && n.tasks.counts && n.tasks.counts.total) || 0, n.kind, !!n.frontier]),
    edges: (dag.edges || []).length,
    collapsed: [...collapsed].sort(),
  });
}

export const lens = {
  mount(p) { pane = p; sigLast = null; build(); },
  update() {
    if (!pane) return;
    const sig = currentSig();
    if (sig !== sigLast) { const prev = scrollEl ? scrollEl.scrollLeft : 0; build(); if (scrollEl) scrollEl.scrollLeft = prev; sigLast = sig; }
  },
  applySelection(id) {
    selectedId = id;
    repaint(null);
    const el = nodeEls[id];
    if (el) el.scrollIntoView({ block: "center", inline: "center" });
  },
  unmount() {
    if (ro) { try { ro.disconnect(); } catch (e) {} ro = null; }
    if (pane) pane.style.overflow = "";
    pane = null; sigLast = null; nodeEls = {}; attrEls = {}; edgeEls = [];
    scrollEl = stageEl = wrapEl = fitBtn = detailEl = null;
  },
};
