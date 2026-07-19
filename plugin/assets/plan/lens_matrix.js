/* plan/lens_matrix.js — the Matrix lens. Ported from PlanDependencyMatrix.tsx at
   N=22: rows/columns ordered by stage (S0..S7) then id. A cell is filled iff the
   row depends on the column — those marks fall in the lower-left triangle, kept
   transparent while the upper-right is tinted. Diagonal status pills follow the
   shared node vocabulary. Row hover traces its dependency cells blue; column
   hover traces its dependent cells green; unrelated marks dim to 0.12. A footer
   runs a real topo sort to assert acyclicity.

   Structure follows the DAG-lens host pattern (lens_dag.js): the pane's overflow
   is pinned hidden and an unscaled .plan-scroll-host owns the .plan-mx-scroll
   scroll container plus the floating detail card. Column headers pin to the top,
   row labels to the left, and the corner spacer to both (timeline-lens sticky
   idiom). The cell size is fit to BOTH the pane width and height, so the grid
   drops to a scroll only when it truly cannot fit. Built once (signature-gated);
   hover + selection are attribute passes over the prebuilt cells. */

import { esc, escAttr, icon } from "../app.js";
import { bus } from "../core/bus.js";
import { getDag } from "./data.js";

const LABEL_W = 236;        // row-label column width
const TOP_HEADER = 96;      // vertical column-header band height
const FOOTER_H = 48;        // acyclicity footer reserve (fit math)
const PAD = 24;             // horizontal breathing room + scrollbar allowance
const PAD_V = 20;           // vertical breathing room (fit math)
const CELL_MIN = 22, CELL_MAX = 44;
const LG_CELL = 32;         // at/above this the row label stacks title over id
const TONE = { ink: "var(--n-800)", blue: "var(--tone-blue-dot)", green: "var(--tone-green-dot)" };
const FOLLOW_KEY = "gluerun.plan.mx.follow";

const clamp = (lo, hi, v) => Math.max(lo, Math.min(hi, v));

let pane = null, sigLast = null, selectedId = null;
let CELL = 27;                          // computed per build from the pane box
let fitX = false, fitY = false;         // does the grid fit each axis (centre vs scroll)
let order = [], nodesById = {}, depSets = {}, dependentsMap = {};
let depCellEls = [], rowLabelEls = {}, colHeadEls = {}, diagEls = {}, detailEl = null, scrollEl = null, toolbarEl = null;
let resizeObs = null, resizeTimer = null;
// Follow-diagonal: a horizontal scroll drives an equal vertical scroll so the eye
// tracks the diagonal (marks + status pills). Default ON, persisted. lastLeft is
// the previous scrollLeft; progScroll suppresses the follow during our own
// programmatic scrolls (selection centring, post-rebuild restore).
let followOn = (() => { try { return localStorage.getItem(FOLLOW_KEY) !== "0"; } catch (e) { return true; } })();
let lastLeft = 0, progScroll = false;

function stageIndexMap(dag) { const m = {}; (dag.stages || []).forEach((s, i) => { m[s.id] = i; }); return m; }

// Adaptive cell size: fit the grid to BOTH the pane width and height, clamped to
// [22, 44]. Height-awareness is the fix for the old width-only sizing that let a
// tall grid run off the bottom of the pane.
function computeCell(n) {
  const paneW = (pane && pane.clientWidth) || 1200;
  const paneH = (pane && pane.clientHeight) || 800;
  const wFit = Math.floor((paneW - LABEL_W - PAD) / Math.max(1, n));
  const hFit = Math.floor((paneH - TOP_HEADER - FOOTER_H - PAD_V) / Math.max(1, n));
  return clamp(CELL_MIN, CELL_MAX, Math.min(wFit, hFit));
}

