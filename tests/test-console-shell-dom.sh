#!/usr/bin/env bash
set -uo pipefail

# 0.10.0: headless-Chrome DOM assertions over the console app shell + the rebuilt
# dependency-matrix lens. Hermetic like test-console-cli.sh: a mktemp fixture repo,
# a console server started on a free port and killed in the trap, and an isolated
# Chrome profile so a running browser can't clash. When no Google Chrome is present
# it prints a skip note and exits 0 (the DOM checks need a real renderer).

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLUERUN="$ENGINE_HOME/cli/gluerun"
export GLUERUN_ENGINE_HOME="$ENGINE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: test-console-shell-dom.sh — $*"; exit 0; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3"; }
assert_absent()   { [[ "$1" != *"$2"* ]] || fail "$3"; }

# --- locate Chrome (skip cleanly when absent, per plan) ------------------------
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ ! -x "$CHROME" ]]; then
  CHROME="$(command -v google-chrome || true)"
fi
[[ -n "$CHROME" && -x "$CHROME" ]] || skip "Google Chrome not found (headless DOM checks need it)"

[[ -f "$GLUERUN" ]] || fail "cli/gluerun not present: $GLUERUN"
[[ -f "$ENGINE_HOME/plugin/scripts/gluerun_graph_server.py" ]] \
  || fail "console server not present in this checkout"

