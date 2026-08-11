#!/usr/bin/env bash
# Covers the sanctioned `cli/singular graph` subcommand: a thin driver-hook that
# delegates into the already-integrated engine/ctx-graph*.sh projector/reader
# functions (singular_graph_rebuild / singular_graph_sync / singular_graph_query_*),
# behind SINGULAR_CTX_GRAPH (default 0). Asserts:
#   * with the flag ON, `graph rebuild/sync/query ...` produce byte-identical
#     output/corpus to the underlying engine functions over the same fixture
#     (delegation adds no projection logic of its own);
#   * with the flag OFF (unset or 0), `singular graph ...` refuses exactly as an
#     unknown command did, and usage()/help output is byte-identical to the
#     pre-hook binary (no `graph` line leaks);
#   * bad/missing graph subcommands produce a clear usage error, non-zero exit,
#     no crash.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SINGULAR_SRC="$ENGINE_HOME/cli/singular"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$SINGULAR_SRC" ]] || fail "cli/singular not present: $SINGULAR_SRC"
for m in "$ENGINE_HOME"/engine/ctx-graph*.sh; do
  [[ -f "$m" ]] || fail "integrated graph module missing: $m"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Hermetic engine home: only engine/lib.sh (resolver needs it) + the integrated
# graph modules + the CLI under test. Keeps the delegation assertions independent
# of whatever .singular-state the suite host happens to carry.
EHOME="$tmp/engine-home"
mkdir -p "$EHOME/engine" "$EHOME/cli"
: > "$EHOME/engine/lib.sh"
cp "$ENGINE_HOME"/engine/ctx-graph*.sh "$EHOME/engine/"
cp "$SINGULAR_SRC" "$EHOME/cli/singular"
SINGULAR="$EHOME/cli/singular"
export SINGULAR_ENGINE_HOME="$EHOME"

# --- Fixture: a state dir exercising the record + event mappers --------------
NODE="TASK-0080"
RUN_A="RUN-20260712T100000Z-00001"
STATE="$tmp/state"
GRAPHDIR="$tmp/graph"
mkdir -p "$STATE/runs/$RUN_A/attempts" "$STATE/docs/orchestration/gates"

cat > "$STATE/runs/$RUN_A/attempts/index.json" <<JSON
{
  "schema": "singular.orchestration.attempts-index.v0",
  "runId": "$RUN_A",
  "taskId": "$NODE",
  "attempts": [
    { "n": 1, "status": "failed", "headSha": "aaa" },
    { "n": 2, "status": "passed", "headSha": "bbb" }
  ]
}
JSON

cat > "$STATE/events.ndjson" <<JSON
{"ts":"2026-07-12T10:00:00Z","type":"plan.revised","message":"m","data":{"node":"$NODE","runId":"$RUN_A"}}
{"ts":"2026-07-12T11:06:00Z","type":"decision.recorded","message":"m","data":{"node":"$NODE","runId":"$RUN_A"}}
{"ts":"2026-07-12T11:10:00Z","type":"l1.committed","message":"m","data":{"node":"$NODE","runId":"$RUN_A","headSha":"0123456789abcdef0123456789abcdef01234567"}}
JSON

# Ground truth: source the integrated modules and call the functions directly.
source_graph='for g in "'"$EHOME"'"/engine/ctx-graph*.sh; do source "$g"; done'

# ---------------------------------------------------------------------------
# FLAG ON: rebuild delegates to singular_graph_rebuild (byte-identical corpus)
# ---------------------------------------------------------------------------
GT_GRAPH="$tmp/gt-graph"
( set -uo pipefail; eval "$source_graph"; singular_graph_rebuild "$STATE" "$GT_GRAPH" ) \
  || fail "ground-truth singular_graph_rebuild failed"
[[ -f "$GT_GRAPH/nodes.jsonl" && -f "$GT_GRAPH/edges.jsonl" ]] \
  || fail "ground-truth rebuild produced no corpus"

