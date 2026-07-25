#!/usr/bin/env bash
set -euo pipefail

repo="${1:-}"
[[ -n "$repo" && -d "$repo" ]] || {
  echo "v1-to-v2: repo directory required" >&2
  exit 2
}
repo="$(cd "$repo" && pwd -P)"

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$repo/schemas/orchestration"
config="$repo/gluerun.config.json"
template="$ENGINE_HOME/templates/gluerun.config.json"
[[ -f "$config" && -f "$template" ]] || {
  echo "v1-to-v2: gluerun config and engine template are required" >&2
  exit 2
}

stage="$(mktemp -d "${TMPDIR:-/tmp}/gluerun-v1-to-v2.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/schemas"

# v1 scaffold copies were "create if absent", so consumer schemas could remain
# stale forever. Stage and validate the complete authoritative bundle before
# replacing any consumer mirror. Consumer-only custom schemas are left alone.
while IFS= read -r schema; do
  cp "$schema" "$stage/schemas/$(basename "$schema")"
done < <(find "$ENGINE_HOME/schemas" -maxdepth 1 -type f -name '*.schema.json' | sort)

python3 - "$config" "$template" "$stage/gluerun.config.json" "$stage/schemas" <<'PY'
import json
import pathlib
import copy
import sys

config_path, template_path, output_path, schemas_path = map(pathlib.Path, sys.argv[1:])
with config_path.open(encoding="utf-8") as handle:
    config = json.load(handle)
with template_path.open(encoding="utf-8") as handle:
    template = json.load(handle)
if not isinstance(config, dict) or not isinstance(template, dict):
    raise SystemExit("v1-to-v2: gluerun configuration must be a JSON object")
if config.get("schemaVersion") != "v1":
    raise SystemExit("v1-to-v2: source schemaVersion must remain v1 until the migration runner advances it")

for key in (
    "capabilityProfiles",
    "roleProfiles",
    "evidence",
    "bootstrap",
    "resources",
    "controlState",
    "legacyCompatibility",
):
    if key not in config:
        config[key] = copy.deepcopy(template[key])
    elif isinstance(config[key], dict) and isinstance(template[key], dict):
        for nested_key, nested_value in template[key].items():
            config[key].setdefault(nested_key, copy.deepcopy(nested_value))

# Parse every staged schema before consumer files are changed.
for schema_path in sorted(schemas_path.glob("*.schema.json")):
    with schema_path.open(encoding="utf-8") as handle:
        schema = json.load(handle)
    if not isinstance(schema, dict) or "$schema" not in schema:
        raise SystemExit(f"v1-to-v2: invalid authoritative schema: {schema_path.name}")

with output_path.open("w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
PY

mkdir -p "$target"
while IFS= read -r schema; do
  base="$(basename "$schema")"
  cp "$schema" "$target/.$base.v2-tmp"
  mv "$target/.$base.v2-tmp" "$target/$base"
done < <(find "$stage/schemas" -maxdepth 1 -type f -name '*.schema.json' | sort)

cp "$stage/gluerun.config.json" "$repo/.gluerun.config.json.v2-tmp"
mv "$repo/.gluerun.config.json.v2-tmp" "$config"

mkdir -p \
  "$repo/docs/orchestration/human-gates" \
  "$repo/docs/orchestration/gate-baselines"

echo "v1-to-v2: synchronized schemas, configuration defaults, and governance directories"
