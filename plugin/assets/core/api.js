/* core/api.js — the single client-side API chokepoint for plan threads (0.8.0).

   The console can be pinned to an archived plan by a `?plan=<id>` query param.
   In that "historical" mode every /api/ read must carry the same param so the
   server resolves the archived mini-repo instead of the live tree. Rather than
   thread that through 21 scattered fetch sites, every fetch now routes through
   apiFetch/apiUrl here, which merge the plan id into the path's query string.

   The active plan is decided ONCE at module init (boot) — switching plans is a
   full page reload (switchPlan), never an in-place cache/signature dance, so
   historical vs live is a single immutable decision for the life of the page.

   Imports NOTHING (dependency-free) so any module — core, surface, or app.js —
   may import it without forming a cycle. Since 0.17.0 it also hosts the tiny
   execution-state store (setExecState/getExecState/onExecState, see the bottom
   of the file), for the same reason: every surface needs it and nothing may
   import a surface to get it. */

// A plan id as minted by `singular plan archive` (plan-<UTCstamp>[-<slug>]). This
// is also the sole gate on a value that becomes a server-side filesystem root, so
// the charset is tight and mirrors the server's PLAN_ID_RE exactly.
const PLAN_ID_RE = /^plan-[A-Za-z0-9-]{1,64}$/;

function parseActivePlan() {
  try {
    const raw = new URLSearchParams(location.search).get("plan");
    return raw && PLAN_ID_RE.test(raw) ? raw : null;
  } catch (e) { return null; }
}

// Parsed once, at boot. Null unless a valid ?plan= is present.
export const activePlan = parseActivePlan();

export function isHistorical() { return !!activePlan; }

// Merge plan=<id> into an /api/ path's EXISTING query string (paths like
// /api/session/x?cursor=0&limit=200&file=y exist — never a naive append). Live
// mode returns the path unchanged; non-/api/ paths (favicon/assets) are left
// alone so only the API carries the param.
export function apiUrl(path) {
  if (!activePlan) return path;
  if (typeof path !== "string" || !path.startsWith("/api/")) return path;
  try {
    const u = new URL(path, location.origin);
    u.searchParams.set("plan", activePlan);
    return u.pathname + u.search;
  } catch (e) { return path; }
}

export function apiFetch(path, init) { return fetch(apiUrl(path), init); }

// Navigate to the same page with ?plan= set (archived) or removed (live), hash
// reset to #home. A full reload is deliberate: historical mode is decided once at
// boot, so there is no in-place cache/signature invalidation to get wrong.
export function switchPlan(idOrNull) {
  try {
    const u = new URL(location.href);
    if (idOrNull) u.searchParams.set("plan", idOrNull);
    else u.searchParams.delete("plan");
    u.hash = "#home";
    location.href = u.toString();
  } catch (e) {
    location.href = idOrNull ? ("?plan=" + encodeURIComponent(idOrNull) + "#home") : "?#home";
  }
}

// ------------------------------------------------------------ exec state -----
// PMGO-003: the console had exactly one liveness vocabulary, so "Current plan ·
// live" (a DATA-SOURCE fact — we are attached to the live tree, not an archive)
// read as "the orchestration loop is running". They are different facts and now
// have different stores: connection/plan-source stays where it was, EXECUTION
// state lives here as { loopAlive, stopPresent, stopReason }.
//
// app.js is the SOLE writer (setExecState after each /api/state snapshot and
// each /api/overview land) and never writes in historical mode — an archived
// plan's payload describes a finished run and can never be evidence that a loop
// is alive. Subscribe-with-replay mirrors plan/data.js's onDag so a subscriber
// registered before the first poll paints as soon as the state exists.
let execState = null;
let execSig = "";
const execSubs = new Set();

export function getExecState() { return execState; }

// Deduped on the composed value: a quiet 10s poll notifies nobody.
export function setExecState(next) {
  const s = next && typeof next === "object" ? next : null;
  const sig = s ? JSON.stringify([s.loopAlive, s.stopPresent, s.stopReason]) : "";
  if (sig === execSig) return;
  execSig = sig;
  execState = s;
  execSubs.forEach((fn) => { try { fn(execState); } catch (e) {} });
}

// Returns an unsubscribe. Replays the current state immediately when one exists.
export function onExecState(fn) {
  execSubs.add(fn);
  if (execState) { try { fn(execState); } catch (e) {} }
  return () => execSubs.delete(fn);
}
