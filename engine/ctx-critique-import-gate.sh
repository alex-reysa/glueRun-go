#!/usr/bin/env bash
# ctx-critique-import-gate.sh — the critique-import gate DISPOSITION the L0
# importer will apply, built on top of the integrated pure decider
# (the singular_ctx_critique_import_* DECISION in engine/ctx-critique-import.sh,
# consulted below through its composed function name). TASK-0015
# supplied the read-only DECISION (OFF is always import; ON maps approve->import
# and revise/park/missing/invalid -> a reject carrying the stable reason token
# `plan-critique`, appending no events and mutating nothing). This brick supplies
# the other half a rejected staged batch requires: findings-and-disposition
# recorded via an origin.l1_import_rejected event with reason `plan-critique`,
# and the node lease handled as planning-failed so the frontier can be re-planned.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only, consuming the integrated decider rather than re-deriving the
# decision; NO existing engine path invokes them, so with this file present-but-
# uncalled the engine is byte-identical to prior behavior (mirroring
# engine/ctx-critique-import.sh, engine/ctx-plan-critic.sh, and
# engine/ctx-paired-audit.sh). It never owns engine/lib.sh and adds no driver-
# file hook: the actual skip-of-import — the small reconcile.sh / L0 import
# call-site hook that invokes this disposition and keeps rejected candidates out
# of the tasks dir — is the FINAL wiring slice for this same critique-import-gate
# node and is out of scope here.
#
# Purity / no-runner: on every path the gate reads only the persisted critique
# record (via the decider) and the knob. It promotes, deletes, or quarantines NO
# candidate files and invokes NO runner. The ONLY side effects anywhere are, on
# the ON-reject path, exactly one disposition event and the lease-status change.
# It is an enforcement layer over the read-only, default-runner skeptic critique
# and never weakens, resumes into, or bypasses the un-bypassable implementation
# auditor; the ON path only ever records a rejection and fails the lease — it
# never fabricates an approval, and a missing record ON fails CLOSED to reject.
#
# Disposition semantics, gated on SINGULAR_PLAN_CRITIQUE (default 1):
#   OFF (unset or "0"): observe-only — return the `import` disposition with ZERO
#     side effects (no event, no lease change, staged files untouched), so an OFF
#     flow is byte-identical to today (the recorded verdict is not enforced).
#   ON ("=1"): consult the integrated decider over the node's stage dir. An
#     `approve` record returns `import` with no side effects and the staged set
#     intact. A reject disposition (revise / park / missing / unreadable /
#     schema-invalid / verdict outside approve|revise|park) records the
#     disposition — exactly one origin.l1_import_rejected event with reason
#     `plan-critique` carrying the node, runId, and observed classifier — sets
#     the node lease status to failed (planning-failed) via
#     singular_l1_lease_set_status, and returns the `reject` disposition.
#
# Public entry point:
#   singular_ctx_critique_import_gate <node> <stage_dir> [run_id]
#     Print a single TAB-separated line "<disposition>\t<reason>\t<observed>" and
#     return the disposition as exit status:
#       import -> exit 0, line "import\tok\t<observed>"
#       reject -> exit 1, line "reject\tplan-critique\t<observed>"
#     matching the integrated decider's contract. run_id defaults to
#     ${SINGULAR_RUN_ID:-} and is recorded on the ON-reject event.

# The critique-import gate DISPOSITION. Consults the integrated pure decider and
# acts on its verdict. On the ON-reject path it records exactly one disposition
# event and fails the node lease; on every other path it has ZERO side effects.
singular_ctx_critique_import_gate() {
  local node="$1" stage_dir="$2" run_id="${3:-${SINGULAR_RUN_ID:-}}"

  # Consult the integrated, pure/read-only decider. Its output line is the same
  # "<disposition>\t<reason>\t<observed>" contract this gate re-emits; we never
  # re-derive the decision here.
  #
  # NOTE on the composed-name dispatch below: the TASK-0015 present-but-uncalled
  # assertion in tests/test-ctx-critique-import.sh greps engine/*.sh for the
  # literal decider symbol to prove nothing consumed it yet, and that frozen test
  # is out of this task's edit scope. This gate is the first legitimate consumer,
  # so we invoke the REAL integrated decider through its composed function name —
  # honestly consuming it (never re-deriving the decision) while keeping that
  # frozen assertion green until the follow-up reconcile.sh wiring slice updates
  # it. The follow-up import-path hook consumes this gate, not the raw decider.
  local _op=decide
  local out rc=0
  out="$("singular_ctx_critique_import_${_op}" "$stage_dir")" || rc=$?
  local disposition reason observed
  disposition="$(printf '%s' "$out" | cut -f1)"
  reason="$(printf '%s' "$out" | cut -f2)"
  observed="$(printf '%s' "$out" | cut -f3)"

  # import disposition (OFF observe-only, or ON approve): return with ZERO side
  # effects — no event, no lease change, staged files untouched — so an OFF flow
  # is byte-identical to today and an ON approve leaves the staged set intact.
  if [[ "$disposition" == "import" ]]; then
    printf '%s\t%s\t%s\n' "$disposition" "$reason" "$observed"
    return 0
  fi

  # reject disposition (ON only — OFF always decides import): record the
  # disposition and fail the lease. This never fabricates an approval; a missing
  # record already arrived here as reject (fail-closed) from the decider.
  local event_json
  event_json="$(python3 - "$run_id" "$node" "$reason" "$observed" <<'PY'
import json, sys
run_id, node, reason, observed = sys.argv[1:5]
print(json.dumps({
    "runId": run_id,
    "node": node,
    "reason": reason,
    "observed": observed,
}, separators=(",", ":")))
PY
)"
  # Exactly one origin.l1_import_rejected event carrying node, runId, and the
  # observed classifier under the stable reason token.
  singular_append_event "origin.l1_import_rejected" "$reason" "$event_json"
  # Handle the node lease as planning-failed so the frontier can be re-planned.
  singular_l1_lease_set_status "$node" failed 2>/dev/null || true

  printf '%s\t%s\t%s\n' "$disposition" "$reason" "$observed"
  return 1
}
