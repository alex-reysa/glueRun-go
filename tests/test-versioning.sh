#!/usr/bin/env bash
# Covers the version/schema plumbing in cli/singular:
#   - doctor FAILs on a repo-vs-engine schemaVersion mismatch
#   - doctor WARNs when .singular-version and config engineVersion disagree,
#     while .singular-version stays authoritative for resolution
#   - singular migrate: clean no-op when versions match
#   - singular migrate: hard error when the repo is behind and no script exists
#   - singular migrate: a dummy v0-to-v1.sh runs and schemaVersion advances
#   - singular migrate --dry-run: resolves and prints the whole chain, touching
#     neither the config nor the repo
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${SINGULAR_CLI_UNDER_TEST:-$ENGINE_HOME/cli/singular}"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# repo fixture: git repo + singular.config.json with given schemaVersion [engineVersion]
make_repo() { # dir schemaVersion [engineVersion]
  mkdir -p "$1"
  git -C "$1" init -q
  python3 - "$1/singular.config.json" "$2" "${3:-}" <<'PY'
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

# minimal fake engine install (enough for SINGULAR_ENGINE_HOME / pin resolution)
make_engine() { # dir version schemaVersion
  mkdir -p "$1/engine" "$1/schemas" "$1/migrations"
  echo "$2" > "$1/VERSION"
  echo "$3" > "$1/SCHEMA_VERSION"
  : > "$1/engine/lib.sh"
  : > "$1/schemas/gate-result.v0.schema.json"
}

# --- (a) doctor FAILs on schemaVersion mismatch -------------------------------
make_repo "$tmp/repo-a" v9
out="$(cd "$tmp/repo-a" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" doctor 2>&1)"
rc=$?
[[ "$rc" -ne 0 ]] || fail "doctor should exit nonzero on schemaVersion mismatch"
assert_contains "$out" "FAIL  schemaVersion mismatch: repo v9 vs engine v2" "doctor mismatch FAIL line"
assert_contains "$out" "[schema.version]" "doctor identifies the schema-version check"
assert_contains "$out" "engine resolved ($ENGINE_HOME, v$(tr -d '[:space:]' <"$ENGINE_HOME/VERSION"))" \
  "doctor reports resolved engine version"

# --- (b) pin disagreement: WARN, .singular-version stays authoritative ------------
fake_home="$tmp/home"
make_engine "$fake_home/.singular/versions/9.9.9" "9.9.9" "v0"
make_repo "$tmp/repo-b" v0 "1.2.3"
echo "9.9.9" > "$tmp/repo-b/.singular-version"

# A normal command warns, then succeeds against the engine selected by the pin.
out="$(cd "$tmp/repo-b" && env -u SINGULAR_ENGINE_HOME -u SINGULAR_HOME \
  HOME="$fake_home" bash "$CLI" migrate 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "migrate should still succeed under pin disagreement (rc=$rc, out=$out)"
assert_contains "$out" "singular: warning: .singular-version (9.9.9) and singular.config.json engineVersion (1.2.3) disagree; using .singular-version" "repo_pin stderr warning"
assert_contains "$out" "repo schema v0 matches engine schema" "resolution unchanged: .singular-version wins over engineVersion"

# --- (b2) custom SINGULAR_HOME is the only machine-install root --------------
# A pinned consumer must resolve from the configured root without consulting or
# creating the default under HOME. `version` names the actual selected path, so
# this remains a runtime resolution test rather than a source-text assertion.
default_home="$tmp/home-custom-default"
custom_home="$tmp/singular-custom"
mkdir -p "$default_home"
make_engine "$custom_home/versions/8.8.8" "8.8.8" "v8"
make_repo "$tmp/repo-b2" v8
echo "8.8.8" > "$tmp/repo-b2/.singular-version"
[[ ! -e "$default_home/.singular" ]] || fail "custom-home fixture started with a default install"

out="$(cd "$tmp/repo-b2" && env -u SINGULAR_ENGINE_HOME \
  HOME="$default_home" SINGULAR_HOME="$custom_home" bash "$CLI" version 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "custom SINGULAR_HOME pin should resolve (rc=$rc, out=$out)"
assert_contains "$out" "engine      8.8.8  ($custom_home/versions/8.8.8)" \
  "custom SINGULAR_HOME selects the pinned engine"
[[ ! -e "$default_home/.singular" ]] || fail "custom-home resolution touched HOME/.singular"

out="$(cd "$tmp/repo-b2" && env -u SINGULAR_ENGINE_HOME \
  HOME="$default_home" SINGULAR_HOME="relative-home" bash "$CLI" version 2>&1)"
rc=$?
[[ "$rc" -ne 0 ]] || fail "CLI accepted a relative SINGULAR_HOME"
assert_contains "$out" "SINGULAR_HOME must be an absolute path" \
  "CLI rejects cwd-dependent machine-install roots"

