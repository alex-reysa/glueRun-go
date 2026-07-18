/* core/sessions-feed.js — the single /api/sessions poller for the whole console.

   Before 0.6.0 the dock terminal polled /api/sessions itself inside termTick.
   With a Consoles surface that also needs the live session list, two independent
   2s pollers would double the request rate and could disagree. This module is the
   one poller: subscribers register a callback + a `needsPoll()` predicate, and the
   feed ticks only while at least one subscriber needs it AND the tab is visible.

   Imports only the dependency-free core/api.js (the plan-thread fetch chokepoint) —
   no app.js, no bus — so it still sits below the surfaces in the import graph. */

import { apiFetch, isHistorical } from "./api.js";

const LIMIT = 24;
const POLL_MS = 2000;

let state = { sessions: [], auto: { mode: "origin", sessionIds: ["origin"] }, generatedAt: null, byId: new Map() };
const subs = new Set();   // { cb, needsPoll }
let timer = null, inflight = false, started = false;

export function feedState() { return state; }

// Register a subscriber. `cb(state)` fires on every successful poll; `needsPoll()`
// (optional) gates whether this subscriber currently wants the feed running.
// Returns an unsubscribe fn.
export function subscribe(cb, needsPoll) {
  const s = { cb, needsPoll: needsPoll || (() => true) };
  subs.add(s);
  // Hand the newcomer the last good state immediately so it can paint without
  // waiting a full poll interval.
  if (state.generatedAt != null || state.sessions.length) { try { cb(state); } catch (e) {} }
  return () => subs.delete(s);
}

async function poll() {
  if (inflight || document.hidden) return;
  if (![...subs].some((s) => s.needsPoll())) return;   // nobody needs it → skip
  inflight = true;
  try {
    const res = await apiFetch("/api/sessions?limit=" + LIMIT, { cache: "no-store" });
    if (!res.ok) throw new Error("http " + res.status);
    const data = await res.json();
    const sessions = data.sessions || [];
    state = {
      sessions,
      auto: data.auto || state.auto,
      generatedAt: data.generatedAt || null,
      byId: new Map(sessions.map((s) => [s.id, s])),
    };
    for (const s of subs) { try { s.cb(state); } catch (e) {} }
  } catch (e) {
    /* keep last good state; a transient poll miss must not blank the dock/consoles */
  } finally {
    inflight = false;
  }
}

// Force an immediate poll (used on visibility resume / surface activation).
export function pokeFeed() { poll(); }

export function startFeed() {
  if (started) return; started = true;
  poll();
  // Archived sessions are immutable — one fetch (poked on demand when a surface
  // activates), no 2s interval. term-core also stops polling finished sessions.
  if (isHistorical()) return;
  timer = setInterval(poll, POLL_MS);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) poll(); });
}
