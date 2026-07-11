#!/usr/bin/env bash
# Covers the pure attempt-open assembler of the per-run assumption ledger
# (stage S4-context-packets, node assumption-ledger). `engine/ctx-assumptions-assemble.sh`
# ships a PURE, present-but-uncalled helper
#   gluerun_ctx_assumptions_assemble <task-file> <prior-ledger-json>
# that ties the already-integrated seed, carry, and fix/audit render helpers into one
# attempt-OPEN call: it computes the current attempt's input ledger as
# carry(prior, seed(task-file)) and renders both prompt sections from it, printing a
# single envelope JSON on stdout whose `schema` const is
# `gluerun.orchestration.ctx-assumptions-run.v0` and which carries `ledger`,
# `fixSection`, and `auditSection`.
#
#   - LEDGER = carry(prior, seed(task-file)): a first attempt (empty/absent/`{}` prior)
#     yields the seed ledger; a retry whose prior holds a `violated` assumption keeps
#     that id `violated` in the envelope ledger (sticky carry).
#   - SECTIONS = the render helpers applied to the envelope ledger: `fixSection` equals
#     gluerun_ctx_assumptions_fix_section(ledger) and `auditSection` equals
#     gluerun_ctx_assumptions_audit_section(ledger); a zero-assumption task yields empty
#     `fixSection` and `auditSection`.
#   - ATTEMPT-OPEN ONLY: the assembler composes seed + carry + render but NOT the
#     host-derived transition (applied at attempt-close by the later driver hook).
#   - Read-only + deterministic: the task file is byte-identical before/after; identical
#     inputs yield byte-identical output; the only possible side effect is the parser's
#     single `ctx.packet_malformed` warning, inherited via the seed and never re-emitted.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
TEMPLATE="$ENGINE_HOME/docs/orchestration/tasks/TEMPLATE.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Invoke the real engine helper in an isolated subshell so lib.sh's `set -e` and the
# sourced ctx-*.sh files never contaminate this test process. GLUERUN_ROOT is a scratch
# dir; $3 optionally overrides the events file so the malformed case can be inspected.
assemble() {
  local tf="$1" prior="$2" ev="${3:-$tmp/events.ndjson}"
  GLUERUN_ROOT="$tmp" bash -c '
    source "'"$LIB"'"
    GLUERUN_EVENTS_FILE="'"$ev"'"
    gluerun_ctx_assumptions_assemble "$1" "$2"
  ' _ "$tf" "$prior"
}

# The reference seed/carry/render helpers, invoked directly, so the test can assert the
# envelope fields equal exactly what the composed bricks produce.
seed() {
  local tf="$1"
  GLUERUN_ROOT="$tmp" bash -c '
    source "'"$LIB"'"
    GLUERUN_EVENTS_FILE="'"$tmp"'/ref-events.ndjson"
    gluerun_ctx_assumptions_seed "$1"
  ' _ "$tf"
}
carry() {
  local prior="$1" s="$2"
  GLUERUN_ROOT="$tmp" bash -c '
    source "'"$LIB"'"
    gluerun_ctx_assumptions_carry "$1" "$2"
  ' _ "$prior" "$s"
}
fix_section() {
  local ledger="$1"
  GLUERUN_ROOT="$tmp" bash -c '
    source "'"$LIB"'"
    gluerun_ctx_assumptions_fix_section "$1"
  ' _ "$ledger"
}
audit_section() {
  local ledger="$1"
  GLUERUN_ROOT="$tmp" bash -c '
    source "'"$LIB"'"
    gluerun_ctx_assumptions_audit_section "$1"
  ' _ "$ledger"
}

json_eq() { # $1 = actual json, $2 = expected json
  python3 - "$1" "$2" <<'PY'
import json, sys
sys.exit(0 if json.loads(sys.argv[1]) == json.loads(sys.argv[2]) else 1)
PY
}

# $1 = envelope json, $2 = field name -> prints the field value (JSON-decoded string,
# or re-serialized object) so the test can compare against the reference helpers.
field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
v = obj[sys.argv[2]]
if isinstance(v, str):
    sys.stdout.write(v)
else:
    sys.stdout.write(json.dumps(v, sort_keys=True, ensure_ascii=False))
PY
}

hash_of() { python3 - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
}

# --- Fixtures ---------------------------------------------------------------

# Full: three assumptions in declared order, all three status values.
full="$tmp/full.md"
cat > "$full" <<'EOF'
# TASK-9201: full assumptions

## Context packet

### Decisions

- Keep the assembler pure and read-only

### Assumptions

- [open] runtime is node 20 — package.json engines field
- [validated] db schema already migrated — verified in db.ts
- [open] the cache is warm — cold-start trace

### Inspected symbols

- gluerun_ctx_assumptions_seed — the composed seed
EOF

# Packet present but zero assumptions.
noassump="$tmp/noassump.md"
cat > "$noassump" <<'EOF'
# TASK-9202: packet without assumptions

## Context packet

### Decisions

- Keep the slice tight
EOF

# Malformed: an assumption entry that does not match the grammar.
malformed="$tmp/malformed.md"
cat > "$malformed" <<'EOF'
# TASK-9203: malformed packet

## Context packet

### Assumptions

- this line has no [status] bracket and no em-dash basis
EOF

# Absent: a copy of the real TEMPLATE (no `## Context packet` block).
absent="$tmp/absent.md"
cp "$TEMPLATE" "$absent"

EMPTY_LEDGER='{"schema":"gluerun.orchestration.ctx-assumptions.v0","assumptions":[]}'

