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
fakebin="$tmp/bin"
mkdir -p "$root/docs/orchestration/prompts" "$root/schemas/orchestration" \
  "$root/.gluerun-state" "$fakehome/.codex" "$fakebin"
for schema in "$ENGINE_HOME"/schemas/*.schema.json; do
  cp "$schema" "$root/schemas/orchestration/"
done
git -C "$root" init -q
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat >"$fakebin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${DOCTOR_CODEX_SLEEP:-0}" == "1" ]]; then sleep 30; fi
case "${1:-} ${2:-}" in
  "--version ") echo "codex-cli test-1.0" ;;
  "login status")
    [[ "${DOCTOR_CODEX_AUTH_FAIL:-0}" == "1" ]] && { echo "Not logged in"; exit 1; }
    echo "Logged in using test credentials"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fakebin/codex"
cat >"$root/gluerun.config.json" <<'EOF'
{
  "schemaVersion": "v2",
  "targetBranch": "main",
  "gateCommand": "true",
  "env": { "GLUERUN_CODEX_MODEL": "gpt-5.6-sol", "GLUERUN_CLAUDE_MODEL": "bogus-model" }
}
EOF

doctor() {
  (
    cd "$root"
    extra_env=()
    [[ -n "${DOCTOR_CODEX_BIN:-}" ]] && extra_env+=("GLUERUN_CODEX_BIN=$DOCTOR_CODEX_BIN")
    env HOME="$fakehome" GLUERUN_ENGINE_HOME="$ENGINE_HOME" GLUERUN_MIN_DISK_GB=0 \
      PATH="${DOCTOR_PATH:-$fakebin:$PATH}" "${extra_env[@]}" \
      bash "$ENGINE_HOME/cli/gluerun" doctor 2>&1
  )
}

# 1. Clean baseline: hooks absent, no pmgo, models checked.
out="$(doctor)" || true
assert_contains "$out" "ok    codex model: gpt-5.6-sol" "known codex prefix ok"
assert_contains "$out" "warn  GLUERUN_CLAUDE_MODEL 'bogus-model'" "unknown claude prefix warns"
assert_contains "$out" "selected Codex executable: $fakebin/codex" "selected codex path reported"
assert_contains "$out" "ok    selected Codex spawn: codex-cli test-1.0" "selected codex is spawned"
assert_contains "$out" "ok    selected Codex authentication" "selected codex auth is checked"
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

# 5. A broken first PATH candidate is not hidden by a later healthy Codex.
brokenbin="$tmp/broken-bin"
mkdir -p "$brokenbin"
cat >"$brokenbin/codex" <<'EOF'
#!/usr/bin/env bash
echo "Error: packaged native executable ENOENT" >&2
exit 1
EOF
chmod +x "$brokenbin/codex"
rc=0
out="$(DOCTOR_PATH="$brokenbin:$fakebin:$PATH" doctor)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "broken selected Codex must fail doctor"
assert_contains "$out" "selected Codex executable: $brokenbin/codex" "doctor reports broken selected path"
assert_contains "$out" "selected Codex spawn probe failed" "broken native spawn is surfaced"
assert_contains "$out" "ENOENT" "spawn failure preserves useful diagnostic"

# 6. GLUERUN_CODEX_BIN pins the healthy executable independently from PATH.
out="$(DOCTOR_PATH="$brokenbin:$fakebin:$PATH" DOCTOR_CODEX_BIN="$fakebin/codex" doctor)"
assert_contains "$out" "selected Codex executable: $fakebin/codex" "explicit Codex pin wins"
assert_contains "$out" "ok    selected Codex authentication" "pinned Codex auth passes"

# 7. Spawn success is insufficient when the selected CLI reports logged out.
rc=0
out="$(DOCTOR_CODEX_AUTH_FAIL=1 doctor)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "unauthenticated selected Codex must fail doctor"
assert_contains "$out" "selected Codex authentication probe failed" "auth failure surfaced"

# 8. Provider probes are bounded and kill a hung wrapper/native process group.
rc=0
out="$(DOCTOR_CODEX_SLEEP=1 doctor)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "hung selected Codex must fail doctor"
assert_contains "$out" "probe timed out after 10s" "spawn timeout surfaced"

echo "PASS: test-doctor"
