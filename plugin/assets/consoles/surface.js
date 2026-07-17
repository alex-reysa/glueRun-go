/* consoles/surface.js — the Consoles surface (0.6.0 console redesign).

   Left: a persistent, full-height L0 pane (ink header band + two stacked streams —
   origin events.ndjson on top, the supervisor autonomate log below, collapsible).
   Right: a dynamic region of live-session panes, a global toggle bar, and a recent
   rail of finished/evicted sessions.

   Streaming reuses core/term-core.js (byte-identical to the dock); the session list
   comes from the shared core/sessions-feed.js poller (one poller for the whole app).
   A single 2s scheduler polls the visible streams under a MAX_INFLIGHT budget with
   round-robin carryover so no pane starves and a hidden surface polls nothing.

   C1 = skeleton (L0 + dynamic panes + global bar + idle card + dock hide).
   C2 = lifecycle (pop-in, linger, recent rail, overflow queue, pins, solo, deep link). */

import { S, esc, escAttr, icon, toneOf, relTime, viewSessionPrompt } from "../app.js";
import { makePaneState, fetchPaneLines, scrollPaneToBottom, resetPane } from "../core/term-core.js";
import { subscribe as subscribeSessions, feedState, pokeFeed } from "../core/sessions-feed.js";
import { writeRoute } from "../core/router.js";

const TICK_MS = 2000;
const MAX_INFLIGHT = 4;   // line-fetches per tick
const DYN_MAX = 4;        // visible dynamic panes
const RAIL_MAX = 8;       // recent-rail chips
const LINGER_MS = 15000;  // finished pane lingers before collapsing to the rail
const LINGER_FAIL_MS = 45000;

// priority for overflow eviction: planner > worker > integration > audit > decider
const PRIORITY = { planner: 0, worker: 1, "l2-developer": 1, "recovery-worker": 1, integration: 2, "integration-worker": 2, audit: 3, auditor: 3, reviewer: 3, decider: 4, "session-decider": 4 };

const shortRun = (r) => String(r || "").replace(/^ORIGIN-|^RUN-/, "").slice(0, 16);

const CO = {
  started: false,
  visible: false,
  sessions: [],
  byId: new Map(),
  generatedAt: null,
  auto: { mode: "origin", sessionIds: ["origin"] },
  // L0 stacked streams
  l0: { eventsPane: null, supPane: null, supFile: null, supFails: 0, supUnavailable: false },
  supCollapsed: localStorage.getItem("gluerun.co.sup") === "1",
  // dynamic region
  panes: new Map(),        // id -> { el, head, body, pane, live, sess, pinned, soloEl, linger, lingerUntil, polling, finished }
  order: [],               // current visible pane ids (in DOM order)
  rail: [],                // recent finished/evicted session snapshots (newest first)
  queue: [],               // overflow queue-chip session ids
  // global toggles
  autoOn: localStorage.getItem("gluerun.co.auto") !== "0",
  follow: localStorage.getItem("gluerun.co.follow") !== "0",
  raw: localStorage.getItem("gluerun.co.raw") === "1",
  soloId: null,            // soloed pane id (or "origin" for the L0 pane), null = off
  pins: safeParse(localStorage.getItem("gluerun.co.pins"), []),
  tick: null,
  rr: 0,
};

function safeParse(s, fb) { try { return JSON.parse(s) || fb; } catch { return fb; } }
function persist() {
  localStorage.setItem("gluerun.co.auto", CO.autoOn ? "1" : "0");
  localStorage.setItem("gluerun.co.follow", CO.follow ? "1" : "0");
  localStorage.setItem("gluerun.co.raw", CO.raw ? "1" : "0");
  localStorage.setItem("gluerun.co.pins", JSON.stringify(CO.pins));
}

