#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/cli/singular"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" checkout -q -b main
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
printf 'seed\n' >"$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm seed

(
  cd "$repo"
  SINGULAR_ENGINE_HOME="$ROOT" bash "$CLI" init >/dev/null
)
python3 - "$repo/singular.config.json" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["targetBranch"] = "main"
data["gateCommand"] = "true"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
git -C "$repo" add .
git -C "$repo" commit -qm scaffold

base_epoch=1780000000
project_path="$repo/docs/orchestration/project-state.md"
initial_project_commits="$(git -C "$repo" rev-list --count HEAD -- docs/orchestration/project-state.md)"

run_cycle() {
  local epoch="$1"
  (
    cd "$repo"
    SINGULAR_ENGINE_HOME="$ROOT" \
    SINGULAR_CONTROL_COMMIT_MIN_INTERVAL_SEC=300 \
    SINGULAR_CONTROL_COMMIT_NOW_EPOCH="$epoch" \
      bash "$CLI" reconcile --apply
  ) >"$tmp/reconcile-$epoch.log" 2>&1
  if [[ -n "$(git -C "$repo" status --porcelain -- docs/orchestration)" ]]; then
    echo "control tree left dirty at injected epoch $epoch" >&2
    cat "$tmp/reconcile-$epoch.log" >&2
    exit 1
  fi
}

project_mtime() {
  python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$project_path"
}

# Forty-five 20-second cycles model a 15-minute idle-control window. Durable
# changes are injected twice and must commit immediately without forcing an
# early project-state rewrite.
for ((offset=20; offset<=900; offset+=20)); do
  if [[ "$offset" -eq 40 ]]; then
    mtime_before_material="$(project_mtime)"
    cat >"$repo/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: throttle fixture

Status: ready
Area: core
Target branch: `main`
Worker branch: `agent/core/TASK-0001-throttle`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Exercise material control-state commits.

## Scope

Owned files:

- `README.md`

Forbidden files:

- Any other file.

## Acceptance Criteria

- Pass.
EOF
  elif [[ "$offset" -eq 340 ]]; then
    python3 - "$repo/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    path.read_text(encoding="utf-8").replace("Status: ready", "Status: blocked"),
    encoding="utf-8",
)
PY
  fi

  run_cycle "$((base_epoch + offset))"

  if [[ "$offset" -eq 40 ]]; then
    [[ "$(project_mtime)" == "$mtime_before_material" ]] || {
      echo "material transition rewrote project-state before its interval" >&2
      exit 1
    }
    git -C "$repo" show --pretty= --name-only HEAD | grep -qx \
      'docs/orchestration/tasks/TASK-0001.md' || {
      echo "material task transition was not committed immediately" >&2
      exit 1
    }
    if git -C "$repo" show --pretty= --name-only HEAD | grep -qx \
        'docs/orchestration/project-state.md'; then
      echo "material transition improperly bundled a deferred project snapshot" >&2
      exit 1
    fi
  fi
done

final_project_commits="$(git -C "$repo" rev-list --count HEAD -- docs/orchestration/project-state.md)"
snapshot_commits="$((final_project_commits - initial_project_commits))"
[[ "$snapshot_commits" -le 3 ]] || {
  echo "expected at most three project snapshots in 15 minutes, got $snapshot_commits" >&2
  exit 1
}

# An injected clock rollback must defer safely based on the last commit that
# touched project-state, without rewriting the file or dirtying the checkout.
rollback_mtime="$(project_mtime)"
run_cycle "$((base_epoch + 10))"
[[ "$(project_mtime)" == "$rollback_mtime" ]] || {
  echo "clock rollback rewrote the project snapshot" >&2
  exit 1
}

echo "control commit throttle tests passed"
