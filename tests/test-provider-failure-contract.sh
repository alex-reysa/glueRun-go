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
# 429 is a usage-limit window (quota); 503/529 is transient capacity
# (provider-overloaded). They are separate classes with separate backoffs, and
# neither may satisfy an evidence query for the other.
declare -A envelope_class=(
  [codex]=quota [claude]=provider-overloaded [gemini]=provider-overloaded
  [opencode]=quota [cursor]=quota [grok]=quota
)
for provider in codex claude gemini opencode cursor grok; do
  expected="${envelope_class[$provider]}"
  other="quota"; [[ "$expected" == "quota" ]] && other="provider-overloaded"
  result="$(write_result "$provider" "${envelopes[$provider]}")"
  evidence="$(gluerun_runner_quota_evidence_json "$result" "$expected")" \
    || fail "$provider structured terminal status was not accepted as $expected"
  [[ "$(json_field "$result" failureClass)" == "$expected" ]] \
    || fail "$provider runner result not $expected"
  [[ "$evidence" == *"\"provider\":\"$provider\""* ]] \
    || fail "$provider missing from evidence"
  gluerun_runner_quota_evidence_json "$result" "$other" >/dev/null 2>&1 \
    && fail "$provider $expected evidence cross-validated as $other"
  gluerun_runner_quota_evidence_json "$result" any >/dev/null 2>&1 \
    || fail "$provider $expected evidence rejected by the any-window query"
done
pass "cross-provider terminal envelopes normalize to bound, class-separated evidence"

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
backoff_snapshot="$tmp/codex-planner-backoff.json"
cp "$GLUERUN_PLANNER_BACKOFF_FILE" "$backoff_snapshot"
GLUERUN_RUNNER="$ENGINE_HOME/engine/codex-run.sh" \
  gluerun_planner_backoff_active_json >/dev/null \
  || fail "matching built-in provider did not retain active backoff"
if GLUERUN_RUNNER="$ENGINE_HOME/engine/claude-run.sh" \
  gluerun_planner_backoff_active_json >/dev/null 2>&1; then
  fail "switching built-in provider did not bypass old provider backoff"
fi
cmp -s "$GLUERUN_PLANNER_BACKOFF_FILE" "$backoff_snapshot" \
  || fail "provider mismatch changed or corrupted backoff evidence"
GLUERUN_RUNNER="$ENGINE_HOME/engine/codex-run.sh" \
  gluerun_planner_backoff_active_json >/dev/null \
  || fail "preserved backoff did not reactivate when provider reverted"

# Pre-provider planner-backoff.v0 records remain global until expiry. This is
# the explicit compatibility behavior for legacy evidence whose provider cannot
# be attributed safely.
python3 - "$GLUERUN_PLANNER_BACKOFF_FILE" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data.pop("provider", None)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
GLUERUN_RUNNER="$ENGINE_HOME/engine/claude-run.sh" \
  gluerun_planner_backoff_active_json >/dev/null \
  || fail "provider-less legacy backoff did not retain global compatibility behavior"
rm -f "$GLUERUN_PLANNER_BACKOFF_FILE"
mkdir -p "$GLUERUN_RUNS_DIR/RUN-noise"
printf 'quota exceeded rate limit overloaded api_error_status":429\n' \
  >"$GLUERUN_RUNS_DIR/RUN-noise/worker-codex.log"
cycle="$(gluerun_cycle_limit_window_evidence_json)" \
  || fail "cycle did not find validated runner result"
[[ "$cycle" == *"\"resultRef\""* ]] || fail "cycle evidence is not a runner result"
pass "backoff is provider-scoped, preserves evidence, and keeps legacy records global"
pass "backoff and cycle detection consume structured evidence only"

# An overload window is a different class with a different window length. The
# whole point of the split: a 529 must not buy the 30-minute quota backoff, and
# must not be arm-able as quota at all.
rm -f "$GLUERUN_PLANNER_BACKOFF_FILE"
overloaded="$(write_result claude \
  '{"type":"result","subtype":"error","is_error":true,"api_error_status":529,"result":"provider unavailable"}')"
if gluerun_planner_backoff_set quota RUN-overload planner "$overloaded" 2>/dev/null; then
  fail "overload evidence armed a quota backoff"
