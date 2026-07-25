#!/usr/bin/env bash
# Covers the config loader (gluerun.config.json -> GLUERUN_* env), the area->path map,
# and the security guard that rejects malicious config env keys.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

tmp="$(mktemp -d)"
canary="$tmp/CANARY"
cat > "$tmp/gluerun.config.json" <<EOF
{
  "targetBranch": "agent/cfg-target",
  "gateCommand": "npm test && npm run build",
  "areas": { "mcp": "axon-402-mcp/", "cli": ["axon-cli/", "axon-cli-operator/"] },
  "proofLayers": ["storage_proof"],
  "provisionFiles": [{"source": ".env.local", "target": ".env.local", "required": true}],
  "envAllowlist": ["PUBLIC_*", "EXACT_NAME"],
  "capabilityProfiles": {"planner-core": {"required": ["filesystem"], "optional": ["mcp:browser"]}},
  "roleProfiles": {"planner": "planner-core"},
  "evidence": {"maxComposedBytes": 262144, "retrievalBudgetBytes": 131072},
  "bootstrap": {"commands": [{"command": "npm ci", "lockfiles": ["package-lock.json"]}]},
  "resources": {"diskReserveBytes": 4096, "estimatedWorktreeBytes": 8192, "maxConcurrent": 4},
  "controlState": {"commitIntervalSeconds": 300},
  "legacyCompatibility": {"unboundWaivers": false},
  "env": {
    "GLUERUN_GOOD_KEY": "ok",
    "GLUERUN_MAX_CONCURRENT": "9",
    "GLUERUN_BASH_BIN": "/committed/config/must-not-select-bash",
    "BAD KEY; touch $canary; X": "1"
  }
}
EOF
git -C "$tmp" init -q

out="$(GLUERUN_ROOT="$tmp" bash -c '
  source "'"$SCRIPT_DIR"'/lib.sh" 2>/dev/null
  echo "TB=$GLUERUN_TARGET_BRANCH"
  echo "GATE=$GLUERUN_DEFAULT_GATE_CMD"
  echo "PL=$GLUERUN_PROOF_LAYERS"
  echo "PF=$GLUERUN_PROVISION_FILES_JSON"
  echo "EA=$GLUERUN_ENV_ALLOWLIST_JSON"
  echo "CP=$GLUERUN_CAPABILITY_PROFILES_JSON"
  echo "RP=$GLUERUN_ROLE_PROFILES_JSON"
  echo "EV=$GLUERUN_EVIDENCE_CONFIG_JSON"
  echo "BS=$GLUERUN_BOOTSTRAP_JSON"
  echo "DR=$GLUERUN_DISK_RESERVE_BYTES"
  echo "WE=$GLUERUN_ESTIMATED_WORKTREE_BYTES"
  echo "MC=$GLUERUN_MAX_CONCURRENT"
  echo "CI=$GLUERUN_CONTROL_COMMIT_MIN_INTERVAL_SEC"
  echo "UW=$GLUERUN_LEGACY_UNBOUND_WAIVERS"
  echo "GOOD=${GLUERUN_GOOD_KEY:-<unset>}"
  echo "BASHBIN=${GLUERUN_BASH_BIN:-<unset>}"
  echo "MCP=$(gluerun_l1_area_write_scopes mcp)"
  echo "CLI=$(gluerun_l1_area_write_scopes cli | tr "\n" " ")"
  echo "FOO=$(gluerun_l1_area_write_scopes foo)"
')"

assert_contains "$out" "TB=agent/cfg-target" "targetBranch -> GLUERUN_TARGET_BRANCH"
assert_contains "$out" "GATE=npm test && npm run build" "gateCommand -> GLUERUN_DEFAULT_GATE_CMD"
assert_contains "$out" "PL=storage_proof" "proofLayers -> GLUERUN_PROOF_LAYERS"
assert_contains "$out" 'PF=[{"source":".env.local","target":".env.local","required":true}]' "provisionFiles -> GLUERUN_PROVISION_FILES_JSON"
assert_contains "$out" 'EA=["PUBLIC_*","EXACT_NAME"]' "envAllowlist -> GLUERUN_ENV_ALLOWLIST_JSON"
assert_contains "$out" 'CP={"planner-core":{"required":["filesystem"],"optional":["mcp:browser"]}}' "capabilityProfiles -> GLUERUN_CAPABILITY_PROFILES_JSON"
assert_contains "$out" 'RP={"planner":"planner-core"}' "roleProfiles -> GLUERUN_ROLE_PROFILES_JSON"
assert_contains "$out" 'EV={"maxComposedBytes":262144,"retrievalBudgetBytes":131072}' "evidence -> GLUERUN_EVIDENCE_CONFIG_JSON"
assert_contains "$out" 'BS={"commands":[{"command":"npm ci","lockfiles":["package-lock.json"]}]}' "bootstrap -> GLUERUN_BOOTSTRAP_JSON"
assert_contains "$out" "DR=4096" "resources.diskReserveBytes mapping"
assert_contains "$out" "WE=8192" "resources.estimatedWorktreeBytes mapping"
assert_contains "$out" "MC=9" "explicit env overrides resources.maxConcurrent"
assert_contains "$out" "CI=300" "controlState.commitIntervalSeconds mapping"
assert_contains "$out" "UW=0" "legacyCompatibility.unboundWaivers mapping"
assert_contains "$out" "GOOD=ok" "valid env key is exported"
assert_contains "$out" "BASHBIN=<unset>" "bootstrap-only bash bin is ignored in repo config"
assert_contains "$out" "MCP=axon-402-mcp/" "area map: mcp"
assert_contains "$out" "CLI=axon-cli/ axon-cli-operator/" "area map: cli (multi-path)"
assert_contains "$out" "FOO=internal/foo/" "unmapped area falls back to prefix"

# SECURITY: a malicious env KEY must be rejected, not eval'd.
[[ ! -f "$canary" ]] || fail "SECURITY: malicious config env key executed code (canary created)"

# A real bootstrap environment value survives repo config loading unchanged.
out="$(GLUERUN_ROOT="$tmp" GLUERUN_BASH_BIN="$BASH" bash -c '
  source "'"$SCRIPT_DIR"'/lib.sh" 2>/dev/null
  echo "$GLUERUN_BASH_BIN"
')"
[[ "$out" == "$BASH" ]] || fail "bootstrap GLUERUN_BASH_BIN was not preserved"

rm -rf "$tmp"
echo "config-loader tests passed"
