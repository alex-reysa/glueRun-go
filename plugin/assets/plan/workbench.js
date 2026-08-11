/* plan/workbench.js — the Plan surface shell. Owns the toolbar lens tablist, mounts
   exactly one lens at a time into #plan-pane, and drives the right drilldown
   aside. Shared node selection (selectPlanNode) updates the route, tells the
   mounted lens to ring/scroll the node, and renders the aside. Ported from
   PlanGraphWorkbench.tsx (toolbar tablist · center pane · 360px aside). */

import { S, esc, escAttr, icon, toneOf, labelOf, gateTone, select, relTime } from "../app.js";
import { writeRoute, currentRoute } from "../core/router.js";
import { bus } from "../core/bus.js";
import { apiFetch } from "../core/api.js";
import { fetchDag, getDag, dagIndex, dagMaybeRefetch, onDag } from "./data.js";
import { lens as timelineLens } from "./lens_timeline.js";
import { lens as matrixLens } from "./lens_matrix.js";
import { lens as dagLens } from "./lens_dag.js";
import { lens as tasksLens } from "./lens_tasks.js";
import { LENSES, isPlanLens } from "./lenses.js";

const LENS_BY_ID = {
  timeline: timelineLens,
  matrix: matrixLens,
  dag: dagLens,
  tasks: tasksLens,
};

let curLens = null;          // current lens id
let mounted = null;          // current lens object (mounted)
let selectedNodeId = null;   // shared plan-node selection (drives the aside)
let asideOpen = localStorage.getItem("singular.plan.aside") !== "0";
let nodeEnrich = new Map();   // nodeId -> /api/node detail (aside lazy-enrich)
let started = false;

export function getLens() { return curLens; }

// ------------------------------------------------------------ lens nav -----
function renderNav() {
  const nav = document.getElementById("plan-lens-tabs");
  if (!nav) return;
  const empty = dagIsEmpty();
  nav.innerHTML = LENSES.map((l) => {
      const on = l.id === curLens;
      const dim = empty && l.id !== "tasks";
      return `<button type="button" class="tab" role="tab" data-lens="${l.id}" aria-selected="${on}" tabindex="${on ? 0 : -1}"${dim ? ' data-empty="1"' : ""}>${esc(l.label)}</button>`;
    }).join("");
}

function dagIsEmpty() { const d = getDag(); return !!d && (d.nodes || []).length === 0; }

export function setLens(id, opts) {
  if (!isPlanLens(id) || !LENS_BY_ID[id]) id = "tasks";
  // With an empty DAG only the Tasks lens is meaningful.
  if (dagIsEmpty()) id = "tasks";
  const pane = document.getElementById("plan-pane");
  if (id !== curLens || !mounted) {
    if (mounted && mounted.unmount) { try { mounted.unmount(); } catch (e) {} }
    curLens = id;
    localStorage.setItem("singular.plan.lens", id);
    mounted = LENS_BY_ID[id];
    if (pane) pane.dataset.lens = id;
    if (mounted && mounted.mount) mounted.mount(pane);
  }
  renderNav();
  if (!opts || opts.route !== false) {
    // Switching lenses must keep whatever selection is on the route (a TASK-xxxx
    // bottom-sheet or a NODE aside) so a copied URL still reopens it.
    const r = currentRoute();
    const sel = r.surface === "plan" && r.sel ? r.sel : (selectedNodeId ? "NODE:" + selectedNodeId : null);
    writeRoute("plan", id, sel, r.surface === "plan" ? r.tab : null);
  }
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
    const res = await apiFetch("/api/node/" + encodeURIComponent(id), { cache: "no-store" });
    if (!res.ok) return;
    nodeEnrich.set(id, await res.json());
    if (selectedNodeId === id) renderAside();
  } catch (e) { /* aside renders fine from the DAG node without enrichment */ }
}

// ------------------------------------------------------------- aside -------
function chip(text, cls) { return `<span class="plan-chip${cls ? " " + cls : ""}">${esc(text)}</span>`; }