fi
[[ ! -f "$GLUERUN_PLANNER_BACKOFF_FILE" ]] || fail "refused overload-as-quota still wrote a backoff"
gluerun_planner_backoff_set provider-overloaded RUN-overload planner "$overloaded" \
  || fail "overload evidence did not arm a provider-overloaded backoff"
[[ "$(json_field "$GLUERUN_PLANNER_BACKOFF_FILE" failureClass)" == "provider-overloaded" ]] \
  || fail "overload backoff recorded the wrong class"
[[ "$(json_field "$GLUERUN_PLANNER_BACKOFF_FILE" httpStatus)" == "529" ]] \
  || fail "overload backoff missing normalized status"
collision_dir="$tmp/custom-runner"
collision_runner="$collision_dir/codex-run.sh"
mkdir -p "$collision_dir"
printf '#!/usr/bin/env bash\nexit 0\n' >"$collision_runner"
chmod +x "$collision_runner"
collision_snapshot="$tmp/claude-planner-backoff.json"
cp "$GLUERUN_PLANNER_BACKOFF_FILE" "$collision_snapshot"
GLUERUN_RUNNER="$collision_runner" \
  gluerun_planner_backoff_active_json >/dev/null \
  || fail "basename-colliding custom runner bypassed existing provider backoff"
cmp -s "$GLUERUN_PLANNER_BACKOFF_FILE" "$collision_snapshot" \
  || fail "custom-runner lookup changed or corrupted backoff evidence"
pass "basename-colliding custom runner remains provider-unknown"
backoff_window="$(python3 - "$GLUERUN_PLANNER_BACKOFF_FILE" <<'PY'
import json, sys
from datetime import datetime
d = json.load(open(sys.argv[1], encoding="utf-8"))
started = datetime.fromisoformat(d["startedAt"].replace("Z", "+00:00"))
until = datetime.fromisoformat(d["until"].replace("Z", "+00:00"))
print(int((until - started).total_seconds()))
PY
)"
[[ "$backoff_window" == "180" ]] \
  || fail "overload backoff window is ${backoff_window}s, expected the short 180s window"
rm -f "$GLUERUN_PLANNER_BACKOFF_FILE"
pass "provider overload arms its own short backoff and cannot arm quota"

# failureClass is written by the host classifier; `kind` comes from the
# separately hash-bound provider-error sidecar. A result that CLAIMS quota while
# its bound envelope says overloaded is the cheap way to buy a 30-minute
# sleep-through from a 529, so the two must be cross-checked rather than the
# self-declared class trusted.
forged="$tmp/forged-quota-runner-result.json"
cp "$overloaded" "$forged"
python3 - "$forged" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
assert data["failureClass"] == "provider-overloaded", data["failureClass"]
data["failureClass"] = "quota"
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
gluerun_runner_quota_evidence_json "$forged" quota >/dev/null 2>&1 \
  && fail "a result claiming quota over an overload envelope passed the quota query"
gluerun_runner_quota_evidence_json "$forged" any >/dev/null 2>&1 \
  && fail "class/kind disagreement passed the any-window query"
if gluerun_planner_backoff_set quota RUN-forged planner "$forged" 2>/dev/null; then
  fail "forged quota class armed the long quota backoff from a 529"
fi
[[ ! -f "$GLUERUN_PLANNER_BACKOFF_FILE" ]] || fail "forged evidence wrote a backoff"
pass "declared failure class must agree with the bound provider-error kind"

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

# --- provider-pressure concurrency adaptation --------------------------------
#
# The controller's only input is evidence that already survived
# gluerun_runner_quota_evidence_json. These cases pin what may and may not move
# the dispatch ceiling.

# write_result keys its run directory by provider alone, so two fixtures for the
# same provider overwrite each other. Distinct provider EVENTS are the whole
# subject here, so they need distinct run directories and run ids.
write_tagged_result() {
  local provider="$1" tag="$2" envelope_json="$3" exit_code="${4:-4}"
  local dir="$GLUERUN_RUNS_DIR/RUN-$tag"
  mkdir -p "$dir"
  printf '%s\n' "$envelope_json" >"$dir/envelope.json"
  gluerun_runner_result_write "$provider" "RUN-$tag" planner planner-core \
    "$dir/runner-result.json" "$exit_code" "$dir/envelope.json" "" "$dir/out.json"
  printf '%s\n' "$dir/runner-result.json"
}
pressure_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
for key in sys.argv[2].split("."):
    value = value[key]