// ---------------------------------------------------------------- role badge --
// PL planner · DV developer · AU auditor · IG integration · DC decider · RC recovery
function roleBadge(s) {
  const role = String(s.role || s.kind || "");
  if (s.kind === "planner" || role === "planner") return { txt: "PL", layer: "l1" };
  if (s.kind === "integration" || role === "integration-worker") return { txt: "IG", layer: "l1" };
  if (s.kind === "audit" || role === "auditor" || role === "reviewer") return { txt: "AU", layer: "l1" };
  if (role === "recovery-worker") return { txt: "RC", layer: "l2" };
  if (role === "session-decider" || role === "decider") return { txt: "DC", layer: "l2" };
  return { txt: "DV", layer: s.layer === "L1" ? "l1" : "l2" };  // l2-developer / worker
}
// dot tone: green live, blue in-progress, amber awaiting/stale, red failed/blocked
function paneDotTone(s) {
  if (s.live) return "success";
  const st = String(s.state || "");
  if (st === "failed" || st === "blocked") return "error";
  if (st === "awaiting" || st === "stale") return "warn";
  if (st === "active") return "active";
  return toneOf(st);
}
const GATE_PHASES = new Set(["gate", "audit", "gate-done"]);
function ident(s) { return s.taskId || s.node || s.area || (s.kind === "origin" ? "origin" : shortRun(s.runId) || s.id); }
// The rendered prompt this run actually used (session.logFiles kind:"prompt").
function promptFile(s) { const lf = ((s && s.logFiles) || []).find((f) => f.kind === "prompt"); return lf ? lf.name : null; }

// ---------------------------------------------------------------- L0 header ---
function originSession() { return CO.byId.get("origin") || CO.sessions.find((s) => s.kind === "origin") || null; }

function l0Tone(o) {
  if (!o) return "idle";
  if (o.stop && o.state !== "active") return "error";
  if (o.state === "active") return "success";
  if (o.state === "stale") return "warn";
  return "idle";
}

function renderL0Header() {
  const o = originSession();
  const host = document.getElementById("co-l0-head");
  if (!host) return;
  const tone = l0Tone(o);
  const age = o && o.updatedAt ? relTime(o.updatedAt, CO.generatedAt) : "—";
  host.innerHTML =
    `<span class="co-l0-avatar">OR</span>
     <div class="co-l0-head-main">
       <span class="co-eyebrow">L0 · SUPERVISOR</span>
       <span class="co-l0-state"><span class="tone-dot" data-tone="${tone}"></span><span>${esc(o ? (o.state || "idle") : "idle")}</span></span>
     </div>
     <span class="co-l0-age mono">${esc(age)}</span>`;
}

// ------------------------------------------------------------ dynamic panes ---
// live, non-origin sessions; L1 sessions before L2, newest-first; capped at DYN_MAX
function liveDynamicSessions() {
  const live = CO.sessions.filter((s) => s.live && s.id !== "origin");
  live.sort((a, b) => {
    const la = a.layer === "L1" ? 0 : 1, lb = b.layer === "L1" ? 0 : 1;
    if (la !== lb) return la - lb;
    return String(b.updatedAt || "").localeCompare(String(a.updatedAt || ""));
  });
  return live;
}

// Which ids should have panes right now (live + pinned), honoring solo.
function targetPaneIds() {
  if (CO.soloId && CO.soloId !== "origin") return [CO.soloId];
  const live = liveDynamicSessions().map((s) => s.id);
  const pinned = CO.pins.filter((id) => id !== "origin");
  const ids = [];
  for (const id of pinned) if (!ids.includes(id)) ids.push(id);          // pins first, never evicted
  for (const id of live) if (!ids.includes(id)) ids.push(id);
  // overflow beyond DYN_MAX → queue chips (lowest priority, unpinned)
  if (ids.length > DYN_MAX) {
    const keep = ids.slice(0, DYN_MAX);
    CO.queue = ids.slice(DYN_MAX).filter((id) => !CO.pins.includes(id));
    return keep;
  }
  CO.queue = [];
  return ids;
}

function createDynPane(id) {
  const s = CO.byId.get(id) || { id, role: "session", kind: "session", state: "idle" };
  const el = document.createElement("div");
  el.className = "co-pane co-entering";
  el.dataset.id = id;
  el.setAttribute("role", "log");
  el.setAttribute("aria-live", "off");
  el.innerHTML = `<div class="co-pane-head"></div><div class="co-pane-body"><div class="term-pane-loading">connecting…</div></div>`;
  const head = el.querySelector(".co-pane-head");
  const body = el.querySelector(".co-pane-body");
  const pane = makePaneState(el, body, CO.raw);
  body.addEventListener("scroll", () => {
    pane.atBottom = body.scrollTop + body.clientHeight >= body.scrollHeight - 6;
  });
  requestAnimationFrame(() => el.classList.remove("co-entering"));
  const rec = { el, head, body, pane, live: !!s.live, sess: s, pinned: CO.pins.includes(id), polling: true, finished: false, linger: null };
  return rec;
}

