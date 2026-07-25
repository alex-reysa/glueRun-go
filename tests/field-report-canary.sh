#!/usr/bin/env bash
# Non-destructive promotion canary for the July 24 field-report regressions.
# Intentionally excluded from tests/run.sh because it composes focused tests
# that the ordinary suite already executes separately.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPTURE="$ROOT/tests/fixtures/field-report/spokit-localization-26.capture.v0.json"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$tmp" init -q repo
printf '{"schemaVersion":"v2","targetBranch":"main"}\n' \
  >"$repo/gluerun.config.json"

printf 'CANARY %-32s' "captured-26-node-replay"
replay_log="$tmp/captured-replay.log"
if ! python3 "$ROOT/tests/field_report_canary_replay.py" \
  --root "$ROOT" --repo "$repo" --capture "$CAPTURE" \
  >"$replay_log" 2>&1; then
  printf ' FAIL\n'
  cat "$replay_log" >&2
  exit 1
fi
printf ' PASS\n'

run_case() {
  local label="$1" script="$2"
  local log="$tmp/test-case.log"
  printf 'CANARY %-32s' "$label"
  if ! bash "$ROOT/tests/$script" </dev/null >"$log" 2>&1; then
    printf ' FAIL\n'
    cat "$log" >&2
    return 1
  fi
  printf ' PASS\n'
}

# Lifecycle and diagnostic presentation are release requirements, not optional
# smoke checks. The captured replay exercises every phase/category through
# health; these focused contracts keep both public surfaces independently bound.
run_case "run-status-lifecycle" "test-run-status.sh"
run_case "diagnostic-category-rendering" "test-ops-health.sh"

# The ten named field-report regressions. The provider contract test is run once
# because it jointly proves scenarios 2 and 3 across every built-in adapter.
run_case "1-critique-revision-parser" "test-ctx-plan-revision.sh"
printf 'CANARY %-32s' "2-legal-prose-no-backoff"
provider_log="$tmp/provider-contract.log"
if ! bash "$ROOT/tests/test-provider-failure-contract.sh" \
  </dev/null >"$provider_log" 2>&1; then
  printf ' FAIL\n'
  cat "$provider_log" >&2
  exit 1
fi
printf ' PASS\n'
printf 'CANARY %-32s PASS\n' "3-structured-provider-quota"
run_case "4-auditor-cache-immutable" "test-audit-verification.sh"
run_case "5-idle-snapshot-bound" "test-control-commit-throttle.sh"
run_case "6-optional-mcp-warning-once" "test-doctor-json.sh"
run_case "7-large-assertion-truncated" "test-evidence-manifest.sh"
run_case "8-acknowledged-inherited" "test-gate-report.sh"
run_case "9-adaptive-disk-concurrency" "test-resource-bootstrap.sh"
run_case "10-human-artifact-invalidation" "test-human-gate.sh"

echo "FIELD-REPORT CANARY PASS: captured events/artifacts + equivalent 26-node run + 10 regression scenarios"