print("null" if value is None else value)
PY
}
pressure_cap() {
  # Cap for a given provider straight out of the durable state document.
  python3 - "$GLUERUN_PROVIDER_PRESSURE_FILE" "$1" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    print("absent")
    sys.exit(0)
entry = doc.get("providers", {}).get(sys.argv[2])
print("absent" if not entry else ("null" if entry.get("cap") is None else entry["cap"]))
PY
}

export GLUERUN_PROVIDER_PRESSURE_FILE="$GLUERUN_STATE_DIR/provider-pressure.json"
rm -f "$GLUERUN_PLANNER_BACKOFF_FILE" "$GLUERUN_PROVIDER_PRESSURE_FILE"

# Disabled (the default) is inert: the arming path runs, and nothing observes.
quota_a="$(write_tagged_result codex pressure-a \
  '{"type":"turn.failed","error":{"status":429,"code":"rate_limit_exceeded","message":"first"}}')"
gluerun_planner_backoff_set quota RUN-pressure-off planner "$quota_a" >/dev/null \
  || fail "valid evidence did not arm backoff with adaptation disabled"
[[ ! -e "$GLUERUN_PROVIDER_PRESSURE_FILE" ]] \
  || fail "adaptation disabled still created provider-pressure state"
gluerun_provider_pressure_observe "$quota_a" >/dev/null 2>&1 \
  && fail "observe ran while adaptation was disabled"
gluerun_provider_pressure_status_json >/dev/null 2>&1 \
  && fail "status reported while adaptation was disabled"
pass "provider-pressure adaptation is inert when disabled"

export GLUERUN_PROVIDER_PRESSURE_ADAPT=1
export GLUERUN_MAX_CONCURRENT=4
export GLUERUN_PROVIDER_PRESSURE_CLUSTER=2
export GLUERUN_PROVIDER_PRESSURE_RECOVER_QUIET=2
export GLUERUN_RUNNER="$ENGINE_HOME/engine/codex-run.sh"
rm -f "$GLUERUN_PLANNER_BACKOFF_FILE"

# One validated event is a data point, not pressure.
first="$(gluerun_provider_pressure_observe "$quota_a")" \
  || fail "validated congestion evidence was not observed"
[[ "$(pressure_field "$first" action)" == "recorded" ]] \
  || fail "first event action was not 'recorded'"
[[ "$(pressure_field "$first" cap)" == "null" ]] \
  || fail "a single event reduced capacity below the cluster threshold"

# Replay is not a second event: the same provider event re-read on a later cycle
# must never fund half the cluster.
replay="$(gluerun_provider_pressure_observe "$quota_a")" \
  || fail "replayed evidence was rejected outright instead of deduplicated"
[[ "$(pressure_field "$replay" action)" == "duplicate" ]] \
  || fail "replayed evidence was not recognized as a duplicate"
[[ "$(pressure_field "$replay" events)" == "1" ]] \
  || fail "replayed evidence was counted twice"
[[ "$(pressure_field "$replay" cap)" == "null" ]] \
  || fail "replayed evidence reduced capacity"
pass "one validated event does not reduce capacity and replay cannot cluster it"

# Raw prose and tampered/unbound evidence cannot reach the controller at all.
prose_log="$tmp/pressure-prose.log"
printf 'HTTP 429 rate_limit_exceeded overloaded 529 quota exceeded\n' >"$prose_log"
gluerun_provider_pressure_observe "$prose_log" >/dev/null 2>&1 \
  && fail "raw prose became provider-pressure evidence"
tampered="$tmp/pressure-tampered-result.json"
cp "$quota_a" "$tampered"
python3 - "$tampered" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["runId"] = "RUN-tampered"
json.dump(doc, open(path, "w", encoding="utf-8"), indent=2)
PY
gluerun_provider_pressure_observe "$tampered" >/dev/null 2>&1 \
  && fail "runId-tampered result became provider-pressure evidence"
# A 403 entitlement denial is a hard refusal, not congestion; shrinking the pool
# cannot make an unentitled account entitled.
entitlement="$(write_tagged_result claude pressure-entitlement \
  '{"type":"result","subtype":"error","is_error":true,"api_error_status":403,"result":"Organization has disabled subscription access for Claude Code."}')"
gluerun_runner_quota_evidence_json "$entitlement" any >/dev/null \
  || fail "entitlement fixture is not valid evidence"
