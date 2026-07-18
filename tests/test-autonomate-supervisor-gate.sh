#!/usr/bin/env bash
set -euo pipefail

# 0.10.0: the autonomate loop grows a supervisor-briefing gate right after the
# STATUS write. It MUST be byte-inert when GLUERUN_SUPERVISOR_INTERVAL_MIN is
# unset/0 (a reconcile cycle then creates ZERO supervisor artifacts), and when
# enabled it must brief at most once per interval — stamping supervisor/last-run
# BEFORE spawning so an immediate next cycle cannot double-spawn.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-autonomate-supervisor-gate.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/.gluerun-state" "$root/docs/orchestration/prompts" \
  "$root/docs/orchestration/tasks" "$root/docs/orchestration/gates"
git -C "$root" init -q
git -C "$root" checkout -q -b target
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cp "$ENGINE_HOME/templates/prompts/supervisor.md" "$root/docs/orchestration/prompts/supervisor.md"
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{"schema":"gluerun.orchestration.dag.v0","layers":["scaffold"],"kinds":["build"],
 "nodes":[{"id":"M0.core","stage":"M0","area":"core","layer":"scaffold","kind":"build","dependsOn":[],"requiredCompletion":"scaffold_complete"}]}
EOF

# Reconcile stub: one clean, no-op cycle (no dispatch, no failure).
recon="$root/stub-reconcile.sh"
cat >"$recon" <<'SH'
#!/usr/bin/env bash
echo "dispatched_this_run=0"
echo "integrated_this_run=0"
echo "failed_dispatches=0"
echo "failed_integrations=0"
echo "planner_failures_this_run=0"
echo "l1_import_rejections_this_run=0"
SH
chmod +x "$recon"

# Runner stub for the (enabled) briefing: emits a valid report so supervise.sh
# fully completes in the background.
runner="$root/runner.sh"
cat >"$runner" <<'SH'
#!/usr/bin/env bash
out="" meta=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) out="$2"; shift 2 ;;
    --session-meta) meta="$2"; shift 2 ;;
    --level|-C|--run-id|--prompt-file|--resume-session) shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$meta" ]] && printf '{"schema":"gluerun.orchestration.session-meta.v0","provider":"fake","model":"f","effort":"low","exitCode":0}\n' >"$meta"
printf '%s\n' '{"schema":"gluerun.orchestration.supervisor-report.v0","stage":"idle","narrative":"Nothing to do."}' >"$out"
SH
chmod +x "$runner"

auto() {
  env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
    GLUERUN_ORCH_DIR="$root/docs/orchestration" GLUERUN_TASKS_DIR="$root/docs/orchestration/tasks" \
    GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson" GLUERUN_TARGET_BRANCH=target \
    GLUERUN_PUSH=0 GLUERUN_GENERATE=0 GLUERUN_RECONCILE_SCRIPT="$recon" GLUERUN_RUNNER="$runner" \
    "$@" bash "$SCRIPT_DIR/autonomate.sh" --once
}

sup_dir="$root/.gluerun-state/supervisor"
count_sup() { find "$root/.gluerun-state/runs" -maxdepth 1 -mindepth 1 -name 'SUP-*' -type d 2>/dev/null | grep -c . || true; }

# --- 1. knob unset -> byte-inert (ZERO supervisor artifacts) -----------------
auto </dev/null >/dev/null 2>&1
[[ -d "$sup_dir" ]] && fail "byte-inert violated: supervisor/ dir created with knob unset"
[[ "$(count_sup)" -eq 0 ]] || fail "byte-inert violated: a SUP run appeared with knob unset"

# --- 2. knob=1 -> exactly one briefing spawned + stamp -----------------------
auto GLUERUN_SUPERVISOR_INTERVAL_MIN=1 </dev/null >/dev/null 2>&1
[[ -f "$sup_dir/last-run" ]] || fail "last-run stamp not written when enabled"
stamp1="$(cat "$sup_dir/last-run")"
[[ "$stamp1" =~ ^[0-9]+$ ]] || fail "last-run stamp not numeric: $stamp1"
# The briefing spawns in the background; wait for its run dir to materialize.
for _ in $(seq 1 30); do
  [[ "$(count_sup)" -ge 1 ]] && break
  sleep 0.5
done
[[ "$(count_sup)" -eq 1 ]] || fail "expected exactly one SUP run, got $(count_sup)"

# --- 3. immediate second cycle -> NO respawn (interval gate holds) -----------
auto GLUERUN_SUPERVISOR_INTERVAL_MIN=1 </dev/null >/dev/null 2>&1
stamp2="$(cat "$sup_dir/last-run")"
[[ "$stamp2" == "$stamp1" ]] || fail "interval gate failed: stamp re-written within the interval ($stamp1 -> $stamp2)"
sleep 1
[[ "$(count_sup)" -eq 1 ]] || fail "double-spawn: expected one SUP run after a second cycle, got $(count_sup)"

echo "PASS: test-autonomate-supervisor-gate"
