#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
wrapper_dir="$tmp/chosen bash"
mkdir -p "$wrapper_dir"
wrapper="$wrapper_dir/bash"
marker="$tmp/bash-invocations"
path_marker="$tmp/observed-path"
cat >"$wrapper" <<'EOF'
#!/bin/sh
printf 'called\n' >>"$SINGULAR_TEST_BASH_MARKER"
printf '%s\n' "$PATH" >"$SINGULAR_TEST_PATH_MARKER"
exec "$SINGULAR_TEST_REAL_BASH" "$@"
EOF
chmod +x "$wrapper"

original_path="$PATH"
out="$(
  SINGULAR_BASH_BOOTSTRAPPED=0 \
  SINGULAR_BASH_BIN="$wrapper" \
  SINGULAR_TEST_BASH_MARKER="$marker" \
  SINGULAR_TEST_PATH_MARKER="$path_marker" \
  SINGULAR_TEST_REAL_BASH="$BASH" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  "$BASH" "$ENGINE_HOME/cli/singular" status
)"
assert_contains "$out" "singular orchestration status" "CLI reaches the engine under the selected Bash"
[[ -f "$marker" ]] || fail "selected Bash wrapper was not invoked"
calls="$(wc -l <"$marker" | tr -d ' ')"
[[ "$calls" -ge 2 ]] || fail "CLI and engine entrypoint did not both use selected Bash (calls=$calls)"
[[ "$(cat "$path_marker")" == "$original_path" ]] || fail "Bash selection changed PATH"

# Snapshot every tracked path in the real engine checkout using lstat metadata.
# Inode, mode, size, mtime, and ctime catch atomic schema replacement even when
# replacement bytes are identical.
snapshot_tracked_lstat() {
  python3 - "$ENGINE_HOME" "$1" <<'PY'
import json, os, subprocess, sys
root, output = sys.argv[1:3]
raw = subprocess.check_output(["git", "-C", root, "ls-files", "-z"])
paths = [p.decode("utf-8", "surrogateescape") for p in raw.split(b"\0") if p]
snapshot = {}
for rel in paths:
    path = os.path.join(root, rel)
    try:
        st = os.lstat(path)
        snapshot[rel] = [st.st_ino, st.st_mode, st.st_size, st.st_mtime_ns, st.st_ctime_ns]
    except FileNotFoundError:
        snapshot[rel] = None
with open(output, "w", encoding="utf-8") as f:
    json.dump(snapshot, f, sort_keys=True, separators=(",", ":"))
    f.write("\n")
PY
}

snapshot_tracked_lstat "$tmp/tracked-before.json"
real_status_out="$(
  cd "$ENGINE_HOME"
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  "$BASH" "$ENGINE_HOME/cli/singular" status
)"
snapshot_tracked_lstat "$tmp/tracked-after.json"
assert_contains "$real_status_out" "singular orchestration status" "real-checkout status output is preserved"
[[ "$real_status_out" == "$out" ]] || fail "real-checkout status output changed under observational check"
if ! cmp -s "$tmp/tracked-before.json" "$tmp/tracked-after.json"; then
  python3 - "$tmp/tracked-before.json" "$tmp/tracked-after.json" <<'PY' >&2
import json, sys
before, after = (json.load(open(p, encoding="utf-8")) for p in sys.argv[1:3])
for path in sorted(set(before) | set(after)):
    if before.get(path) != after.get(path):
        print(f"tracked path changed: {path}: {before.get(path)} -> {after.get(path)}")
PY
  fail "status changed tracked lstat metadata in the real engine checkout"
fi

# Status is observational: a consumer repo with no singular state/scaffold must
# remain byte-for-byte untouched by the status path.
consumer="$tmp/consumer"
mkdir -p "$consumer"
git -C "$consumer" init -q
before="$(find "$consumer" -mindepth 1 -not -path "$consumer/.git*" -print | sort)"
status_out="$(
  SINGULAR_ROOT="$consumer" \
  SINGULAR_ORCH_DIR="$consumer/docs/orchestration" \
  SINGULAR_STATE_DIR="$consumer/.singular-state" \
  SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  "$BASH" "$ENGINE_HOME/cli/singular" status
)"
assert_contains "$status_out" "singular orchestration status" "status output is preserved"
after="$(find "$consumer" -mindepth 1 -not -path "$consumer/.git*" -print | sort)"
[[ "$after" == "$before" ]] || fail "status created consumer paths: $after"
[[ ! -e "$consumer/.gitignore" ]] || fail "status touched .gitignore"
[[ ! -e "$consumer/.singular-state" ]] || fail "status created state"
[[ ! -e "$consumer/docs/orchestration" ]] || fail "status created orchestration scaffold"

# A mutating reconcile path still performs the missing bootstrap before its
# later repository validation, preserving the actuation/scaffold contract.
SINGULAR_ROOT="$consumer" \
SINGULAR_ORCH_DIR="$consumer/docs/orchestration" \
SINGULAR_STATE_DIR="$consumer/.singular-state" \
SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  "$BASH" "$ENGINE_HOME/engine/reconcile.sh" --dry-run >/dev/null 2>&1 || true
[[ -d "$consumer/.singular-state" ]] || fail "mutating reconcile did not create state"
[[ -d "$consumer/docs/orchestration" ]] || fail "mutating reconcile did not create scaffold"
[[ -f "$consumer/.gitignore" ]] || fail "mutating reconcile did not update .gitignore"

rc=0
out="$(SINGULAR_BASH_BOOTSTRAPPED=0 SINGULAR_BASH_BIN=bash "$BASH" "$ENGINE_HOME/cli/singular" version 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "relative SINGULAR_BASH_BIN must be rejected"
assert_contains "$out" "must be an absolute executable path" "invalid Bash pin has a clear error"

echo "PASS: test-executable-resolution"
