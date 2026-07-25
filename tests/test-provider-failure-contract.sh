#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gluerun-provider-result.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
PY
}

repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.name=test -c user.email=test@example.local \
  commit --allow-empty -q -m init
export GLUERUN_ROOT="$repo"
export GLUERUN_STATE_DIR="$repo/.gluerun-state"
export GLUERUN_EVENTS_FILE="$GLUERUN_STATE_DIR/events.ndjson"
export GLUERUN_RUNS_DIR="$GLUERUN_STATE_DIR/runs"
export GLUERUN_PLANNER_BACKOFF_FILE="$GLUERUN_STATE_DIR/planner-backoff.json"
# shellcheck source=../engine/lib.sh
source "$ENGINE_HOME/engine/lib.sh"
gluerun_ensure_state_dirs

write_result() {
  local provider="$1" envelope_json="$2" exit_code="${3:-4}"
  local dir="$GLUERUN_RUNS_DIR/RUN-$provider"
  mkdir -p "$dir"
  printf '%s\n' "$envelope_json" >"$dir/envelope.json"
  gluerun_runner_result_write "$provider" "RUN-$provider" planner planner-core \
    "$dir/runner-result.json" "$exit_code" "$dir/envelope.json" "" "$dir/out.json"
  printf '%s\n' "$dir/runner-result.json"
}

# Every built-in adapter advertises the same v1 additions without requiring its
# provider binary or a worktree.
for provider in codex claude gemini opencode cursor grok; do
  contract="$("$ENGINE_HOME/engine/$provider-run.sh" --describe-contract)"
  python3 - "$provider" "$contract" <<'PY' || fail "$provider contract"
import json, sys
provider, raw = sys.argv[1:3]
doc = json.loads(raw)
assert doc["schema"] == "gluerun.runner-contract.v1"
assert doc["version"] == 1 and doc["provider"] == provider
for arg in ("--describe-contract", "--role", "--capability-profile", "--result-file"):
    assert arg in doc["arguments"]
assert "--stage-dir" not in doc["arguments"]
PY
done
pass "all built-in runners advertise contract v1"

# Host invocation uses the public argv for a negotiated custom v1 runner. The
# environment remains a legacy compatibility aid, not the advertised seam.
contract_runner="$tmp/custom-contract-v1"
contract_capture="$tmp/custom-contract-v1-argv.json"
python3 - "$contract_runner" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
script = r'''#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--describe-contract" ]]; then
  printf '%s\n' '{"schema":"gluerun.runner-contract.v1","version":1,"provider":"custom","arguments":["--worktree","--prompt-file","--level","--run-id","--role","--capability-profile","--result-file","--describe-contract"],"structuredResult":"gluerun.orchestration.runner-result.v0","structuredProviderError":"gluerun.orchestration.provider-error.v0"}'
  exit 0
fi
python3 - "$CONTRACT_CAPTURE" "$@" <<'ARGS'
import json
import sys
json.dump(sys.argv[2:], open(sys.argv[1], "w", encoding="utf-8"))
ARGS
'''
with open(path, "w", encoding="utf-8") as handle:
    handle.write(script)
os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
PY
gluerun_runner_contract_prepare \
  "$contract_runner" auditor audit-core "$tmp/custom-result.json"
CONTRACT_CAPTURE="$contract_capture" \
  "$contract_runner" "${GLUERUN_RUNNER_CONTRACT_ARGS[@]}" --worktree "$repo"
python3 - "$contract_capture" <<'PY' || fail "host omitted negotiated runner v1 argv"
import json
import sys
argv = json.load(open(sys.argv[1], encoding="utf-8"))
for pair in (
    ("--role", "auditor"),
    ("--capability-profile", "audit-core"),
    ("--result-file", sys.argv[1].replace("custom-contract-v1-argv.json", "custom-result.json")),
):
    index = argv.index(pair[0])
    assert argv[index + 1] == pair[1], argv
assert "--stage-dir" not in argv
PY
pass "host passes negotiated runner contract v1 argv"

