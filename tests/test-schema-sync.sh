#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
missing=0
authoritative_list="$(mktemp)"
mirror_list="$(mktemp)"
trap 'rm -f "$authoritative_list" "$mirror_list"' EXIT

find "$ROOT/schemas" -maxdepth 1 -type f -name '*.schema.json' \
  -exec basename {} \; | LC_ALL=C sort >"$authoritative_list"
find "$ROOT/schemas/orchestration" -maxdepth 1 -type f -name '*.schema.json' \
  -exec basename {} \; | LC_ALL=C sort >"$mirror_list"

if ! cmp -s "$authoritative_list" "$mirror_list"; then
  echo "schema mirror filename set differs from the authoritative bundle:" >&2
  diff -u "$authoritative_list" "$mirror_list" >&2 || true
  missing=1
fi

while IFS= read -r schema; do
  mirror="$ROOT/schemas/orchestration/$(basename "$schema")"
  if [[ ! -f "$mirror" ]]; then
    echo "missing consumer schema mirror: $mirror" >&2
    missing=1
  elif ! cmp -s "$schema" "$mirror"; then
    echo "stale consumer schema mirror: $mirror" >&2
    missing=1
  fi
done < <(find "$ROOT/schemas" -maxdepth 1 -type f -name '*.schema.json' | sort)

python3 - "$ROOT/schemas" "$ROOT/schemas/orchestration" <<'PY' || missing=1
import json
import pathlib
import sys

for directory in map(pathlib.Path, sys.argv[1:]):
    for path in sorted(directory.glob("*.schema.json")):
        with path.open(encoding="utf-8") as handle:
            schema = json.load(handle)
        assert isinstance(schema, dict), path
        assert isinstance(schema.get("$schema"), str) and schema["$schema"], path
        assert isinstance(schema.get("$id"), str) and schema["$id"], path
PY

[[ "$missing" -eq 0 ]] || exit 1
echo "schema mirror tests passed"
