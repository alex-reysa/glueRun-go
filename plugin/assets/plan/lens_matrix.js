/* plan/lens_matrix.js — the Matrix lens. Ported from PlanDependencyMatrix.tsx at
   N=22: rows/columns ordered by stage (S0..S7) then id; CELL 27 squares, LABEL_W
   178 row labels, TOP_HEADER 78 vertical column headers. A cell is filled iff the
   row depends on the column — those marks fall in the lower-left triangle, kept
   transparent while the upper-right is tinted. Diagonal status pills follow the
   shared node vocabulary. Row hover traces its dependency cells blue; column
   hover traces its dependent cells green; unrelated marks dim to 0.12. A footer
   runs a real topo sort to assert acyclicity. Built once (signature-gated); hover
   + selection are attribute passes over the prebuilt cells. */

import { esc, escAttr, icon } from "../app.js";
import { bus } from "../core/bus.js";
import { getDag } from "./data.js";

const LABEL_W = 178;
const TOP_HEADER = 78;
const PAD = 24;             // grid padding + scrollbar allowance
const CELL_MIN = 22, CELL_MAX = 44;
const TONE = { ink: "var(--n-800)", blue: "var(--tone-blue-dot)", green: "var(--tone-green-dot)" };

const clamp = (lo, hi, v) => Math.max(lo, Math.min(hi, v));

let pane = null, sigLast = null, selectedId = null;
let CELL = 27;              // computed per build from the pane width
let order = [], nodesById = {}, depSets = {}, dependentsMap = {};
let depCellEls = [], rowEls = {}, colHeadEls = {}, diagEls = {}, detailEl = null;
let resizeObs = null, resizeTimer = null;

function stageIndexMap(dag) { const m = {}; (dag.stages || []).forEach((s, i) => { m[s.id] = i; }); return m; }

// Adaptive cell size: fill the pane width, clamped to [22, 44]. Below 22 marks
// become invisible; above 44 the grid stops feeling like a matrix.
function computeCell(n) {
  const paneW = (pane && pane.clientWidth) || 1200;
  return clamp(CELL_MIN, CELL_MAX, Math.floor((paneW - LABEL_W - PAD) / Math.max(1, n)));
}

