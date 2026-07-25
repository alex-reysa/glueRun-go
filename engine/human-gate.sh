#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

exec python3 "$SCRIPT_DIR/human_gate.py" "$@" --repo "$GLUERUN_ROOT"