# --- Case 1: first attempt (empty prior) -> ledger == seed, schema const -----
env1="$(assemble "$full" '')" || fail "case1: assemble exited non-zero"
assert_contains "$env1" '"gluerun.orchestration.ctx-assumptions-run.v0"' "case1: envelope schema const present"
seed_full="$(seed "$full")" || fail "case1: seed exited non-zero"
led1="$(field "$env1" ledger)"
json_eq "$led1" "$seed_full" || fail "case1: envelope ledger != seed on first attempt; got [$led1]"
# Envelope carries all three fields.
python3 - "$env1" <<'PY' || fail "case1: envelope missing a required field"
import json, sys
o = json.loads(sys.argv[1])
need = {"schema", "ledger", "fixSection", "auditSection"}
sys.exit(0 if need <= set(o) else 1)
PY

# --- Case 2: sections == render helpers applied to the envelope ledger -------
fix_ref="$(fix_section "$led1")"
aud_ref="$(audit_section "$led1")"
[[ "$(field "$env1" fixSection)" == "$fix_ref" ]] || fail "case2: fixSection != fix_section(ledger)"
[[ "$(field "$env1" auditSection)" == "$aud_ref" ]] || fail "case2: auditSection != audit_section(ledger)"
# Sanity: a populated ledger renders non-empty sections mentioning an id.
assert_contains "$(field "$env1" fixSection)" "A1" "case2: fixSection lists ids"
assert_contains "$(field "$env1" auditSection)" "A1" "case2: auditSection lists ids"

# --- Case 3: retry with a sticky `violated` prior carries forward ------------
# The prior attempt observed A2 violated (host-derived). Seed re-seeds A2 `validated`,
# but the envelope ledger must keep A2 `violated` (sticky carry), and the fix section
# must foreground it as an open finding.
PRIOR_A2_VIOLATED='{"schema":"gluerun.orchestration.ctx-assumptions.v0","assumptions":[
  {"id":"A1","status":"open","claim":"runtime is node 20","basis":"package.json engines field"},
  {"id":"A2","status":"violated","claim":"db schema already migrated","basis":"verified in db.ts"},
  {"id":"A3","status":"open","claim":"the cache is warm","basis":"cold-start trace"}
]}'
env3="$(assemble "$full" "$PRIOR_A2_VIOLATED")" || fail "case3: assemble exited non-zero"
led3="$(field "$env3" ledger)"
carry_ref="$(carry "$PRIOR_A2_VIOLATED" "$seed_full")"
json_eq "$led3" "$carry_ref" || fail "case3: envelope ledger != carry(prior,seed); got [$led3]"
python3 - "$led3" <<'PY' || fail "case3: A2 not sticky-violated in envelope ledger"
import json, sys
o = json.loads(sys.argv[1])
by = {a["id"]: a["status"] for a in o["assumptions"]}
sys.exit(0 if by.get("A2") == "violated" else 1)
PY
assert_contains "$(field "$env3" fixSection)" "db schema already migrated" "case3: violated claim surfaced in fix section"

# --- Case 4: zero-assumption task -> empty sections, empty ledger ------------
for f in "$noassump" "$absent"; do
  env4="$(assemble "$f" '')" || fail "case4: assemble exited non-zero for $f"
  json_eq "$(field "$env4" ledger)" "$EMPTY_LEDGER" || fail "case4: $f expected empty ledger"
  [[ -z "$(field "$env4" fixSection)" ]] || fail "case4: $f expected empty fixSection"
  [[ -z "$(field "$env4" auditSection)" ]] || fail "case4: $f expected empty auditSection"
done

# --- Case 5: deterministic -> byte-identical output across runs --------------
env1b="$(assemble "$full" '')" || fail "case5: assemble exited non-zero"
[[ "$env1" == "$env1b" ]] || fail "case5: output not deterministic; [$env1] != [$env1b]"

# --- Case 6: read-only -> task file byte-identical before/after each run -----
for f in "$full" "$noassump" "$malformed" "$absent"; do
  before="$(hash_of "$f")"
  assemble "$f" '' "$tmp/ro-events.ndjson" >/dev/null 2>&1 || true
  after="$(hash_of "$f")"
  [[ "$before" == "$after" ]] || fail "read-only: $f mutated by assemble ($before -> $after)"
done

# --- Case 7: malformed packet -> empty ledger, exactly one PARSER warning ----
# The single ctx.packet_malformed warning is the parser's (inherited via the seed) and
# is never re-emitted by the assembler.
ev="$tmp/malformed-events.ndjson"
: > "$ev"
env7="$(assemble "$malformed" '' "$ev")" || fail "case7: assemble must fail closed (exit 0)"
json_eq "$(field "$env7" ledger)" "$EMPTY_LEDGER" || fail "case7: expected empty ledger on malformed packet"
n="$(grep -c 'ctx.packet_malformed' "$ev" 2>/dev/null || echo 0)"
[[ "$n" -eq 1 ]] || fail "case7: expected exactly one ctx.packet_malformed event (parser's), got $n"
total="$(wc -l < "$ev" | tr -d ' ')"
[[ "$total" -eq 1 ]] || fail "case7: assembler re-emitted events; expected 1 line total, got $total"

# --- Case 8: pure -> writes nothing to the filesystem (well-formed input) ----
pure="$tmp/pure"
mkdir -p "$pure"
GLUERUN_ROOT="$pure" bash -c '
  source "'"$LIB"'"
  GLUERUN_EVENTS_FILE="'"$pure"'/events.ndjson"
  gluerun_ctx_assumptions_assemble "$1" "$2"
' _ "$full" '' >/dev/null 2>&1 || fail "case8: assemble exited non-zero"
nf="$(find "$pure" -type f | wc -l | tr -d ' ')"
[[ "$nf" -eq 0 ]] || fail "case8: assemble wrote $nf file(s) on well-formed input; must be a pure transform"

echo "ctx-assumptions-assemble tests passed"
