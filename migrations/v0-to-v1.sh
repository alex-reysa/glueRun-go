#!/usr/bin/env bash
set -euo pipefail

repo="${1:-}"
[[ -n "$repo" && -d "$repo" ]] || { echo "v0-to-v1: repo directory required" >&2; exit 2; }

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GLUERUN_ROOT="$repo" GLUERUN_ENGINE_HOME="$ENGINE_HOME" bash "$ENGINE_HOME/engine/scaffold.sh"

python3 - "$repo" <<'PY'
import os
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
candidates = []
cfg = repo / "gluerun.config.json"
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
    updated = text.replace("pmgo.orchestration.", "gluerun.orchestration.")
    if updated != text:
        path.write_text(updated, encoding="utf-8")
PY
