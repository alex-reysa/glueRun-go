#!/usr/bin/env bash
set -euo pipefail

# P1 (0.5.0): `gluerun promote-gate` honors the repo config `promoter` key
# (routed through engine/promote-gate.sh, which sources lib.sh); explicit env
# GLUERUN_PROMOTER beats config; a missing promoter dies with actionable text.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

root="$tmp/repo"
mkdir -p "$root/.gluerun-state" "$root/promoters" "$root/docs/orchestration/tasks"
git -C "$root" init -q
git -C "$root" checkout -q -b target
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

cat >"$root/promoters/config-promoter.sh" <<'SH'
#!/usr/bin/env bash
echo "CONFIG-PROMOTER argv:$*"
SH
chmod +x "$root/promoters/config-promoter.sh"
cat >"$root/promoters/env-promoter.sh" <<'SH'
#!/usr/bin/env bash
echo "ENV-PROMOTER argv:$*"
SH
chmod +x "$root/promoters/env-promoter.sh"

cat >"$root/gluerun.config.json" <<EOF
{
  "schemaVersion": "v1",
  "targetBranch": "target",
  "gateCommand": "true",
  "promoter": "$root/promoters/config-promoter.sh"
}
EOF

run_wrapper() {
  env GLUERUN_ROOT="$root" GLUERUN_STATE_DIR="$root/.gluerun-state" \
    GLUERUN_ENGINE_HOME="$ENGINE_HOME" GLUERUN_TARGET_BRANCH=target "$@" \
    bash "$ENGINE_HOME/engine/promote-gate.sh" some-node 2>&1
}

# 1. Config promoter key is honored (the 0.4.0 defect: CLI never saw it).
out="$(run_wrapper env)"
assert_contains "$out" "CONFIG-PROMOTER argv:some-node" "config promoter invoked"

# 2. Explicit env GLUERUN_PROMOTER beats config.
out="$(run_wrapper env GLUERUN_PROMOTER="$root/promoters/env-promoter.sh")"
assert_contains "$out" "ENV-PROMOTER argv:some-node" "env promoter wins over config"

# 3. Missing promoter dies with actionable guidance.
rc=0
out="$(run_wrapper env GLUERUN_PROMOTER="$root/promoters/nope.sh")" || rc=$?
[[ "$rc" -eq 2 ]] || fail "missing promoter should exit 2 (rc=$rc)"
assert_contains "$out" 'Set "promoter" in gluerun.config.json' "actionable error"

# 4. Through the CLI dispatch table.
out="$(cd "$root" && env GLUERUN_ENGINE_HOME="$ENGINE_HOME" GLUERUN_TARGET_BRANCH=target \
  bash "$ENGINE_HOME/cli/gluerun" promote-gate some-node 2>&1)"
assert_contains "$out" "CONFIG-PROMOTER argv:some-node" "CLI promote-gate honors config"

echo "PASS: test-promote-gate-cli"
