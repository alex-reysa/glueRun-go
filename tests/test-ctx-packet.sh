#!/usr/bin/env bash
# Covers the OPTIONAL, additive context-packet contract (stage S4-context-packets,
# node context-packet-contract). `engine/ctx-packet.sh` ships a PURE, present-but-
# uncalled helper `singular_ctx_packet_json <task-file>` that reads a task markdown
# READ-ONLY and prints normalized JSON:
#   - a well-formed `## Context packet` block  -> stable sorted-key object
#   - no `## Context packet` block             -> exactly `{}`
#   - a block with a malformed assumption entry-> fail closed to `{}` + exactly one
#                                                 `ctx.packet_malformed` warning event
# The parser's only side effect is that one warning event (in SINGULAR_EVENTS_FILE);
# it never mutates the task file or any other repo file.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
TEMPLATE="$ENGINE_HOME/docs/orchestration/tasks/TEMPLATE.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Parse a task file through the real engine helper in an isolated subshell so
# lib.sh's `set -e` and the sourced ctx-*.sh files never contaminate this test
# process. SINGULAR_ROOT is a scratch dir so any state (the malformed warning
# event) lands under $tmp, never in the repo. $2 optionally overrides the events
# file so the malformed case can be inspected in isolation.
parse() {
  local tf="$1" ev="${2:-$tmp/events.ndjson}"
  SINGULAR_ROOT="$tmp" bash -c '
    source "'"$LIB"'"
    SINGULAR_EVENTS_FILE="'"$ev"'"
    singular_ctx_packet_json "'"$tf"'"
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

# --- Fixtures ---------------------------------------------------------------

# Full: all four subsections present and well-formed.
full="$tmp/full.md"
cat > "$full" <<'EOF'
# TASK-9001: full packet

## Objective

Exercise the full context-packet block.

## Context packet

### Decisions

- Use a tolerant parser so old tasks keep validating
- Emit sorted-key JSON for stable diffs

### Assumptions

- [open] runtime is node 20 — package.json engines field
- [validated] db schema already migrated — verified in db.ts

### Rejected alternatives

- A strict schema that rejects old tasks — breaks every TEMPLATE task
- A SINGULAR flag — belongs to the downstream ledger node

### Inspected symbols

- singular_append_event — appends the malformed warning
- ctx loader block — auto-sources this file

## Acceptance Criteria

- Parses.
EOF

# Partial: only Decisions and Assumptions present.
partial="$tmp/partial.md"
cat > "$partial" <<'EOF'
# TASK-9002: partial packet

## Context packet

### Decisions

- Keep the slice tight

### Assumptions

- [violated] the cache is warm — cold-start trace shows a miss
EOF

# Malformed: an assumption entry that does not match the grammar.
malformed="$tmp/malformed.md"
cat > "$malformed" <<'EOF'
# TASK-9003: malformed packet

## Context packet

### Decisions

- This decision is fine

### Assumptions

- this line has no [status] bracket and no em-dash basis
EOF

# Absent: a copy of the real TEMPLATE (no `## Context packet` block).
absent="$tmp/absent.md"
cp "$TEMPLATE" "$absent"

# --- Case 1: full packet -> normalized sorted-key object --------------------
out_full="$(parse "$full")" || fail "full: parse exited non-zero"
expected_full='{
  "schema": "singular.orchestration.ctx-packet.v0",
  "decisions": [
    "Use a tolerant parser so old tasks keep validating",
    "Emit sorted-key JSON for stable diffs"
  ],
  "assumptions": [
    {"status": "open", "claim": "runtime is node 20", "basis": "package.json engines field"},
    {"status": "validated", "claim": "db schema already migrated", "basis": "verified in db.ts"}
  ],
  "rejectedAlternatives": [
    "A strict schema that rejects old tasks — breaks every TEMPLATE task",
    "A SINGULAR flag — belongs to the downstream ledger node"
  ],
  "inspectedSymbols": [
    "singular_append_event — appends the malformed warning",
    "ctx loader block — auto-sources this file"
  ]
}'
json_eq "$out_full" "$expected_full" || fail "full: normalized object mismatch; got [$out_full]"
assert_contains "$out_full" '"singular.orchestration.ctx-packet.v0"' "full: schema const present"

# Deterministic: byte-identical stdout across repeated runs on identical input.
out_full2="$(parse "$full")" || fail "full(2): parse exited non-zero"
[[ "$out_full" == "$out_full2" ]] || fail "full: output not deterministic across runs"

# --- Case 2: absent block (TEMPLATE-based task) -> exactly {} ----------------
out_absent="$(parse "$absent")" || fail "absent: parse exited non-zero"
[[ "$out_absent" == "{}" ]] || fail "absent: expected exactly {} got [$out_absent]"

# --- Case 3: partial packet -> only present subsections populated ------------
out_partial="$(parse "$partial")" || fail "partial: parse exited non-zero"
expected_partial='{
  "schema": "singular.orchestration.ctx-packet.v0",
  "decisions": ["Keep the slice tight"],
  "assumptions": [
    {"status": "violated", "claim": "the cache is warm", "basis": "cold-start trace shows a miss"}
  ],
  "rejectedAlternatives": [],
  "inspectedSymbols": []
}'
json_eq "$out_partial" "$expected_partial" || fail "partial: mismatch; got [$out_partial]"

# --- Case 4: malformed -> fail closed to {} + exactly one warning event ------
ev="$tmp/malformed-events.ndjson"
: > "$ev"
out_bad="$(parse "$malformed" "$ev")" || fail "malformed: wrapper must exit 0 (fail closed), not error"
[[ "$out_bad" == "{}" ]] || fail "malformed: expected exactly {} on stdout got [$out_bad]"
n="$(grep -c 'ctx.packet_malformed' "$ev" 2>/dev/null || echo 0)"
[[ "$n" -eq 1 ]] || fail "malformed: expected exactly one ctx.packet_malformed event, got $n"
total="$(wc -l < "$ev" | tr -d ' ')"
[[ "$total" -eq 1 ]] || fail "malformed: expected exactly one event line total, got $total"

# --- Case 5: read-only -> task file byte-identical before/after each parse ---
for f in "$full" "$partial" "$malformed" "$absent"; do
  before="$(hash_of "$f")"
  parse "$f" "$tmp/ro-events.ndjson" >/dev/null 2>&1 || true
  after="$(hash_of "$f")"
  [[ "$before" == "$after" ]] || fail "read-only: $f mutated by parse ($before -> $after)"
done

# --- Case 6: planner-prompt request present in BOTH prompt files -------------
for pf in "$ENGINE_HOME/templates/prompts/l1-planner.md" \
          "$ENGINE_HOME/docs/orchestration/prompts/l1-planner.md"; do
  grep -q 'Context packet' "$pf" || fail "prompt: $pf missing 'Context packet' request"
  grep -q '\[open|validated|violated\] <claim> — <basis>' "$pf" \
    || fail "prompt: $pf missing the assumption grammar"
  grep -q 'never restate what the repo can answer' "$pf" \
    || fail "prompt: $pf missing the 'never restate what the repo can answer' rule"
done

echo "ctx-packet tests passed"