function paneClasses(rec) {
  const s = rec.sess;
  rec.el.classList.toggle("co-l1", s.layer === "L1");   // L1 spans full width
  rec.el.classList.toggle("co-pinned", rec.pinned);
  rec.el.classList.toggle("co-dim", rec.finished);
}

function renderPaneHead(rec) {
  const s = rec.sess;
  const b = roleBadge(s);
  const dot = paneDotTone(s);
  const phase = s.phase ? `<span class="co-phase${GATE_PHASES.has(s.phase) ? " co-phase-gate" : ""}">${esc(s.phase)}</span>` : "";
  const model = s.model ? `<span class="co-model mono">${esc(s.model)}${s.effort ? " · " + esc(s.effort) : ""}</span>` : "";
  const age = relTime(s.updatedAt, CO.generatedAt);
  const pf = promptFile(s);
  const promptChip = pf ? `<button class="co-prompt-chip" data-co-prompt="${escAttr(rec.el.dataset.id)}" data-co-prompt-file="${escAttr(pf)}" title="view the rendered prompt for this run">${icon("i-file")}prompt</button>` : "";
  rec.head.innerHTML =
    `<span class="co-badge" data-layer="${b.layer}">${esc(b.txt)}<span class="tone-dot" data-tone="${dot}"></span></span>
     <span class="co-ident mono">${esc(ident(s))}</span>
     ${phase}${model}${promptChip}
     <span class="co-age mono">${esc(age)}</span>
     <span class="co-pane-ctls">
       <button class="co-ctl" data-co-pin="${escAttr(rec.el.dataset.id)}" aria-pressed="${rec.pinned}" title="Pin pane">${icon("i-pin")}</button>
       <button class="co-ctl" data-co-raw="${escAttr(rec.el.dataset.id)}" aria-pressed="${rec.pane.raw}" title="Raw log lines">${icon("i-file")}</button>
       <button class="co-ctl" data-co-solo="${escAttr(rec.el.dataset.id)}" title="Expand (solo)">${icon("i-expand")}</button>
     </span>`;
}

// finished/failed terminal-state band (linger)
function renderLingerBand(rec) {
  let band = rec.el.querySelector(".co-term-band");
  if (!rec.finished) { if (band) band.remove(); return; }
  const s = rec.sess;
  const fail = s.state === "failed" || s.state === "blocked";
  const label = fail ? (s.state) : ("finished" + (s.exitCode != null ? " · exit " + s.exitCode : ""));
  if (!band) {
    band = document.createElement("div");
    band.className = "co-term-band";
    rec.el.insertBefore(band, rec.body);
  }
  band.dataset.tone = fail ? "error" : "success";
  band.innerHTML = `<span class="tone-dot" data-tone="${fail ? "error" : "success"}"></span><span>${esc(label)}</span>`;
}

