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
  "env": { "GLUERUN_GOOD_KEY": "ok", "BAD KEY; touch $canary; X": "1" }
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
  echo "GOOD=${GLUERUN_GOOD_KEY:-<unset>}"
  echo "MCP=$(gluerun_l1_area_write_scopes mcp)"
  echo "CLI=$(gluerun_l1_area_write_scopes cli | tr "\n" " ")"
  echo "FOO=$(gluerun_l1_area_write_scopes foo)"
')"

assert_contains "$out" "TB=agent/cfg-target" "targetBranch -> GLUERUN_TARGET_BRANCH"
assert_contains "$out" "GATE=npm test && npm run build" "gateCommand -> GLUERUN_DEFAULT_GATE_CMD"
assert_contains "$out" "PL=storage_proof" "proofLayers -> GLUERUN_PROOF_LAYERS"
assert_contains "$out" 'PF=[{"source":".env.local","target":".env.local","required":true}]' "provisionFiles -> GLUERUN_PROVISION_FILES_JSON"
assert_contains "$out" 'EA=["PUBLIC_*","EXACT_NAME"]' "envAllowlist -> GLUERUN_ENV_ALLOWLIST_JSON"
assert_contains "$out" "GOOD=ok" "valid env key is exported"
assert_contains "$out" "MCP=axon-402-mcp/" "area map: mcp"
assert_contains "$out" "CLI=axon-cli/ axon-cli-operator/" "area map: cli (multi-path)"
assert_contains "$out" "FOO=internal/foo/" "unmapped area falls back to prefix"

# SECURITY: a malicious env KEY must be rejected, not eval'd.
[[ ! -f "$canary" ]] || fail "SECURITY: malicious config env key executed code (canary created)"

rm -rf "$tmp"
echo "config-loader tests passed"