function build() {
  const dag = getDag();
  if (!pane) return;
  if (!dag || !(dag.nodes || []).length) { pane.innerHTML = `<div class="plan-lens-empty">no DAG nodes to chart</div>`; sigLast = "empty"; return; }
  nodesById = {}; for (const n of dag.nodes) nodesById[n.id] = n;
  const si = stageIndexMap(dag);
  order = [...dag.nodes].sort((a, b) => (si[a.stage] - si[b.stage]) || a.id.localeCompare(b.id));
  depSets = {}; dependentsMap = {};
  for (const n of dag.nodes) depSets[n.id] = new Set(n.dependsOn || []);
  for (const n of dag.nodes) for (const d of n.dependsOn || []) (dependentsMap[d] = dependentsMap[d] || []).push(n.id);

  CELL = computeCell(order.length);
  const stageStart = (i) => i === 0 || order[i].stage !== order[i - 1].stage;
  const width = LABEL_W + order.length * CELL + 2;
  const paneW = (pane && pane.clientWidth) || width;
  // center only when the grid is narrower than the pane (small N); otherwise
  // left-align and let the container scroll horizontally.
  const centered = width < paneW - 2;

  // column header row
  let head = `<div class="pm-colhead" style="width:${LABEL_W}px;flex:none"></div>`;
  order.forEach((col, i) => {
    head += `<div class="pm-colhead-cell" data-colhead="${escAttr(col.id)}" style="width:${CELL}px;${stageStart(i) ? "border-left:1px solid var(--border-strong)" : ""}">
      <span class="pmch-stage">${stageStart(i) ? esc(col.stage.split("-")[0]) : ""}</span>
      <span class="pmch-id">${esc(col.id)}</span></div>`;
  });

  // rows
  let rows = "";
  order.forEach((row, rowIndex) => {
    let cells = "";
    order.forEach((col, colIndex) => {
      const bl = stageStart(colIndex) ? "1px solid var(--border-strong)" : "1px solid var(--border-subtle)";
      if (row.id === col.id) {
        cells += `<button class="pm-cell pm-diag" data-diag="${escAttr(row.id)}" data-node="${escAttr(row.id)}" style="width:${CELL}px;height:${CELL}px;border-left:${bl}">${diagMark(row)}</button>`;
      } else {
        const dep = depSets[row.id].has(col.id);
        const tint = colIndex < rowIndex ? "transparent" : "var(--surface-sunken)";
        cells += `<div class="pm-cell" data-row="${escAttr(row.id)}" data-col="${escAttr(col.id)}" data-dep="${dep}" style="width:${CELL}px;height:${CELL}px;border-left:${bl};background:${tint}">${dep ? `<span class="pm-mark"></span>` : ""}</div>`;
      }
    });
    rows += `<div class="pm-row" data-row="${escAttr(row.id)}" style="border-top:${stageStart(rowIndex) ? "1px solid var(--border-strong)" : "1px solid var(--border-subtle)"}">
      <button class="pm-rowlabel" data-node="${escAttr(row.id)}" data-selected="false" style="width:${LABEL_W}px">
        <span class="pmrl-id mono">${esc(row.id)}</span>
        <span class="pmrl-title">${esc((nodesById[row.id].description || "").split(".")[0] || row.id)}</span>
        <span class="pmrl-gate"><span class="tone-dot" data-tone="${gateDot(row)}"></span></span>
      </button>${cells}</div>`;
  });

  // acyclicity footer (real topological sort)
  const acyclic = isAcyclic(dag);
  const footer = acyclic
    ? `<div class="pm-footer"><span>All marks fall below the diagonal — every dependency points to an earlier node, so the plan is provably acyclic.</span></div>`
    : `<div class="pm-footer pm-footer-warn"><span>${icon("i-alert")} a dependency cycle was detected — the plan is not a DAG.</span></div>`;

  pane.innerHTML = `<div class="plan-matrix"><div class="pm-grid${centered ? " pm-centered" : ""}" style="width:${width}px;--pm-cell:${CELL}px">
    <div class="pm-colhead-row" style="height:${TOP_HEADER}px">${head}</div>
    ${rows}
    ${footer}
  </div><div class="plan-detail-card pm-detail" hidden></div></div>`;

  depCellEls = []; rowEls = {}; colHeadEls = {}; diagEls = {};
  pane.querySelectorAll(".pm-cell[data-dep]").forEach((el) => { if (el.dataset.dep === "true") depCellEls.push(el); });
  pane.querySelectorAll(".pm-row").forEach((el) => { rowEls[el.dataset.row] = el; });
  pane.querySelectorAll("[data-colhead]").forEach((el) => { colHeadEls[el.dataset.colhead] = el; });
  pane.querySelectorAll("[data-diag]").forEach((el) => { diagEls[el.dataset.diag] = el; });
  detailEl = pane.querySelector(".pm-detail");
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
  for (const [id, el] of Object.entries(rowEls)) el.style.background = id === hover ? "var(--surface-sunken)" : "transparent";
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

function wire() {
  const grid = pane.querySelector(".pm-grid");
  grid.addEventListener("click", (e) => { const b = e.target.closest("[data-node]"); if (b && bus.onNodeSelect) bus.onNodeSelect(b.dataset.node); });
  grid.addEventListener("pointerover", (e) => {
    const cell = e.target.closest("[data-row],[data-colhead]");
    if (!cell) return;
    repaint(cell.dataset.colhead || cell.dataset.row);
  });
  grid.addEventListener("pointerleave", () => repaint(null));
}

// The computed CELL folds into the signature so a width-band crossing rebuilds
// (a live 10s poll at the same width — same CELL — does not).
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
      if (computeCell(dag.nodes.length) !== CELL) { build(); sigLast = currentSig(); }
    }, 120);
  });
  resizeObs.observe(pane);
}

export const lens = {
  mount(p) { pane = p; sigLast = null; build(); observeResize(); },
  update() { if (!pane) return; const sig = currentSig(); if (sig !== sigLast) { build(); sigLast = sig; } },
  applySelection(id) {
    selectedId = id; repaint(null);
    const el = diagEls[id]; if (el) el.scrollIntoView({ block: "center", inline: "center" });
  },
  unmount() {
    if (resizeObs) { resizeObs.disconnect(); resizeObs = null; }
    clearTimeout(resizeTimer);
    pane = null; sigLast = null; depCellEls = [];
  },
};
