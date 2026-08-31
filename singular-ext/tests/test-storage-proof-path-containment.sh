#!/usr/bin/env bash
set -euo pipefail

# The storage-proof skip guard is an evidence trust boundary. A packet-authored
# ref may name only a regular file contained in its workspace or canonical run
# directory; absolute paths, lexical traversal, and symlink escapes fail closed.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ENGINE_HOME/singular-ext/storage-proof.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/singular-storage-proof-paths.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

workspace="$fixture/workspace"
run_dir="$fixture/runs/RUN-PROOF"
packet="$fixture/packet.json"
task="$fixture/TASK-9001.md"
mkdir -p "$workspace/.singular-evidence" "$run_dir/worker-evidence"

cat >"$task" <<'EOF'
# TASK-9001: durable storage proof

## Objective

Implement the storage_proof durable round-trip proof against real PostgreSQL.

## Acceptance Criteria

- Include a marked nonzero storage-stripped proof command.

## Required Evidence

- Include a skip-guard-red artifact.
EOF

write_packet() {
  local ref="$1"
  python3 - "$packet" "$ref" <<'PY'
import json
import sys

path, ref = sys.argv[1:3]
packet = {
    "commands": [{
        "cmd": "env -u SINGULAR_STORAGE_PROOF_DATABASE_URL -u SINGULAR_DATABASE_URL go test ./internal/storage -run TestDurable -count=1",
        "exitCode": 1,
        "logRef": ref,
    }],
    "tests": [{
        "name": "storage stripped",
        "phase": "red",
        "status": "failed-as-expected",
        "logRef": ref,
    }],
    "evidence": [{"kind": "red-log", "ref": ref}],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(packet, handle)
    handle.write("\n")
PY
}

assert_guard_passes() {
  local label="$1" ref="$2"
  write_packet "$ref"
  singular_packet_module_guard "$packet" "$task" "$workspace" "$run_dir" >/dev/null \
    || fail "$label: valid contained evidence should pass"
}

assert_guard_rejects() {
  local label="$1" ref="$2" expected="$3" out rc=0
  write_packet "$ref"
  out="$(singular_packet_module_guard "$packet" "$task" "$workspace" "$run_dir" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "$label: unsafe evidence ref unexpectedly passed"
  assert_contains "$out" "$expected" "$label"
}

workspace_ref=".singular-evidence/workspace-skip-guard-red"
printf 'storage stripped failed\n' >"$workspace/$workspace_ref"
assert_guard_passes "workspace-contained ref" "$workspace_ref"

run_ref=".singular-evidence/run-skip-guard-red"
printf 'storage stripped failed\n' >"$run_dir/worker-evidence/run-skip-guard-red"
assert_guard_passes "run-contained worker-evidence ref" "$run_ref"

outside="$fixture/outside-skip-guard-red"
printf 'untrusted outside evidence\n' >"$outside"
assert_guard_rejects "absolute outside ref" "$outside" "unsafe absolute"

printf 'untrusted traversal evidence\n' >"$workspace/outside-skip-guard-red"
assert_guard_rejects "parent traversal ref" \
  ".singular-evidence/../outside-skip-guard-red" "unsafe traversal"

symlink_ref=".singular-evidence/symlink-skip-guard-red"
ln -s "$outside" "$workspace/$symlink_ref"
assert_guard_rejects "final symlink escape" "$symlink_ref" "traverses a symlink"

mkdir -p "$fixture/outside-dir"
printf 'untrusted parent-link evidence\n' >"$fixture/outside-dir/parent-skip-guard-red"
ln -s "$fixture/outside-dir" "$workspace/.singular-evidence/linked"
assert_guard_rejects "parent symlink escape" \
  ".singular-evidence/linked/parent-skip-guard-red" "traverses a symlink"

assert_guard_rejects "empty ref" "" "requires a nonzero command logRef"
assert_guard_rejects "dot ref" "." "requires a nonzero command logRef"

echo "storage-proof path containment tests passed"
