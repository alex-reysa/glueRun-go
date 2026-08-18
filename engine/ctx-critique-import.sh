#!/usr/bin/env bash
# ctx-critique-import.sh — the critique-import gate: the pure, read-only DECISION
# the L0 importer will consult to honor plan-critique verdicts behind the
# SINGULAR_PLAN_CRITIQUE knob (default 1 as of 0.20.0; set 0 to disable).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-plan-critic.sh and engine/ctx-paired-audit.sh). It never owns
# engine/lib.sh and adds no driver-file hook. The reconcile.sh / L0 import
# call-site that CONSUMES this decision — emitting origin.l1_import_rejected with
# reason "plan-critique", handling the node lease as planning-failed, and keeping
# the OFF path byte-identical — is the follow-up slice for this same
# critique-import-gate node and is out of scope here.
#
# The gate reads ONLY the persisted critique record (plan-critique.json, written
# by engine/ctx-plan-critic.sh next to a node's staged candidates) together with
# the SINGULAR_PLAN_CRITIQUE knob, and returns the import disposition. It appends
# NO events, spawns no runner, and mutates nothing — evidence invariance: the
# disposition event and lease handling belong to the follow-up wiring slice. The
# gate is an added enforcement layer over the read-only skeptic critique; it
# never weakens, resumes into, or bypasses the un-bypassable implementation
# auditor, and on the fail-closed ON path it only ever refuses import — it never
# fabricates an approval.
#
# Decision semantics, gated on SINGULAR_PLAN_CRITIQUE (default 1):
#   OFF (unset or "0"): observe-only — the decision is ALWAYS `import`,
#     regardless of the recorded verdict or a missing record, so wiring it OFF
#     leaves the import path byte-identical to today.
#   ON ("=1"): enforce the persisted verdict — `approve` imports; `revise` or
#     `park` reject; a missing, unreadable, or schema-invalid critique record, or
#     a verdict outside approve|revise|park, fails CLOSED to reject.
#
# Public entry points:
#   singular_ctx_critique_import_record_path <stage_dir>
#     Pure: print the canonical critique record path "<stage_dir>/plan-critique.json"
#     (the same path engine/ctx-plan-critic.sh persists to). Empty stage_dir ->
#     empty (caller skips). No side effects.
#   singular_ctx_critique_import_enabled
#     Pure: exit 0 when the gate is ON (SINGULAR_PLAN_CRITIQUE=1), else 1.
#   singular_ctx_critique_import_decide <stage_dir>
#     Pure/read-only: print a single TAB-separated line "<disposition>\t<reason>\t<observed>"
#     and return the disposition as exit status:
#       import -> exit 0, line "import\tok\t<observed>"
#       reject -> exit 1, line "reject\tplan-critique\t<observed>"
#     <reason> is the stable token the follow-up reconcile.sh wiring records as
#     origin.l1_import_rejected reason `plan-critique` without further parsing;
#     the import path carries `ok`, distinct from it. <observed> is the classifier
#     token (off|approve|revise|park|missing|invalid) so the verdict classes stay
#     distinguishable. Reads only the persisted record and the knob.

# Shipped plan-critique schema. The engine ships its OWN schemas, so resolve
# them relative to THIS file (mirroring lib.sh) — never a possibly-stale
# SINGULAR_SCHEMA_DIR pointing at another install. Overridable for vendoring.
if [[ -z "${SINGULAR_PLAN_CRITIQUE_SCHEMA:-}" ]]; then
  SINGULAR_PLAN_CRITIQUE_SCHEMA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/schemas/plan-critique.v0.schema.json"
fi

# The stable reject reason token. Kept as one place so the follow-up reconcile.sh
# wiring and this gate never drift.
singular_ctx_critique_import_reason() { printf '%s' "plan-critique"; }

# Pure path helper: the canonical critique record path next to a node's staged
# candidates. Empty stage_dir -> empty (caller skips). No side effects.
singular_ctx_critique_import_record_path() {
  local stage_dir="$1"
  [[ -n "$stage_dir" ]] || { printf '%s' ""; return 0; }
  printf '%s/plan-critique.json' "$stage_dir"
}

# Pure knob read: exit 0 when enforcement is ON (SINGULAR_PLAN_CRITIQUE=1). Any
# other value (unset, "0", anything else) is observe-only (OFF). No side effects.
singular_ctx_critique_import_enabled() {
  [[ "${SINGULAR_PLAN_CRITIQUE:-0}" == "1" ]]
}

# The critique-import gate DECISION. Pure and read-only: reads only the persisted
# critique record and the knob; appends no events, spawns no runner, writes no
# files. See the header for the output contract.
singular_ctx_critique_import_decide() {
  local stage_dir="$1"
  local record; record="$(singular_ctx_critique_import_record_path "$stage_dir")"
  local reason; reason="$(singular_ctx_critique_import_reason)"

  # OFF (observe-only): ALWAYS import — the recorded verdict is not enforced and
  # a missing record is fine, so the OFF import path is byte-identical to today.
  if ! singular_ctx_critique_import_enabled; then
    printf 'import\tok\toff\n'
    return 0
  fi

  # ON: enforce. Everything below fails CLOSED to reject unless we can read a
  # schema-valid record carrying an `approve` verdict.

  # Missing or unreadable record -> reject.
  if [[ -z "$record" || ! -f "$record" || ! -r "$record" ]]; then
    printf 'reject\t%s\tmissing\n' "$reason"
    return 1
  fi

  # Compact the record; invalid / unparseable JSON -> reject.
  local compact
  compact="$(python3 - "$record" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        obj = json.load(f)
except Exception:
    sys.exit(2)
sys.stdout.write(json.dumps(obj, separators=(",", ":")))
PY
)" || { printf 'reject\t%s\tinvalid\n' "$reason"; return 1; }

  # Schema validation via the shared checker. A record failing
  # singular.orchestration.plan-critique.v0 (including a verdict outside the
  # approve|revise|park enum) -> reject.
  singular_json_schema_check "$compact" "$SINGULAR_PLAN_CRITIQUE_SCHEMA" "plan critique" \
    >/dev/null 2>&1 || { printf 'reject\t%s\tinvalid\n' "$reason"; return 1; }

  # Extract the (schema-valid) verdict and map it to a disposition.
  local verdict
  verdict="$(python3 - "$record" <<'PY' 2>/dev/null
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
sys.stdout.write(str(obj.get("verdict", "")))
PY
)"

  case "$verdict" in
    approve) printf 'import\tok\tapprove\n';           return 0 ;;
    revise)  printf 'reject\t%s\trevise\n' "$reason";  return 1 ;;
    park)    printf 'reject\t%s\tpark\n'   "$reason";  return 1 ;;
    # Defensive fail-closed: a verdict outside the enum is already caught by the
    # schema check above; this arm never fabricates an approval.
    *)       printf 'reject\t%s\tinvalid\n' "$reason"; return 1 ;;
  esac
}
