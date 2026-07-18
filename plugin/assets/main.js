// glueRun console — module entry point. Boots the app shell, then wires the Plan,
// Consoles, and Agents surfaces (each on top of app.js's exported seams) and the
// hash router. main.js is the ONLY module that imports app.js AND the surface
// modules AND the router, so the composition lives here and no static import cycle
// forms (app.js imports only bus + the two dependency-free core streamers).
import { start } from "./app.js";
import { bus } from "./core/bus.js";
import { initRouter, tick as routerTick } from "./core/router.js";
import { initPlans } from "./core/plans.js";
import { initWorkbench, setLens, getLens, planTick } from "./plan/workbench.js";
import { initConsoles, setConsolesActive, consolesRoute, consolesLiveCount } from "./consoles/surface.js";
import { initAgents, setAgentsActive, agentsRoute, agentsTick } from "./agents/surface.js";
import { initProviders, setProvidersActive, providersRoute, providersTick } from "./providers/surface.js";
import { initHome, setHomeActive, homeRoute, homeTick } from "./home/surface.js";

initPlans();           // header plan switcher + historical banner (sets body.historical early)
start();               // boot the core console (top bar, inspector, polling)
initWorkbench();       // mount the stored Plan lens + register the plan bus seams
initConsoles();        // build the Consoles surface (idle until shown)
initAgents();          // build the Agents surface (idle until shown)
initProviders();       // build the Providers surface (idle until shown)
initHome();            // build the Home surface (idle until shown)

// The per-snapshot dispatcher app.js invokes each successful 10s load: refresh the
// mounted plan lens (paused when hidden), the agents grid (paused when hidden),
// then let the router apply any deferred initial deep-link selection.
bus.onSnapshot = () => { planTick(); agentsTick(); providersTick(); homeTick(); routerTick(); updateConsoleBadge(); };

// Consoles nav button carries a small live-session count badge (C4).
function updateConsoleBadge() {
  const btn = document.querySelector('#surface-nav [data-surface="consoles"]');
  if (!btn) return;
  const n = consolesLiveCount();
  btn.dataset.live = n > 0 ? String(n) : "";
}
setInterval(updateConsoleBadge, 2000);

initRouter({
  // Dock is visible only on Plan; hidden on Consoles + Agents (it duplicates the
  // L0 streams there). Activate/deactivate the surface modules so a backgrounded
  // surface does no polling or DOM work.
  onSurface: (surface) => {
    setConsolesActive(surface === "consoles");
    setAgentsActive(surface === "agents");
    setProvidersActive(surface === "providers");
    setHomeActive(surface === "home");
  },
  onLens: (lens) => setLens(lens, { route: false }),
  getLens,
  onConsole: (route) => consolesRoute(route),
  onAgents: (route) => agentsRoute(route),
  onProviders: (route) => providersRoute(route),
  onHome: (route) => homeRoute(route),
});