function reconcileDynPanes() {
  const host = document.getElementById("co-dyn-grid");
  if (!host) return;
  const ids = targetPaneIds();
  CO.order = ids;

  // idle empty state when there is nothing live/pinned to show
  const idleCard = document.getElementById("co-idle");
  if (idleCard) {
    if (!ids.length && CO.panes.size === 0) {
      idleCard.hidden = false;
      const newest = CO.sessions.filter((s) => s.id !== "origin").sort((a, b) => String(b.updatedAt || "").localeCompare(String(a.updatedAt || "")))[0];
      const when = newest ? relTime(newest.updatedAt, CO.generatedAt) : "—";
      idleCard.innerHTML = `<div class="co-idle-inner">${icon("i-terminal")}<div class="co-idle-title">no live sessions</div><div class="co-idle-sub">last activity ${esc(when)} ago</div></div>`;
    } else {
      idleCard.hidden = true;
    }
  }

  // Lifecycle: a pane that leaves the target set (its session flipped not-live and
  // isn't pinned) does NOT vanish — it lingers (dimmed, terminal-state band, polling
  // stopped) for LINGER_MS (45s if it failed/blocked) then collapses into the rail.
  // While soloed we keep every pane (the non-soloed ones are hidden by CSS) so exiting
  // solo restores them without a linger storm.
  if (!CO.soloId) {
    for (const [id, rec] of [...CO.panes]) {
      rec.pinned = CO.pins.includes(id);        // refresh against current pins (may have just been unpinned)
      if (ids.includes(id)) { if (rec.linger) { clearTimeout(rec.linger); rec.linger = null; rec.finished = false; } continue; }
      if (rec.linger || rec.pinned) continue;   // already lingering / pinned stays
      paneClasses(rec);
      startLinger(rec);
    }
  }
  // create/update targeted panes
  for (const id of ids) {
    let rec = CO.panes.get(id);
    const s = CO.byId.get(id) || (rec && rec.sess) || { id, role: "session", kind: "session", state: "idle" };
    if (!rec) { rec = createDynPane(id); CO.panes.set(id, rec); host.appendChild(rec.el); }
    rec.sess = s;
    rec.pinned = CO.pins.includes(id);
    // a pinned/soloed historical pane that isn't live stops polling once loaded
    rec.polling = s.live || !rec.pane.loaded || rec.pinned && !rec.pane.loaded;
    if (s.live) { rec.finished = false; if (rec.linger) { clearTimeout(rec.linger); rec.linger = null; } }
    paneClasses(rec);
    renderPaneHead(rec);
    renderLingerBand(rec);
  }
  // ensure DOM order matches ids (idle card stays last)
  ids.forEach((id, i) => {
    const rec = CO.panes.get(id); if (!rec) return;
    if (host.children[i] !== rec.el) host.insertBefore(rec.el, host.children[i] || null);
  });
  renderRail();
  renderSolo();
}

// Begin the linger phase for a pane whose session just finished/left the list.
function startLinger(rec) {
  if (rec.linger) return;
  const s = rec.sess;
  const fail = s.state === "failed" || s.state === "blocked";
  rec.finished = true;
  rec.polling = false;
  paneClasses(rec);
  renderPaneHead(rec);
  renderLingerBand(rec);
  rec.linger = setTimeout(() => collapseToRail(rec), fail ? LINGER_FAIL_MS : LINGER_MS);
}

// After the linger timeout, collapse the pane into the recent rail (the rail is
// pulled from the sessions feed, so the finished session already shows there).
function collapseToRail(rec) {
  if (rec.pinned) { clearTimeout(rec.linger); rec.linger = null; rec.finished = false; paneClasses(rec); renderLingerBand(rec); return; }
  const id = rec.el.dataset.id;
  clearTimeout(rec.linger); rec.linger = null;
  rec.el.remove();
  CO.panes.delete(id);
  if (CO.visible) reconcileDynPanes();
}

// ------------------------------------------------------------- global bar -----
function renderBar() {
  const set = (n, on) => { const b = document.querySelector('.co-tgl[data-co-tgl="' + n + '"]'); if (b) b.setAttribute("aria-pressed", String(on)); };
  set("auto", CO.autoOn); set("pin", !CO.autoOn); set("follow", CO.follow); set("raw", CO.raw); set("solo", !!CO.soloId);
}

// ------------------------------------------------------------- recent rail ----
function renderRail() {
  const host = document.getElementById("co-rail-chips");
  if (!host) return;
  // pre-populate from recent finished sessions on an idle repo
  const recent = CO.sessions
    .filter((s) => s.id !== "origin" && !s.live)
    .sort((a, b) => String(b.updatedAt || "").localeCompare(String(a.updatedAt || "")))
    .slice(0, RAIL_MAX);
  host.innerHTML = recent.map((s) => {
    const b = roleBadge(s);
    return `<button class="co-rail-chip" data-co-rail="${escAttr(s.id)}" title="${escAttr(s.id)}" aria-label="reopen session ${escAttr(ident(s))}">
      <span class="co-rail-badge" data-layer="${b.layer}">${esc(b.txt)}</span>
      <span class="co-rail-id mono">${esc(ident(s))}</span>
      <span class="tone-dot" data-tone="${paneDotTone(s)}"></span>
      <span class="co-rail-age mono">${esc(relTime(s.updatedAt, CO.generatedAt))}</span></button>`;
  }).join("") || `<span class="co-rail-empty">no recent sessions</span>`;
  // queue chips (overflow), pulsing
  const qhost = document.getElementById("co-queue-chips");
  if (qhost) {
    qhost.innerHTML = (CO.queue || []).map((id) => {
      const s = CO.byId.get(id); if (!s) return "";
      const b = roleBadge(s);
      return `<button class="co-queue-chip" data-co-promote="${escAttr(id)}" title="promote ${escAttr(id)}">
        <span class="co-rail-badge" data-layer="${b.layer}">${esc(b.txt)}</span><span class="co-rail-id mono">${esc(ident(s))}</span></button>`;
    }).join("");
  }
}

