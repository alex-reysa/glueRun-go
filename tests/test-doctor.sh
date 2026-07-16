#!/usr/bin/env bash
set -euo pipefail

# P8 (0.5.0): doctor preflights — legacy pmgo ids (FAIL), broken
# ~/.codex/hooks.json (FAIL), model-prefix warnings, stale pidfiles (warn),
# disk floor. Each of these bit the field run undetected.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
fakehome="$tmp/home"
mkdir -p "$root/docs/orchestration/prompts" "$root/schemas/orchestration" \
  "$root/.gluerun-state" "$fakehome/.codex"
git -C "$root" init -q
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat >"$root/gluerun.config.json" <<'EOF'
{
  "schemaVersion": "v1",
  "targetBranch": "main",
  "gateCommand": "true",
  "env": { "GLUERUN_CODEX_MODEL": "gpt-5.6-sol", "GLUERUN_CLAUDE_MODEL": "bogus-model" }
}
EOF

doctor() {
  ( cd "$root" && env HOME="$fakehome" GLUERUN_ENGINE_HOME="$ENGINE_HOME" \
      bash "$ENGINE_HOME/cli/gluerun" doctor 2>&1 )
}

# 1. Clean baseline: hooks absent, no pmgo, models checked.
out="$(doctor)" || true
assert_contains "$out" "ok    codex model: gpt-5.6-sol" "known codex prefix ok"
assert_contains "$out" "warn  GLUERUN_CLAUDE_MODEL 'bogus-model'" "unknown claude prefix warns"
assert_contains "$out" "ok    no legacy pmgo.* schema ids" "pmgo clean"

# 2. Broken hooks.json -> FAIL (nonzero exit).
printf '' >"$fakehome/.codex/hooks.json"
rc=0; out="$(doctor)" || rc=$?
assert_contains "$out" "hooks.json is not valid JSON" "hooks parse failure surfaced"
[[ "$rc" -ne 0 ]] || fail "broken hooks.json must fail doctor"
printf '{}\n' >"$fakehome/.codex/hooks.json"
out="$(doctor)" || true
assert_contains "$out" "ok    ~/.codex/hooks.json parses" "fixed hooks ok"

# 3. Legacy pmgo id in a consumer prompt -> FAIL with migrate pointer.
printf 'emit "schema": "pmgo.orchestration.decider-verdict.v0"\n' \
  >"$root/docs/orchestration/prompts/decider.md"
rc=0; out="$(doctor)" || rc=$?
assert_contains "$out" "legacy pmgo.* schema ids found" "pmgo detected"
assert_contains "$out" "migrations/v0-to-v1.sh" "migrate pointer"
[[ "$rc" -ne 0 ]] || fail "pmgo ids must fail doctor"
rm -f "$root/docs/orchestration/prompts/decider.md"

# 4. Stale pidfile -> warn.
printf '99999999\n' >"$root/.gluerun-state/autonomate.pid"
out="$(doctor)" || true
assert_contains "$out" "stale pidfile" "stale pidfile warned"

echo "PASS: test-doctor"
