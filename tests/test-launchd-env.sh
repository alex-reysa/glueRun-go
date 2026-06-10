#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg: missing '$needle' in: $haystack"
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$msg: unexpectedly found '$needle' in: $haystack"
}

test_launchd_wrapper_sources_env_and_defaults_autonomy_flags() {
  local tmp fake_codex codex_home env_file out
  tmp="$(mktemp -d)"
  fake_codex="$tmp/codex"
  codex_home="$tmp/codex-home"
  env_file="$tmp/gluerun.env"
  mkdir -p "$codex_home"
  printf '{}\n' >"$codex_home/auth.json"
  cat >"$fake_codex" <<'EOF'
#!/usr/bin/env bash
echo "codex 0.0-test"
EOF
  chmod +x "$fake_codex"
  cat >"$env_file" <<'EOF'
GLUERUN_STORAGE_PROOF_DATABASE_URL=postgres://gluerun-secret.example/proof
EOF

  out="$(
    HOME="$tmp/home" \
    CODEX_HOME="$codex_home" \
    CODEX_BIN="$fake_codex" \
    GLUERUN_ENV_FILE="$env_file" \
    GLUERUN_LAUNCHD_MODE=--print-env \
    bash "$ENGINE_HOME/templates/launchd/run-orchestrator.sh"
  )"

  assert_contains "$out" "GLUERUN_ENV_FILE=$env_file" "env file path is reported"
  assert_contains "$out" "GLUERUN_STORAGE_PROOF_DATABASE_URL=SET" "storage proof DSN is loaded without disclosure"
  assert_contains "$out" "GLUERUN_AUTO_PROMOTE_GATES=1" "auto gate promotion defaults on"
  assert_contains "$out" "GLUERUN_L2_SANDBOX=danger-full-access" "network-capable L2 sandbox defaults on"
  assert_contains "$out" "GLUERUN_ENABLE_L1_PARALLEL=1" "parallel L1 defaults on"
  assert_contains "$out" "GLUERUN_MAX_L1_CONCURRENT=3" "parallel L1 cap defaults to 3"
  assert_contains "$out" "GLUERUN_L1_TASKS_PER_NODE=1" "per-node L1 task cap defaults to 1"
  assert_contains "$out" "GLUERUN_L2_SLICE_BUDGET=1" "per-task slice budget defaults to 1 (byte-identical)"
  assert_contains "$out" "GLUERUN_L2_SLICE_BUDGET_MAX=3" "slice budget cap defaults to 3"
  assert_contains "$out" "GLUERUN_MAX_CONCURRENT=5" "worker concurrency cap defaults to 5"
  assert_contains "$out" "GLUERUN_MAX_DISPATCH=5" "dispatch cap defaults to 5"
  assert_contains "$out" "GLUERUN_MAX_HOURS=12" "watchdog time box defaults to 12 hours"
  assert_not_contains "$out" "gluerun-secret.example" "database URL is not printed"
}

test_launchd_wrapper_sources_env_and_defaults_autonomy_flags

echo "test-launchd-env: ok"
