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
  // choose the wide detail dock vs modal drawer presentation and lets the
  // workbench pause its polling when hidden.
  planVisible: null,

  // Plan-surface DAG-node selection. Registered by the workbench. It rings the
  // selected node in the mounted lens, preserves the route, and opens the shared
  // detail dock through app.select().
  onNodeSelect: null,

  // Clear the Plan lens marker when the shared inspector switches to a task or
  // closes. This is deliberately route-free; app.js owns the resulting route.
  onPlanSelectionClear: null,

  // Switch to the Tasks lens and scroll/ring a task row. Registered by the
  // workbench; called by app.navigateToTask so a deep link or dep-chip lands on
  // the row, not just the bottom sheet.
  onTaskNavigate: null,

  // Router surface changes can alter whether an open inspector is a dock or a
  // modal without changing its selected subject.
  onSurfaceChange: null,

  // Called on every successful 10s snapshot load so the mounted lens can refresh
  // (signature-gated) and the DAG cache can refetch when the gate map changes.
  onSnapshot: null,
};
