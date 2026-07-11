#!/usr/bin/env bash
# Covers Slice A of artifact-secret-scan containment: quarantine-on-hit.
# `engine/ctx-artifact-quarantine.sh` ships a PURE, present-but-uncalled helper
#   gluerun_ctx_artifact_quarantine <run_dir>
# that enumerates the durable context artifacts via the integrated enumerator
# (gluerun_ctx_artifact_scan_paths) and the shared secret patterns
# (gluerun_secret_scan_patterns), and for every artifact matching a secret
# pattern it (1) renames the artifact to `<path>.quarantined` preserving its
# byte content, (2) appends exactly one `ctx.artifact_secret` event recording the
# artifact path and matched pattern label, and (3) returns success (exit 0).
#
#   - Containment: a seeded fake secret gets renamed to `<path>.quarantined`;
#     the ORIGINAL path no longer exists; the `.quarantined` file holds the
#     original bytes verbatim (evidence-preserving, never deleted).
#   - Event: exactly one `ctx.artifact_secret` event per quarantined artifact,
#     carrying the artifact path and the matched pattern label.
#   - Clean artifacts are left byte-for-byte untouched: not renamed, no event.
#   - Non-blocking: quarantine exits 0 even when it quarantines a hit (it never
#     blocks the task outcome the way detection-mode scan does).
#   - Additive / default-OFF: the helper is defined by sourcing lib.sh but is
#     invoked by no default engine flow.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
SCAN="$ENGINE_HOME/engine/secret-scan.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected [$2] in [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

state_dir="$tmp/state"
events_file="$state_dir/events.ndjson"
run_dir="$tmp/run-state/RUN-QUARANTINE"
mkdir -p "$run_dir/sessions/planner"

# --- Fixtures ---------------------------------------------------------------
# Clean artifacts (must survive untouched). Split-literals so the test file
# itself carries no live-looking secret.
sbp_token="sbp_""123456789012345678901234"
aws_key="AK""IA1234567890ABCDEF"

printf '{"schema":"x","verdict":"accepted"}\n' >"$run_dir/reviewer-capsule.json"
printf '{"taskId":"TASK-CLEAN","notes":"no credential here"}\n' >"$run_dir/packet.json"

# Secret-bearing artifacts (must be quarantined).
printf '{"nextAction":"rotate leaked token %s"}\n' "$sbp_token" \
  >"$run_dir/implementer-capsule.json"
printf '{"session":"%s"}\n' "$aws_key" \
  >"$run_dir/session-reviewer.json"

# Capture the exact bytes of the dirty artifacts BEFORE quarantine so we can
# prove the `.quarantined` copy preserves them verbatim.
impl_bytes="$(cat "$run_dir/implementer-capsule.json")"
sess_bytes="$(cat "$run_dir/session-reviewer.json")"

# Capture the clean artifacts' content hashes so we can prove they are untouched.
clean_reviewer_hash="$(shasum "$run_dir/reviewer-capsule.json" | awk '{print $1}')"
clean_packet_hash="$(shasum "$run_dir/packet.json" | awk '{print $1}')"

# --- Invoke the helper in an isolated subshell ------------------------------
# lib.sh auto-sources ctx-artifact-scan.sh (the enumerator) and the new
# ctx-artifact-quarantine.sh. The shared secret patterns live in secret-scan.sh;
# reuse that single source of truth by loading only its patterns function.
quarantine() {
  GLUERUN_ROOT="$tmp" GLUERUN_STATE_DIR="$state_dir" bash -c '
    source "'"$LIB"'"
    eval "$(sed -n "/^gluerun_secret_scan_patterns()/,/^}/p" "'"$SCAN"'")"
    gluerun_ctx_artifact_quarantine "$1"
  ' _ "$1"
}

set +e
q_out="$(quarantine "$run_dir" 2>&1)"
q_rc=$?
set -e

# --- Non-blocking: exit 0 even though it quarantined hits --------------------
[[ "$q_rc" -eq 0 ]] || fail "quarantine must exit 0 (non-blocking); rc=$q_rc out=$q_out"

# --- Containment + evidence preservation for each seeded secret -------------
[[ ! -e "$run_dir/implementer-capsule.json" ]] \
  || fail "dirty implementer capsule original should be renamed away"
[[ -f "$run_dir/implementer-capsule.json.quarantined" ]] \
  || fail "dirty implementer capsule should be quarantined"
[[ "$(cat "$run_dir/implementer-capsule.json.quarantined")" == "$impl_bytes" ]] \
  || fail "quarantined implementer capsule must preserve original bytes"

[[ ! -e "$run_dir/session-reviewer.json" ]] \
  || fail "dirty reviewer session original should be renamed away"
[[ -f "$run_dir/session-reviewer.json.quarantined" ]] \
  || fail "dirty reviewer session should be quarantined"
[[ "$(cat "$run_dir/session-reviewer.json.quarantined")" == "$sess_bytes" ]] \
  || fail "quarantined reviewer session must preserve original bytes"

# --- Clean artifacts untouched: not renamed, content identical --------------
[[ -f "$run_dir/reviewer-capsule.json" ]] \
  || fail "clean reviewer capsule must remain in place"
[[ ! -e "$run_dir/reviewer-capsule.json.quarantined" ]] \
  || fail "clean reviewer capsule must NOT be quarantined"
[[ "$(shasum "$run_dir/reviewer-capsule.json" | awk '{print $1}')" == "$clean_reviewer_hash" ]] \
  || fail "clean reviewer capsule content changed"

[[ -f "$run_dir/packet.json" ]] || fail "clean packet must remain in place"
[[ ! -e "$run_dir/packet.json.quarantined" ]] \
  || fail "clean packet must NOT be quarantined"
[[ "$(shasum "$run_dir/packet.json" | awk '{print $1}')" == "$clean_packet_hash" ]] \
  || fail "clean packet content changed"

# --- Exactly one ctx.artifact_secret event per quarantined artifact ---------
[[ -f "$events_file" ]] || fail "events file was not written"
secret_events="$(grep -c '"type":"ctx.artifact_secret"' "$events_file" 2>/dev/null || true)"
[[ "$secret_events" -eq 2 ]] \
  || fail "expected exactly 2 ctx.artifact_secret events, got $secret_events"

events_all="$(cat "$events_file")"
assert_contains "$events_all" "ctx.artifact_secret" "event type present"
assert_contains "$events_all" "$run_dir/implementer-capsule.json" "event records implementer path"
assert_contains "$events_all" "Supabase token (sbp_)" "event records Supabase label"
assert_contains "$events_all" "$run_dir/session-reviewer.json" "event records reviewer path"
assert_contains "$events_all" "AWS access key id" "event records AWS label"

# --- Idempotence guard: a second pass finds nothing new to quarantine -------
# (all remaining in-scope artifacts are clean; already-quarantined files are
# never re-enumerated as originals and never double-processed.)
before_second="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
set +e
q2_out="$(quarantine "$run_dir" 2>&1)"
q2_rc=$?
set -e
[[ "$q2_rc" -eq 0 ]] || fail "second quarantine pass must exit 0; rc=$q2_rc out=$q2_out"
after_second="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
[[ "$before_second" == "$after_second" ]] \
  || fail "second quarantine pass must not mutate the tree"

echo "ctx-artifact-quarantine tests passed"
