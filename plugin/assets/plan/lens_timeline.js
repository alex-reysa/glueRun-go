/* plan/lens_timeline.js — the Timeline lens (flagship). Projects /api/timeline
   onto a compressed real-time axis: activity segments padded ±10min, gaps >45min
   collapsed to fixed break cells, hour gridlines + day rules with sticky date
   labels, and a NOW line. Lanes are area groups (collapsible) over node lanes
   whose bars are greedy row-packed on real ms. Bars carry the shared state
   vocabulary; retries chain with dotted connectors; gate marks are coral
   diamonds; L0 cycles a strip up top. Hover dims unrelated lanes and traces the
   task's node dependencies (blue) / dependents (green) to their bar hulls.

   Built once per signature (task count · max end · live ids · gates · cycles);
   live bars get a width-only patch each tick — never an innerHTML rebuild. */

import { S, esc, escAttr, icon, gateTone, select } from "../app.js";
import { bus } from "../core/bus.js";
import { getDag, dagIndex, fetchTimeline, getTimeline } from "./data.js";

const GUTTER = 210, BAR_H = 22, GAP = 6, LANE_PAD = 8;
const BREAK_W = 28, AREA_HEAD_H = 30, HEATLINE_H = 30, AXIS_H = 46, CYCLE_H = 4;
const M = 60000;
const MON = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];

let pane = null, sigLast = null, selectedTask = null;
let openAreas = null;        // Set<area>
let axis = null, barIndex = {}, nodeHull = {}, laneY = {};
let hostEl = null, scrollEl = null, overlayEl = null, detailEl = null;

// ------------------------------------------------------------- axis --------
function buildAxis(data, paneW) {
  const spans = [];
  const nowMs = Date.parse(data.now);
  for (const t of data.tasks) for (const iv of t.intervals) {
    const s = Date.parse(iv.startedAt); if (isNaN(s)) continue;
    let e = iv.endedAt ? Date.parse(iv.endedAt) : nowMs;
    if (isNaN(e) || e < s) e = s + M;
    spans.push([s, e]);
  }
  for (const c of data.cycles) { const s = Date.parse(c.startedAt); if (isNaN(s)) continue; const e = c.endedAt ? Date.parse(c.endedAt) : s; spans.push([s, isNaN(e) ? s : e]); }
  const times = [];
  for (const [s, e] of spans) times.push(s, e);
  for (const g of data.gates) { const t = Date.parse(g.recordedAt); if (!isNaN(t)) times.push(t); }
  if (!isNaN(nowMs)) times.push(nowMs);
  times.sort((a, b) => a - b);
  if (!times.length) return null;

  const GAP45 = 45 * M, PAD = 10 * M;
  const raw = []; let segS = times[0], prev = times[0];
  for (let i = 1; i < times.length; i++) { const t = times[i]; if (t - prev > GAP45) { raw.push([segS, prev]); segS = t; } prev = t; }
  raw.push([segS, prev]);
  const segs = raw.map(([s, e]) => ({ s: s - PAD, e: e + PAD, rawS: s, rawE: e }));
  const activeMin = segs.reduce((a, g) => a + (g.e - g.s) / M, 0);
  const targetW = Math.max(2600, 3 * paneW);
  const SCALE = Math.max(0.5, Math.min(2.0, targetW / Math.max(1, activeMin)));
  let run = 0; const breaks = [];
  segs.forEach((g, i) => {
    g.x0 = run; g.w = (g.e - g.s) / M * SCALE; run += g.w;
    if (i < segs.length - 1) { breaks.push({ x: run, fromE: raw[i][1], toS: raw[i + 1][0] }); run += BREAK_W; }
  });
  const xOf = (ms) => {
    if (ms <= segs[0].s) return segs[0].x0;
    for (let i = 0; i < segs.length; i++) {
      const g = segs[i];
      if (ms <= g.e) return g.x0 + Math.max(0, ms - g.s) / M * SCALE;
      if (i < segs.length - 1 && ms < segs[i + 1].s) return g.x0 + g.w + BREAK_W / 2;
    }
    const last = segs[segs.length - 1]; return last.x0 + last.w;
  };
  return { segs, breaks, xOf, totalWidth: run, SCALE, nowMs };
}

