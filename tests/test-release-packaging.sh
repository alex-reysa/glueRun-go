#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# VERSION is the single source of truth; everything else must AGREE with it.
# These three used to hard-code the release string, so the suite went red on
# every version bump and told you nothing except that someone had bumped the
# version — the same stale-pin that broke test-versioning.sh in 0.14.x. What is
# actually worth checking is that the four places a version appears never drift
# apart, and that holds whatever the version is.
VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$(tr -d '[:space:]' <"$ROOT/.gluerun-version")" == "$VERSION" ]]
[[ "$(tr -d '[:space:]' <"$ROOT/SCHEMA_VERSION")" == "v2" ]]
[[ -x "$ROOT/migrations/v1-to-v2.sh" ]]

python3 - "$VERSION" "$ROOT/gluerun.config.json" "$ROOT/templates/gluerun.config.json" <<'PY'
import json
import sys

version = sys.argv[1]
configs = [json.load(open(path, encoding="utf-8")) for path in sys.argv[2:]]
for config in configs:
    assert config["schemaVersion"] == "v2"
    assert config["engineVersion"] == version, (config["engineVersion"], version)
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
    # required is False, not True. `required: true` with zero commands is a
    # promise that guarantees nothing, and doctor reported it as passing — so
    # every `gluerun init` inherited an empty promise from this very template.
    # A consumer that adds real commands sets it back to true, and doctor now
    # warns if they set it true without any.
    assert config["bootstrap"] == {
        "required": False,
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
