#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
run="$repo/.gluerun-state/runs/RUN-evidence"
mkdir -p "$repo/src" "$run/worker-evidence"
git -C "$tmp" init -q repo
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf 'old\n' >"$repo/src/value.txt"
git -C "$repo" add src/value.txt
git -C "$repo" commit -qm base
base="$(git -C "$repo" rev-parse HEAD)"
printf 'new\n' >"$repo/src/value.txt"
git -C "$repo" add src/value.txt
git -C "$repo" commit -qm change
head="$(git -C "$repo" rev-parse HEAD)"

python3 - "$run/worker-evidence/huge.log" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text("assertion: " + ("x" * 10000), encoding="utf-8")
PY
cp "$run/worker-evidence/huge.log" "$run/gate-check.log"
printf 'scope clean\n' >"$run/scope-check.log"
printf 'secret log exists but has no structured result\n' >"$run/secret-scan.log"
cat >"$run/packet.json" <<'JSON'
{
  "commands": [
    {
      "cmd": "run tests",
      "exitCode": 1,
      "logRef": "worker-evidence/huge.log"
    }
  ]
}
JSON
command_sha="$(printf '%s' 'run tests' | shasum -a 256 | awk '{print $1}')"
cat >"$run/gate-observation.json" <<'JSON'
{
  "schema": "gluerun.orchestration.gate-observation.v0",
  "failures": [{"signature": "known"}]
}
JSON
cat >"$run/gate-baseline.json" <<JSON
{
  "schema": "gluerun.orchestration.gate-baseline.v0",
  "commandSha256": "$command_sha",
  "failures": [{"signature": "known"}],
  "acknowledgedBy": "owner",
  "recordedAt": "2026-07-24T10:00:00Z"
}
JSON
python3 "$ROOT/engine/gate_report.py" \
  --task-id TASK-0001 --run-id RUN-evidence --head-sha "$head" \
  --command "run tests" --raw-exit-code 1 \
  --log-ref "$run/gate-check.log" --log-path "$run/gate-check.log" \
  --observation "$run/gate-observation.json" --baseline "$run/gate-baseline.json" \
  --integrity-status verified --phase worker --workspace-kind worker \
  --output "$run/gate-report.json" >/dev/null
GLUERUN_ROOT="$repo" GLUERUN_STATE_DIR="$repo/.gluerun-state" \
  bash -c 'source "$1"; gluerun_check_result_write "$2" scope passed 0 "$3"' \
  _ "$ROOT/engine/lib.sh" "$run/scope-check-result.json" "$run/scope-check.log"
cat >"$run/worker-runner-result.json" <<'JSON'
{
  "schema": "gluerun.orchestration.runner-result.v0",
  "usage": {
    "inputTokens": 4200,
    "cachedInputTokens": 1000,
    "outputTokens": 300
  }
}
JSON
cat >"$run/auditor-attempt-1-try-0-runner-result.json" <<'JSON'
{
  "schema": "gluerun.orchestration.runner-result.v0",
  "role": "auditor",
  "usage": {
    "inputTokens": 8000,
    "cachedInputTokens": 2000,
    "outputTokens": 500
  }
}
JSON

evidence_config='{"maxComposedBytes":65536,"maxExcerptBytes":128,"retrievalBudgetBytes":200,"auditInputTokenCanary":10000}'
GLUERUN_EVIDENCE_CONFIG_JSON="$evidence_config" "$ROOT/engine/evidence-manifest.sh" \
  --run-dir "$run" --task-id TASK-0001 --worktree "$repo" \
  --base-ref "$base" --head-sha "$head" >/dev/null

python3 - "$run/evidence-manifest.json" <<'PY'
import hashlib, json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
assert data["schema"] == "gluerun.orchestration.evidence-manifest.v0"
assert data["diffSha256"]
assert data["files"][0]["path"] == "src/value.txt"
assert data["expectedFailureCount"] == 1
assert data["unexpectedFailureCount"] == 0
assert data["checks"]["scope"]["status"] == "passed"
assert data["checks"]["secret"]["status"] == "not-run"
assert data["checks"]["gate"]["status"] == "passed"
assert data["budget"]["limitBytes"] == 65536
assert data["budget"]["composedBytes"] <= 65536
assert data["budget"]["excerptLimitBytes"] == 128
assert data["budget"]["retrievalLimitBytes"] == 200
assert data["budget"]["auditInputTokenCanary"] == 10000
assert data["budget"]["actualAuditInputTokens"] == 8000
assert max(len(c.get("excerpt", "")) for c in data["commands"]) <= 128
assert any(a["ref"] == "worker-evidence/huge.log" for a in data["artifacts"])
assert any(
    a["ref"] == "auditor-attempt-1-try-0-runner-result.json"
    for a in data["artifacts"]
)
diff_artifact = next(a for a in data["artifacts"] if a["ref"] == "committed.diff")
diff_bytes = (path.parent / diff_artifact["ref"]).read_bytes()
assert hashlib.sha256(diff_bytes).hexdigest() == data["diffSha256"]
assert diff_artifact["sha256"] == data["diffSha256"]
assert data["providerUsage"] == {
    "inputTokens": 12200,
    "cachedInputTokens": 3000,
    "outputTokens": 800,
}
PY

if GLUERUN_EVIDENCE_CONFIG_JSON='{"auditInputTokenCanary":8000}' \
  "$ROOT/engine/evidence-manifest.sh" \
    --run-dir "$run" --task-id TASK-0001 --worktree "$repo" \
    --base-ref "$base" --head-sha "$head" >/dev/null 2>&1; then
  echo "expected auditor input-token canary to fail at its bound" >&2
  exit 1
fi

"$ROOT/engine/evidence-show.sh" "$run/evidence-manifest.json" \
  worker-evidence/huge.log 128 >"$tmp/excerpt"
[[ "$(wc -c <"$tmp/excerpt" | tr -d ' ')" -lt 256 ]]
"$ROOT/engine/evidence-show.sh" "$run/evidence-manifest.json" \
  worker-evidence/huge.log 128 >"$tmp/excerpt-two"
[[ "$(wc -c <"$tmp/excerpt-two" | tr -d ' ')" -lt 200 ]]
if "$ROOT/engine/evidence-show.sh" "$run/evidence-manifest.json" \
  worker-evidence/huge.log 1 >/dev/null 2>&1; then
  echo "expected cumulative evidence budget to be exhausted" >&2
  exit 1
fi

printf 'tamper\n' >>"$run/worker-evidence/huge.log"
if "$ROOT/engine/evidence-show.sh" "$run/evidence-manifest.json" \
  worker-evidence/huge.log 128 >/dev/null 2>&1; then
  echo "expected tampered evidence to be rejected" >&2
  exit 1
fi

echo "evidence manifest tests passed"
