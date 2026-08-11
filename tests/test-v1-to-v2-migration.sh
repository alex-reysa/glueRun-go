#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/schemas/orchestration" "$repo/docs/orchestration"
cat >"$repo/singular.config.json" <<'JSON'
{
  "schemaVersion": "v1",
  "targetBranch": "custom/integration",
  "bootstrap": {
    "required": true,
    "command": "printf legacy"
  },
  "resources": {
    "diskReserveBytes": 99,
    "estimatedWorktreeBytes": 123,
    "maxConcurrent": 1
  }
}
JSON
printf '{"stale":true}\n' >"$repo/schemas/orchestration/dag.v0.schema.json"
cat >"$repo/schemas/orchestration/acme-extension.v0.schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://example.test/schemas/acme-extension.v0.schema.json",
  "type": "object",
  "properties": {
    "custom": {"const": true}
  }
}
JSON
cp "$repo/schemas/orchestration/acme-extension.v0.schema.json" \
  "$tmp/acme-extension.before.json"

bash "$ROOT/migrations/v1-to-v2.sh" "$repo" >/dev/null
while IFS= read -r schema; do
  cmp -s "$schema" "$repo/schemas/orchestration/$(basename "$schema")" || {
    echo "migration mirror mismatch: $(basename "$schema")" >&2
    exit 1
  }
done < <(find "$ROOT/schemas" -maxdepth 1 -type f -name '*.schema.json' | sort)
cmp -s "$tmp/acme-extension.before.json" \
  "$repo/schemas/orchestration/acme-extension.v0.schema.json" || {
  echo "migration changed consumer-only schema extension" >&2
  exit 1
}
[[ -d "$repo/docs/orchestration/human-gates" ]]
[[ -d "$repo/docs/orchestration/gate-baselines" ]]
python3 - "$repo/singular.config.json" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
assert config["schemaVersion"] == "v1", "migration runner, not script, owns the version bump"
assert config["targetBranch"] == "custom/integration"
assert config["resources"]["diskReserveBytes"] == 99, "existing config must win"
for key in (
    "capabilityProfiles",
    "roleProfiles",
    "evidence",
    "bootstrap",
    "resources",
    "controlState",
    "legacyCompatibility",
):
    assert key in config, key
assert config["evidence"]["maxComposedBytes"] == 262144
assert config["evidence"]["maxExcerptBytes"] == 2048
assert config["evidence"]["retrievalBudgetBytes"] == 262144
assert config["evidence"]["auditInputTokenCanary"] == 100000
assert config["controlState"]["commitIntervalSeconds"] == 300
assert config["legacyCompatibility"] == {"unboundWaivers": False}
assert config["bootstrap"]["command"] == "printf legacy"
assert config["bootstrap"]["commands"] == []
assert config["bootstrap"]["lockfiles"] == []
PY

cp "$repo/singular.config.json" "$tmp/config.after-first.json"
bash "$ROOT/migrations/v1-to-v2.sh" "$repo" >/dev/null
cmp -s "$tmp/config.after-first.json" "$repo/singular.config.json" || {
  echo "migration is not idempotent" >&2
  exit 1
}

echo "v1 to v2 migration tests passed"