const fmtDur = (mins) => { const h = Math.floor(mins / 60), m = Math.round(mins % 60); return h ? `${h}h ${m}m` : `${m}m`; };

// split an interval into per-segment pieces (so a bar crossing a break renders split)
function pieces(s, e) {
  const out = [];
  for (const g of axis.segs) { const a = Math.max(s, g.s), b = Math.min(e, g.e); if (b > a) out.push([a, b]); }
  return out.length ? out : [[s, Math.max(e, s + M)]];
}

// ------------------------------------------------------------- build -------
function build() {
  const data = getTimeline();
  if (!pane) return;
  if (!data || !(data.tasks || []).length) { pane.innerHTML = `<div class="plan-lens-empty">no runtime activity recorded yet</div>`; sigLast = sigOf(data); return; }

  const paneW = pane.clientWidth || 900;
  axis = buildAxis(data, paneW);
  if (!axis) { pane.innerHTML = `<div class="plan-lens-empty">no runtime activity recorded yet</div>`; return; }
  const idx = dagIndex();
  const stageOf = (nid) => (idx && idx.nodeById[nid] ? idx.nodeById[nid].stage : "");
  const gateByNode = {}; for (const g of data.gates) gateByNode[g.node] = g;

  // group tasks: area -> node(or "(unattributed)") -> [tasks]
  const areas = {};
  for (const t of data.tasks) {
    const a = t.area || "(none)"; const nkey = t.node || "(unattributed)";
    (areas[a] = areas[a] || {});
    (areas[a][nkey] = areas[a][nkey] || []).push(t);
  }
  const areaFirst = (a) => Math.min(...Object.values(areas[a]).flat().flatMap((t) => t.intervals.map((iv) => Date.parse(iv.startedAt) || Infinity)));
  const areaOrder = Object.keys(areas).sort((x, y) => areaFirst(x) - areaFirst(y));

  if (openAreas == null) {
    openAreas = new Set();
    const stored = localStorage.getItem("gluerun.plan.tl.open");
    if (stored != null) { try { openAreas = new Set(JSON.parse(stored)); } catch (e) {} }
    else for (const a of areaOrder) if (Object.values(areas[a]).flat().some((t) => t.status !== "integrated")) openAreas.add(a);
  }

  barIndex = {}; nodeHull = {}; laneY = {};
  let y = AXIS_H;
  let rowsHtml = `<div class="tl-row tl-axis-spacer" style="height:${AXIS_H}px"><div class="tl-gutter tl-corner"></div><div class="tl-track"></div></div>`;

  for (const a of areaOrder) {
    const nodesInArea = Object.keys(areas[a]).sort((x, y2) => (stageOf(x) || "").localeCompare(stageOf(y2) || "") || x.localeCompare(y2));
    const allTasks = Object.values(areas[a]).flat();
    const gatesPassed = nodesInArea.filter((n) => (gateByNode[n] || {}).status === "passed").length;
    const open = openAreas.has(a);
    rowsHtml += `<div class="tl-row tl-arearow" style="height:${AREA_HEAD_H}px">
      <button class="tl-gutter tl-area-head" data-area="${escAttr(a)}" aria-expanded="${open}">
        <span class="tl-area-chev">${icon("i-chev")}</span><span class="tl-area-name">${esc(a)}</span>
        <span class="tl-area-meta mono">${nodesInArea.length}n · ${gatesPassed}/${nodesInArea.length}</span></button>
      <div class="tl-track tl-area-band"></div></div>`;
    y += AREA_HEAD_H;

    if (!open) {
      // collapsed → single heatline row of micro-bars
      let micro = "";
      for (const t of allTasks) for (const iv of t.intervals) {
        const s = Date.parse(iv.startedAt); let e = iv.endedAt ? Date.parse(iv.endedAt) : axis.nowMs; if (e < s) e = s + M;
        for (const [ps, pe] of pieces(s, e)) micro += `<span class="tl-heat" style="left:${axis.xOf(ps)}px;width:${Math.max(2, axis.xOf(pe) - axis.xOf(ps))}px"></span>`;
      }
      rowsHtml += `<div class="tl-row" style="height:${HEATLINE_H}px">
        <div class="tl-gutter tl-heat-gutter">${allTasks.length} tasks · collapsed</div>
        <div class="tl-track tl-heatline">${micro}</div></div>`;
      y += HEATLINE_H;
      continue;
    }

    for (const nkey of nodesInArea) {
      const tasks = areas[a][nkey].slice().sort((t1, t2) => taskStart(t1) - taskStart(t2));
      // greedy row packing on task span
      const rowEnds = []; const place = {};
      for (const t of tasks) {
        const st = taskStart(t); let ri = rowEnds.findIndex((e) => st >= e);
        if (ri < 0) { ri = rowEnds.length; rowEnds.push(0); }
        rowEnds[ri] = taskEnd(t); place[t.taskId] = ri;
      }
      const nRows = Math.max(1, rowEnds.length);
      const laneH = nRows * (BAR_H + GAP) - GAP + LANE_PAD * 2;
      const laneTop = y;
      laneY[nkey] = laneTop + laneH / 2;

      let bars = "";
      let nodeX0 = Infinity, nodeX1 = -Infinity;
      for (const t of tasks) {
        const row = place[t.taskId];
        const barTop = LANE_PAD + row * (BAR_H + GAP);
        const st2 = barState(t);
        const title = titleOf(t.taskId);
        let prevRight = null, taskX0 = Infinity, taskX1 = -Infinity;
        t.intervals.forEach((iv, ii) => {
          let s = Date.parse(iv.startedAt); let e = iv.endedAt ? Date.parse(iv.endedAt) : axis.nowMs;
          const amber = e < s; if (amber) e = s + M;
          pieces(s, e).forEach(([ps, pe], pi) => {
            const left = axis.xOf(ps); let width = Math.max(18, axis.xOf(pe) - left);
            if (t.liveNow && !iv.endedAt) width = Math.max(18, axis.xOf(axis.nowMs) - left);
            taskX0 = Math.min(taskX0, left); taskX1 = Math.max(taskX1, left + width);
            const first = ii === 0 && pi === 0;
            const retryChip = ii > 0 && pi === 0 ? `<span class="tl-retry">↻${ii}</span>` : "";
            const labelOut = width < 90 ? " tl-label-out" : "";
            const lab = first ? `<span class="tl-bar-label${labelOut}">${esc(t.taskId)}${title ? " · " + esc(title) : ""}</span>` : "";
            bars += `<div class="tl-bar tl-s-${st2}${amber ? " tl-amber" : ""}${t.liveNow && !iv.endedAt ? " tl-live" : ""}" data-task="${escAttr(t.taskId)}" data-node="${escAttr(nkey)}" data-live="${t.liveNow && !iv.endedAt ? 1 : 0}"
              style="left:${left}px;top:${barTop}px;width:${width}px">${retryChip}${lab}</div>`;
          });
          if (prevRight != null) {
            const cx = axis.xOf(Date.parse(iv.startedAt));
            bars += `<span class="tl-retry-link" style="left:${prevRight}px;top:${barTop + BAR_H / 2}px;width:${Math.max(0, cx - prevRight)}px"></span>`;
          }
          prevRight = axis.xOf(e);
        });
        nodeX0 = Math.min(nodeX0, taskX0); nodeX1 = Math.max(nodeX1, taskX1);
        barIndex[t.taskId] = { node: nkey, x0: isFinite(taskX0) ? taskX0 : 0, x1: isFinite(taskX1) ? taskX1 : 0, y: laneTop + barTop + BAR_H / 2 };
      }
      const g = gateByNode[nkey];
      let gate = "";
      if (g && g.recordedAt) {
        const gx = axis.xOf(Date.parse(g.recordedAt));
        const passed = g.status === "passed";
        gate = `<span class="tl-gate${passed ? " passed" : ""}" style="left:${gx}px;top:${laneH - 12}px" title="${escAttr((g.evidenceClass || "") + " · " + g.recordedAt)}">${passed ? icon("i-check") : ""}</span>`;
      }
      nodeHull[nkey] = { y: laneY[nkey], x0: isFinite(nodeX0) ? nodeX0 : 0, x1: isFinite(nodeX1) ? nodeX1 : 0 };
      const gtone = gateTone((gateByNode[nkey] || {}).status);
      rowsHtml += `<div class="tl-row" style="height:${laneH}px">
        <button class="tl-gutter tl-node-gutter" data-node="${escAttr(nkey)}"><span class="tone-dot" data-tone="${gtone}"></span><span class="mono tl-node-id">${esc(nkey)}</span></button>
        <div class="tl-track tl-lane" data-nodelane="${escAttr(nkey)}">${bars}${gate}</div></div>`;
      y += laneH;
    }
  }

  const contentH = y + 20;
  const totalW = axis.totalWidth;

  // background: hour/day gridlines, break cells, day labels, NOW, cycles strip
  let bg = "";
  // cycles strip
  let cyc = "";
  data.cycles.forEach((c, i) => {
    const s = Date.parse(c.startedAt), e = c.endedAt ? Date.parse(c.endedAt) : s;
    const x = axis.xOf(s), w = Math.max(2, axis.xOf(Math.max(e, s + M)) - x);
    cyc += `<span class="tl-cycle" style="left:${x}px;width:${w}px;${i % 2 ? "opacity:0.5" : ""}"></span>`;
  });
  bg += `<div class="tl-cycle-strip" style="width:${totalW}px">${cyc}</div>`;
  // gridlines per segment
  for (const g of axis.segs) {
    let t = Math.ceil(g.rawS / 3600000) * 3600000;
    for (; t <= g.rawE; t += 3600000) {
      const x = axis.xOf(t);
      const d = new Date(t);
      const midnight = d.getUTCHours() === 0;
      if (midnight) {
        bg += `<div class="tl-dayrule" style="left:${x}px;height:${contentH}px"></div>`;
        bg += `<div class="tl-daylabel" style="left:${x + 4}px">${MON[d.getUTCMonth()]} ${d.getUTCDate()}</div>`;
      } else {
        bg += `<div class="tl-hourline" style="left:${x}px;height:${contentH}px"></div>`;
      }
    }
  }
  // break cells
  for (const b of axis.breaks) {
    const mins = (b.toS - b.fromE) / M;
    bg += `<div class="tl-break" style="left:${b.x}px;width:${BREAK_W}px;height:${contentH}px"><span class="tl-break-l1"></span><span class="tl-break-l2"></span><span class="tl-break-lbl">${esc(fmtDur(mins))}</span></div>`;
  }
  // NOW line
  const nowX = axis.xOf(axis.nowMs);
  bg += `<div class="tl-now" style="left:${nowX}px;height:${contentH}px"><span class="tl-now-cap">NOW</span></div>`;

  pane.style.overflow = "hidden";
  pane.innerHTML =
    `<div class="plan-tl-scroll"><div class="plan-tl" style="width:${GUTTER + totalW}px;min-height:${contentH}px">
       <div class="tl-bg" style="left:${GUTTER}px;width:${totalW}px;height:${contentH}px">${bg}</div>
       <svg class="tl-overlay" style="left:${GUTTER}px;width:${totalW}px;height:${contentH}px"></svg>
       <div class="tl-flow">${rowsHtml}</div>
       <div class="plan-detail-card tl-detail" hidden></div>
     </div></div>`;

  scrollEl = pane.querySelector(".plan-tl-scroll");
  overlayEl = pane.querySelector(".tl-overlay");
  detailEl = pane.querySelector(".tl-detail");
  wire();
  sigLast = sigOf(data);
}