gluerun_provider_pressure_observe "$entitlement" >/dev/null 2>&1 \
  && fail "403 entitlement was treated as congestion pressure"
[[ "$(pressure_cap claude)" == "absent" ]] \
  || fail "entitlement evidence created claude pressure state"
[[ "$(pressure_cap codex)" == "null" ]] \
  || fail "rejected evidence disturbed the codex cap"
pass "prose, tampered evidence and entitlement denials cannot apply pressure"

# A distinct second event completes the cluster: multiplicative decrease.
quota_b="$(write_tagged_result codex pressure-b \
  '{"type":"turn.failed","error":{"status":429,"code":"rate_limit_exceeded","message":"second"}}' 5)"
second="$(gluerun_provider_pressure_observe "$quota_b")" \
  || fail "second distinct event was not observed"
[[ "$(pressure_field "$second" action)" == "reduced" ]] \
  || fail "clustered distinct evidence did not reduce capacity"
[[ "$(pressure_field "$second" cap)" == "2" ]] \
  || fail "multiplicative decrease from 4 configured slots should cap at 2"
grep -q '"type":"provider_pressure.reduced"' "$GLUERUN_EVENTS_FILE" \
  || fail "capacity reduction emitted no event"
# The digests remain for dedup but are consumed, so a third replay of either one
# cannot fund a second halving.
gluerun_provider_pressure_observe "$quota_a" >/dev/null \
  || fail "post-reduction replay was rejected"
[[ "$(pressure_cap codex)" == "2" ]] \
  || fail "consumed evidence funded a second reduction"
pass "clustered distinct validated evidence reduces capacity exactly once"

# Pressure is provider-scoped: switching runners must not inherit codex's cap,
# and codex's state must survive the switch intact.
switch_status="$(GLUERUN_RUNNER="$ENGINE_HOME/engine/claude-run.sh" \
  gluerun_provider_pressure_status_json)" \
  || fail "status failed after provider switch"
[[ "$(pressure_field "$switch_status" provider)" == "claude" ]] \
  || fail "status did not follow the selected provider"
[[ "$(pressure_field "$switch_status" cap)" == "null" ]] \
  || fail "switched provider inherited another provider's reduced cap"
# A basename-colliding custom wrapper must not impersonate the built-in and
# collect codex's cap either.
collision_status="$(GLUERUN_RUNNER="$collision_runner" \
  gluerun_provider_pressure_status_json)" \
  || fail "status failed for a custom runner"
[[ "$(pressure_field "$collision_status" provider)" == "null" ]] \
  || fail "basename-colliding custom runner was attributed a built-in provider"
[[ "$(pressure_field "$collision_status" cap)" == "null" ]] \
  || fail "basename-colliding custom runner inherited the codex cap"
GLUERUN_RUNNER="$collision_runner" gluerun_provider_pressure_success >/dev/null 2>&1 \
  && fail "custom runner recovered another provider's capacity"
[[ "$(pressure_cap codex)" == "2" ]] \
  || fail "provider switch mutated the codex cap"
pass "provider pressure is scoped to a canonically resolved shipped adapter"

# Additive increase: one slot per quiet-success interval, and only for the
# selected provider. Sub-interval successes change nothing visible.
[[ "$(pressure_field "$(gluerun_provider_pressure_success)" action)" == "quiet" ]] \
  || fail "first quiet success should not restore a slot yet"
[[ "$(pressure_cap codex)" == "2" ]] || fail "sub-interval success restored capacity early"
recovered="$(gluerun_provider_pressure_success)" || fail "quiet-interval success failed"
[[ "$(pressure_field "$recovered" action)" == "recovered" ]] \
  || fail "completed quiet interval did not restore a slot"
[[ "$(pressure_field "$recovered" cap)" == "3" ]] \
  || fail "recovery restored more than one slot at a time"
gluerun_provider_pressure_success >/dev/null || fail "quiet success failed"
cleared="$(gluerun_provider_pressure_success)" || fail "quiet success failed"
[[ "$(pressure_field "$cleared" action)" == "cleared" ]] \
  || fail "recovery to the configured ceiling did not clear the cap"
[[ "$(pressure_cap codex)" == "null" ]] \
  || fail "cleared pressure left a stale cap"
