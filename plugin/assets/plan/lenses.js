/* plan/lenses.js — dependency-free Plan lens vocabulary shared by the router
   and workbench. Keep route ids and visible labels together so adding or
   renaming a lens cannot make the URL grammar drift from the toolbar. */

export const LENSES = Object.freeze([
  Object.freeze({ id: "timeline", label: "Timeline" }),
  Object.freeze({ id: "matrix", label: "Matrix" }),
  Object.freeze({ id: "dag", label: "DAG" }),
  Object.freeze({ id: "tasks", label: "Tasks" }),
]);

const LENS_IDS = new Set(LENSES.map((lens) => lens.id));

export function isPlanLens(id) {
  return LENS_IDS.has(id);
}