function taskStart(t) { return Math.min(...t.intervals.map((iv) => Date.parse(iv.startedAt) || Infinity)); }
function taskEnd(t) { return Math.max(...t.intervals.map((iv) => (iv.endedAt ? Date.parse(iv.endedAt) : (axis ? axis.nowMs : Date.now())) || 0)); }
function titleOf(id) { const t = (S.snap && S.snap.l2Tasks || []).find((x) => x.id === id); return t ? t.title : ""; }
function barState(t) {
  if (t.liveNow) return "live";
  const s = t.status;
  if (s === "integrated") return "integrated";
  if (s === "failed" || s === "blocked") return "failed";
  if (s === "awaiting" || s === "accepted") return "awaiting";
  return "active";
}

// ------------------------------------------------------------- hover -------
function applyHover(taskId) {
  const bars = pane.querySelectorAll(".tl-bar");
  if (!taskId) { bars.forEach((b) => { b.style.opacity = ""; }); overlayEl.innerHTML = ""; if (detailEl) detailEl.hidden = true; return; }
  const idx = dagIndex();
  const info = barIndex[taskId]; if (!info) return;
  const node = info.node;
  const deps = idx && idx.nodeById[node] ? (idx.nodeById[node].dependsOn || []) : [];
  const dependents = idx ? (idx.dependents[node] || []) : [];
  const related = new Set([node, ...deps, ...dependents]);
  bars.forEach((b) => { b.style.opacity = related.has(b.dataset.node) ? "1" : "0.28"; });
  // connectors from this bar to dep/dependent node hulls
  const from = info;
  let paths = "";
  const orth = (x1, y1, x2, y2, color) => { const mx = (x1 + x2) / 2; return `<path d="M${x1},${y1} L${mx},${y1} L${mx},${y2} L${x2},${y2}" fill="none" stroke="${color}" stroke-width="1.5" opacity="0.85"/>`; };
  for (const d of deps) { const h = nodeHull[d]; if (h) paths += orth(from.x0, from.y, h.x1, h.y, "var(--tone-blue-dot)"); }
  for (const d of dependents) { const h = nodeHull[d]; if (h) paths += orth(from.x1, from.y, h.x0, h.y, "var(--tone-green-dot)"); }
  overlayEl.innerHTML = paths;
  showDetail(taskId);
}

