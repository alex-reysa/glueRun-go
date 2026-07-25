#!/usr/bin/env bash
set -euo pipefail

# E10 (0.5.0): interruptible naps (STOP/WAKE/backoff-clear honored mid-sleep)
# and `autonomate.sh --detach` (supported daemonized launch).

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-autonomate-lifecycle.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/.gluerun-state" "$root/docs/orchestration/tasks"
git -C "$root" init -q
git -C "$root" checkout -q -b target
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

env_common() {
  env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
    GLUERUN_ORCH_DIR="$root/docs/orchestration" GLUERUN_TASKS_DIR="$root/docs/orchestration/tasks" \
    GLUERUN_EVENTS_FILE="$root/.gluerun-state/events.ndjson" \
    GLUERUN_TARGET_BRANCH=target GLUERUN_PUSH=0 GLUERUN_SLEEP_POLL_SEC=1 "$@"
}

# --- 1. gluerun_interruptible_sleep unit behavior ---------------------------
lib_sleep() {
  env_common bash -c "source '$SCRIPT_DIR/lib.sh'; $1"
}

start=$SECONDS
( sleep 2 && touch "$root/.gluerun-state/WAKE" ) &
rc=0; lib_sleep "gluerun_interruptible_sleep 30" || rc=$?
elapsed=$((SECONDS - start))
[[ "$rc" -eq 1 ]] || fail "WAKE should end the nap with rc 1 (rc=$rc)"
[[ "$elapsed" -lt 10 ]] || fail "WAKE should end the nap early (took ${elapsed}s)"
[[ -f "$root/.gluerun-state/WAKE" ]] && fail "WAKE file must be consumed"

( sleep 2 && touch "$root/.gluerun-state/STOP" ) &
rc=0; lib_sleep "gluerun_interruptible_sleep 30" || rc=$?
[[ "$rc" -eq 2 ]] || fail "STOP should end the nap with rc 2 (rc=$rc)"
rm -f "$root/.gluerun-state/STOP"

# watch_backoff: clearing the backoff ends the nap.
printf '%s\n' \
  '{"schema":"gluerun.orchestration.planner-backoff.v0","failureClass":"quota","until":"2999-01-01T00:00:00Z"}' \
  >"$root/.gluerun-state/planner-backoff.json"
( sleep 2 && rm -f "$root/.gluerun-state/planner-backoff.json" ) &
rc=0; lib_sleep "gluerun_interruptible_sleep 30 1" || rc=$?
[[ "$rc" -eq 1 ]] || fail "backoff clear should end a watched nap (rc=$rc)"

# --- 2. --detach: parent returns fast, loop runs, STOP ends it --------------
stub="$root/stub-reconcile.sh"
cat >"$stub" <<'SH'
#!/usr/bin/env bash
echo "dispatched_this_run=0"
echo "integrated_this_run=1"
echo "failed_dispatches=0"
echo "failed_integrations=0"
echo "planner_failures_this_run=0"
echo "l1_import_rejections_this_run=0"
SH
chmod +x "$stub"

out="$(env_common GLUERUN_RECONCILE_SCRIPT="$stub" GLUERUN_SLEEP=2 \
  bash "$SCRIPT_DIR/autonomate.sh" --detach 2>&1)"
assert_contains "$out" "detached pid=" "detach reports the pid"
pid="$(sed -n 's/.*detached pid=\([0-9]*\).*/\1/p' <<<"$out")"
kill -0 "$pid" 2>/dev/null || fail "detached loop not alive"
[[ "$(cat "$root/.gluerun-state/autonomate.pid")" == "$pid" ]] || fail "pidfile owned by detached loop"

# Second --detach is a no-op while running.
out2="$(env_common GLUERUN_RECONCILE_SCRIPT="$stub" GLUERUN_SLEEP=2 \
  bash "$SCRIPT_DIR/autonomate.sh" --detach 2>&1)"
assert_contains "$out2" "already running" "second detach refuses"

# STOP written mid-nap ends the detached loop within a few poll chunks.
touch "$root/.gluerun-state/STOP"
for _ in $(seq 1 20); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done
kill -0 "$pid" 2>/dev/null && { kill "$pid"; fail "STOP did not end the detached loop"; }
[[ -f "$root/.gluerun-state/autonomate.pid" ]] && fail "pidfile must be removed on exit"
grep -q "STOP sentinel" "$root/.gluerun-state/autonomate.log" || fail "loop logged the STOP halt"

echo "PASS: test-autonomate-lifecycle"
