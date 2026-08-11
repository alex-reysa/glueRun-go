#!/usr/bin/env bash
# Covers the first strict-test-first slice of DAG node `rehydrate-path`
# (stage S5-routing, layer engine_runtime): the pure, read-only rehydration
# packet assembler `engine/ctx-rehydrate.sh`.
#
#   singular_ctx_rehydrate_packet   id=path [id=path ...]   # labeled text packet
#   singular_ctx_rehydrate_manifest id=path [id=path ...]   # JSON {id, sha256}
#
# Both assemble a deterministic, section-capped, quarantine-aware view over a
# fixed set of durable artifact sources (task packet, implementer/reviewer
# capsules, findings + assumption ledgers, critique + decision records):
#   - Deterministic: identical bytes -> byte-identical packet AND manifest;
#     sections emitted in a fixed, documented order regardless of argument or
#     on-disk order.
#   - Capped: each section body truncated to <= SINGULAR_CONTEXT_SECTION_MAX_CHARS
#     (default 4000) with a stable marker.
#   - Quarantine-aware: a `*.quarantined` source, or an original whose
#     `.quarantined` sibling exists, never reaches the packet or the manifest
#     (composes the integrated singular_ctx_artifact_exclude).
#   - Manifest: exactly the INCLUDED source ids, each with a sha256 of that
#     artifact's bytes.
#   - Pure / read-only: the source files are byte-identical before and after,
#     and the function never exits non-zero on well-formed input.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SINGULAR_ROOT="$tmp"

run_dir="$tmp/run-state/RUN-REHYDRATE"
mkdir -p "$run_dir"

# --- Durable artifact fixtures (fixed source classes) -----------------------
printf '{"task":"T"}\n'        >"$run_dir/task-packet.json"
printf '{"impl":"cap"}\n'      >"$run_dir/implementer-capsule.json"
printf '{"rev":"cap"}\n'       >"$run_dir/reviewer-capsule.json"
printf '{"findings":[]}\n'     >"$run_dir/findings-status.json"
printf '{"assumptions":[]}\n'  >"$run_dir/assumptions.json"
printf '{"critique":"c"}\n'    >"$run_dir/critique.json"
printf '{"decision":"d"}\n'    >"$run_dir/decision.json"

# Documented fixed section order (independent of argument order).
FIXED_ORDER="task-packet implementer-capsule reviewer-capsule findings-ledger assumptions-ledger critique-record decision-record"

# Full source set, deliberately SCRAMBLED to prove ordering is by class, not argv.
scrambled=(
  "decision-record=$run_dir/decision.json"
  "task-packet=$run_dir/task-packet.json"
  "reviewer-capsule=$run_dir/reviewer-capsule.json"
  "critique-record=$run_dir/critique.json"
  "findings-ledger=$run_dir/findings-status.json"
  "implementer-capsule=$run_dir/implementer-capsule.json"
  "assumptions-ledger=$run_dir/assumptions.json"
)
# Same set in FIXED order — must yield byte-identical output.
ordered=(
  "task-packet=$run_dir/task-packet.json"
  "implementer-capsule=$run_dir/implementer-capsule.json"
  "reviewer-capsule=$run_dir/reviewer-capsule.json"
  "findings-ledger=$run_dir/findings-status.json"
  "assumptions-ledger=$run_dir/assumptions.json"
  "critique-record=$run_dir/critique.json"
  "decision-record=$run_dir/decision.json"
)

rehydrate() {
  bash -c '
    source "'"$LIB"'"
    mode="$1"; shift
    singular_ctx_rehydrate_"$mode" "$@"
  ' _ "$@"
}

# section headers, in output order, from a packet on stdin
packet_ids() { grep -E '^=== .* ===$' | sed -E 's/^=== (.*) ===$/\1/'; }
# manifest ids, in output order
manifest_ids() {
  python3 -c 'import json,sys; print("\n".join(s["id"] for s in json.load(sys.stdin)["sources"]))'
}

