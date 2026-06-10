#!/usr/bin/env bash
# Abstraction gate: the generic engine/ (and the shipped schemas/) must reference
# ZERO GLUERUN-project-specific symbols. GLUERUN behavior lives in gluerun-ext/ (loaded only
# when a repo opts in) and in each consumer's config — never in engine/ or schemas/.
#
# Allowed (not flagged): the engine's own brand "gluerun" / default email "gluerun.local",
# and "internal/" as the overridable default area prefix (GLUERUN_AREA_PREFIX).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

# GLUERUN-project identifiers + language assumptions that must not appear in engine/.
# Both underscore (storage_proof) and hyphen (storage-proof) naming are banned.
banned='glueRun-go|storage_proof|storage-proof|storage_substrate_base|kernel-build-plan|GLUERUN_STORAGE_PROOF_DATABASE_URL|go mod download|go build \./|go test \./|go vet|codex/gluerun-bootstrap-target'
hits="$(grep -rnoE "$banned" "$ROOT/engine" 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
  echo "FAIL: GLUERUN-specific symbols in the generic engine/:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  fail=1
fi

# Shipped schemas must not carry the GLUERUN project brand.
shits="$(grep -rnoE 'glueRun-go|codex/gluerun-bootstrap-target' "$ROOT/schemas" 2>/dev/null || true)"
if [[ -n "$shits" ]]; then
  echo "FAIL: GLUERUN brand in shipped schemas/:" >&2
  printf '%s\n' "$shits" | sed 's/^/  /' >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "" >&2
  echo "Move project-specific logic to gluerun-ext/ (module) or consumer config." >&2
  exit 1
fi

echo "engine-clean: engine/ + schemas/ are free of GLUERUN-specific symbols"
