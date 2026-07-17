/* plan/lens_tasks.js — the Tasks lens. The exceptions-first task table, moved out
   of app.js's old list drawer into the workbench pane, plus a "node" column that
   maps each task to the DAG node it serves (clickable → plan aside). Filters,
   search, and exceptions-first sort are unchanged; a quiet poll rebuilds nothing
   (signature-gated), selection/pin markers are applied over the prebuilt DOM. */

import { S, esc, escAttr, relTime, select, statusChip, highlight, shortBranch, tasksFiltered, sortExceptionsFirst } from "../app.js";
import { bus } from "../core/bus.js";
import { getDag, dagIndex } from "./data.js";

let pane = null;
let lastSig = null;

function listSig() {
  const rows = tasksFiltered();
  return JSON.stringify({
    v: "tasks", q: S.query, af: S.areaFilter, sf: S.statusFilter, dag: !!getDag(),
    rows: rows.map((t) => [t.id, t.state, t.updatedAt]),
  });
}

function render() {
  if (!pane) return;
  const idx = dagIndex();
  const t2n = idx ? idx.taskToNode : {};
  const rows = sortExceptionsFirst(tasksFiltered());
  const now = S.snap && S.snap.generatedAt;
  let body = rows.map((t) => {
    const node = t2n[t.id];
    const nodeCell = node
      ? `<button class="plan-node-link" data-plan-node="${escAttr(node)}">${esc(node)}</button>`
      : `<span class="plan-node-none">—</span>`;
    return `<tr data-task-id="${escAttr(t.id)}" data-layer="l2" data-selected="${S.selectedId === t.id}" data-pinned="${S.pinnedId === t.id}">
      <td>${statusChip(t.state)}</td>
      <td class="c-id">${highlight(t.id, S.query)}</td>
      <td class="c-title">${highlight(t.title || "", S.query)}</td>
      <td class="c-area">${esc(t.area)}</td>
      <td class="c-node">${nodeCell}</td>
      <td class="c-branch">${highlight(shortBranch(t.workerBranch), S.query)}</td>
      <td class="c-updated">${esc(relTime(t.updatedAt, now))}</td>
    </tr>`;
  }).join("");
  if (!rows.length) body = `<tr><td colspan="7" class="lane-empty" style="padding:16px">no tasks match the current filters</td></tr>`;
  pane.innerHTML = `<div class="list-pad"><table class="task-table">
    <thead><tr><th>state</th><th>id</th><th>title</th><th>area</th><th>node</th><th>branch</th><th>upd</th></tr></thead>
    <tbody>${body}</tbody></table></div>`;
  lastSig = listSig();
}

function applyMarkers() {
  if (!pane) return;
  pane.querySelectorAll("tr[data-task-id]").forEach((el) => {
    el.dataset.selected = String(el.dataset.taskId === S.selectedId);
    el.dataset.pinned = String(el.dataset.taskId === S.pinnedId);
  });
}

export const lens = {
  mount(p) {
    pane = p;
    if (!pane) return;
    render();
    if (!pane._tasksWired) {
      pane._tasksWired = true;
      pane.addEventListener("click", (e) => {
        const nodeLink = e.target.closest("[data-plan-node]");
        if (nodeLink) { e.stopPropagation(); if (bus.onNodeSelect) bus.onNodeSelect(nodeLink.dataset.planNode); return; }
        const row = e.target.closest("tr[data-task-id]");
        if (row) select("l2", row.dataset.taskId);
      });
    }
  },
  update() {
    if (!pane) return;
    const sig = listSig();
    if (sig !== lastSig) {
      const scroller = pane.closest("#plan-pane") || pane;
      const prev = scroller ? scroller.scrollTop : 0;
      render();
      if (scroller) scroller.scrollTop = prev;
    }
    applyMarkers();
  },
  applySelection() { applyMarkers(); },
  focusTask(id) {
    if (!pane) return;
    const row = pane.querySelector(`tr[data-task-id="${window.CSS && CSS.escape ? CSS.escape(id) : id}"]`);
    if (row) row.scrollIntoView({ block: "center" });
    applyMarkers();
  },
  unmount() { pane = null; lastSig = null; },
};
