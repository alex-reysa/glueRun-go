#!/usr/bin/env bash
# singular-test: serial — asserts wall-clock bounds (a detached cycle must return before
# its stubs finish / a headless browser must settle focus) that a loaded machine breaks.
set -uo pipefail

# Shared Plan inspector contract: one detail primitive, wide bottom dock, narrow
# modal drawer, and task/node deep links over a hermetic console fixture.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SINGULAR="$ENGINE_HOME/cli/singular"
export SINGULAR_ENGINE_HOME="$ENGINE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: test-console-plan-inspector-dock.sh — $*"; exit 0; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3"; }
assert_absent() { [[ "$1" != *"$2"* ]] || fail "$3"; }

# Static ownership guard: Plan no longer carries a second right-side renderer.
index="$(<"$ENGINE_HOME/plugin/assets/index.html")"
workbench="$(<"$ENGINE_HOME/plugin/assets/plan/workbench.js")"
styles="$(<"$ENGINE_HOME/plugin/assets/styles.css")"
app_js="$(<"$ENGINE_HOME/plugin/assets/app.js")"
tasks_lens="$(<"$ENGINE_HOME/plugin/assets/plan/lens_tasks.js")"
timeline_lens="$(<"$ENGINE_HOME/plugin/assets/plan/lens_timeline.js")"

assert_absent "$index" 'id="plan-aside"' "duplicate Plan right aside returned"
assert_absent "$workbench" "renderAside" "workbench still renders duplicate node detail"
assert_contains "$index" 'id="inspector-grip" type="button"' "resize control missing"
assert_contains "$index" 'role="separator"' "keyboard resize separator semantics missing"
assert_contains "$index" 'id="insp-collapse"' "independent collapse control missing"
assert_contains "$styles" '"side inspector"' "app grid does not reserve the shared bottom row"
assert_contains "$styles" '#inspector[data-presentation="dock"]' "wide dock presentation missing"
assert_contains "$workbench" 'select("node", selectedNodeId, { fromPlan: true })' "Plan node selection does not reuse the rich inspector"
assert_contains "$tasks_lens" 'data-open-task=' "Tasks lens lacks a keyboard task control"
assert_contains "$timeline_lens" 'bar.focus({ preventScroll: true })' "Timeline task focus origin is not preserved"
assert_contains "$app_js" 'const activeIndex = focusable.indexOf(document.activeElement)' "modal focus trap does not handle a non-tabbable sentinel"
assert_contains "$app_js" 'wasDocked && !docked' "dock-to-modal focus transfer guard is missing"
assert_contains "$app_js" 'preferredInspectorHeight' "preferred dock height is not separate from its responsive clamp"
assert_contains "$styles" '#insp-collapse, #insp-close { width: 40px; height: 40px; }' "narrow inspector header controls are below the 40px touch target"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ ! -x "$CHROME" ]]; then CHROME="$(command -v google-chrome || true)"; fi
[[ -n "$CHROME" && -x "$CHROME" ]] || skip "Google Chrome not found"