# `update` has a second lookup path: with no argument it reads `current` before
# writing the repo pin. Exercise that path against the same custom root.
ln -s "versions/8.8.8" "$custom_home/current"
make_repo "$tmp/repo-b2-update" v8
out="$(cd "$tmp/repo-b2-update" && env -u SINGULAR_ENGINE_HOME \
  HOME="$default_home" SINGULAR_HOME="$custom_home" bash "$CLI" update 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "update should read current from custom SINGULAR_HOME (rc=$rc, out=$out)"
[[ "$(tr -d '[:space:]' < "$tmp/repo-b2-update/.singular-version")" == "8.8.8" ]] \
  || fail "update did not pin the version from custom SINGULAR_HOME/current"
[[ ! -e "$default_home/.singular" ]] || fail "custom-home update touched HOME/.singular"

# `setup` invokes install.sh before an engine is available. A deliberately
# failing checkout installer records its environment, proving the child sees
# the same custom root and that recovery guidance preserves it.
fake_checkout="$tmp/fake-checkout"
mkdir -p "$fake_checkout/cli" "$fake_checkout/engine"
cp "$CLI" "$fake_checkout/cli/singular"
: > "$fake_checkout/engine/lib.sh"
echo "7.7.7" > "$fake_checkout/VERSION"
cat > "$fake_checkout/install.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${SINGULAR_HOME:-<unset>}" > "${SINGULAR_INSTALL_RECORD:?}"
exit 23
SH
repo_setup="$tmp/repo-b2-setup"
make_repo "$repo_setup" v8
echo "7.7.7" > "$repo_setup/.singular-version"
git -C "$repo_setup" add singular.config.json .singular-version
git -C "$repo_setup" -c user.name=test -c user.email=test@example.local commit -q -m fixture
install_record="$tmp/install-home.txt"
out="$(cd "$repo_setup" && env -u SINGULAR_ENGINE_HOME \
  HOME="$default_home" SINGULAR_HOME="$custom_home" \
  SINGULAR_INSTALL_RECORD="$install_record" \
  bash "$fake_checkout/cli/singular" setup --no-test 2>&1)"
rc=$?
[[ "$rc" -ne 0 ]] || fail "failing setup installer fixture should fail"
[[ -f "$install_record" ]] || fail "setup did not invoke the checkout installer"
[[ "$(tr -d '\n' < "$install_record")" == "$custom_home" ]] \
  || fail "setup child installer did not inherit custom SINGULAR_HOME"
assert_contains "$out" "SINGULAR_HOME=$custom_home" \
  "setup recovery guidance preserves the custom install root"
[[ ! -e "$default_home/.singular" ]] || fail "custom-home setup touched HOME/.singular"

# The installer itself must create and describe that same layout. Use a minimal
# checkout and put its future bin directory on PATH so this stays hermetic (the
# installer's optional /usr/local/bin convenience link is never considered).
installer_checkout="$tmp/installer-checkout"
installer_home="$tmp/installer-custom-home"
mkdir -p "$installer_checkout/engine"
cp "$ENGINE_HOME/install.sh" "$installer_checkout/install.sh"
cp "$ENGINE_HOME/engine/bash-guard.sh" "$installer_checkout/engine/bash-guard.sh"
cp "$ENGINE_HOME/engine/lib.sh" "$installer_checkout/engine/lib.sh"
echo "6.6.6" > "$installer_checkout/VERSION"
out="$(HOME="$default_home" SINGULAR_HOME="$installer_home" \
  PATH="$installer_home/bin:$PATH" bash "$installer_checkout/install.sh" 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "installer should honor custom SINGULAR_HOME (rc=$rc, out=$out)"
[[ -f "$installer_home/versions/6.6.6/engine/lib.sh" ]] \
  || fail "installer did not create the version under custom SINGULAR_HOME"
[[ "$(readlink "$installer_home/current")" == "$installer_home/versions/6.6.6" ]] \
  || fail "installer current link does not target the custom root"
assert_contains "$out" "export SINGULAR_HOME=$installer_home" \
  "installer explains how to persist a custom install root"
assert_contains "$out" "$installer_home/bin is already on PATH." \
  "installer PATH guidance names the custom root"
[[ ! -e "$default_home/.singular" ]] || fail "custom-home installer touched HOME/.singular"

out="$(cd "$tmp" && HOME="$default_home" SINGULAR_HOME="relative-home" \
  PATH="$PATH" bash "$installer_checkout/install.sh" 2>&1)"
rc=$?
[[ "$rc" -ne 0 ]] || fail "installer accepted a relative SINGULAR_HOME"
assert_contains "$out" "SINGULAR_HOME must be an absolute path" \
  "installer rejects broken relative symlink roots"
[[ ! -e "$tmp/relative-home" ]] || fail "rejected relative install created a partial root"

# --- (c) migrate no-ops cleanly when schema versions match --------------------
make_repo "$tmp/repo-c" v2
out="$(cd "$tmp/repo-c" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" migrate 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "migrate should exit 0 when up to date (rc=$rc, out=$out)"
assert_contains "$out" "up to date, nothing to do" "migrate up-to-date no-op message"