function showDetail(taskId) {
  if (!detailEl) return;
  const data = getTimeline(); const t = data.tasks.find((x) => x.taskId === taskId); if (!t) return;
  const idx = dagIndex();
  const deps = idx && idx.nodeById[t.node] ? (idx.nodeById[t.node].dependsOn || []).join(" · ") || "—" : "—";
  const dep2 = idx && t.node ? (idx.dependents[t.node] || []).join(" · ") || "—" : "—";
  const s = taskStart(t), e = taskEnd(t);
  const mins = Math.round((e - s) / M);
  const runId = (t.intervals[0] || {}).runId || "—";
  detailEl.innerHTML =
    `<div class="plan-detail-head"><span class="mono" style="font-size:11px;color:var(--text-secondary)">${esc(t.taskId)}</span>
       <span class="plan-chip">${esc(t.area || "—")}</span>
       <span style="margin-left:auto;font:600 9px var(--font-sans);letter-spacing:0.05em;text-transform:uppercase;color:var(--text-meta)">${esc(t.status)}</span></div>
     <div class="plan-detail-title">${esc(titleOf(t.taskId) || t.taskId)}</div>
     <div class="plan-detail-rule"></div>
     <div class="plan-detail-row"><span class="pdl">Window</span><span class="pdv mono">${fmtDur(mins)} · ${t.retryCount || 0} retries</span></div>
     <div class="plan-detail-row"><span class="pdl">Run</span><span class="pdv mono">${esc(String(runId).replace(/^RUN-/, "").slice(0, 16))}</span></div>
     <div class="plan-detail-row"><span class="pdl">Node deps</span><span class="pdv mono" style="color:var(--tone-blue-fg)">${esc(deps)}</span></div>
     <div class="plan-detail-row"><span class="pdl">Unblocks</span><span class="pdv mono" style="color:var(--tone-green-fg)">${esc(dep2)}</span></div>`;
  detailEl.hidden = false;
}

