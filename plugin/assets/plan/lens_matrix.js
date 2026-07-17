/* plan/lens_matrix.js — placeholder (filled in commit P2). */
let pane = null;
export const lens = {
  mount(p) { pane = p; if (pane) pane.innerHTML = `<div class="plan-lens-empty">Matrix lens — coming in this release</div>`; },
  update() {},
  applySelection() {},
  unmount() { pane = null; },
};
