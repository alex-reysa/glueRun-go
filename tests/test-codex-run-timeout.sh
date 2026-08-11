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
  env PATH="$tmp/bin:$PATH" SINGULAR_ROOT="$tmp/wt" SINGULAR_STATE_DIR="$tmp/state" SINGULAR_TARGET_BRANCH="$target_branch" "$@" \
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
CODEX_CHILD_FILE="$tmp/child.pid" run_codex env SINGULAR_CODEX_TIMEOUT_SEC=3 SINGULAR_CODEX_IDLE_SEC=0 CODEX_CHILD_FILE="$tmp/child.pid" || rc=$?
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
run_codex env SINGULAR_CODEX_TIMEOUT_SEC=60 SINGULAR_CODEX_IDLE_SEC=3 || rc=$?
assert_eq "124" "$rc" "stalled output is killed by the idle guard"
grep -q "IDLE" "$tmp/err.log" || fail "idle kill reported on stderr"

cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
for i in 1 2 3 4; do echo "{\"type\":\"tick\",\"n\":$i}"; sleep 1; done
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env SINGULAR_CODEX_TIMEOUT_SEC=60 SINGULAR_CODEX_IDLE_SEC=3 || rc=$?
assert_eq "0" "$rc" "steadily streaming run is never idle-killed"

# 3. Guards disabled: legacy path, exit propagates.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
echo '{"type":"done"}'
exit 7
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env SINGULAR_CODEX_TIMEOUT_SEC=0 SINGULAR_CODEX_IDLE_SEC=0 \
  SINGULAR_CODEX_COMPLETION_GRACE_SEC=0 || rc=$?
assert_eq "7" "$rc" "disabled guards propagate the codex exit code"

# 4. A parsed terminal completion event starts a grace period. If Codex remains
# alive, its whole process tree is cleaned up while the completed run stays
# successful and its already-written last-message artifact remains intact.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
out_file=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "-o" ]] && out_file="$arg"
  prev="$arg"
done
[[ -n "$out_file" ]] && printf '%s\n' '{"status":"accepted"}' >"$out_file"
echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
sleep 60 &
child=$!
echo "$child" >"${CODEX_CHILD_FILE:-/dev/null}"
wait "$child"
SH
chmod +x "$tmp/bin/codex"
rc=0
started="$SECONDS"
CODEX_CHILD_FILE="$tmp/completed-child.pid" run_codex env \
  SINGULAR_CODEX_TIMEOUT_SEC=60 SINGULAR_CODEX_IDLE_SEC=60 \
  SINGULAR_CODEX_COMPLETION_GRACE_SEC=1 SINGULAR_PROVIDER_KILL_GRACE_SEC=1 \
  CODEX_CHILD_FILE="$tmp/completed-child.pid" || rc=$?
elapsed=$(( SECONDS - started ))
assert_eq "0" "$rc" "semantically completed hung codex exits successfully"
(( elapsed < 10 )) || fail "semantic completion cleanup took too long (${elapsed}s)"
grep -q "semantic completion observed" "$tmp/err.log" \
  || fail "semantic completion was not reported"
grep -q "completion grace expired" "$tmp/err.log" \
  || fail "completion grace cleanup was not reported"
grep -q '"status":"accepted"' "$tmp/state/runs/RUN-T/last-message.json" \
  || fail "last-message artifact was not preserved after completion cleanup"
if [[ -s "$tmp/completed-child.pid" ]]; then
  child="$(cat "$tmp/completed-child.pid")"
  sleep 0.3
  kill -0 "$child" 2>/dev/null && fail "completed provider grandchild survived cleanup"
fi

# 5. Prose and non-terminal/malformed JSON that merely mention the event name
# must not bypass ordinary timeout behavior.
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
echo 'provider log mentions {"type":"turn.completed"} but is not JSON'
echo 'provider log mentions {"type":"turn.failed","error":{"message":"no"}} but is not JSON'
echo '{"type":"item.completed","message":"turn.completed"}'
echo '{"type":"item.completed","item":{"type":"turn.failed","error":{"message":"nested"}}}'
echo '{"type":["turn.completed"]}'
echo '{"type":"turn.completed"'
sleep 60
SH
chmod +x "$tmp/bin/codex"
rc=0
run_codex env SINGULAR_CODEX_TIMEOUT_SEC=3 SINGULAR_CODEX_IDLE_SEC=0 \
  SINGULAR_CODEX_COMPLETION_GRACE_SEC=1 || rc=$?
assert_eq "124" "$rc" "completion mentions do not bypass wall timeout"
grep -q "TIMED OUT" "$tmp/err.log" || fail "ordinary timeout was not reported"
if grep -q "semantic completion observed" "$tmp/err.log"; then
  fail "malformed/prose completion mention triggered semantic completion"
fi

# 6. ps-denied sandbox (PMGO-004). The old cleanup built its target list from
# `ps -A` and ignored its exit status: where process enumeration is denied the
# list came back empty, only the direct child was signalled, the provider's
# descendants survived the timeout — and nothing said so. The provider pipeline
# now runs as its own session leader, so one negative pid reaches the whole tree
# with no `ps` involved, and the cleanup proves it rather than assuming it.
mkdir -p "$tmp/psdeny"
cat >"$tmp/psdeny/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$tmp/psdeny/ps"
cat >"$tmp/bin/codex" <<'SH'
#!/usr/bin/env bash
echo '{"type":"thread.started","thread_id":"t6"}'
sleep 60 &
child=$!
echo "$child" >"${CODEX_CHILD_FILE:-/dev/null}"
wait "$child"
SH
chmod +x "$tmp/bin/codex"
: >"$tmp/psdenied-child.pid"
rc=0
env PATH="$tmp/psdeny:$tmp/bin:$PATH" SINGULAR_ROOT="$tmp/wt" SINGULAR_STATE_DIR="$tmp/state" \
  SINGULAR_TARGET_BRANCH="$target_branch" \
  SINGULAR_CODEX_TIMEOUT_SEC=3 SINGULAR_CODEX_IDLE_SEC=0 \
  SINGULAR_PROVIDER_KILL_GRACE_SEC=1 CODEX_CHILD_FILE="$tmp/psdenied-child.pid" \
  bash "$SCRIPT_DIR/codex-run.sh" --worktree "$tmp/wt" --level l2 --run-id RUN-PSDENY \
    --prompt-file "$tmp/prompt.md" >/dev/null 2>"$tmp/err.log" || rc=$?
assert_eq "124" "$rc" "ps-denied hung codex still times out with rc 124"
grep -q "TIMED OUT" "$tmp/err.log" || fail "ps-denied timeout was not reported on stderr"
[[ -s "$tmp/psdenied-child.pid" ]] || fail "ps-denied case: fake codex never spawned its grandchild"
child="$(cat "$tmp/psdenied-child.pid")"
sleep 0.3
kill -0 "$child" 2>/dev/null && fail "grandchild survived the kill with ps denied"
grep -q "UNVERIFIED" "$tmp/err.log" && fail "session kill reported UNVERIFIED although the group was proven"

echo "PASS: test-codex-run-timeout"
