#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$tmp" init -q repo
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
printf 'seed\n' >"$repo/seed.txt"
git -C "$repo" add seed.txt
git -C "$repo" commit -qm seed
git -C "$repo" branch -M canary-target
target_before="$(git -C "$repo" rev-parse canary-target)"
printf '{"schemaVersion":"v2","targetBranch":"canary-target","gateCommand":"true","runner":"missing-runner.sh","bootstrap":{"required":false,"commands":[]}}\n' >"$repo/singular.config.json"

# A fixture lifecycle must not hide a broken production adapter.  The default
# path checks that adapter and stops before lifecycle execution; --fixture
# explicitly replaces only that contract check, never the lifecycle itself.
if production_out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ROOT" bash "$ROOT/engine/campaign-canary.sh" --json)"; then
  echo "campaign canary accepted a missing production runner" >&2
  exit 1
fi
python3 - "$production_out" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["ok"] is False
assert data["failures"] == ["production-runner-contract"], data
assert data["providerInvoked"] is False
assert data["providerUnchecked"] is True
assert data["providerUncheckedWaived"] is False
assert data["lifecycle"]["covered"] is False
PY

# A conforming deterministic stub exercises the same bounded live-readonly
# invocation contract without any network access.
live_runner="$tmp/live-probe-runner.sh"
cat >"$live_runner" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--describe-contract" ]]; then
  printf '%s\n' '{"schema":"singular.runner-contract.v1","version":1,"provider":"codex","arguments":["--worktree","--prompt-file","--level","--run-id","--output-last-message","--role","--capability-profile","--result-file","--describe-contract"],"structuredResult":"singular.orchestration.runner-result.v0","structuredProviderError":"singular.orchestration.provider-error.v0"}'
  exit 0
fi
run_id=""; role=""; capability=""; result=""; output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) run_id="$2"; shift 2 ;;
    --role) role="$2"; shift 2 ;;
    --capability-profile) capability="$2"; shift 2 ;;
    --result-file) result="$2"; shift 2 ;;
    --output-last-message) output="$2"; shift 2 ;;
    --worktree|--prompt-file|--level) shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$run_id" && -n "$result" && -n "$output" && "$role" == "supervisor" ]]
printf '%s\n' '{"ok":true}' >"$output"
python3 - "$result" "$run_id" "$role" "$capability" "$output" <<'PY'
import json, sys
path, run_id, role, capability, output = sys.argv[1:]
json.dump({"schema":"singular.orchestration.runner-result.v0","contractVersion":1,"provider":"codex","runId":run_id,"role":role,"capabilityProfile":capability,"exitCode":0,"outcome":"succeeded","failureClass":"none","providerErrorRef":None,"outputRef":output,"recordedAt":"2026-08-30T00:00:00Z"}, open(path, "w", encoding="utf-8"))
PY
SH
chmod +x "$live_runner"
python3 - "$repo/singular.config.json" "$live_runner" <<'PY'
import json, sys
path, runner = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
data["runner"] = runner
json.dump(data, open(path, "w", encoding="utf-8"))
PY
live_out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ROOT" bash "$ROOT/engine/campaign-canary.sh" --json)"
python3 - "$live_out" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["ok"] is True, data
assert data["providerInvoked"] is True
assert data["providerUnchecked"] is False
assert data["providerUncheckedWaived"] is False
assert data["providerProbe"] == {"invoked": True, "state": "passed"}
assert "production-runner-live-readonly-probe" in data["checks"]
PY

out="$(cd "$repo" && SINGULAR_ENGINE_HOME="$ROOT" bash "$ROOT/engine/campaign-canary.sh" --fixture --json)"
python3 - "$out" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["schema"] == "singular.orchestration.campaign-canary.v1"
assert data["fixture"] is True
assert data["ok"] is True, data
assert data["providerInvoked"] is False
assert data["providerUnchecked"] is True
assert data["providerUncheckedWaived"] is True
expected = {
    "bash>=4",
    "fixture-runner-contract",
    "disposable-worktree-bootstrap",
    "fixture-runner-live-readonly-probe",
    "fixture-lifecycle-worker-gate-audit-evidence-import-integration",
}
assert expected <= set(data["checks"])
assert data["lifecycle"] == {
    "mode": "isolated-fixture-v1-runner",
    "providerInvoked": False,
    "providerUnchecked": True,
    "providerUncheckedWaived": True,
    "targetMutated": False,
    "covered": True,
    "auditVerification": "not-rerun-evidence-verified",
    "stages": ["worker", "gate", "accepted-audit", "evidence", "packet-import", "integration"],
}
PY
[[ "$(git -C "$repo" rev-parse canary-target)" == "$target_before" ]] || {
  echo "fixture lifecycle mutated the campaign target" >&2
  exit 1
}
echo "PASS campaign canary"
