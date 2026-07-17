/* plan/workbench.js — the Plan surface shell. Owns the left lens tablist, mounts
   exactly one lens at a time into #plan-pane, and drives the right drilldown
   aside. Shared node selection (selectPlanNode) updates the route, tells the
   mounted lens to ring/scroll the node, and renders the aside. Ported from
   PlanGraphWorkbench.tsx (196px tablist · center pane · 360px aside). */

import { S, esc, escAttr, icon, toneOf, labelOf, gateTone, select, relTime } from "../app.js";
import { writeRoute } from "../core/router.js";
import { bus } from "../core/bus.js";
import { fetchDag, getDag, dagIndex, dagMaybeRefetch, onDag } from "./data.js";
import { lens as timelineLens } from "./lens_timeline.js";
import { lens as matrixLens } from "./lens_matrix.js";
import { lens as dagLens } from "./lens_dag.js";
import { lens as tasksLens } from "./lens_tasks.js";

const LENSES = [
  { id: "timeline", label: "Timeline", lens: timelineLens },
  { id: "matrix", label: "Matrix", lens: matrixLens },
  { id: "dag", label: "DAG", lens: dagLens },
  { id: "tasks", label: "Tasks", lens: tasksLens },
];
const LENS_BY_ID = Object.fromEntries(LENSES.map((l) => [l.id, l]));

let curLens = null;          // current lens id
let mounted = null;          // current lens object (mounted)
let selectedNodeId = null;   // shared plan-node selection (drives the aside)
let asideOpen = localStorage.getItem("gluerun.plan.aside") !== "0";
let nodeEnrich = new Map();   // nodeId -> /api/node detail (aside lazy-enrich)
let started = false;

export function getLens() { return curLens; }

// ------------------------------------------------------------ lens nav -----
function renderNav() {
  const nav = document.getElementById("plan-lensnav");
  if (!nav) return;
  const empty = dagIsEmpty();
  nav.innerHTML = `<div class="plan-lensnav-eyebrow">plan views</div>` +
    LENSES.map((l) => {
      const on = l.id === curLens;
      const dim = empty && l.id !== "tasks";
      return `<button class="plan-lenstab" role="tab" data-lens="${l.id}" aria-selected="${on}"${dim ? ' data-empty="1"' : ""}>${esc(l.label)}</button>`;
    }).join("");
}

function dagIsEmpty() { const d = getDag(); return !!d && (d.nodes || []).length === 0; }

export function setLens(id, opts) {
  if (!LENS_BY_ID[id]) id = "tasks";
  // With an empty DAG only the Tasks lens is meaningful.
  if (dagIsEmpty()) id = "tasks";
  const pane = document.getElementById("plan-pane");
  if (id !== curLens || !mounted) {
    if (mounted && mounted.unmount) { try { mounted.unmount(); } catch (e) {} }
    curLens = id;
    localStorage.setItem("gluerun.plan.lens", id);
    mounted = LENS_BY_ID[id].lens;
    if (pane) pane.dataset.lens = id;
    if (mounted && mounted.mount) mounted.mount(pane);
  }
  renderNav();
  if (!opts || opts.route !== false) writeRoute("plan", id, selectedNodeId ? "NODE:" + selectedNodeId : null, null);
  if (selectedNodeId && mounted && mounted.applySelection) mounted.applySelection(selectedNodeId);
}

// -------------------------------------------------- shared node selection --
export function selectPlanNode(id) {
  selectedNodeId = id;
  writeRoute("plan", curLens, id ? "NODE:" + id : null, null);
  if (mounted && mounted.applySelection) mounted.applySelection(id);
  renderAside();
  if (id && !nodeEnrich.has(id)) enrichNode(id);
}

async function enrichNode(id) {
  try {
    const res = await fetch("/api/node/" + encodeURIComponent(id), { cache: "no-store" });
    if (!res.ok) return;
    nodeEnrich.set(id, await res.json());
    if (selectedNodeId === id) renderAside();
  } catch (e) { /* aside renders fine from the DAG node without enrichment */ }
}

// ------------------------------------------------------------- aside -------
function chip(text, cls) { return `<span class="plan-chip${cls ? " " + cls : ""}">${esc(text)}</span>`; }

