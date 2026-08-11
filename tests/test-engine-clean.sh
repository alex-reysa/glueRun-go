#!/usr/bin/env bash
# Abstraction gate: the generic engine/ (and the shipped schemas/) must reference
# zero consumer-project-specific symbols. Consumer behavior lives in singular-ext/
# (loaded only when a repo opts in) and in each consumer's config — never in
# engine/ or schemas/. The Singular runtime namespace itself is expected here.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

# Consumer-project identifiers + language assumptions that must not appear in engine/.
# Both underscore (storage_proof) and hyphen (storage-proof) naming are banned.
banned='storage_proof|storage-proof|storage_substrate_base|kernel-build-plan|SINGULAR_STORAGE_PROOF_DATABASE_URL|go mod download|go build \./|go test \./|go vet|codex/singular-bootstrap-target'
hits="$(grep -rnoE "$banned" "$ROOT/engine" 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
  echo "FAIL: consumer-specific symbols in the generic engine/:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  fail=1
fi

# Shipped schemas must not carry consumer-only branch identities.
shits="$(grep -rnoE 'codex/singular-bootstrap-target' "$ROOT/schemas" 2>/dev/null || true)"
if [[ -n "$shits" ]]; then
  echo "FAIL: consumer-specific identity in shipped schemas/:" >&2
  printf '%s\n' "$shits" | sed 's/^/  /' >&2
  fail=1
fi

# Skill/CLI verb drift (0.5.0): every `singular <verb>` the skill documents
# must exist in the CLI dispatch table — docs promising missing verbs cost
# real operator time in the field.
skill_dir="$ROOT/plugin/skills/singular-orchestration"
if [[ -d "$skill_dir" ]]; then
  cli_verbs="$(sed -n 's/^    \([a-z-]*\))[[:space:]].*/\1/p' "$ROOT/cli/singular" | sort -u)"
  doc_verbs="$(grep -rhoE 'singular (supersede|clear-backoff|breaker|stop|resume|wake|gates|health|gc|lease|accept-packet|console|status|recover|next-areas|promote-gate|auto|doctor|init|setup|test|metrics|validate-dag|area-gate)' \
    "$skill_dir"/SKILL.md "$skill_dir"/references/*.md 2>/dev/null | awk '{print $2}' | sort -u)"
  for v in $doc_verbs; do
    if ! grep -qx "$v" <<<"$cli_verbs"; then
      echo "FAIL: skill documents 'singular $v' but cli/singular has no such verb" >&2
      fail=1
    fi
  done
fi

if [[ "$fail" -ne 0 ]]; then
  echo "" >&2
  echo "Move project-specific logic to singular-ext/ (module) or consumer config." >&2
  exit 1
fi

echo "engine-clean: engine/ + schemas/ are free of consumer-specific symbols"
