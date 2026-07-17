/* plan/lens_dag.js — the DAG lens. Ported from PlanGraphLarge.tsx with STAGE as
   the phase axis: 8 collapsible stage ribbons, intra-stage longest-path columns,
   bezier edges with directional arrowheads, transitive ancestor/descendant hover
   tracing (blue upstream · green downstream), a floating detail card, and
   scroll-shadow fades. Layout is rebuilt only when the DAG or a stage-collapse
   changes (signature-gated); hover + selection are attribute/style passes over
   the prebuilt DOM, never a rebuild. */

import { esc, escAttr, icon } from "../app.js";
import { bus } from "../core/bus.js";
import { getDag } from "./data.js";

const RADIUS = 19;
const COLUMN_W = 120;
const ROW_H = 74;
const MARGIN_X = 150;
const MID_Y = 322;
const STAGE_HEIGHT = 660;
const STAGE_GAP = 0.6;
const TOP_PAD = 16;

let pane = null;
let sigLast = null;
let selectedId = null;
let collapsed = new Set();     // collapsed stage ids
// build artifacts
let nodesById = {}, positions = {}, zones = {}, ancestors = {}, descendants = {};
let stageOrder = [], nodeEls = {}, labelEls = {}, edgeEls = [], detailEl = null, scrollEl = null;

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
    col += width + STAGE_GAP;
  }
  const totalCols = col;

  positions = {};
  for (const id of stageOrder) {
    const byDepth = {};
    for (const n of nodesByStage[id]) (byDepth[depth[n.id]] = byDepth[depth[n.id]] || []).push(n.id);
    for (const [dRaw, ids] of Object.entries(byDepth)) {
      ids.sort((a, b) => a.localeCompare(b));
      ids.forEach((nid, i) => {
        positions[nid] = {
          x: MARGIN_X + (geom[id].startCol + Number(dRaw)) * COLUMN_W,
          y: MID_Y - ((ids.length - 1) * ROW_H) / 2 + i * ROW_H,
        };
      });
    }
  }

  zones = {};
  for (const id of stageOrder) {
    const ids = nodesByStage[id].map((n) => n.id);
    const xs = ids.map((nid) => positions[nid].x);
    const passed = ids.filter((nid) => (nodesById[nid].gate || {}).status === "passed").length;
    zones[id] = ids.length
      ? { ids, x0: Math.min(...xs), x1: Math.max(...xs), cx: (Math.min(...xs) + Math.max(...xs)) / 2, cy: MID_Y, passed }
      : { ids: [], x0: MARGIN_X, x1: MARGIN_X, cx: MARGIN_X, cy: MID_Y, passed: 0 };
  }
  return { stageWidth: MARGIN_X + totalCols * COLUMN_W + 40, stages: dag.stages || [] };
}

// classification of a node's resting visual per the shared vocabulary
function visualOf(n) {
  const g = n.gate || {};
  const c = (n.tasks && n.tasks.counts) || {};
  const passed = g.status === "passed";
  const active = (c.active || 0) > 0;
  const failed = g.status === "failed" || g.status === "blocked" || g.status === "invalid";
  const isEval = n.kind === "evaluation" || n.kind === "gate";
  let well = "var(--n-100)", dot = "var(--n-400)", border = "1.5px dashed var(--n-300)", opacity = 0.6, inner = "dot", shadow = false;
  if (passed || active) { well = "var(--ink)"; dot = "#fff"; border = "1px solid var(--ink)"; opacity = 1; shadow = true; inner = passed ? "check" : "dot"; }
  else if (isEval) { well = "var(--tone-coral-bg)"; dot = "var(--tone-coral-dot)"; border = "1.5px solid var(--tone-coral-dot)"; opacity = 1; }
  return { well, dot, border, opacity, inner, shadow, active, failed, passed };
}

function curve(from, to) {
  const k = Math.max(36, (to.x - from.x) * 0.45);
  return `M${from.x + RADIUS},${from.y} C${from.x + RADIUS + k},${from.y} ${to.x - RADIUS - k},${to.y} ${to.x - RADIUS},${to.y}`;
}

const renderKey = (id) => (collapsed.has(nodesById[id].stage) ? "PH:" + nodesById[id].stage : id);
function effectivePos(id) {
  const st = nodesById[id].stage;
  return collapsed.has(st) ? { x: zones[st].cx, y: zones[st].cy } : positions[id];
}

