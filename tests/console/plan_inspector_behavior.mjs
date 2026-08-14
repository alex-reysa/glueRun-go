#!/usr/bin/env node

// Browser-level contract for the shared Plan inspector. This speaks Chrome's
// DevTools protocol directly so the shell UI test stays dependency-free.

const [baseUrl, port] = process.argv.slice(2);
if (!baseUrl || !port) throw new Error("usage: plan_inspector_behavior.mjs <base-url> <debug-port>");
if (typeof WebSocket !== "function") throw new Error("this interaction contract requires a Node runtime with WebSocket support");

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const deadline = (ms, work) => Promise.race([
  work,
  new Promise((_, reject) => setTimeout(() => reject(new Error(`timed out after ${ms}ms`)), ms)),
]);

async function pageTarget() {
  for (let i = 0; i < 80; i += 1) {
    try {
      const targets = await fetch(`http://127.0.0.1:${port}/json/list`).then((response) => response.json());
      const target = targets.find((item) => item.type === "page" && item.webSocketDebuggerUrl);
      if (target) return target;
    } catch (_) {}
    await pause(50);
  }
  throw new Error("Chrome page target did not become available");
}

const target = await pageTarget();
const socket = new WebSocket(target.webSocketDebuggerUrl);
await deadline(5000, new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, { once: true });
  socket.addEventListener("error", reject, { once: true });
}));

let nextId = 0;
const pending = new Map();
socket.addEventListener("message", (event) => {
  const message = JSON.parse(String(event.data));
  if (!message.id || !pending.has(message.id)) return;
  const { resolve, reject } = pending.get(message.id);
  pending.delete(message.id);
  if (message.error) reject(new Error(message.error.message));
  else resolve(message.result || {});
});

function command(method, params = {}) {
  const id = ++nextId;
  const result = new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  socket.send(JSON.stringify({ id, method, params }));
  return deadline(5000, result);
}

async function evaluate(expression) {
  const response = await command("Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true,
  });
  if (response.exceptionDetails) {
    const text = response.exceptionDetails.exception?.description || response.exceptionDetails.text;
    throw new Error(text || "browser evaluation failed");
  }
  return response.result?.value;
}

async function waitFor(expression, description, timeout = 10000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    try {
      if (await evaluate(expression)) return;
    } catch (_) {}
    await pause(60);
  }
  throw new Error(`timed out waiting for ${description}`);
}

function check(condition, message) {
  if (!condition) throw new Error(message);
  console.log(`  ✓ ${message}`);
}

