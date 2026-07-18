/* glueRun-go orchestration console — client logic.
   Read-only. Renders durable orchestration state into a top/main/inspector
   console. Selection, pins, filters, and expansion live in JS state (never
   derived from the DOM) so the 10s auto-refresh never loses them. Views are
   re-rendered only when their inputs actually change (signature-gated), so a
   quiet snapshot produces zero rebuilds and zero scroll/selection loss. */

// ES module (0.6.0): loaded via main.js. Module scope replaces the old IIFE;
// the exported seams at the bottom are the contract the surface modules build
// on. Body indentation preserved from the IIFE to keep the diff reviewable.

import { bus } from "./core/bus.js";
import { startFeed } from "./core/sessions-feed.js";
import { apiFetch, isHistorical } from "./core/api.js";

  const POLL_MS = 10000;
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
    query: "",
    areaFilter: "",
    statusFilter: "",
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
    fileSubject: null,         // { title, path, content, language, size, mtime } for the "file" inspector kind
    roleCatalog: null,     // /api/roles (declared reference), fetched once
    roleInflight: false,
    lastSig: {},
    lastOkAt: 0,
    connState: "down",
  };

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
      const res = await apiFetch("/api/state" + (fresh ? "?fresh=1" : ""), { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      S.snap = await res.json();
      S.lastOkAt = Date.now();
      // A stale-served snapshot (server is recomputing in the background) is
      // shown, but flagged via the existing stale hint rather than as live.
      setConn(S.snap && S.snap.stale ? "stale" : "connected");
      seedSelection();
      renderAll();
      maybeRefreshOpenTask();
      fetchOverview(); // refresh the plan pill + overview panel (own cheap cached endpoint)
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

  function seedSelection() {
    // If a pin survives reloads but its task vanished, drop it gracefully.
    if (S.pinnedId && S.pinnedId.startsWith("TASK-")) {
      const exists = (S.snap.l2Tasks || []).some((t) => t.id === S.pinnedId);
      if (!exists) { S.pinnedId = null; if (!isHistorical()) localStorage.removeItem("gluerun.pinnedId"); }
    }
  }

  // ---- historical (archived plan) boot ----
  // In historical mode we never call /api/state (it would return LIVE data) and
  // never schedule the 10s poll. Instead we do a single one-shot boot: fetch the
  // immutable /api/timeline?plan= and synthesize a minimal S.snap so the Tasks
  // lens, showing-count, quick-filters, and header render the archived data. The
  // Plan lenses' own data layer (plan/data.js) fetches the archived dag+timeline
  // directly on mount, so this snapshot only needs the l2Tasks projection.
  function histState(status) {
    const s = String(status || "").toLowerCase();
    if (["integrated", "merged", "complete", "completed", "done"].includes(s)) return "integrated";
    if (["accepted", "awaiting"].includes(s)) return "awaiting";
    if (s === "blocked") return "blocked";
    if (["failed", "error"].includes(s)) return "failed";
    if (s === "stale") return "stale";
    if (["idle", "draft", "ready"].includes(s)) return "idle";
    return "active";
  }
  function taskLastEnd(t) {
    let m = null;
    for (const iv of (t.intervals || [])) { const e = iv.endedAt || iv.startedAt; if (e && (!m || e > m)) m = e; }
    return m;
  }
  async function historicalBoot() {
    let tl = null;
    try {
      const res = await apiFetch("/api/timeline", { cache: "no-store" });
      if (res.ok) tl = await res.json();
    } catch (e) { /* synthesize an empty snapshot if the timeline is unavailable */ }
    const l2Tasks = ((tl && tl.tasks) || []).map((t) => ({
      id: t.taskId, title: "", state: histState(t.status),
      area: t.area || "", workerBranch: t.branch || "",
      updatedAt: taskLastEnd(t) || (tl && tl.now) || null,
    }));
    const stateCounts = {};
    for (const t of l2Tasks) stateCounts[t.state] = (stateCounts[t.state] || 0) + 1;
    const activeAgents = l2Tasks.filter((t) => t.state !== "integrated" && t.state !== "idle").length;
    S.snap = {
      generatedAt: (tl && tl.now) || new Date().toISOString(),
      l2Tasks,
      summary: { stateCounts, activeAgents },
      agents: { l0: {}, l1: [], l2: [] },
      orchestration: { gates: {} },
      health: "archived",
      stop: { present: false },
    };
    S.lastOkAt = Date.now();
    setConn("connected");
    renderAll();   // the single "tick" that drives lenses + the deferred deep-link
  }

  // -------------------------------------------------------- filtering core ---
  function tasksFiltered() {
    const q = S.query;
    const out = [];
    // The Tasks lens can render before the first snapshot (mounted at boot).
    for (const t of (S.snap && S.snap.l2Tasks) || []) {
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
  // The slimmed header carries only the always-visible system signals: the
  // health flag + the hard-stop presence chip. Every stat pill moved to Home;
  // the actionable status filters moved into the Plan workbench header.
  function renderTop() {
    const d = S.snap;

    // Historical (archived) mode: the live health/stop signals don't apply — show a
    // neutral "archived" state (the Refresh button + conn dot are hidden via CSS).
    if (isHistorical()) {
      const hf = $("health-flag"); if (hf) hf.dataset.tone = "idle";
      const ht = $("health-text"); if (ht) ht.textContent = "archived";
      const stopChip = $("stop-chip");
      if (stopChip) {
        stopChip.dataset.present = "false"; stopChip.dataset.tone = "idle";
        const st = $("stop-text"); if (st) st.textContent = "archived";
      }
      renderPlanFilters();
      return;
    }

    // health flag
    const healthTone = d.health === "healthy" ? "success" : d.health === "blocker" ? "error" : "warn";
    const hf = $("health-flag"); if (hf) hf.dataset.tone = healthTone;
    const ht = $("health-text"); if (ht) ht.textContent = d.health || "—";

    // stop chip — amber when present (an intentional hold, not a fault)
    const stopPresent = !!(d.stop && d.stop.present);
    const stopChip = $("stop-chip");
    if (stopChip) {
      stopChip.dataset.present = String(stopPresent);
      stopChip.dataset.tone = stopPresent ? "warn" : "idle";
      const st = $("stop-text"); if (st) st.textContent = stopPresent ? "stop present" : "stop clear";
    }

    renderPlanFilters();
  }

  // Plan workbench header: the three status-filter pills (live counts + pressed
  // state) and the slim gates X/Y readout that opens the overview inspector.
  function renderPlanFilters() {
    const d = S.snap; if (!d) return;
    const sc = (d.summary && d.summary.stateCounts) || {};
    const counts = { active: sc.active || 0, awaiting: sc.awaiting || 0, blocked: (sc.blocked || 0) + (sc.failed || 0) };
    for (const stat of ["active", "awaiting", "blocked"]) {
      const c = $("qf-" + stat); if (c) c.textContent = counts[stat];
      const pill = document.querySelector(`.qf-pill[data-qf="${stat}"]`);
      if (pill) pill.setAttribute("aria-pressed", String(S.statusFilter === stat || (stat === "blocked" && S.statusFilter === "failed")));
    }
    // In historical mode the archived plan's gates are painted by core/plans.js
    // from the /api/plans registry entry — leave the readout alone here.
    if (!isHistorical()) {
      const g = (d.orchestration && d.orchestration.gates) || {};
      const val = $("plan-gates-val");
      if (val) val.textContent = `${g.passed != null ? g.passed : "?"}/${g.total != null ? g.total : "?"}`;
    }
  }

  const shortRun = (r) => String(r || "").replace(/^ORIGIN-|^RUN-/, "").slice(0, 16);

  // =========================================================== RENDER ALL ====
  function renderAll() {
    if (!S.snap) return;
    renderTop();
    populateAreaFilter();
    renderShowing();
    refreshInspectorHeaderFromSnap();
    tickAge();
    // Plan lenses refresh off the same snapshot (signature-gated, own scroll/
    // selection preservation). The dispatcher is composed in main.js and also
    // drives the router's deferred deep-link resolution.
    if (bus.onSnapshot) bus.onSnapshot();
  }

  // Filter/search changes repaint the showing-count and ask the mounted Plan lens
  // to refresh (its own signature gate decides whether to rebuild).
  function planRefresh() { if (bus.onSnapshot) bus.onSnapshot(); }

  // Selection/pin markers are applied over prebuilt lens DOM — never a rebuild.
  // Any lens row/bar carrying data-task-id + data-selected/data-pinned updates.
  function applyMarkers() {
    document.querySelectorAll("[data-task-id][data-selected]").forEach((el) => {
      el.dataset.selected = String(el.dataset.taskId === S.selectedId);
    });
    document.querySelectorAll("[data-task-id][data-pinned]").forEach((el) => {
      el.dataset.pinned = String(el.dataset.taskId === S.pinnedId);
    });
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
  }

  function tickAge() {
    if (!S.lastOkAt) { $("refresh-age").textContent = "—"; return; }
    const s = Math.round((Date.now() - S.lastOkAt) / 1000);
    $("refresh-age").textContent = s < 1 ? "now" : s + "s ago";
    if (s > POLL_MS / 1000 + 8 && S.connState === "connected") setConn("stale");
  }

  // ========================================================= INSPECTOR ======
  function select(kind, id) {
    // Plan-surface node selection is owned by the workbench aside (360px
    // drilldown), NOT the bottom sheet — but only when nothing is already open in
    // the sheet (a node chip clicked inside an open task inspector still opens the
    // node in the sheet, replacing the task view, as before).
    if (kind === "node" && bus.onNodeSelect && bus.planVisible && bus.planVisible() && S.selectedKind === "none") {
      bus.onNodeSelect(id);
      return;
    }
    S.selectedKind = kind; S.selectedId = id;
    // Open/close the inspector bottom-sheet modal (scrim + slide-up sheet).
    const insp = $("inspector");
    const open = kind !== "none";
    insp.dataset.subjectKind = kind;
    insp.dataset.taskId = kind === "l2" ? id : "";
    insp.setAttribute("aria-hidden", String(!open));
    insp.style.transform = ""; // clear any drag offset so CSS open/close takes over
    $("inspector-scrim").dataset.open = String(open);
    // The router owns the URL hash; fall back to a legacy write if unwired (dev).
    if (bus.writeRoute) {
      if (kind === "l2") bus.writeRoute("task", id, S.inspTab);
      else if (kind === "node") bus.writeRoute("node", id, null);
      else if (kind === "overview") bus.writeRoute("overview", "plan", null);
    } else {
      if (kind === "l2") { try { history.replaceState(null, "", "#" + id); } catch (e) {} }
      else if (kind === "node") { try { history.replaceState(null, "", "#NODE:" + id); } catch (e) {} }
      else if (kind === "overview") { try { history.replaceState(null, "", "#PLAN"); } catch (e) {} }
    }
    applyMarkers();
    renderInspector();
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
    // "open console" is an L2-task-with-runId affordance only; renderTaskDetail
    // re-shows it after this. Hide it for every other subject.
    const cb = $("insp-console"); if (cb) { cb.hidden = true; cb.dataset.runid = ""; }
  }

  function renderInspector() {
    const kind = S.selectedKind;
    // When nothing is selected the inspector slides out (CSS, data-subject-kind=none);
    // no empty-state element to toggle.
    if (kind === "none") { $("inspector-tabs").innerHTML = ""; setRawCluster(null); return; }
    setRawCluster(null);   // specific renderers (l2, node, file) repopulate as needed
    if (kind === "l0") return renderInspectorL0();
    if (kind === "l1") return renderInspectorL1();
    if (kind === "l2") return renderInspectorL2();
    if (kind === "node") return renderInspectorNode();
    if (kind === "overview") return renderInspectorOverview();
    if (kind === "file") return renderInspectorFile();
  }

  // Populate the header's {}-button cluster (raw/prompt "view source" affordances).
  // buttons: [{label, root, name, title}] — cleared for kinds that own none.
  function setRawCluster(buttons) {
    const host = $("insp-raw-cluster");
    if (!host) return;
    host.innerHTML = (buttons || []).map((b) =>
      `<button class="insp-raw-btn" data-raw-root="${escAttr(b.root)}" data-raw-name="${escAttr(b.name)}" data-raw-title="${escAttr(b.title || b.label)}" title="view source · ${escAttr(b.title || b.label)}">{ }<span class="irb-label">${esc(b.label)}</span></button>`
    ).join("");
  }

  const fmtBytes = (n) => n == null ? "" : (n < 1024 ? n + " B" : n < 1048576 ? (n / 1024).toFixed(1) + " KB" : (n / 1048576).toFixed(1) + " MB");

  // ---- generic file-view inspector (shared foundation for raw + prompt views) ----
  function renderInspectorFile() {
    const fs = S.fileSubject || {};
    setRawCluster(null);
    setInspHeader(fs.title || "file", "", "", null, "");
    $("insp-sub").innerHTML =
      `<span class="mono">${esc(fs.path || "")}</span>` +
      (fs.size != null ? `<span>${esc(fmtBytes(fs.size))}</span>` : "") +
      (fs.mtime ? `<span>${esc(relTime(new Date(fs.mtime * 1000).toISOString()))} ago</span>` : "");
    setTabs(["source"]);
    let body = fs.content || "";
    if (fs.language === "json") { try { body = JSON.stringify(JSON.parse(body), null, 2); } catch (e) { /* show verbatim */ } }
    showPanels(`<div class="tab-panel" data-tab="source">
      <div class="insp-file-head"><button class="copy-btn" data-copy="${escAttr(fs.content || "")}">${icon("i-copy")} copy</button></div>
      <pre class="insp-file mono">${esc(body)}</pre></div>`);
  }

  // Open a resolved file payload in the inspector file-view.
  function viewFile(fs) { S.fileSubject = fs; select("file", (fs && (fs.path || fs.title)) || "file"); }

  // Fetch a raw record (/api/raw/<root>/<name>) and show it in the file-view.
  async function viewRaw(root, name, title) {
    try {
      const res = await apiFetch("/api/raw/" + encodeURIComponent(root) + "/" + encodeURIComponent(name), { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      const r = await res.json();
      viewFile({ title: title || r.name || name, path: r.path, content: r.content, language: String(name).endsWith(".json") ? "json" : "md", size: r.size, mtime: r.mtime });
    } catch (e) { toast("could not load " + name); }
  }

  // Fetch the EXACT rendered prompt for one run (session file reader) and show it
  // in the file-view — the real prompt that ran, not just the template.
  async function viewSessionPrompt(sessionId, name, label) {
    try {
      const res = await apiFetch("/api/session/" + encodeURIComponent(sessionId) + "?file=" + encodeURIComponent(name) + "&raw=1&limit=5000", { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      const r = await res.json();
      const content = (r.lines || []).map((l) => typeof l === "string" ? l : (l.text != null ? l.text : (l.raw || ""))).join("\n");
      viewFile({ title: "prompt · " + (label || name), path: name, content, language: "md", size: r.size });
    } catch (e) { toast("could not load prompt"); }
  }

  // Fetch a role prompt template (/api/prompt/<name>) and show it in the file-view.
  async function viewPrompt(name) {
    try {
      const res = await apiFetch("/api/prompt/" + encodeURIComponent(name), { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      const r = await res.json();
      viewFile({ title: name, path: r.path, content: r.content, language: "md", size: r.size, mtime: r.mtime });
    } catch (e) { toast("could not load " + name); }
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
      const r = await apiFetch("/api/roles");
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
      const res = await apiFetch("/api/task/" + encodeURIComponent(id), { cache: "no-store" });
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
      const res = await apiFetch("/api/node/" + encodeURIComponent(id), { cache: "no-store" });
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
      const res = await apiFetch("/api/area/" + encodeURIComponent(area) + "/nodes", { cache: "no-store" });
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
      const res = await apiFetch("/api/overview", { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      S.overview = await res.json();
      if (S.selectedKind === "overview") renderInspectorOverview();
    } catch (e) {
      /* pill keeps its last value; overview is optional chrome */
    } finally {
      S.overviewInflight = false;
    }
  }

  function renderTaskDetail(d) {
    setInspHeader(d.id, d.title, `${d.area} · ${labelOf(d.state)}`, d.state, shortBranch(d.workerBranch));
    // Raw "view source" cluster: the task's durable primitives (E3).
    const rawBtns = [
      { label: "task", root: "task", name: d.id + ".md", title: "task " + d.id },
      { label: "lease", root: "lease", name: d.id + ".json", title: "lease " + d.id },
      { label: "dispatch", root: "dispatch", name: d.id + ".json", title: "dispatch " + d.id },
    ];
    if (d.gates && d.gates.length) rawBtns.push({ label: "gate", root: "gate", name: d.gates[0].node + ".gate-result.json", title: "gate " + d.gates[0].node });
    setRawCluster(rawBtns);
    // Task detail carries a runId → surface an "open console" jump to the Consoles
    // surface (pinned + soloed on that run).
    const cb = $("insp-console");
    if (cb) { if (d.runId) { cb.hidden = false; cb.dataset.runid = d.runId; } else { cb.hidden = true; cb.dataset.runid = ""; } }

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
    setRawCluster([
      { label: "gate", root: "gate", name: d.nodeId + ".gate-result.json", title: "gate " + d.nodeId },
      { label: "dag", root: "dag", name: "dag.v0.json", title: "dag.v0.json" },
    ]);
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
    const copyBtn = e.target.closest(".copy-btn");
    if (copyBtn) { e.stopPropagation(); copy(copyBtn.dataset.copy); return; }

    const rawBtn = e.target.closest(".insp-raw-btn, [data-raw-root]");
    if (rawBtn && rawBtn.dataset.rawRoot) { e.stopPropagation(); viewRaw(rawBtn.dataset.rawRoot, rawBtn.dataset.rawName, rawBtn.dataset.rawTitle); return; }

    const pinGlyph = e.target.closest(".pin-glyph");
    if (pinGlyph) { e.stopPropagation(); const node = pinGlyph.closest("[data-task-id]"); if (node) togglePin(node.dataset.taskId); return; }

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

  // Deep link: #<id> or #<id>:<tab> (legacy grammar). Retained for compatibility;
  // the hash router (core/router.js) now owns deep-link resolution and calls the
  // same navigateToTask/select seams, so this is a fallback for standalone use.
  function applyDeepLink() {
    const h = decodeURIComponent((location.hash || "").replace(/^#/, ""));
    if (!h) return;
    const ci = h.lastIndexOf(":");
    let id = h, tab = "";
    const prefixed = h.startsWith("L1:") || h.startsWith("NODE:");
    if (ci > 0 && !prefixed) { id = h.slice(0, ci); tab = h.slice(ci + 1); }
    else if (prefixed && h.indexOf(":", h.indexOf(":") + 1) > 0) {
      const j = h.indexOf(":", h.indexOf(":") + 1); id = h.slice(0, j); tab = h.slice(j + 1);
    }
    if (tab) S.inspTab = tab === "events" ? "timeline" : tab;
    if (/^TASK-\d+$/.test(id)) { if ((S.snap.l2Tasks || []).some((t) => t.id === id)) navigateToTask(id); }
    else if (id === "L0") select("l0", "L0");
    else if (id === "PLAN") select("overview", "plan");
    else if (/^NODE:/.test(id)) select("node", id.slice(5));
    else if (/^L1:/.test(id)) select("l1", id);
  }

  // Open a task in the inspector bottom sheet, and (on the Plan surface) switch to
  // the Tasks lens and scroll/ring its row — the lens handles the scroll.
  function navigateToTask(id) {
    select("l2", id);
    if (bus.onTaskNavigate) bus.onTaskNavigate(id);
  }

  function togglePin(id) {
    S.pinnedId = S.pinnedId === id ? null : id;
    // Read-only in historical mode — keep the in-session pin marker but never persist.
    if (!isHistorical()) {
      if (S.pinnedId) localStorage.setItem("gluerun.pinnedId", S.pinnedId);
      else localStorage.removeItem("gluerun.pinnedId");
    }
    applyMarkers();
    if (S.selectedId) $("insp-pin").setAttribute("aria-pressed", String(S.pinnedId === S.selectedId));
  }

  function setAreaFilter(area) {
    S.areaFilter = area;
    $("filter-area").value = area;
    renderShowing();
    planRefresh();
  }

  function setStatusFilter(st) {
    S.statusFilter = S.statusFilter === st ? "" : st;
    $("filter-status").value = S.statusFilter;
    renderTop();
    renderShowing();
    planRefresh();
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
      const res = await apiFetch("/api/events?" + p.toString(), { cache: "no-store" });
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

  // The pulse + feed now live on the Home surface (#home-activity-*). Both
  // renderers no-op when their host is absent (any non-Home surface), while the
  // poll keeps filling O.rows so a Home visit paints instantly.
  function renderOverlayPulse() {
    const pulse = $("home-activity-pulse");
    if (!pulse) return;
    const p = resolvePulse();
    pulse.dataset.state = p.state;
    const dot = pulse.querySelector(".tone-dot"); if (dot) dot.dataset.tone = p.tone;
    const txt = $("home-activity-pulse-text"); if (txt) txt.textContent = p.text;
    const rate = $("home-activity-rate"); if (rate) rate.textContent = p.rate ? p.rate + "/min" : "";
  }

  function renderOverlay() {
    renderOverlayPulse();   // cheap; refresh every tick so the pulse stays live
    const feed = $("home-activity-feed");
    if (!feed) return;
    const sig = JSON.stringify(O.rows.slice(0, 60).map((r) => r._sig));
    if (sig === O.feedSig) return;       // signature-gate the feed DOM rebuild
    O.feedSig = sig;
    feed.innerHTML = O.rows.map((r) => {
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

  // Force a repaint of the relocated feed (Home calls this when it mounts so the
  // buffered rows render without waiting for the next 2s poll).
  function renderActivityFeed() { O.feedSig = null; renderOverlay(); }

  async function overlayTick() {
    if (document.hidden) return;
    await overlayFetch();
  }

  // Historical mode: the archived events.ndjson is immutable, so one bounded read
  // of its tail (no cursor loop, no interval) fills the feed once.
  async function overlayFetchBounded() {
    if (O.inflight) return;
    O.inflight = true;
    try {
      const res = await apiFetch("/api/events?cursor=0&limit=200", { cache: "no-store" });
      if (!res.ok) throw new Error("http " + res.status);
      const data = await res.json();
      O.rows = []; O.seen.clear();
      appendOverlayRows(data.rows || []);
      renderOverlay();
    } catch (e) { /* leave the feed empty on a miss */ }
    finally { O.inflight = false; }
  }

  function overlayInit() {
    if (O.started) return;
    O.started = true;
    // Clicking a row is the entry ramp into the provenance inspector. Delegated
    // on document so it survives the feed being (re)mounted by the Home surface.
    document.addEventListener("click", (e) => {
      const row = e.target.closest(".ov-row"); if (!row) return;
      if (!S.snap) return; // overlay polls independently; ignore clicks until the graph snapshot is in
      const task = row.dataset.task, node = row.dataset.node, area = row.dataset.area;
      if (task && /^TASK-\d+$/.test(task)) { navigateToTask(task); return; }
      if (node) { select("node", node); return; }
      if (area) { select("l1", "L1:" + area); return; }
      select("l0", "L0");
    });
    if (isHistorical()) { overlayFetchBounded(); return; }   // one-shot, no 2s poll
    overlayTick();
    setInterval(overlayTick, OVERLAY_POLL_MS);
  }

  // ----------------------------------------------------------------- init ---
  function init() {
    document.addEventListener("click", onClick);

    $("btn-refresh").addEventListener("click", () => load(true));
    const gatesReadout = $("plan-gates-readout");
    if (gatesReadout) gatesReadout.addEventListener("click", () => select("overview", "plan"));

    let qt;
    $("search-input").addEventListener("input", (e) => {
      clearTimeout(qt);
      qt = setTimeout(() => { S.query = e.target.value.trim().toLowerCase(); renderShowing(); planRefresh(); }, 120);
    });

    $("filter-area").addEventListener("change", (e) => setAreaFilter(e.target.value));
    $("filter-status").addEventListener("change", (e) => { S.statusFilter = e.target.value; renderTop(); renderShowing(); planRefresh(); });

    // Plan workbench quick status-filter pills (relocated from the header strip).
    const qf = $("plan-quickfilters");
    if (qf) qf.addEventListener("click", (e) => {
      const b = e.target.closest(".qf-pill"); if (!b) return;
      const stat = b.dataset.qf;
      if (stat === "blocked") setStatusFilter(S.statusFilter === "blocked" ? "" : "blocked");
      else setStatusFilter(stat);
    });

    $("inspector-tabs").addEventListener("click", (e) => {
      const t = e.target.closest(".tab"); if (!t) return;
      S.inspTab = t.dataset.tab; activatePanel();
      // Fetch area nodes lazily the first time the "nodes" tab is shown.
      if (S.selectedKind === "l1" && S.inspTab === "nodes") fetchAreaNodes(S.selectedId.replace(/^L1:/, ""));
    });
    $("insp-pin").addEventListener("click", () => { if (S.selectedKind === "l2") togglePin(S.selectedId); });
    $("insp-console").addEventListener("click", () => { const r = $("insp-console").dataset.runid; if (r) location.hash = "#consoles/" + r; });
    $("insp-close").addEventListener("click", () => select("none", null));
    $("inspector-scrim").addEventListener("click", () => select("none", null));
    initInspectorSheet();
    overlayInit();
    startFeed();   // start the single /api/sessions poller (Consoles/Agents subscribers)

    document.addEventListener("keydown", (e) => {
      if (e.key === "/" && document.activeElement !== $("search-input")) { e.preventDefault(); $("search-input").focus(); }
      else if (e.key === "Escape") {
        const onSearch = document.activeElement === $("search-input");
        if (onSearch && S.query) { $("search-input").value = ""; S.query = ""; renderShowing(); planRefresh(); }
        else if (onSearch) { $("search-input").blur(); }
        else if (S.selectedKind !== "none") { select("none", null); }
      }
    });

    if (isHistorical()) {
      // Archived plan: one-shot synthetic snapshot, no /api/state, no live timers.
      historicalBoot();
    } else {
      load(false);
      setInterval(() => { if (!document.hidden) load(false); }, POLL_MS);
      setInterval(tickAge, 1000);
      // Pause polling in backgrounded tabs; refresh immediately on return so a
      // re-shown dashboard is never stale.
      document.addEventListener("visibilitychange", () => {
        if (!document.hidden) { load(false); overlayTick(); }
      });
    }
  }

  function start() {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
    else init();
  }

  export {
    // state + vocab
    S, O, POLL_MS, STATE_TONE, STATE_LABEL, STATE_ORDER, toneOf, labelOf, gateTone,
    // dom + format helpers
    $, esc, escAttr, icon, relTime, toast, kvGrid, statusChip, highlight, shortBranch,
    // filtering + selection + navigation seams (used by the plan surface + router)
    tasksFiltered, sortExceptionsFirst, load, setConn, select, navigateToTask,
    setAreaFilter, applyDeepLink, gateBlock,
    // developer primitives — inspector file-view + raw/prompt helpers (E)
    viewFile, viewRaw, viewPrompt, viewSessionPrompt,
    // activity feed (relocated to Home; Home remounts + repaints it)
    overlayTick, renderActivityFeed,
    // entry
    start, init,
  };
