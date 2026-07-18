/* core/term-core.js — the pure per-pane terminal engine, extracted from app.js so
   both the bottom dock and the Consoles surface stream the same byte-cursor tail
   with identical row rendering, scroll-retention, and id-keyed row replacement.

   Imports only the dependency-free core/api.js (the plan-thread fetch chokepoint)
   so there is still never a static cycle: app.js → term-core, consoles/* →
   term-core. The few tiny pure helpers it needs (esc, relTime, toneOf, eventTone)
   are duplicated here verbatim from app.js; they are stable formatting primitives
   and keeping them local is what makes this module (near-)dependency-free. The row
   HTML is byte-identical to the old dock renderer, so re-pointing the dock at this
   module changes nothing the user can see. */

import { apiFetch } from "./api.js";

export const TERM_MAX_LINES = 600;        // per-pane ring-buffer cap (DOM nodes)
export const TERM_LINE_LIMIT = 500;       // initial tail size requested from the server
export const TERM_BACKLOG_SNAP = 1000000; // bytes behind EOF before we snap to the live tail

// ---- pure helpers (verbatim copies of app.js's — must stay render-compatible) ----
const esc = (v) => String(v == null ? "" : v).replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const STATE_TONE = {
  idle: "idle", stopped: "idle", draft: "idle",
  active: "active", awaiting: "awaiting", stale: "warn",
  blocked: "error", failed: "error", integrated: "success",
};
const toneOf = (state) => STATE_TONE[state] || "idle";

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

function eventTone(type) {
  type = String(type || "");
  if (/fail|error|frozen|blocked|reject|pressure|abort/.test(type)) return "warn";
  if (/accept/.test(type)) return "active";
  if (/passed|integrated|committed|ok/.test(type)) return "success";
  if (/dispatch|started|generated|fanout|staged|lease/.test(type)) return "active";
  return "idle";
}

function toneDot(state, cls) {
  return `<span class="tone-dot${cls ? " " + cls : ""}" data-tone="${toneOf(state)}"></span>`;
}

// ---- pane state ----
// A pane-state object is { el, body, cursor, raw, lineEls, count, atBottom,
// inflight, loaded }. Callers create the DOM (`el`/`body`) and wire the scroll
// listener; this module only mutates the streaming fields. makePaneState seeds
// the streaming fields for a caller who already built the DOM.
export function makePaneState(el, body, raw) {
  return { el, body, cursor: null, raw: !!raw, lineEls: new Map(), count: 0, atBottom: true, inflight: false, loaded: false };
}

function makeNode(html) {
  const t = document.createElement("template");
  t.innerHTML = html.trim();
  return t.content.firstElementChild;
}

export function clearPaneBody(pane) { pane.body.innerHTML = ""; pane.lineEls.clear(); pane.count = 0; pane.atBottom = true; }
export function resetPane(pane) { pane.cursor = null; clearPaneBody(pane); }

export function termLineHtml(ln, now) {
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
      return `<div class="term-line tl-event"><span class="tl-ev-ts">${esc(relTime(ln.ts, now))}</span><span class="tl-ev-type" data-tone="${eventTone(ln.eventType)}">${esc(ln.eventType)}</span><span class="tl-ev-msg">${esc(ln.text)}</span></div>`;
    case "meta":
      return `<div class="term-line tl-meta">${esc(ln.text)}</div>`;
    case "log":
    default: {
      const lvl = ln.level ? `<span class="tl-lvl">${esc(ln.level)}</span>` : "";
      return `<div class="term-line tl-log${ln.level ? " lvl-" + esc(ln.level) : ""}">${lvl}${esc(ln.text || "")}</div>`;
    }
  }
}

export function appendLines(pane, lines, isInitial, opts) {
  if (!lines.length) return;
  const follow = !opts || opts.follow !== false;
  const now = opts && opts.now;
  const wasBottom = pane.atBottom;
  const loading = pane.body.querySelector(".term-pane-loading"); if (loading) loading.remove();
  for (const ln of lines) {
    const node = makeNode(termLineHtml(ln, now));
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
  if (follow && (wasBottom || isInitial)) scrollPaneToBottom(pane);
  else pane.atBottom = pane.body.scrollTop + pane.body.clientHeight >= pane.body.scrollHeight - 6;
}

// Pin a pane to the newest output. The rAF re-pin handles the case where flex
// layout settles a frame after the lines are inserted (scrollHeight not final yet).
export function scrollPaneToBottom(pane) {
  const stick = () => {
    pane.body.scrollTop = pane.body.scrollHeight;
    pane.atBottom = true;
  };
  stick();
  requestAnimationFrame(stick);
}

// Fetch one window of a session's tail into `pane`. opts: { raw, follow, now,
// file }. Mutates pane (cursor/lines/scroll) exactly as the old dock did; a
// scrolled-up pane keeps its scrollTop because appendLines only sticks when the
// pane was already at bottom. Returns the parsed payload (for callers who want
// to stop polling a finished historical session).
export async function fetchPaneLines(id, pane, opts) {
  opts = opts || {};
  if (pane.inflight) return null;
  if (pane.raw !== !!opts.raw) { resetPane(pane); pane.raw = !!opts.raw; } // raw toggled — reload
  pane.inflight = true;
  try {
    const p = new URLSearchParams();
    if (pane.cursor != null) p.set("cursor", String(pane.cursor));
    p.set("limit", String(TERM_LINE_LIMIT));
    if (opts.raw) p.set("raw", "1");
    if (opts.file) p.set("file", opts.file);
    const res = await apiFetch("/api/session/" + encodeURIComponent(id) + "?" + p.toString(), { cache: "no-store" });
    if (!res.ok) throw new Error("http " + res.status);
    const data = await res.json();
    const fresh = data.reset || pane.cursor == null;
    if (fresh) clearPaneBody(pane);
    appendLines(pane, data.lines || [], fresh, opts);
    pane.cursor = data.cursor;
    pane.loaded = true;
    // Far behind a bursty writer (forward reads advance one window at a time)?
    // Snap to the live tail next poll instead of crawling — show "now", not history.
    if (data.size != null && data.size - data.cursor > TERM_BACKLOG_SNAP) pane.cursor = null;
    return data;
  } catch (e) {
    if (!pane.loaded) pane.body.innerHTML = `<div class="term-pane-loading">could not load session</div>`;
    return null;
  } finally {
    pane.inflight = false;
  }
}