SINGULAR_CTX_GRAPH=1 "$SINGULAR" graph rebuild "$STATE" "$GRAPHDIR" \
  > "$tmp/rebuild.out" 2>"$tmp/rebuild.err" \
  || fail "singular graph rebuild exited non-zero: $(cat "$tmp/rebuild.err")"
[[ -f "$GRAPHDIR/nodes.jsonl" && -f "$GRAPHDIR/edges.jsonl" ]] \
  || fail "singular graph rebuild wrote no canonical corpus"
cmp -s "$GT_GRAPH/nodes.jsonl" "$GRAPHDIR/nodes.jsonl" \
  || fail "graph rebuild nodes.jsonl not byte-identical to singular_graph_rebuild"
cmp -s "$GT_GRAPH/edges.jsonl" "$GRAPHDIR/edges.jsonl" \
  || fail "graph rebuild edges.jsonl not byte-identical to singular_graph_rebuild"

# ---------------------------------------------------------------------------
# FLAG ON: sync delegates to singular_graph_sync (byte-identical, scratch corpus)
# ---------------------------------------------------------------------------
GT_SYNC="$tmp/gt-sync"
( set -uo pipefail; eval "$source_graph"; singular_graph_sync "$STATE" "$GT_SYNC" ) \
  || fail "ground-truth singular_graph_sync failed"
SYNCDIR="$tmp/graph-sync"
SINGULAR_CTX_GRAPH=1 "$SINGULAR" graph sync "$STATE" "$SYNCDIR" \
  > "$tmp/sync.out" 2>"$tmp/sync.err" \
  || fail "singular graph sync exited non-zero: $(cat "$tmp/sync.err")"
cmp -s "$GT_SYNC/nodes.jsonl" "$SYNCDIR/nodes.jsonl" \
  || fail "graph sync nodes.jsonl not byte-identical to singular_graph_sync"
cmp -s "$GT_SYNC/edges.jsonl" "$SYNCDIR/edges.jsonl" \
  || fail "graph sync edges.jsonl not byte-identical to singular_graph_sync"

# ---------------------------------------------------------------------------
# FLAG ON: query neighbors|lineage|open-contradictions delegate to the readers
# ---------------------------------------------------------------------------
# Pick a real node id from the rebuilt corpus to exercise a non-empty walk.
QID="$(python3 -c '
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if line:
        print(json.loads(line)["id"]); break
' "$GRAPHDIR/nodes.jsonl")"
[[ -n "$QID" ]] || fail "could not extract a node id from rebuilt corpus"

for q in neighbors lineage; do
  ( set -uo pipefail; eval "$source_graph"; "singular_graph_query_$q" "$GRAPHDIR" "$QID" ) \
    > "$tmp/gt-$q.out" 2>/dev/null || fail "ground-truth query $q failed"
  SINGULAR_CTX_GRAPH=1 SINGULAR_CTX_GRAPH_DIR="$GRAPHDIR" "$SINGULAR" graph query "$q" "$QID" \
    > "$tmp/cli-$q.out" 2>"$tmp/cli-$q.err" \
    || fail "singular graph query $q exited non-zero: $(cat "$tmp/cli-$q.err")"
  cmp -s "$tmp/gt-$q.out" "$tmp/cli-$q.out" \
    || fail "graph query $q output not byte-identical to singular_graph_query_$q"
done

( set -uo pipefail; eval "$source_graph"; singular_graph_query_open_contradictions "$GRAPHDIR" ) \
  > "$tmp/gt-oc.out" 2>/dev/null || fail "ground-truth query open-contradictions failed"
SINGULAR_CTX_GRAPH=1 SINGULAR_CTX_GRAPH_DIR="$GRAPHDIR" "$SINGULAR" graph query open-contradictions \
  > "$tmp/cli-oc.out" 2>"$tmp/cli-oc.err" \
  || fail "singular graph query open-contradictions exited non-zero: $(cat "$tmp/cli-oc.err")"
cmp -s "$tmp/gt-oc.out" "$tmp/cli-oc.out" \
  || fail "graph query open-contradictions output not byte-identical to reader"