// live bars: width-only patch each tick (no rebuild)
function patchLive() {
  if (!pane || !axis) return;
  const nowX = axis.xOf(axis.nowMs);
  pane.querySelectorAll('.tl-bar[data-live="1"]').forEach((b) => {
    const left = parseFloat(b.style.left) || 0; b.style.width = Math.max(18, nowX - left) + "px";
  });
}

function wire() {
  const flow = pane.querySelector(".tl-flow");
  flow.addEventListener("click", (e) => {
    const head = e.target.closest(".tl-area-head");
    if (head) { const a = head.dataset.area; if (openAreas.has(a)) openAreas.delete(a); else openAreas.add(a); localStorage.setItem("gluerun.plan.tl.open", JSON.stringify([...openAreas])); sigLast = null; build(); return; }
    const node = e.target.closest(".tl-node-gutter");
    if (node) { if (node.dataset.node !== "(unattributed)" && bus.onNodeSelect) bus.onNodeSelect(node.dataset.node); return; }
    const bar = e.target.closest(".tl-bar[data-task]");
    if (bar) select("l2", bar.dataset.task);
  });
  flow.addEventListener("pointerover", (e) => { const b = e.target.closest(".tl-bar[data-task]"); if (b) applyHover(b.dataset.task); });
  flow.addEventListener("pointerout", (e) => { const b = e.target.closest(".tl-bar[data-task]"); if (b && !(e.relatedTarget && e.relatedTarget.closest && e.relatedTarget.closest(".tl-bar"))) applyHover(null); });
}

