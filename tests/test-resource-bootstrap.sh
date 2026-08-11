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

plan="$(SINGULAR_ROOT="$repo" "$ROOT/engine/resource-plan.sh" \
  --configured-slots 5 --reserve-bytes 100 --estimated-worktree-bytes 100 \
  --free-bytes 350 --json)"
python3 - "$plan" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["configuredSlots"] == 5
assert data["effectiveSlots"] == 2
assert data["reason"] == "disk-limited-concurrency"
PY

# --- provider-pressure ceiling in the resource plan --------------------------
#
# The controller's evidence semantics live in test-provider-failure-contract.sh.
# What matters here is only how a stored cap meets the disk plan: it may lower
# the answer, never raise it, and a broken or absent cap must leave the plan
# exactly as it was.

pressure_state="$tmp/provider-pressure.json"
plan_env=(
  SINGULAR_ROOT="$repo"
  SINGULAR_STATE_DIR="$repo/.singular-state"
  SINGULAR_PROVIDER_PRESSURE_FILE="$pressure_state"
  SINGULAR_RUNNER="$ROOT/engine/codex-run.sh"
)
run_plan() {
  env "${plan_env[@]}" "$@" "$ROOT/engine/resource-plan.sh" \
    --configured-slots 5 --reserve-bytes 100 --estimated-worktree-bytes 100 \
    --free-bytes 350 --json
}
seed_pressure() {
  python3 - "$pressure_state" "$1" "$2" <<'PY'
import json, sys
path, provider, cap = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "schema": "singular.orchestration.provider-pressure.v0",
        "updatedAt": "2026-01-01T00:00:00Z",
        "providers": {provider: {
            "cap": None if cap == "null" else int(cap),
            "events": [],
            "quietSuccesses": 0,
            "lastReducedAt": None,
            "lastRecoveredAt": None,
        }},
    }, handle)
PY
}

# Disabled is the default and must be byte-identical to the pre-controller plan.
baseline_plan="$(run_plan)"
[[ "$baseline_plan" == "$plan" ]] \
  || { echo "adaptation-disabled plan drifted from the baseline plan" >&2; exit 1; }
[[ "$baseline_plan" != *providerPressure* ]] \
  || { echo "disabled adaptation emitted providerPressure" >&2; exit 1; }

# Enabling it must not, by itself, change any number or create durable state.
enabled_plan="$(run_plan SINGULAR_PROVIDER_PRESSURE_ADAPT=1)"
[[ ! -e "$pressure_state" ]] \
  || { echo "planning created provider-pressure state" >&2; exit 1; }
python3 - "$enabled_plan" "$baseline_plan" <<'PY'
import json, sys
live, base = (json.loads(arg) for arg in sys.argv[1:3])
pressure = live.pop("providerPressure", None)
assert live == base, (live, base)
assert pressure == {
    "enabled": True, "provider": "codex", "cap": None, "events": 0,
    "pendingEvents": 0, "quietSuccesses": 0, "recoverQuiet": 3,
    "clusterThreshold": 2, "applied": False,
}, pressure
PY

# A stored cap below the disk answer lowers it and renames the reason.
seed_pressure codex 1
python3 - "$(run_plan SINGULAR_PROVIDER_PRESSURE_ADAPT=1)" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["effectiveSlots"] == 1, data
assert data["affordableSlots"] == 2, data
assert data["reason"] == "provider-pressure-limited", data
assert data["providerPressure"]["applied"] is True, data
PY

# A cap at or above the disk answer changes nothing: pressure is a ceiling, and
# recovery can never buy back slots the disk cannot afford.
for cap in 2 3 5; do
  seed_pressure codex "$cap"
  python3 - "$(run_plan SINGULAR_PROVIDER_PRESSURE_ADAPT=1)" "$cap" <<'PY'
import json, sys
data, cap = json.loads(sys.argv[1]), sys.argv[2]
assert data["effectiveSlots"] == 2, (cap, data)
assert data["reason"] == "disk-limited-concurrency", (cap, data)
assert data["providerPressure"]["applied"] is False, (cap, data)
PY
done