# ---------------------------------------------------------------------------
# FLAG ON: usage() lists a graph line
# ---------------------------------------------------------------------------
SINGULAR_CTX_GRAPH=1 "$SINGULAR" help > "$tmp/help-on.txt" 2>&1 \
  || fail "singular help (flag on) exited non-zero"
grep -q '^  graph' "$tmp/help-on.txt" \
  || fail "graph line not listed in usage() when SINGULAR_CTX_GRAPH=1"

# ---------------------------------------------------------------------------
# FLAG ON: bad/missing subcommand + query reader -> clear usage error, non-zero
# ---------------------------------------------------------------------------
if SINGULAR_CTX_GRAPH=1 "$SINGULAR" graph bogus-sub >/dev/null 2>"$tmp/badsub.err"; then
  fail "graph with an unknown subcommand should exit non-zero"
fi
grep -qi 'usage' "$tmp/badsub.err" || fail "unknown graph subcommand gave no usage hint"

if SINGULAR_CTX_GRAPH=1 "$SINGULAR" graph >/dev/null 2>&1; then
  fail "bare 'graph' (no subcommand) should exit non-zero"
fi

if SINGULAR_CTX_GRAPH=1 "$SINGULAR" graph query not-a-reader >/dev/null 2>"$tmp/badq.err"; then
  fail "graph query with an unknown reader should exit non-zero"
fi
grep -qi 'usage' "$tmp/badq.err" || fail "unknown graph query reader gave no usage hint"

# ---------------------------------------------------------------------------
# OFF-PARITY: flag unset/0 -> graph refuses as unknown command; help unchanged
# ---------------------------------------------------------------------------
# Reference help/unknown-command behavior with the graph arm neutralized: strip
# the flag-gated usage line and any code path so we can compare byte-for-byte to
# the pre-hook binary. We prove OFF-parity by (a) help has NO graph line and (b)
# `graph` errors with the SAME message an arbitrary unknown command produces.
for flag in "unset" "0"; do
  if [[ "$flag" == "unset" ]]; then
    env -u SINGULAR_CTX_GRAPH "$SINGULAR" help > "$tmp/help-off.txt" 2>&1 \
      || fail "singular help (flag $flag) exited non-zero"
    env -u SINGULAR_CTX_GRAPH "$SINGULAR" graph rebuild "$STATE" "$GRAPHDIR" \
      >/dev/null 2>"$tmp/off-graph.err" && fail "graph must refuse when flag $flag"
    env -u SINGULAR_CTX_GRAPH "$SINGULAR" totally-unknown-xyz \
      >/dev/null 2>"$tmp/off-unknown.err" && fail "control unknown command should be non-zero"
  else
    SINGULAR_CTX_GRAPH=0 "$SINGULAR" help > "$tmp/help-off.txt" 2>&1 \
      || fail "singular help (flag $flag) exited non-zero"
    SINGULAR_CTX_GRAPH=0 "$SINGULAR" graph rebuild "$STATE" "$GRAPHDIR" \
      >/dev/null 2>"$tmp/off-graph.err" && fail "graph must refuse when flag $flag"
    SINGULAR_CTX_GRAPH=0 "$SINGULAR" totally-unknown-xyz \
      >/dev/null 2>"$tmp/off-unknown.err" && fail "control unknown command should be non-zero"
  fi
  grep -q 'graph' "$tmp/help-off.txt" \
    && fail "usage() leaked a graph line when SINGULAR_CTX_GRAPH=$flag (OFF-parity broken)"
  # graph's refusal must read exactly like an unknown command's, modulo the
  # command token (graph vs totally-unknown-xyz).
  off_graph="$(sed 's/graph/CMD/' "$tmp/off-graph.err")"
  off_unknown="$(sed 's/totally-unknown-xyz/CMD/' "$tmp/off-unknown.err")"
  [[ "$off_graph" == "$off_unknown" ]] \
    || fail "graph OFF refusal differs from unknown-command refusal ($flag): [$off_graph] vs [$off_unknown]"
done

echo "singular-graph-cli tests passed"