// One plain sentence under the gate chip saying why this node is not moving —
// the gate status alone cannot distinguish "waiting for an operator" from
// "waiting for a prerequisite" from "already done, in an earlier campaign", and
// an unexplained stall reads as a broken engine (PMGO-001 / AXON-002). Every
// field is optional: the server grows humanGate / runnable / exclusion / cohort
// in a separate change and this must stay silent, not wrong, without them.
function asideStatusNote(node) {
  const g = node.gate || {};
  const hg = node.humanGate || null;
  const ok = g.status === "passed" || g.status === "passed-with-acknowledged-baseline";
  const historical = g.cohort === "historical" || g.evidenceClass === "grandfathered";
  // The gate is projected onto the node that carries it (humanGate) and named on
  // every node it holds up (humanGateBlockedBy, a list of carrier ids).
  const blockedBy = node.humanGateBlockedBy;
  const blockedList = Array.isArray(blockedBy) ? blockedBy.join(", ") : (blockedBy || "");
  if (hg && hg.state && hg.state !== "approved") {
    const id = hg.gateId || hg.id || blockedList;
    const why = hg.reason || hg.detail || (hg.state === "pending" ? "operator approval pending" : String(hg.state));
    return `blocked by human gate${id ? " " + id : ""} — ${why}`;
  }
  if (blockedList) return `blocked by human gate ${blockedList} — operator approval pending`;
  if (node.runnable === false) {
    const ex = node.exclusion || {};
    return `serialized — ${ex.detail || ex.reason || "another node in this area holds a lease"}`;
  }
  if (ok && historical) {
    const when = g.recordedAt ? String(g.recordedAt).slice(0, 10) : "";
    return `historically complete (grandfathered${when ? " " + when : ""})`;
  }
  return "";
}

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
  const statusNote = asideStatusNote(node);
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
       <span class="insp-raw-cluster" style="margin-left:auto">
         <button class="insp-raw-btn" data-raw-root="gate" data-raw-name="${escAttr(node.id)}.gate-result.json" data-raw-title="gate ${escAttr(node.id)}" title="view source · gate">{ }<span class="irb-label">gate</span></button>
         <button class="insp-raw-btn" data-raw-root="dag" data-raw-name="dag.v0.json" data-raw-title="dag.v0.json" title="view source · dag">{ }<span class="irb-label">dag</span></button>
       </span>
     </div>
     ${statusNote ? `<div class="plan-aside-note">${esc(statusNote)}</div>` : ""}
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
    if (t) { asideOpen = !asideOpen; localStorage.setItem("singular.plan.aside", asideOpen ? "1" : "0"); renderAside(); return; }
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
  curLens = localStorage.getItem("singular.plan.lens") || "timeline";
  if (!isPlanLens(curLens) || !LENS_BY_ID[curLens]) curLens = "timeline";

  const nav = document.getElementById("plan-lens-tabs");
  if (nav) {
    nav.addEventListener("click", (e) => {
      const b = e.target.closest("[data-lens]");
      if (b) setLens(b.dataset.lens);
    });
    // A horizontal tablist uses one tab stop, then arrow/Home/End navigation.
    // renderNav() replaces the buttons after activation, so focus the freshly
    // rendered active tab rather than the detached pre-render button.
    nav.addEventListener("keydown", (e) => {
      const current = e.target.closest('[role="tab"][data-lens]');
      if (!current || !["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) return;
      const tabs = [...nav.querySelectorAll('[role="tab"][data-lens]')];
      const at = tabs.indexOf(current);
      if (at < 0 || !tabs.length) return;
      let next = at;
      if (e.key === "Home") next = 0;
      else if (e.key === "End") next = tabs.length - 1;
      else next = (at + (e.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length;
      e.preventDefault();
      const id = tabs[next].dataset.lens;
      setLens(id);
      // setLens may coerce an unavailable lens (empty DAG -> Tasks); follow the
      // resulting selected tab, not the originally requested id.
      const active = nav.querySelector('[role="tab"][aria-selected="true"]');
      if (active) active.focus();
    });
  }
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
