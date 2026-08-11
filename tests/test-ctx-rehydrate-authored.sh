#!/usr/bin/env bash
# Covers the OPTIONAL authored-knowledge manifest ingestion leaf (stage
# S5-routing, node `rehydrate-path`, layer engine_runtime; singular-brain
# integration point 3). `engine/ctx-rehydrate-authored.sh` ships a PURE,
# read-only, present-but-uncalled selector
#
#   singular_ctx_rehydrate_authored_select <manifest-json-path>
#
# that parses a FIXTURE authored-knowledge manifest and selects the injectable
# entries under the AUTHORED-KNOWLEDGE class rules:
#
#   - A normal current entry is emitted with its id, tagged AUTHORED-KNOWLEDGE,
#     and is NEVER marked authoritative / host-verified / tainted.
#   - An entry flagged `description_unverified` is NEVER emitted as current.
#   - A quarantined path-backed entry is excluded by composing the integrated
#     singular_ctx_artifact_exclude (a `*.quarantined` path, or an original whose
#     `.quarantined` sibling exists on disk, never survives).
#   - Deterministic: identical manifest bytes yield byte-identical output in a
#     fixed (id-sorted) order.
#   - Pure / read-only: it mutates nothing on disk, appends no events, and never
#     exits non-zero on well-formed input. A malformed or absent manifest yields
#     an empty selection (fail-soft).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_dir="$tmp/run-state/RUN-AUTHORED"
mkdir -p "$run_dir"

# --- Path-backed artifact fixtures on disk ----------------------------------
# alpha-doc's path is an ordinary safe artifact (no quarantined sibling) -> KEEP
# big-doc's path has a `.quarantined` sibling on disk                    -> DROP
printf '# alpha doc body\n'  >"$run_dir/alpha.md"
printf '{"leak":"x"}\n'      >"$run_dir/big.md.quarantined"

# --- Authored-knowledge manifest fixture ------------------------------------
# Entries deliberately in NON-sorted id order so the id-sorted emission order is
# exercised. Contains: a normal body entry, a description_unverified entry, a
# quarantined path-backed entry, and a safe path-backed entry.
manifest="$tmp/authored-manifest.json"
cat >"$manifest" <<JSON
{
  "schema": "singular.orchestration.authored-knowledge-manifest.v0",
  "entries": [
    {
      "id": "zeta-guide",
      "body": "Prefer tabs. Keep leaves pure.",
      "load-when": ["always"],
      "freshness": "current"
    },
    {
      "id": "draft-note",
      "body": "Unverified scratch note.",
      "load-when": ["editing"],
      "freshness": "current",
      "description_unverified": true
    },
    {
      "id": "big-doc",
      "path": "$run_dir/big.md",
      "load-when": ["deep-dive"],
      "freshness": "current"
    },
    {
      "id": "alpha-doc",
      "path": "$run_dir/alpha.md",
      "load-when": ["startup"],
      "freshness": "current"
    }
  ]
}
JSON

# Snapshot the on-disk tree so we can prove the selector is read-only.
tree_hash() {
  find "$run_dir" "$manifest" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}'
}
before_hash="$(tree_hash)"

select_authored() {
  bash -c '
    source "'"$LIB"'"
    singular_ctx_rehydrate_authored_select "$1"
  ' _ "$1"
}

# --- Case 1: core selection --------------------------------------------------
out="$(select_authored "$manifest")" || fail "case1: selector exited non-zero"

grep -q '"id": "alpha-doc"' <<<"$out" \
  || fail "case1: safe path-backed entry alpha-doc not emitted. got:[$out]"
grep -q '"id": "zeta-guide"' <<<"$out" \
  || fail "case1: normal body entry zeta-guide not emitted. got:[$out]"
grep -q '"id": "draft-note"' <<<"$out" \
  && fail "case1: description_unverified entry draft-note emitted as current. got:[$out]"
grep -q '"id": "big-doc"' <<<"$out" \
  && fail "case1: quarantined path-backed entry big-doc not excluded. got:[$out]"

# Exactly two survivors, one per line.
n="$(grep -c . <<<"$out")"
[[ "$n" == "2" ]] || fail "case1: expected 2 survivors, got $n. out:[$out]"

# --- Case 2: AUTHORED-KNOWLEDGE class, never authoritative -------------------
# Every emitted entry must carry the distinct authored-knowledge class marker
# and must never be marked authoritative / host-verified / tainted.
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  grep -q '"class": "authored-knowledge"' <<<"$line" \
    || fail "case2: emitted entry missing authored-knowledge class. line:[$line]"
  grep -q '"authoritative": false' <<<"$line" \
    || fail "case2: emitted entry not explicitly non-authoritative. line:[$line]"
done <<<"$out"
grep -Eq '"(host-verified|host_verified|tainted|authoritative)": true' <<<"$out" \
  && fail "case2: an entry was marked authoritative/host-verified/tainted. out:[$out]"

# --- Case 3: determinism + fixed id-sorted order ----------------------------
out2="$(select_authored "$manifest")" || fail "case3: selector exited non-zero on rerun"
[[ "$out" == "$out2" ]] || fail "case3: non-deterministic output.\n1:[$out]\n2:[$out2]"

line_alpha="$(grep -n '"id": "alpha-doc"' <<<"$out" | head -1 | cut -d: -f1)"
line_zeta="$(grep -n '"id": "zeta-guide"' <<<"$out" | head -1 | cut -d: -f1)"
[[ -n "$line_alpha" && -n "$line_zeta" && "$line_alpha" -lt "$line_zeta" ]] \
  || fail "case3: entries not in fixed id-sorted order (alpha before zeta). out:[$out]"

# --- Case 4: fail-soft on malformed and absent manifests --------------------
bad="$tmp/malformed.json"
printf '{ this is : not json,,,\n' >"$bad"
out_bad="$(select_authored "$bad")" || fail "case4: selector exited non-zero on malformed manifest"
[[ -z "$out_bad" ]] || fail "case4: malformed manifest produced output. got:[$out_bad]"

out_absent="$(select_authored "$tmp/does-not-exist.json")" \
  || fail "case4: selector exited non-zero on absent manifest"
[[ -z "$out_absent" ]] || fail "case4: absent manifest produced output. got:[$out_absent]"

out_empty="$(select_authored "")" || fail "case4: selector exited non-zero on empty arg"
[[ -z "$out_empty" ]] || fail "case4: empty-arg produced output. got:[$out_empty]"

# --- Read-only: the selector mutated nothing on disk ------------------------
after_hash="$(tree_hash)"
[[ "$before_hash" == "$after_hash" ]] || fail "selector mutated the tree"

echo "ctx-rehydrate-authored tests passed"
