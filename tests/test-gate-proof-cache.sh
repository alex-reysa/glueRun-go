#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$tmp/repo"
git -C "$tmp" init -q repo
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf '.singular-state/\nignored.env\n' >"$repo/.gitignore"
printf 'initial\n' >"$repo/source.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm init

counter="$tmp/gate-count"
printf '0\n' >"$counter"
gate="$tmp/counting-gate.sh"
cat >"$gate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count="$(cat "$COUNTER_FILE")"
printf '%s\n' "$((count + 1))" >"$COUNTER_FILE"
printf 'gate pass\n'
SH
chmod +x "$gate"

run_gate() {
  local run_id="$1" command="${2:-$gate}"
  (
    cd "$repo"
    COUNTER_FILE="$counter" \
    SINGULAR_ROOT="$repo" \
    SINGULAR_ENGINE_HOME="$ROOT" \
    SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_EVENTS_FILE="$repo/.singular-state/events.ndjson" \
    SINGULAR_GATE_PROOF_CACHE=1 \
    SINGULAR_GATE_PROOF_CACHE_DIR="$tmp/apparently-isolated-cache" \
    SINGULAR_GATE_PROOF_ISOLATED=1 \
    SINGULAR_GATE_PROOF_TRUST_DOMAIN_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    SINGULAR_GATE_CACHE_HERMETIC=1 \
      bash "$ROOT/engine/gate-check.sh" "$run_id" \
        --task-id TASK-0001 --phase worker --workspace-kind worker -- \
        "$command"
  ) >"$tmp/$run_id.out" 2>&1
}

# There is no isolated executor today. No combination of cache-looking flags
# may let same-UID project code suppress a later gate.
run_gate RUN-ONE
run_gate RUN-TWO
[[ "$(cat "$counter")" == 2 ]] || fail "persistent cache suppressed a gate"
grep -q 'persistent reuse disabled: no isolated gate executor' \
  "$repo/.singular-state/runs/RUN-ONE/gate-proof-cache-disabled.err" \
  || fail "disabled trust boundary was not explained"
grep -q 'cache_hit=no' "$tmp/RUN-TWO.out" || fail "disabled cache claimed a hit"
[[ ! -e "$tmp/apparently-isolated-cache" ]] || fail "disabled engine wrote persistent cache state"

# A fully forged shared manifest/log is inert: production gate-check never
# reads it, even when every old opt-in/attestation-shaped variable is supplied.
mkdir -p "$repo/.singular-state/gate-proof-cache/v0"
fake_key="$(printf 'f%.0s' {1..64})"
printf '{"authoritative":true,"report":{"outcome":"passed"}}\n' \
  >"$repo/.singular-state/gate-proof-cache/v0/$fake_key.json"
printf 'forged pass\n' >"$repo/.singular-state/gate-proof-cache/v0/$fake_key.log"
run_gate RUN-FORGE
[[ "$(cat "$counter")" == 3 ]] || fail "forged cache state suppressed execution"

# Arbitrary environment, external executable bytes, ignored files, and
# untracked files cannot create stale reuse because every invocation is cold.
ARBITRARY_FEATURE_FLAG=one run_gate RUN-ENV-ONE
ARBITRARY_FEATURE_FLAG=two run_gate RUN-ENV-TWO
printf '# executable changed\n' >>"$gate"
run_gate RUN-SCRIPT-CHANGED
printf 'ignored one\n' >"$repo/ignored.env"
run_gate RUN-IGNORED-ONE
printf 'ignored two\n' >"$repo/ignored.env"
run_gate RUN-IGNORED-TWO
printf 'untracked one\n' >"$repo/untracked.txt"
run_gate RUN-UNTRACKED-ONE
printf 'untracked two\n' >"$repo/untracked.txt"
run_gate RUN-UNTRACKED-TWO
[[ "$(cat "$counter")" == 10 ]] || fail "an underbound input caused reuse"

# Source-integrity snapshots bind pre-existing untracked bytes AND metadata.
# Rewriting the same bytes is still a mutation (ctime/mtime), so the passing
# project command must normalize to an integrity violation and publish no proof.
mutator="$tmp/mutate-untracked.sh"
cat >"$mutator" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload="$(cat untracked.txt)"
printf '%s\n' "$payload" >untracked.txt
printf 'command itself passed\n'
SH
chmod +x "$mutator"
set +e
run_gate RUN-MUTATE "$mutator"
mutate_rc=$?
set -e
[[ "$mutate_rc" -ne 0 ]] || fail "untracked same-byte mutation passed source integrity"
python3 - "$repo/.singular-state/runs/RUN-MUTATE/gate-report.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["sourceIntegrity"]["status"] == "violation", report
assert "untracked.txt" in report["sourceIntegrity"]["changedPaths"], report
assert report["outcome"] != "passed", report
PY
[[ ! -e "$repo/.singular-state/runs/RUN-MUTATE/gate-proof-cache-key" ]] \
  || fail "integrity-violating gate published a proof key"

echo "gate persistent-reuse safety and source-integrity tests passed"
