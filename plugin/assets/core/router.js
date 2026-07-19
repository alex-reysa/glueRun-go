/* core/router.js — the console's hash router. Owns which #surface-* is shown,
   which thread-subnav row is pressed, and the URL grammar:

     #<surface>[/<lens>[/<selection>[:<tab>]]]
     #plan/timeline|matrix|dag|tasks[/NODE:<id>|TASK-XXXX[:tab]]
     #consoles[/<sessionId>]
     #agents[/<roleId>[/<sessionId>]]
     #providers[/<providerId>]

   Legacy 0.5.x hashes are migrated on load + hashchange:
     #TASK-0123[:tab] → #plan/tasks/TASK-0123[:tab]   (+ navigate)
     #NODE:<id>       → #plan/dag/NODE:<id>            (+ select node)
     #L1:<area>       → #plan/tasks (+ area filter + select L1)
     #PLAN            → open the overview inspector (plan-pill behavior)
     ?list=1          → #plan/tasks

   Selections need the first snapshot, so on initial load they are deferred and
   applied by tick() once S.snap arrives; hashchange navigations apply at once.

   Import direction: router → app.js (never the reverse), router → bus. app.js
   imports only bus, so there is no static cycle. */

import { select, navigateToTask, setAreaFilter, S } from "../app.js";
import { bus } from "./bus.js";
import { isHistorical } from "./api.js";

const SURFACES = ["home", "plan", "consoles", "agents", "providers"];
const LENSES = ["timeline", "matrix", "dag", "tasks"];

let cfg = { onSurface: null, onLens: null };
let applying = false;         // guard: suppress route writes while resolving one
let pending = null;           // deferred initial selection (needs a snapshot)

