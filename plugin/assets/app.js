/* glueRun-go orchestration console — client logic.
   Read-only. Renders durable orchestration state into a top/main/inspector
   console. Selection, pins, filters, and expansion live in JS state (never
   derived from the DOM) so the 10s auto-refresh never loses them. Views are
   re-rendered only when their inputs actually change (signature-gated), so a
   quiet snapshot produces zero rebuilds and zero scroll/selection loss. */

(() => {
  "use strict";

  const POLL_MS = 10000;
  const LANE_BUDGET = 40;  // max non-terminal L2 nodes shown per lane in the graph
  const MORE_STEP = 24;    // integrated tasks revealed per "+ more" click in the graph
  const $ = (id) => document.getElementById(id);

  // ---- pure state engine (tone + label) ----
  const STATE_TONE = {
    idle: "idle", stopped: "idle", draft: "idle",
    active: "active", awaiting: "awaiting", stale: "warn",
    blocked: "error", failed: "error", integrated: "success",
  };
  const STATE_LABEL = {
    idle: "idle", stopped: "stopped", draft: "draft", active: "active",
    awaiting: "awaiting release", stale: "stale", blocked: "blocked",
    failed: "failed", integrated: "integrated",
  };
  const STATE_ORDER = { blocked: 0, failed: 1, active: 2, awaiting: 3, stale: 4, idle: 5, integrated: 6 };
  const toneOf = (state) => STATE_TONE[state] || "idle";
  const labelOf = (state) => STATE_LABEL[state] || state || "unknown";

  // ---- app state ----
  const S = {
    snap: null,
    listOpen: localStorage.getItem("gluerun.listOpen") === "1", // task-list drawer expanded?
    listHeight: parseInt(localStorage.getItem("gluerun.listH"), 10) || 260,
    query: "",
    areaFilter: "",
    statusFilter: "",
    expanded: null,        // Set<area>; seeded once from auto-expand heuristic
    selectedId: null,      // node id (TASK-xxxx | L0 | L1:area)
    selectedKind: "none",  // none | l0 | l1 | l2
    pinnedId: localStorage.getItem("gluerun.pinnedId") || null,
    inspTab: "overview",
    taskCache: new Map(),  // id -> detail
    taskInflight: new Set(),
    nodeCache: new Map(),      // nodeId -> /api/node detail
    nodeInflight: new Set(),
    areaNodesCache: new Map(), // area -> /api/area/<area>/nodes rows
    areaNodesInflight: new Set(),
    overview: null,            // /api/overview (plan progress + inputs + settings + status)
    overviewInflight: false,
    budgets: new Map(),    // area -> graph lane render budget (durable across polls)
    roleCatalog: null,     // /api/roles (declared reference), fetched once
    roleInflight: false,
    transform: { x: 0, y: 0, z: 1 }, // graph canvas pan/zoom (survives polls)
    graphBBox: null,
    _nodeIndex: null,      // id -> laid-out node (for panToNode / edge highlight)
    _graphFitted: false,
    _userPanned: false,
    _suppressClick: false, // set after a pan-drag so the trailing click doesn't select
    lastSig: {},
    lastOkAt: 0,
    connState: "down",
  };
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

  // ---------------------------------------------------------------- utils ---
  const esc = (v) => String(v == null ? "" : v).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  const escAttr = (v) => esc(v);

  function icon(id, extra) {
    return `<svg class="icon${extra ? " " + extra : ""}" aria-hidden="true"><use href="#${id}"/></svg>`;
  }

  function highlight(text, q) {
    const safe = esc(text);
    if (!q) return safe;
    const i = String(text).toLowerCase().indexOf(q);
    if (i < 0) return safe;
    const a = esc(String(text).slice(0, i));
    const b = esc(String(text).slice(i, i + q.length));
    const c = esc(String(text).slice(i + q.length));
    return `${a}<mark>${b}</mark>${c}`;
  }

  function relTime(iso, nowIso) {
    if (!iso) return "—";
    const t = Date.parse(iso), now = nowIso ? Date.parse(nowIso) : Date.now();
    if (isNaN(t)) return "—";
    let s = Math.max(0, Math.round((now - t) / 1000));
    if (s < 60) return s + "s";
    const m = Math.round(s / 60); if (m < 60) return m + "m";
    const h = Math.round(m / 60); if (h < 48) return h + "h";
    return Math.round(h / 24) + "d";
  }

  function shortBranch(b) {
    if (!b) return "";
    // agent/scheduler/TASK-0309-... -> ../TASK-0309-..
    const parts = String(b).split("/");
    return parts.length > 2 ? "…/" + parts.slice(2).join("/") : b;
  }

  function toast(msg) {
    const el = $("toast");
    el.textContent = msg;
    el.dataset.show = "true";
    clearTimeout(el._t);
    el._t = setTimeout(() => { el.dataset.show = "false"; }, 1600);
  }

  async function copy(text) {
    try { await navigator.clipboard.writeText(text); toast("copied " + text); }
    catch { toast("copy unavailable"); }
  }

  function toneDot(state, cls) {
    return `<span class="tone-dot${cls ? " " + cls : ""}" data-tone="${toneOf(state)}"></span>`;
  }
  function statusChip(state) {
    return `<span class="status-chip" data-tone="${toneOf(state)}">${toneDot(state)}<span>${esc(labelOf(state))}</span></span>`;
  }

  // ----------------------------------------------------------- data fetch ---
  async function load(fresh) {
    try {
      // An explicit Refresh invalidates the slow-changing provenance caches too.
      if (fresh) { S.nodeCache.clear(); S.areaNodesCache.clear(); }
      const res = await fetch("/api/state" + (fresh ? "?fresh=1" : ""), { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      S.snap = await res.json();
      S.lastOkAt = Date.now();
      setConn("connected");
      seedExpansion();
      seedSelection();
      renderAll();
      maybeRefreshOpenTask();
      fetchOverview(); // refresh the plan pill + overview panel (own cheap cached endpoint)
      if (!S.deepLinkApplied) { S.deepLinkApplied = true; applyDeepLink(); }
    } catch (err) {
      setConn("down");
      console.error("[gluerun] load failed:", err && err.stack ? err.stack : err);
    }
  }

  function setConn(state) {
    if (S.connState !== state) {
      const sr = $("sr-status");
      if (sr) sr.textContent = state === "connected" ? "connection live" : state === "stale" ? "snapshot stale" : "connection lost";
    }
    S.connState = state;
    $("conn-dot").dataset.state = state;
  }

  function seedExpansion() {
    if (S.expanded) return;
    S.expanded = new Set();
    const areas = (S.snap.agents && S.snap.agents.l1) || [];
    for (const a of areas) {
      const sc = a.stateCounts || {};
      const hot = (sc.active || 0) + (sc.awaiting || 0) + (sc.blocked || 0) + (sc.failed || 0) + (sc.stale || 0);
      if (hot > 0) S.expanded.add(a.area);
    }
  }

  function seedSelection() {
    // If a pin survives reloads but its task vanished, drop it gracefully.
    if (S.pinnedId && S.pinnedId.startsWith("TASK-")) {
      const exists = (S.snap.l2Tasks || []).some((t) => t.id === S.pinnedId);
      if (!exists) { S.pinnedId = null; localStorage.removeItem("gluerun.pinnedId"); }
    }
  }

  // -------------------------------------------------------- filtering core ---
  function tasksFiltered() {
    const q = S.query;
    const out = [];
    for (const t of S.snap.l2Tasks || []) {
      if (S.areaFilter && t.area !== S.areaFilter) continue;
      if (S.statusFilter && t.state !== S.statusFilter) continue;
      if (q) {
        const hay = [t.id, t.title, t.workerBranch, t.area].join(" ").toLowerCase();
        if (!hay.includes(q)) continue;
      }
      out.push(t);
    }
    return out;
  }

  function sortExceptionsFirst(list) {
    return list.slice().sort((a, b) => {
      const d = (STATE_ORDER[a.state] ?? 9) - (STATE_ORDER[b.state] ?? 9);
      if (d) return d;
      return (numId(b.id) - numId(a.id));
    });
  }
  const numId = (id) => { const m = /(\d+)/.exec(id || ""); return m ? +m[1] : -1; };

  // ============================================================ TOP BAR =====
  function renderTop() {
    const d = S.snap;
    const o = d.orchestration || {};
    const na = o.nextArea || {};
    const drift = (d.git && d.git.drift) || { left: 0, right: 0 };
    const disk = d.disk || {};
    const sc = (d.summary && d.summary.stateCounts) || {};

    // health flag
    const healthTone = d.health === "healthy" ? "success" : d.health === "blocker" ? "error" : "warn";
    const hf = $("health-flag"); hf.dataset.tone = healthTone;
    $("health-text").textContent = d.health || "—";

    // stop chip — amber when present (an intentional hold, not a fault)
    const stopPresent = !!(d.stop && d.stop.present);
    const stopChip = $("stop-chip");
    stopChip.dataset.present = String(stopPresent);
    stopChip.dataset.tone = stopPresent ? "warn" : "idle";
    $("stop-text").textContent = stopPresent ? "stop present" : "stop clear";

    // drift
    const driftTone = drift.left ? "error" : drift.right ? "warn" : "idle";
    $("stat-drift").innerHTML = `${toneDot(driftTone === "error" ? "blocked" : driftTone === "warn" ? "stale" : "idle")}<span class="num">${drift.left} · ${drift.right}</span>`;

    // frontier — plural ready-node count (violet), plus active L1 planners (cobalt)
    const frontierNodes = (o.nextAreas && Array.isArray(o.nextAreas.frontier)) ? o.nextAreas.frontier : [];
    const frCount = (d.summary && d.summary.frontierCount != null) ? d.summary.frontierCount
      : (frontierNodes.length || (na.node ? 1 : 0));
    const planners = (d.summary && d.summary.l1PlannersActive) || 0;
    const frTxt = frCount ? `${frCount} ready` : "none";
    const plannerSeg = planners
      ? ` <span class="tone-dot" data-tone="active" title="active L1 planners"></span><span class="num" title="active L1 planners">${planners}</span>`
      : "";
    $("stat-frontier").innerHTML =
      `<span class="tone-dot" data-tone="integration"></span><span class="num">${frTxt}</span>${plannerSeg}`;

    // active / awaiting / blocked counters (filter pills)
    setCounter("active", sc.active || 0, "active");
    setCounter("awaiting", sc.awaiting || 0, "awaiting");
    setCounter("blocked", (sc.blocked || 0) + (sc.failed || 0), "blocked");

    // disk
    const diskTone = disk.watch ? "stale" : "integrated";
    $("stat-disk").innerHTML = `${toneDot(diskTone)}<span class="num">${disk.capacityPercent != null ? disk.capacityPercent + "%" : "—"}</span> <span class="unit">${esc(disk.free || "?")} free</span>`;

    // gates + dag
    const gate = (label, run) => {
      const ok = run && run.ok;
      const tone = ok ? "integrated" : "blocked";
      return `<span class="gate-tag" data-tone="${toneOf(tone)}">${toneDot(tone)}<span class="lbl">${label}</span></span>`;
    };
    $("stat-gates").innerHTML =
      gate("D0", o.gateD0) + gate("D1", o.gateD1) + gate("dag", o.validateDag);
  }

  function setCounter(stat, n, state) {
    const el = $("stat-" + stat);
    const tone = n > 0 ? toneOf(state) : "idle";
    el.innerHTML = `<span class="tone-dot" data-tone="${tone}"></span><span class="num">${n}</span>`;
    const pill = document.querySelector(`.stat-pill[data-stat="${stat}"]`);
    if (pill) {
      pill.style.setProperty("--tone", `var(--tone-${tone === "idle" ? "gray" : tone === "warn" ? "amber" : tone === "error" ? "red" : tone === "success" ? "forest" : tone === "awaiting" || tone === "active" ? "cobalt" : "gray"})`);
      pill.setAttribute("aria-pressed", String(S.statusFilter === stat || (stat === "blocked" && (S.statusFilter === "blocked" || S.statusFilter === "failed"))));
    }
  }

  const shortRun = (r) => String(r || "").replace(/^ORIGIN-|^RUN-/, "").slice(0, 16);

  // ============================================================= GRAPH ======
  function graphSig() {
    const ag = S.snap.agents || {};
    return JSON.stringify({
      v: "graph",
      // include l1Active + the active lease node so the planner overlay repaints
      l1: (ag.l1 || []).map((a) => [a.area, a.state, a.taskCount, a.stateCounts, a.l1Active, (a.l1Lease || {}).node, (a.l1Lease || {}).status]),
      l0: ag.l0 && [ag.l0.state, ag.l0.runId, ag.l0.processes, ag.l0.activeOriginLock],
      fr: [...frontierAreaSet()].sort(),
      exp: [...(S.expanded || [])].sort(),
      bud: [...S.budgets].sort(),
      q: S.query, af: S.areaFilter, sf: S.statusFilter,
      // transform + selection are applied separately (never rebuild on pan/select)
      tasks: (S.snap.l2Tasks || []).map((t) => [t.id, t.state, t.area, (t.dependsOn || []).length]),
    });
  }

  // Layout geometry (left -> right): L0 column, L1 areas column, L2 tasks column.
  const GL = { PAD: 24, X0: 24, W0: 280, X1: 394, W1: 250, X2: 714, W2: 320,
    H0: 78, H1: 52, H2: 46, VGAP: 10, BANDGAP: 26 };

  // Pure deterministic layout -> {nodes, bbox, index}. Single vertical cursor packs
  // each area into a contiguous band (bandH = max(L1, budgeted L2 stack)); advancing
  // by bandH+gap is collision-free by construction. L0 is centered on the L1 column.
  // The set of areas with a ready DAG frontier node (plural). Falls back to the
  // singular next-area when the plural frontier is unavailable.
  function frontierAreaSet() {
    const o = (S.snap && S.snap.orchestration) || {};
    const list = (o.nextAreas && Array.isArray(o.nextAreas.frontier)) ? o.nextAreas.frontier : [];
    const set = new Set(list.map((f) => f && f.area).filter(Boolean));
    if (set.size === 0 && o.nextArea && o.nextArea.area) set.add(o.nextArea.area);
    return set;
  }

  function layoutGraph() {
    const ag = S.snap.agents || {};
    const frontierAreas = frontierAreaSet();
    const byArea = groupTasks();
    const areas = (ag.l1 || []).filter((a) => !S.areaFilter || a.area === S.areaFilter);
    const nodes = [];
    let y = GL.PAD, anyExpanded = false;
    for (const a of areas) {
      const laneTasks = byArea.get(a.area) || [];
      const matchOpen = !!S.query && laneTasks.some((t) =>
        [t.id, t.title, t.workerBranch].join(" ").toLowerCase().includes(S.query));
      const expanded = (S.expanded.has(a.area) || matchOpen) && laneTasks.length > 0;
      const frontier = frontierAreas.has(a.area);
      if (expanded) {
        anyExpanded = true;
        // Spatial graph shows the exceptions: all non-terminal tasks, plus however
        // many integrated the operator has revealed via "load more". The integrated
        // majority stays collapsed behind a single "+N more" node (use the list view
        // to scan them all) — keeps the canvas compact and attention on what's live.
        const sorted = sortExceptionsFirst(laneTasks);
        const nonTerminal = sorted.filter((t) => t.state !== "integrated");
        const integrated = sorted.filter((t) => t.state === "integrated");
        const reveal = S.budgets.get(a.area) || 0;
        const ntShown = nonTerminal.slice(0, LANE_BUDGET);
        const shown = ntShown.concat(integrated.slice(0, reveal));
        const hidden = (nonTerminal.length - ntShown.length) + Math.max(0, integrated.length - reveal);
        const count = Math.max(1, shown.length + (hidden > 0 ? 1 : 0));
        const bandH = Math.max(GL.H1, count * GL.H2 + (count - 1) * GL.VGAP);
        nodes.push({ kind: "l1", area: a, frontier, expanded: true, x: GL.X1, y: y + (bandH - GL.H1) / 2, w: GL.W1, h: GL.H1 });
        let ty = y;
        for (const t of shown) { nodes.push({ kind: "l2", task: t, x: GL.X2, y: ty, w: GL.W2, h: GL.H2 }); ty += GL.H2 + GL.VGAP; }
        if (hidden > 0) nodes.push({ kind: "more", area: a.area, remaining: hidden, x: GL.X2, y: ty, w: GL.W2, h: GL.H2 });
        y += bandH + GL.BANDGAP;
      } else {
        nodes.push({ kind: "l1", area: a, frontier, expanded: false, empty: laneTasks.length === 0, x: GL.X1, y, w: GL.W1, h: GL.H1 });
        y += GL.H1 + GL.BANDGAP;
      }
    }
    const bandsH = Math.max(0, y - GL.BANDGAP - GL.PAD);
    const l0y = GL.PAD + Math.max(0, (bandsH - GL.H0) / 2);
    nodes.unshift({ kind: "l0", l0: ag.l0 || {}, x: GL.X0, y: l0y, w: GL.W0, h: GL.H0 });
    const W = (anyExpanded ? GL.X2 + GL.W2 : GL.X1 + GL.W1) + GL.PAD;
    const H = Math.max(y, l0y + GL.H0 + GL.PAD);
    const index = {};
    for (const n of nodes) {
      const id = n.kind === "l0" ? "L0" : n.kind === "l1" ? n.area.id : n.kind === "l2" ? n.task.id : null;
      if (id) index[id] = n;
    }
    return { nodes, bbox: { W, H }, index };
  }

  function renderGraph() {
    const root = $("view-graph");
    const { nodes, bbox, index } = layoutGraph();
    S.graphBBox = bbox; S._nodeIndex = index;
    const q = S.query;
    let nh = "";
    for (const n of nodes) {
      if (n.kind === "l0") nh += l0NodeHtml(n);
      else if (n.kind === "l1") nh += l1NodeHtml(n);
      else if (n.kind === "l2") nh += l2NodeHtml(n, q);
      else if (n.kind === "more") nh += moreNodeHtml(n);
    }
    root.innerHTML =
      `<div class="canvas" style="width:${bbox.W}px;height:${bbox.H}px">` +
      `<svg class="edge-layer" width="${bbox.W}" height="${bbox.H}" viewBox="0 0 ${bbox.W} ${bbox.H}">${renderEdges(nodes)}</svg>` +
      nh + `</div>` + canvasControlsHtml();
    if (!S._graphFitted) { S._graphFitted = true; fitGraph(); } else { applyTransform(); }
    applyMarkers();
  }

  const pos = (n) => `left:${n.x}px;top:${n.y}px;width:${n.w}px;height:${n.h}px`;

  function l0NodeHtml(n) {
    const l0 = n.l0 || {};
    return `<button class="gnode l0" style="${pos(n)}" data-id="L0" data-layer="l0" data-state="${escAttr(l0.state)}" data-tone="${toneOf(l0.state)}" data-selected="false">
      <span class="bezel" data-tone="${toneOf(l0.state)}">${icon("i-hub")}</span>
      <div style="display:flex;flex-direction:column;gap:2px;min-width:0;flex:1">
        <div class="gn-title">L0 origin ${statusChip(l0.state)}</div>
        <div class="gn-meta">${esc(shortRun(l0.runId) || "—")} · leases ${esc(l0.activeLeases != null ? l0.activeLeases : "—")}</div>
      </div></button>`;
  }

  function l1NodeHtml(n) {
    const a = n.area;
    const lease = a.l1Lease || null;
    // A live L1 planner is a durable fact (an active l1-lease) — surfaced as a
    // distinct cobalt "L1" badge, separate from the area's L2-task state tone.
    const plannerBadge = a.l1Active
      ? `<span class="l1-planner" title="L1 planner active${lease ? ": " + escAttr(lease.node) + " (" + escAttr(lease.status) + ")" : ""}">L1</span>`
      : "";
    return `<button class="gnode l1${n.frontier ? " has-frontier" : ""}${a.l1Active ? " has-l1" : ""}" style="${pos(n)}" data-id="${escAttr(a.id)}" data-area="${escAttr(a.area)}" data-layer="l1" data-state="${escAttr(a.state)}" data-tone="${toneOf(a.state)}" data-expanded="${n.expanded}" data-selected="false" aria-expanded="${n.expanded}">
      <span class="chevron">${icon("i-chev")}</span>
      ${toneDot(a.state)}
      <span class="gn-title">${esc(a.area)}</span>
      ${plannerBadge}
      ${n.frontier ? `<span class="fdiamond" title="frontier"></span>` : ""}
      ${laneCountBadge(a)}
    </button>`;
  }

  function l2NodeHtml(n, q) {
    const t = n.task;
    const dim = q && ![t.id, t.title, t.workerBranch].join(" ").toLowerCase().includes(q) ? " search-dim" : "";
    return `<button class="gnode l2${dim}" style="${pos(n)}" data-task-id="${escAttr(t.id)}" data-layer="l2" data-state="${escAttr(t.state)}" data-area="${escAttr(t.area)}" data-tone="${toneOf(t.state)}" data-selected="false" data-pinned="false">
      ${toneDot(t.state)}
      <span class="gn-id">${highlight(t.id, q)}</span>
      <span class="gn-title">${highlight(t.title || "", q)}</span>
      <span class="gn-chip">${statusChip(t.state)}</span>
      <span class="pin-glyph">${icon("i-pin")}</span>
    </button>`;
  }

  function moreNodeHtml(n) {
    return `<button class="gnode more" style="${pos(n)}" data-area="${escAttr(n.area)}" data-remaining="${n.remaining}">+ ${n.remaining} more integrated · load ${Math.min(MORE_STEP, n.remaining)}</button>`;
  }

  function canvasControlsHtml() {
    return `<div class="canvas-controls">
      <div class="cc-row">
        <button class="zoom-btn" data-zoom="out" title="Zoom out" aria-label="Zoom out">−</button>
        <button class="zoom-btn" data-zoom="in" title="Zoom in" aria-label="Zoom in">+</button>
      </div>
      <button class="zoom-btn wide" data-zoom="fit" title="Fit graph">${icon("i-expand")}fit</button>
    </div>`;
  }

  function laneCountBadge(a) {
    const sc = a.stateCounts || {};
    const integ = sc.integrated || 0;
    let mk = "";
    if (sc.awaiting) mk += ` <span class="mk awaiting">▲${sc.awaiting}</span>`;
    if (sc.blocked) mk += ` <span class="mk blocked">▢${sc.blocked}</span>`;
    if (sc.failed) mk += ` <span class="mk failed">✕${sc.failed}</span>`;
    if (sc.active) mk += ` <span class="mk active">●${sc.active}</span>`;
    if (sc.stale) mk += ` <span class="mk stale">◌${sc.stale}</span>`;
    return `<span class="count-badge"><span class="pos">${integ}</span>/${a.taskCount}${mk}</span>`;
  }

  function groupTasks() {
    const m = new Map();
    for (const t of S.snap.l2Tasks || []) {
      if (S.statusFilter && t.state !== S.statusFilter) continue;
      if (!m.has(t.area)) m.set(t.area, []);
      m.get(t.area).push(t);
    }
    return m;
  }

  // ---- edges (svg, in canvas coordinate space) ----
  function renderEdges(nodes) {
    const l0 = nodes.find((n) => n.kind === "l0");
    const l1s = nodes.filter((n) => n.kind === "l1");
    const areaL1 = {}; l1s.forEach((n) => { areaL1[n.area.area] = n; });
    let p = "";
    if (l0) for (const n of l1s) p += edgePath(l0, n, "edge", "L0", n.area.id);
    for (const n of nodes) {
      if (n.kind === "l2" || n.kind === "more") {
        const par = areaL1[n.kind === "l2" ? n.task.area : n.area];
        if (par) p += edgePath(par, n, "edge", par.area.id, n.kind === "l2" ? n.task.id : "");
      }
    }
    return p;
  }
  function edgePath(a, b, cls, from, to) {
    const px = a.x + a.w, py = a.y + a.h / 2, cx = b.x, cy = b.y + b.h / 2;
    const dx = Math.max(40, (cx - px) * 0.5);
    const d = `M ${px} ${py} C ${px + dx} ${py}, ${cx - dx} ${cy}, ${cx} ${cy}`;
    return `<path class="${cls}" data-from="${escAttr(from)}" data-to="${escAttr(to)}" d="${d}"/>`;
  }
  // dependency edge between two L2 nodes (same column) — bow out to the right
  function depEdge(a, b) {
    const ax = a.x + a.w, ay = a.y + a.h / 2, bx = b.x + b.w, by = b.y + b.h / 2;
    const off = 56 + Math.abs(by - ay) * 0.12;
    return `<path class="edge dep" d="M ${ax} ${ay} C ${ax + off} ${ay}, ${bx + off} ${by}, ${bx} ${by}"/>`;
  }

  // ---- pan / zoom (CSS transform on .canvas; never triggers a rebuild) ----
  function applyTransform() {
    const c = document.querySelector("#view-graph .canvas");
    if (c) c.style.transform = `translate(${S.transform.x}px, ${S.transform.y}px) scale(${S.transform.z})`;
  }
  function zoomAt(factor, ev) {
    const r = $("view-graph").getBoundingClientRect();
    const mx = (ev ? ev.clientX : r.left + r.width / 2) - r.left;
    const my = (ev ? ev.clientY : r.top + r.height / 2) - r.top;
    const z = clamp(S.transform.z * factor, 0.3, 2.5);
    S.transform.x = mx - (mx - S.transform.x) * (z / S.transform.z);
    S.transform.y = my - (my - S.transform.y) * (z / S.transform.z);
    S.transform.z = z;
    S._userPanned = true;
    applyTransform();
  }
  function fitGraph() {
    const bb = S.graphBBox; if (!bb) return;
    const r = $("view-graph").getBoundingClientRect();
    if (!r.width) return;
    const z = clamp(Math.min((r.width - 28) / bb.W, (r.height - 28) / bb.H), 0.3, 1.2);
    S.transform = { z, x: Math.max(14, (r.width - bb.W * z) / 2), y: Math.max(14, (r.height - bb.H * z) / 2) };
    S._userPanned = false;
    applyTransform();
  }
  function panToNode(id) {
    const n = (S._nodeIndex || {})[id]; if (!n) return;
    const r = $("view-graph").getBoundingClientRect();
    const z = S.transform.z;
    S.transform.x = r.width / 2 - (n.x + n.w / 2) * z;
    S.transform.y = r.height / 2 - (n.y + n.h / 2) * z;
    S._userPanned = true;
    applyTransform();
  }

  // (The former "agents" table view was removed — the node-edge graph is the agent
  // map: nodes carry deployed L0/L1/L2 state. The worktree-divergence note moved to
  // the L0 inspector; per-task agent detail lives in the L2 inspector "work" tab.)

  // ============================================================== LIST =======
  function listSig() {
    const rows = tasksFiltered();
    return JSON.stringify({
      v: "list", q: S.query, af: S.areaFilter, sf: S.statusFilter,
      rows: rows.map((t) => [t.id, t.state, t.updatedAt]),
    });
  }

  function renderList() {
    const root = $("view-list");
    const rows = sortExceptionsFirst(tasksFiltered());
    const now = S.snap.generatedAt;
    let body = rows.map((t) => `
      <tr data-task-id="${escAttr(t.id)}" data-layer="l2" data-selected="${S.selectedId === t.id}" data-pinned="${S.pinnedId === t.id}">
        <td>${statusChip(t.state)}</td>
        <td class="c-id">${highlight(t.id, S.query)}</td>
        <td class="c-title">${highlight(t.title || "", S.query)}</td>
        <td class="c-area">${esc(t.area)}</td>
        <td class="c-branch">${highlight(shortBranch(t.workerBranch), S.query)}</td>
        <td class="c-updated">${esc(relTime(t.updatedAt, now))}</td>
      </tr>`).join("");
    if (!rows.length) body = `<tr><td colspan="6" class="lane-empty" style="padding:16px">no tasks match the current filters</td></tr>`;
    root.innerHTML = `<table class="task-table">
      <thead><tr><th>state</th><th>id</th><th>title</th><th>area</th><th>branch</th><th>upd</th></tr></thead>
      <tbody>${body}</tbody></table>`;
  }

  // =========================================================== RENDER ALL ====
  function renderAll() {
    if (!S.snap) return;
    renderTop();
    populateAreaFilter();
    renderShowing();
    renderCurrentView();
    refreshInspectorHeaderFromSnap();
    tickAge();
  }

  // The graph is always rendered; the task list is rendered only while its drawer
  // is open. Each is signature-gated so a quiet poll rebuilds neither.
  function renderCurrentView(force) {
    if (!S.snap) return;
    const gsig = graphSig();
    if (force || S.lastSig.graph !== gsig) {
      const scroll = $("view-scroll");
      const prevTop = scroll.scrollTop;
      renderGraph();
      S.lastSig.graph = gsig;
      scroll.scrollTop = prevTop;
    }
    if (S.listOpen) {
      const lsig = listSig();
      if (force || S.lastSig.list !== lsig) {
        const lb = $("list-body");
        const prevTop = lb ? lb.scrollTop : 0;
        renderList();
        S.lastSig.list = lsig;
        if (lb) lb.scrollTop = prevTop;
      }
    }
    applyMarkers(); // keep selection/pin markers fresh on graph + list rows
  }

  function applyMarkers() {
    document.querySelectorAll("[data-selected]").forEach((el) => {
      const id = el.dataset.taskId || el.dataset.id;
      el.dataset.selected = String(id === S.selectedId);
    });
    document.querySelectorAll("[data-task-id][data-pinned]").forEach((el) => {
      el.dataset.pinned = String(el.dataset.taskId === S.pinnedId);
    });
    applyEdgeHighlight();
  }

  // Recolor structural edges to the selected node + inject dependency edges for the
  // selected/pinned task. No relayout — runs on every quiet poll via applyMarkers.
  function applyEdgeHighlight() {
    const svg = document.querySelector("#view-graph .edge-layer");
    if (!svg) return;
    svg.querySelectorAll(".edge.sel").forEach((p) => p.classList.remove("sel"));
    svg.querySelectorAll(".edge.dep").forEach((p) => p.remove());
    const sel = S.selectedId;
    if (sel) svg.querySelectorAll(`.edge[data-to="${cssEsc(sel)}"]`).forEach((p) => p.classList.add("sel"));
    const focus = S.selectedKind === "l2" ? S.selectedId : null;
    if (!focus) return;
    const idx = S._nodeIndex || {};
    const self = idx[focus];
    const t = (S.snap.l2Tasks || []).find((x) => x.id === focus);
    if (!self || !t) return;
    let add = "";
    for (const dep of t.dependsOn || []) { const dn = idx[dep]; if (dn) add += depEdge(dn, self); }
    for (const inc of S.snap.l2Tasks || []) {
      if ((inc.dependsOn || []).includes(focus)) { const dn = idx[inc.id]; if (dn) add += depEdge(self, dn); }
    }
    if (add) svg.insertAdjacentHTML("beforeend", add);
  }

  function populateAreaFilter() {
    const sel = $("filter-area");
    const areas = (S.snap.agents && S.snap.agents.l1) || [];
    const want = ["", ...areas.map((a) => a.area)].join("|");
    if (sel._want === want) { sel.value = S.areaFilter; return; }
    sel._want = want;
    sel.innerHTML = `<option value="">all areas</option>` +
      areas.map((a) => `<option value="${escAttr(a.area)}">${esc(a.area)} · ${a.taskCount}</option>`).join("");
    sel.value = S.areaFilter;
  }

  function renderShowing() {
    const total = (S.snap.l2Tasks || []).length;
    const shown = tasksFiltered().length;
    const filtered = S.query || S.areaFilter || S.statusFilter;
    $("showing-count").innerHTML = filtered
      ? `showing <b>${shown}</b> of <b>${total}</b>`
      : `<b>${total}</b> tasks · <b>${(S.snap.summary && S.snap.summary.activeAgents) || 0}</b> non-terminal`;
    const lc = $("list-count");
    if (lc) lc.textContent = filtered ? `${shown} / ${total}` : `${total}`;
  }

  function tickAge() {
    if (!S.lastOkAt) { $("refresh-age").textContent = "—"; return; }
    const s = Math.round((Date.now() - S.lastOkAt) / 1000);
    $("refresh-age").textContent = s < 1 ? "now" : s + "s ago";
    if (s > POLL_MS / 1000 + 8 && S.connState === "connected") setConn("stale");
  }

  // ========================================================= INSPECTOR ======
  function select(kind, id) {
    S.selectedKind = kind; S.selectedId = id;
    // Open/close the inspector bottom-sheet modal (scrim + slide-up sheet).
    const insp = $("inspector");
    const open = kind !== "none";
    insp.dataset.subjectKind = kind;
    insp.dataset.taskId = kind === "l2" ? id : "";
    insp.setAttribute("aria-hidden", String(!open));
    insp.style.transform = ""; // clear any drag offset so CSS open/close takes over
    $("inspector-scrim").dataset.open = String(open);
    if (kind === "l2") { try { history.replaceState(null, "", "#" + id); } catch (e) {} }
    else if (kind === "node") { try { history.replaceState(null, "", "#NODE:" + id); } catch (e) {} }
    else if (kind === "overview") { try { history.replaceState(null, "", "#PLAN"); } catch (e) {} }
    applyMarkers();
    renderInspector();
  }

  // Bottom dock (terminal) height presets — the resize handle drives this.
  function setDockSize(size) {
    const dock = $("dock");
    dock.style.height = ""; // clear any drag override
    dock.dataset.size = size;
  }

  // If an L2 inspector is open, drop its cached detail and refetch when the live
  // snapshot shows the task changed — so the body never silently goes stale.
  function maybeRefreshOpenTask() {
    if (S.selectedKind !== "l2" || !S.selectedId) return;
    const t = (S.snap.l2Tasks || []).find((x) => x.id === S.selectedId);
    const cached = S.taskCache.get(S.selectedId);
    if (!t || !cached) return;
    const cachedUpd = (cached.lease && cached.lease.updatedAt) || null;
    if (cached.state !== t.state || cachedUpd !== (t.updatedAt || null)) {
      S.taskCache.delete(S.selectedId);
      renderInspectorL2();
    }
  }

  function refreshInspectorHeaderFromSnap() {
    if (S.selectedKind === "none") return;
    // keep header live (state may change under us) without clobbering the body
    if (S.selectedKind === "l2") {
      const t = (S.snap.l2Tasks || []).find((x) => x.id === S.selectedId);
      if (t) setInspHeader(t.id, t.title, `${t.area} · ${labelOf(t.state)}`, t.state, shortBranch(t.workerBranch));
    }
  }

  function setInspHeader(id, title, sub, state, mono) {
    $("insp-id").textContent = id || "";
    $("insp-title").textContent = title || "";
    $("insp-bezel").dataset.tone = toneOf(state);
    const chip = $("insp-chip");
    if (state) {
      chip.hidden = false; chip.dataset.tone = toneOf(state);
      chip.querySelector("span:last-child").textContent = labelOf(state);
    } else chip.hidden = true;
    $("insp-sub").innerHTML = sub
      ? `<span>${esc(sub)}</span>${mono ? `<span class="mono">${esc(mono)}</span>` : ""}`
      : "";
    $("insp-pin").setAttribute("aria-pressed", String(S.pinnedId && S.pinnedId === id));
  }

  function renderInspector() {
    const kind = S.selectedKind;
    // When nothing is selected the inspector slides out (CSS, data-subject-kind=none);
    // no empty-state element to toggle.
    if (kind === "none") { $("inspector-tabs").innerHTML = ""; return; }
    if (kind === "l0") return renderInspectorL0();
    if (kind === "l1") return renderInspectorL1();
    if (kind === "l2") return renderInspectorL2();
    if (kind === "node") return renderInspectorNode();
    if (kind === "overview") return renderInspectorOverview();
  }

  function showInspState(which) {
    ["empty", "skeleton", "error"].forEach((s) => {
      const el = $("inspector-" + s);
      if (el) el.dataset.active = String(s === which);
    });
    $("inspector-panels").style.display = which ? "none" : "";
  }

  function tabStrip(tabs, active) {
    return tabs.map((t) =>
      `<button class="tab" role="tab" data-tab="${t}" aria-selected="${t === active}">${t}</button>`).join("");
  }

  function setTabs(tabs) {
    if (!tabs.includes(S.inspTab)) S.inspTab = tabs[0];
    $("inspector-tabs").innerHTML = tabStrip(tabs, S.inspTab);
  }

  function showPanels(html) {
    showInspState(null);
    $("inspector-panels").innerHTML = html;
    activatePanel();
  }
  function activatePanel() {
    document.querySelectorAll("#inspector-panels .tab-panel").forEach((p) => {
      p.dataset.active = String(p.dataset.tab === S.inspTab);
    });
    document.querySelectorAll("#inspector-tabs .tab").forEach((t) => {
      t.setAttribute("aria-selected", String(t.dataset.tab === S.inspTab));
    });
  }

  // ---- L0 inspector ----
  function renderInspectorL0() {
    const l0 = (S.snap.agents && S.snap.agents.l0) || {};
    const rt = S.snap.runtime || {};
    const os = (S.snap.orchestration && S.snap.orchestration.originState) || {};
    setInspHeader("L0", "origin orchestrator", labelOf(l0.state), l0.state, "");
    setTabs(["overview", "roles"]);
    const kv = [
      ["state", labelOf(l0.state)],
      ["stop sentinel", l0.stop ? "present" : "clear"],
      ["active origin lock", l0.activeOriginLock ? "yes" : "no"],
      ["stale locks", (l0.staleLocks || []).length],
      ["live processes", l0.processes],
      ["run id", l0.runId, true],
      ["head sha", l0.headSha ? String(l0.headSha).slice(0, 12) : "—", true],
      ["packets inbox/imported", l0.packets ? `${l0.packets.inbox || 0} / ${l0.packets.imported || 0}` : "—"],
      ["active leases", l0.activeLeases],
    ];
    let ov = `<div class="tab-panel" data-tab="overview">`;
    if (l0.staleLocks && l0.staleLocks.length) {
      ov += `<div class="note warn">${icon("i-alert")} stale origin lock present — orchestrator is not active; this is leftover bookkeeping, not a running agent.</div>`;
    }
    const diskWt = (rt.worktrees || []).length;
    if ((os.extraWorktrees || 0) !== diskWt) {
      ov += `<div class="note warn">${icon("i-alert")} worktree divergence — origin-state reports ${esc(os.extraWorktrees)} · ${diskWt} present on disk — treating disk as truth; not rendered as agents.</div>`;
    }
    ov += kvGrid(kv) + `</div>`;
    const roles = `<div class="tab-panel" data-tab="roles">${renderRolesPanel()}</div>`;
    showPanels(ov + roles);
  }

  // declared role/skill catalog — lazily fetched once from /api/roles
  function renderRolesPanel() {
    const rc = S.roleCatalog;
    if (!rc) { fetchRoles(); return `<div class="section-empty">loading role catalog…</div>`; }
    const item = (r, iconId) => `<div class="role-item">
      <span class="bezel" data-tone="idle">${icon(iconId)}</span>
      <div class="role-main">
        <div class="role-name">${esc(r.label)}${r.recordedAs ? ` <span class="role-rec">${esc(r.recordedAs)}</span>` : ""}</div>
        <div class="role-disc">${esc((r.disciplines || []).join(" · "))}</div>
        ${(r.typicalTools && r.typicalTools.length) ? `<div class="role-tools">${r.typicalTools.map((t) => `<span class="tool-chip">${esc(t)}</span>`).join("")}</div>` : ""}
      </div>
      <span class="role-tag">${r.writes ? "writes" : "read-only"}</span>
    </div>`;
    return `<div class="note">${esc(rc.note || "")}</div>
      <div class="field-block"><span class="meta-label">layers · declared</span>${(rc.layers || []).map((r) => item(r, r.id === "L0" ? "i-hub" : "i-layers")).join("")}</div>
      <div class="field-block"><span class="meta-label">worker roles · declared §4.3</span>${(rc.workers || []).map((r) => item(r, "i-cpu")).join("")}</div>
      <div class="field-block"><span class="meta-label">disciplines · §9</span><div class="chips-row">${(rc.disciplines || []).map((t) => `<span class="tool-chip">${esc(t)}</span>`).join("")}</div></div>`;
  }

  async function fetchRoles() {
    if (S.roleCatalog || S.roleInflight) return;
    S.roleInflight = true;
    try {
      const r = await fetch("/api/roles");
      if (r.ok) {
        S.roleCatalog = await r.json();
        if (S.selectedKind === "l0" && S.inspTab === "roles") renderInspectorL0();
      }
    } catch (e) { /* declared catalog is optional; inspector still works without it */ }
    finally { S.roleInflight = false; }
  }

  // ---- L1 inspector ----
  function renderInspectorL1() {
    const area = S.selectedId.replace(/^L1:/, "");
    const a = ((S.snap.agents && S.snap.agents.l1) || []).find((x) => x.area === area) || { area, stateCounts: {}, taskCount: 0, state: "idle" };
    // All L1 node leases touching this area (active + history); active one first.
    const leases = (S.snap.l1Leases || []).filter((l) => l.area === area);
    const activeLease = a.l1Lease || leases.find((l) => l.active) || null;
    const hasLease = leases.length > 0;
    setInspHeader("L1 · " + area, area + " area", labelOf(a.state), a.state, "");
    setTabs(hasLease ? ["overview", "nodes", "lease", "tasks"] : ["overview", "nodes", "tasks"]);
    const sc = a.stateCounts || {};
    const kv = [["area", area], ["liveness", labelOf(a.state)],
      ["L1 planner", a.l1Active ? (activeLease ? activeLease.node + " · " + activeLease.status : "active") : "none"],
      ["tasks", a.taskCount]];
    Object.keys(STATE_ORDER).sort((x, y) => STATE_ORDER[x] - STATE_ORDER[y]).forEach((st) => {
      if (sc[st]) kv.push([st, sc[st]]);
    });
    const tasks = sortExceptionsFirst((S.snap.l2Tasks || []).filter((t) => t.area === area));
    const taskRows = tasks.slice(0, 200).map((t) =>
      `<button class="dep-chip" data-task-id="${escAttr(t.id)}" data-nav="1">${toneDot(t.state)}<span class="dep-chip-id">${esc(t.id)}</span></button>`).join("");
    let leasePanel = "";
    if (hasLease) {
      const leaseRow = (l) =>
        `<div class="cmd-row"><span class="tone-dot" data-tone="${l.active ? "active" : l1LeaseTone(l.status)}"></span>` +
        `<span class="cmd-text">${esc(l.node)}</span><span class="cmd-sub">${esc(l.status)}${l.runId ? " · " + esc(shortRun(l.runId) || l.runId) : ""}</span></div>`;
      const activeKv = activeLease ? kvGrid([
        ["node", activeLease.node],
        ["status", activeLease.status],
        ["run id", shortRun(activeLease.runId) || activeLease.runId || "—"],
        ["base sha", (activeLease.baseSha || "").slice(0, 12) || "—"],
        ["started", activeLease.startedAt || "—"],
        ["updated", activeLease.updatedAt || "—"],
        ["write scopes", (activeLease.allowedWriteScopes || []).join(", ") || "—"],
      ]) : "";
      leasePanel =
        `<div class="tab-panel" data-tab="lease">` +
        (activeLease
          ? `<div class="field-block"><span class="meta-label">active L1 planner</span>${activeKv}</div>`
          : `<div class="note">no live L1 planner in this area right now</div>`) +
        `<div class="field-block"><span class="meta-label">l1 leases (${leases.length})</span>${leases.map(leaseRow).join("")}</div>` +
        `<div class="note">An L1 lease reserves a DAG node for parallel planning. It never means complete — gate-result.v0 is the only completion authority.</div>` +
        `</div>`;
    }
    showPanels(
      `<div class="tab-panel" data-tab="overview"><div class="field-block">${kvGrid(kv)}</div></div>` +
      renderAreaNodesPanel(area) +
      leasePanel +
      `<div class="tab-panel" data-tab="tasks"><div class="field-block"><span class="meta-label">tasks (${tasks.length})</span><div class="chips-row">${taskRows || '<span class="section-empty">none</span>'}</div></div></div>`
    );
  }

  // Area "nodes" tab — the DAG nodes in this area with gate status + frontier.
  // Fetched on demand (one /api/area/<area>/nodes call) when the tab is shown.
  function renderAreaNodesPanel(area) {
    const data = S.areaNodesCache.get(area);
    if (!data) {
      if (S.inspTab === "nodes") fetchAreaNodes(area);
      return `<div class="tab-panel" data-tab="nodes"><div class="section-empty">loading nodes…</div></div>`;
    }
    const rows = (data.nodes || []).map((n) => {
      const gtone = gateTone(n.gateStatus);
      const tc = n.taskCounts || {};
      const frontier = n.frontier ? `<span class="frontier-marker" title="frontier node">frontier</span>` : "";
      return `<button class="node-row" data-node-id="${escAttr(n.nodeId)}" data-nav-node="1">
        <span class="nr-id">${esc(n.nodeId)}</span>
        <span class="nr-side">
          <span class="status-chip" data-tone="${gtone}"><span class="tone-dot" data-tone="${gtone}"></span><span>${esc(n.gateStatus)}</span></span>
          ${frontier}
        </span>
        <span class="nr-meta">${esc(n.stage || "")}${n.layer ? " · " + esc(n.layer) : ""} · ${esc(n.predicate || "—")} · tasks ${tc.integrated || 0}/${tc.total || 0}</span>
      </button>`;
    }).join("");
    return `<div class="tab-panel" data-tab="nodes"><div class="field-block">
      <span class="meta-label">dag nodes · ${(data.nodes || []).length}</span>
      <div class="node-list">${rows || '<span class="section-empty">no nodes in this area</span>'}</div></div></div>`;
  }

  // ---- L2 inspector (fetch /api/task, degrade gracefully) ----
  function renderInspectorL2() {
    const id = S.selectedId;
    setTabs(["overview", "origin", "gate", "scope", "acceptance", "evidence", "runtime", "work", "timeline"]);
    const cached = S.taskCache.get(id);
    if (cached) { renderTaskDetail(cached); return; }
    // header already set from snapshot; show skeleton for body while fetching
    showInspState("skeleton");
    fetchTask(id);
  }

  async function fetchTask(id) {
    if (S.taskInflight.has(id)) return;
    S.taskInflight.add(id);
    try {
      const res = await fetch("/api/task/" + encodeURIComponent(id), { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      const detail = await res.json();
      S.taskCache.set(id, detail);
      if (S.selectedId === id) renderTaskDetail(detail);
    } catch (err) {
      if (S.selectedId === id) {
        $("inspector-error-text").textContent = "could not load " + id + " · click to retry";
        showInspState("error");
        $("inspector-error").onclick = () => { S.taskInflight.delete(id); renderInspectorL2(); };
      }
    } finally {
      S.taskInflight.delete(id);
    }
  }

  async function fetchNode(id) {
    if (S.nodeInflight.has(id)) return;
    S.nodeInflight.add(id);
    try {
      const res = await fetch("/api/node/" + encodeURIComponent(id), { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      const detail = await res.json();
      S.nodeCache.set(id, detail);
      if (S.selectedKind === "node" && S.selectedId === id) renderNodeDetail(detail);
    } catch (err) {
      if (S.selectedKind === "node" && S.selectedId === id) {
        $("inspector-error-text").textContent = "could not load node " + id + " · click to retry";
        showInspState("error");
        $("inspector-error").onclick = () => { S.nodeInflight.delete(id); renderInspectorNode(); };
      }
    } finally {
      S.nodeInflight.delete(id);
    }
  }

  async function fetchAreaNodes(area) {
    if (S.areaNodesCache.has(area) || S.areaNodesInflight.has(area)) return;
    S.areaNodesInflight.add(area);
    try {
      const res = await fetch("/api/area/" + encodeURIComponent(area) + "/nodes", { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      S.areaNodesCache.set(area, await res.json());
      if (S.selectedKind === "l1" && S.selectedId.replace(/^L1:/, "") === area) renderInspectorL1();
    } catch (e) {
      /* leave the loading placeholder; reopening the tab retries */
    } finally {
      S.areaNodesInflight.delete(area);
    }
  }

  async function fetchOverview() {
    if (S.overviewInflight) return;
    S.overviewInflight = true;
    try {
      const res = await fetch("/api/overview", { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      S.overview = await res.json();
      renderPlanPill();
      if (S.selectedKind === "overview") renderInspectorOverview();
    } catch (e) {
      /* pill keeps its last value; overview is optional chrome */
    } finally {
      S.overviewInflight = false;
    }
  }

  function renderPlanPill() {
    const o = S.overview;
    const pct = o && o.progress ? o.progress.pct : null;
    $("plan-pct").textContent = pct == null ? "—" : pct + "%";
    $("plan-fill").style.width = (pct || 0) + "%";
  }

  function renderTaskDetail(d) {
    setInspHeader(d.id, d.title, `${d.area} · ${labelOf(d.state)}`, d.state, shortBranch(d.workerBranch));

    // overview
    const deps = (d.dependsOn || []).map((dep) => {
      const t = (S.snap.l2Tasks || []).find((x) => x.id === dep);
      const st = t ? t.state : "idle";
      const done = st === "integrated" ? `<span class="check">${icon("i-check")}</span>` : "";
      return `<button class="dep-chip" data-task-id="${escAttr(dep)}" data-nav="1">${toneDot(st)}<span class="dep-chip-id">${esc(dep)}</span>${done}</button>`;
    }).join("");
    const overview = `<div class="tab-panel" data-tab="overview">
      ${whyLine(provenanceOf(d).whyTaskExists)}
      <div class="field-block"><span class="meta-label">objective</span><div class="objective-text">${esc(d.objective || "—")}</div></div>
      <div class="field-block"><span class="meta-label">depends on</span><div class="chips-row">${deps || '<span class="section-empty">no dependencies</span>'}</div></div>
      ${kvGrid([["area", d.area], ["status", labelOf(d.state)], ["test policy", d.testPolicy || "—"], ["dispatch", d.dispatchMode || "—"], ["gate command", d.gateCommand || "—", true]])}
    </div>`;

    // scope
    const owned = (d.ownedFiles || []).map((f) => fileItem(f, "owned")).join("");
    const forb = (d.forbiddenFiles || []).map((f) => fileItem(f, "forbidden")).join("");
    let scopeNote = "";
    const ls = d.lease && d.lease.fileScope;
    if (ls && d.ownedFiles && d.ownedFiles.length) {
      const leaseSet = String(ls).split(/\s+/).filter(Boolean).sort().join("|");
      const ownSet = d.ownedFiles.slice().sort().join("|");
      if (leaseSet !== ownSet) scopeNote = `<div class="note warn">${icon("i-alert")} lease file scope differs from task owned files</div>`;
    }
    const scope = `<div class="tab-panel" data-tab="scope">
      ${scopeNote}
      <div class="field-block"><span class="meta-label">owned files · ${(d.ownedFiles || []).length}</span><div class="file-list">${owned || '<span class="section-empty">none</span>'}</div></div>
      <div class="field-block"><span class="meta-label">forbidden files · ${(d.forbiddenFiles || []).length}</span><div class="file-list">${forb || '<span class="section-empty">none</span>'}</div></div>
    </div>`;

    // acceptance — neutral until a gate/evidence proves it (never auto-checked)
    const proven = d.gates && d.gates.some((g) => g.status === "passed");
    const accRows = (d.acceptanceCriteria || []).map((c) => `
      <div class="check-item${proven ? " done" : ""}"><span class="check-box">${proven ? icon("i-check") : ""}</span><span>${esc(c)}</span></div>`).join("");
    const acceptance = `<div class="tab-panel" data-tab="acceptance">
      <div class="field-block"><span class="meta-label">acceptance criteria · ${(d.acceptanceCriteria || []).length}${proven ? " · gate passed" : ""}</span>
        <div class="checklist">${accRows || '<span class="section-empty">none listed</span>'}</div></div>
    </div>`;

    // evidence — required evidence matched against packet/audit presence
    const packet = (d.packets || [])[0];
    const evItems = (d.requiredEvidence || []).map((e) => {
      const present = packet && (packet.evidence || []).length > 0;
      return `<div class="evidence-item${present ? " present" : ""}">${toneDot(present ? "integrated" : "idle")}<span>${esc(e)}</span><span class="ev-state">${present ? "present" : "expected"}</span></div>`;
    }).join("");
    let evExtra = "";
    if (packet) {
      const tests = (packet.tests || []).map((t) => `${esc(t.phase || t.name)}: ${esc(t.status)}`).join(" · ");
      evExtra = `<div class="field-block"><span class="meta-label">packet ${esc(packet.status || "")}${packet.superseded ? " · superseded" : ""}</span>
        ${kvGrid([["packet id", packet.packetId, true], ["head sha", packet.headSha ? String(packet.headSha).slice(0, 12) : "—", true], ["next action", packet.nextAction || "—"]])}
        ${tests ? `<div class="kv-value" style="margin-top:6px">${esc(tests)}</div>` : ""}</div>`;
    }
    let auditExtra = "";
    if (d.integrateRuns && d.integrateRuns.length) {
      const ir = d.integrateRuns[0];
      const gc = ir.gateCheck || {};
      const exTone = gc.exitCode === 0 ? "integrated" : (gc.exitCode == null ? "idle" : "blocked");
      const exChip = `<span class="gate-tag" data-tone="${toneOf(exTone)}">${toneDot(exTone)}<span class="lbl">exit ${gc.exitCode != null ? gc.exitCode : "—"}</span></span>`;
      auditExtra = `<div class="field-block"><span class="meta-label">integration audit</span>
        <div class="chips-row" style="margin-bottom:6px">${exChip}</div>
        ${kvGrid([["gate", gc.cmd || "—"], ["log", ir.logRef || "—", true]])}</div>`;
    }
    // Gate references + command evidence now live in the dedicated "gate" tab
    // (renderGatePanel); the evidence tab keeps required-evidence + packet + audit.
    const evidence = `<div class="tab-panel" data-tab="evidence">
      <div class="field-block"><span class="meta-label">required evidence · ${(d.requiredEvidence || []).length}</span>${evItems || '<span class="section-empty">none</span>'}</div>
      ${evExtra}${auditExtra}
    </div>`;

    // runtime — trust-critical lease + worktree facts
    const lease = d.lease || {};
    const wt = d.worktree || {};
    const retryStr = (lease.retryCount != null) ? `${lease.retryCount} / ${lease.maxRetries != null ? lease.maxRetries : "—"}` : "—";
    let rtNote = "";
    if (!wt.exists && wt.path) rtNote = `<div class="note warn">${icon("i-alert")} worktree path recorded but not present on disk</div>`;
    if (d.state === "blocked") rtNote += `<div class="note error">${icon("i-alert")} retries exhausted — needs operator intervention</div>`;
    const runtime = `<div class="tab-panel" data-tab="runtime">
      ${rtNote}
      ${kvGrid([
        ["lease status", lease.status ? labelOf(stateFromLease(lease.status)) + " (" + lease.status + ")" : "—"],
        ["owner", lease.owner || "—"],
        ["run id", d.runId || "—", true],
        ["retry", retryStr],
        ["worktree", wt.path || "—", true],
        ["worktree exists", wt.exists ? "yes · on disk" : "no"],
        ["base sha", lease.baseSha ? String(lease.baseSha).slice(0, 12) : "—", true],
        ["batch", lease.batchId || "—", true],
        ["created", lease.createdAt || "—", true],
        ["updated", lease.updatedAt || "—", true],
      ])}
    </div>`;

    showPanels(overview + renderOriginPanel(d) + renderGatePanel(d) + scope + acceptance +
      evidence + runtime + renderWorkPanel(d) + renderTimelinePanel(d));
  }

  // -------------------------------------------------- provenance builders ---
  const provenanceOf = (d) => (d && d.provenance) || {};

  // The prominent "why this exists" line, shared by task + node inspectors.
  function whyLine(text) {
    if (!text) return "";
    return `<div class="why-line"><span class="bezel" data-tone="idle">${icon("i-hub")}</span><p>${esc(text)}</p></div>`;
  }

  // Stage-level source-document references (content-hashed). Shared task + node.
  function sourceRefsBlock(refs) {
    if (!refs || !refs.length) return "";
    const cards = refs.map((r) => `<div class="source-ref">
      <div class="sr-head"><span>${esc(r.section || "section")}</span>
        <span class="gate-tag hash-badge" title="${escAttr(r.contentHash || "")}">${esc((r.contentHash || "").slice(7, 17))}</span></div>
      <div class="sr-doc mono">${esc(r.document || "")}${r.lineStart ? ` · L${r.lineStart}–${r.lineEnd}` : ""}</div>
      ${r.excerpt ? `<div class="sr-excerpt">${esc(r.excerpt)}</div>` : ""}
      ${r.reason ? `<div class="note">${esc(r.reason)}</div>` : ""}
    </div>`).join("");
    return `<div class="field-block"><span class="meta-label">source references · stage-level</span>${cards}</div>`;
  }

  // The vertical lifecycle trace (generated → … → integrated), reusing .event-feed.
  function renderOriginChain(chain) {
    if (!chain || !chain.length) return '<span class="section-empty">no lifecycle events in window</span>';
    return `<div class="event-feed">` + chain.map((s) => {
      const extra = s.extra || {};
      const commit = extra.mergeCommit || extra.headSha;
      const tail = commit
        ? `<button class="copy-btn ev-commit" data-copy="${escAttr(commit)}">${esc(String(commit).slice(0, 7))}${icon("i-copy")}</button>`
        : (extra.verdict ? `<span class="ev-commit">${esc(extra.verdict)}</span>` : "");
      return `<div class="event-line"><span class="event-ts">${esc(relTime(s.ts, S.snap.generatedAt))}</span>
        <span class="event-type" data-tone="${esc(s.tone || "idle")}">${esc(s.type)}</span>
        <span class="event-msg">${esc(s.label || "")}</span>${tail}</div>`;
    }).join("") + `</div>`;
  }

  // L2 "origin" tab — why the task exists + its full upstream provenance chain.
  function renderOriginPanel(d) {
    const p = provenanceOf(d);
    const nodeChip = p.parentNode
      ? `<button class="dep-chip" data-node-id="${escAttr(p.parentNode)}" data-nav-node="1"><span class="dep-chip-id">${esc(p.parentNode)}</span></button>`
      : '<span class="section-empty">unresolved</span>';
    const staged = p.stagedCandidate;
    const linkNote = p.linkConfidence && p.linkConfidence !== "events"
      ? `<div class="note">link confidence: ${esc(p.linkConfidence)} — derived without a full event chain</div>` : "";
    let dupNote = "";
    if (p.duplicateOf || p.supersededBy) {
      const other = p.supersededBy || p.duplicateOf;
      dupNote = `<div class="note warn">${icon("i-alert")} advisory: looks ${p.supersededBy ? "superseded by" : "duplicate of"}
        <button class="dep-chip" data-task-id="${escAttr(other)}" data-nav="1"><span class="dep-chip-id">${esc(other)}</span></button>
        — identical owned files in the same area; not authoritative.</div>`;
    }
    return `<div class="tab-panel" data-tab="origin">
      ${whyLine(p.whyTaskExists)}
      ${dupNote}
      ${sourceRefsBlock(p.sourceRefs)}
      <div class="field-block"><span class="meta-label">serving dag node</span><div class="chips-row">${nodeChip}</div></div>
      <div class="field-block"><span class="meta-label">planner origin</span>${kvGrid([
        ["stage", p.stage || "—"],
        ["planner run", p.plannerRunId || "—", true],
        ["worker run", p.workerRunId || "—", true],
        ["batch", p.batchId || "—", true],
        ["planner prompt", p.plannerPromptRef ? shortRun(p.plannerPromptRef.split("/").slice(-2, -1)[0]) || "present" : "—"],
        ["staged candidate", staged ? (staged.localId ? staged.localId + " · " + (staged.title || "") : staged.candidateCount + " candidates") : "—"],
      ])}${linkNote}</div>
      <div class="field-block"><span class="meta-label">origin chain</span>${renderOriginChain(p.originChain)}</div>
      ${p.integrationCommit ? `<div class="field-block"><span class="meta-label">integration commit</span>${kvGrid([["merge commit", p.integrationCommit, true]])}</div>` : ""}
    </div>`;
  }

  // L2 "gate" tab — the gates this task contributes evidence to (promoted out of
  // the evidence tab). Each gate node chip opens the full node gate inspector.
  function renderGatePanel(d) {
    const gates = d.gates || [];
    const refs = gates.map((g) => {
      const passed = g.status === "passed";
      return `<button class="gate-tag gate-link" data-node-id="${escAttr(g.node)}" data-nav-node="1" data-tone="${toneOf(passed ? "integrated" : "blocked")}">${toneDot(passed ? "integrated" : "blocked")}<span class="lbl">${esc(g.node)} · ${esc(g.status)}</span></button>`;
    }).join(" ");
    const cmdRows = gates.flatMap((g) =>
      (g.commandLogs || []).map((log) => {
        const exit = log.exitCode;
        const tone = exit === 0 ? "integrated" : (log.skipGuardRed ? "blocked" : "failed");
        const marker = log.skipGuardRed ? " · skip-guard-red" : "";
        return `<div class="cmd-row"><span class="cmd-text">${esc(g.node)} · ${esc(log.ref || "command-log")}${marker}</span>${
          exit != null ? `<span class="gate-tag" data-tone="${toneOf(tone)}">${toneDot(tone)}<span class="lbl">exit ${exit}</span></span>` : ""
        }</div>`;
      })
    ).join("");
    return `<div class="tab-panel" data-tab="gate">
      <div class="note">Gates are the only completion authority. This task contributes evidence to the gates below; open a gate node to see its predicate and pass/block reason.</div>
      <div class="field-block"><span class="meta-label">contributes to gates · ${gates.length}</span><div class="chips-row">${refs || '<span class="section-empty">none</span>'}</div></div>
      ${cmdRows ? `<div class="field-block"><span class="meta-label">gate command evidence</span>${cmdRows}</div>` : ""}
    </div>`;
  }

  // L2 "timeline" tab — replaces the old events tab; merges the typed origin chain
  // with task-scoped events.ndjson rows, reverse-chronological.
  function renderTimelinePanel(d) {
    const p = provenanceOf(d);
    const seen = new Set();
    const rows = [];
    for (const s of (p.originChain || [])) {
      seen.add((s.ts || "") + "|" + (s.type || ""));
      rows.push({ ts: s.ts, type: s.type, tone: s.tone, msg: s.label });
    }
    for (const e of (d.events || [])) {
      const k = (e.ts || "") + "|" + (e.type || "");
      if (seen.has(k)) continue;
      rows.push({ ts: e.ts, type: e.type || "raw", tone: eventTone(e.type), msg: e.message || (e.raw ? e.raw.slice(0, 120) : "") });
    }
    rows.sort((a, b) => String(b.ts || "").localeCompare(String(a.ts || "")));
    const html = rows.map((r) => `<div class="event-line"><span class="event-ts">${esc(relTime(r.ts, S.snap.generatedAt))}</span>
      <span class="event-type" data-tone="${esc(r.tone || "idle")}">${esc(r.type)}</span>
      <span class="event-msg">${esc(r.msg || "")}</span></div>`).join("");
    return `<div class="tab-panel" data-tab="timeline">
      <div class="event-feed">${html || '<span class="section-empty">no task-scoped events found</span>'}</div></div>`;
  }

  // ---- node inspector (first-class; reached from the area Nodes tab + task origin) ----
  function renderInspectorNode() {
    const id = S.selectedId;
    setInspHeader(id, id, "dag node", null, "");
    setTabs(["overview", "origin", "gate", "tasks"]);
    const cached = S.nodeCache.get(id);
    if (cached) { renderNodeDetail(cached); return; }
    showInspState("skeleton");
    fetchNode(id);
  }

  function renderNodeDetail(d) {
    const def = d.definition || {};
    const gate = d.gate || {};
    const fr = d.frontier || {};
    setInspHeader(d.nodeId, def.description ? truncate(def.description, 80) : d.nodeId,
      `node · ${def.stage || ""}${def.layer ? " · " + def.layer : ""}`, gateTone(gate.status), "");
    const depChips = (def.dependsOn || []).map((u) =>
      `<button class="dep-chip" data-node-id="${escAttr(u)}" data-nav-node="1"><span class="dep-chip-id">${esc(u)}</span></button>`).join("") || '<span class="section-empty">none</span>';
    const overview = `<div class="tab-panel" data-tab="overview">
      ${whyLine(fr.why)}
      ${fr.isFrontier ? `<div class="note">${icon("i-bolt")} frontier node — work here advances the build.</div>` : ""}
      <div class="field-block">${kvGrid([
        ["node", def.id], ["stage", def.stage], ["area", def.area], ["layer", def.layer],
        ["kind", def.kind], ["completion", def.requiredCompletion],
      ])}</div>
      <div class="field-block"><span class="meta-label">depends on</span><div class="chips-row">${depChips}</div></div>
    </div>`;
    const origin = `<div class="tab-panel" data-tab="origin">
      ${sourceRefsBlock(d.sourceRefs)}
      <div class="field-block"><span class="meta-label">planner runs · ${(d.plannerRuns || []).length}</span>${
        (d.plannerRuns || []).map((r) => `<div class="cmd-row"><span class="cmd-text mono">${esc(shortRun(r.runId) || r.runId || "—")}</span><span class="cmd-sub">${esc(r.status || (r.batchRef ? "planner batch" : "prompt"))}${r.active ? " · active" : ""}</span></div>`).join("") || '<span class="section-empty">none</span>'
      }</div>
    </div>`;
    const tasks = `<div class="tab-panel" data-tab="tasks">
      <div class="field-block"><span class="meta-label">tasks generated · ${(d.tasksGenerated || []).length}</span><div class="chips-row">${
        (d.tasksGenerated || []).map((t) => `<button class="dep-chip" data-task-id="${escAttr(t.taskId)}" data-nav="1">${toneDot(stateFromLease(t.status))}<span class="dep-chip-id">${esc(t.taskId)}</span></button>`).join("") || '<span class="section-empty">none</span>'
      }</div></div>
    </div>`;
    showPanels(overview + origin + gateBlock(gate, def) + tasks);
  }

  // Rich single-gate block (node inspector "gate" tab): predicate, plain-language
  // pass/block reason, accepted vs missing evidence tasks, upstream, command logs.
  function gateBlock(gate, def) {
    const b = gate.blocking || {};
    const passed = gate.status === "passed";
    const reasonNote = b.reason
      ? `<div class="note${passed ? "" : " warn"}">${passed ? "" : icon("i-alert")}${esc(b.reason)}</div>`
      : (passed ? `<div class="note">Gate passed — completion authority satisfied.</div>` : "");
    const taskChips = (ids, tone) => (ids || []).map((t) =>
      `<button class="dep-chip" data-task-id="${escAttr(t)}" data-nav="1">${toneDot(tone)}<span class="dep-chip-id">${esc(t)}</span></button>`).join("") || '<span class="section-empty">none</span>';
    const upstream = (gate.upstreamGates || []).map((u) => {
      const st = (gate.upstreamStatus || {})[u] || "absent";
      return `<button class="gate-tag gate-link" data-node-id="${escAttr(u)}" data-nav-node="1" data-tone="${gateTone(st)}">${toneDot(gateTone(st) === "integrated" ? "integrated" : "blocked")}<span class="lbl">${esc(u)} · ${esc(st)}</span></button>`;
    }).join(" ");
    const cmdRows = (gate.commandLogs || []).map((log) => {
      const exit = log.exitCode;
      const tone = exit === 0 ? "integrated" : "failed";
      return `<div class="cmd-row"><span class="cmd-text">${esc(log.command || log.ref || "command-log")}</span>${
        exit != null ? `<span class="gate-tag" data-tone="${toneOf(tone)}">${toneDot(tone)}<span class="lbl">exit ${exit}</span></span>` : ""
      }</div>`;
    }).join("");
    return `<div class="tab-panel" data-tab="gate">
      ${reasonNote}
      <div class="field-block">${kvGrid([
        ["status", gate.status || "absent"], ["predicate", gate.predicate || (def || {}).requiredCompletion || "—"],
        ["authoritative", gate.authoritative == null ? "—" : (gate.authoritative ? "yes" : "no")],
        ["evidence class", gate.evidenceClass || "—"], ["decided by", gate.decidedBy || "—"],
        ["recorded", gate.recordedAt || "—"],
      ])}</div>
      ${upstream ? `<div class="field-block"><span class="meta-label">upstream gates</span><div class="chips-row">${upstream}</div></div>` : ""}
      <div class="field-block"><span class="meta-label">accepted evidence tasks · ${(b.acceptedTaskIds || []).length}</span><div class="chips-row">${taskChips(b.acceptedTaskIds, "integrated")}</div></div>
      ${(b.missingTaskIds || []).length ? `<div class="field-block"><span class="meta-label">missing evidence tasks · ${b.missingTaskIds.length}</span><div class="chips-row">${taskChips(b.missingTaskIds, "blocked")}</div></div>` : ""}
      ${cmdRows ? `<div class="field-block"><span class="meta-label">command logs</span>${cmdRows}</div>` : ""}
    </div>`;
  }

  // ---- Plan overview ("mission control": progress · inputs · settings · status) ----
  function renderInspectorOverview() {
    setInspHeader("PLAN", "plan overview", "orchestration mission control", null, "");
    setTabs(["progress", "inputs", "settings", "status"]);
    const o = S.overview;
    if (!o) { showInspState("skeleton"); fetchOverview(); return; }
    showPanels(ovProgressPanel(o) + ovInputsPanel(o) + ovSettingsPanel(o) + ovStatusPanel(o));
  }

  // Live heartbeat — node % is a coarse 34-node metric that sits flat for hours while
  // L2 tasks grind toward one node's gate; this strip shows the loop IS moving.
  function ovPulseStrip(o) {
    const p = o.pulse || {};
    const age = p.activityAgeSeconds;
    let state, tone, label;
    if (!p.running) { state = "stopped"; tone = "idle"; label = "stopped"; }
    else if (age != null && age <= 600) { state = "progressing"; tone = "integrated"; label = "running"; }
    else { state = "idle"; tone = "stale"; label = "running · quiet"; }
    const stat = (k, v) => `<span class="pulse-stat"><span class="ps-k">${k}</span><span class="ps-v">${v}</span></span>`;
    return `<div class="pulse-strip" data-state="${state}">
      <span class="pulse-led" data-tone="${tone}"></span>
      <span class="pulse-label">${esc(label)}${p.activeArea ? ` · <span class="pulse-area">${esc(p.activeArea)}</span>` : ""}</span>
      <span class="pulse-stats">
        ${stat("iter", p.iteration != null ? p.iteration : "—")}
        ${stat("last", p.lastActivityAt ? relTime(p.lastActivityAt, o.generatedAt) + " ago" : "—")}
        ${stat("integ/hr", p.recentIntegrations != null ? p.recentIntegrations : "—")}
        ${stat("lifetime", p.integrationsLifetime != null ? p.integrationsLifetime : "—")}
      </span>
    </div>`;
  }

  // Per-area frontier throughput — which area the loop is feeding now and the nodes it
  // is working toward, so "grinding the frontier" is distinguishable from "stuck".
  function ovActivityRows(o) {
    const fa = o.frontierActivity || [];
    if (!fa.length) return '<span class="section-empty">all nodes gated — plan complete</span>';
    return fa.map((a) => {
      const nodes = (a.nodes || []).map((n) =>
        `<button class="dep-chip" data-node-id="${escAttr(n.id)}" data-nav-node="1">${toneDot(gateTone(n.status))}<span class="dep-chip-id">${esc(n.id)}</span></button>`).join("");
      const rate = a.recentIntegrations > 0
        ? `<span class="fa-rate"><span class="num">${a.recentIntegrations}</span> integrated · ${esc(relTime(a.lastAt, o.generatedAt))} ago</span>`
        : `<span class="fa-rate fa-quiet">no recent integrations</span>`;
      return `<div class="fa-row${a.active ? " fa-active" : ""}">
        <div class="fa-head">
          <span class="fa-area">${toneDot(a.active ? "integrated" : "idle")}<span>${esc(a.area)}</span></span>
          ${a.active ? '<span class="fa-tag">active</span>' : ""}
          ${rate}
        </div>
        <div class="chips-row">${nodes}</div>
      </div>`;
    }).join("");
  }

  function ovProgressPanel(o) {
    const p = o.progress || {};
    const ladder = (o.stages || []).map((s) => {
      const pct = s.total ? Math.round(100 * s.passed / s.total) : 0;
      const pips = (s.nodes || []).map((n) =>
        `<button class="ph-pip" data-node-id="${escAttr(n.id)}" data-nav-node="1" data-tone="${gateTone(n.status)}" title="${escAttr(n.id + " · " + n.status)}"></button>`).join("");
      return `<div class="ph-row" data-status="${esc(s.status)}">
        <span class="ph-stage">${esc(s.stage)}</span>
        <span class="ph-bar"><span class="ph-fill" data-status="${esc(s.status)}" style="width:${pct}%"></span></span>
        <span class="ph-pips">${pips}</span>
        <span class="ph-count">${s.passed}/${s.total}</span>
      </div>`;
    }).join("");
    return `<div class="tab-panel" data-tab="progress">
      <div class="field-block">
        <div class="ov-progress-head"><span class="ov-pct">${p.pct != null ? p.pct + "%" : "—"}</span>
          <span class="ov-progress-sub">${p.passedNodes || 0} / ${p.totalNodes || 0} DAG nodes gated complete</span></div>
        <div class="ov-progress-bar"><span class="ov-progress-fill" style="width:${p.pct || 0}%"></span></div>
      </div>
      ${ovPulseStrip(o)}
      <div class="field-block"><span class="meta-label">phases · D-stages + S0</span><div class="ph-ladder">${ladder}</div></div>
      <div class="field-block"><span class="meta-label">active work · where the loop is grinding now</span><div class="fa-list">${ovActivityRows(o)}</div></div>
    </div>`;
  }

  function ovInputsPanel(o) {
    const inp = o.inputs || {};
    const feedRow = (i) => `<div class="src-row">
      <span class="src-path mono">${esc(i.path)}</span>
      ${i.count != null ? `<span class="count-badge"><span class="pos">${i.count}</span></span>` : ""}
      ${i.role ? `<span class="src-role">${esc(i.role)}</span>` : ""}
      <span class="src-note">${esc(i.note)}</span></div>`;
    const pp = inp.plannerPrompt || {};
    return `<div class="tab-panel" data-tab="inputs">
      <div class="note">L0 (origin) and L1 (planners) are driven by the executable DAG and gate results — not by the prose plan docs, which were distilled into the DAG once and are now static reference.</div>
      <div class="field-block"><span class="meta-label">live feed · read every cycle</span>${(inp.runtime || []).map(feedRow).join("")}</div>
      <div class="field-block"><span class="meta-label">authoring source · not read at runtime</span>${(inp.authoring || []).map((i) => `<div class="src-row src-static"><span class="src-path mono">${esc(i.path)}</span><span class="src-tag">static</span><span class="src-note">${esc(i.note)}</span></div>`).join("")}</div>
      <div class="field-block"><span class="meta-label">L1 planner prompt</span><div class="src-note" style="padding:2px 0">${esc(pp.note || "")} <span class="mono">${esc(pp.ref || "")}</span></div></div>
    </div>`;
  }

  // Effort heat scale for reasoning enums — EDITORIAL (intensity), not live status:
  // it lets the planner-xhigh > worker-medium effort gradient read as a colour ladder.
  const REASONING_TONE = { xhigh: "active", high: "active", medium: "idle", low: "warn", minimal: "warn" };

  // bool default (raw "0"/"1" or boolValue) -> on/off status-chip, never raw 0/1.
  function boolPill(it) {
    const on = it.boolValue === true || it.value === "1" || it.value === "on";
    return `<span class="status-chip set-bool" data-tone="${on ? "success" : "idle"}">${toneDot(on ? "integrated" : "idle")}<span>${on ? "on" : "off"}</span></span>`;
  }

  // magnitude-first number + faint split unit (reuses the .stat-value/.num/.unit idiom).
  function numVal(it) {
    const u = it.unit ? `<span class="unit">${esc(it.unit)}</span>` : "";
    return `<span class="stat-value set-num"><span class="num">${esc(it.value)}</span>${u}</span>`;
  }

  // dispatch a single value cell by item.kind.
  function settingVal(it) {
    switch (it.kind) {
      case "bool":
        return boolPill(it);
      case "derived": // a hollow ring reads "computed / linked, not a literal value"
        return `<span class="gate-tag set-derived" data-tone="idle">${toneDot("idle", "ring")}<span class="lbl">${esc(it.value)}</span></span>`;
      case "reasoning":
        return `<span class="gate-tag" data-tone="${REASONING_TONE[String(it.value).toLowerCase()] || "idle"}"><span class="lbl">${esc(it.value)}</span></span>`;
      case "enum":
        return `<span class="gate-tag" data-tone="idle"><span class="lbl">${esc(it.value)}</span></span>`;
      case "model":
        return `<span class="gate-tag set-model" data-tone="active"><span class="lbl">${esc(it.value)}</span></span>`;
      case "identifier":
        return `<code class="mono set-id">${esc(it.value)}</code><button class="copy-btn" data-copy="${escAttr(it.value)}">${icon("i-copy")}</button>`;
      default: // count, duration, bytes
        return numVal(it);
    }
  }

  // one ledger row: label (+ optional meaning) + faint env-key caption | typed value.
  function settingRow(it) {
    const meaning = it.meaning ? `<span class="set-meaning">${esc(it.meaning)}</span>` : "";
    return `<div class="set-row">
      <div class="set-key"><span class="set-label">${esc(it.label)}</span>${meaning}<code class="set-env mono">${esc(it.envKey || it.key)}</code></div>
      <div class="set-val">${settingVal(it)}</div>
    </div>`;
  }

  // role x {model, reasoning} matrix for the models group (layout === "matrix").
  // Looks items up BY envKey so it is robust to spec reordering.
  function roleMatrix(g) {
    const items = g.items || [];
    const byKey = (k) => items.find((it) => (it.envKey || it.key) === k) || { value: "—", envKey: k };
    const model = byKey("GLUERUN_CODEX_MODEL");
    const tier = byKey("GLUERUN_CODEX_SERVICE_TIER");
    const roles = [
      ["planner", "L1", byKey("GLUERUN_CODEX_PLANNER_REASONING_EFFORT")],
      ["worker", "L2", byKey("GLUERUN_CODEX_L2_REASONING_EFFORT")],
      ["auditor", "gate", byKey("GLUERUN_CODEX_AUDITOR_REASONING_EFFORT")],
    ];
    const head = `<div class="set-row set-shared">
      <div class="set-key"><span class="set-label">all roles</span><code class="set-env mono">${esc(model.envKey || "GLUERUN_CODEX_MODEL")}</code></div>
      <div class="set-val"><span class="gate-tag set-model" data-tone="active"><span class="lbl">${esc(model.value)}</span></span><span class="gate-tag" data-tone="idle"><span class="lbl">tier ${esc(tier.value)}</span></span></div>
    </div>`;
    const rows = roles.map(([name, cap, eff]) => {
      const tone = REASONING_TONE[String(eff.value).toLowerCase()] || "idle";
      const help = eff.meaning ? `<span class="set-meaning">${esc(eff.meaning)}</span>` : "";
      return `<div class="set-row">
        <div class="set-key"><span class="role-chip">${icon("i-cpu")}<span>${esc(name)}</span><span class="role-cap">${esc(cap)}</span></span>${help}<code class="set-env mono">${esc(eff.envKey || "")}</code></div>
        <div class="set-val"><span class="gate-tag" data-tone="${tone}"><span class="lbl">${esc(eff.value)}</span></span></div>
      </div>`;
    }).join("");
    return head + rows;
  }

  function ovSettingsPanel(o) {
    const groups = (o.settings || []).map((g) => {
      const body = g.layout === "matrix" ? roleMatrix(g) : (g.items || []).map(settingRow).join("");
      return `<div class="field-block"><span class="meta-label">${esc(g.title || g.category)}</span><div class="set-list">${body}</div></div>`;
    }).join("");
    return `<div class="tab-panel" data-tab="settings">
      <div class="note">Configured <strong>defaults</strong> — env-overridable, parsed from <span class="mono">scripts/orchestration/*.sh</span>. There is no single runtime config file, so these are the defaults the loop uses unless overridden — <strong>not</strong> a record of any one run's env. The faint key under each setting is the override knob.</div>
      ${groups}
    </div>`;
  }

  function ovStatusPanel(o) {
    const l = o.loop || {};
    const running = !l.stopPresent && !/stop|halt/i.test(l.note || "");
    const stateChip = `<span class="status-chip" data-tone="${running ? "success" : "warn"}">${toneDot(running ? "integrated" : "stale")}<span>${running ? "running" : "stopped"}</span></span>`;
    return `<div class="tab-panel" data-tab="status">
      <div class="field-block"><span class="meta-label">autonomous loop</span>
        <div class="chips-row" style="margin-bottom:7px">${stateChip}${l.stopPresent ? `<span class="gate-tag" data-tone="warn">${toneDot("stale")}<span class="lbl">STOP sentinel present</span></span>` : ""}</div>
        ${kvGrid([
          ["note", l.note || "—"],
          ["iteration", l.iteration != null ? l.iteration : "—"],
          ["ready tasks", l.readyTasks != null ? l.readyTasks : "—"],
          ["active leases", l.activeLeases != null ? l.activeLeases : "—"],
          ["circuit breaker", l.breaker ? l.breaker + " consec fails" : (l.consecFails != null ? l.consecFails : "—")],
          ["integrations (lifetime)", l.integrationsLifetime != null ? l.integrationsLifetime : "—"],
          ["parked escalations (lifetime)", l.parkedLifetime != null ? l.parkedLifetime : "—"],
          ["imported packets", l.importedPackets != null ? l.importedPackets : "—"],
          ["branch", l.branch || "—", true],
          ["head", l.headSha || "—", true],
          ["status updated", l.updatedAt || "—"],
        ])}</div>
    </div>`;
  }

  // "work" tab — observed-this-run agents + the tools/commands they actually ran
  // (honest proxies; glueRun-go has no live skill registry).
  function renderWorkPanel(d) {
    const ai = d.agentsInvolved || {};
    const tu = d.toolsUsed || {};
    const chips = [];
    if (ai.owner) chips.push(`<span class="role-chip">${icon("i-cpu")}<span>owner · ${esc(ai.owner)}</span><span class="role-cap">recorded</span></span>`);
    for (const r of ai.rolesFromPrompts || []) {
      const reason = r.reason ? ` · ${esc(r.reason)}` : "";
      chips.push(`<span class="role-chip">${icon("i-cpu")}<span>${esc(r.role)}${reason}</span><span class="role-cap">inferred</span></span>`);
    }
    const cmdRow = (cmd, exit) => `<div class="cmd-row"><span class="cmd-text">${esc(cmd || "")}</span>${
      exit != null ? `<span class="gate-tag" data-tone="${toneOf(exit === 0 ? "integrated" : "blocked")}">${toneDot(exit === 0 ? "integrated" : "blocked")}<span class="lbl">exit ${exit}</span></span>` : ""
    }</div>`;
    const worker = (tu.workerCommands || []).map((c) => cmdRow(c.cmd, c.exitCode)).join("");
    const auditor = (tu.auditorCommands || []).map((c) => cmdRow(c, null)).join("");
    const packet = (d.packets || [])[0];
    const kinds = packet && packet.evidence ? [...new Set(packet.evidence.map((e) => e.kind).filter(Boolean))] : [];
    return `<div class="tab-panel" data-tab="work">
      <div class="field-block"><span class="meta-label">roles involved · observed this run</span>
        <div class="chips-row">${chips.join("") || '<span class="section-empty">no roles recorded for this run</span>'}</div></div>
      ${ai.source ? `<div class="note">${esc(ai.source)}</div>` : ""}
      ${worker ? `<div class="field-block"><span class="meta-label">worker · packet commands</span>${worker}</div>` : ""}
      ${auditor ? `<div class="field-block"><span class="meta-label">auditor · audit.json commands</span><div class="cmd-sub">read-only audit; no exit codes recorded</div>${auditor}</div>` : ""}
      <div class="field-block"><span class="meta-label">gate command</span>${tu.gateCommand ? cmdRow(tu.gateCommand, tu.gateCheck ? tu.gateCheck.exitCode : null) : '<span class="section-empty">none</span>'}</div>
      ${kinds.length ? `<div class="field-block"><span class="meta-label">evidence kinds · observed</span><div class="chips-row">${kinds.map((k) => `<span class="tool-chip">${esc(k)}</span>`).join("")}</div></div>` : ""}
    </div>`;
  }

  function stateFromLease(s) {
    s = String(s || "").toLowerCase();
    if (s === "accepted") return "awaiting";
    if (s === "blocked") return "blocked";
    if (["failed", "error"].includes(s)) return "failed";
    if (["integrated", "merged", "complete", "completed"].includes(s)) return "integrated";
    return "active";
  }
  // L1 node-lease status -> tone. proposed/planning/active = live planner (cobalt);
  // released = handed off (forest, NOT "complete" — gates are the only authority);
  // failed = red.
  function l1LeaseTone(s) {
    s = String(s || "").toLowerCase();
    if (s === "failed") return "failed";
    if (s === "released") return "integrated";
    if (["proposed", "planning", "active"].includes(s)) return "active";
    return "idle";
  }
  // gate-result.v0 status -> tone. passed=forest, blocked/invalid=red, stale=amber,
  // absent=gray.
  function gateTone(status) {
    status = String(status || "").toLowerCase();
    if (status === "passed") return "integrated";
    if (status === "blocked" || status === "invalid") return "blocked";
    if (status === "stale") return "warn";
    return "idle";
  }
  const truncate = (s, n) => { s = String(s || ""); return s.length > n ? s.slice(0, n - 1) + "…" : s; };

  function eventTone(type) {
    type = String(type || "");
    if (/fail|error|frozen|blocked|reject|pressure|abort/.test(type)) return "warn";
    if (/accept/.test(type)) return "active"; // awaiting/approval reads cobalt, not green
    if (/passed|integrated|committed|ok/.test(type)) return "success";
    if (/dispatch|started|generated|fanout|staged|lease/.test(type)) return "active";
    return "idle";
  }

  function fileItem(f, kind) {
    const isPath = /\//.test(f);
    return `<div class="file-item ${kind}">
      <span class="bezel" data-tone="${kind === "forbidden" ? "warn" : "idle"}">${icon("i-file")}</span>
      <span style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis">${esc(f)}</span>
      ${isPath ? `<button class="copy-btn" data-copy="${escAttr(f)}">${icon("i-copy")}</button>` : ""}
    </div>`;
  }

  function kvGrid(rows) {
    return `<div class="kv-grid">` + rows.map(([k, v, mono]) => `
      <div class="kv-key">${esc(k)}</div>
      <div class="kv-value${mono ? " mono" : ""}">${esc(v == null || v === "" ? "—" : v)}${mono && v && v !== "—" ? `<button class="copy-btn" data-copy="${escAttr(v)}">${icon("i-copy")}</button>` : ""}</div>`).join("") + `</div>`;
  }

  // ============================================================ EVENTS ======
  function onClick(e) {
    // a pan-drag just ended — swallow the trailing click so it doesn't select
    if (S._suppressClick) { S._suppressClick = false; return; }

    const copyBtn = e.target.closest(".copy-btn");
    if (copyBtn) { e.stopPropagation(); copy(copyBtn.dataset.copy); return; }

    const zoomBtn = e.target.closest(".zoom-btn");
    if (zoomBtn) {
      const z = zoomBtn.dataset.zoom;
      if (z === "fit") fitGraph(); else zoomAt(z === "in" ? 1.2 : 1 / 1.2);
      return;
    }

    const pinGlyph = e.target.closest(".pin-glyph");
    if (pinGlyph) { e.stopPropagation(); const node = pinGlyph.closest("[data-task-id]"); if (node) togglePin(node.dataset.taskId); return; }

    const more = e.target.closest(".gnode.more");
    if (more) {
      const area = more.dataset.area;
      S.budgets.set(area, (S.budgets.get(area) || 0) + MORE_STEP);
      renderCurrentView(true);
      return;
    }

    // L1 graph node: toggle its lane AND select it for the inspector
    const l1node = e.target.closest(".gnode.l1");
    if (l1node) { toggleExpand(l1node.dataset.area); select("l1", l1node.dataset.id); return; }

    // Node navigation — area Nodes-tab rows and task/node provenance chips.
    const navNode = e.target.closest("[data-nav-node]");
    if (navNode) { select("node", navNode.dataset.nodeId); return; }

    const dep = e.target.closest("[data-nav]");
    if (dep) { navigateToTask(dep.dataset.taskId); return; }

    const node = e.target.closest("[data-task-id]");
    if (node && node.dataset.layer === "l2") { select("l2", node.dataset.taskId); return; }

    const l0 = e.target.closest('[data-layer="l0"]');
    if (l0) { select("l0", "L0"); return; }
  }

  // background-drag = pan; wheel = zoom-to-cursor; click on a node still selects
  function initGraphInteractions() {
    const vp = $("view-graph");
    vp.addEventListener("wheel", (e) => {
      e.preventDefault();
      zoomAt(Math.exp(-e.deltaY * 0.0015), e);
    }, { passive: false });
    let down = null, moved = false;
    vp.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      if (e.target.closest(".gnode") || e.target.closest(".canvas-controls")) return; // node/control press
      down = { x: e.clientX, y: e.clientY, tx: S.transform.x, ty: S.transform.y }; moved = false;
    });
    window.addEventListener("pointermove", (e) => {
      if (!down) return;
      const dx = e.clientX - down.x, dy = e.clientY - down.y;
      if (!moved && Math.hypot(dx, dy) > 5) { moved = true; S._userPanned = true; vp.classList.add("dragging"); }
      if (moved) { S.transform.x = down.tx + dx; S.transform.y = down.ty + dy; applyTransform(); }
    });
    const end = () => { if (down && moved) S._suppressClick = true; down = null; moved = false; vp.classList.remove("dragging"); };
    window.addEventListener("pointerup", end);
    window.addEventListener("pointercancel", end);
  }

  // Deep link: #<id> or #<id>:<tab>  (id = TASK-xxxx | L0 | L1:area)
  function applyDeepLink() {
    const h = decodeURIComponent((location.hash || "").replace(/^#/, ""));
    if (!h) return;
    const ci = h.lastIndexOf(":");
    let id = h, tab = "";
    // L1:/NODE: ids contain a ':', so only split a trailing :tab past that prefix colon.
    const prefixed = h.startsWith("L1:") || h.startsWith("NODE:");
    if (ci > 0 && !prefixed) { id = h.slice(0, ci); tab = h.slice(ci + 1); }
    else if (prefixed && h.indexOf(":", h.indexOf(":") + 1) > 0) {
      const j = h.indexOf(":", h.indexOf(":") + 1); id = h.slice(0, j); tab = h.slice(j + 1);
    }
    if (tab) S.inspTab = tab === "events" ? "timeline" : tab; // events tab was renamed
    if (/^TASK-\d+$/.test(id)) { if ((S.snap.l2Tasks || []).some((t) => t.id === id)) navigateToTask(id); }
    else if (id === "L0") select("l0", "L0");
    else if (id === "PLAN") select("overview", "plan");
    else if (/^NODE:/.test(id)) select("node", id.slice(5));
    else if (/^L1:/.test(id)) select("l1", id);
  }

  function navigateToTask(id) {
    const t = (S.snap.l2Tasks || []).find((x) => x.id === id);
    if (t && !S.expanded.has(t.area)) S.expanded.add(t.area);
    select("l2", id);
    renderCurrentView(true); // rebuild so the (now-expanded) lane includes the node
    panToNode(id);
  }
  const cssEsc = (s) => (window.CSS && CSS.escape ? CSS.escape(s) : s);

  function toggleExpand(area) {
    if (S.expanded.has(area)) S.expanded.delete(area); else S.expanded.add(area);
    renderCurrentView(true);
  }

  function togglePin(id) {
    S.pinnedId = S.pinnedId === id ? null : id;
    if (S.pinnedId) localStorage.setItem("gluerun.pinnedId", S.pinnedId);
    else localStorage.removeItem("gluerun.pinnedId");
    applyMarkers();
    if (S.selectedId) $("insp-pin").setAttribute("aria-pressed", String(S.pinnedId === S.selectedId));
  }

  // Task-list drawer: expand/retract inside the graph area (no view swap).
  function applyListDrawer() {
    const d = $("list-drawer");
    d.dataset.open = String(S.listOpen);
    d.style.setProperty("--list-h", S.listHeight + "px");
    $("list-toggle").setAttribute("aria-expanded", String(S.listOpen));
  }
  function toggleList(open) {
    S.listOpen = (open == null) ? !S.listOpen : open;
    localStorage.setItem("gluerun.listOpen", S.listOpen ? "1" : "0");
    applyListDrawer();
    if (S.listOpen) renderCurrentView(true);   // populate the table on first open
    if (!S._userPanned) fitGraph();            // graph re-fits to its new height
  }
  function setListHeight(px) {
    S.listHeight = Math.max(120, Math.min(window.innerHeight - 220, Math.round(px)));
    localStorage.setItem("gluerun.listH", String(S.listHeight));
    $("list-drawer").style.setProperty("--list-h", S.listHeight + "px");
    if (!S._userPanned) fitGraph();
  }
  // Drag the drawer's top grip to resize (height grows as the pointer moves up).
  function initListResize() {
    const grip = $("list-resize");
    let startY = 0, startH = 0, dragging = false;
    grip.addEventListener("pointerdown", (e) => {
      if (!S.listOpen) return;
      dragging = true; startY = e.clientY; startH = S.listHeight;
      grip.setPointerCapture(e.pointerId); e.preventDefault();
    });
    grip.addEventListener("pointermove", (e) => {
      if (dragging) setListHeight(startH + (startY - e.clientY));
    });
    const end = (e) => { if (dragging) { dragging = false; try { grip.releasePointerCapture(e.pointerId); } catch (x) {} } };
    grip.addEventListener("pointerup", end);
    grip.addEventListener("pointercancel", end);
  }

  function setAreaFilter(area) {
    S.areaFilter = area;
    $("filter-area").value = area;
    renderShowing();
    renderCurrentView(true);
  }

  function setStatusFilter(st) {
    S.statusFilter = S.statusFilter === st ? "" : st;
    $("filter-status").value = S.statusFilter;
    renderTop();
    renderShowing();
    renderCurrentView(true);
  }

  // -------------------------------------------------- inspector bottom sheet
  // Grip affordance: tap dismisses; drag the sheet down past a threshold dismisses,
  // a small drag snaps back. (Esc and the scrim also dismiss.)
  function initInspectorSheet() {
    const insp = $("inspector");
    const grip = $("inspector-grip");
    let drag = null;
    const onMove = (e) => {
      if (!drag) return;
      const dy = e.clientY - drag.y;
      if (Math.abs(dy) > 4) drag.moved = true;
      insp.style.transform = "translateY(" + Math.max(0, dy) + "px)";
    };
    const end = (e) => {
      if (!drag) return;
      const dy = Math.max(0, (e.clientY || drag.y) - drag.y);
      const moved = drag.moved;
      drag = null;
      insp.classList.remove("dragging");
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", end);
      window.removeEventListener("pointercancel", end);
      if (!moved || dy > 130) select("none", null); // tap or far drag → dismiss
      else insp.style.transform = "";               // small drag → snap back
    };
    grip.addEventListener("pointerdown", (e) => {
      drag = { y: e.clientY, moved: false };
      insp.classList.add("dragging");
      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", end);
      window.addEventListener("pointercancel", end);
    });
  }

  // ------------------------------------------------------------ dock resize
  function initResize() {
    const handle = $("dock-resize-handle");
    const dock = $("dock");
    let dragging = false;
    const onMove = (ev) => {
      if (!dragging) return;
      const appPad = 10;
      // Keep a floor tall enough that the always-on terminal stays usable.
      const h = Math.max(150, Math.min(window.innerHeight * 0.92, window.innerHeight - ev.clientY - appPad));
      dock.style.height = h + "px";
      dock.dataset.size = "custom";
    };
    const stop = () => {
      dragging = false;
      document.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerup", stop);
      document.removeEventListener("pointercancel", stop);
    };
    handle.addEventListener("pointerdown", (ev) => {
      dragging = true; ev.preventDefault();
      document.addEventListener("pointermove", onMove);
      document.addEventListener("pointerup", stop);
      document.addEventListener("pointercancel", stop);
    });
    handle.addEventListener("dblclick", () => setDockSize(dock.dataset.size === "full" ? "half" : "full"));
  }

  // ========================================================== TERMINAL ======
  // Always-on session terminal in the work dock. Polls /api/sessions every 2s
  // (independent of the 10s graph snapshot) and incrementally tails each visible
  // pane's log via a byte cursor. Strict read-only observer — it never writes.
  const TERM_POLL_MS = 2000;
  const TERM_MAX_LINES = 600;        // per-pane ring-buffer cap (DOM nodes)
  const TERM_LINE_LIMIT = 500;       // initial tail size requested from the server
  const TERM_BACKLOG_SNAP = 1000000; // bytes behind EOF before we snap to the live tail

  const T = {
    sessions: [],
    auto: { mode: "origin", sessionIds: ["origin"] },
    autoOn: localStorage.getItem("gluerun.term.auto") !== "0",
    follow: localStorage.getItem("gluerun.term.follow") !== "0",
    raw: localStorage.getItem("gluerun.term.raw") === "1",
    solo: localStorage.getItem("gluerun.term.solo") === "1",
    manualIds: safeParse(localStorage.getItem("gluerun.term.manual"), []),
    sessById: new Map(),
    panes: new Map(),  // id -> pane state
    visible: [],
    generatedAt: null, // generatedAt of the latest /api/sessions payload (2s cadence)
    _chipSig: null,    // signature gate for the chip strip
    fetchingSessions: false,
    started: false,
  };
  function safeParse(s, fb) { try { return JSON.parse(s) || fb; } catch { return fb; } }
  function persistTerm() {
    localStorage.setItem("gluerun.term.auto", T.autoOn ? "1" : "0");
    localStorage.setItem("gluerun.term.follow", T.follow ? "1" : "0");
    localStorage.setItem("gluerun.term.raw", T.raw ? "1" : "0");
    localStorage.setItem("gluerun.term.solo", T.solo ? "1" : "0");
    localStorage.setItem("gluerun.term.manual", JSON.stringify(T.manualIds));
  }

  function termVisibleIds() {
    let ids;
    if (T.autoOn || !T.manualIds.length) {
      // Auto: only show sessions the server currently lists; fall back to origin.
      ids = (T.auto.sessionIds || []).filter((id) => T.sessById.has(id));
      if (!ids.length) ids = ["origin"];
    } else {
      // Pinned/manual: honor explicit pins even if a session briefly drops out of the
      // capped /api/sessions list — the server resolves any valid id directly, so the
      // pane keeps streaming instead of collapsing to origin and losing its scrollback.
      ids = T.manualIds.slice();
    }
    return T.solo ? ids.slice(0, 1) : ids.slice(0, 3);
  }

  async function termFetchSessions() {
    if (T.fetchingSessions) return;
    T.fetchingSessions = true;
    try {
      const res = await fetch("/api/sessions", { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      const data = await res.json();
      T.sessions = data.sessions || [];
      T.auto = data.auto || T.auto;
      T.generatedAt = data.generatedAt || null; // drive age display off the 2s feed, not the 10s snapshot
      T.sessById = new Map(T.sessions.map((s) => [s.id, s]));
      renderTermBar();
      renderTermChips();
      reconcilePanes();
    } catch (e) {
      /* keep last good session list; a transient poll miss must not blank the dock */
    } finally {
      T.fetchingSessions = false;
    }
  }

  function renderTermBar() {
    $("term-mode").textContent = T.autoOn ? ("auto · " + (T.auto.mode || "—")) : "manual";
    const set = (n, on) => { const b = document.querySelector('.term-ctl[data-ctl="' + n + '"]'); if (b) b.setAttribute("aria-pressed", String(on)); };
    set("auto", T.autoOn); set("pin", !T.autoOn); set("follow", T.follow); set("raw", T.raw); set("solo", T.solo);
  }

  // Chip-worthy sessions only: origin + currently-live work, plus whatever is on
  // screen or pinned. Finished/quiet sessions (idle/integrated/stale) are dropped
  // so the strip stays short and relevant rather than listing every task.
  const LIVE_CHIP_STATES = new Set(["active", "awaiting", "blocked", "failed", "running", "dispatched"]);
  function chipSessions(visible) {
    const keep = new Set(visible);
    (T.manualIds || []).forEach((id) => keep.add(id));
    return T.sessions.filter((s) =>
      s.kind === "origin" || LIVE_CHIP_STATES.has(s.state) || keep.has(s.id));
  }

  function renderTermChips() {
    const visible = termVisibleIds();
    const shown = chipSessions(visible);
    // Signature-gate the rebuild (mirrors renderCurrentView): a quiet 2s poll must
    // not churn the chip DOM or drop hover/:active state mid-interaction.
    const sig = JSON.stringify([shown.map((s) => [s.id, s.state, s.role, s.taskId || s.node || s.runId]), visible]);
    if (sig === T._chipSig) return;
    T._chipSig = sig;
    const sel = new Set(visible);
    $("term-chips").innerHTML = shown.map((s) => {
      const label = s.taskId || s.node || (s.kind === "origin" ? "origin" : (shortRun(s.runId) || s.id));
      return `<button class="term-chip" data-term-chip="${escAttr(s.id)}" aria-pressed="${sel.has(s.id)}" title="${escAttr(s.id)}">
        ${toneDot(s.state)}<span class="term-chip-role">${esc(s.role || s.kind)}</span><span class="term-chip-id">${esc(label)}</span></button>`;
    }).join("");
  }

  function reconcilePanes() {
    const ids = termVisibleIds();
    T.visible = ids;
    const host = $("term-panes");
    $("session-terminal").dataset.empty = String(ids.length === 0);
    for (const [id, pane] of [...T.panes]) {
      if (!ids.includes(id)) { pane.el.remove(); T.panes.delete(id); }
    }
    if (!ids.length) {
      host.innerHTML = `<div class="term-empty">${icon("i-terminal")}<div>no active sessions</div></div>`;
      return;
    }
    const empty = host.querySelector(".term-empty"); if (empty) empty.remove();
    for (const id of ids) {
      if (!T.panes.has(id)) T.panes.set(id, createPane(id));
      updatePaneHead(id);
    }
    // Insert/move panes ONLY when their DOM position is actually wrong. Re-appending
    // an already-attached pane every poll would reset its scrollTop to 0 (and fire a
    // scroll event that flips atBottom=false), which breaks Follow and sticks the view
    // at the top. In steady state this loop touches nothing, so scroll is preserved.
    ids.forEach((id, i) => {
      const el = T.panes.get(id).el;
      if (host.children[i] !== el) host.insertBefore(el, host.children[i] || null);
    });
  }

  function createPane(id) {
    const el = document.createElement("div");
    el.className = "term-pane";
    el.dataset.id = id;
    el.innerHTML = `<div class="term-pane-head"></div><div class="term-pane-body"><div class="term-pane-loading">connecting…</div></div>`;
    const body = el.querySelector(".term-pane-body");
    const pane = { el, body, cursor: null, raw: T.raw, lineEls: new Map(), count: 0, atBottom: true, inflight: false, loaded: false };
    body.addEventListener("scroll", () => {
      pane.atBottom = body.scrollTop + body.clientHeight >= body.scrollHeight - 6;
    });
    return pane;
  }

  function updatePaneHead(id) {
    const pane = T.panes.get(id); if (!pane) return;
    // A pinned session can briefly be absent from the capped list — show it as
    // reconnecting (it keeps streaming) rather than mislabeling it.
    const s = T.sessById.get(id) || { id, kind: "session", role: "session", state: "idle", phase: "reconnecting…" };
    const ident = s.taskId || s.node || (s.kind === "origin" ? "origin" : (shortRun(s.runId) || s.id));
    const age = relTime(s.updatedAt, T.generatedAt || (S.snap && S.snap.generatedAt));
    const hint = s.branch ? shortBranch(s.branch) : (s.area || (s.runId ? shortRun(s.runId) : ""));
    pane.el.querySelector(".term-pane-head").innerHTML =
      `<span class="term-pane-role" data-tone="${toneOf(s.state)}">${toneDot(s.state)}${esc(s.role || s.kind)}</span>
       <span class="term-pane-id">${esc(ident)}</span>
       <span class="term-pane-meta">${s.phase ? `<span class="tp-phase">${esc(s.phase)}</span>` : ""}<span>${esc(age)}</span>${hint ? `<span>${esc(hint)}</span>` : ""}</span>`;
  }

  function termPollLines() { for (const id of T.visible) termFetchLines(id); }

  async function termFetchLines(id) {
    const pane = T.panes.get(id); if (!pane || pane.inflight) return;
    if (pane.raw !== T.raw) { resetPane(pane); pane.raw = T.raw; } // raw toggled — reload
    pane.inflight = true;
    try {
      const p = new URLSearchParams();
      if (pane.cursor != null) p.set("cursor", String(pane.cursor));
      p.set("limit", String(TERM_LINE_LIMIT));
      if (T.raw) p.set("raw", "1");
      const res = await fetch("/api/session/" + encodeURIComponent(id) + "?" + p.toString(), { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      const data = await res.json();
      const fresh = data.reset || pane.cursor == null;
      if (fresh) clearPaneBody(pane);
      appendLines(pane, data.lines || [], fresh);
      pane.cursor = data.cursor;
      pane.loaded = true;
      // Far behind a bursty writer (forward reads advance one window at a time)?
      // Snap to the live tail next poll instead of crawling — show "now", not history.
      if (data.size != null && data.size - data.cursor > TERM_BACKLOG_SNAP) pane.cursor = null;
    } catch (e) {
      if (!pane.loaded) pane.body.innerHTML = `<div class="term-pane-loading">could not load session</div>`;
    } finally {
      pane.inflight = false;
    }
  }

  function resetPane(pane) { pane.cursor = null; clearPaneBody(pane); }
  function clearPaneBody(pane) { pane.body.innerHTML = ""; pane.lineEls.clear(); pane.count = 0; pane.atBottom = true; }

  function makeNode(html) {
    const t = document.createElement("template");
    t.innerHTML = html.trim();
    return t.content.firstElementChild;
  }

  function appendLines(pane, lines, isInitial) {
    if (!lines.length) return;
    const wasBottom = pane.atBottom;
    const loading = pane.body.querySelector(".term-pane-loading"); if (loading) loading.remove();
    for (const ln of lines) {
      const node = makeNode(termLineHtml(ln));
      if (!node) continue;
      // command/file lines carry an item id — replace the in-progress row in place
      // when its completion arrives, instead of stacking a duplicate.
      if (ln.id && pane.lineEls.has(ln.id)) {
        pane.body.replaceChild(node, pane.lineEls.get(ln.id));
        pane.lineEls.set(ln.id, node);
      } else {
        pane.body.appendChild(node);
        pane.count++;
        if (ln.id) pane.lineEls.set(ln.id, node);
      }
    }
    while (pane.count > TERM_MAX_LINES && pane.body.firstElementChild) {
      const first = pane.body.firstElementChild;
      for (const [k, v] of pane.lineEls) if (v === first) pane.lineEls.delete(k);
      first.remove(); pane.count--;
    }
    if (T.follow && (wasBottom || isInitial)) scrollPaneToBottom(pane);
    else pane.atBottom = pane.body.scrollTop + pane.body.clientHeight >= pane.body.scrollHeight - 6;
  }

  // Pin a pane to the newest output. The rAF re-pin handles the case where flex
  // layout settles a frame after the lines are inserted (scrollHeight not final yet).
  function scrollPaneToBottom(pane) {
    const stick = () => {
      pane.body.scrollTop = pane.body.scrollHeight;
      pane.atBottom = true;
    };
    stick();
    requestAnimationFrame(stick);
  }

  function termLineHtml(ln) {
    switch (ln.kind) {
      case "message":
        return `<div class="term-line tl-message"><span class="tl-gutter">agent</span><span class="tl-text">${esc(ln.text)}${ln.truncated ? " …" : ""}</span></div>`;
      case "reasoning":
        return `<div class="term-line tl-message tl-reasoning"><span class="tl-gutter">think</span><span class="tl-text">${esc(ln.text)}</span></div>`;
      case "command": {
        const running = ln.status !== "completed" && ln.exitCode == null;
        const tail = running
          ? `<span class="tl-running">running…</span>`
          : (ln.exitCode != null
            ? `<span class="tl-exit gate-tag" data-tone="${toneOf(ln.exitCode === 0 ? "integrated" : "blocked")}">${toneDot(ln.exitCode === 0 ? "integrated" : "blocked")}<span class="lbl">exit ${esc(ln.exitCode)}</span></span>`
            : "");
        const out = (ln.output && ln.output.trim())
          ? `<div class="tl-output">${esc(ln.output)}${ln.outputTruncated ? "\n…" : ""}</div>` : "";
        return `<div class="term-line tl-command"><div class="tl-cmd-line"><span class="tl-prompt">$</span><span class="tl-cmd-text">${esc(ln.command)}</span>${tail}</div>${out}</div>`;
      }
      case "file": {
        const items = (ln.changes || []).map((c) =>
          `<span class="tl-fkind">${esc(c.kind || "edit")}</span> ${esc(String(c.path || "").split("/").slice(-2).join("/"))}`).join(" · ");
        return `<div class="term-line tl-file">✎ ${items || "file change"}</div>`;
      }
      case "event":
        return `<div class="term-line tl-event"><span class="tl-ev-ts">${esc(relTime(ln.ts, T.generatedAt || (S.snap && S.snap.generatedAt)))}</span><span class="tl-ev-type" data-tone="${eventTone(ln.eventType)}">${esc(ln.eventType)}</span><span class="tl-ev-msg">${esc(ln.text)}</span></div>`;
      case "meta":
        return `<div class="term-line tl-meta">${esc(ln.text)}</div>`;
      case "log":
      default: {
        const lvl = ln.level ? `<span class="tl-lvl">${esc(ln.level)}</span>` : "";
        return `<div class="term-line tl-log${ln.level ? " lvl-" + esc(ln.level) : ""}">${lvl}${esc(ln.text || "")}</div>`;
      }
    }
  }

  function termRefresh() { renderTermBar(); renderTermChips(); reconcilePanes(); termPollLines(); }

  async function termTick() {
    if (document.hidden) return; // don't poll a backgrounded tab
    await termFetchSessions();
    termPollLines();
  }

  function termInit() {
    if (T.started) return;
    T.started = true;
    renderTermBar();

    $("term-controls").addEventListener("click", (e) => {
      const b = e.target.closest(".term-ctl"); if (!b) return;
      const ctl = b.dataset.ctl;
      if (ctl === "auto") { T.autoOn = true; T.manualIds = []; }
      else if (ctl === "pin") { T.autoOn = false; T.manualIds = termVisibleIds().slice(); }
      else if (ctl === "follow") {
        T.follow = !T.follow;
        if (T.follow) for (const p of T.panes.values()) scrollPaneToBottom(p);
      } else if (ctl === "raw") {
        T.raw = !T.raw;
        for (const p of T.panes.values()) resetPane(p);
      } else if (ctl === "solo") { T.solo = !T.solo; }
      persistTerm();
      termRefresh();
    });

    $("term-chips").addEventListener("click", (e) => {
      const c = e.target.closest("[data-term-chip]"); if (!c) return;
      const id = c.dataset.termChip;
      const cur = (!T.autoOn && T.manualIds.length) ? T.manualIds : termVisibleIds();
      const set = new Set(cur);
      if (set.has(id)) set.delete(id);
      else set.add(id);
      let ids = [...set];
      if (!T.solo && ids.length > 3) ids = ids.slice(-3);
      T.manualIds = ids;
      T.autoOn = ids.length === 0; // emptied selection -> resume auto
      persistTerm();
      termRefresh();
    });

    termTick();
    setInterval(termTick, TERM_POLL_MS);
  }

  // =========================================================== OVERLAY ======
  // Live event overlay: a semantic, system-wide activity feed projected from
  // events.ndjson (/api/events, 2s cursor poll). Complementary to — never a
  // duplicate of — the dock terminal, which streams raw per-session log tails.
  // Distinct axis of screen space (graph width vs dock height) and a separate
  // state object, so the two feeds never contend. Strict read-only observer.
  const OVERLAY_POLL_MS = 2000;
  const OVERLAY_MAX_ROWS = 200;       // capped ring buffer (DOM rows)
  const OVERLAY_REQ_LIMIT = 120;
  const OVERLAY_BACKLOG_SNAP = 1500000;
  // server six-tone palette -> the client's [data-tone] vocabulary (reuses all CSS)
  const OV_TONE = { cobalt: "active", forest: "success", amber: "warn", red: "error", violet: "integration", gray: "idle" };
  const RECOVERY_TYPES = new Set(["recovery.action", "decider.verdict", "decider.parked", "l1.task_failed", "l1.frozen", "l1.task_terminal"]);
  const PROGRESS_RESET_TYPES = new Set(["l1.task_accepted", "integration.integrated", "packet.imported"]);

  const O = {
    rows: [],            // newest-first display model
    seen: new Set(),     // dedup by row signature
    cursor: null,        // byte cursor into events.ndjson
    feedSig: null,       // signature gate for the feed DOM
    collapsed: localStorage.getItem("gluerun.overlay.collapsed") === "1",
    unread: 0,
    inflight: false,
    started: false,
  };

  const ovRowSig = (r) => (r.ts || "") + "|" + (r.type || "") + "|" + (r.taskId || r.nodeId || r.runId || "");

  async function overlayFetch() {
    if (O.inflight) return;
    O.inflight = true;
    try {
      const p = new URLSearchParams();
      if (O.cursor != null) p.set("cursor", String(O.cursor));
      p.set("limit", String(OVERLAY_REQ_LIMIT));
      const res = await fetch("/api/events?" + p.toString(), { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      const data = await res.json();
      if (data.reset || O.cursor == null) { O.rows = []; O.seen.clear(); }
      appendOverlayRows(data.rows || []);
      O.cursor = data.cursor;
      // Far behind EOF (e.g. first load on a huge file) — snap to the live tail.
      if (data.size != null && O.cursor != null && data.size - O.cursor > OVERLAY_BACKLOG_SNAP) O.cursor = null;
      renderOverlay();
    } catch (e) {
      /* keep last good rows; a transient miss must not blank the rail */
    } finally {
      O.inflight = false;
    }
  }

  function appendOverlayRows(incoming) {
    for (const r of incoming) {           // incoming is chronological (file order)
      const sig = ovRowSig(r);
      if (O.seen.has(sig)) continue;
      O.seen.add(sig);
      r._sig = sig;
      O.rows.unshift(r);                  // newest-first
      if (O.collapsed) O.unread++;
    }
    if (O.rows.length > OVERLAY_MAX_ROWS) {
      for (const r of O.rows.splice(OVERLAY_MAX_ROWS)) O.seen.delete(r._sig);
    }
  }

  // progressing vs spinning, from event recency + rate + recovery loops.
  function resolvePulse() {
    const now = Date.now();
    let lastAdv = 0, rate = 0;
    for (const r of O.rows) {
      const t = Date.parse(r.ts) || 0;
      if (now - t < 60000) rate++;
      if (r.advancing && t > lastAdv) lastAdv = t;
    }
    const streak = new Map();
    for (let i = O.rows.length - 1; i >= 0; i--) {   // chronological
      const r = O.rows[i];
      if (!r.taskId) continue;
      if (RECOVERY_TYPES.has(r.type)) streak.set(r.taskId, (streak.get(r.taskId) || 0) + 1);
      else if (PROGRESS_RESET_TYPES.has(r.type)) streak.set(r.taskId, 0);
    }
    let stuck = null, maxStreak = 0;
    for (const [k, v] of streak) if (v > maxStreak) { maxStreak = v; stuck = k; }
    const advAge = lastAdv ? now - lastAdv : Infinity;
    // Stuck in a recovery loop, or actively churning without advancing => spinning.
    // Recently advancing => progressing. Otherwise (quiet) => idle.
    if (maxStreak >= 3) return { state: "spinning", text: "spinning · " + stuck, tone: "warn", rate };
    if (advAge < 90000) return { state: "progressing", text: "progressing", tone: "success", rate };
    if (rate > 0) return { state: "spinning", text: "spinning · no progress", tone: "warn", rate };
    return { state: "idle", text: "idle", tone: "idle", rate };
  }

  function renderOverlayPulse() {
    const p = resolvePulse();
    const pulse = $("ov-pulse");
    pulse.dataset.state = p.state;
    pulse.querySelector(".tone-dot").dataset.tone = p.tone;
    $("ov-pulse-text").textContent = p.text;
    $("ov-rate").textContent = p.rate ? p.rate + "/min" : "";
    $("ov-spine-dot").dataset.tone = p.tone;
    $("ov-unread").textContent = O.unread ? String(O.unread) : "";
  }

  function renderOverlay() {
    renderOverlayPulse();   // cheap; refresh every tick so the pulse stays live
    const sig = JSON.stringify([O.rows.slice(0, 60).map((r) => r._sig), O.collapsed]);
    if (sig === O.feedSig) return;       // signature-gate the feed DOM rebuild
    O.feedSig = sig;
    $("overlay-feed").innerHTML = O.rows.map((r) => {
      const tone = OV_TONE[r.tone] || "idle";
      const ref = r.taskId || r.nodeId;
      return `<button class="ov-row" data-tone="${tone}" data-task="${escAttr(r.taskId || "")}" data-node="${escAttr(r.nodeId || "")}" data-area="${escAttr(r.areaId || "")}">
        <span class="ov-age">${esc(relTime(r.ts, S.snap && S.snap.generatedAt))}</span>
        <span class="tone-dot" data-tone="${tone}"></span>
        <span class="ov-label">${esc(r.label || r.type)}</span>
        ${ref ? `<span class="ov-ref mono">${esc(ref)}</span>` : ""}
        ${r.reason ? `<span class="ov-reason" data-tone="${tone}">${esc(r.reason)}</span>` : ""}
      </button>`;
    }).join("");
  }

  function setOverlayCollapsed(v) {
    O.collapsed = v;
    localStorage.setItem("gluerun.overlay.collapsed", v ? "1" : "0");
    $("event-overlay").dataset.collapsed = String(v);
    if (!v) { O.unread = 0; renderOverlayPulse(); }
  }

  async function overlayTick() {
    if (document.hidden) return;
    await overlayFetch();
  }

  function overlayInit() {
    if (O.started) return;
    O.started = true;
    setOverlayCollapsed(O.collapsed);
    $("ov-collapse").addEventListener("click", () => setOverlayCollapsed(!O.collapsed));
    $("ov-spine").addEventListener("click", () => setOverlayCollapsed(false));
    // Clicking a row is the entry ramp into the provenance inspector.
    $("overlay-feed").addEventListener("click", (e) => {
      const row = e.target.closest(".ov-row"); if (!row) return;
      if (!S.snap) return; // overlay polls independently; ignore clicks until the graph snapshot is in
      const task = row.dataset.task, node = row.dataset.node, area = row.dataset.area;
      if (task && /^TASK-\d+$/.test(task)) { navigateToTask(task); return; }
      if (node) { select("node", node); return; }
      if (area) { select("l1", "L1:" + area); return; }
      select("l0", "L0");
    });
    overlayTick();
    setInterval(overlayTick, OVERLAY_POLL_MS);
  }

  // ----------------------------------------------------------------- init ---
  function init() {
    document.addEventListener("click", onClick);

    $("btn-refresh").addEventListener("click", () => load(true));
    $("plan-pill").addEventListener("click", () => select("overview", "plan"));

    // Task-list drawer: toggle on the header bar; drag the grip to resize.
    $("list-toggle").addEventListener("click", () => toggleList());
    initListResize();

    let qt;
    $("search-input").addEventListener("input", (e) => {
      clearTimeout(qt);
      qt = setTimeout(() => { S.query = e.target.value.trim().toLowerCase(); renderShowing(); renderCurrentView(true); }, 120);
    });

    $("filter-area").addEventListener("change", (e) => setAreaFilter(e.target.value));
    $("filter-status").addEventListener("change", (e) => { S.statusFilter = e.target.value; renderTop(); renderShowing(); renderCurrentView(true); });

    document.querySelectorAll('.stat-pill[role="button"]').forEach((p) => {
      const act = () => {
        const stat = p.dataset.stat;
        if (stat === "frontier") {
          const fas = [...frontierAreaSet()];
          // Pan to a live L1 planner's area first, else the first frontier area.
          const l1 = (S.snap.agents && S.snap.agents.l1) || [];
          const activeArea = (l1.find((a) => a.l1Active && fas.includes(a.area)) || {}).area;
          const target = activeArea || fas[0];
          if (target) { setAreaFilter(""); fas.forEach((a) => S.expanded.add(a)); renderCurrentView(true); panToNode("L1:" + target); }
        } else if (stat === "blocked") {
          setStatusFilter(S.statusFilter === "blocked" ? "" : "blocked");
        } else {
          setStatusFilter(stat);
        }
      };
      p.addEventListener("click", act);
      p.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); act(); } });
    });

    $("inspector-tabs").addEventListener("click", (e) => {
      const t = e.target.closest(".tab"); if (!t) return;
      S.inspTab = t.dataset.tab; activatePanel();
      // Fetch area nodes lazily the first time the "nodes" tab is shown.
      if (S.selectedKind === "l1" && S.inspTab === "nodes") fetchAreaNodes(S.selectedId.replace(/^L1:/, ""));
    });
    $("insp-pin").addEventListener("click", () => { if (S.selectedKind === "l2") togglePin(S.selectedId); });
    $("insp-close").addEventListener("click", () => select("none", null));
    $("inspector-scrim").addEventListener("click", () => select("none", null));
    initInspectorSheet();
    initResize();
    termInit();
    overlayInit();
    initGraphInteractions();
    if (window.ResizeObserver) {
      const ro = new ResizeObserver(() => { if (!S._userPanned) fitGraph(); });
      ro.observe($("view-graph"));
    }

    document.addEventListener("keydown", (e) => {
      if (e.key === "/" && document.activeElement !== $("search-input")) { e.preventDefault(); $("search-input").focus(); }
      else if (e.key === "Escape") {
        const onSearch = document.activeElement === $("search-input");
        if (onSearch && S.query) { $("search-input").value = ""; S.query = ""; renderShowing(); renderCurrentView(true); }
        else if (onSearch) { $("search-input").blur(); }
        else if (S.selectedKind !== "none") { select("none", null); } // keep dock height; terminal owns it
      }
    });

    // ?list=1 opens the task-list drawer on load.
    if (new URLSearchParams(location.search).get("list") === "1") S.listOpen = true;
    applyListDrawer();
    load(false);
    setInterval(() => { if (!document.hidden) load(false); }, POLL_MS);
    setInterval(tickAge, 1000);

    // Pause polling in backgrounded tabs; refresh immediately on return so a
    // re-shown dashboard is never stale.
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) { load(false); termTick(); overlayTick(); }
    });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