// --------------------------------------------------------------- solo ---------
function renderSolo() {
  const surf = document.getElementById("surface-consoles");
  if (!surf) return;
  surf.dataset.solo = CO.soloId ? (CO.soloId === "origin" ? "l0" : "dyn") : "off";
  for (const [id, rec] of CO.panes) rec.el.classList.toggle("co-solo", CO.soloId && CO.soloId === id);
}

// -------------------------------------------------------------- line poll ----
function collectStreams() {
  const out = [];
  if (CO.soloId === "origin") {
    if (CO.l0.eventsPane) out.push({ id: "origin", pane: CO.l0.eventsPane, file: "events.ndjson", raw: false });
    return out;
  }
  if (CO.l0.eventsPane) out.push({ id: "origin", pane: CO.l0.eventsPane, file: "events.ndjson", raw: false });
  if (CO.l0.supPane && !CO.supCollapsed && CO.l0.supFile && !CO.l0.supUnavailable) out.push({ id: "origin", pane: CO.l0.supPane, file: CO.l0.supFile, raw: true, sup: true });
  if (!CO.soloId || CO.soloId === "origin") {
    for (const id of CO.order) {
      const rec = CO.panes.get(id);
      if (rec && rec.polling) out.push({ id, pane: rec.pane, raw: rec.pane.raw, file: undefined });
    }
  } else {
    const rec = CO.panes.get(CO.soloId);
    if (rec && rec.polling) out.push({ id: CO.soloId, pane: rec.pane, raw: rec.pane.raw });
  }
  return out;
}

function consolesTick() {
  if (!CO.visible || document.hidden) return;
  const streams = collectStreams();
  if (!streams.length) return;
  const start = streams.length ? CO.rr % streams.length : 0;
  const ordered = streams.slice(start).concat(streams.slice(0, start));
  const due = ordered.filter((s) => !s.pane.inflight).slice(0, MAX_INFLIGHT);
  CO.rr = (CO.rr + MAX_INFLIGHT) % Math.max(1, streams.length);
  const now = CO.generatedAt || (S.snap && S.snap.generatedAt);
  for (const s of due) {
    const p = fetchPaneLines(s.id, s.pane, { raw: s.raw, follow: CO.follow, now, file: s.file });
    // The supervisor log is declared in origin.logFiles but may not exist yet
    // (e.g. an idle repo). Two consecutive misses with nothing loaded → stop
    // polling it and show a quiet hint instead of a 404 every 2s.
    if (s.sup && p && typeof p.then === "function") {
      p.then((data) => {
        if (data == null && !s.pane.loaded) {
          if (++CO.l0.supFails >= 2) { CO.l0.supUnavailable = true; s.pane.body.innerHTML = `<div class="co-sup-empty">no supervisor log</div>`; }
        } else if (data != null) { CO.l0.supFails = 0; }
      });
    }
  }
}

// ------------------------------------------------------------- feed hook ------
function onFeed(state) {
  CO.sessions = state.sessions || [];
  CO.byId = state.byId || new Map(CO.sessions.map((s) => [s.id, s]));
  CO.generatedAt = state.generatedAt || null;
  CO.auto = state.auto || CO.auto;
  // resolve the supervisor logfile from origin's second logFile
  const o = originSession();
  if (o && Array.isArray(o.logFiles)) {
    const sup = o.logFiles.find((f) => f.kind !== "event");
    const name = sup ? sup.name : null;
    if (name !== CO.l0.supFile) { CO.l0.supFile = name; CO.l0.supFails = 0; CO.l0.supUnavailable = false; }
  }
  if (!CO.visible) return;   // don't churn DOM for a hidden surface
  renderL0Header();
  renderBar();
  reconcileDynPanes();
}

