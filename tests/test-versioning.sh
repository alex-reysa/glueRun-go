#!/usr/bin/env bash
# Covers the version/schema plumbing in cli/gluerun:
#   - doctor FAILs on a repo-vs-engine schemaVersion mismatch
#   - doctor WARNs when .gluerun-version and config engineVersion disagree,
#     while .gluerun-version stays authoritative for resolution
#   - gluerun migrate: clean no-op when versions match
#   - gluerun migrate: hard error when the repo is behind and no script exists
#   - gluerun migrate: a dummy v0-to-v1.sh runs and schemaVersion advances
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ENGINE_HOME/cli/gluerun"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# repo fixture: git repo + gluerun.config.json with given schemaVersion [engineVersion]
make_repo() { # dir schemaVersion [engineVersion]
  mkdir -p "$1"
  git -C "$1" init -q
  python3 - "$1/gluerun.config.json" "$2" "${3:-}" <<'PY'
import json, sys
path, sv, ev = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {"targetBranch": "agent/integration", "gateCommand": "true", "areas": {}}
if sv:
    cfg["schemaVersion"] = sv
if ev:
    cfg["engineVersion"] = ev
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
}

# minimal fake engine install (enough for GLUERUN_ENGINE_HOME / pin resolution)
make_engine() { # dir version schemaVersion
  mkdir -p "$1/engine" "$1/schemas" "$1/migrations"
  echo "$2" > "$1/VERSION"
  echo "$3" > "$1/SCHEMA_VERSION"
  : > "$1/engine/lib.sh"
  : > "$1/schemas/gate-result.v0.schema.json"
}

# --- (a) doctor FAILs on schemaVersion mismatch -------------------------------
make_repo "$tmp/repo-a" v9
out="$(cd "$tmp/repo-a" && GLUERUN_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" doctor 2>&1)"
rc=$?
[[ "$rc" -ne 0 ]] || fail "doctor should exit nonzero on schemaVersion mismatch"
assert_contains "$out" "FAIL  schemaVersion mismatch: repo v9 vs engine v2" "doctor mismatch FAIL line"
assert_contains "$out" "[schema.version]" "doctor identifies the schema-version check"
assert_contains "$out" "engine resolved ($ENGINE_HOME, v0.13.0)" "doctor reports resolved engine version"

# --- (b) pin disagreement: WARN, .gluerun-version stays authoritative ------------
fake_home="$tmp/home"
make_engine "$fake_home/.gluerun/versions/9.9.9" "9.9.9" "v0"
make_repo "$tmp/repo-b" v0 "1.2.3"
echo "9.9.9" > "$tmp/repo-b/.gluerun-version"

# A normal command warns, then succeeds against the engine selected by the pin.
out="$(cd "$tmp/repo-b" && HOME="$fake_home" bash "$CLI" migrate 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "migrate should still succeed under pin disagreement (rc=$rc, out=$out)"
assert_contains "$out" "gluerun: warning: .gluerun-version (9.9.9) and gluerun.config.json engineVersion (1.2.3) disagree; using .gluerun-version" "repo_pin stderr warning"
assert_contains "$out" "repo schema v0 matches engine schema" "resolution unchanged: .gluerun-version wins over engineVersion"

# --- (c) migrate no-ops cleanly when schema versions match --------------------
make_repo "$tmp/repo-c" v2
out="$(cd "$tmp/repo-c" && GLUERUN_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" migrate 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "migrate should exit 0 when up to date (rc=$rc, out=$out)"
assert_contains "$out" "up to date, nothing to do" "migrate up-to-date no-op message"

# --- (d) migrate errors clearly when behind with no script --------------------
make_engine "$tmp/engine-v2" "0.2.0" "v2"
make_repo "$tmp/repo-d" v0
out="$(cd "$tmp/repo-d" && GLUERUN_ENGINE_HOME="$tmp/engine-v2" bash "$CLI" migrate 2>&1)"
rc=$?
[[ "$rc" -ne 0 ]] || fail "migrate should exit nonzero when behind with no migration script"
assert_contains "$out" "no migration found for v0 -> v2" "migrate missing-script error"
assert_contains "$out" "CHANGELOG" "migrate missing-script error points at CHANGELOG"
sv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schemaVersion"])' "$tmp/repo-d/gluerun.config.json")"
[[ "$sv" == "v0" ]] || fail "failed migrate must not advance schemaVersion (got $sv)"

# --- (e) dummy migration runs and schemaVersion advances ----------------------
make_engine "$tmp/engine-v1" "0.2.0" "v1"
cat > "$tmp/engine-v1/migrations/v0-to-v1.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
repo="$1"
[[ -f "$repo/gluerun.config.json" ]] || { echo "v0-to-v1: no config in $repo" >&2; exit 1; }
touch "$repo/MIGRATED-v0-to-v1"
EOF
chmod +x "$tmp/engine-v1/migrations/v0-to-v1.sh"
make_repo "$tmp/repo-e" v0
out="$(cd "$tmp/repo-e" && GLUERUN_ENGINE_HOME="$tmp/engine-v1" bash "$CLI" migrate 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "migrate should succeed with v0-to-v1.sh present (rc=$rc, out=$out)"
assert_contains "$out" "run   v0-to-v1.sh (v0 -> v1)" "migrate announces the step"
assert_contains "$out" "repo is now at schema v1" "migrate completion message"
[[ -f "$tmp/repo-e/MIGRATED-v0-to-v1" ]] || fail "migration script did not run against the repo"
sv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schemaVersion"])' "$tmp/repo-e/gluerun.config.json")"
[[ "$sv" == "v1" ]] || fail "schemaVersion should advance to v1 (got $sv)"

echo "versioning tests passed"