# Snapshot the source tree so we can prove the assembler is read-only.
before_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"

# --- Case 1: determinism (byte-identical across runs) -----------------------
p1="$(rehydrate packet "${scrambled[@]}")"   || fail "case1: packet exited non-zero"
p2="$(rehydrate packet "${scrambled[@]}")"   || fail "case1: packet(2) exited non-zero"
[[ "$p1" == "$p2" ]] || fail "case1: packet not deterministic"
m1="$(rehydrate manifest "${scrambled[@]}")" || fail "case1: manifest exited non-zero"
m2="$(rehydrate manifest "${scrambled[@]}")" || fail "case1: manifest(2) exited non-zero"
[[ "$m1" == "$m2" ]] || fail "case1: manifest not deterministic"

# --- Case 2: fixed order, independent of argument order ---------------------
p_ord="$(rehydrate packet "${ordered[@]}")" || fail "case2: packet(ordered) exited non-zero"
[[ "$p1" == "$p_ord" ]] || fail "case2: packet order depends on argv"
got_ids="$(printf '%s\n' "$p1" | packet_ids | tr '\n' ' ' | sed 's/ $//')"
[[ "$got_ids" == "$FIXED_ORDER" ]] || fail "case2: packet section order wrong. got:[$got_ids] want:[$FIXED_ORDER]"
got_mids="$(printf '%s\n' "$m1" | manifest_ids | tr '\n' ' ' | sed 's/ $//')"
[[ "$got_mids" == "$FIXED_ORDER" ]] || fail "case2: manifest id order wrong. got:[$got_mids] want:[$FIXED_ORDER]"