// -------------------------------------------------------------- parse ------
export function currentRoute() {
  const raw = decodeURIComponent((location.hash || "").replace(/^#/, ""));
  const legacy = migrateLegacy(raw);
  if (legacy) return legacy;
  const parts = raw.split("/").filter(Boolean);
  const surface = SURFACES.includes(parts[0]) ? parts[0] : "home";
  if (surface === "home") return { surface };
  if (surface === "plan") {
    const lens = LENSES.includes(parts[1]) ? parts[1] : null;
    let sel = parts[2] != null ? parts.slice(2).join("/") : null;
    let tab = null;
    if (sel) {
      // TASK-xxxx:tab — only split a trailing :tab (NODE:id keeps its colon).
      if (/^TASK-\d+:/.test(sel)) { const i = sel.indexOf(":"); tab = sel.slice(i + 1); sel = sel.slice(0, i); }
      else if (/^NODE:/.test(sel)) { const j = sel.indexOf(":", 5); if (j > 0) { tab = sel.slice(j + 1); sel = sel.slice(0, j); } }
    }
    return { surface, lens, sel, tab };
  }
  if (surface === "consoles") return { surface, session: parts[1] || null };
  if (surface === "providers") return { surface, id: parts[1] || null };
  return { surface, role: parts[1] || null, session: parts[2] || null };
}

// Returns a route object for a legacy hash, or null if the hash isn't legacy.
function migrateLegacy(raw) {
  if (!raw) {
    if (new URLSearchParams(location.search).get("list") === "1") return { surface: "plan", lens: "tasks", sel: null, tab: null, _migrate: true };
    return { surface: "home", _migrate: true };
  }
  if (/^TASK-\d+(:|$)/.test(raw)) {
    const i = raw.indexOf(":");
    const id = i > 0 ? raw.slice(0, i) : raw;
    const tab = i > 0 ? raw.slice(i + 1) : null;
    return { surface: "plan", lens: "tasks", sel: id, tab, _migrate: true };
  }
  if (/^NODE:/.test(raw)) return { surface: "plan", lens: "dag", sel: raw, tab: null, _migrate: true };
  if (/^L1:/.test(raw)) return { surface: "plan", lens: "tasks", sel: raw, tab: null, _migrate: true };
  if (raw === "PLAN") return { surface: "plan", lens: null, sel: "PLAN", tab: null, _migrate: true };
  return null;
}

// -------------------------------------------------------------- write ------
export function writeRoute(surface, lens, selId, tab) {
  if (applying) return;
  let h = "#" + surface;
  if (surface === "home") {
    // no sub-route in v2
  } else if (surface === "plan") {
    if (lens) h += "/" + lens;
    if (selId) { h += "/" + selId; if (tab) h += ":" + tab; }
  } else if (surface === "consoles") {
    // #consoles[/<sessionId>]
    if (selId) h += "/" + selId;
  } else if (surface === "agents") {
    // #agents[/<roleId>[/<sessionId>]] — lens carries the roleId, selId the session
    if (lens) h += "/" + lens;
    if (selId) h += "/" + selId;
  } else if (surface === "providers") {
    // #providers[/<providerId>] — lens carries the providerId
    if (lens) h += "/" + lens;
  }
  try { history.replaceState(null, "", h); } catch (e) {}
}

// -------------------------------------------------- surface visibility -----
export function surfaceVisible(name) {
  const el = document.getElementById("surface-" + name);
  return !!el && el.dataset.active === "true";
}

const SURFACE_LABELS = { home: "Home", plan: "Plan", consoles: "Consoles", agents: "Agents", providers: "Providers" };

function showSurface(name) {
  for (const s of SURFACES) {
    const el = document.getElementById("surface-" + s);
    if (!el) continue;
    const on = s === name;
    el.dataset.active = String(on);
    el.hidden = !on;
  }
  // aria-pressed is mirrored across BOTH navs: the active thread's sub-menu
  // (#thread-subnav — a persistent node core/plans.js re-parents under the
  // active thread row) and the app-level sidebar (#side-nav, Providers).
  document.querySelectorAll("#thread-subnav [data-surface], #side-nav [data-surface]").forEach((b) => {
    b.setAttribute("aria-pressed", String(b.dataset.surface === name));
  });
  // Breadcrumb tail (repo › thread › SURFACE) — the earlier segments are painted
  // by core/dock.js (repo) and core/plans.js (thread).
  const crumb = document.getElementById("crumb-surface");
  if (crumb) crumb.textContent = SURFACE_LABELS[name] || name;
}

// ------------------------------------------------------------- resolve -----
function resolveSelection(route) {
  if (route.surface !== "plan") return;
  const sel = route.sel, tab = route.tab;
  if (!sel) return;
  if (sel === "PLAN") { select("overview", "plan"); return; }
  if (/^TASK-\d+$/.test(sel)) {
    if (tab) S.inspTab = tab === "events" ? "timeline" : tab;
    navigateToTask(sel);
    return;
  }
  if (/^NODE:/.test(sel)) {
    const id = sel.slice(5);
    if (bus.onNodeSelect) bus.onNodeSelect(id); else select("node", id);
    return;
  }
  if (/^L1:/.test(sel)) {
    const area = sel.slice(3);
    setAreaFilter(area);
    select("l1", "L1:" + area);
  }
}

// Apply a parsed route: surface + lens now; selection now if the snapshot is in,
// else defer to the next tick(). `initial` selections always defer.
function applyRoute(route, initial) {
  // Agents + Providers are live-repo concepts (config/settings/runtime probes) —
  // unreachable in historical mode. Redirect either route to #home before it resolves.
  if (isHistorical() && (route.surface === "agents" || route.surface === "providers")) {
    route = { surface: "home" };
    try { history.replaceState(null, "", "#home"); } catch (e) {}
  }
  applying = true;
  try {
    showSurface(route.surface);
    if (cfg.onSurface) cfg.onSurface(route.surface);
    if (route.surface === "plan" && route.lens && cfg.onLens) cfg.onLens(route.lens);
    // Consoles/Agents own their own sub-route (session / role+session). They are
    // feed-driven, not snapshot-gated, so they resolve immediately on load and on
    // every hashchange — no deferral like the plan selection below.
    if (route.surface === "consoles" && cfg.onConsole) cfg.onConsole(route);
    if (route.surface === "agents" && cfg.onAgents) cfg.onAgents(route);
    if (route.surface === "providers" && cfg.onProviders) cfg.onProviders(route);
    if (route.surface === "home" && cfg.onHome) cfg.onHome(route);
  } finally { applying = false; }
  // Normalize a legacy/implicit hash to the canonical form.
  if (route._migrate || !location.hash) {
    const lens = route.lens || (cfg.getLens ? cfg.getLens() : "timeline");
    writeRoute(route.surface, lens, /^L1:/.test(route.sel || "") || route.sel === "PLAN" ? null : route.sel, route.tab);
  }
  if (route.surface === "plan" && (route.sel)) {
    if (initial || !S.snap) pending = route; else resolveSelection(route);
  }
}

// Called every snapshot tick (via bus.onSnapshot) — applies a deferred initial
// selection exactly once, when the snapshot is finally available.
export function tick() {
  if (pending && S.snap) { const p = pending; pending = null; resolveSelection(p); }
}

// -------------------------------------------------------------- init -------
export function initRouter(options) {
  cfg = Object.assign({ onSurface: null, onLens: null, getLens: null, onConsole: null, onAgents: null, onProviders: null, onHome: null }, options || {});

  bus.writeRoute = (kind, id, tab) => {
    const r = currentRoute();
    if (r.surface !== "plan") return;
    if (kind === "task") writeRoute("plan", r.lens || (cfg.getLens && cfg.getLens()) || "tasks", id, tab);
    else if (kind === "node") writeRoute("plan", r.lens || (cfg.getLens && cfg.getLens()) || "dag", "NODE:" + id, tab);
    else if (kind === "none") writeRoute("plan", r.lens || (cfg.getLens && cfg.getLens()), null, null);
  };
  bus.planVisible = () => surfaceVisible("plan");

  // Surface switch: delegated on BOTH the thread sub-menu and the app-level
  // sidebar (Providers lives in #side-nav as of 0.10.0). Same click handler.
  // #thread-subnav is a persistent node (core/plans.js builds it once and
  // re-parents it across threads repaints), so this binding survives repaints;
  // main.js init order (initPlans before initRouter) guarantees it exists here.
  const onNavClick = (e) => {
    const b = e.target.closest("[data-surface]");
    if (!b || b.disabled) return;
    const name = b.dataset.surface;
    // Only the Plan surface carries a lens in its hash; Consoles/Agents must not
    // inherit a plan lens id as a session/role segment.
    const lens = name === "plan" ? (cfg.getLens ? cfg.getLens() : "timeline") : null;
    writeRoute(name, lens, null, null);
    applyRoute(currentRoute(), false);
  };
  for (const id of ["thread-subnav", "side-nav"]) {
    const nav = document.getElementById(id);
    if (nav) nav.addEventListener("click", onNavClick);
  }

  window.addEventListener("hashchange", () => applyRoute(currentRoute(), false));
  applyRoute(currentRoute(), true);
}