# Another provider's cap is not this provider's ceiling, and a basename-
# colliding custom wrapper cannot collect one either.
seed_pressure claude 1
python3 - "$(run_plan SINGULAR_PROVIDER_PRESSURE_ADAPT=1)" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["effectiveSlots"] == 2, data
assert data["providerPressure"]["provider"] == "codex", data
assert data["providerPressure"]["cap"] is None, data
PY
collision="$tmp/collision/codex-run.sh"
mkdir -p "$(dirname "$collision")"
printf '#!/usr/bin/env bash\nexit 0\n' >"$collision"
chmod +x "$collision"
seed_pressure codex 1
python3 - "$(env "${plan_env[@]}" SINGULAR_PROVIDER_PRESSURE_ADAPT=1 SINGULAR_RUNNER="$collision" \
  "$ROOT/engine/resource-plan.sh" --configured-slots 5 --reserve-bytes 100 \
  --estimated-worktree-bytes 100 --free-bytes 350 --json)" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["providerPressure"]["provider"] is None, data
assert data["effectiveSlots"] == 2, data
PY

# Corrupt, hostile and zero-valued state all fail OPEN to the disk plan. A
# controller that can zero the scheduler is worse than one that never ran.
for bad in \
  'not json at all' \
  '{"schema":"singular.orchestration.provider-pressure.v0","providers":' \
  '{"schema":"other","providers":{"codex":{"cap":1}}}' \
  '{"schema":"singular.orchestration.provider-pressure.v0","providers":{"codex":{"cap":0}}}' \
  '{"schema":"singular.orchestration.provider-pressure.v0","providers":{"codex":{"cap":-3}}}' \
  '{"schema":"singular.orchestration.provider-pressure.v0","providers":{"codex":{"cap":"1"}}}' \
  '{"schema":"singular.orchestration.provider-pressure.v0","providers":[]}'; do
  printf '%s' "$bad" >"$pressure_state"
  python3 - "$(run_plan SINGULAR_PROVIDER_PRESSURE_ADAPT=1)" "$bad" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["effectiveSlots"] == 2, (sys.argv[2], data)
assert data["reason"] == "disk-limited-concurrency", (sys.argv[2], data)
assert data["providerPressure"]["cap"] is None, (sys.argv[2], data)
PY
done
rm -f "$pressure_state"

# The floor holds through the plan too: even a one-slot disk answer keeps its
# slot, so runnable work is never starved by pressure.
seed_pressure codex 1
python3 - "$(env "${plan_env[@]}" SINGULAR_PROVIDER_PRESSURE_ADAPT=1 \
  "$ROOT/engine/resource-plan.sh" --configured-slots 5 --reserve-bytes 100 \
  --estimated-worktree-bytes 100 --free-bytes 250 --json)" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["affordableSlots"] == 1, data
assert data["effectiveSlots"] == 1, data
assert data["providerPressure"]["applied"] is False, data
PY
rm -f "$pressure_state"

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
  SINGULAR_ROOT="$repo"
  SINGULAR_STATE_DIR="$repo/.singular-state"
  SINGULAR_BOOTSTRAP_JSON="$config"
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

marker="$(find "$repo/.singular-state/bootstrap" -type f -name '*.json' -print -quit)"
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
if env SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
  SINGULAR_BOOTSTRAP_JSON="$bad" "$ROOT/engine/bootstrap-worktree.sh" \
  --worktree "$repo" --dry-run >/dev/null 2>&1; then
  echo "shared link traversal must be rejected" >&2
  exit 1
fi

failing='{"required":true,"command":"exit 19","lockfiles":["lockfile"]}'
if env SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
  SINGULAR_BOOTSTRAP_JSON="$failing" "$ROOT/engine/bootstrap-worktree.sh" \
  --worktree "$repo" >/dev/null 2>&1; then
  echo "required bootstrap failure must fail closed" >&2
  exit 1
fi

optional='{"commands":[{"command":"exit 17","required":false,"lockfiles":["lockfile"]},{"command":"printf continued > optional-result","required":true,"lockfiles":["lockfile"]}]}'
env SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$tmp/optional-state" \
  SINGULAR_BOOTSTRAP_JSON="$optional" "$ROOT/engine/bootstrap-worktree.sh" \
  --worktree "$repo" >/dev/null
[[ "$(cat "$repo/optional-result")" == "continued" ]]

echo "resource and bootstrap tests passed"
