/* core/plans.js — the plan-thread registry client (0.8.0). Fetches /api/plans
   once at boot (and lazily on switcher focus), owns the header plan switcher and
   the historical-mode banner, and — in historical mode — paints the archived
   plan's gates into the Plan workbench readout.

   Import direction: plans.js → core/api.js only (never a surface, never app.js),
   so it sits low in the graph and any surface + main.js may import it. The tiny
   esc/fmtDate helpers are local (kept dependency-free on purpose). */

import { activePlan, isHistorical, apiFetch, switchPlan } from "./api.js";

const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const esc = (v) => String(v == null ? "" : v).replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function fmtDate(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d)) return String(iso).slice(0, 10);
  return `${MON[d.getUTCMonth()]} ${d.getUTCDate()}`;
}

// null = not fetched yet OR the endpoint is unavailable (older server); an array
// (possibly empty) means the endpoint answered. Callers use null to hide the
// feature quietly.
let plansData = null;
let fetched = false;
let inflight = null;

export function plansList() { return plansData; }

export function activePlanEntry() {
  if (!activePlan || !plansData) return null;
  return plansData.find((p) => p.id === activePlan) || null;
}

export async function fetchPlans(force) {
  if (inflight) return inflight;
  if (fetched && !force) return plansData;
  inflight = (async () => {
    try {
      const res = await apiFetch("/api/plans", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        plansData = Array.isArray(data.plans) ? data.plans : [];
      }
      // A non-OK response leaves plansData as-is (null on first miss) so the
      // switcher/card stay hidden on servers without the endpoint.
    } catch (e) { /* leave last good; null signals unavailable */ }
    finally { fetched = true; inflight = null; }
    return plansData;
  })();
  return inflight;
}

// name · MMM D · gates P/T
function entryLabel(p) {
  const g = p.gates || {};
  const gp = g.passed != null ? g.passed : "?";
  const gt = g.total != null ? g.total : "?";
  return `${p.name || p.id} · ${fmtDate(p.archivedAt)} · gates ${gp}/${gt}`;
}

// ------------------------------------------------------------- switcher -------
function populateSwitcher() {
  const wrap = document.getElementById("plan-switcher");
  const sel = document.getElementById("plan-switcher-select");
  if (!wrap || !sel) return;
  const list = plansData || [];
  // Older server (no endpoint) or nothing archived, and we are live → the feature
  // is quietly absent.
  if (!isHistorical() && (plansData == null || list.length === 0)) { wrap.hidden = true; return; }
  wrap.hidden = false;
  let opts = `<option value="">Current plan</option>`;
  opts += list.map((p) =>
    `<option value="${esc(p.id)}"${p.id === activePlan ? " selected" : ""}>${esc(entryLabel(p))}</option>`).join("");
  // Self-heal edge: historical on an id the registry didn't return — still offer it.
  if (isHistorical() && !list.some((p) => p.id === activePlan)) {
    opts += `<option value="${esc(activePlan)}" selected>${esc(activePlan)}</option>`;
  }
  sel.innerHTML = opts;
  sel.value = activePlan || "";
}

// ------------------------------------------------------------- banner ---------
function paintBanner() {
  const banner = document.getElementById("plan-banner");
  if (!banner) return;
  if (!isHistorical()) { banner.hidden = true; return; }
  const entry = activePlanEntry();
  const name = (entry && entry.name) || activePlan;
  const when = entry && entry.archivedAt ? fmtDate(entry.archivedAt) : "";
  const txt = banner.querySelector(".pb-text");
  if (txt) txt.textContent = `Viewing archived plan ${name}${when ? " (" + when + ")" : ""} — read-only`;
  banner.hidden = false;
}

// The Plan workbench gates readout, in historical mode, reflects the archived
// plan's registry entry (app.js suppresses its own gates write when historical).
function paintArchivedGates() {
  if (!isHistorical()) return;
  const entry = activePlanEntry();
  const val = document.getElementById("plan-gates-val");
  if (!val || !entry || !entry.gates) return;
  const g = entry.gates;
  val.textContent = `${g.passed != null ? g.passed : "?"}/${g.total != null ? g.total : "?"}`;
}

// ------------------------------------------------------------- init -----------
export function initPlans() {
  if (isHistorical()) document.body.classList.add("historical");

  const backBtn = document.getElementById("pb-back");
  if (backBtn) backBtn.addEventListener("click", () => switchPlan(null));

  const sel = document.getElementById("plan-switcher-select");
  if (sel) {
    sel.addEventListener("change", () => {
      const v = sel.value;
      if (v) switchPlan(v);
      else if (isHistorical()) switchPlan(null);   // "Current plan" while historical → back to live
    });
    // Lazily refresh the list just before the dropdown opens.
    sel.addEventListener("focus", () => { fetchPlans(true).then(() => populateSwitcher()); });
  }

  if (isHistorical()) {
    const agentsNav = document.querySelector('#surface-nav [data-surface="agents"]');
    if (agentsNav) { agentsNav.disabled = true; agentsNav.title = "live only"; }
  }

  paintBanner();   // shows the id fallback immediately; refreshed once plans resolve
  fetchPlans().then(() => { populateSwitcher(); paintBanner(); paintArchivedGates(); });
}

export { fmtDate };