async function viewport(width, height) {
  await command("Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await pause(180);
}

const explicitPlanUrl = `${baseUrl.replace(/\/$/, "")}/?inspector-behavior=1#plan/dag/NODE:S1.inspector`;
await command("Runtime.enable");
await waitFor(
  `document.querySelector('#inspector[data-subject-kind="node"][data-presentation="dock"]') !== null`,
  "initial wide Plan dock",
);
await viewport(1680, 980);

// Seed the maximum supported wide preference in a fresh runtime. It must remain
// the preference even while the rendered dock is temporarily clamped.
await evaluate(`localStorage.setItem("singular.inspector.height", "560")`);
await command("Page.navigate", { url: explicitPlanUrl });
await waitFor(
  `document.querySelector('#inspector[data-subject-kind="node"][data-presentation="dock"]') !== null`,
  "reloaded wide Plan dock",
);
await waitFor(
  `document.getElementById('app').style.getPropertyValue('--inspector-height') === '560px'`,
  "560px preferred height",
);
check(await evaluate(`localStorage.getItem("singular.inspector.height") === "560"`), "wide dock preference is seeded at 560px");

// A dock becoming modal must pull focus inside only when focus would otherwise
// be stranded behind the modal scrim.
await evaluate(`document.querySelector('#surface-tabs [data-surface="plan"]').focus()`);
await viewport(700, 900);
await waitFor(`document.getElementById('inspector').dataset.presentation === "modal"`, "responsive modal conversion");
await pause(50);
check(await evaluate(`document.getElementById('inspector').contains(document.activeElement)`), "wide dock to narrow modal transfers outside focus inside");

// The title is the intentional initial-focus sentinel (tabindex=-1). Reverse
// tabbing from it must wrap to the last actual control instead of escaping.
const reverseTrap = await evaluate(`(() => {
  const inspector = document.getElementById('inspector');
  const title = document.getElementById('inspector-title');
  title.focus({ preventScroll: true });
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', shiftKey: true, bubbles: true, cancelable: true }));
  return { inside: inspector.contains(document.activeElement), activeId: document.activeElement.id, stayedOnSentinel: document.activeElement === title };
})()`);
check(reverseTrap.inside && !reverseTrap.stayedOnSentinel, "Shift+Tab from the title sentinel wraps within the modal");

// If focus is already on a viable inspector control, a presentation conversion
// must preserve it instead of resetting the user's position.
await viewport(1680, 980);
await waitFor(`document.getElementById('inspector').dataset.presentation === "dock"`, "wide dock restoration");
await evaluate(`document.getElementById('insp-collapse').focus({ preventScroll: true })`);
await viewport(700, 900);
await waitFor(`document.getElementById('inspector').dataset.presentation === "modal"`, "second responsive modal conversion");
await pause(50);
check(await evaluate(`document.activeElement?.id === "insp-collapse"`), "dock-to-modal conversion preserves focus already inside");

// A surface change can also turn the wide Plan dock into a modal. Focus begins
// on the clicked destination tab, so the same conditional transfer is required.
await viewport(1680, 980);
await waitFor(`document.getElementById('inspector').dataset.presentation === "dock"`, "wide dock before surface transition");
await evaluate(`(() => {
  const button = document.querySelector('#surface-tabs [data-surface="consoles"]');
  button.focus({ preventScroll: true });
  button.click();
})()`);
await waitFor(`document.getElementById('inspector').dataset.presentation === "modal"`, "non-Plan modal transition");
await pause(50);
check(await evaluate(`document.getElementById('inspector').contains(document.activeElement)`), "Plan to non-Plan modal transition transfers outside focus inside");

// Return to an explicit selected Plan route, then prove a short viewport clamps
// only the rendered row. The 560px preference must restore without reloading.
await command("Page.navigate", { url: explicitPlanUrl });
await waitFor(
  `document.querySelector('#inspector[data-subject-kind="node"][data-presentation="dock"]') !== null && document.getElementById('app').style.getPropertyValue('--inspector-height') === '560px'`,
  "preferred wide dock before clamp round trip",
);
await viewport(1680, 560);
const clamped = await evaluate(`({
  rendered: document.getElementById('app').style.getPropertyValue('--inspector-height'),
  preferred: localStorage.getItem('singular.inspector.height')
})`);
check(clamped.rendered !== "560px" && clamped.preferred === "560", "short viewport clamps rendering without overwriting preference");
await viewport(700, 560);
await waitFor(`document.getElementById('inspector').dataset.presentation === "modal"`, "short narrow modal");
await viewport(1680, 980);
await waitFor(`document.getElementById('inspector').dataset.presentation === "dock"`, "wide dock after responsive round trip");
check(await evaluate(`document.getElementById('app').style.getPropertyValue('--inspector-height') === '560px'`), "560px dock preference restores immediately after round trip");

// Header actions are the narrow drawer's primary controls and must be comfortable
// touch targets, independent of their compact visual icon.
await viewport(430, 900);
await waitFor(`document.getElementById('inspector').dataset.presentation === "modal"`, "narrow touch-target check");
const targets = await evaluate(`(() => {
  const box = (id) => { const rect = document.getElementById(id).getBoundingClientRect(); return { width: rect.width, height: rect.height }; };
  return { collapse: box('insp-collapse'), close: box('insp-close') };
})()`);
check(targets.collapse.width >= 40 && targets.collapse.height >= 40, "narrow collapse target is at least 40×40px");
check(targets.close.width >= 40 && targets.close.height >= 40, "narrow close target is at least 40×40px");

socket.close();
console.log("PASS: plan inspector browser behavior");
