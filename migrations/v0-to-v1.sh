#!/usr/bin/env bash
set -euo pipefail

# Migrations are documented as directly invocable (`bash <script> <repo-root>`),
# so they carry the Bash >= 4 guard themselves rather than trusting the caller.
# migrations/ sits beside engine/ in a checkout and in an installed engine
# alike, so the relative path holds in both layouts.
# shellcheck source=../engine/bash-guard.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../engine" && pwd)/bash-guard.sh"

repo="${1:-}"
[[ -n "$repo" && -d "$repo" ]] || { echo "v0-to-v1: repo directory required" >&2; exit 2; }

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SINGULAR_ROOT="$repo" SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$ENGINE_HOME/engine/scaffold.sh"

python3 - "$repo" <<'PY'
import os
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
candidates = []
cfg = repo / "singular.config.json"
if cfg.exists():
    candidates.append(cfg)
orch = repo / "docs" / "orchestration"
if orch.exists():
    for path in orch.rglob("*"):
        if path.is_file() and path.suffix in {".json", ".md", ".txt", ".sh"}:
            candidates.append(path)

for path in candidates:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    updated = text.replace("pmgo.orchestration.", "singular.orchestration.")
    if updated != text:
        path.write_text(updated, encoding="utf-8")
PY
