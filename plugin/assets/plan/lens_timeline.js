/* plan/lens_timeline.js — placeholder (filled in commit P3). */
let pane = null;
export const lens = {
  mount(p) { pane = p; if (pane) pane.innerHTML = `<div class="plan-lens-empty">Timeline lens — coming in this release</div>`; },
  update() {},
  applySelection() {},
  unmount() { pane = null; },
};
