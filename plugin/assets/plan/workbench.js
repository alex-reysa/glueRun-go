/* plan/workbench.js — the Plan surface shell. Owns the toolbar lens tablist,
   mounts exactly one lens at a time into #plan-pane, and keeps shared node
   selection aligned across the four lenses, the route, and the app detail dock. */

import { esc, select } from "../app.js";
import { writeRoute, currentRoute } from "../core/router.js";
import { bus } from "../core/bus.js";
import { fetchDag, getDag, dagMaybeRefetch, onDag } from "./data.js";
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
let selectedNodeId = null;   // shared plan-node selection (rings every lens)
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
    // Switching lenses must keep whatever shared-dock selection is on the route
    // so a copied URL still reopens the same task or node in every view.
    const r = currentRoute();
    const sel = r.surface === "plan" && r.sel ? r.sel : (selectedNodeId ? "NODE:" + selectedNodeId : null);
    writeRoute("plan", id, sel, r.surface === "plan" ? r.tab : null);
  }
  if (selectedNodeId && mounted && mounted.applySelection) mounted.applySelection(selectedNodeId);
}

// -------------------------------------------------- shared node selection --
export function selectPlanNode(id) {
  selectedNodeId = id || null;
  writeRoute("plan", curLens, selectedNodeId ? "NODE:" + selectedNodeId : null, null);
  if (mounted && mounted.applySelection) mounted.applySelection(selectedNodeId);
  if (selectedNodeId) select("node", selectedNodeId, { fromPlan: true });
}

export function clearPlanSelection() {
  if (!selectedNodeId) return;
  selectedNodeId = null;
  if (mounted && mounted.applySelection) mounted.applySelection(null);
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
  // Register the seams app.js / router.js call into.
  bus.onNodeSelect = selectPlanNode;
  bus.onPlanSelectionClear = clearPlanSelection;
  bus.onTaskNavigate = (id) => { setLens("tasks"); if (mounted && mounted.focusTask) mounted.focusTask(id); };

  // Mount the stored lens now; refetch the DAG and re-evaluate lens availability
  // (an empty DAG forces the Tasks lens) once it arrives.
  setLens(curLens, { route: false });
  onDag(() => { if (dagIsEmpty() && curLens !== "tasks") setLens("tasks"); renderNav(); if (mounted && mounted.update) mounted.update(); });
  fetchDag();
}
