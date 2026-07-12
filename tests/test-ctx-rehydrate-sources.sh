#!/usr/bin/env bash
# Covers the third strict-test-first slice of DAG node `rehydrate-path`
# (stage S5-routing, layer engine_runtime): the pure, read-only durable-source
# resolver `engine/ctx-rehydrate-sources.sh`.
#
#   gluerun_ctx_rehydrate_sources <run_dir> [extra-id=path ...]
#
# Enumerates the class-tagged durable rehydration sources that EXIST under
# <run_dir>, one `<id>=<path>` spec per line, in the assembler's fixed
# source-class order, deterministically (independent of on-disk enumeration).
# Its stdout composes directly as arguments to gluerun_ctx_rehydrate_packet /
# gluerun_ctx_rehydrate_manifest.
#
#   - Class -> run_dir file mapping (single-sourced in the resolver):
#       task-packet          -> packet.json
#       implementer-capsule  -> implementer-capsule.json
#       reviewer-capsule     -> reviewer-capsule.json
#       findings-ledger      -> findings-status.json
#       assumptions-ledger   -> assumptions-ledger.json
#       critique-record      -> plan-critique.json
#   - Existing-files-only: a class is emitted only when its mapped file exists.
#   - Caller-supplied `extra-id=path` specs are appended verbatim after the
#     run_dir-resolved specs.
#   - Quarantine exclusion is NOT performed here: the resolver only enumerates
#     candidates; the assembler/manifest own the single quarantine authority.
#   - Pure / read-only: writes/renames/deletes nothing, appends no events, and
#     never exits non-zero on well-formed input (absent/empty run_dir -> no
#     specs, non-fatal). Confers no independence: `rehydrate` stays tainted.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GLUERUN_ROOT="$tmp"

run_dir="$tmp/run-state/RUN-REHYDRATE-SOURCES"
mkdir -p "$run_dir"

sources() {
  bash -c '
    source "'"$LIB"'"
    gluerun_ctx_rehydrate_sources "$@"
  ' _ "$@"
}
manifest() {
  bash -c '
    source "'"$LIB"'"
    gluerun_ctx_rehydrate_manifest "$@"
  ' _ "$@"
}
manifest_ids() {
  python3 -c 'import json,sys; print("\n".join(s["id"] for s in json.load(sys.stdin)["sources"]))'
}

# --- Case 1: enumeration + omission ----------------------------------------
# run_dir has packet.json, implementer-capsule.json, findings-status.json but
# NOT reviewer-capsule.json -> exactly three class-tagged specs, fixed order.
printf '{"task":"T"}\n'    >"$run_dir/packet.json"
printf '{"impl":"cap"}\n'  >"$run_dir/implementer-capsule.json"
printf '{"findings":[]}\n' >"$run_dir/findings-status.json"

before_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"

out="$(sources "$run_dir")" || fail "case1: resolver exited non-zero"
want="task-packet=$run_dir/packet.json
implementer-capsule=$run_dir/implementer-capsule.json
findings-ledger=$run_dir/findings-status.json"
[[ "$out" == "$want" ]] || fail "case1: enumeration/omission wrong.
got:
$out
want:
$want"

# --- Case 2: determinism ---------------------------------------------------
out2="$(sources "$run_dir")" || fail "case2: resolver(2) exited non-zero"
[[ "$out" == "$out2" ]] || fail "case2: resolver not deterministic"

# --- Case 3: full fixed order, independent of on-disk creation order --------
printf '{"rev":"cap"}\n'         >"$run_dir/reviewer-capsule.json"
printf '{"assumptions":[]}\n'    >"$run_dir/assumptions-ledger.json"
printf '{"critique":"c"}\n'      >"$run_dir/plan-critique.json"
full="$(sources "$run_dir")" || fail "case3: resolver(full) exited non-zero"
want_full="task-packet=$run_dir/packet.json
implementer-capsule=$run_dir/implementer-capsule.json
reviewer-capsule=$run_dir/reviewer-capsule.json
findings-ledger=$run_dir/findings-status.json
assumptions-ledger=$run_dir/assumptions-ledger.json
critique-record=$run_dir/plan-critique.json"
[[ "$full" == "$want_full" ]] || fail "case3: fixed full order wrong.
got:
$full
want:
$want_full"

# --- Case 4: composition with the assembler + quarantine authority ----------
# Resolver output composes directly as manifest arguments; its ids are exactly
# the resolved classes. A quarantined artifact under run_dir is STILL enumerated
# by the resolver, yet EXCLUDED from the manifest by the assembler.
printf '{"leak":"c"}\n' >"$run_dir/plan-critique.json.quarantined"
comp="$(sources "$run_dir")" || fail "case4: resolver(comp) exited non-zero"
# resolver still enumerates the quarantined critique-record candidate
[[ "$comp" == *"critique-record=$run_dir/plan-critique.json"* ]] \
  || fail "case4: resolver dropped the quarantined candidate (quarantine authority leaked into resolver)"
# feed the resolver output straight into the manifest assembler
IFS=$'\n' read -r -d '' -a comp_specs < <(printf '%s\0' "$comp")
m="$(manifest "${comp_specs[@]}")" || fail "case4: manifest exited non-zero"
m_ids="$(printf '%s\n' "$m" | manifest_ids | tr '\n' ' ' | sed 's/ $//')"
want_m="task-packet implementer-capsule reviewer-capsule findings-ledger assumptions-ledger"
[[ "$m_ids" == "$want_m" ]] || fail "case4: manifest ids wrong (quarantine not applied by assembler). got:[$m_ids] want:[$want_m]"
[[ "$m" != *"leak"* ]] || fail "case4: quarantined bytes reached the manifest"
rm -f "$run_dir/plan-critique.json.quarantined"

# --- Case 5: extra specs appended verbatim ---------------------------------
decision="$tmp/repo-decision-record.json"
printf '{"decision":"d"}\n' >"$decision"
ext="$(sources "$run_dir" "decision-record=$decision")" || fail "case5: resolver(extra) exited non-zero"
want_ext="$want_full
decision-record=$decision"
[[ "$ext" == "$want_ext" ]] || fail "case5: extra spec not appended after run_dir specs.
got:
$ext
want:
$want_ext"

# --- Case 6: purity / evidence invariance ----------------------------------
after_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
[[ "$before_hash" != "$after_hash" ]] || fail "case6: fixtures unchanged? (harness bug)"
# The resolver itself must not mutate the tree: snapshot around a lone call.
snap_before="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
sources "$run_dir" >/dev/null 2>&1 || fail "case6: resolver exited non-zero"
snap_after="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
[[ "$snap_before" == "$snap_after" ]] || fail "case6: resolver mutated the source tree (not read-only)"

# absent run_dir -> no specs, non-fatal
absent="$(sources "$tmp/does-not-exist")" || fail "case6: absent run_dir exited non-zero"
[[ -z "$absent" ]] || fail "case6: absent run_dir yielded specs: [$absent]"
# empty run_dir -> no specs, non-fatal
mkdir -p "$tmp/empty-run"
empty="$(sources "$tmp/empty-run")" || fail "case6: empty run_dir exited non-zero"
[[ -z "$empty" ]] || fail "case6: empty run_dir yielded specs: [$empty]"

# grants no independence: rehydrate strategy stays tainted
tainted="$(bash -c 'source "'"$LIB"'"; gluerun_ctx_route_strategy_tainted rehydrate')" \
  || fail "case6: taint query exited non-zero"
[[ "$tainted" == "1" ]] || fail "case6: rehydrate strategy no longer tainted (got [$tainted])"

echo "ctx-rehydrate-sources tests passed"
