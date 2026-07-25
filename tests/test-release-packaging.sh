#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(tr -d '[:space:]' <"$ROOT/VERSION")" == "0.14.1" ]]
[[ "$(tr -d '[:space:]' <"$ROOT/.gluerun-version")" == "0.14.1" ]]
[[ "$(tr -d '[:space:]' <"$ROOT/SCHEMA_VERSION")" == "v2" ]]
[[ -x "$ROOT/migrations/v1-to-v2.sh" ]]

python3 - "$ROOT/gluerun.config.json" "$ROOT/templates/gluerun.config.json" <<'PY'
import json
import sys

configs = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
for config in configs:
    assert config["schemaVersion"] == "v2"
    assert config["engineVersion"] == "0.14.1"
    profiles = config["capabilityProfiles"]
    roles = config["roleProfiles"]
    required_roles = {
        "planner",
        "critic",
        "implementer",
        "auditor",
        "decider",
        "integrator",
        "supervisor",
        "assistant",
    }
    assert required_roles <= set(roles)
    for role, profile_name in roles.items():
        assert profile_name in profiles, (role, profile_name)
        profile = profiles[profile_name]
        assert profile["startup"] == "lazy"
        assert set(profile["required"]) >= {
            "filesystem",
            "git",
            "schemas",
            "runner-contract",
            "provider-executable",
        }
    assert config["evidence"] == {
        "maxComposedBytes": 262144,
        "maxExcerptBytes": 2048,
        "retrievalBudgetBytes": 262144,
        "auditInputTokenCanary": 100000,
    }
    assert config["bootstrap"] == {
        "required": True,
        "command": "",
        "commands": [],
        "lockfiles": [],
        "sharedStoreRoots": [],
        "sharedLinks": [],
    }
    assert config["resources"] == {
        "diskReserveBytes": 2147483648,
        "estimatedWorktreeBytes": 268435456,
        "maxConcurrent": 3,
    }
    assert config["controlState"]["commitIntervalSeconds"] == 300
    assert config["legacyCompatibility"] == {"unboundWaivers": False}
PY

echo "release packaging tests passed"
