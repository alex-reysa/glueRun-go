#!/usr/bin/env bash
# Covers artifact-secret-scan detection/reporting only: explicit --artifacts mode
# scans durable context artifacts with the commit-grade high-confidence patterns,
# reports file path + pattern label for each hit, stays clean for missing/clean
# artifacts, and never mutates the run-state tree.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ENGINE_HOME/engine/secret-scan.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg: missing [$needle] in [$haystack]"
}
assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$msg: unexpected [$needle] in [$haystack]"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
run_dir="$tmp/run-state/RUN-ARTIFACTS"
mkdir -p "$run_dir/l1-staging/planner-session-meta" "$run_dir/sessions/planner"

# Clean artifacts and intentionally missing classes must not produce hits.
printf '{"schema":"x","nextAction":"clean"}\n' >"$run_dir/implementer-capsule.json"
printf '{"schema":"x","verdict":"accepted"}\n' >"$run_dir/reviewer-capsule.json"
printf '{"schema":"x","role":"implementer","sessionId":"sid-clean"}\n' >"$run_dir/session-implementer.json"
printf '{"schema":"x","role":"reviewer","sessionId":"sid-clean"}\n' >"$run_dir/session-reviewer.json"
printf '{"schema":"x","role":"planner","sessionId":"sid-clean"}\n' >"$run_dir/sessions/planner/planner-session-meta.json"
printf '{"taskId":"TASK-CLEAN","notes":"no credential here"}\n' >"$run_dir/packet.json"
printf '{"schema":"x","verdict":"accepted"}\n' >"$run_dir/l1-staging/planner-session-meta/plan-critique.json"
printf '{"schema":"x","transcript":"no credential here"}\n' >"$run_dir/l1-staging/planner-session-meta/plan-critique-raw.json"
printf '{"schema":"x","agreement":true}\n' >"$run_dir/paired-audit.json"

clean_out="$("$SCAN" --artifacts "$run_dir" 2>&1)" || fail "clean artifacts should exit 0: $clean_out"
assert_contains "$clean_out" "secret-scan: clean" "clean artifact scan"
assert_not_contains "$clean_out" "potential secret" "clean artifact scan"

before_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"

# Seed one hit in each representative durable artifact class. Patterns mirror
# the commit-grade scanner labels and must be reported with the artifact path.
sbp_token="sbp_""123456789012345678901234"
aws_key="AK""IA1234567890ABCDEF"
jwt_token="ey""JAAAAAAAAA.eyJBBBBBBBBB.cccccccccc"
github_token="gh""p_123456789012345678901234567890123456"
openai_key="s""k-123456789012345678901234"
private_key_header="-----BEGIN PRIVATE ""KEY-----"

printf '{"nextAction":"rotate leaked token %s"}\n' "$sbp_token" \
  >"$run_dir/implementer-capsule.json"
printf '{"session":"%s"}\n' "$aws_key" \
  >"$run_dir/session-reviewer.json"
printf '{"jwt":"%s"}\n' "$jwt_token" \
  >"$run_dir/sessions/planner/planner-session-meta.json"
printf '{"body":"%s"}\n' "$github_token" \
  >"$run_dir/packet.json"
printf '{"finding":"OpenAI key %s"}\n' "$openai_key" \
  >"$run_dir/l1-staging/planner-session-meta/plan-critique.json"
printf '{"raw":"verbatim critic output leaked %s"}\n' "$sbp_token" \
  >"$run_dir/l1-staging/planner-session-meta/plan-critique-raw.json"
printf '{"raw":"%s"}\n' "$private_key_header" \
  >"$run_dir/paired-audit-raw.json"

after_seed_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
[[ "$before_hash" != "$after_seed_hash" ]] || fail "fixture seeding did not change hash"

set +e
hit_out="$("$SCAN" --artifacts "$run_dir" 2>&1)"
hit_rc=$?
set -e
[[ "$hit_rc" -eq 2 ]] || fail "seeded artifact scan exit=$hit_rc output=$hit_out"

assert_contains "$hit_out" "$run_dir/implementer-capsule.json" "implementer capsule path"
assert_contains "$hit_out" "Supabase token (sbp_)" "Supabase label"
assert_contains "$hit_out" "$run_dir/session-reviewer.json" "reviewer session path"
assert_contains "$hit_out" "AWS access key id" "AWS label"
assert_contains "$hit_out" "$run_dir/sessions/planner/planner-session-meta.json" "planner session path"
assert_contains "$hit_out" "JWT / bearer token" "JWT label"
assert_contains "$hit_out" "$run_dir/packet.json" "packet path"
assert_contains "$hit_out" "GitHub token" "GitHub label"
assert_contains "$hit_out" "$run_dir/l1-staging/planner-session-meta/plan-critique.json" "critique path"
assert_contains "$hit_out" "OpenAI key" "OpenAI label"
assert_contains "$hit_out" "$run_dir/l1-staging/planner-session-meta/plan-critique-raw.json" "raw critique path"
assert_contains "$hit_out" "Supabase token (sbp_)" "raw critique Supabase label"
assert_contains "$hit_out" "$run_dir/paired-audit-raw.json" "paired audit raw path"
assert_contains "$hit_out" "private key block" "private key label"

after_scan_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
[[ "$after_seed_hash" == "$after_scan_hash" ]] || fail "artifact scan mutated file contents"
[[ -z "$(find "$run_dir" -name '*.quarantined' -print -quit)" ]] || fail "artifact scan quarantined a file"

echo "ctx-artifact-scan tests passed"