gluerun_provider_pressure_success >/dev/null 2>&1
[[ "$(pressure_cap codex)" == "null" ]] \
  || fail "recovery continued past the configured ceiling"
pass "quiet successful intervals restore one slot at a time and stop at capacity"

# The floor. With a single configured slot, a cluster must still leave one slot
# for runnable work rather than halving to zero.
floor_state="$tmp/pressure-floor.json"
rm -f "$floor_state"
floor_a="$(write_tagged_result grok pressure-floor-a '{"type":"error","error":{"http_status":429,"code":"rate_limit_exceeded","message":"floor-a"}}')"
floor_b="$(write_tagged_result grok pressure-floor-b '{"type":"error","error":{"http_status":429,"code":"rate_limit_exceeded","message":"floor-b"}}' 5)"
GLUERUN_PROVIDER_PRESSURE_FILE="$floor_state" GLUERUN_MAX_CONCURRENT=1 \
  gluerun_provider_pressure_observe "$floor_a" >/dev/null || fail "floor observe a failed"
floor_result="$(GLUERUN_PROVIDER_PRESSURE_FILE="$floor_state" GLUERUN_MAX_CONCURRENT=1 \
  gluerun_provider_pressure_observe "$floor_b")" || fail "floor observe b failed"
[[ "$(pressure_field "$floor_result" cap)" == "1" ]] \
  || fail "pressure reduction produced a cap below one slot"
# ...and repeated clusters cannot grind it below the floor either.
for suffix in c d; do
  extra="$(write_tagged_result grok "pressure-floor-$suffix" "{\"type\":\"error\",\"error\":{\"http_status\":429,\"code\":\"rate_limit_exceeded\",\"message\":\"floor-$suffix\"}}" 5)"
  GLUERUN_PROVIDER_PRESSURE_FILE="$floor_state" GLUERUN_MAX_CONCURRENT=1 \
    gluerun_provider_pressure_observe "$extra" >/dev/null || fail "floor observe $suffix failed"
done
[[ "$(GLUERUN_PROVIDER_PRESSURE_FILE="$floor_state" pressure_cap grok)" == "1" ]] \
  || fail "sustained pressure drove the cap below one slot"
# Sitting at the floor is not a fresh cut. Announcing one per cluster would tell
# the operator capacity kept falling while the ceiling never moved.
floor_reduced="$(grep -c '"type":"provider_pressure.reduced"' "$GLUERUN_EVENTS_FILE" || true)"
floor_e="$(write_tagged_result grok pressure-floor-e '{"type":"error","error":{"http_status":429,"code":"rate_limit_exceeded","message":"floor-e"}}' 5)"
floor_f="$(write_tagged_result grok pressure-floor-f '{"type":"error","error":{"http_status":429,"code":"rate_limit_exceeded","message":"floor-f"}}' 5)"
GLUERUN_PROVIDER_PRESSURE_FILE="$floor_state" GLUERUN_MAX_CONCURRENT=1 \
  gluerun_provider_pressure_observe "$floor_e" >/dev/null || fail "floor observe e failed"
# floor_f completes a fresh cluster against a cap that is already at the floor.
held="$(GLUERUN_PROVIDER_PRESSURE_FILE="$floor_state" GLUERUN_MAX_CONCURRENT=1 \
  gluerun_provider_pressure_observe "$floor_f")" || fail "floor observe f failed"
[[ "$(pressure_field "$held" action)" == "held" ]] \
  || fail "a cluster that cannot lower the cap reported '$(pressure_field "$held" action)'"
[[ "$(grep -c '"type":"provider_pressure.reduced"' "$GLUERUN_EVENTS_FILE" || true)" == "$floor_reduced" ]] \
  || fail "sustained pressure at the floor kept emitting reduction events"
pass "provider-pressure cap never falls below one slot"

# Corrupt state fails OPEN to the ordinary plan; it never crashes and never
# reduces to zero.
corrupt_state="$tmp/pressure-corrupt.json"
printf '{"schema":"gluerun.orchestration.provider-pressure.v0","providers":' >"$corrupt_state"
corrupt_status="$(GLUERUN_PROVIDER_PRESSURE_FILE="$corrupt_state" \
  gluerun_provider_pressure_status_json)" || fail "corrupt pressure state broke status"
[[ "$(pressure_field "$corrupt_status" cap)" == "null" ]] \
  || fail "corrupt pressure state produced a cap"