# A valid invocation always leaves a result, even when provider preflight fails
# before an envelope exists. Contract-description calls above remain artifact-free.
export GLUERUN_TARGET_BRANCH
GLUERUN_TARGET_BRANCH="$(git -C "$repo" branch --show-current)"
prompt="$tmp/preflight-prompt.md"
printf 'preflight only\n' >"$prompt"
for provider in codex claude gemini opencode cursor grok; do
  result="$tmp/$provider-preflight-runner-result.json"
  ec=0
  if [[ "$provider" == "codex" ]]; then
    PATH=/usr/bin:/bin GLUERUN_CODEX_BIN="/definitely/missing/gluerun-codex" \
      bash "$ENGINE_HOME/engine/$provider-run.sh" -C "$repo" --level l2 \
        --run-id "RUN-preflight-$provider" --prompt-file "$prompt" \
        --result-file "$result" >/dev/null 2>&1 || ec=$?
  else
    PATH=/usr/bin:/bin \
      bash "$ENGINE_HOME/engine/$provider-run.sh" -C "$repo" --level l2 \
        --run-id "RUN-preflight-$provider" --prompt-file "$prompt" \
        --result-file "$result" >/dev/null 2>&1 || ec=$?
  fi
  [[ "$ec" -eq 127 ]] || fail "$provider missing executable should exit 127 (got $ec)"
  [[ -f "$result" ]] || fail "$provider preflight failure omitted runner result"
  [[ "$(json_field "$result" exitCode)" == "127" ]] \
    || fail "$provider preflight result exit code mismatch"
  [[ "$(json_field "$result" failureClass)" == "provider-exit" ]] \
    || fail "$provider preflight failure class mismatch"
done
pass "all built-in runners write results for provider preflight failures"

# Cross-provider structured terminal status normalization.
declare -A envelopes=(
  [codex]='{"type":"turn.failed","error":{"status":429,"code":"rate_limit_exceeded","message":"request rejected"}}'
  [claude]='{"type":"result","subtype":"error","is_error":true,"api_error_status":529,"result":"provider unavailable"}'
  [gemini]='{"error":{"status":503,"code":"service_unavailable","message":"provider unavailable"}}'
  [opencode]='{"type":"error","error":{"name":"RateLimitError","data":{"statusCode":429,"code":"rate_limit_exceeded","message":"request rejected"}}}'
  [cursor]='{"type":"result","is_error":true,"status":429,"code":"rate_limit_exceeded","result":"request rejected"}'
  [grok]='{"type":"error","error":{"http_status":429,"code":"rate_limit_exceeded","message":"request rejected"}}'
)
for provider in codex claude gemini opencode cursor grok; do
  result="$(write_result "$provider" "${envelopes[$provider]}")"
  evidence="$(gluerun_runner_quota_evidence_json "$result")" \
    || fail "$provider structured terminal status was not accepted"
  [[ "$(json_field "$result" failureClass)" == "quota" ]] \
    || fail "$provider runner result not quota"
  [[ "$evidence" == *"\"provider\":\"$provider\""* ]] \
    || fail "$provider missing from evidence"
done
pass "cross-provider terminal envelopes normalize to bound quota evidence"

# Raw provider evidence remains byte-for-byte available after each runner
# removes its private temp files, and both raw references are hash-bound.
python3 - "$result" <<'PY' || fail "raw provider artifacts are not hash-bound"
import hashlib
import json
import pathlib
import sys

result_path = pathlib.Path(sys.argv[1])
runner = json.loads(result_path.read_text(encoding="utf-8"))
envelope = pathlib.Path(runner["providerEnvelopeRef"])
assert hashlib.sha256(envelope.read_bytes()).hexdigest() == runner["providerEnvelopeSha256"]
error_path = pathlib.Path(runner["providerErrorRef"])
error = json.loads(error_path.read_text(encoding="utf-8"))
raw_event = pathlib.Path(error["rawEventRef"])
assert hashlib.sha256(raw_event.read_bytes()).hexdigest() == error["rawEventSha256"]
raw_event.write_bytes(raw_event.read_bytes() + b" ")
PY
gluerun_runner_quota_evidence_json "$result" >/dev/null 2>&1 \
  && fail "tampered raw provider event passed evidence validation"