// Does the laid-out grid fit the pane on each axis? Drives centre-vs-scroll.
function computeFit(n, cell) {
  const paneW = (pane && pane.clientWidth) || 1200;
  const paneH = (pane && pane.clientHeight) || 800;
  return { x: LABEL_W + n * cell <= paneW, y: TOP_HEADER + n * cell + FOOTER_H <= paneH };
}

function build() {
  const dag = getDag();
  if (!pane) return;
  if (!dag || !(dag.nodes || []).length) { pane.style.overflow = ""; pane.innerHTML = `<div class="plan-lens-empty">no DAG nodes to chart</div>`; sigLast = "empty"; return; }
  nodesById = {}; for (const n of dag.nodes) nodesById[n.id] = n;
  const si = stageIndexMap(dag);
  order = [...dag.nodes].sort((a, b) => (si[a.stage] - si[b.stage]) || a.id.localeCompare(b.id));
  depSets = {}; dependentsMap = {};
  for (const n of dag.nodes) depSets[n.id] = new Set(n.dependsOn || []);
  for (const n of dag.nodes) for (const d of n.dependsOn || []) (dependentsMap[d] = dependentsMap[d] || []).push(n.id);

  const n = order.length;
  CELL = computeCell(n);
  const fit = computeFit(n, CELL); fitX = fit.x; fitY = fit.y;
  const lg = CELL >= LG_CELL;
  const stageStart = (i) => i === 0 || order[i].stage !== order[i - 1].stage;
  const width = LABEL_W + n * CELL;

  // column header row: a sticky corner spacer over the labels, then vertical ids
  let head = `<div class="pm-colhead pm-corner" style="width:${LABEL_W}px"></div>`;
  order.forEach((col, i) => {
    head += `<div class="pm-colhead-cell" data-colhead="${escAttr(col.id)}" title="${escAttr(col.id)}" style="width:${CELL}px;${stageStart(i) ? "border-left:1px solid var(--n-400)" : ""}">
      <span class="pmch-stage">${stageStart(i) ? esc(col.stage.split("-")[0]) : ""}</span>
      <span class="pmch-id">${esc(col.id)}</span></div>`;
  });

  // rows
  let rows = "";
  order.forEach((row, rowIndex) => {
    let cells = "";
    order.forEach((col, colIndex) => {
      const bl = stageStart(colIndex) ? "1px solid var(--n-400)" : "1px solid var(--border-subtle)";
      if (row.id === col.id) {
        cells += `<button class="pm-cell pm-diag" data-diag="${escAttr(row.id)}" data-node="${escAttr(row.id)}" style="width:${CELL}px;height:${CELL}px;border-left:${bl}">${diagMark(row)}</button>`;
      } else {
        const dep = depSets[row.id].has(col.id);
        const tint = colIndex < rowIndex ? "transparent" : "var(--surface-sunken)";
        cells += `<div class="pm-cell" data-row="${escAttr(row.id)}" data-col="${escAttr(col.id)}" data-dep="${dep}" style="width:${CELL}px;height:${CELL}px;border-left:${bl};background:${tint}">${dep ? `<span class="pm-mark"></span>` : ""}</div>`;
      }
    });
    const title = (nodesById[row.id].description || "").split(".")[0] || row.id;
    rows += `<div class="pm-row" data-row="${escAttr(row.id)}" style="border-top:${stageStart(rowIndex) ? "1px solid var(--n-400)" : "1px solid var(--border-subtle)"}">
      <button class="pm-rowlabel" data-node="${escAttr(row.id)}" data-selected="false" title="${escAttr(row.id + " — " + title)}" style="width:${LABEL_W}px;height:${CELL}px">
        <span class="pmrl-text">
          <span class="pmrl-title">${esc(title)}</span>
          <span class="pmrl-id mono">${esc(row.id)}</span>
        </span>
        <span class="pmrl-gate"><span class="tone-dot" data-tone="${gateDot(row)}"></span></span>
      </button>${cells}</div>`;
  });

  // acyclicity footer (real topological sort); sticky-left so it stays readable
  // however far the grid is scrolled right (width:max-content, see plan.css).
  const acyclic = isAcyclic(dag);
  const footer = acyclic
    ? `<div class="pm-footer"><span>${esc(n)} nodes — every dependency points to an earlier node; the plan is provably acyclic.</span></div>`
    : `<div class="pm-footer pm-footer-warn"><span>${icon("i-alert")} a dependency cycle was detected — the plan is not a DAG.</span></div>`;

  pane.style.overflow = "hidden";
  pane.innerHTML =
    `<div class="plan-scroll-host">
       <div class="plan-mx-scroll" data-fit-x="${fitX}" data-fit-y="${fitY}">
         <div class="plan-matrix">
           <div class="pm-grid${lg ? " pm-lg" : ""}" style="width:${width}px;--pm-cell:${CELL}px">
             <div class="pm-colhead-row" style="height:${TOP_HEADER}px">${head}</div>
             ${rows}
             ${footer}
           </div>
         </div>
       </div>
       <div class="pm-toolbar"${fitX && fitY ? " hidden" : ""}>
         <button class="secondary-button pm-follow" aria-pressed="${followOn}" title="Follow diagonal — scrolling right also scrolls down so the eye tracks the diagonal">${icon("i-arrowdown")}<span>Follow diagonal</span></button>
       </div>
       <div class="plan-detail-card pm-detail" hidden></div>
     </div>`;

  depCellEls = []; rowLabelEls = {}; colHeadEls = {}; diagEls = {};
  pane.querySelectorAll(".pm-cell[data-dep]").forEach((el) => { if (el.dataset.dep === "true") depCellEls.push(el); });
  pane.querySelectorAll(".pm-rowlabel").forEach((el) => { rowLabelEls[el.dataset.node] = el; });
  pane.querySelectorAll("[data-colhead]").forEach((el) => { colHeadEls[el.dataset.colhead] = el; });
  pane.querySelectorAll("[data-diag]").forEach((el) => { diagEls[el.dataset.diag] = el; });
  detailEl = pane.querySelector(".pm-detail");
  scrollEl = pane.querySelector(".plan-mx-scroll");
  toolbarEl = pane.querySelector(".pm-toolbar");
  lastLeft = scrollEl ? scrollEl.scrollLeft : 0;   // reset the follow baseline for the fresh scroller
  wire();
  repaint(null);
}