// ------------------------------------------------------------- iface -------
function sigOf(data) {
  if (!data) return "none";
  let maxEnd = 0; for (const t of data.tasks) for (const iv of t.intervals) { const e = iv.endedAt ? Date.parse(iv.endedAt) : 0; if (e > maxEnd) maxEnd = e; }
  return JSON.stringify([data.tasks.length, maxEnd, data.tasks.filter((t) => t.liveNow).map((t) => t.taskId), data.gates.length, data.cycles.length]);
}

async function refresh(initial) {
  await fetchTimeline();
  if (!pane) return;
  const data = getTimeline();
  const sig = sigOf(data);
  if (initial || sig !== sigLast) { const prev = scrollEl ? scrollEl.scrollLeft : 0; build(); if (scrollEl) scrollEl.scrollLeft = prev; }
  else patchLive();
}

export const lens = {
  mount(p) { pane = p; sigLast = null; if (getTimeline()) build(); else pane.innerHTML = `<div class="plan-lens-empty">loading timeline…</div>`; refresh(true); },
  update() { refresh(false); },
  applySelection(id) { /* node selection has no direct bar; hover drives relations */ },
  focusTask(id) {
    selectedTask = id;
    const b = pane && pane.querySelector(`.tl-bar[data-task="${window.CSS && CSS.escape ? CSS.escape(id) : id}"]`);
    if (b) b.scrollIntoView({ block: "center", inline: "center" });
  },
  unmount() { if (pane) pane.style.overflow = ""; pane = null; sigLast = null; barIndex = {}; },
};
