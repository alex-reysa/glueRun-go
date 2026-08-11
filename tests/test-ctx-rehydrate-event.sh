#!/usr/bin/env bash
# Covers the fifth strict-test-first slice of DAG node `rehydrate-path`
# (stage S5-routing, layer engine_runtime): the pure, read-only strategy-event
# payload builder `engine/ctx-rehydrate-event.sh`.
#
#   singular_ctx_rehydrate_event_data \
#     <role> <task-id> <run-id> <attempt> <reason> <run_dir> [extra-id=path ...]
#
# Prints a single compact JSON object suitable as the third (`data`) argument to
# `singular_append_event "context.strategy_selected"`, extending the existing
# resume/fresh payload shape additively:
#   {"taskId":…,"runId":…,"role":…,"attempt":<n>,"strategy":"rehydrate",
#    "reason":"<reason>","manifest":<manifest-json>}
# where `attempt` is numeric, the rest strings, and `manifest` is a NESTED JSON
# object (not a stringified blob) — the deterministic output of
# singular_ctx_rehydrate_manifest over singular_ctx_rehydrate_sources <run_dir>.
#   - Quarantine-aware transitively (the assembler composes the exclude filter).
#   - Deterministic: identical run_dir bytes -> byte-identical event data.
#   - Robust to an empty source set: manifest.sources = [] and still valid JSON.
#   - Pure / read-only: writes/renames/deletes nothing, appends no events, and
#     never exits non-zero on well-formed input; the packet BODY is never
#     embedded (only the manifest of ids + hashes). Confers no independence:
#     `rehydrate` stays tainted per singular_ctx_route_strategy_tainted.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SINGULAR_ROOT="$tmp"

run_dir="$tmp/run-state/RUN-REHYDRATE-EVENT"
mkdir -p "$run_dir"

# --- Durable artifact fixtures (subset of the resolver's classes) -----------
printf '{"task":"T"}\n'        >"$run_dir/packet.json"
printf '{"impl":"cap"}\n'      >"$run_dir/implementer-capsule.json"
printf '{"findings":[]}\n'     >"$run_dir/findings-status.json"

event_data() {
  bash -c '
    source "'"$LIB"'"
    singular_ctx_rehydrate_event_data "$@"
  ' _ "$@"
}
manifest() {
  bash -c '
    source "'"$LIB"'"
    singular_ctx_rehydrate_manifest "$@"
  ' _ "$@"
}
sources() {
  bash -c '
    source "'"$LIB"'"
    singular_ctx_rehydrate_sources "$@"
  ' _ "$@"
}

before_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"

# --- Case 1: payload shape --------------------------------------------------
out="$(event_data implementer T-1 R-1 2 window-pressure "$run_dir")" \
  || fail "case1: builder exited non-zero"

# parses as a single JSON object (so append_event's json.loads keeps `manifest`
# structured, not a {"raw":…} fallback)
printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  || fail "case1: output is not a single valid JSON object"

check_field() {
  local expr="$1" want="$2" got
  got="$(printf '%s' "$out" | python3 -c 'import json,sys; o=json.load(sys.stdin); print('"$expr"')')" \
    || fail "case1: field probe failed for [$expr]"
  [[ "$got" == "$want" ]] || fail "case1: $expr = [$got], want [$want]"
}
check_field 'o["strategy"]' 'rehydrate'
check_field 'o["reason"]'   'window-pressure'
check_field 'o["role"]'     'implementer'
check_field 'o["taskId"]'   'T-1'
check_field 'o["runId"]'    'R-1'
# attempt is numeric (int), not a string
check_field 'o["attempt"]'                 '2'
check_field 'type(o["attempt"]).__name__'  'int'
# manifest is a nested object, not a stringified blob
check_field 'type(o["manifest"]).__name__' 'dict'
check_field 'o["manifest"]["schema"]' 'singular.orchestration.ctx-rehydrate-manifest.v0'

# --- Case 2: manifest fidelity ---------------------------------------------
# The embedded manifest exactly equals the manifest assembled from the resolver
# output for the same fixture (canonicalized via sort_keys).
specs="$(sources "$run_dir")" || fail "case2: sources exited non-zero"
IFS=$'\n' read -r -d '' -a spec_arr < <(printf '%s\0' "$specs")
ref_manifest="$(manifest "${spec_arr[@]}")" || fail "case2: manifest exited non-zero"
embedded="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["manifest"], sort_keys=True))')"
ref_canon="$(printf '%s' "$ref_manifest" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))')"
[[ "$embedded" == "$ref_canon" ]] || fail "case2: embedded manifest != resolver+assembler manifest.
embedded: $embedded
ref:      $ref_canon"

# the packet BODY is never embedded — only ids + hashes
[[ "$out" != *'=== '* ]] || fail "case2: packet body leaked into event data"

# --- Case 3: determinism ----------------------------------------------------
out2="$(event_data implementer T-1 R-1 2 window-pressure "$run_dir")" \
  || fail "case3: builder(2) exited non-zero"
[[ "$out" == "$out2" ]] || fail "case3: event data not byte-identical across runs"

# --- Case 4: quarantine exclusion ------------------------------------------
# A quarantined artifact under run_dir is absent from the embedded sources.
printf '{"leak":"x"}\n' >"$run_dir/findings-status.json.quarantined"
q="$(event_data implementer T-1 R-1 2 window-pressure "$run_dir")" \
  || fail "case4: builder(quarantine) exited non-zero"
q_ids="$(printf '%s' "$q" | python3 -c 'import json,sys; print(" ".join(s["id"] for s in json.load(sys.stdin)["manifest"]["sources"]))')"
[[ "$q_ids" == "task-packet implementer-capsule" ]] \
  || fail "case4: quarantined findings-ledger not excluded. got:[$q_ids]"
[[ "$q" != *leak* ]] || fail "case4: quarantined bytes reached the event data"
rm -f "$run_dir/findings-status.json.quarantined"

# --- Case 5: empty-source robustness ---------------------------------------
empty_dir="$tmp/empty-run"
mkdir -p "$empty_dir"
e="$(event_data reviewer T-9 R-9 1 no-survivors "$empty_dir")" \
  || fail "case5: builder(empty) exited non-zero"
printf '%s' "$e" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  || fail "case5: empty-source output is not valid JSON"
e_sources="$(printf '%s' "$e" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["manifest"]["sources"]))')"
[[ "$e_sources" == "[]" ]] || fail "case5: empty run_dir did not yield []. got:[$e_sources]"
e_strategy="$(printf '%s' "$e" | python3 -c 'import json,sys; print(json.load(sys.stdin)["strategy"])')"
[[ "$e_strategy" == "rehydrate" ]] || fail "case5: strategy not rehydrate on empty source set"

# --- Case 6: purity / evidence invariance ----------------------------------
after_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]] || fail "case6: builder mutated the source tree (not read-only)"

# appends NO events itself
[[ ! -e "$tmp/.singular-state/events.ndjson" ]] \
  || fail "case6: builder appended events (should PRODUCE data only)"

# grants no independence: rehydrate strategy stays tainted
tainted="$(bash -c 'source "'"$LIB"'"; singular_ctx_route_strategy_tainted rehydrate')" \
  || fail "case6: taint query exited non-zero"
[[ "$tainted" == "1" ]] || fail "case6: rehydrate strategy no longer tainted (got [$tainted])"

echo "ctx-rehydrate-event tests passed"