function gateDot(n) {
  const s = (n.gate || {}).status;
  if (s === "passed") return "success";
  if (s === "blocked" || s === "failed" || s === "invalid") return "blocked";
  return "idle";
}

function diagMark(n) {
  const g = n.gate || {}, c = (n.tasks && n.tasks.counts) || {};
  const passed = g.status === "passed", active = (c.active || 0) > 0;
  const failed = g.status === "failed" || g.status === "blocked" || g.status === "invalid";
  const isEval = n.kind === "evaluation" || n.kind === "gate";
  let bg = "var(--n-100)", dot = "var(--n-400)", border = "1.5px dashed var(--n-300)";
  if (passed || active) { bg = "var(--ink)"; dot = "#fff"; border = "1px solid var(--ink)"; }
  else if (isEval) { bg = "var(--tone-coral-bg)"; dot = "var(--tone-coral-dot)"; border = "1.5px solid var(--tone-coral-dot)"; }
  const inner = passed ? "" : `<span class="pmd-dot" style="background:${dot}"></span>`;
  return `<span class="pm-diagpill${failed ? " is-failed" : ""}" style="background:${bg};border:${border}">${inner}</span>`;
}

// --------------------------------------------------------------- paint -----
function cellState(rowId, colId, hover) {
  const dep = depSets[rowId].has(colId);
  if (!hover) return { tone: dep ? "ink" : null, dim: false };
  if (rowId === hover) return { tone: dep ? "blue" : null, dim: !dep };
  if (colId === hover) return { tone: dep ? "green" : null, dim: !dep };
  return { tone: dep ? "ink" : null, dim: true };
}

