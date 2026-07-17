// glueRun console — module entry point. Boots the app shell, then wires the Plan
// surface (workbench + lenses) and the hash router on top of app.js's exported
// seams. main.js is the ONLY module that imports both app.js and the plan/router
// modules, so the composition lives here and no static import cycle forms.
import { start } from "./app.js";
import { bus } from "./core/bus.js";
import { initRouter, tick as routerTick } from "./core/router.js";
import { initWorkbench, setLens, getLens, planTick } from "./plan/workbench.js";

start();               // boot the core console (top bar, dock, inspector, polling)
initWorkbench();       // mount the stored Plan lens + register the plan bus seams

// The per-snapshot dispatcher app.js invokes each successful 10s load: refresh
// the mounted lens (paused when the Plan surface is hidden), then let the router
// apply any deferred initial deep-link selection once the snapshot is in.
bus.onSnapshot = () => { planTick(); routerTick(); };

initRouter({
  onSurface: () => {},                          // (polling is paused per-lens via planTick)
  onLens: (lens) => setLens(lens, { route: false }),
  getLens,
});
