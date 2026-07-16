#!/usr/bin/env bash
set -euo pipefail

# E6 (0.5.0): codex-run.sh wall-clock timeout + idle-output liveness guard.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$1' got '$2'"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/wt" "$tmp/state"
git -C "$tmp/wt" init -q
git -C "$tmp/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
target_branch="$(git -C "$tmp/wt" branch --show-current)"
printf 'hello\n' >"$tmp/prompt.md"

run_codex() {
  # args: env-pairs... — invokes codex-run with the fake codex on PATH
  env PATH="$tmp/bin:$PATH" GLUERUN_ROOT="$tmp/wt" GLUERUN_STATE_DIR="$tmp/state" GLUERUN_TARGET_BRANCH="$target_branch" "$@" \
    bash "$SCRIPT_DIR/codex-run.sh" --worktree "$tmp/wt" --level l2 --run-id RUN-T \
      --prompt-file "$tmp/prompt.md" >/dev/null 2>"$tmp/err.log"
}

# 1. Wall-clock timeout: fake codex hangs -> rc 124 fast, no orphans.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"t1"}'
sleep 60 &
child=$!
echo "$child" >"${CODEX_CHILD_FILE:-/dev/null}"
wait "$child"
SH
chmod +x "$tmp/bin/codex"
rc=0
CODEX_CHILD_FILE="$tmp/child.pid" run_codex env GLUERUN_CODEX_TIMEOUT_SEC=3 GLUERUN_CODEX_IDLE_SEC=0 CODEX_CHILD_FILE="$tmp/child.pid" || rc=$?
assert_eq "124" "$rc" "hung codex times out with rc 124"
grep -q "TIMED OUT" "$tmp/err.log" || fail "timeout reported on stderr"
if [[ -s "$tmp/child.pid" ]]; then
  child="$(cat "$tmp/child.pid")"
  sleep 0.3
  kill -0 "$child" 2>/dev/null && fail "grandchild survived the kill tree"
fi

# 2. Idle guard: output stalls -> rc 124; continuous output -> rc 0.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"t2"}'
sleep 30
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env GLUERUN_CODEX_TIMEOUT_SEC=60 GLUERUN_CODEX_IDLE_SEC=3 || rc=$?
assert_eq "124" "$rc" "stalled output is killed by the idle guard"
grep -q "IDLE" "$tmp/err.log" || fail "idle kill reported on stderr"

cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
for i in 1 2 3 4; do echo "{\"type\":\"tick\",\"n\":$i}"; sleep 1; done
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env GLUERUN_CODEX_TIMEOUT_SEC=60 GLUERUN_CODEX_IDLE_SEC=3 || rc=$?
assert_eq "0" "$rc" "steadily streaming run is never idle-killed"

# 3. Guards disabled: legacy path, exit propagates.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
echo '{"type":"done"}'
exit 7
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env GLUERUN_CODEX_TIMEOUT_SEC=0 GLUERUN_CODEX_IDLE_SEC=0 || rc=$?
assert_eq "7" "$rc" "disabled guards propagate the codex exit code"

echo "PASS: test-codex-run-timeout"