function repaint(hover) {
  for (const el of depCellEls) {
    const st = cellState(el.dataset.row, el.dataset.col, hover);
    const mark = el.firstElementChild;
    if (!mark) continue;
    if (st.tone) {
      mark.style.background = TONE[st.tone];
      mark.style.opacity = st.dim ? "0.12" : st.tone === "ink" ? "0.82" : "1";
    }
  }
  // The sticky row labels are now opaque, so the hover tint lives on the label
  // element itself (cached beside the cells — no queries in this hot path).
  for (const [id, el] of Object.entries(rowLabelEls)) el.style.background = id === hover ? "var(--surface-sunken)" : "var(--surface-panel)";
  for (const [id, el] of Object.entries(colHeadEls)) el.dataset.hover = String(id === hover);
  for (const [id, el] of Object.entries(diagEls)) el.dataset.selected = String(id === selectedId);
  if (hover && detailEl) showDetail(hover); else if (detailEl) detailEl.hidden = true;
}

function showDetail(id) {
  const n = nodesById[id]; if (!n || !detailEl) return;
  const deps = (n.dependsOn || []).join(" · ") || "—";
  const needed = (dependentsMap[id] || []).join(" · ") || "—";
  detailEl.innerHTML =
    `<div class="plan-detail-head"><span class="mono" style="font-size:11px;color:var(--text-secondary)">${esc(n.id)}</span>
       <span class="plan-chip">${esc(n.area)}</span>
       <span style="margin-left:auto;font:600 9px var(--font-sans);letter-spacing:0.05em;text-transform:uppercase;color:var(--text-meta)">${esc((n.gate || {}).status || "absent")}</span></div>
     <div class="plan-detail-title">${esc(n.stage)}${n.kind ? " · " + esc(n.kind) : ""}</div>
     <div class="plan-detail-rule"></div>
     <div class="plan-detail-row"><span class="pdl">Depends on</span><span class="pdv mono" style="color:var(--tone-blue-fg)">${esc(deps)}</span></div>
     <div class="plan-detail-row"><span class="pdl">Needed by</span><span class="pdv mono" style="color:var(--tone-green-fg)">${esc(needed)}</span></div>`;
  detailEl.hidden = false;
}

function isAcyclic(dag) {
  const indeg = {}, adj = {};
  for (const n of dag.nodes) { indeg[n.id] = 0; adj[n.id] = []; }
  for (const n of dag.nodes) for (const d of n.dependsOn || []) { if (adj[d]) { adj[d].push(n.id); indeg[n.id]++; } }
  const q = dag.nodes.filter((n) => indeg[n.id] === 0).map((n) => n.id);
  let seen = 0;
  while (q.length) { const id = q.shift(); seen++; for (const m of adj[id]) if (--indeg[m] === 0) q.push(m); }
  return seen === dag.nodes.length;
}

// Follow-diagonal scroll linking. A horizontal scroll (wheel, trackpad, scrollbar
// drag) echoes an equal delta into the vertical axis so the eye tracks the
// diagonal. The vertical axis is otherwise free. Loop-free by construction: the
// scrollTop write fires another scroll event, but scrollLeft is unchanged there
// so dx === 0 and we return before writing again. progScroll suppresses the whole
// thing during our own programmatic scrolls (selection centring, rebuild restore).
function onScroll() {
  if (!scrollEl) return;
  const left = scrollEl.scrollLeft;
  const dx = left - lastLeft;
  lastLeft = left;                       // always track, even on a skipped event
  if (progScroll || !followOn || dx === 0) return;
  scrollEl.scrollTop += dx;
}

