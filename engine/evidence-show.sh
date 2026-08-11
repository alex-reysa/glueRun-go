#!/usr/bin/env bash
set -euo pipefail

manifest="${1:-}"
ref="${2:-}"
max_bytes="${3:-32768}"
[[ -f "$manifest" && -n "$ref" ]] || {
  echo "usage: evidence-show.sh <manifest.json> <artifact-ref> [max-bytes]" >&2
  exit 2
}
[[ "$max_bytes" =~ ^[0-9]+$ ]] || {
  echo "evidence-show: max-bytes must be a non-negative integer" >&2
  exit 2
}
(( max_bytes <= 2048 )) || max_bytes=2048

python3 - "$manifest" "$ref" "$max_bytes" <<'PY'
import fcntl
import hashlib
import json
import os
import pathlib
import sys
import tempfile

manifest_path = pathlib.Path(sys.argv[1]).resolve()
ref = sys.argv[2]
requested = int(sys.argv[3])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
state_key = hashlib.sha256(str(manifest_path).encode("utf-8")).hexdigest()
state_root = pathlib.Path("/tmp/singular-evidence-retrieval-v0")
state_root.mkdir(mode=0o700, parents=True, exist_ok=True)
try:
    state_root.chmod(0o700)
except OSError:
    pass
state_path = state_root / f"{state_key}.bytes"
lock_path = state_root / f"{state_key}.lock"
budget = int(manifest.get("budget", {}).get("retrievalLimitBytes", 262144))
excerpt_budget = int(manifest.get("budget", {}).get("excerptLimitBytes", 2048))
excerpt_budget = max(0, min(2048, excerpt_budget))
requested = min(requested, excerpt_budget)
entries = {
    item.get("ref"): item
    for item in manifest.get("artifacts", [])
    if isinstance(item, dict) and isinstance(item.get("ref"), str)
}
if ref not in entries:
    sys.stderr.write(f"evidence-show: artifact is not declared in manifest: {ref}\n")
    sys.exit(3)
if ref.startswith("worktree/") or pathlib.PurePosixPath(ref).is_absolute() or ".." in pathlib.PurePosixPath(ref).parts:
    sys.stderr.write("evidence-show: only run-local raw artifacts are retrievable\n")
    sys.exit(3)
artifact = (manifest_path.parent / ref).resolve()
try:
    artifact.relative_to(manifest_path.parent)
except ValueError:
    sys.stderr.write("evidence-show: artifact escapes run directory\n")
    sys.exit(3)
if not artifact.is_file():
    sys.stderr.write(f"evidence-show: artifact missing: {ref}\n")
    sys.exit(3)
data = artifact.read_bytes()
actual_hash = hashlib.sha256(data).hexdigest()
if actual_hash != entries[ref].get("sha256"):
    sys.stderr.write(f"evidence-show: artifact hash mismatch: {ref}\n")
    sys.exit(4)
with lock_path.open("a+b") as lock_handle:
    fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
    try:
        used = int(state_path.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        used = 0
    remaining = max(0, budget - used)
    count = min(requested, remaining, len(data))
    if count <= 0 and data:
        sys.stderr.write("evidence-show: cumulative retrieval budget exhausted\n")
        sys.exit(5)
    fd, temporary = tempfile.mkstemp(
        prefix=state_path.name + ".", dir=str(state_path.parent)
    )
    try:
        with os.fdopen(fd, "w", encoding="ascii") as handle:
            handle.write(str(used + count) + "\n")
        os.replace(temporary, state_path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    sys.stdout.buffer.write(data[:count])
    if count < len(data):
        sys.stdout.buffer.write(b"\n[bounded evidence excerpt truncated]\n")
PY
