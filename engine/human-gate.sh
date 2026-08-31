#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

singular_campaign_verify_or_refuse human-gate entry || exit 2
human_gate_campaign_binding="$(singular_campaign_binding)" || exit 2
singular_campaign_lock_acquire || {
  echo "human-gate: campaign publication lock unavailable" >&2
  exit 75
}
trap 'singular_campaign_lock_release 2>/dev/null || true' EXIT
SINGULAR_CAMPAIGN_BINDING="$human_gate_campaign_binding" \
  python3 "$SCRIPT_DIR/human_gate.py" "$@" --repo "$SINGULAR_ROOT"
