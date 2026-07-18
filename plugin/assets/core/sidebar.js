/* core/sidebar.js — the app-level sidebar's collapse state (0.10.0). Persists an
   open|rail preference in localStorage under `gluerun.side`; with no stored
   preference it follows the viewport (rail under 1100px, open at or above) and
   keeps following as the window crosses that breakpoint. A click on #side-collapse
   pins an explicit choice that from then on wins over the media query.

   Dependency-free (imports nothing) so it sits at the very bottom of the graph;
   main.js calls initSidebar() once, right after initPlans(). */

const KEY = "gluerun.side";
const NARROW = "(max-width: 1100px)";

// A valid stored preference, or null when the user has made no explicit choice.
function stored() {
  try { const v = localStorage.getItem(KEY); return v === "open" || v === "rail" ? v : null; }
  catch (e) { return null; }
}

// Reflect the rail state into the body class + the chevron's aria-expanded.
function apply(rail) {
  document.body.classList.toggle("side-rail", rail);
  const btn = document.getElementById("side-collapse");
  if (btn) btn.setAttribute("aria-expanded", String(!rail));
}

export function initSidebar() {
  const mq = window.matchMedia ? window.matchMedia(NARROW) : null;
  // Initial state: an explicit stored choice wins; else follow the viewport.
  const pref = stored();
  apply(pref ? pref === "rail" : !!(mq && mq.matches));

  const btn = document.getElementById("side-collapse");
  if (btn) btn.addEventListener("click", () => {
    const rail = !document.body.classList.contains("side-rail");
    apply(rail);
    try { localStorage.setItem(KEY, rail ? "rail" : "open"); } catch (e) {}
  });

  // With no explicit choice, keep following the breakpoint as the window resizes;
  // once the user has pinned a preference, the media query no longer overrides.
  if (mq) {
    const onChange = () => { if (!stored()) apply(mq.matches); };
    if (mq.addEventListener) mq.addEventListener("change", onChange);
    else if (mq.addListener) mq.addListener(onChange);   // Safari <14 fallback
  }
}