tmp="$(mktemp -d)"
root="$tmp/repo"
cleanup() {
  # Kill the console the test started + any headless Chrome on our isolated
  # profile, then remove the fixture.
  local p="$root/.gluerun-state/console.pid"
  [[ -f "$p" ]] && kill "$(tr -d '[:space:]' < "$p" 2>/dev/null)" 2>/dev/null || true
  pkill -9 -f "$tmp/chrome-profile" 2>/dev/null || true
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

# --- fixture repo with an overflowing DAG --------------------------------------
# 36 nodes so the N×N grid overflows the small 900×600 window on both axes and the
# follow-diagonal toolbar is shown (hidden only when the grid fully fits).
mkdir -p "$root/.gluerun-state" "$root/docs/orchestration/tasks" "$root/docs/orchestration/gates"
git -C "$root" init -q
git -C "$root" checkout -q -b main
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat >"$root/gluerun.config.json" <<'EOF'
{"schemaVersion": "v1", "targetBranch": "main"}
EOF
python3 - "$root/docs/orchestration/dag.v0.json" <<'PY'
import json, sys
stages = ["S0", "S1", "S2", "S3", "S4", "S5"]
nodes, prev = [], None
for si, st in enumerate(stages):
    for i in range(6):                       # 6 stages x 6 = 36 nodes
        nid = "%s.node%d%d" % (st, si, i)
        nodes.append({"id": nid, "stage": st, "area": "core", "layer": "build",
                      "kind": "build", "dependsOn": ([prev] if prev else []),
                      "requiredCompletion": "done"})
        prev = nid                            # linear chain -> valid acyclic DAG
with open(sys.argv[1], "w") as fh:
    json.dump({"schema": "gluerun.orchestration.dag.v0", "nodes": nodes}, fh)
PY
cd "$root"

# --- start the console server (free port, detached; killed in the trap) --------
url="$("$GLUERUN" console --ensure)" \
  || fail "console --ensure failed; log tail: $(tail -5 "$root/.gluerun-state/console.log" 2>/dev/null)"
[[ "$url" == http://127.0.0.1:* ]] || fail "--ensure printed unexpected url: $url"

# --- headless DOM capture at #plan/matrix --------------------------------------
# --virtual-time-budget lets the SPA boot, poll /api/state, fetch /api/dag and
# build the matrix before the DOM is dumped; the small window forces the 36-node
# grid to overflow. The static shell (sidebar, header tabs) is present regardless
# of route, so one capture covers both the shell and the matrix assertions.
#   * `--headless=old`: new headless waits for network to go idle before dumping,
#     which never happens against the console's continuous 10s poll (it hangs);
#     old headless dumps at the virtual-time budget instead. If a future Chrome
#     drops old headless this will fail loudly rather than hang.
#   * Backgrounded with a hard-deadline watchdog: --dump-dom writes the serialized
#     DOM in one shot at exit, so a non-empty file means Chrome finished; the
#     deadline guarantees a wedged Chrome can never hang the suite.
dom="$tmp/matrix.html"
"$CHROME" --headless=old --disable-gpu --no-sandbox --disable-dev-shm-usage \
  --hide-scrollbars --user-data-dir="$tmp/chrome-profile" \
  --window-size=900,600 --virtual-time-budget=10000 \
  --run-all-compositor-stages-before-draw \
  --dump-dom "$url/#plan/matrix" >"$dom" 2>/dev/null &
cpid=$!
i=0
until [[ -s "$dom" ]] || ! kill -0 "$cpid" 2>/dev/null || [[ $i -ge 45 ]]; do sleep 1; i=$((i+1)); done
if kill -0 "$cpid" 2>/dev/null; then kill -9 "$cpid" 2>/dev/null; fi
wait "$cpid" 2>/dev/null || true          # reap quietly (suppress job-control notice)
pkill -9 -f "$tmp/chrome-profile" 2>/dev/null || true
[[ -s "$dom" ]] || fail "chrome produced no DOM output (waited ${i}s)"
html="$(cat "$dom")"

count() { grep -o "$1" "$dom" 2>/dev/null | grep -c . || true; }

# --- app-shell assertions ------------------------------------------------------
assert_contains "$html" 'id="side-bar"' "left app sidebar (#side-bar) missing"

# 0.12.0: the header tab row is gone; the surface tabs live in the sidebar as
# the active thread's vertical sub-menu (#thread-subnav, painted by plans.js).
assert_absent   "$html" 'id="surface-nav"'   "removed header #surface-nav still present"
assert_contains "$html" 'id="thread-subnav"' "thread sub-menu (#thread-subnav) missing"

# The sub-menu (and with it every data-surface button) must be nested inside
# #side-bar: 4 sub-menu rows + the 1 providers row in #side-nav, nothing else.
side="${html#*id=\"side-bar\"}"; side="${side%%</aside>*}"
assert_contains "$side" 'id="thread-subnav"' "#thread-subnav not nested inside #side-bar"
got="$(printf '%s' "$side" | grep -o 'data-surface=' | grep -c . || true)"
[[ "$got" -eq 5 ]] \
  || fail "expected 5 data-surface buttons inside #side-bar (4 sub-menu rows + providers), got $got"

got="$(count 'data-surface="providers"')"
[[ "$got" -eq 1 ]] || fail "expected data-surface=\"providers\" exactly once, got $got"

got="$(count 'data-surface=')"
[[ "$got" -eq 5 ]] \
  || fail "expected 5 data-surface buttons (4 sub-menu rows + 1 sidebar providers), got $got"

for s in home plan consoles agents; do
  got="$(count "data-surface=\"$s\"")"
  [[ "$got" -eq 1 ]] || fail "sub-menu row data-surface=\"$s\" not present exactly once (got $got)"
done

assert_absent "$html" "plan-switcher-select" "removed header plan-switcher-select still present"

# --- matrix (rebuilt lens) assertions ------------------------------------------
assert_contains "$html" "plan-mx-scroll" "matrix scroll container (plan-mx-scroll) missing — did #plan/matrix render?"
assert_contains "$html" "pm-corner"      "matrix sticky corner (pm-corner) missing"
assert_contains "$html" "pmrl-text"      "matrix two-line row label (pmrl-text) missing"
assert_absent   "$html" "pm-centered"    "obsolete pm-centered class still present"
assert_contains "$html" "pm-follow"      "follow-diagonal control (pm-follow) missing"

# The follow toolbar is rendered but gets a `hidden` attribute only when the grid
# fully fits; a hidden toolbar here means the 36-node grid did not overflow.
assert_absent "$html" 'pm-toolbar" hidden' "matrix toolbar hidden — grid did not overflow the 900x600 window"

echo "PASS: test-console-shell-dom.sh"