// ------------------------------------------------------------- mount ----------
function mount() {
  const surf = document.getElementById("surface-consoles");
  if (!surf) return;
  surf.innerHTML = "";
  surf.classList.add("co-surface");
  surf.dataset.solo = "off";
  surf.innerHTML = `
    <section class="co-l0" aria-label="L0 supervisor">
      <div class="co-l0-head" id="co-l0-head"></div>
      <div class="co-l0-streams">
        <div class="co-stream co-stream-events">
          <div class="co-stream-label">events</div>
          <div class="co-pane-body" id="co-l0-events" role="log" aria-live="off"><div class="term-pane-loading">connecting…</div></div>
        </div>
        <div class="co-stream co-stream-sup" data-collapsed="${CO.supCollapsed}">
          <button class="co-stream-label co-sup-toggle" id="co-sup-toggle" aria-expanded="${!CO.supCollapsed}">${icon("i-chev")}<span>supervisor</span></button>
          <div class="co-pane-body" id="co-l0-sup" role="log" aria-live="off"></div>
        </div>
      </div>
    </section>
    <section class="co-dyn" aria-label="Live sessions">
      <div class="co-bar" id="co-bar" role="group" aria-label="Console controls">
        <button class="co-tgl" data-co-tgl="auto" aria-pressed="true" title="Auto — manage the visible set automatically">${icon("i-bolt")}Auto</button>
        <button class="co-tgl" data-co-tgl="pin" aria-pressed="false" title="Pin all — only pinned panes stream">${icon("i-pin")}Pin all</button>
        <button class="co-tgl" data-co-tgl="follow" aria-pressed="true" title="Follow — auto-scroll to newest output">${icon("i-arrowdown")}Follow</button>
        <button class="co-tgl" data-co-tgl="raw" aria-pressed="false" title="Raw — show underlying log lines">${icon("i-file")}Raw</button>
        <button class="co-tgl" data-co-tgl="solo" aria-pressed="false" title="Solo — one pane fills the column">${icon("i-cols")}Solo</button>
      </div>
      <div class="co-dyn-grid" id="co-dyn-grid"></div>
      <div class="co-idle" id="co-idle" hidden></div>
      <div class="co-rail" id="co-rail">
        <div class="co-rail-head"><span class="co-eyebrow">recent</span><div class="co-queue-chips" id="co-queue-chips"></div></div>
        <div class="co-rail-chips" id="co-rail-chips"></div>
      </div>
    </section>`;

  // L0 stream panes (term-core states)
  const evBody = document.getElementById("co-l0-events");
  const supBody = document.getElementById("co-l0-sup");
  CO.l0.eventsPane = makePaneState(document.querySelector(".co-stream-events"), evBody, false);
  CO.l0.supPane = makePaneState(document.querySelector(".co-stream-sup"), supBody, true);
  evBody.addEventListener("scroll", () => { CO.l0.eventsPane.atBottom = evBody.scrollTop + evBody.clientHeight >= evBody.scrollHeight - 6; });
  supBody.addEventListener("scroll", () => { CO.l0.supPane.atBottom = supBody.scrollTop + supBody.clientHeight >= supBody.scrollHeight - 6; });

  wireEvents();
  renderL0Header();
  renderBar();
}

