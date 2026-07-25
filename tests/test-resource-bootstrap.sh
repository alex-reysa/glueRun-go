#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
store="$tmp/store"
mkdir -p "$store/cache"
git -C "$tmp" init -q repo
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf 'lock\n' >"$repo/lockfile"
printf '.shared/\n' >"$repo/.gitignore"
git -C "$repo" add lockfile .gitignore
git -C "$repo" commit -qm init

plan="$(GLUERUN_ROOT="$repo" "$ROOT/engine/resource-plan.sh" \
  --configured-slots 5 --reserve-bytes 100 --estimated-worktree-bytes 100 \
  --free-bytes 350 --json)"
python3 - "$plan" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["configuredSlots"] == 5
assert data["effectiveSlots"] == 2
assert data["reason"] == "disk-limited-concurrency"
PY

config="$(python3 - "$store" <<'PY'
import json, sys
print(json.dumps({
    "required": True,
    "command": "",
    "commands": [
        {
            "command": "test -L .shared/cache && printf first >> .shared/cache/bootstrap-count",
            "lockfiles": ["lockfile"]
        },
        {
            "command": "printf second >> .shared/cache/bootstrap-count",
            "lockfiles": ["lockfile"]
        }
    ],
    "lockfiles": ["lockfile"],
    "sharedStoreRoots": [sys.argv[1]],
    "sharedLinks": [{"source": sys.argv[1] + "/cache", "target": ".shared/cache"}],
}, separators=(",", ":")))
PY
)"
base_env=(
  GLUERUN_ROOT="$repo"
  GLUERUN_STATE_DIR="$repo/.gluerun-state"
  GLUERUN_BOOTSTRAP_JSON="$config"
)
env "${base_env[@]}" "$ROOT/engine/bootstrap-worktree.sh" --worktree "$repo" >/dev/null
env "${base_env[@]}" "$ROOT/engine/bootstrap-worktree.sh" --worktree "$repo" >/dev/null
[[ "$(cat "$store/cache/bootstrap-count")" == "firstsecond" ]]

# A completion marker is valid only for the exact committed worktree head.
printf 'next\n' >"$repo/tracked"
git -C "$repo" add tracked
git -C "$repo" commit -qm next
env "${base_env[@]}" "$ROOT/engine/bootstrap-worktree.sh" --worktree "$repo" >/dev/null
[[ "$(cat "$store/cache/bootstrap-count")" == "firstsecondfirstsecond" ]]

# Declared lockfile bytes are part of the cache key even before they are
# committed. An unchanged subsequent invocation remains cached.
printf 'lock changed\n' >"$repo/lockfile"
env "${base_env[@]}" "$ROOT/engine/bootstrap-worktree.sh" --worktree "$repo" >/dev/null
env "${base_env[@]}" "$ROOT/engine/bootstrap-worktree.sh" --worktree "$repo" >/dev/null
[[ "$(cat "$store/cache/bootstrap-count")" == "firstsecondfirstsecondfirstsecond" ]]

marker="$(find "$repo/.gluerun-state/bootstrap" -type f -name '*.json' -print -quit)"
python3 - "$marker" "$repo" <<'PY'
import hashlib, json, pathlib, subprocess, sys
marker, repo = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
data = json.loads(marker.read_text(encoding="utf-8"))
head = subprocess.check_output(
    ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
).strip()
assert data["headSha"] == head
assert data["lockfileSha256"]["lockfile"] == hashlib.sha256(
    (repo / "lockfile").read_bytes()
).hexdigest()
PY

bad="$(python3 - "$store" <<'PY'
import json, sys
print(json.dumps({
    "required": True,
    "sharedStoreRoots": [sys.argv[1]],
    "sharedLinks": [{"source": sys.argv[1] + "/cache", "target": "../escape"}],
}))
PY
)"
if env GLUERUN_ROOT="$repo" GLUERUN_STATE_DIR="$repo/.gluerun-state" \
  GLUERUN_BOOTSTRAP_JSON="$bad" "$ROOT/engine/bootstrap-worktree.sh" \
  --worktree "$repo" --dry-run >/dev/null 2>&1; then
  echo "shared link traversal must be rejected" >&2
  exit 1
fi

failing='{"required":true,"command":"exit 19","lockfiles":["lockfile"]}'
if env GLUERUN_ROOT="$repo" GLUERUN_STATE_DIR="$repo/.gluerun-state" \
  GLUERUN_BOOTSTRAP_JSON="$failing" "$ROOT/engine/bootstrap-worktree.sh" \
  --worktree "$repo" >/dev/null 2>&1; then
  echo "required bootstrap failure must fail closed" >&2
  exit 1
fi

optional='{"commands":[{"command":"exit 17","required":false,"lockfiles":["lockfile"]},{"command":"printf continued > optional-result","required":true,"lockfiles":["lockfile"]}]}'
env GLUERUN_ROOT="$repo" GLUERUN_STATE_DIR="$tmp/optional-state" \
  GLUERUN_BOOTSTRAP_JSON="$optional" "$ROOT/engine/bootstrap-worktree.sh" \
  --worktree "$repo" >/dev/null
[[ "$(cat "$repo/optional-result")" == "continued" ]]

echo "resource and bootstrap tests passed"
