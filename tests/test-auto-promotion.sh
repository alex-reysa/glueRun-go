#!/usr/bin/env bash
set -euo pipefail

# P3 (0.5.0): SINGULAR_AUTO_PROMOTE_GATES defaults ON — the reconcile
# empty-queue pass invokes the promoter WITHOUT the env being set (0.4.0
# default 0 + a dispatch-budget condition meant it effectively never fired),
# and integrate.sh emits the gates_promoted_this_run counter.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-auto-promotion.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/gates" "$root/.singular-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

fake_promoter="$tmp/fake-promoter.sh"
cat >"$fake_promoter" <<'SH'
#!/usr/bin/env bash
echo "FAKE-PROMOTER argv:$*"
echo "no promotable frontier gates"
SH
chmod +x "$fake_promoter"

common_env() {
  env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks" \
    SINGULAR_LEASES_DIR="$root/.singular-state/leases" SINGULAR_INBOX_DIR="$root/.singular-state/inbox" \
    SINGULAR_RUNS_DIR="$root/.singular-state/runs" SINGULAR_WORKTREES_DIR="$root/.worktrees" \
    SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_PUSH=0 SINGULAR_GENERATE=0 \
    SINGULAR_PROMOTER="$fake_promoter" "$@"
}

# 1. Default env (no SINGULAR_AUTO_PROMOTE_GATES): empty-queue reconcile pass
#    attempts promotion via the configured promoter.
out="$(common_env "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
assert_contains "$out" "attempting gate promotion" "empty-queue pass fires by default"
assert_contains "$out" "FAKE-PROMOTER argv:--from-reconcile --frontier" "configured promoter invoked"

# 2. Opt-out restores 0.4.0 silence.
out="$(common_env env SINGULAR_AUTO_PROMOTE_GATES=0 "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
assert_not_contains "$out" "attempting gate promotion" "opt-out suppresses the pass"

# 3. integrate.sh always reports the promotion counter (0 on an empty run).
out="$(common_env "$SCRIPT_DIR/integrate.sh" 2>&1 || true)"
assert_contains "$out" "gates_promoted_this_run=0" "integrate reports promotion counter"

echo "PASS: test-auto-promotion"