printf '%s' '{"schema":"gluerun.orchestration.provider-pressure.v0","providers":{"codex":{"cap":0,"events":"nope","quietSuccesses":-4}}}' >"$corrupt_state"
hostile_status="$(GLUERUN_PROVIDER_PRESSURE_FILE="$corrupt_state" \
  gluerun_provider_pressure_status_json)" || fail "out-of-range pressure state broke status"
[[ "$(pressure_field "$hostile_status" cap)" == "null" ]] \
  || fail "a zero cap in state was honored instead of discarded"
pass "malformed provider-pressure state fails open"

# Dedup identity is the EVENT, not its path on disk. The validator accepts
# relative refs, so the same provider event can legitimately appear at two
# paths; hashing the path in would let one event fund a whole cluster.
rm -f "$GLUERUN_PROVIDER_PRESSURE_FILE"
relative_src="$GLUERUN_RUNS_DIR/RUN-pressure-rel"
mkdir -p "$relative_src"
rel_result="$(write_tagged_result opencode pressure-rel \
  '{"type":"error","error":{"name":"RateLimitError","data":{"statusCode":429,"code":"rate_limit_exceeded","message":"rel"}}}')"
python3 - "$rel_result" <<'PY'
import json, os, pathlib, sys
# Rewrite the engine's absolute refs to the relative form the validator also
# accepts, so the copy below is a byte-faithful second home for one event.
result_path = pathlib.Path(sys.argv[1])
result = json.loads(result_path.read_text(encoding="utf-8"))
error_path = pathlib.Path(result["providerErrorRef"])
error = json.loads(error_path.read_text(encoding="utf-8"))
if error.get("rawEventRef"):
    error["rawEventRef"] = os.path.basename(error["rawEventRef"])
error_path.write_text(json.dumps(error), encoding="utf-8")
result["providerErrorRef"] = error_path.name
if result.get("providerEnvelopeRef"):
    result["providerEnvelopeRef"] = os.path.basename(result["providerEnvelopeRef"])
result_path.write_text(json.dumps(result), encoding="utf-8")
PY
gluerun_runner_quota_evidence_json "$rel_result" any >/dev/null \
  || fail "relative-ref evidence fixture is not valid evidence"
cp -R "$relative_src" "$GLUERUN_RUNS_DIR/RUN-pressure-rel-copy"
gluerun_provider_pressure_observe "$rel_result" >/dev/null \
  || fail "relative-ref evidence was not observed"
gluerun_provider_pressure_observe \
  "$GLUERUN_RUNS_DIR/RUN-pressure-rel-copy/runner-result.json" >/dev/null \
  || fail "the copied event was rejected outright"
[[ "$(pressure_cap opencode)" == "null" ]] \
  || fail "one provider event at two paths was counted as a cluster"
pass "dedup identity is the provider event, not its path on disk"

# A floor above the configured ceiling must not persist a cap that the plan can
# never honour; the controller would otherwise reduce and re-reduce forever.
rm -f "$GLUERUN_PROVIDER_PRESSURE_FILE"
floor_high_a="$(write_tagged_result gemini pressure-highfloor-a \
  '{"error":{"status":503,"code":"service_unavailable","message":"a"}}')"
floor_high_b="$(write_tagged_result gemini pressure-highfloor-b \
  '{"error":{"status":503,"code":"service_unavailable","message":"b"}}' 5)"
for ev in "$floor_high_a" "$floor_high_b"; do
  GLUERUN_MAX_CONCURRENT=2 GLUERUN_PROVIDER_PRESSURE_MIN_SLOTS=6 \
    gluerun_provider_pressure_observe "$ev" >/dev/null \
    || fail "high-floor observe failed"
done
high_floor_cap="$(GLUERUN_MAX_CONCURRENT=2 pressure_cap gemini)"
[[ "$high_floor_cap" == "2" ]] \
  || fail "a floor above the configured ceiling persisted an unusable cap ($high_floor_cap)"
GLUERUN_MAX_CONCURRENT=2 GLUERUN_PROVIDER_PRESSURE_MIN_SLOTS=6 \
  gluerun_provider_pressure_observe "$floor_high_a" >/dev/null \
  || fail "high-floor replay failed"
[[ "$(GLUERUN_MAX_CONCURRENT=2 pressure_cap gemini)" == "2" ]] \
  || fail "the high-floor cap oscillated instead of holding"
