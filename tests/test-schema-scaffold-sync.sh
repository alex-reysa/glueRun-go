#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/schemas/orchestration"
git -C "$tmp" init -q repo

write_config() {
  printf '{"schemaVersion":"%s"}\n' "$1" >"$repo/singular.config.json"
}

# A consumer that has not migrated must keep its prior schema bytes and must not
# receive any new v2 contract merely because scaffold runs.
write_config v1
printf '{"stale":true}\n' >"$repo/schemas/orchestration/dag.v0.schema.json"
before="$(shasum -a 256 "$repo/schemas/orchestration/dag.v0.schema.json" | awk '{print $1}')"
SINGULAR_ROOT="$repo" SINGULAR_ENGINE_HOME="$ROOT" bash "$ROOT/engine/scaffold.sh"
after="$(shasum -a 256 "$repo/schemas/orchestration/dag.v0.schema.json" | awk '{print $1}')"
[[ "$before" == "$after" ]] || {
  echo "pre-migration scaffold rewrote an existing v1 mirror" >&2
  exit 1
}
[[ ! -e "$repo/schemas/orchestration/human-gate.v0.schema.json" ]] || {
  echo "pre-migration scaffold introduced a v2 schema" >&2
  exit 1
}

# Once migration bookkeeping says v2, the engine bundle is authoritative:
# stale copies are replaced and every basename is mirrored byte-for-byte.
write_config v2
SINGULAR_ROOT="$repo" SINGULAR_ENGINE_HOME="$ROOT" bash "$ROOT/engine/scaffold.sh"
while IFS= read -r schema; do
  mirror="$repo/schemas/orchestration/$(basename "$schema")"
  cmp -s "$schema" "$mirror" || {
    echo "post-migration scaffold mirror mismatch: $(basename "$schema")" >&2
    exit 1
  }
done < <(find "$ROOT/schemas" -maxdepth 1 -type f -name '*.schema.json' | sort)

echo "schema scaffold sync tests passed"