# --- Case 3: caps ----------------------------------------------------------
# A single oversized (single-line) source; cap tightened to 200.
big="$(printf 'X%.0s' $(seq 1 9000))"
printf '%s\n' "$big" >"$run_dir/task-packet.json"
export SINGULAR_CONTEXT_SECTION_MAX_CHARS=200
cp1="$(rehydrate packet "task-packet=$run_dir/task-packet.json")" || fail "case3: capped packet exited non-zero"
# body = everything after the single "=== task-packet ===" header line
cbody="$(printf '%s\n' "$cp1" | tail -n +2)"
(( ${#cbody} <= 200 )) || fail "case3: section body ${#cbody} exceeds cap 200"
[[ "$cbody" == *"truncated"* ]] || fail "case3: capped section missing stable truncation marker"
unset SINGULAR_CONTEXT_SECTION_MAX_CHARS

# Default cap (4000) honored when the knob is unset: a 3000-char single line is
# NOT truncated; the same source under cap=200 IS truncated (tighter).
mid="$(printf 'Y%.0s' $(seq 1 3000))"
printf '%s\n' "$mid" >"$run_dir/reviewer-capsule.json"
dp="$(rehydrate packet "reviewer-capsule=$run_dir/reviewer-capsule.json")" || fail "case3b: default-cap packet exited non-zero"
dbody="$(printf '%s\n' "$dp" | tail -n +2)"
(( ${#dbody} == 3000 )) || fail "case3b: default cap 4000 not honored (body=${#dbody})"
[[ "$dbody" != *"truncated"* ]] || fail "case3b: 3000-char body wrongly truncated under default cap"
export SINGULAR_CONTEXT_SECTION_MAX_CHARS=200
tp="$(rehydrate packet "reviewer-capsule=$run_dir/reviewer-capsule.json")" || fail "case3c: tight-cap packet exited non-zero"
tbody="$(printf '%s\n' "$tp" | tail -n +2)"
(( ${#tbody} <= 200 )) || fail "case3c: tightened cap not applied (body=${#tbody})"
unset SINGULAR_CONTEXT_SECTION_MAX_CHARS
# restore small fixtures for the remaining cases
printf '{"task":"T"}\n' >"$run_dir/task-packet.json"
printf '{"rev":"cap"}\n' >"$run_dir/reviewer-capsule.json"

# --- Case 4: quarantine exclusion ------------------------------------------
# critique-record: original present but a .quarantined sibling exists -> DROP.
printf '{"leak":"c"}\n' >"$run_dir/critique.json.quarantined"
# decision-record: the source path is itself a *.quarantined file -> DROP.
printf '{"leak":"d"}\n' >"$run_dir/decision.json.quarantined"
q_sources=(
  "task-packet=$run_dir/task-packet.json"
  "implementer-capsule=$run_dir/implementer-capsule.json"
  "reviewer-capsule=$run_dir/reviewer-capsule.json"
  "findings-ledger=$run_dir/findings-status.json"
  "assumptions-ledger=$run_dir/assumptions.json"
  "critique-record=$run_dir/critique.json"
  "decision-record=$run_dir/decision.json.quarantined"
)
qp="$(rehydrate packet "${q_sources[@]}")"   || fail "case4: quarantine packet exited non-zero"
qm="$(rehydrate manifest "${q_sources[@]}")" || fail "case4: quarantine manifest exited non-zero"
q_ids="$(printf '%s\n' "$qp" | packet_ids | tr '\n' ' ' | sed 's/ $//')"
want_q="task-packet implementer-capsule reviewer-capsule findings-ledger assumptions-ledger"
[[ "$q_ids" == "$want_q" ]] || fail "case4: quarantined sources leaked into packet. got:[$q_ids]"
qm_ids="$(printf '%s\n' "$qm" | manifest_ids | tr '\n' ' ' | sed 's/ $//')"
[[ "$qm_ids" == "$want_q" ]] || fail "case4: quarantined sources leaked into manifest. got:[$qm_ids]"
[[ "$qp" != *"leak"* && "$qm" != *"leak"* ]] || fail "case4: quarantined bytes reached output"
# survivors still deterministic
qp2="$(rehydrate packet "${q_sources[@]}")" || fail "case4: quarantine packet(2) exited non-zero"
[[ "$qp" == "$qp2" ]] || fail "case4: quarantined-set packet not deterministic"

# --- Case 5: manifest hashes ------------------------------------------------
# Each included id carries the sha256 of its bytes; two runs agree; changing one
# artifact's bytes changes ONLY that entry.
hash_of() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(s["sha256"] for s in d["sources"] if s["id"]==sys.argv[1]))' "$1"
}
mA="$(rehydrate manifest "${ordered[@]}")"
mB="$(rehydrate manifest "${ordered[@]}")"
[[ "$mA" == "$mB" ]] || fail "case5: manifest hashes not stable across runs"
task_hash="$(printf '%s\n' "$mA" | hash_of task-packet)"
py_hash="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$run_dir/task-packet.json")"
[[ "$task_hash" == "$py_hash" ]] || fail "case5: manifest sha256 not derived from artifact bytes"
rev_before="$(printf '%s\n' "$mA" | hash_of reviewer-capsule)"
# mutate ONLY the task-packet artifact
printf '{"task":"CHANGED"}\n' >"$run_dir/task-packet.json"
mC="$(rehydrate manifest "${ordered[@]}")"
task_after="$(printf '%s\n' "$mC" | hash_of task-packet)"
rev_after="$(printf '%s\n' "$mC" | hash_of reviewer-capsule)"
[[ "$task_after" != "$task_hash" ]] || fail "case5: changed artifact hash did not change"
[[ "$rev_after" == "$rev_before" ]] || fail "case5: unrelated artifact hash changed"
printf '{"task":"T"}\n' >"$run_dir/task-packet.json"  # restore
rm -f "$run_dir/critique.json.quarantined" "$run_dir/decision.json.quarantined"

# --- Read-only / purity -----------------------------------------------------
after_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]] || fail "assembler mutated the source tree (not read-only)"

echo "ctx-rehydrate tests passed"