function wireEvents() {
  const surf = document.getElementById("surface-consoles");
  // supervisor collapse
  const supToggle = document.getElementById("co-sup-toggle");
  if (supToggle) supToggle.addEventListener("click", () => {
    CO.supCollapsed = !CO.supCollapsed;
    localStorage.setItem("gluerun.co.sup", CO.supCollapsed ? "1" : "0");
    const wrap = document.querySelector(".co-stream-sup");
    if (wrap) wrap.dataset.collapsed = String(CO.supCollapsed);
    supToggle.setAttribute("aria-expanded", String(!CO.supCollapsed));
  });
  // global bar
  const bar = document.getElementById("co-bar");
  if (bar) bar.addEventListener("click", (e) => {
    const b = e.target.closest(".co-tgl"); if (!b) return;
    const t = b.dataset.coTgl;
    if (t === "auto") { CO.autoOn = true; CO.pins = []; }
    else if (t === "pin") { CO.autoOn = false; CO.pins = CO.order.slice(); }
    else if (t === "follow") { CO.follow = !CO.follow; if (CO.follow) for (const rec of CO.panes.values()) scrollPaneToBottom(rec.pane); }
    else if (t === "raw") { CO.raw = !CO.raw; for (const rec of CO.panes.values()) { rec.pane.raw = CO.raw; resetPane(rec.pane); } }
    else if (t === "solo") { CO.soloId = CO.soloId ? null : (CO.order[0] || "origin"); syncSoloRoute(); }
    persist(); renderBar(); reconcileDynPanes();
  });
  // pane controls + rail chips (delegated)
  if (surf) surf.addEventListener("click", (e) => {
    const prompt = e.target.closest("[data-co-prompt]");
    if (prompt) { const s = CO.byId.get(prompt.dataset.coPrompt) || {}; viewSessionPrompt(prompt.dataset.coPrompt, prompt.dataset.coPromptFile, ident(s)); return; }
    const pin = e.target.closest("[data-co-pin]");
    if (pin) { togglePin(pin.dataset.coPin); return; }
    const raw = e.target.closest("[data-co-raw]");
    if (raw) { const rec = CO.panes.get(raw.dataset.coRaw); if (rec) { rec.pane.raw = !rec.pane.raw; resetPane(rec.pane); renderPaneHead(rec); } return; }
    const solo = e.target.closest("[data-co-solo]");
    if (solo) { setSolo(CO.soloId === solo.dataset.coSolo ? null : solo.dataset.coSolo); return; }
    const rail = e.target.closest("[data-co-rail]");
    if (rail) { reopenPinned(rail.dataset.coRail); return; }
    const promote = e.target.closest("[data-co-promote]");
    if (promote) { promoteQueued(promote.dataset.coPromote); return; }
  });
  // Esc exits solo
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && CO.visible && CO.soloId) { setSolo(null); }
  });
}

// ------------------------------------------------------------- actions --------
function togglePin(id) {
  if (CO.pins.includes(id)) CO.pins = CO.pins.filter((x) => x !== id);
  else CO.pins = CO.pins.concat(id);
  persist(); reconcileDynPanes();
}
function setSolo(id) {
  CO.soloId = id;
  syncSoloRoute();
  renderBar(); reconcileDynPanes();
}
function syncSoloRoute() {
  writeRoute("consoles", null, CO.soloId || null, null);
}
function reopenPinned(id) {
  if (!CO.pins.includes(id)) CO.pins = CO.pins.concat(id);
  persist();
  reconcileDynPanes();
}
function promoteQueued(id) {
  // evict the lowest-priority unpinned visible pane, pin the promoted one
  reopenPinned(id);
}

// ------------------------------------------------------------- lifecycle ------
export function initConsoles() {
  if (CO.started) return; CO.started = true;
  mount();
  subscribeSessions(onFeed, () => CO.visible);
  CO.tick = setInterval(consolesTick, TICK_MS);
  // seed from any state the feed already has
  onFeed(feedState());
}

// Called by main.js onSurface: activate/deactivate the surface.
export function setConsolesActive(on) {
  CO.visible = on;
  if (on) {
    renderL0Header(); renderBar(); reconcileDynPanes();
    pokeFeed();
    consolesTick();
  }
}

// Called by the router (onConsole) with the parsed route: #consoles[/<sessionId>].
export function consolesRoute(route) {
  const session = route && route.session;
  if (session) {
    if (session === "origin") { setSolo("origin"); return; }
    if (!CO.pins.includes(session)) CO.pins = CO.pins.concat(session);
    persist();
    CO.soloId = session;
    renderBar(); reconcileDynPanes();
  } else if (CO.soloId) {
    // returning to #consoles (no session) clears solo
    CO.soloId = null;
    renderBar(); reconcileDynPanes();
  }
}

// Live session count, for the nav badge (C4).
export function consolesLiveCount() {
  return feedState().sessions.filter((s) => s.live && s.id !== "origin").length;
}