pass "a min-slots floor above configured capacity is clamped, not oscillated"

# A write that never landed is not a reduction. Reporting one would tell the
# operator capacity was cut while the on-disk ceiling never moved.
readonly_dir="$tmp/pressure-readonly"
mkdir -p "$readonly_dir"
readonly_state="$readonly_dir/provider-pressure.json"
ro_a="$(write_tagged_result grok pressure-ro-a \
  '{"type":"error","error":{"http_status":429,"code":"rate_limit_exceeded","message":"ro-a"}}')"
ro_b="$(write_tagged_result grok pressure-ro-b \
  '{"type":"error","error":{"http_status":429,"code":"rate_limit_exceeded","message":"ro-b"}}' 5)"
GLUERUN_PROVIDER_PRESSURE_FILE="$readonly_state" GLUERUN_MAX_CONCURRENT=4 \
  gluerun_provider_pressure_observe "$ro_a" >/dev/null || fail "readonly observe a failed"
reduced_before="$(grep -c '"type":"provider_pressure.reduced"' "$GLUERUN_EVENTS_FILE" || true)"
chmod 500 "$readonly_dir"
ro_report="$(GLUERUN_PROVIDER_PRESSURE_FILE="$readonly_state" GLUERUN_MAX_CONCURRENT=4 \
  gluerun_provider_pressure_observe "$ro_b")" || true
chmod 700 "$readonly_dir"
if [[ -n "$ro_report" ]]; then
  [[ "$(pressure_field "$ro_report" action)" == "write-failed" ]] \
    || fail "an unwritable state file still reported action '$(pressure_field "$ro_report" action)'"
  [[ "$(pressure_field "$ro_report" cap)" == "null" ]] \
    || fail "a failed write reported a cap that was never persisted"
fi
[[ "$(GLUERUN_PROVIDER_PRESSURE_FILE="$readonly_state" pressure_cap grok)" == "null" ]] \
  || fail "a failed write left a phantom cap on disk"
reduced_after="$(grep -c '"type":"provider_pressure.reduced"' "$GLUERUN_EVENTS_FILE" || true)"
[[ "$reduced_after" == "$reduced_before" ]] \
  || fail "a failed write emitted a reduction event ($reduced_before -> $reduced_after)"
# Silence would be its own defect: an unwritable state dir leaves the controller
# inert, and the operator needs to be told rather than left guessing.
grep -q '"type":"provider_pressure.write_failed"' "$GLUERUN_EVENTS_FILE" \
  || fail "a failed state write produced no operator-visible diagnostic"
pass "a failed state write reports no reduction and emits no event"

# The arming path is the real choke point: pressure is observed there, not by a
# caller that happens to remember to call it.
rm -f "$GLUERUN_PROVIDER_PRESSURE_FILE" "$GLUERUN_PLANNER_BACKOFF_FILE"
chokepoint_a="$(write_tagged_result cursor pressure-choke-a '{"type":"result","is_error":true,"status":429,"code":"rate_limit_exceeded","result":"choke-a"}')"
chokepoint_b="$(write_tagged_result cursor pressure-choke-b '{"type":"result","is_error":true,"status":429,"code":"rate_limit_exceeded","result":"choke-b"}' 5)"
GLUERUN_MAX_CONCURRENT=4 gluerun_planner_backoff_set quota RUN-choke-a planner "$chokepoint_a" \
  || fail "chokepoint arming a failed"
GLUERUN_MAX_CONCURRENT=4 gluerun_planner_backoff_set quota RUN-choke-b planner "$chokepoint_b" \
  || fail "chokepoint arming b failed"
[[ "$(pressure_cap cursor)" == "2" ]] \
  || fail "arming a backoff did not observe provider pressure"
# Refused evidence arms nothing and must record nothing.
rm -f "$GLUERUN_PROVIDER_PRESSURE_FILE"
if gluerun_planner_backoff_set quota RUN-choke-legacy planner "$legacy" 2>/dev/null; then
  fail "legacy log armed a backoff under adaptation"
fi
[[ ! -e "$GLUERUN_PROVIDER_PRESSURE_FILE" ]] \
  || fail "refused backoff evidence still recorded provider pressure"
pass "pressure is observed at the validated backoff-arming choke point"

echo "ALL PROVIDER FAILURE CONTRACT TESTS PASSED"