// --------------------------------------------------------------- build -----
function build() {
  const dag = getDag();
  if (!pane) return;
  if (!dag || !(dag.nodes || []).length) { pane.innerHTML = `<div class="plan-lens-empty">no DAG nodes to graph</div>`; sigLast = "empty"; return; }
  computeAncestry(dag);
  const { stageWidth, stages } = computeLayout(dag);

  // dedup edges under the current collapse state
  const seen = new Set(); const edges = [];
  for (const e of dag.edges || []) {
    const fk = renderKey(e.from), tk = renderKey(e.to);
    if (fk === tk) continue;
    const key = fk + "->" + tk;
    if (!seen.has(key)) { seen.add(key); edges.push({ from: e.from, to: e.to }); }
  }

  const stageName = {}; for (const s of stages) stageName[s.id] = s.id;

  // ribbons (collapse toggles) + alternating tints
  let ribbons = "", tints = "";
  stageOrder.forEach((sid, i) => {
    const z = zones[sid];
    const left = z.x0 - RADIUS - 8, width = z.x1 - z.x0 + 2 * RADIUS + 16;
    ribbons += `<button class="plan-dag-ribbon" data-stage="${escAttr(sid)}" style="left:${left}px;top:${TOP_PAD}px;width:${width}px" aria-expanded="${!collapsed.has(sid)}">
      <span class="pdr-chev">${icon("i-chev")}</span><span class="pdr-id">${esc(sid.split("-")[0])}</span><span class="pdr-name">${esc(sid.replace(/^S\d+-/, ""))}</span></button>`;
    tints += `<div class="plan-dag-tint" style="left:${left}px;width:${width}px;top:52px;bottom:8px;${i % 2 ? "opacity:0" : ""}"></div>`;
  });

  // svg edges
  const edgePaths = edges.map((e, i) => {
    const from = effectivePos(e.from), to = effectivePos(e.to);
    if (from.x === to.x && from.y === to.y) return "";
    return `<path data-edge="${i}" data-from="${escAttr(e.from)}" data-to="${escAttr(e.to)}" d="${curve(from, to)}" fill="none" stroke="var(--n-300)" stroke-width="1.2" opacity="0.5" marker-end="url(#dag-a)"/>`;
  }).join("");
  const svg = `<svg width="${stageWidth}" height="${STAGE_HEIGHT}" class="plan-dag-edges">
    <defs>
      <marker id="dag-a" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto" markerUnits="userSpaceOnUse"><path d="M1,1.5 L6,4 L1,6.5" fill="none" stroke="var(--n-400)" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></marker>
      <marker id="dag-up" markerWidth="9" markerHeight="9" refX="6" refY="4" orient="auto" markerUnits="userSpaceOnUse"><path d="M1,1.5 L6,4 L1,6.5" fill="none" stroke="var(--tone-blue-dot)" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></marker>
      <marker id="dag-dn" markerWidth="9" markerHeight="9" refX="6" refY="4" orient="auto" markerUnits="userSpaceOnUse"><path d="M1,1.5 L6,4 L1,6.5" fill="none" stroke="var(--tone-green-dot)" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></marker>
    </defs>${edgePaths}</svg>`;

  // node labels + circles (expanded stages only)
  let labels = "", circles = "";
  for (const n of dag.nodes) {
    if (collapsed.has(n.stage)) continue;
    const p = positions[n.id];
    labels += `<div class="plan-dag-label" data-label="${escAttr(n.id)}" style="left:${p.x - 50}px;top:${p.y + RADIUS + 6}px">${esc(n.id)}</div>`;
    const v = visualOf(n);
    const innerHtml = v.inner === "check"
      ? `<span class="pdn-check">${icon("i-check")}</span>`
      : `<span class="pdn-dot" style="background:${v.dot}"></span>`;
    circles += `<div class="plan-dag-nodewrap" style="left:${p.x - RADIUS}px;top:${p.y - RADIUS}px">
      <button class="plan-dag-node${v.active ? " is-active" : ""}${v.failed ? " is-failed" : ""}" data-node="${escAttr(n.id)}" data-selected="false"
        style="background:${v.well};border:${v.border};opacity:${v.opacity};box-shadow:${v.shadow ? "var(--shadow-sm)" : "none"}">${innerHtml}</button></div>`;
  }

  // collapsed stage summaries
  let summaries = "";
  for (const sid of stageOrder) {
    if (!collapsed.has(sid)) continue;
    const z = zones[sid];
    summaries += `<button class="plan-dag-summary" data-stage="${escAttr(sid)}" style="left:${z.x0 - RADIUS - 8}px;top:${MID_Y - 40}px;width:${z.x1 - z.x0 + 2 * RADIUS + 16}px">
      <span class="pds-eyebrow">${esc(sid.split("-")[0])}</span>
      <span class="pds-name">${esc(sid.replace(/^S\d+-/, ""))}</span>
      <span class="pds-meta">${z.ids.length} nodes · ${z.passed} gated · tap to expand</span></button>`;
  }

  pane.style.overflow = "hidden";
  pane.innerHTML =
    `<div class="plan-scroll-host">
       <div class="plan-dag-scroll">
         <div class="plan-dag-stage" style="width:${stageWidth}px;height:${STAGE_HEIGHT}px">
           ${tints}${ribbons}${svg}${labels}${circles}${summaries}
           <div class="plan-detail-card plan-dag-detail" hidden></div>
         </div>
       </div>
       <div class="plan-fade left"></div>
       <div class="plan-fade right"></div>
     </div>`;

  // cache refs
  nodeEls = {}; labelEls = {}; edgeEls = [];
  pane.querySelectorAll(".plan-dag-node").forEach((el) => { nodeEls[el.dataset.node] = el; });
  pane.querySelectorAll(".plan-dag-label").forEach((el) => { labelEls[el.dataset.label] = el; });
  pane.querySelectorAll(".plan-dag-edges path[data-edge]").forEach((el) => edgeEls.push({ el, from: el.dataset.from, to: el.dataset.to }));
  detailEl = pane.querySelector(".plan-dag-detail");
  scrollEl = pane.querySelector(".plan-dag-scroll");

  wire();
  measureFades();
  repaint(null);
}

