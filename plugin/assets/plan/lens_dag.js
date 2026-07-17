/* plan/lens_dag.js — placeholder (filled in commit P1). */
let pane = null;
export const lens = {
  mount(p) { pane = p; if (pane) pane.innerHTML = `<div class="plan-lens-empty">DAG lens — coming in this release</div>`; },
  update() {},
  applySelection() {},
  unmount() { pane = null; },
};
