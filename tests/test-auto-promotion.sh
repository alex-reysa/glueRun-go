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
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "singular.orchestration.dag.v0",
  "nodes": [
    {"id":"D1.contract","stage":"D1","area":"artifact","layer":"contract","kind":"contract","dependsOn":[],"requiredCompletion":"contract_complete"}
  ]
}
EOF
git -C "$root" add docs/orchestration/dag.v0.json
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

fake_promoter="$tmp/fake-promoter.sh"
cat >"$fake_promoter" <<'SH'
#!/usr/bin/env bash
echo "FAKE-PROMOTER argv:$*"
if [[ "${FAKE_PROMOTED:-0}" == "1" ]]; then
  echo "promoted node=D1.contract gate=fake log=fake"
  exit 0
fi
if [[ "${FAKE_GATE_TRANSITION:-0}" == "1" ]]; then
  cat >"$SINGULAR_ORCH_DIR/gates/D1.contract.gate-result.json" <<'EOF'
{"schema":"singular.orchestration.gate-result.v0","node":"D1.contract","status":"passed","authoritative":true,"evidenceClass":"grandfathered","evidence":[{"kind":"source-path","ref":"docs/orchestration/dag.v0.json"}],"decidedBy":"test-promoter","recordedAt":"2026-08-30T00:00:00Z"}
EOF
  echo "promoted node=D1.contract gate=real log=real"
  exit 0
fi
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

# Promoter stdout is not authority. A forged success line without an actual,
# schema-valid authoritative gate transition must count as zero.
out="$(common_env env FAKE_PROMOTED=1 "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
assert_contains "$out" "gates_promoted_this_run=0" "forged promoter stdout cannot report progress"

# A real false->true authoritative transition survives the reconcile summary
# boundary so autonomate can safely treat it as breaker-resetting progress.
out="$(common_env env FAKE_GATE_TRANSITION=1 "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
assert_contains "$out" "gates_promoted_this_run=1" "reconcile reports a validated direct gate transition"

# 2. Opt-out restores 0.4.0 silence.
out="$(common_env env SINGULAR_AUTO_PROMOTE_GATES=0 "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
assert_not_contains "$out" "attempting gate promotion" "opt-out suppresses the pass"

# 3. integrate.sh always reports the promotion counter (0 on an empty run).
out="$(common_env "$SCRIPT_DIR/integrate.sh" 2>&1 || true)"
assert_contains "$out" "gates_promoted_this_run=0" "integrate reports promotion counter"

echo "PASS: test-auto-promotion"