// --------------------------------------------------------------- paint -----
function repaint(focusId) {
  const dag = getDag(); if (!dag) return;
  let up = null, down = null, all = null;
  if (focusId && nodeEls[focusId]) { up = ancestors[focusId]; down = descendants[focusId]; all = new Set([focusId, ...up, ...down]); }

  for (const [id, el] of Object.entries(nodeEls)) {
    const n = nodesById[id]; const v = visualOf(n);
    let outline = "none", outlineOffset = "2px", op = v.opacity, transform = "scale(1)", z = "3";
    if (all) {
      if (id === focusId) { outline = "2.5px solid var(--ink)"; transform = "scale(1.12)"; z = "8"; }
      else if (up.has(id)) { outline = "2px solid var(--tone-blue-dot)"; z = "6"; }
      else if (down.has(id)) { outline = "2px solid var(--tone-green-dot)"; z = "6"; }
      else { op = 0.16; }
    } else if (id === selectedId) { outline = "2.5px solid var(--ink)"; z = "7"; }
    else if (v.failed) { outline = "2px solid var(--tone-red-dot)"; }
    el.style.outline = outline; el.style.outlineOffset = outlineOffset; el.style.opacity = op;
    el.style.transform = transform; el.parentElement.style.zIndex = z;
    el.dataset.selected = String(id === selectedId);
  }
  for (const [id, el] of Object.entries(labelEls)) el.style.opacity = all && !all.has(id) ? "0.18" : "1";
  for (const e of edgeEls) {
    let stroke = "var(--n-300)", w = "1.2", op = "0.5", mk = "url(#dag-a)";
    if (all) {
      const upEdge = (e.to === focusId || up.has(e.to)) && (e.from === focusId || up.has(e.from));
      const dnEdge = (e.from === focusId || down.has(e.from)) && (e.to === focusId || down.has(e.to));
      if (upEdge) { stroke = "var(--tone-blue-dot)"; w = "1.8"; op = "0.95"; mk = "url(#dag-up)"; }
      else if (dnEdge) { stroke = "var(--tone-green-dot)"; w = "1.8"; op = "0.95"; mk = "url(#dag-dn)"; }
      else { op = "0.06"; }
    }
    e.el.setAttribute("stroke", stroke); e.el.setAttribute("stroke-width", w);
    e.el.setAttribute("opacity", op); e.el.setAttribute("marker-end", mk);
  }
  if (focusId && detailEl) showDetail(focusId); else if (detailEl) detailEl.hidden = true;
}

function showDetail(id) {
  const n = nodesById[id]; if (!n || !detailEl) return;
  const p = positions[id]; if (!p) { detailEl.hidden = true; return; }
  const stageWidth = parseInt(pane.querySelector(".plan-dag-stage").style.width, 10) || 900;
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
  detailEl.style.left = Math.min(Math.max(p.x - 130, 8), stageWidth - 268) + "px";
  detailEl.style.top = (p.y > 330 ? p.y - RADIUS - 12 - 176 : p.y + RADIUS + 14) + "px";
  detailEl.hidden = false;
}

// --------------------------------------------------------------- wire ------
function wire() {
  const stage = pane.querySelector(".plan-dag-stage");
  stage.addEventListener("click", (e) => {
    const ribbon = e.target.closest("[data-stage]");
    if (ribbon) { const s = ribbon.dataset.stage; if (collapsed.has(s)) collapsed.delete(s); else collapsed.add(s); sigLast = null; build(); return; }
    const node = e.target.closest("[data-node]");
    if (node && bus.onNodeSelect) bus.onNodeSelect(node.dataset.node);
  });
  stage.addEventListener("pointerover", (e) => { const node = e.target.closest("[data-node]"); if (node) repaint(node.dataset.node); });
  stage.addEventListener("pointerout", (e) => {
    const node = e.target.closest("[data-node]");
    if (node && !stage.contains(e.relatedTarget && e.relatedTarget.closest && e.relatedTarget.closest("[data-node]"))) repaint(null);
  });
  scrollEl.addEventListener("scroll", measureFades);
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
    nodes: dag.nodes.map((n) => [n.id, (n.gate || {}).status, (n.tasks && n.tasks.counts && n.tasks.counts.active) || 0, n.kind]),
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
  unmount() { if (pane) pane.style.overflow = ""; pane = null; sigLast = null; nodeEls = {}; edgeEls = []; },
};