pass "raw provider artifacts remain available and tamper-evident"

# Provider error codes without the exact provider-controlled HTTP status remain
# ordinary runner failures, even inside an otherwise valid terminal envelope.
for spec in \
  'codex|{"type":"turn.failed","error":{"code":"rate_limit_exceeded","message":"request rejected"}}' \
  'gemini|{"error":{"code":"service_unavailable","message":"provider unavailable"}}'; do
  provider="${spec%%|*}"
  envelope="${spec#*|}"
  result="$(write_result "$provider" "$envelope")"
  [[ "$(json_field "$result" failureClass)" == "provider-exit" ]] \
    || fail "$provider code-only terminal envelope was classified as quota"
  gluerun_runner_quota_evidence_json "$result" >/dev/null 2>&1 \
    && fail "$provider code-only terminal envelope became quota evidence"
done
pass "terminal error codes without exact HTTP status cannot arm quota backoff"

# Successful terminal payloads, assistant prose and command output are not
# status. Even nested status-like data in a command event must be ignored.
prose='This repository documents quota exceeded, rate-limit, and overloaded behavior.'
for provider in codex claude gemini opencode cursor grok; do
  case "$provider" in
    codex) envelope='{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"HTTP 429 quota exceeded"}}' ;;
    claude) envelope="$(python3 -c 'import json,sys; print(json.dumps({"type":"result","subtype":"success","is_error":False,"api_error_status":None,"result":sys.argv[1]}))' "$prose")" ;;
    gemini) envelope="$(python3 -c 'import json,sys; print(json.dumps({"response":sys.argv[1]}))' "$prose")" ;;
    opencode) envelope="$(python3 -c 'import json,sys; print(json.dumps({"type":"message.part.updated","part":{"type":"text","text":sys.argv[1]}}))' "$prose")" ;;
    cursor) envelope="$(python3 -c 'import json,sys; print(json.dumps({"type":"result","is_error":False,"result":sys.argv[1]}))' "$prose")" ;;
    grok) envelope="$(python3 -c 'import json,sys; print(json.dumps({"type":"result","text":sys.argv[1]}))' "$prose")" ;;
  esac
  result="$(write_result "$provider" "$envelope" 0)"
  [[ "$(json_field "$result" failureClass)" == "none" ]] \
    || fail "$provider classified assistant/command prose"
  gluerun_runner_quota_evidence_json "$result" >/dev/null 2>&1 \
    && fail "$provider assistant/command prose became quota evidence"
done
pass "assistant, repository, legal, test and command prose are excluded"

# 403 requires the narrow entitlement signature; a generic permission error is
# a normal provider failure.
result="$(write_result claude \
  '{"type":"result","subtype":"error","is_error":true,"api_error_status":403,"result":"Organization has disabled subscription access for Claude Code."}')"
gluerun_runner_quota_evidence_json "$result" >/dev/null \
  || fail "recognized 403 entitlement should be structured evidence"
result="$(write_result cursor \
  '{"type":"result","is_error":true,"status":403,"code":"permission_denied","result":"operation forbidden"}')"
gluerun_runner_quota_evidence_json "$result" >/dev/null 2>&1 \
  && fail "generic 403 must not be treated as quota"
[[ "$(json_field "$result" failureClass)" == "provider-exit" ]] \
  || fail "generic 403 should remain provider-exit"
pass "403 entitlement recognition is narrow"

# Provider-reported usage is persisted verbatim when exposed; no counters are
# estimated when the envelope omits them.
usage_result="$(write_result claude \
  '{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"ok","usage":{"input_tokens":17,"cache_read_input_tokens":11,"output_tokens":5}}' 0)"