# --- (d) migrate errors clearly when behind with no script --------------------
make_engine "$tmp/engine-v2" "0.2.0" "v2"
make_repo "$tmp/repo-d" v0
out="$(cd "$tmp/repo-d" && SINGULAR_ENGINE_HOME="$tmp/engine-v2" bash "$CLI" migrate 2>&1)"
rc=$?
[[ "$rc" -ne 0 ]] || fail "migrate should exit nonzero when behind with no migration script"
assert_contains "$out" "no migration found for v0 -> v2" "migrate missing-script error"
assert_contains "$out" "CHANGELOG" "migrate missing-script error points at CHANGELOG"
sv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schemaVersion"])' "$tmp/repo-d/singular.config.json")"
[[ "$sv" == "v0" ]] || fail "failed migrate must not advance schemaVersion (got $sv)"

# --- (e) dummy migration runs and schemaVersion advances ----------------------
make_engine "$tmp/engine-v1" "0.2.0" "v1"
cat > "$tmp/engine-v1/migrations/v0-to-v1.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
repo="$1"
[[ -f "$repo/singular.config.json" ]] || { echo "v0-to-v1: no config in $repo" >&2; exit 1; }
touch "$repo/MIGRATED-v0-to-v1"
EOF
chmod +x "$tmp/engine-v1/migrations/v0-to-v1.sh"
make_repo "$tmp/repo-e" v0
out="$(cd "$tmp/repo-e" && SINGULAR_ENGINE_HOME="$tmp/engine-v1" bash "$CLI" migrate 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "migrate should succeed with v0-to-v1.sh present (rc=$rc, out=$out)"
assert_contains "$out" "run   v0-to-v1.sh (v0 -> v1)" "migrate announces the step"
assert_contains "$out" "repo is now at schema v1" "migrate completion message"
[[ -f "$tmp/repo-e/MIGRATED-v0-to-v1" ]] || fail "migration script did not run against the repo"
sv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schemaVersion"])' "$tmp/repo-e/singular.config.json")"
[[ "$sv" == "v1" ]] || fail "schemaVersion should advance to v1 (got $sv)"

# --- (f) --dry-run resolves the whole chain and changes nothing --------------
# "What will this do to my repository" must be answerable without finding out.
# The dry run walks the same discovery as the real loop, across more than one
# step, and is required to leave both the config and the repo untouched.
make_engine "$tmp/engine-dry" "0.2.0" "v2"
for step in v0-to-v1 v1-to-v2; do
  cat > "$tmp/engine-dry/migrations/$step.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
touch "\$1/MIGRATED-$step"
EOF
  chmod +x "$tmp/engine-dry/migrations/$step.sh"
done
make_repo "$tmp/repo-f" v0
before="$(shasum "$tmp/repo-f/singular.config.json" | awk '{print $1}')"
out="$(cd "$tmp/repo-f" && SINGULAR_ENGINE_HOME="$tmp/engine-dry" bash "$CLI" migrate --dry-run 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "migrate --dry-run should exit 0 (rc=$rc, out=$out)"
assert_contains "$out" "would run: v0-to-v1.sh (v0 -> v1)" "dry run announces the first step"
assert_contains "$out" "would run: v1-to-v2.sh (v1 -> v2)" "dry run announces the second step"
assert_contains "$out" "nothing was changed" "dry run says it changed nothing"
[[ "$out" != *"  run   "* ]] || fail "dry run must not report a migration as run: $out"
after="$(shasum "$tmp/repo-f/singular.config.json" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail "dry run rewrote singular.config.json"
compgen -G "$tmp/repo-f/MIGRATED-*" >/dev/null \
  && fail "dry run executed a migration script"

# The same flag on an up-to-date repo is the existing no-op, not a new message.
make_repo "$tmp/repo-f2" v2
out="$(cd "$tmp/repo-f2" && SINGULAR_ENGINE_HOME="$ENGINE_HOME" bash "$CLI" migrate --dry-run 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "migrate --dry-run should exit 0 when up to date (rc=$rc, out=$out)"
assert_contains "$out" "up to date, nothing to do" "dry run reuses the up-to-date no-op message"

# A dry run must never be able to become a real one by falling through.
make_repo "$tmp/repo-f3" v0
out="$(cd "$tmp/repo-f3" && SINGULAR_ENGINE_HOME="$tmp/engine-v2" bash "$CLI" migrate --dry-run 2>&1)"
rc=$?
[[ "$rc" -ne 0 ]] || fail "dry run must fail on an unresolvable chain like the real path"
assert_contains "$out" "no migration found for v0 -> v2" "dry run reports the same missing-script error"
sv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schemaVersion"])' "$tmp/repo-f3/singular.config.json")"
[[ "$sv" == "v0" ]] || fail "a failed dry run must not advance schemaVersion (got $sv)"

echo "versioning tests passed"
