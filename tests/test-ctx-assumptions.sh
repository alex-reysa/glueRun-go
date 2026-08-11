#!/usr/bin/env bash
# Covers the per-run assumption ledger seed (stage S4-context-packets, node
# assumption-ledger, foundational data-structure slice). `engine/ctx-assumptions.sh`
# ships a PURE, present-but-uncalled helper `singular_ctx_assumptions_seed <task-file>`
# that composes the already-integrated `singular_ctx_packet_json` parser and prints a
# normalized per-run assumption ledger JSON:
#   - a packet declaring assumptions -> {"schema":".ctx-assumptions.v0","assumptions":[
#         {"id":"A1","status":..,"claim":..,"basis":..}, ... ]} in declared order
#   - no `## Context packet` block, an empty packet, or zero assumptions -> stable
#         empty ledger {"schema":".ctx-assumptions.v0","assumptions":[]}
#   - a malformed packet fails closed through the parser (empty ledger); the single
#         `ctx.packet_malformed` warning is the PARSER's, never re-emitted by the seed.
# The seed reads the task STRICTLY READ-ONLY and, on well-formed input, appends no
# events of its own.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
TEMPLATE="$ENGINE_HOME/docs/orchestration/tasks/TEMPLATE.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Seed a task file through the real engine helper in an isolated subshell so
# lib.sh's `set -e` and the sourced ctx-*.sh files never contaminate this test
# process. SINGULAR_ROOT is a scratch dir so any state (the parser's malformed
# warning event) lands under $tmp, never in the repo. $2 optionally overrides the
# events file so the malformed case can be inspected in isolation.
seed() {
  local tf="$1" ev="${2:-$tmp/events.ndjson}"
  SINGULAR_ROOT="$tmp" bash -c '
    source "'"$LIB"'"
    SINGULAR_EVENTS_FILE="'"$ev"'"
    singular_ctx_assumptions_seed "'"$tf"'"
  '
}

json_eq() { # $1 = actual stdout, $2 = expected json literal
  python3 - "$1" "$2" <<'PY'
import json, sys
a = json.loads(sys.argv[1])
b = json.loads(sys.argv[2])
sys.exit(0 if a == b else 1)
PY
}

hash_of() { python3 - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
}

EMPTY_LEDGER='{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[]}'

# --- Fixtures ---------------------------------------------------------------

# Full: three assumptions in declared order, all three status values.
full="$tmp/full.md"
cat > "$full" <<'EOF'
# TASK-9101: full assumptions

## Context packet

### Decisions

- Keep the seed pure and read-only

### Assumptions

- [open] runtime is node 20 — package.json engines field
- [validated] db schema already migrated — verified in db.ts
- [violated] the cache is warm — cold-start trace shows a miss

### Inspected symbols

- singular_ctx_packet_json — the composed parser
EOF

# Packet present but zero assumptions (only Decisions).
noassump="$tmp/noassump.md"
cat > "$noassump" <<'EOF'
# TASK-9102: packet without assumptions

## Context packet

### Decisions

- Keep the slice tight
EOF

# Malformed: an assumption entry that does not match the grammar.
malformed="$tmp/malformed.md"
cat > "$malformed" <<'EOF'
# TASK-9103: malformed packet

## Context packet

### Assumptions

- this line has no [status] bracket and no em-dash basis
EOF

# Absent: a copy of the real TEMPLATE (no `## Context packet` block).
absent="$tmp/absent.md"
cp "$TEMPLATE" "$absent"

# --- Case 1: full packet -> ledger with stable positional ids ---------------
out_full="$(seed "$full")" || fail "full: seed exited non-zero"
expected_full='{
  "schema": "singular.orchestration.ctx-assumptions.v0",
  "assumptions": [
    {"id": "A1", "status": "open", "claim": "runtime is node 20", "basis": "package.json engines field"},
    {"id": "A2", "status": "validated", "claim": "db schema already migrated", "basis": "verified in db.ts"},
    {"id": "A3", "status": "violated", "claim": "the cache is warm", "basis": "cold-start trace shows a miss"}
  ]
}'
json_eq "$out_full" "$expected_full" || fail "full: ledger mismatch; got [$out_full]"
assert_contains "$out_full" '"singular.orchestration.ctx-assumptions.v0"' "full: schema const present"
assert_contains "$out_full" '"A1"' "full: id A1 present"
assert_contains "$out_full" '"A3"' "full: id A3 present"

# Deterministic: byte-identical stdout across repeated runs on identical input.
out_full2="$(seed "$full")" || fail "full(2): seed exited non-zero"
[[ "$out_full" == "$out_full2" ]] || fail "full: output not deterministic across runs"

# --- Case 2: absent block -> stable empty ledger ----------------------------
out_absent="$(seed "$absent")" || fail "absent: seed exited non-zero"
json_eq "$out_absent" "$EMPTY_LEDGER" || fail "absent: expected empty ledger, got [$out_absent]"

# --- Case 3: packet with zero assumptions -> stable empty ledger ------------
out_noassump="$(seed "$noassump")" || fail "noassump: seed exited non-zero"
json_eq "$out_noassump" "$EMPTY_LEDGER" || fail "noassump: expected empty ledger, got [$out_noassump]"

# --- Case 4: malformed -> empty ledger + exactly one PARSER warning event ----
ev="$tmp/malformed-events.ndjson"
: > "$ev"
out_bad="$(seed "$malformed" "$ev")" || fail "malformed: seed must exit 0 (fail closed), not error"
json_eq "$out_bad" "$EMPTY_LEDGER" || fail "malformed: expected empty ledger on stdout, got [$out_bad]"
n="$(grep -c 'ctx.packet_malformed' "$ev" 2>/dev/null || echo 0)"
[[ "$n" -eq 1 ]] || fail "malformed: expected exactly one ctx.packet_malformed event (parser's), got $n"
total="$(wc -l < "$ev" | tr -d ' ')"
[[ "$total" -eq 1 ]] || fail "malformed: seed re-emitted events; expected 1 line total, got $total"

# --- Case 5: well-formed seed appends NO events -----------------------------
ev2="$tmp/wf-events.ndjson"
: > "$ev2"
seed "$full" "$ev2" >/dev/null 2>&1 || fail "full(events): seed exited non-zero"
total2="$(wc -l < "$ev2" | tr -d ' ')"
[[ "$total2" -eq 0 ]] || fail "well-formed: seed appended $total2 event(s), expected 0"

# --- Case 6: read-only -> task file byte-identical before/after each seed ----
for f in "$full" "$noassump" "$malformed" "$absent"; do
  before="$(hash_of "$f")"
  seed "$f" "$tmp/ro-events.ndjson" >/dev/null 2>&1 || true
  after="$(hash_of "$f")"
  [[ "$before" == "$after" ]] || fail "read-only: $f mutated by seed ($before -> $after)"
done

echo "ctx-assumptions tests passed"