[[ "$(json_field "$usage_result" usage.inputTokens)" == "17" ]] \
  || fail "input token usage not persisted"
[[ "$(json_field "$usage_result" usage.cachedInputTokens)" == "11" ]] \
  || fail "cached input token usage not persisted"
[[ "$(json_field "$usage_result" usage.outputTokens)" == "5" ]] \
  || fail "output token usage not persisted"
no_usage="$(write_result grok '{"type":"result","text":"ok"}' 0)"
python3 - "$no_usage" <<'PY' || fail "missing usage was fabricated"
import json, sys
assert "usage" not in json.load(open(sys.argv[1], encoding="utf-8"))
PY
pass "provider usage persists only when reported"

# A legacy/custom runner transcript cannot create quota evidence or arm a quota
# backoff, even when it contains the old marker strings.
legacy="$tmp/custom-runner.log"
printf 'api_error_status":429 rate limit exceeded quota overloaded\n' >"$legacy"
[[ "$(gluerun_planner_failure_class "$legacy" 1 "$tmp/missing-output" "$tmp/no-result.json")" == "codex-exit" ]] \
  || fail "legacy runner prose changed failure class"
if gluerun_planner_backoff_set quota RUN-legacy planner "$legacy" 2>/dev/null; then
  fail "legacy runner log armed quota backoff"
fi
[[ ! -f "$GLUERUN_PLANNER_BACKOFF_FILE" ]] || fail "rejected legacy evidence wrote backoff"
grep -q '"type":"backoff.rejected_invalid_evidence"' "$GLUERUN_EVENTS_FILE" \
  || fail "rejected legacy evidence event missing"
pass "legacy/custom runner fails safely without quota sleep-through"

# A validated result arms backoff and binds the normalized provider error; the
# cycle detector sees result sidecars only and ignores nearby raw logs.
valid="$(write_result codex \
  '{"type":"turn.failed","error":{"status":429,"code":"rate_limit_exceeded","message":"request rejected"}}')"
gluerun_planner_backoff_set quota RUN-codex planner "$valid" \
  || fail "valid structured evidence did not arm backoff"
[[ "$(json_field "$GLUERUN_PLANNER_BACKOFF_FILE" evidenceRef)" == "$valid" ]] \
  || fail "backoff not bound to runner result"
[[ "$(json_field "$GLUERUN_PLANNER_BACKOFF_FILE" httpStatus)" == "429" ]] \
  || fail "backoff missing normalized status"
rm -f "$GLUERUN_PLANNER_BACKOFF_FILE"
mkdir -p "$GLUERUN_RUNS_DIR/RUN-noise"
printf 'quota exceeded rate limit overloaded api_error_status":429\n' \
  >"$GLUERUN_RUNS_DIR/RUN-noise/worker-codex.log"
cycle="$(gluerun_cycle_limit_window_evidence_json)" \
  || fail "cycle did not find validated runner result"
[[ "$cycle" == *"\"resultRef\""* ]] || fail "cycle evidence is not a runner result"
pass "backoff and cycle detection consume structured evidence only"

# Schema mirrors are byte-identical and the validator rejects a tampered result.
cmp -s "$ENGINE_HOME/schemas/provider-error.v0.schema.json" \
  "$ENGINE_HOME/schemas/orchestration/provider-error.v0.schema.json" \
  || fail "provider-error schema mirror drift"
cmp -s "$ENGINE_HOME/schemas/runner-result.v0.schema.json" \
  "$ENGINE_HOME/schemas/orchestration/runner-result.v0.schema.json" \
  || fail "runner-result schema mirror drift"
python3 - "$valid" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["untrusted"] = True
json.dump(doc, open(path, "w", encoding="utf-8"))
PY
gluerun_runner_quota_evidence_json "$valid" >/dev/null 2>&1 \
  && fail "tampered runner result passed validation"
pass "schema mirrors match and strict validation rejects tampering"

echo "ALL PROVIDER FAILURE CONTRACT TESTS PASSED"
