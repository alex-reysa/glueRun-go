#!/usr/bin/env bash
set -uo pipefail

# Headless DOM contract for the Plan overview's progress instrument. The fixture
# is intentionally stopped: this is the safety state that must distinguish held
# dispatch from in-flight work and must remain readable at a narrow viewport.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SINGULAR="$ENGINE_HOME/cli/singular"
export SINGULAR_ENGINE_HOME="$ENGINE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: test-console-plan-overview-dom.sh — $*"; exit 0; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3"; }
assert_absent() { [[ "$1" != *"$2"* ]] || fail "$3"; }

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ ! -x "$CHROME" ]]; then CHROME="$(command -v google-chrome || true)"; fi
[[ -n "$CHROME" && -x "$CHROME" ]] || skip "Google Chrome not found"

tmp="$(mktemp -d)"
root="$tmp/repo"
cleanup() {
  local p="$root/.singular-state/console.pid"
  [[ -f "$p" ]] && kill "$(tr -d '[:space:]' < "$p" 2>/dev/null)" 2>/dev/null || true
  pkill -9 -f "$tmp/chrome-profile" 2>/dev/null || true
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$root/.singular-state" "$root/docs/orchestration/tasks" "$root/docs/orchestration/gates"
git -C "$root" init -q
git -C "$root" checkout -q -b main
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat >"$root/singular.config.json" <<'EOF'
{"schemaVersion":"v1","targetBranch":"main"}
EOF
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{"schema":"singular.orchestration.dag.v0","nodes":[
  {"id":"rel-00-contract","stage":"S0-contract","area":"foundation","layer":"contract","kind":"build","dependsOn":[],"requiredCompletion":"done"},
  {"id":"rel-04-evidence-remedy","stage":"S1-defect-fixes","area":"foundation","layer":"engine_runtime","kind":"build","dependsOn":["rel-00-contract"],"requiredCompletion":"done"}
]}
EOF
cat >"$root/.singular-state/STATUS.md" <<'EOF'
# singular Autonomous Status

Updated: 2026-08-14T20:00:00Z
Iteration: 7
Note: stopped (STOP sentinel)
STOP requested: yes

- integrations (lifetime): 3
EOF
touch "$root/.singular-state/STOP"
cd "$root"

url="$("$SINGULAR" console --ensure)" \
  || fail "console --ensure failed: $(tail -5 "$root/.singular-state/console.log" 2>/dev/null)"
[[ "$url" == http://127.0.0.1:* ]] || fail "unexpected console url: $url"

dom="$tmp/overview.html"
"$CHROME" --headless=old --disable-gpu --no-sandbox --disable-dev-shm-usage \
  --hide-scrollbars --user-data-dir="$tmp/chrome-profile" \
  --window-size=430,900 --virtual-time-budget=10000 \
  --run-all-compositor-stages-before-draw \
  --dump-dom "$url/#PLAN" >"$dom" 2>/dev/null &
cpid=$!
i=0
until [[ -s "$dom" ]] || ! kill -0 "$cpid" 2>/dev/null || [[ $i -ge 45 ]]; do sleep 1; i=$((i+1)); done
if kill -0 "$cpid" 2>/dev/null; then kill -9 "$cpid" 2>/dev/null; fi
wait "$cpid" 2>/dev/null || true
pkill -9 -f "$tmp/chrome-profile" 2>/dev/null || true
[[ -s "$dom" ]] || fail "Chrome produced no overview DOM (waited ${i}s)"
html="$(cat "$dom")"

assert_contains "$html" 'data-subject-kind="overview"' "#PLAN did not open the overview inspector"
assert_contains "$html" 'class="tab-panel ov-progress-panel" data-tab="progress" data-active="true"' "progress panel is not active"
assert_contains "$html" 'class="ov-summary" aria-label="Current campaign and control-loop state"' "campaign/control summary missing"
assert_contains "$html" 'role="progressbar" aria-label="Current campaign progress"' "campaign progressbar semantics missing"
assert_contains "$html" 'class="status-chip ov-exec-chip" data-tone="idle"' "stopped control state is not explicit"
assert_contains "$html" '>STOP sentinel</span>' "STOP sentinel reason missing"
assert_contains "$html" 'New dispatch is held; in-flight verification may still finish.' "STOP behavior explanation missing"
assert_contains "$html" 'class="pulse-stats"' "latest-signal telemetry ledger missing"
assert_contains "$html" 'class="ph-stage-code">S1</span><span class="ph-stage-name">defect fixes</span>' "phase label was not split into readable code and name"
assert_contains "$html" 'aria-label="Open rel-04-evidence-remedy · absent"' "phase node control lacks an accessible name"
assert_contains "$html" 'aria-label="frontier held"' "stopped frontier is still described as active work"
assert_absent "$html" 'stopped — stopped' "duplicated stopped reason returned"
assert_absent "$html" 'where the loop is grinding now' "misleading active-work copy returned"

echo "PASS: test-console-plan-overview-dom.sh"