function wire() {
  const grid = pane.querySelector(".pm-grid");
  grid.addEventListener("click", (e) => { const b = e.target.closest("[data-node]"); if (b && bus.onNodeSelect) bus.onNodeSelect(b.dataset.node); });
  grid.addEventListener("pointerover", (e) => {
    const cell = e.target.closest("[data-row],[data-colhead]");
    if (!cell) return;
    repaint(cell.dataset.colhead || cell.dataset.row);
  });
  grid.addEventListener("pointerleave", () => repaint(null));
  if (scrollEl) scrollEl.addEventListener("scroll", onScroll, { passive: true });
  const follow = pane.querySelector(".pm-follow");
  if (follow) follow.addEventListener("click", () => {
    followOn = !followOn;
    try { localStorage.setItem(FOLLOW_KEY, followOn ? "1" : "0"); } catch (e) {}
    follow.setAttribute("aria-pressed", String(followOn));
  });
}

// The computed CELL folds into the signature so a size-band crossing rebuilds
// (a live 10s poll at the same box — same CELL — does not).
function currentSig() {
  const dag = getDag();
  if (!dag) return "nodag";
  const cell = computeCell(dag.nodes.length);
  return JSON.stringify([cell, dag.nodes.map((n) => [n.id, (n.gate || {}).status, (n.tasks && n.tasks.counts && n.tasks.counts.active) || 0, n.kind])]);
}

function observeResize() {
  if (resizeObs || typeof ResizeObserver === "undefined" || !pane) return;
  resizeObs = new ResizeObserver(() => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      const dag = getDag(); if (!dag || !pane) return;
      const n = dag.nodes.length;
      const newCell = computeCell(n);
      if (newCell !== CELL) { build(); sigLast = currentSig(); return; }
      // Fast-path: the cell band held but the fit flags may have flipped (a small
      // resize within a band) — just re-toggle centring, no rebuild.
      const fit = computeFit(n, newCell);
      if ((fit.x !== fitX || fit.y !== fitY) && scrollEl) {
        fitX = fit.x; fitY = fit.y;
        scrollEl.dataset.fitX = String(fitX);
        scrollEl.dataset.fitY = String(fitY);
        if (toolbarEl) toolbarEl.hidden = fitX && fitY;   // hide the follow pill once it all fits
      }
    }, 120);
  });
  resizeObs.observe(pane);
}

export const lens = {
  mount(p) { pane = p; sigLast = null; build(); observeResize(); },
  update() {
    if (!pane) return;
    const sig = currentSig();
    if (sig !== sigLast) {
      // Preserve the scroll position across a signature rebuild (a live tick must
      // not yank the viewport back to the origin) — under progScroll so the
      // restore does not trip the follow handler, resyncing the baseline after.
      const sl = scrollEl ? scrollEl.scrollLeft : 0, st = scrollEl ? scrollEl.scrollTop : 0;
      build(); sigLast = sig;
      if (scrollEl) {
        progScroll = true;
        scrollEl.scrollLeft = sl; scrollEl.scrollTop = st;
        requestAnimationFrame(() => { lastLeft = scrollEl ? scrollEl.scrollLeft : 0; progScroll = false; });
      }
    }
  },
  applySelection(id) {
    selectedId = id; repaint(null);
    const el = diagEls[id]; if (!el) return;
    // Centre the node without the follow handler adding extra vertical drift
    // (scrollIntoView moves both axes); resync the baseline once it settles.
    progScroll = true;
    el.scrollIntoView({ block: "center", inline: "center" });
    requestAnimationFrame(() => { lastLeft = scrollEl ? scrollEl.scrollLeft : 0; progScroll = false; });
  },
  unmount() {
    if (resizeObs) { resizeObs.disconnect(); resizeObs = null; }
    clearTimeout(resizeTimer);
    if (pane) pane.style.overflow = "";
    pane = null; sigLast = null; depCellEls = []; scrollEl = null; toolbarEl = null; progScroll = false;
  },
};