function renderAside() {
  const aside = document.getElementById("plan-aside");
  if (!aside) return;
  aside.dataset.open = String(asideOpen);
  const idx = dagIndex();
  const node = idx && selectedNodeId ? idx.nodeById[selectedNodeId] : null;
  const collapseBtn = `<button class="plan-aside-toggle" id="plan-aside-toggle" title="Collapse / expand drilldown" aria-expanded="${asideOpen}">${icon("i-chev")}</button>`;

  if (!asideOpen) { aside.innerHTML = collapseBtn; return; }
  if (!node) {
    aside.innerHTML = collapseBtn + `<div class="plan-aside-empty">${icon("i-diamond")}<div>select a node</div></div>`;
    return;
  }

  const g = node.gate || {};
  const gtone = gateTone(g.status);
  const deps = node.dependsOn || [];
  const dependents = (idx.dependents[node.id]) || [];
  const depChip = (nid) => `<button class="plan-depchip" data-plan-node="${escAttr(nid)}"><span class="dep-chip-id">${esc(nid)}</span></button>`;
  const en = nodeEnrich.get(node.id);
  const rollup = (node.tasks && node.tasks.taskIds || []).map((tid) => {
    const t = (S.snap && S.snap.l2Tasks || []).find((x) => x.id === tid) || { state: "idle" };
    return `<button class="plan-taskrow" data-plan-task="${escAttr(tid)}">
      <span class="tone-dot" data-tone="${toneOf(t.state)}"></span>
      <span class="mono plan-taskrow-id">${esc(tid)}</span>
      <span class="plan-taskrow-state">${esc(labelOf(t.state))}</span></button>`;
  }).join("");

  aside.innerHTML = collapseBtn +
    `<div class="plan-aside-head">
       <span class="plan-aside-id mono">${esc(node.id)}</span>
       <div class="plan-aside-chips">
         ${chip(node.stage)}${chip(node.area)}${node.kind ? chip(node.kind, "kind") : ""}
       </div>
     </div>
     <div class="plan-aside-gate">
       <span class="status-chip" data-tone="${gtone}"><span class="tone-dot" data-tone="${gtone}"></span><span>gate ${esc(g.status || "absent")}</span></span>
       ${g.recordedAt ? `<span class="plan-aside-meta">${esc(relTime(g.recordedAt, S.snap && S.snap.generatedAt))} ago${g.evidenceClass ? " · " + esc(g.evidenceClass) : ""}</span>` : ""}
     </div>
     ${node.requiredCompletion ? `<div class="plan-aside-block"><span class="meta-label">required completion</span><p class="plan-aside-text">${esc(node.requiredCompletion)}</p></div>` : ""}
     ${node.description ? `<div class="plan-aside-block"><span class="meta-label">description</span><p class="plan-aside-text">${esc(node.description)}</p></div>` : ""}
     <div class="plan-aside-block"><span class="meta-label">depends on · ${deps.length}</span><div class="chips-row">${deps.map(depChip).join("") || '<span class="section-empty">none</span>'}</div></div>
     <div class="plan-aside-block"><span class="meta-label">dependents · ${dependents.length}</span><div class="chips-row">${dependents.map(depChip).join("") || '<span class="section-empty">none</span>'}</div></div>
     <div class="plan-aside-block"><span class="meta-label">tasks · ${(node.tasks && node.tasks.counts && node.tasks.counts.total) || 0}</span><div class="plan-taskrows">${rollup || '<span class="section-empty">no tasks generated</span>'}</div></div>
     ${en && (en.plannerRuns || []).length ? `<div class="plan-aside-block"><span class="meta-label">planner runs · ${en.plannerRuns.length}</span></div>` : ""}`;
}

function wireAside() {
  const aside = document.getElementById("plan-aside");
  if (!aside) return;
  aside.addEventListener("click", (e) => {
    const t = e.target.closest("#plan-aside-toggle");
    if (t) { asideOpen = !asideOpen; localStorage.setItem("gluerun.plan.aside", asideOpen ? "1" : "0"); renderAside(); return; }
    const dep = e.target.closest("[data-plan-node]");
    if (dep) { selectPlanNode(dep.dataset.planNode); return; }
    const task = e.target.closest("[data-plan-task]");
    if (task) { select("l2", task.dataset.planTask); return; }
  });
}

// ------------------------------------------------------------- tick --------
// Called from the composed snapshot dispatcher (bus.onSnapshot). Pauses when the
// Plan surface is hidden so a backgrounded surface never churns.
export function planTick() {
  if (bus.planVisible && !bus.planVisible()) return;
  dagMaybeRefetch();
  if (mounted && mounted.update) mounted.update();
}

// ------------------------------------------------------------- init --------
export function initWorkbench() {
  if (started) return; started = true;
  curLens = localStorage.getItem("gluerun.plan.lens") || "timeline";
  if (!LENS_BY_ID[curLens]) curLens = "timeline";

  const nav = document.getElementById("plan-lensnav");
  if (nav) nav.addEventListener("click", (e) => {
    const b = e.target.closest("[data-lens]");
    if (b) setLens(b.dataset.lens);
  });
  wireAside();

  // Register the seams app.js / router.js call into.
  bus.onNodeSelect = selectPlanNode;
  bus.onTaskNavigate = (id) => { setLens("tasks"); if (mounted && mounted.focusTask) mounted.focusTask(id); };

  // Mount the stored lens now; refetch the DAG and re-evaluate lens availability
  // (an empty DAG forces the Tasks lens) once it arrives.
  setLens(curLens, { route: false });
  renderAside();
  onDag(() => { if (dagIsEmpty() && curLens !== "tasks") setLens("tasks"); renderNav(); if (mounted && mounted.update) mounted.update(); });
  fetchDag();
}