tmp="$(mktemp -d)"
root="$tmp/repo"
cleanup() {
  local p="$root/.singular-state/console.pid"
  [[ -f "$p" ]] && kill "$(tr -d '[:space:]' < "$p" 2>/dev/null)" 2>/dev/null || true
  pkill -9 -f "$tmp/chrome-" 2>/dev/null || true
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$root/.singular-state/leases" "$root/.singular-state/dispatch" \
  "$root/docs/orchestration/tasks" "$root/docs/orchestration/gates"
git -C "$root" init -q
git -C "$root" checkout -q -b main
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat >"$root/singular.config.json" <<'EOF'
{"schemaVersion":"v1","targetBranch":"main"}
EOF
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{"schema":"singular.orchestration.dag.v0","nodes":[
  {"id":"S0.contract","stage":"S0-contract","area":"console","layer":"contract","kind":"build","dependsOn":[],"requiredCompletion":"done"},
  {"id":"S1.inspector","stage":"S1-interface","area":"console","layer":"interface","kind":"build","dependsOn":["S0.contract"],"requiredCompletion":"verified","description":"One shared bottom detail dock."}
]}
EOF
cat >"$root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Verify the shared Plan inspector

Status: active
Area: console
DAG node: S1.inspector
Target branch: `main`
Worker branch: `agent/console/TASK-0001-inspector`
Test policy: red-green
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Keep one selected-object detail panel across every Plan view.

## Acceptance Criteria

- Wide Plan uses the full-width bottom dock.
- Narrow Plan uses the accessible modal drawer.
EOF
cat >"$root/.singular-state/leases/TASK-0001.json" <<'EOF'
{"taskId":"TASK-0001","status":"active","area":"console","branch":"agent/console/TASK-0001-inspector","runId":"RUN-1","createdAt":"2026-08-14T18:00:00Z","updatedAt":"2026-08-14T18:05:00Z"}
EOF
cat >"$root/.singular-state/dispatch/TASK-0001.json" <<'EOF'
{"taskId":"TASK-0001","state":"launched","runId":"RUN-1","startedAt":"2026-08-14T18:00:00Z"}
EOF
cd "$root"

url="$("$SINGULAR" console --ensure)" \
  || fail "console --ensure failed: $(tail -5 "$root/.singular-state/console.log" 2>/dev/null)"
[[ "$url" == http://127.0.0.1:* ]] || fail "unexpected console url: $url"

capture() {
  local name="$1" size="$2" route="$3"
  local dom="$tmp/$name.html" profile="$tmp/chrome-$name"
  "$CHROME" --headless=old --disable-gpu --no-sandbox --disable-dev-shm-usage \
    --hide-scrollbars --user-data-dir="$profile" --window-size="$size" \
    --virtual-time-budget=10000 --run-all-compositor-stages-before-draw \
    --dump-dom "$url/$route" >"$dom" 2>/dev/null &
  local cpid=$! i=0
  until [[ -s "$dom" ]] || ! kill -0 "$cpid" 2>/dev/null || [[ $i -ge 45 ]]; do sleep 1; i=$((i+1)); done
  if kill -0 "$cpid" 2>/dev/null; then kill -9 "$cpid" 2>/dev/null; fi
  wait "$cpid" 2>/dev/null || true
  pkill -9 -f "$profile" 2>/dev/null || true
  [[ -s "$dom" ]] || fail "Chrome produced no $name DOM (waited ${i}s)"
}

capture wide 1680,980 '#plan/dag/NODE:S1.inspector'
capture narrow 430,900 '#plan/tasks/TASK-0001'
wide="$(<"$tmp/wide.html")"
narrow="$(<"$tmp/narrow.html")"

wide_tail="${wide#*id=\"inspector\"}"
[[ "$wide_tail" != "$wide" ]] || fail "wide inspector missing"
wide_open="${wide_tail%%>*}"
assert_contains "$wide_open" 'data-subject-kind="node"' "wide node deep link did not resolve"
assert_contains "$wide_open" 'data-presentation="dock"' "wide Plan detail is not docked"
assert_contains "$wide_open" 'role="region"' "wide dock lacks region semantics"
assert_absent "$wide_open" 'aria-modal=' "wide dock incorrectly claims modal semantics"
assert_contains "$wide" 'id="inspector-scrim" data-open="false"' "wide dock opened a scrim"
assert_contains "$wide" '>S1.inspector</span>' "wide node detail did not render"

narrow_tail="${narrow#*id=\"inspector\"}"
[[ "$narrow_tail" != "$narrow" ]] || fail "narrow inspector missing"
narrow_open="${narrow_tail%%>*}"
assert_contains "$narrow_open" 'data-subject-kind="l2"' "narrow task deep link did not resolve"
assert_contains "$narrow_open" 'data-presentation="modal"' "narrow Plan detail is not a drawer"
assert_contains "$narrow_open" 'role="dialog"' "narrow drawer lacks dialog semantics"
assert_contains "$narrow_open" 'aria-modal="true"' "narrow drawer lacks modal semantics"
assert_contains "$narrow" 'id="inspector-scrim" data-open="true"' "narrow drawer scrim is closed"
assert_contains "$narrow" 'data-open-task="TASK-0001"' "Tasks lens keyboard control missing at runtime"
assert_contains "$narrow" '>TASK-0001</span>' "narrow task detail did not render"

# Interaction contract: focus containment across presentation changes, responsive
# height preference restoration, and narrow touch geometry.
behavior_profile="$tmp/chrome-behavior"
"$CHROME" --headless=old --disable-gpu --no-sandbox --disable-dev-shm-usage \
  --hide-scrollbars --remote-debugging-address=127.0.0.1 --remote-debugging-port=0 \
  --user-data-dir="$behavior_profile" --window-size=1680,980 \
  "$url/#plan/dag/NODE:S1.inspector" >/dev/null 2>&1 &
behavior_pid=$!
i=0
until [[ -s "$behavior_profile/DevToolsActivePort" ]] || ! kill -0 "$behavior_pid" 2>/dev/null || [[ $i -ge 80 ]]; do
  sleep 0.1
  i=$((i+1))
done
[[ -s "$behavior_profile/DevToolsActivePort" ]] || fail "Chrome behavior endpoint did not start"
debug_port="$(sed -n '1p' "$behavior_profile/DevToolsActivePort")"
node "$ENGINE_HOME/tests/console/plan_inspector_behavior.mjs" "$url" "$debug_port" \
  || fail "Plan inspector browser behavior contract failed"
kill "$behavior_pid" 2>/dev/null || true
wait "$behavior_pid" 2>/dev/null || true

echo "PASS: test-console-plan-inspector-dock.sh"
