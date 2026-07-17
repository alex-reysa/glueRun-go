/* core/bus.js — a tiny registration bus that decouples app.js (the core console
   logic) from the plan/* surface modules and the router.

   app.js imports ONLY this module (never a plan module or the router), and calls
   the seams below when they are registered. The router and the plan workbench
   register their implementations at boot. Because nothing here imports app.js,
   a plan module, or the router, there is never a static import cycle:

     bus  ←  app.js
     bus, app.js  ←  router.js
     bus, app.js, router.js  ←  plan/*  ←  main.js

   Every seam is null until wired; callers guard with `bus.x && bus.x(...)`. */

export const bus = {
  // Router owns the URL hash. app.js routes its selection writes through here so
  // the console and the plan router never fight over `location.hash`.
  //   writeRoute(kind, id, tab)  kind ∈ "task" | "node" | "overview" | "none"
  writeRoute: null,

  // Is the Plan surface the one currently shown? (Router-owned.) Lets app.js
  // decide whether a node selection belongs in the plan aside vs the bottom sheet,
  // and lets the workbench pause its polling when hidden.
  planVisible: null,

  // Plan-surface DAG-node drilldown (the 360px aside). Registered by the
  // workbench. app.select()'s "node" arm and overlay clicks delegate here when
  // the Plan surface is visible and no bottom-sheet inspector is open.
  onNodeSelect: null,

  // Switch to the Tasks lens and scroll/ring a task row. Registered by the
  // workbench; called by app.navigateToTask so a deep link or dep-chip lands on
  // the row, not just the bottom sheet.
  onTaskNavigate: null,

  // Called on every successful 10s snapshot load so the mounted lens can refresh
  // (signature-gated) and the DAG cache can refetch when the gate map changes.
  onSnapshot: null,
};
