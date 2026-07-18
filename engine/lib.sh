#!/usr/bin/env bash
set -euo pipefail

gluerun_repo_root() {
  git rev-parse --show-toplevel
}

# Engine install location. The engine ships its OWN schemas (and other engine
# assets); resolve them relative to THIS file, not the consumer repo, so a repo
# that holds only config still validates. GLUERUN_ROOT remains the *consumer* repo.
# Override GLUERUN_ENGINE_HOME / GLUERUN_SCHEMA_DIR when vendoring or testing.
GLUERUN_ENGINE_DIR="${GLUERUN_ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
GLUERUN_ENGINE_HOME="${GLUERUN_ENGINE_HOME:-$(cd "$GLUERUN_ENGINE_DIR/.." && pwd)}"
GLUERUN_SCHEMA_DIR="${GLUERUN_SCHEMA_DIR:-$GLUERUN_ENGINE_HOME/schemas}"

GLUERUN_ROOT="${GLUERUN_ROOT:-$(gluerun_repo_root)}"
GLUERUN_ORCH_DIR="${GLUERUN_ORCH_DIR:-$GLUERUN_ROOT/docs/orchestration}"
GLUERUN_STATE_DIR="${GLUERUN_STATE_DIR:-$GLUERUN_ROOT/.gluerun-state}"

# ---- Consumer configuration --------------------------------------------------
# All per-repo variation lives in the CONSUMER repo, never in engine files. The
# engine loads, in increasing precedence (each can override the previous),
# BEFORE the ${VAR:-default} block below so a repo's settings win:
#   gluerun.config.json          declarative: targetBranch, gateCommand, runner,
#                             areas{}, proofLayers[], identity{}, prewarm, env{}
#   gluerun.config.sh            optional shell extras (computed values / functions)
#   .gluerun-state/config.local.sh  gitignored operator overrides + secrets
# Never edit engine/ to customize a repo — put it in these files.

# Translate the declarative JSON config into GLUERUN_* env exports.
gluerun_json_config_to_env() {
  python3 - "$1" <<'PY'
import json, sys, shlex, re
cfg = json.load(open(sys.argv[1]))
out = []
_VAR = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')
def setv(var, val):
    if val is None: return
    if not _VAR.match(var):
        sys.stderr.write("gluerun: ignoring invalid config env key: %r\n" % var)
        return
    out.append("export %s=%s" % (var, shlex.quote(str(val))))
setv("GLUERUN_TARGET_BRANCH", cfg.get("targetBranch"))
setv("GLUERUN_DEFAULT_GATE_CMD", cfg.get("gateCommand"))
setv("GLUERUN_RUNNER", cfg.get("runner"))
setv("GLUERUN_AREA_PREFIX", cfg.get("areaPrefix"))
setv("GLUERUN_PREWARM_CMD", cfg.get("prewarm"))
areas = cfg.get("areas")
if isinstance(areas, dict):
    lines = []
    for k, v in areas.items():
        if isinstance(v, list): v = ":".join(v)
        lines.append("%s=%s" % (k, v))
    setv("GLUERUN_AREA_PATHS", "\n".join(lines))
pl = cfg.get("proofLayers")
if isinstance(pl, list): setv("GLUERUN_PROOF_LAYERS", ",".join(pl))
pg = cfg.get("proofGrandfather")
if isinstance(pg, list): setv("GLUERUN_PROOF_GRANDFATHER", ",".join(pg))
mods = cfg.get("modules")
if isinstance(mods, list): setv("GLUERUN_MODULES", " ".join(mods))
ssl = cfg.get("singleSliceLayers")
if isinstance(ssl, list): setv("GLUERUN_SINGLE_SLICE_LAYERS", ",".join(ssl))
pf = cfg.get("provisionFiles")
if isinstance(pf, list): setv("GLUERUN_PROVISION_FILES_JSON", json.dumps(pf, separators=(",", ":")))
ea = cfg.get("envAllowlist")
if isinstance(ea, list): setv("GLUERUN_ENV_ALLOWLIST_JSON", json.dumps(ea, separators=(",", ":")))
setv("GLUERUN_PROMOTER", cfg.get("promoter"))
ident = cfg.get("identity") or {}
l0 = ident.get("l0") or {}; l1 = ident.get("l1") or {}
setv("GLUERUN_GIT_L0_NAME", l0.get("name")); setv("GLUERUN_GIT_L0_EMAIL", l0.get("email"))
setv("GLUERUN_GIT_L1_NAME", l1.get("name")); setv("GLUERUN_GIT_L1_EMAIL", l1.get("email"))
for k, v in (cfg.get("env") or {}).items():
    setv(k, v)
print("\n".join(out))
PY
}

GLUERUN_JSON_CONFIG_FILE="${GLUERUN_JSON_CONFIG_FILE:-$GLUERUN_ROOT/gluerun.config.json}"
if [[ -f "$GLUERUN_JSON_CONFIG_FILE" ]]; then
  _gluerun_cfg_env="$(gluerun_json_config_to_env "$GLUERUN_JSON_CONFIG_FILE")" \
    || { echo "gluerun: failed to parse $GLUERUN_JSON_CONFIG_FILE" >&2; exit 2; }
  eval "$_gluerun_cfg_env"
  unset _gluerun_cfg_env
fi
GLUERUN_CONFIG_FILE="${GLUERUN_CONFIG_FILE:-$GLUERUN_ROOT/gluerun.config.sh}"
if [[ -f "$GLUERUN_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$GLUERUN_CONFIG_FILE"
fi
GLUERUN_LOCAL_CONFIG_FILE="${GLUERUN_LOCAL_CONFIG_FILE:-$GLUERUN_STATE_DIR/config.local.sh}"
if [[ -f "$GLUERUN_LOCAL_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$GLUERUN_LOCAL_CONFIG_FILE"
fi
# ------------------------------------------------------------------------------

GLUERUN_LOCK_FILE="$GLUERUN_STATE_DIR/locks/origin.lock.json"
GLUERUN_EVENTS_FILE="$GLUERUN_STATE_DIR/events.ndjson"
GLUERUN_TASKS_DIR="${GLUERUN_TASKS_DIR:-$GLUERUN_ORCH_DIR/tasks}"
GLUERUN_LEASES_DIR="${GLUERUN_LEASES_DIR:-$GLUERUN_STATE_DIR/leases}"
GLUERUN_INBOX_DIR="${GLUERUN_INBOX_DIR:-$GLUERUN_STATE_DIR/inbox}"
GLUERUN_RUNS_DIR="${GLUERUN_RUNS_DIR:-$GLUERUN_STATE_DIR/runs}"
GLUERUN_WORKTREES_DIR="${GLUERUN_WORKTREES_DIR:-$GLUERUN_ROOT/.worktrees}"
GLUERUN_ORIGIN_STATE_FILE="${GLUERUN_ORIGIN_STATE_FILE:-$GLUERUN_STATE_DIR/origin-state.json}"
GLUERUN_GIT_LOCK_DIR="${GLUERUN_GIT_LOCK_DIR:-$GLUERUN_STATE_DIR/locks/git-op.lock}"
GLUERUN_PACKET_SCHEMA="${GLUERUN_PACKET_SCHEMA:-$GLUERUN_SCHEMA_DIR/state-packet.v0.schema.json}"
GLUERUN_AUDIT_SCHEMA="${GLUERUN_AUDIT_SCHEMA:-$GLUERUN_SCHEMA_DIR/audit-verdict.v0.schema.json}"
GLUERUN_DECIDER_SCHEMA="${GLUERUN_DECIDER_SCHEMA:-$GLUERUN_SCHEMA_DIR/decider-verdict.v0.schema.json}"
GLUERUN_GATE_SCHEMA="${GLUERUN_GATE_SCHEMA:-$GLUERUN_SCHEMA_DIR/gate-result.v0.schema.json}"
GLUERUN_TASKBATCH_SCHEMA="${GLUERUN_TASKBATCH_SCHEMA:-$GLUERUN_SCHEMA_DIR/task-batch.v0.schema.json}"
GLUERUN_SUPERVISOR_SCHEMA="${GLUERUN_SUPERVISOR_SCHEMA:-$GLUERUN_SCHEMA_DIR/supervisor-report.v0.schema.json}"
# Post-worker + integrate validation. No universal default — a repo MUST set its
# gate command (per task `Gate command:` or via config). Empty = no implicit gate.
GLUERUN_DEFAULT_GATE_CMD="${GLUERUN_DEFAULT_GATE_CMD:-}"
# Worker source-tree convention: area -> write-scope path. GLUERUN_AREA_PATHS is a
# newline list of "area=path1[:path2]" entries (set in gluerun.config.sh); unmapped
# areas fall back to GLUERUN_AREA_PREFIX + area.
GLUERUN_AREA_PREFIX="${GLUERUN_AREA_PREFIX:-internal/}"
GLUERUN_AREA_PATHS="${GLUERUN_AREA_PATHS:-}"
# Optional pre-worker prewarm (e.g. dependency fetch). Empty = none.
GLUERUN_PREWARM_CMD="${GLUERUN_PREWARM_CMD:-}"
# Bot git identity for L0/L1 control-state commits (override per project).
GLUERUN_GIT_L0_NAME="${GLUERUN_GIT_L0_NAME:-gluerun L0}"
GLUERUN_GIT_L0_EMAIL="${GLUERUN_GIT_L0_EMAIL:-l0@gluerun.local}"
GLUERUN_GIT_L1_NAME="${GLUERUN_GIT_L1_NAME:-gluerun L1}"
GLUERUN_GIT_L1_EMAIL="${GLUERUN_GIT_L1_EMAIL:-l1@gluerun.local}"
# A runner given as a bare filename (e.g. "claude-run.sh") resolves against the
# engine dir; an absolute/relative path is used as-is.
if [[ -n "${GLUERUN_RUNNER:-}" && "$GLUERUN_RUNNER" != */* ]]; then
  GLUERUN_RUNNER="$GLUERUN_ENGINE_DIR/$GLUERUN_RUNNER"
fi
# A gate promoter given as a bare name resolves to a gluerun-ext module
# (<engine>/gluerun-ext/<name>.sh); an absolute/relative path is used as-is.
if [[ -n "${GLUERUN_PROMOTER:-}" && "$GLUERUN_PROMOTER" != */* ]]; then
  GLUERUN_PROMOTER="$GLUERUN_ENGINE_HOME/gluerun-ext/$GLUERUN_PROMOTER.sh"
fi

# Autonomy controls.
GLUERUN_MAX_RETRIES="${GLUERUN_MAX_RETRIES:-3}"            # per-task worker retries before the decider escalates
GLUERUN_AUTO_INTEGRATE="${GLUERUN_AUTO_INTEGRATE:-1}"      # direct reconcile/auto/launchd all integrate accepted work by default
# Decider fast-path (T-F1): when 1 (default), gluerun_decider_fast_action resolves
# clear-cut failure classes by policy without paying a model decider round-trip;
# set 0 to force every failure through decide.sh (the historical behavior).
GLUERUN_DECIDER_FAST="${GLUERUN_DECIDER_FAST:-1}"
# Infra-failure isolation (T-E6): bounded re-runs of ONLY the failed role when a
# runner times out / refuses / yields no parseable output (broken infrastructure,
# not a real worker/audit failure). These NEVER reach the main retry loop or bump
# the lease retryCount; on exhaustion they surface as worker-infra / audit-infra.
GLUERUN_WORKER_INFRA_MAX="${GLUERUN_WORKER_INFRA_MAX:-1}"  # extra worker re-runs on an infra failure
GLUERUN_AUDIT_INFRA_MAX="${GLUERUN_AUDIT_INFRA_MAX:-2}"    # extra auditor re-runs on an infra failure
# Context-continuity fix/re-audit prompts (T-E3/T-E4). STRUCTURED=1 renders a
# structured fix prompt on retries (authoritative findings + scoped evidence);
# =0 reproduces the legacy fix_hints tail byte-for-byte. SECTION_MAX_CHARS caps
# each appended section so a runaway ledger/log can't blow the prompt budget.
GLUERUN_FIX_PROMPT_STRUCTURED="${GLUERUN_FIX_PROMPT_STRUCTURED:-1}"
GLUERUN_CONTEXT_SECTION_MAX_CHARS="${GLUERUN_CONTEXT_SECTION_MAX_CHARS:-4000}"
GLUERUN_PREFLIGHT_REQUIRE_ACCEPTANCE="${GLUERUN_PREFLIGHT_REQUIRE_ACCEPTANCE:-1}"  # task preflight: require non-empty acceptanceCriteria
GLUERUN_MAX_HOURS="${GLUERUN_MAX_HOURS:-20}"              # autonomate.sh wall-clock budget
GLUERUN_MAX_CONSEC_FAILS="${GLUERUN_MAX_CONSEC_FAILS:-5}" # circuit breaker threshold
GLUERUN_STOP_FILE="${GLUERUN_STOP_FILE:-$GLUERUN_STATE_DIR/STOP}"
GLUERUN_STATUS_FILE="${GLUERUN_STATUS_FILE:-$GLUERUN_STATE_DIR/STATUS.md}"
GLUERUN_BREAKER_FILE="${GLUERUN_BREAKER_FILE:-$GLUERUN_STATE_DIR/circuit.json}"
GLUERUN_PLANNER_BACKOFF_FILE="${GLUERUN_PLANNER_BACKOFF_FILE:-$GLUERUN_STATE_DIR/planner-backoff.json}"
# Supervisor briefing + ask (0.10.0). All INERT by default: the autonomate loop
# only spawns a periodic briefing when the interval knob is >0, and `gluerun ask`
# / `gluerun report` are explicit operator verbs. With INTERVAL_MIN=0 (default) a
# reconcile cycle creates ZERO supervisor artifacts (byte-identical to 0.9.0).
GLUERUN_SUPERVISOR_INTERVAL_MIN="${GLUERUN_SUPERVISOR_INTERVAL_MIN:-0}"    # minutes between auto briefings; 0 = off
GLUERUN_SUPERVISOR_TIMEOUT_SEC="${GLUERUN_SUPERVISOR_TIMEOUT_SEC:-900}"    # readonly briefing runner wall budget
GLUERUN_ASK_TIMEOUT_SEC="${GLUERUN_ASK_TIMEOUT_SEC:-600}"                  # readonly ask runner wall budget
# Detached dispatch (default ON; set to 0 for the legacy batch path). When on,
# reconcile spawns workers in their own session and returns within seconds;
# completion is observed by the reaper on later cycles via dispatch records +
# exit files, so import/integrate/recover/STOP regain their ~GLUERUN_SLEEP cadence
# while workers run. Setting 0 restores batch dispatch: reconcile waits for
# every worker before returning, exactly as the original loop did. Dispatch
# records live outside ensure_state_dirs on purpose: the dir is created only by
# the dispatch-record write path so other commands stay dormant.
GLUERUN_DETACHED_DISPATCH="${GLUERUN_DETACHED_DISPATCH:-1}"
GLUERUN_DISPATCH_DIR="${GLUERUN_DISPATCH_DIR:-$GLUERUN_STATE_DIR/dispatch}"

# L1 node leases + parallel-area planning.
GLUERUN_L1_LEASES_DIR="${GLUERUN_L1_LEASES_DIR:-$GLUERUN_STATE_DIR/l1-leases}"
GLUERUN_L1_LEASE_SCHEMA="${GLUERUN_L1_LEASE_SCHEMA:-$GLUERUN_SCHEMA_DIR/l1-lease.v0.schema.json}"
GLUERUN_L1_STALE_MINUTES="${GLUERUN_L1_STALE_MINUTES:-60}"
# Live L1 fanout (OPT-IN: default OFF — when unset, the actuation path is
# byte-identical to single-node planning). When enabled, L0 plans multiple
# independent DAG nodes concurrently (default 3), then imports their staged task
# proposals serially under the origin lock. L0 stays the only scheduler/importer.
GLUERUN_ENABLE_L1_PARALLEL="${GLUERUN_ENABLE_L1_PARALLEL:-0}"   # 1 enables concurrent L1 planners
GLUERUN_MAX_L1_CONCURRENT="${GLUERUN_MAX_L1_CONCURRENT:-3}"     # default L1 planner concurrency when enabled
GLUERUN_L1_TASKS_PER_NODE="${GLUERUN_L1_TASKS_PER_NODE:-1}"     # tasks each L1 planner proposes per node
GLUERUN_L2_SLICE_BUDGET="${GLUERUN_L2_SLICE_BUDGET:-1}"         # independent strict-test-first slices folded per L2 task (1 = today)
GLUERUN_L2_SLICE_BUDGET_MAX="${GLUERUN_L2_SLICE_BUDGET_MAX:-3}" # hard cap on slice budget (per-task blast-radius guard)
GLUERUN_MIN_DISK_GB="${GLUERUN_MIN_DISK_GB:-2}"                 # below this free-space floor, fanout blocks entirely

# 0.5.0 field-hardening knobs (see CHANGELOG "Migrating from 0.4.0").
# NOTE: the WAKE and task-id-counter paths are derived at CALL time via
# gluerun_wake_file / gluerun_task_id_counter_file so fixtures that re-point
# GLUERUN_STATE_DIR after sourcing lib.sh keep working; export the
# corresponding env var to pin a path explicitly.
GLUERUN_SLEEP_POLL_SEC="${GLUERUN_SLEEP_POLL_SEC:-10}"                     # interruptible-sleep chunk size
# Whole-tree liveness: a dispatch is alive if any process in its tree/pgroup
# survives OR its run dir saw writes within this window. HARD_MINUTES bounds
# conservatism: past that lease age we report dead regardless.
GLUERUN_TREE_ACTIVITY_WINDOW_SEC="${GLUERUN_TREE_ACTIVITY_WINDOW_SEC:-120}"
GLUERUN_STALE_HARD_MINUTES="${GLUERUN_STALE_HARD_MINUTES:-240}"
# Legacy pmgo.* schema ids in verdicts: "warn" tolerates + rewrites for
# validation (file untouched); "reject" hard-fails (post-migration hygiene).
GLUERUN_LEGACY_SCHEMA_MODE="${GLUERUN_LEGACY_SCHEMA_MODE:-warn}"

gluerun_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

gluerun_run_id() {
  date -u +"ORIGIN-%Y%m%dT%H%M%SZ-$$"
}

gluerun_ensure_state_dirs() {
  # NOTE: $GLUERUN_L1_LEASES_DIR is intentionally NOT created here. It is created
  # only by the L1 lease write path (gluerun_l1_lease_write), so ordinary commands
  # stay fully dormant w.r.t. the (deferred) L1-parallel machinery.
  mkdir -p "$GLUERUN_STATE_DIR/locks" "$GLUERUN_STATE_DIR/runs" "$GLUERUN_STATE_DIR/inbox"
}

gluerun_count_files() {
  local dir="$1"
  shift || true
  [[ -d "$dir" ]] || { echo 0; return 0; }
  find "$dir" "$@" -type f 2>/dev/null | wc -l | tr -d ' '
}

gluerun_ensure_gitignore_entries() {
  local gi="$GLUERUN_ROOT/.gitignore" entry
  mkdir -p "$(dirname "$gi")"
  touch "$gi"
  for entry in "$@"; do
    [[ -n "$entry" ]] || continue
    grep -qxF "$entry" "$gi" 2>/dev/null || printf '%s\n' "$entry" >>"$gi"
  done
}

gluerun_ensure_repo_scaffold() {
  mkdir -p \
    "$GLUERUN_ORCH_DIR/prompts" \
    "$GLUERUN_ORCH_DIR/tasks" \
    "$GLUERUN_ORCH_DIR/areas/core" \
    "$GLUERUN_ORCH_DIR/gates" \
    "$GLUERUN_ORCH_DIR/packets/imported" \
    "$GLUERUN_ROOT/schemas/orchestration"

  if [[ ! -f "$GLUERUN_ORCH_DIR/decisions.md" ]]; then
    cat >"$GLUERUN_ORCH_DIR/decisions.md" <<'EOF'
# Decisions

## Decision Log
EOF
  fi
  if [[ ! -f "$GLUERUN_ORCH_DIR/project-state.md" ]]; then
    cat >"$GLUERUN_ORCH_DIR/project-state.md" <<'EOF'
# Project State

Initial gluerun scaffold. Reconcile snapshots will be maintained below.
EOF
  fi
  if [[ ! -f "$GLUERUN_ORCH_DIR/tasks/TEMPLATE.md" ]]; then
    cat >"$GLUERUN_ORCH_DIR/tasks/TEMPLATE.md" <<'EOF'
# TASK-XXXX: <title>

Status: ready
Area: core
DAG node: <node-id>
Target branch: `agent/integration`
Worker branch: `agent/core/TASK-XXXX-<slug>`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Describe the smallest independently verifiable change.

## Scope

Owned files:

- `path/to/file`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The gate command passes.
EOF
  fi
  if [[ ! -f "$GLUERUN_ORCH_DIR/planner-contract.md" ]]; then
    cat >"$GLUERUN_ORCH_DIR/planner-contract.md" <<'EOF'
# Planner Contract

Create small, canonical tasks that can be validated by their gate command. Keep
owned files narrow, declare dependencies explicitly, and do not broaden scope
without a recorded decision.
EOF
  fi
  if [[ ! -f "$GLUERUN_ORCH_DIR/areas/core/state.md" ]]; then
    cat >"$GLUERUN_ORCH_DIR/areas/core/state.md" <<'EOF'
# Core Area State

Status: starter
EOF
  fi
  if [[ -d "$GLUERUN_SCHEMA_DIR" ]]; then
    local schema base
    while IFS= read -r schema; do
      [[ -n "$schema" ]] || continue
      base="$(basename "$schema")"
      [[ -f "$GLUERUN_ROOT/schemas/orchestration/$base" ]] || cp "$schema" "$GLUERUN_ROOT/schemas/orchestration/$base"
    done < <(find "$GLUERUN_SCHEMA_DIR" -maxdepth 1 -name '*.schema.json' -type f 2>/dev/null | sort)
  fi
  gluerun_ensure_gitignore_entries ".gluerun-state/" ".worktrees/" ".gluerun-evidence/" ".gluerun-cache/"
}

gluerun_json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))' 
}

gluerun_json_field() {
  local file="$1"
  local field="$2"
  python3 - "$file" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
value = data
for part in field.split("."):
    if not isinstance(value, dict) or part not in value:
        sys.exit(2)
    value = value[part]
if isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
PY
}

gluerun_packet_has_accept_waiver() {
  local packet="$1"
  python3 - "$packet" "$GLUERUN_RUNS_DIR" "$GLUERUN_ORCH_DIR/decisions.md" <<'PY'
import json
import os
import sys

packet_path, runs_dir, decisions_path = sys.argv[1:4]
try:
    with open(packet_path, encoding="utf-8") as f:
        packet = json.load(f)
except (OSError, json.JSONDecodeError):
    sys.exit(1)

task = str(packet.get("taskId", ""))
run = str(packet.get("runId", ""))
branch = str(packet.get("branch", ""))
if not task or not run or packet.get("status") != "accepted":
    sys.exit(1)

evidence = packet.get("evidence", [])
has_waiver_ref = any(
    isinstance(item, dict)
    and item.get("kind") == "waiver"
    and item.get("ref") == "decider:accept-waiver"
    for item in evidence
)
if not has_waiver_ref:
    sys.exit(1)

decision_json_ok = False
decision_path = os.path.join(runs_dir, run, "decision-audit-needs-fix.json")
try:
    with open(decision_path, encoding="utf-8") as f:
        decision = json.load(f)
    decision_json_ok = (
        decision.get("taskId") == task
        and decision.get("action") == "accept-waiver"
        and decision.get("failureClass") == "audit-needs-fix"
    )
except (OSError, json.JSONDecodeError):
    decision_json_ok = False

decisions_md_ok = False
try:
    with open(decisions_path, encoding="utf-8") as f:
        text = f.read()
    decisions_md_ok = (
        f"— {task} — decide:accept-waiver" in text
        and f"— {task} — accept" in text
        and f"- Run: `{run}`" in text
        and (not branch or f"- Branch: `{branch}`" in text)
    )
except OSError:
    decisions_md_ok = False

if decision_json_ok or decisions_md_ok:
    sys.exit(0)
sys.exit(1)
PY
}

gluerun_packet_acceptance_mode() {
  local packet="$1"
  local audit_record="$2"
  local verdict=""
  if [[ -f "$audit_record" ]]; then
    verdict="$(gluerun_json_field "$audit_record" verdict 2>/dev/null || true)"
    if [[ "$verdict" == "accepted" ]]; then
      echo "accepted"
      return 0
    fi
  fi
  if gluerun_packet_has_accept_waiver "$packet"; then
    echo "accepted-waiver"
    return 0
  fi
  return 1
}

gluerun_scope_amendment_path_allowed() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  case "$path" in
    .gluerun-cache|.gluerun-cache/*|.gluerun-state|.gluerun-state/*|.gluerun-evidence|.gluerun-evidence/*)
      return 1
      ;;
  esac
  return 0
}

# ---- Decider/parking hooks (generic; overridden by enabled modules) ----------
# Whether a terminal external-resource blocker applies to a failed gate. Generic: never.
gluerun_gate_red_external_proof_env_blocker() { return 1; }
# Whether the worker introduced a skipped proof path. Generic: never.
gluerun_strict_proof_skip_detected() { return 1; }
# Terminal parking rationale for a failure class (non-empty => park). Generic: none.
gluerun_terminal_blocker_rationale() { printf ''; }

# ---- Decider fast-path (T-F1) -------------------------------------------------
# Resolve a clear-cut failure class to a recovery action by policy, avoiding a
# model decider round-trip. Prints exactly ONE action token on stdout, OR prints
# nothing (empty) meaning "consult the model decider (decide.sh)".
#   gluerun_decider_fast_action <failure_class> <retry_count> <max_retries> <prev_failure_class>
# retry_count/max_retries are evaluated as the CALLER's budget accounting (the
# loop's 0-based attempt vs max_retries) so "retries remaining" (left) matches
# exactly when the existing loop decides to retry-vs-park. Logic, in order:
#   1. GLUERUN_DECIDER_FAST != 1            -> empty (force the model path).
#   2. failure_class == prev (repeat)    -> empty (a same-class repeat may be
#      systemic; escalate to the model for judgment).
#   3. table on left = max_retries - retry_count (>0 => budget remains).
gluerun_decider_fast_action() {
  local failure_class="$1" retry_count="${2:-0}" max_retries="${3:-0}" prev="${4:-}"
  [[ "${GLUERUN_DECIDER_FAST:-1}" == "1" ]] || return 0
  [[ "$retry_count" =~ ^[0-9]+$ ]] || retry_count=0
  [[ "$max_retries" =~ ^[0-9]+$ ]] || max_retries=0
  # A same-class repeat escalates to the model (could be systemic).
  if [[ -n "$failure_class" && "$failure_class" == "$prev" ]]; then
    return 0
  fi
  local left=$((max_retries - retry_count))
  local has_budget="no"
  [[ "$left" -gt 0 ]] && has_budget="yes"
  case "$failure_class" in
    gate-red|worker-no-packet|packet-invalid|no-changes|commit-failed)
      if [[ "$has_budget" == "yes" ]]; then printf 'retry'; else printf 'escalate-parked'; fi ;;
    scope-violation)
      if [[ "$has_budget" == "yes" ]]; then printf 'amend-scope'; else printf 'escalate-parked'; fi ;;
    worker-infra|audit-infra)
      # A model decider cannot fix broken infrastructure — park unconditionally.
      printf 'escalate-parked' ;;
    audit-needs-fix)
      # Buildable while budget remains; otherwise the model weighs accept-waiver.
      if [[ "$has_budget" == "yes" ]]; then printf 'retry'; else return 0; fi ;;
    *)
      # audit-blocked, audit-needs-human, audit-unknown, secret-detected,
      # proof-skip-detected, and any unlisted class -> the model decides.
      return 0 ;;
  esac
}

gluerun_append_event() {
  local type="$1"
  local message="$2"
  local data
  if [[ $# -ge 3 ]]; then
    data="$3"
  else
    data="{}"
  fi
  gluerun_ensure_state_dirs
  python3 - "$GLUERUN_EVENTS_FILE" "$type" "$message" "$data" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, typ, message, data_raw = sys.argv[1:5]
try:
    data = json.loads(data_raw)
except json.JSONDecodeError:
    data = {"raw": data_raw}
event = {
    "ts": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "type": typ,
    "message": message,
    "data": data,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(event, separators=(",", ":")) + "\n")
PY
}

gluerun_require_target_branch() {
  if [[ -z "${GLUERUN_TARGET_BRANCH:-}" ]]; then
    echo "GLUERUN_TARGET_BRANCH is required" >&2
    return 2
  fi
  if ! git -C "$GLUERUN_ROOT" rev-parse --verify --quiet "$GLUERUN_TARGET_BRANCH" >/dev/null; then
    echo "target branch not found: $GLUERUN_TARGET_BRANCH" >&2
    return 2
  fi
}

gluerun_current_branch() {
  git -C "$GLUERUN_ROOT" branch --show-current
}

gluerun_pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# SIGKILL a pid and every transitive descendant. Snapshots the full ps tree
# (intact at kill time, before anything exits) so reparenting can't let a child
# escape — more reliable than recursive pgrep -P or a process-group kill.
# Shared by claude-run.sh / codex-run.sh / decide.sh guards.
gluerun_kill_tree() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import os, signal, subprocess, sys
root = int(sys.argv[1])
out = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid="],
                     capture_output=True, text=True).stdout
children = {}
for line in out.splitlines():
    f = line.split()
    if len(f) != 2:
        continue
    try:
        pid, ppid = int(f[0]), int(f[1])
    except ValueError:
        continue
    children.setdefault(ppid, []).append(pid)
order, stack = [], [root]
while stack:
    p = stack.pop()
    for c in children.get(p, []):
        order.append(c)
        stack.append(c)
for pid in list(reversed(order)) + [root]:
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
PY
}

gluerun_acquire_lock() {
  local run_id="$1"
  gluerun_ensure_state_dirs
  if [[ -f "$GLUERUN_LOCK_FILE" ]]; then
    local pid
    pid="$(gluerun_json_field "$GLUERUN_LOCK_FILE" pid 2>/dev/null || true)"
    if gluerun_pid_alive "$pid"; then
      echo "active origin lock exists for pid $pid: $GLUERUN_LOCK_FILE" >&2
      gluerun_append_event "origin.lock_skipped" "active origin lock exists" "{\"pid\":\"$pid\"}"
      return 75
    fi
    local stale="$GLUERUN_LOCK_FILE.stale.$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$GLUERUN_LOCK_FILE" "$stale"
    gluerun_append_event "origin.lock_stale" "moved stale origin lock" "{\"path\":\"$stale\"}"
  fi
  python3 - "$GLUERUN_LOCK_FILE" "$run_id" "$$" "${GLUERUN_LOCK_MINUTES:-60}" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path, run_id, pid, minutes = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
now = datetime.now(timezone.utc).replace(microsecond=0)
data = {
    "schema": "gluerun.orchestration.lock.v0",
    "owner": "origin",
    "runId": run_id,
    "startedAt": now.isoformat().replace("+00:00", "Z"),
    "expiresAt": (now + timedelta(minutes=minutes)).isoformat().replace("+00:00", "Z"),
    "pid": pid,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

gluerun_release_lock() {
  local run_id="$1"
  if [[ ! -f "$GLUERUN_LOCK_FILE" ]]; then
    return 0
  fi
  local existing
  existing="$(gluerun_json_field "$GLUERUN_LOCK_FILE" runId 2>/dev/null || true)"
  if [[ "$existing" == "$run_id" ]]; then
    rm -f "$GLUERUN_LOCK_FILE"
  fi
}

gluerun_git_lock_acquire() {
  gluerun_ensure_state_dirs
  local waited=0
  while ! mkdir "$GLUERUN_GIT_LOCK_DIR" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    if [[ "$waited" -ge 600 ]]; then
      echo "timed out waiting for git operation lock: $GLUERUN_GIT_LOCK_DIR" >&2
      return 75
    fi
  done
  printf '%s\n' "$$" >"$GLUERUN_GIT_LOCK_DIR/pid"
}

gluerun_git_lock_release() {
  rm -rf "$GLUERUN_GIT_LOCK_DIR" 2>/dev/null || true
}

gluerun_with_git_lock() {
  gluerun_git_lock_acquire || return $?
  set +e
  "$@"
  local ec=$?
  set -e
  gluerun_git_lock_release
  return "$ec"
}

gluerun_validate_packet_basic() {
  local packet="$1"
  local schema="$GLUERUN_PACKET_SCHEMA"
  python3 - "$packet" "$schema" <<'PY'
import json
import sys

path, schema_path = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
with open(schema_path, "r", encoding="utf-8") as f:
    schema = json.load(f)
required = schema["required"]
properties = set(schema["properties"].keys())
missing = [key for key in required if key not in data]
if missing:
    print("missing required fields: " + ", ".join(missing), file=sys.stderr)
    sys.exit(2)
extra = sorted(set(data.keys()) - properties)
if extra:
    print("unknown fields: " + ", ".join(extra), file=sys.stderr)
    sys.exit(2)
if data["schema"] != "gluerun.orchestration.state-packet.v0":
    print("unsupported schema: " + str(data["schema"]), file=sys.stderr)
    sys.exit(2)
for key in ["ownedFiles", "changedFiles", "commands", "tests", "evidence", "blockers"]:
    if not isinstance(data[key], list):
        print(f"{key} must be an array", file=sys.stderr)
        sys.exit(2)
print("ok")
PY
}

# ---- Extension hooks (generic; overridden by enabled project modules) --------
# Choose the L2 worker runner for a task. Generic: always the default runner.
# A module may override to route specific tasks to an alternate runner
# (args: task_file default_runner alt_runner).
gluerun_select_l2_runner() {
  local task_file="$1" default_runner="$2" alt_runner="${3:-}"
  printf '%s\n' "$default_runner"
}

# Extra worker-prompt contract text for a task. Generic: none. A module may
# override to append project-specific obligations (args: task_file task_id).
gluerun_worker_contract_extra() {
  printf ''
}

# Red-evidence log path for a task's worker prompt. Generic: none (empty), so
# the prompt keeps its default red log. A module may override to point specific
# tasks at a project-specific red artifact (args: task_file task_id).
gluerun_worker_red_log() {
  printf ''
}

# Per-task guard for worker/import packets. Generic: accept. A module may
# override to enforce project-specific durable-proof requirements
# (args: packet task_file workspace run_dir).
gluerun_packet_module_guard() {
  return 0
}


gluerun_write_run_snapshot() {
  local run_id="$1"
  local snapshot="$2"
  local run_dir="$GLUERUN_STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir"
  printf "%s\n" "$snapshot" >"$run_dir/reconcile-snapshot.md"
}

gluerun_update_project_snapshot() {
  local snapshot_file="$GLUERUN_ORCH_DIR/project-state.md"
  local snapshot="$1"
  python3 - "$snapshot_file" "$snapshot" <<'PY'
import sys
from pathlib import Path

path, snapshot = sys.argv[1], sys.argv[2]
start = "<!-- gluerun:reconcile-snapshot:start -->"
end = "<!-- gluerun:reconcile-snapshot:end -->"
p = Path(path)
p.parent.mkdir(parents=True, exist_ok=True)
if p.exists():
    text = p.read_text(encoding="utf-8")
else:
    text = "# Project State\n"
replacement = f"{start}\n{snapshot.rstrip()}\n{end}"
if start not in text or end not in text:
    text = text.rstrip() + "\n\n## Latest Reconcile Snapshot\n\n" + replacement + "\n"
else:
    prefix, rest = text.split(start, 1)
    _, suffix = rest.split(end, 1)
    text = prefix + replacement + suffix
p.write_text(text, encoding="utf-8")
PY
}

# --- Actuation helpers (L0 scheduling, L1 driving) ---

gluerun_run_dir() {
  echo "$GLUERUN_RUNS_DIR/$1"
}

# Extract a single JSON object from a model's final message and write it back
# normalized. Handles the common cases where the message is pure JSON, wrapped in
# ```json fences, or has prose around a JSON object. Exits non-zero if no parseable
# JSON object is found. Usage: gluerun_extract_json <in> <out>
gluerun_extract_json() {
  local infile="$1" outfile="$2"
  python3 - "$infile" "$outfile" <<'PY'
import json
import sys

infile, outfile = sys.argv[1], sys.argv[2]
with open(infile, "r", encoding="utf-8") as f:
    text = f.read()

def try_load(s):
    try:
        return json.loads(s), True
    except Exception:
        return None, False

obj, ok = try_load(text)
if not ok:
    # Strip code fences if present.
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.split("\n", 1)[1] if "\n" in stripped else stripped
        if stripped.rstrip().endswith("```"):
            stripped = stripped.rstrip()[:-3]
    obj, ok = try_load(stripped)

if not ok:
    # Scan for ALL balanced top-level {...} objects (respecting strings) and keep
    # the LARGEST one that parses as JSON. Agentic models (e.g. Claude) emit the
    # real payload after reasoning prose and may add a small trailing note object;
    # the largest valid object is the intended payload, and preferring it avoids
    # latching onto an inline example/snippet that appears earlier in the prose.
    # (Codex clean JSON already parsed via the whole-text attempt above, so this
    # path never changes the codex result.)
    candidates = []
    n = len(text)
    start = text.find("{")
    while start != -1:
        depth = 0
        in_str = False
        esc = False
        end = -1
        for i in range(start, n):
            c = text[i]
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
            else:
                if c == '"':
                    in_str = True
                elif c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
        if end == -1:
            break
        cand, cok = try_load(text[start:end + 1])
        if cok:
            candidates.append((end - start, cand))
        start = text.find("{", end + 1)
    if candidates:
        candidates.sort(key=lambda p: p[0])
        obj = candidates[-1][1]
        ok = True

if not ok:
    sys.stderr.write("no parseable JSON object found\n")
    sys.exit(2)

with open(outfile, "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2)
    f.write("\n")
PY
}

gluerun_l1_normalize_worker_packet_schema() {
  local packet="$1"
  python3 - "$packet" <<'PY'
import json
import sys

path = sys.argv[1]
legacy_schema = "schemas/orchestration/state-packet.v0.schema.json"
schema_const = "gluerun.orchestration.state-packet.v0"
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
schema = str(data.get("schema", ""))
normalized = schema.replace("\\", "/")
if schema == legacy_schema or normalized.endswith("/" + legacy_schema):
    data["schema"] = schema_const
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
PY
}

gluerun_l1_prepare_worker_packet() {
  local raw_message="$1" packet="$2" validation_log="$3"
  [[ -n "$validation_log" ]] && mkdir -p "$(dirname "$validation_log")"
  if [[ ! -f "$raw_message" ]]; then
    [[ -n "$validation_log" ]] && echo "missing worker final message: $raw_message" >"$validation_log"
    return 10
  fi
  if ! gluerun_extract_json "$raw_message" "$packet" 2>"$validation_log"; then
    return 11
  fi
  gluerun_l1_normalize_worker_packet_schema "$packet"
  if ! gluerun_validate_packet_basic "$packet" >"$validation_log" 2>&1; then
    return 12
  fi
  return 0
}

gluerun_audit_record_path() {
  echo "$GLUERUN_RUNS_DIR/$1/audit.json"
}

gluerun_worker_run_id() {
  # Stable-ish per-invocation run id for L1/L2 work.
  date -u +"RUN-%Y%m%dT%H%M%SZ-$$"
}

# Parse a task markdown file into a normalized JSON object on stdout.
gluerun_task_json() {
  local task_file="$1"
  python3 - "$task_file" <<'PY'
import json
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

def strip_ticks(s):
    return s.strip().strip("`").strip()

data = {
    "taskId": "",
    "title": "",
    "status": "",
    "area": "",
    "targetBranch": "",
    "workerBranch": "",
    "testPolicy": "",
    "gateCommand": "",
    "dispatchMode": "",
    "dagNode": "",
    "supersedes": [],
    "supersededBy": [],
    "dependsOn": [],
    "objective": "",
    "ownedFiles": [],
    "forbiddenFiles": [],
    "prerequisites": [],
    "acceptanceCriteria": [],
}

header_keys = {
    "status": "status",
    "area": "area",
    "target branch": "targetBranch",
    "worker branch": "workerBranch",
    "test policy": "testPolicy",
    "gate command": "gateCommand",
    "dispatch mode": "dispatchMode",
    "dag node": "dagNode",
}

def parse_depends(raw):
    raw = strip_ticks(raw)
    if raw in ("", "[]", "none", "None", "NONE"):
        return []
    return re.findall(r"TASK-\d{4,}", raw)

section = None
subsection = None
objective_lines = []
for raw in lines:
    line = raw.rstrip()
    m = re.match(r"^#\s+(TASK-\d{4,})\s*:\s*(.*)$", line)
    if m:
        data["taskId"] = m.group(1)
        data["title"] = m.group(2).strip()
        continue
    hm = re.match(r"^##\s+(.*)$", line)
    if hm:
        section = hm.group(1).strip().lower()
        subsection = None
        continue
    if section is None:
        km = re.match(r"^([A-Za-z][A-Za-z ]+):\s*(.*)$", line)
        if km:
            key = km.group(1).strip().lower()
            if key == "depends on":
                data["dependsOn"] = parse_depends(km.group(2))
            elif key == "supersedes" or key == "superseded by":
                # "Supersedes:" declares intentional replacement (duplicate-guard
                # bypass); "Superseded by:" is the inverse pointer written by the
                # supersede verb. Both parse to TASK-id lists.
                field = "supersedes" if key == "supersedes" else "supersededBy"
                data[field] = parse_depends(km.group(2))
            elif key in header_keys:
                data[header_keys[key]] = strip_ticks(km.group(2))
        continue
    if section == "objective":
        if line.strip():
            objective_lines.append(line.strip())
        continue
    if section == "scope":
        sm = re.match(r"^(Owned files|Forbidden files)\s*:?\s*$", line.strip(), re.I)
        if sm:
            subsection = sm.group(1).lower()
            continue
        im = re.match(r"^[-*]\s+(.*)$", line.strip())
        if im:
            item = strip_ticks(im.group(1))
            if subsection == "owned files":
                data["ownedFiles"].append(item)
            elif subsection == "forbidden files":
                data["forbiddenFiles"].append(item)
        continue
    if section == "prerequisites":
        im = re.match(r"^[-*]\s+(.*)$", line.strip())
        if im:
            data["prerequisites"].append(im.group(1).strip())
        continue
    if section == "acceptance criteria":
        im = re.match(r"^[-*]\s+(.*)$", line.strip())
        if im:
            data["acceptanceCriteria"].append(im.group(1).strip())
        continue
    if section == "executable dag frontier" and not data["dagNode"]:
        # Planner-appended provenance ("- node: `X`") — the dagNode fallback for
        # tasks authored before the `DAG node:` header existed.
        nm = re.match(r"^[-*]\s+node:\s*(.+)$", line.strip(), re.I)
        if nm:
            data["dagNode"] = strip_ticks(nm.group(1))
        continue

data["objective"] = " ".join(objective_lines).strip()
print(json.dumps(data, separators=(",", ":")))
PY
}

# The DAG node a task belongs to (header `DAG node:` first, planner frontier
# section as fallback). Empty when the task predates node attribution.
gluerun_task_node() {
  gluerun_task_field "$1" dagNode 2>/dev/null || true
}

# JSON index of every task attributed to a DAG node, scanning the tasks dir
# INCLUDING subdirs (tasks/superseded/ etc.). One python pass — a per-file
# gluerun_task_json fan-out is too slow for promoter/health paths. The parse
# here is a deliberate minimal subset of gluerun_task_json (header lines,
# owned-files list, frontier-section node fallback); keep the two in sync.
# Output: [{"taskId","status","ownedFiles":[],"supersededBy":[],"file"}...]
gluerun_node_task_index_json() {
  local node="$1"
  python3 - "$GLUERUN_TASKS_DIR" "$node" <<'PY'
import json
import os
import re
import sys

tasks_dir, want_node = sys.argv[1], sys.argv[2]
out = []


def strip_ticks(s):
    return s.strip().strip("`").strip()


for dirpath, _dirs, files in os.walk(tasks_dir):
    for name in sorted(files):
        if not (name.startswith("TASK-") and name.endswith(".md")):
            continue
        path = os.path.join(dirpath, name)
        try:
            with open(path, "r", encoding="utf-8") as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        task_id = status = dag_node = ""
        owned, superseded_by = [], []
        section = subsection = None
        for raw in lines:
            line = raw.rstrip()
            m = re.match(r"^#\s+(TASK-\d{4,})\s*:", line)
            if m:
                task_id = m.group(1)
                continue
            hm = re.match(r"^##\s+(.*)$", line)
            if hm:
                section = hm.group(1).strip().lower()
                subsection = None
                continue
            if section is None:
                km = re.match(r"^([A-Za-z][A-Za-z ]+):\s*(.*)$", line)
                if km:
                    key = km.group(1).strip().lower()
                    if key == "status":
                        status = strip_ticks(km.group(2)).lower()
                    elif key == "dag node":
                        dag_node = strip_ticks(km.group(2))
                    elif key == "superseded by":
                        superseded_by = re.findall(r"TASK-\d{4,}", km.group(2))
                continue
            if section == "scope":
                sm = re.match(r"^(Owned files|Forbidden files)\s*:?\s*$", line.strip(), re.I)
                if sm:
                    subsection = sm.group(1).lower()
                    continue
                im = re.match(r"^[-*]\s+(.*)$", line.strip())
                if im and subsection == "owned files":
                    owned.append(strip_ticks(im.group(1)))
                continue
            if section == "executable dag frontier" and not dag_node:
                nm = re.match(r"^[-*]\s+node:\s*(.+)$", line.strip(), re.I)
                if nm:
                    dag_node = strip_ticks(nm.group(1))
                continue
        if task_id and dag_node == want_node:
            out.append({
                "taskId": task_id,
                "status": status,
                "ownedFiles": sorted(set(owned)),
                "supersededBy": superseded_by,
                "file": path,
            })
print(json.dumps(out, separators=(",", ":")))
PY
}

# A node is "pending promotion" when its planned work is done but its gate has
# not been published: >=1 task, zero open tasks (ready/planned/running/
# needs-review/accepted), >=1 integrated, every terminal task satisfied
# (integrated; or superseded/blocked/failed/cancelled with an integrated task
# covering its owned files or an integrated supersededBy successor), and the
# gate result is not passed. Planner suppression + integrate-time promotion
# both key on this predicate.
gluerun_node_pending_promotion() {
  local node="$1"
  local index gate_status=""
  index="$(gluerun_node_task_index_json "$node")" || return 1
  local gate="$GLUERUN_ORCH_DIR/gates/$node.gate-result.json"
  if [[ -f "$gate" ]]; then
    gate_status="$(gluerun_json_field "$gate" status 2>/dev/null || true)"
  fi
  python3 - "$gate_status" <<PY
import json
import sys

tasks = json.loads('''$index''')
gate_status = sys.argv[1]
# passed -> nothing to promote; failed/blocked -> promotion was ATTEMPTED and
# refused, so the node needs more work and must stay plannable (suppressing
# here would deadlock an all-integrated node behind a red gate).
if gate_status in ("passed", "failed", "blocked") or not tasks:
    sys.exit(1)

OPEN = {"ready", "planned", "running", "needs-review", "accepted", ""}
by_id = {t["taskId"]: t for t in tasks}
integrated = [t for t in tasks if t["status"] == "integrated"]
if not integrated:
    sys.exit(1)
if any(t["status"] in OPEN for t in tasks):
    sys.exit(1)


def satisfied(t, depth=0):
    if t["status"] == "integrated":
        return True
    if depth > 16:
        return False
    for succ in t.get("supersededBy", []):
        nxt = by_id.get(succ)
        if nxt is not None and satisfied(nxt, depth + 1):
            return True
    owned = set(t.get("ownedFiles", []))
    if owned:
        for it in integrated:
            if owned <= set(it.get("ownedFiles", [])):
                return True
    return False


sys.exit(0 if all(satisfied(t) for t in tasks) else 1)
PY
}

# Read a single field from a parsed task file (dotted path supported).
gluerun_task_field() {
  local task_file="$1"
  local field="$2"
  local json
  json="$(gluerun_task_json "$task_file")" || return $?
  python3 -c '
import json, sys
field, raw = sys.argv[1], sys.argv[2]
data = json.loads(raw)
value = data
for part in field.split("."):
    if not isinstance(value, dict) or part not in value:
        sys.exit(2)
    value = value[part]
print(json.dumps(value, separators=(",", ":")) if isinstance(value, (dict, list)) else value)
' "$field" "$json"
}

# Host-only task preflight (runs BEFORE any run_id/lease/worktree is created).
# Validates a parsed task JSON (gluerun_task_json output) and prints one
# human-readable refusal reason per line on stdout; returns non-zero on any
# failure, zero (and prints nothing) when the task is dispatchable.
#
#   gluerun_task_preflight <task_json> [<effective_gate_cmd>] [<effective_target_branch>] [<require_gate 0|1>]
#
# - effective_gate_cmd / effective_target_branch: pass the post-fallback values
#   the driver computed (config default gate, GLUERUN_TARGET_BRANCH). When empty,
#   the task's own fields are used.
# - require_gate=0 skips the empty-gate refusal (the historical dry-run
#   exemption); every other check still applies.
# - acceptanceCriteria is required when GLUERUN_PREFLIGHT_REQUIRE_ACCEPTANCE=1
#   (the default).
# Owned/forbidden conflicts use the same segment-boundary semantics as
# scope-check.sh: "a/b" conflicts with "a/b" and "a/b/c", but NOT with "a/bc".
# Forbidden entries are considered only when path-like (contain "/" and no
# space), matching the driver's forbidden-prefix filter, so prose entries like
# "Any file outside the owned scope." are ignored.
gluerun_task_preflight() {
  local task_json="$1" gate_cmd="${2-}" target_branch="${3-}" require_gate="${4:-1}"
  python3 - "$task_json" "$gate_cmd" "$target_branch" "$require_gate" \
    "${GLUERUN_PREFLIGHT_REQUIRE_ACCEPTANCE:-1}" <<'PY'
import json
import sys

task_raw, gate_arg, target_arg, require_gate, require_accept = sys.argv[1:6]
try:
    task = json.loads(task_raw)
    if not isinstance(task, dict):
        raise ValueError("task JSON must be an object")
except Exception as exc:
    print(f"unparseable task JSON: {exc}")
    sys.exit(1)

reasons = []

def field(key):
    return str(task.get(key, "") or "").strip()

target_branch = target_arg.strip() or field("targetBranch")
for key, label in (
    ("taskId", "taskId"),
    ("area", "area"),
    ("workerBranch", "workerBranch"),
    ("objective", "objective"),
):
    if not field(key):
        reasons.append(f"missing {label}")
if not target_branch:
    reasons.append("missing targetBranch")
if field("workerBranch") and target_branch and field("workerBranch") == target_branch:
    reasons.append(f"workerBranch equals targetBranch ({target_branch})")

owned = [str(x).strip() for x in (task.get("ownedFiles") or []) if str(x).strip()]
if not owned:
    reasons.append("task declares no owned files")

# Forbidden-prefix filter mirrors the driver: path-like entries only.
forbidden = [
    str(x).strip() for x in (task.get("forbiddenFiles") or [])
    if "/" in str(x) and " " not in str(x) and str(x).strip()
]

def paths_conflict(a, b):
    a, b = a.rstrip("/"), b.rstrip("/")
    if not a or not b:
        return False
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")

for own in owned:
    for forb in forbidden:
        if paths_conflict(own, forb):
            reasons.append(f"owned path conflicts with forbidden path: {own} vs {forb}")

gate_cmd = gate_arg if gate_arg.strip() else str(task.get("gateCommand", "") or "")
if require_gate == "1" and not "".join(gate_cmd.split()):
    reasons.append("no gate command (set 'Gate command:' in the task or gateCommand in gluerun.config.json)")

if require_accept == "1":
    accept = [str(x).strip() for x in (task.get("acceptanceCriteria") or []) if str(x).strip()]
    if not accept:
        reasons.append("task declares no acceptance criteria")

if reasons:
    print("\n".join(reasons))
    sys.exit(1)
PY
}

gluerun_planner_failure_class() {
  local log_file="$1" exit_code="${2:-0}" output_file="${3:-}"
  python3 - "$log_file" "$exit_code" "$output_file" <<'PY'
import os
import sys

log_file, exit_raw, output_file = sys.argv[1:4]
try:
    exit_code = int(exit_raw)
except ValueError:
    exit_code = 0
text = ""
if log_file and os.path.exists(log_file):
    with open(log_file, "r", encoding="utf-8", errors="replace") as f:
        text = f.read().lower()
quota_markers = (
    "usage limit",
    "rate limit",
    "quota",
    "too many requests",
    "try again at",
    # Claude session/usage-limit notices (e.g. "You've hit your session
    # limit · resets 10:40pm"). Without these the limit was misclassified
    # codex-exit and the quota sleep-through never engaged. Limit-specific;
    # real code failures still classify codex-exit and still trip the breaker.
    "session limit",
    "you've hit your",
    "limit reached",
    # Claude (Anthropic) overload / rate signals: the runner logs the JSON
    # envelope, whose api_error_status carries the HTTP status, and 529 surfaces
    # as an "Overloaded" error. These are distinctive substrings that only appear
    # on a failing run, so a longer (quota) backoff here is safe and correct.
    "overloaded",
    'api_error_status":429',
    'api_error_status":529',
    'api_error_status":503',
)
timeout_markers = (
    "timed out",
    "timeout",
    "deadline exceeded",
    "context deadline",
)
if any(marker in text for marker in quota_markers):
    print("quota")
elif exit_code in (124, 137) or any(marker in text for marker in timeout_markers):
    print("timeout")
elif exit_code != 0:
    print("codex-exit")
elif not output_file or not os.path.exists(output_file) or os.path.getsize(output_file) == 0:
    print("empty-output")
else:
    print("invalid-output")
PY
}

gluerun_planner_backoff_active_json() {
  [[ -f "$GLUERUN_PLANNER_BACKOFF_FILE" ]] || return 1
  python3 - "$GLUERUN_PLANNER_BACKOFF_FILE" <<'PY'
import json
import sys
from datetime import datetime, timezone

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    until_raw = str(data.get("until", ""))
    until = datetime.fromisoformat(until_raw.replace("Z", "+00:00"))
except Exception:
    sys.exit(1)
now = datetime.now(timezone.utc)
if until <= now:
    sys.exit(1)
print(json.dumps(data, separators=(",", ":")))
PY
}

gluerun_planner_backoff_set() {
  local failure_class="$1" run_id="${2:-}" node="${3:-}" log_ref="${4:-}"
  # A quota backoff without a logRef is unfalsifiable — every false backoff in
  # the field audit carried logRef:"" — so refuse to arm one. Callers with real
  # provider evidence always have the failing run's log path.
  if [[ "$failure_class" == "quota" && -z "$log_ref" ]]; then
    gluerun_append_event "backoff.rejected_no_evidence" \
      "quota backoff refused: no logRef evidence" \
      "{\"runId\":\"$run_id\",\"node\":\"$node\"}" 2>/dev/null || true
    echo "quota backoff refused: no logRef evidence (runId=$run_id node=$node)" >&2
    return 1
  fi
  local seconds
  if [[ "$failure_class" == "quota" ]]; then
    seconds="${GLUERUN_PLANNER_QUOTA_BACKOFF_SECONDS:-1800}"
  else
    seconds="${GLUERUN_PLANNER_BACKOFF_SECONDS:-900}"
  fi
  [[ "$seconds" =~ ^[0-9]+$ && "$seconds" -ge 1 ]] || seconds=900
  gluerun_ensure_state_dirs
  python3 - "$GLUERUN_PLANNER_BACKOFF_FILE" "$failure_class" "$seconds" "$run_id" "$node" "$log_ref" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path, failure_class, seconds_raw, run_id, node, log_ref = sys.argv[1:7]
now = datetime.now(timezone.utc).replace(microsecond=0)
until = now + timedelta(seconds=int(seconds_raw))
data = {
    "schema": "gluerun.orchestration.planner-backoff.v0",
    "failureClass": failure_class,
    "runId": run_id,
    "node": node,
    "logRef": log_ref,
    "startedAt": now.isoformat().replace("+00:00", "Z"),
    "until": until.isoformat().replace("+00:00", "Z"),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# Remove the planner backoff (operator "clear-backoff" primitive). Prints what
# was cleared; emits backoff.cleared with the prior record. Always exits 0 —
# clearing an absent backoff is a no-op, not an error.
gluerun_planner_backoff_clear() {
  if [[ ! -f "$GLUERUN_PLANNER_BACKOFF_FILE" ]]; then
    echo "no active backoff"
    return 0
  fi
  local prior
  prior="$(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),separators=(",",":")))' \
    "$GLUERUN_PLANNER_BACKOFF_FILE" 2>/dev/null || echo '{}')"
  rm -f "$GLUERUN_PLANNER_BACKOFF_FILE"
  gluerun_append_event "backoff.cleared" "planner backoff cleared by operator" "{\"previous\":$prior}"
  echo "backoff cleared (was: $prior)"
}

# Scan ONE file for usage-limit / overload / 403-entitlement markers. This is
# the single marker source for gluerun_planner_failure_class and the cycle
# limit-window detector. Markers are word-boundary contextual regexes — a bare
# repo word like "quota" (e.g. a quota-banner feature) must NOT match; only
# provider-error phrasings do. On match prints {"marker":...,"line":N}; rc 1
# when clean/unreadable.
gluerun_limit_marker_scan() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  python3 - "$file" <<'PY'
import json
import re
import sys

path = sys.argv[1]
markers = [
    r"usage limit",
    r"\bquota (?:exceeded|reached|exhausted|limit)",
    r"\brate[ -]?limit(?:ed|s)?\b",
    r"too many requests",
    r"\btry again at\b",
    r"session limit",
    r"you've hit your",
    r"\blimit reached\b",
    r"\boverloaded\b",
    r"api_error_status\":(?:429|529|503)",
    r"organization has disabled",
    r"subscription access for claude code",
    r"disabled claude subscription",
]
pattern = re.compile("|".join(f"(?:{m})" for m in markers))
try:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for lineno, line in enumerate(handle, 1):
            m = pattern.search(line.lower())
            if m:
                print(json.dumps({"marker": m.group(0), "line": lineno}, separators=(",", ":")))
                sys.exit(0)
except OSError:
    pass
sys.exit(1)
PY
}

# C2 (0.5.0 rewrite): detect a usage-limit / 403-org-disabled / overload window
# from THIS cycle's RUNNER logs and print structured evidence
# {"logRef","marker","line"} — the non-empty logRef is the arming contract for
# gluerun_planner_backoff_set. The 0.4.0 detector free-text-scanned every
# .log/.md/.json in the runs dir, so repo prose (a "quota-banner" feature, the
# word "quota" in a prompt .md) armed 30-minute backoffs from healthy cycles
# (field audit: >=13 false backoffs). Now:
#   - only engine-written runner output files are scanned (exact-name
#     whitelist; NEVER .md — prompts embed repo content),
#   - markers are word-boundary contextual regexes (gluerun_limit_marker_scan),
#   - still bounded to files modified within GLUERUN_LIMIT_SCAN_WINDOW_SEC.
# FAIL-CLOSED: no evidence -> rc 1 -> the breaker still trips on real failures.
gluerun_cycle_limit_window_evidence_json() {
  local runs_dir="${GLUERUN_RUNS_DIR:-$GLUERUN_STATE_DIR/runs}"
  [[ -d "$runs_dir" ]] || return 1
  local candidates
  candidates="$(python3 - "$runs_dir" "${GLUERUN_LIMIT_SCAN_WINDOW_SEC:-900}" <<'PY'
import os
import sys
import time

runs_dir = sys.argv[1]
try:
    window = int(sys.argv[2])
except ValueError:
    window = 900
now = time.time()

# Engine-written runner output files only. Prompts (*.md), packets, verdicts,
# and task files are excluded by construction.
RUNNER_LOG_NAMES = {
    "worker-codex.log",
    "planner-codex.log",
    "auditor-codex.log",
    "decider-codex.log",
    "plan.log",
    "gate-check.log",
    "claude-envelope.json",
}
RUNNER_LOG_SUFFIXES = (".runner.log", "-codex.log", "-claude.log", "-ctl.log")


def recent(path):
    try:
        return now - os.path.getmtime(path) <= window
    except OSError:
        return False


out = []
try:
    entries = list(os.scandir(runs_dir))
except OSError:
    entries = []
for entry in entries:
    try:
        if not entry.is_dir() or not recent(entry.path):
            continue
    except OSError:
        continue
    for root, _dirs, files in os.walk(entry.path):
        for name in files:
            if name in RUNNER_LOG_NAMES or name.endswith(RUNNER_LOG_SUFFIXES):
                path = os.path.join(root, name)
                if recent(path):
                    out.append(path)
for p in out:
    print(p)
PY
)"
  [[ -n "$candidates" ]] || return 1
  local file hit
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if hit="$(gluerun_limit_marker_scan "$file")"; then
      python3 - "$file" "$hit" <<'PY'
import json
import sys

log_ref, hit_raw = sys.argv[1], sys.argv[2]
hit = json.loads(hit_raw)
hit["logRef"] = log_ref
print(json.dumps(hit, separators=(",", ":")))
PY
      return 0
    fi
  done <<<"$candidates"
  return 1
}

# Thin compat wrapper (0.4.0 name): true iff structured evidence exists.
gluerun_cycle_limit_window_detected() {
  gluerun_cycle_limit_window_evidence_json >/dev/null
}

gluerun_blocked_gate_planner_guard_json() {
  local node="$1"
  local gate="$GLUERUN_ORCH_DIR/gates/$node.gate-result.json"
  [[ -f "$gate" ]] || return 1
  python3 - "$node" "$gate" <<'PY'
import json
import sys

node, path = sys.argv[1:3]
try:
    with open(path, "r", encoding="utf-8") as f:
        gate = json.load(f)
except Exception:
    sys.exit(1)
if gate.get("node") != node or gate.get("status") != "blocked":
    sys.exit(1)
missing = []
for evidence in gate.get("evidence", []):
    if evidence.get("kind") == "task-set":
        missing.extend(str(item) for item in evidence.get("taskIds", []) if item)
if not missing:
    sys.exit(1)
print(json.dumps({
    "node": node,
    "gateRef": f"docs/orchestration/gates/{node}.gate-result.json",
    "missingTaskIds": missing,
    "rationale": gate.get("rationale", ""),
}, separators=(",", ":")))
PY
}

# Duplicate-candidate guard (v2, 0.5.0). args: candidate_file [node] [mode].
# mode "create" (default; planner/importer): an existing task blocks the
#   candidate only while it is OPEN (ready/planned/running/needs-review/
#   accepted). Terminal tasks (blocked/superseded/integrated/failed/cancelled/
#   stale) never block — 0.4.0 scanned every task regardless of status, so a
#   node whose only task was blocked could never re-plan (deadlock -> breaker;
#   the field workaround was fake "legacy token" lines + file-scope inflation).
# mode "dispatch" (ready-frontier dedup): integrated also blocks — dispatching
#   a ready twin of integrated work is wasted compute.
# Node identity: explicit `DAG node:` header (dagNode) first; the legacy
# S#/D#-token regex is a fallback only. Both nodes non-empty -> must be equal.
# Either side missing -> only a FULL signature (title AND objective AND
# ownedFiles) matches; owned-files-alone no longer matches across unknown
# nodes (the 0.4.0 empty-node wildcard).
# A candidate whose `Supersedes:` header names the existing task bypasses the
# guard (intentional replacement); bypasses are reported on fd 2 as
# "SUPERSEDES <candidate> <existing>" for the caller to event.
gluerun_find_duplicate_task_signature() {
  local candidate="$1" node="${2:-}" mode="${3:-create}"
  # f MUST be local: this helper is called from inside callers' own
  # while-read-f loops (gluerun_list_ready_tasks) and bash dynamic scoping
  # would otherwise clobber their loop variable at EOF.
  local candidate_json task_input f
  candidate_json="$(gluerun_task_json "$candidate")" || return 1
  task_input="$(mktemp)"
  while IFS= read -r f; do
    [[ -n "$f" && "$f" != "$candidate" ]] || continue
    case "$(basename "$f")" in TEMPLATE.md) continue ;; esac
    printf '%s\t%s\n' "$f" "$(gluerun_task_json "$f")" >>"$task_input"
  done < <(find "$GLUERUN_TASKS_DIR" -maxdepth 1 -name 'TASK-*.md' -type f 2>/dev/null | sort)
  python3 - "$node" "$candidate_json" "$task_input" "$mode" <<'PY'
import json
import re
import sys

node, candidate_raw, task_input, mode = sys.argv[1:5]
candidate = json.loads(candidate_raw)

BLOCKING = {"ready", "planned", "running", "needs-review", "accepted", ""}
if mode == "dispatch":
    BLOCKING = BLOCKING | {"integrated"}

def norm_text(value):
    value = str(value or "").replace("`", " ").lower()
    return " ".join(value.split())

def norm_path(value):
    value = str(value or "").strip().strip("`").strip()
    while value.startswith("./"):
        value = value[2:]
    return value.rstrip("/")

def owned_sig(task):
    return sorted({norm_path(item) for item in task.get("ownedFiles", []) if norm_path(item)})

def infer_node(task):
    explicit = str(task.get("dagNode", "") or "").strip()
    if explicit:
        return explicit
    text = " ".join(
        str(task.get(key, ""))
        for key in ("title", "objective")
    )
    matches = re.findall(r"\b[DS]\d+\.[A-Za-z0-9_]+\b", text)
    return matches[0] if matches else ""

candidate_sig = {
    "node": node or infer_node(candidate),
    "title": norm_text(candidate.get("title")),
    "objective": norm_text(candidate.get("objective")),
    "ownedFiles": owned_sig(candidate),
}
if not candidate_sig["title"] or not candidate_sig["objective"] or not candidate_sig["ownedFiles"]:
    sys.exit(1)
supersedes = {str(t) for t in candidate.get("supersedes", [])}

with open(task_input, "r", encoding="utf-8") as f:
    lines = [line.rstrip("\n") for line in f if line.strip()]
for raw in lines:
    path, task_raw = raw.split("\t", 1)
    task = json.loads(task_raw)
    status = str(task.get("status", "") or "").strip().lower()
    if status not in BLOCKING:
        continue
    existing_id = str(task.get("taskId", "") or "")
    if existing_id and existing_id in supersedes:
        print(f"SUPERSEDES {candidate.get('taskId','')} {existing_id}", file=sys.stderr)
        continue
    existing_node = infer_node(task)
    existing_owned = owned_sig(task)
    if existing_owned != candidate_sig["ownedFiles"]:
        continue
    existing_title = norm_text(task.get("title"))
    existing_objective = norm_text(task.get("objective"))
    full_match = existing_title == candidate_sig["title"] and existing_objective == candidate_sig["objective"]
    if candidate_sig["node"] and existing_node:
        if existing_node != candidate_sig["node"]:
            continue
        matched = True  # same node + same owned files
    else:
        # Unknown node on either side: only a full signature is conclusive.
        matched = full_match
    if not matched:
        continue
    print(json.dumps({
        "reason": "duplicate-candidate",
        "match": "full-signature" if full_match else "owned-files",
        "existingTaskId": existing_id,
        "existingStatus": task.get("status", ""),
        "existingPath": path,
        "candidateTaskId": candidate.get("taskId", ""),
        "node": candidate_sig["node"],
        "existingNode": existing_node,
        "title": task.get("title", ""),
    }, separators=(",", ":")))
    sys.exit(0)
sys.exit(1)
PY
  local rc=$?
  rm -f "$task_input"
  return "$rc"
}

gluerun_duplicate_candidate_event_json() {
  local run_id="$1" node="$2" duplicate_json="$3"
  python3 - "$run_id" "$node" "$duplicate_json" <<'PY'
import json
import sys

run_id, node, raw = sys.argv[1:4]
data = json.loads(raw)
data["runId"] = run_id
if node:
    data["node"] = node
print(json.dumps(data, separators=(",", ":")))
PY
}

# List task files whose Status header equals "ready", sorted by task id, without
# applying dispatch duplicate policy. A single parser process keeps queue
# telemetry linear even when a campaign has dozens of ready tasks.
gluerun_list_status_ready_tasks() {
  [[ -d "$GLUERUN_TASKS_DIR" ]] || return 0
  python3 - "$GLUERUN_TASKS_DIR" <<'PY'
import pathlib
import sys

tasks_dir = pathlib.Path(sys.argv[1])
for path in sorted(tasks_dir.glob("TASK-*.md")):
    if path.name == "TEMPLATE.md" or not path.is_file():
        continue
    try:
        ready = any(line.strip().lower() == "status: ready" for line in path.open(encoding="utf-8"))
    except OSError:
        continue
    if ready:
        print(path)
PY
}

# List ready task files after applying the legacy duplicate-dispatch policy.
gluerun_list_ready_tasks() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ "${GLUERUN_SKIP_DUPLICATE_READY_TASKS:-1}" == "1" ]] && gluerun_find_duplicate_task_signature "$f" "" dispatch >/dev/null 2>&1; then
      continue
    fi
    echo "$f"
  done < <(gluerun_list_status_ready_tasks)
}

# Select a deterministic ready frontier for canonical parallel dispatch.
# Emits task file paths, sorted by task id, greedily selected up to the provided
# slot count. Readiness is stricter than Status: ready: dependencies must be
# integrated, no active lease may exist for the task, and file scopes must not
# overlap active leases or earlier selected tasks.
gluerun_select_dispatch_frontier() {
  local limit="${1:-1}"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=1
  [[ "$limit" -gt 0 ]] || return 0
  [[ -d "$GLUERUN_TASKS_DIR" ]] || return 0

  local task_json_lines
  task_json_lines="$(
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      [[ "$(basename "$f")" == "TEMPLATE.md" ]] && continue
      printf '%s\t%s\n' "$f" "$(gluerun_task_json "$f")"
    done < <(find "$GLUERUN_TASKS_DIR" -maxdepth 1 -name 'TASK-*.md' -type f 2>/dev/null | sort)
  )"

  local frontier_input
  frontier_input="$(mktemp)"
  printf '%s\n' "$task_json_lines" >"$frontier_input"
  python3 - "$limit" "$GLUERUN_LEASES_DIR" "$frontier_input" <<'PY'
import json
import os
import re
import sys

limit = int(sys.argv[1])
leases_dir = sys.argv[2]
tasks_path = sys.argv[3]

tasks = []
with open(tasks_path, "r", encoding="utf-8") as src:
  raw_lines = list(src)
for raw in raw_lines:
    raw = raw.rstrip("\n")
    if not raw:
        continue
    path, task_raw = raw.split("\t", 1)
    task = json.loads(task_raw)
    task["_path"] = path
    tasks.append(task)

statuses = {t.get("taskId", ""): t.get("status", "") for t in tasks}
active_scopes = []
active_statuses = {"running", "planned", "needs-review"}
blocking_task_statuses = active_statuses
lease_by_task = {}

def useful_scope(value):
    value = str(value or "").strip().strip("`").strip()
    if not value or "/" not in value or " " in value:
        return ""
    return value.rstrip("/")

def add_scope(target, values):
    for value in values or []:
        clean = useful_scope(value)
        if clean:
            target.append(clean)

def path_conflict(a, b):
    if not a or not b:
        return False
    return a == b or a.startswith(b.rstrip("/") + "/") or b.startswith(a.rstrip("/") + "/")

def any_conflict(left, right):
    return any(path_conflict(a, b) for a in left for b in right)

def owned_sig(task):
    return sorted({useful_scope(item) for item in task.get("ownedFiles", []) if useful_scope(item)})

def infer_node(task):
    explicit = str(task.get("dagNode", "") or "").strip()
    if explicit:
        return explicit
    text = " ".join(str(task.get(key, "")) for key in ("title", "objective"))
    matches = re.findall(r"\b[DS]\d+\.[A-Za-z0-9_]+\b", text)
    return matches[0] if matches else ""

if os.path.isdir(leases_dir):
    for name in sorted(os.listdir(leases_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(leases_dir, name)
        try:
            with open(path, "r", encoding="utf-8") as f:
                lease = json.load(f)
        except Exception:
            continue
        task_id = lease.get("taskId")
        if task_id:
            lease_by_task[task_id] = lease
        if lease.get("status") in active_statuses:
            scope = []
            owned = lease.get("ownedFiles")
            if isinstance(owned, list) and owned:
                add_scope(scope, owned)
            else:
                add_scope(scope, str(lease.get("fileScope", "")).split())
            active_scopes.append(scope)

selected = []
selected_scopes = []
for task in sorted(tasks, key=lambda t: t.get("taskId", "")):
    task_id = task.get("taskId", "")
    if len(selected) >= limit:
        break
    if task.get("status") != "ready":
        continue
    if os.environ.get("GLUERUN_SKIP_DUPLICATE_READY_TASKS", "1") == "1":
        # v2 (0.5.0): only OPEN non-ready twins and integrated twins suppress a
        # ready task. Terminal-but-unfinished statuses (blocked/superseded/
        # failed/cancelled/stale) never do — 0.4.0 blocked here too, so a
        # legitimate successor of a blocked task sat at frontier=0 forever.
        # A task whose `Supersedes:` header names the twin bypasses suppression.
        duplicate = False
        blocking = {"planned", "running", "needs-review", "accepted", "integrated"}
        supersedes = {str(t) for t in task.get("supersedes", [])}
        task_node = infer_node(task)
        task_owned = owned_sig(task)
        if task_owned:
            for other in tasks:
                if other is task:
                    continue
                if str(other.get("status", "")).strip().lower() not in blocking:
                    continue
                if str(other.get("taskId", "")) in supersedes:
                    continue
                other_node = infer_node(other)
                if task_node and other_node and task_node != other_node:
                    continue
                if owned_sig(other) == task_owned:
                    duplicate = True
                    break
        if duplicate:
            continue
    if task.get("dispatchMode") != "canonical":
        continue
    lease = lease_by_task.get(task_id)
    if lease and lease.get("status") in blocking_task_statuses:
        continue
    deps = task.get("dependsOn") or []
    if any(statuses.get(dep) != "integrated" for dep in deps):
        continue
    scope = []
    add_scope(scope, task.get("ownedFiles", []))
    if any(any_conflict(scope, active) for active in active_scopes):
        continue
    if any(any_conflict(scope, prior) for prior in selected_scopes):
        continue
    selected.append(task["_path"])
    selected_scopes.append(scope)

for path in selected:
    print(path)
PY
  rm -f "$frontier_input"
}

gluerun_lease_path() {
  echo "$GLUERUN_LEASES_DIR/$1.json"
}

gluerun_lease_status() {
  local task_id="$1"
  local lease
  lease="$(gluerun_lease_path "$task_id")"
  [[ -f "$lease" ]] || return 1
  gluerun_json_field "$lease" status 2>/dev/null || true
}

# Write (create or overwrite) a lease record for a task.
gluerun_lease_write() {
  # args: task_id branch area owner scope status [runId] [worktree] [baseSha] [batchId] [ownedFilesJson] [forbiddenFilesJson]
  local task_id="$1" branch="$2" area="$3" owner="$4" scope="$5" status="$6"
  local run_id="${7:-}" worktree="${8:-}"
  local base_sha="${9:-}" batch_id="${10:-}" owned_json="${11:-}" forbidden_json="${12:-}"
  mkdir -p "$GLUERUN_LEASES_DIR"
  local lease
  lease="$(gluerun_lease_path "$task_id")"
  # Protect accepted/integrated work: a fresh lease write for a DIFFERENT
  # branch over a terminal-good lease is an identity collision (the 0.4.0
  # allocator reused archived ids and the failed pre-lease destroyed the
  # superseded task's lease). Refuse instead of clobbering.
  if [[ -f "$lease" ]]; then
    local prev_status prev_branch
    prev_status="$(gluerun_json_field "$lease" status 2>/dev/null || true)"
    prev_branch="$(gluerun_json_field "$lease" branch 2>/dev/null || true)"
    if [[ ( "$prev_status" == "accepted" || "$prev_status" == "integrated" ) \
      && -n "$prev_branch" && -n "$branch" && "$prev_branch" != "$branch" ]]; then
      gluerun_append_event "lease.write_refused_protected" \
        "refused to overwrite $prev_status lease with different branch" \
        "{\"taskId\":\"$task_id\",\"prevBranch\":\"$prev_branch\",\"newBranch\":\"$branch\",\"prevStatus\":\"$prev_status\"}"
      echo "lease write refused: $task_id has $prev_status lease for $prev_branch (incoming: $branch)" >&2
      return 1
    fi
  fi
  python3 - "$lease" "$task_id" "$branch" "$area" "$owner" "$scope" "$status" "$run_id" "$worktree" \
    "$base_sha" "$batch_id" "$owned_json" "$forbidden_json" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

(path, task_id, branch, area, owner, scope, status, run_id, worktree,
 base_sha, batch_id, owned_raw, forbidden_raw) = sys.argv[1:14]
max_retries = int(os.environ.get("GLUERUN_MAX_RETRIES", "3"))
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
created = now
retry_count = 0
def parse_array(raw, fallback=None):
    if raw:
        try:
            value = json.loads(raw)
            if isinstance(value, list):
                return [str(v) for v in value]
        except Exception:
            pass
    return list(fallback or [])

if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            prev = json.load(f)
        created = prev.get("createdAt", now)
        retry_count = int(prev.get("retryCount", 0))
        if not base_sha:
            base_sha = prev.get("baseSha", "")
        if not batch_id:
            batch_id = prev.get("batchId", "")
    except Exception:
        pass
owned_files = parse_array(owned_raw, scope.split())
forbidden_files = parse_array(forbidden_raw, [])
data = {
    "taskId": task_id,
    "branch": branch,
    "area": area,
    "owner": owner,
    "fileScope": scope,
    "ownedFiles": owned_files,
    "forbiddenFiles": forbidden_files,
    "baseSha": base_sha,
    "batchId": batch_id,
    "runId": run_id,
    "worktree": worktree,
    "status": status,
    "retryCount": retry_count,
    "maxRetries": max_retries,
    "createdAt": created,
    "updatedAt": now,
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

# Update only the status (and updatedAt) of an existing lease.
gluerun_lease_set_status() {
  local task_id="$1" status="$2"
  local lease
  lease="$(gluerun_lease_path "$task_id")"
  [[ -f "$lease" ]] || return 1
  python3 - "$lease" "$status" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, status = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["status"] = status
data["updatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

# Increment a lease's retryCount; echo the new count.
gluerun_lease_bump_retry() {
  local task_id="$1"
  local lease
  lease="$(gluerun_lease_path "$task_id")"
  [[ -f "$lease" ]] || { echo 0; return 1; }
  python3 - "$lease" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["retryCount"] = int(data.get("retryCount", 0)) + 1
data["updatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print(data["retryCount"])
PY
}

# Overwrite a lease's ownedFiles with a JSON array. Used when amend-scope widens
# the worker's owned set mid-drive: the parallel-L1 scheduler derives its
# scope-overlap guard from lease.ownedFiles, so a widened scope that is not
# written back would let a concurrent task collide on the newly-owned paths.
gluerun_lease_update_owned() {
  local task_id="$1" owned_json="$2"
  local lease
  lease="$(gluerun_lease_path "$task_id")"
  [[ -f "$lease" ]] || return 1
  python3 - "$lease" "$owned_json" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, owned_raw = sys.argv[1], sys.argv[2]
try:
    owned = json.loads(owned_raw)
    if not isinstance(owned, list):
        raise ValueError("ownedFiles must be a JSON array")
except Exception as e:
    sys.stderr.write("gluerun_lease_update_owned: %s\n" % e)
    sys.exit(1)
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["ownedFiles"] = [str(x).strip() for x in owned if str(x).strip()]
data["updatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

gluerun_lease_field() {
  local task_id="$1" field="$2"
  local lease
  lease="$(gluerun_lease_path "$task_id")"
  [[ -f "$lease" ]] || return 1
  gluerun_json_field "$lease" "$field" 2>/dev/null || true
}

# --- Dispatch records (detached dispatch + shadow accounting) ---
# One record per spawned worker under $GLUERUN_DISPATCH_DIR: <taskId>.json with
# {taskId, runId, pid, pidStart, startedAt, log, baseSha, batchId, state}.
# The spawn wrapper drops <taskId>.exit (the driver's exit code) when the worker
# returns; gluerun_reap_dispatches consumes exit files (or detects dead pids) and
# finalizes records to state=reaped. pidStart (ps lstart) defeats pid reuse.

gluerun_dispatch_record_path() {
  printf '%s/%s.json' "$GLUERUN_DISPATCH_DIR" "$1"
}

gluerun_dispatch_exit_path() {
  printf '%s/%s.exit' "$GLUERUN_DISPATCH_DIR" "$1"
}

gluerun_dispatch_pid_start() {
  # Process start time for pid-reuse detection; empty if the pid is gone.
  local pid="$1"
  [[ -n "$pid" ]] || { echo ""; return 0; }
  ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//' || true
}

gluerun_dispatch_record_write() {
  # args: task_id run_id pid pid_start log base_sha batch_id
  local task_id="$1" run_id="$2" pid="$3" pid_start="$4" log="$5" base_sha="$6" batch_id="$7"
  mkdir -p "$GLUERUN_DISPATCH_DIR"
  # pgid: recorded for whole-tree liveness checks and (when the dispatch was
  # setsid'd, i.e. pgid == pid) safe orphan process-group cleanup.
  local pgid=""
  if [[ -n "$pid" ]]; then
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  python3 - "$(gluerun_dispatch_record_path "$task_id")" "$task_id" "$run_id" "$pid" "$pid_start" "$log" "$base_sha" "$batch_id" "$pgid" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, task_id, run_id, pid, pid_start, log, base_sha, batch_id, pgid = sys.argv[1:10]
data = {
    "taskId": task_id,
    "runId": run_id,
    "pid": int(pid) if pid.isdigit() else 0,
    "pidStart": pid_start,
    "pgid": int(pgid) if pgid.isdigit() else 0,
    "startedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "log": log,
    "baseSha": base_sha,
    "batchId": batch_id,
    "state": "launched",
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

gluerun_dispatch_exit_write() {
  # Called by the spawn wrapper after the driver returns. tmp+mv so a reader
  # never sees a partial code.
  local task_id="$1" ec="$2"
  mkdir -p "$GLUERUN_DISPATCH_DIR"
  local exit_file tmp
  exit_file="$(gluerun_dispatch_exit_path "$task_id")"
  tmp="$exit_file.tmp"
  printf '%s\n' "$ec" >"$tmp"
  mv -f "$tmp" "$exit_file"
}

gluerun_dispatch_record_finalize() {
  # args: task_id exit_code outcome  -- marks the record reaped, removes .exit
  local task_id="$1" ec="$2" outcome="$3"
  local record
  record="$(gluerun_dispatch_record_path "$task_id")"
  [[ -f "$record" ]] || return 0
  python3 - "$record" "$ec" "$outcome" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, ec, outcome = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["state"] = "reaped"
data["exitCode"] = int(ec)
data["outcome"] = outcome
data["reapedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
  rm -f "$(gluerun_dispatch_exit_path "$task_id")"
}

# Whole-tree dispatch liveness. The 0.4.0 reaper checked only the recorded root
# pid, so a dead wrapper with a still-running auditor child was "crashed" — the
# lease was deleted under a live process (field audit: accepted work destroyed,
# then an infinite re-dispatch loop). Alive (rc 0) if ANY of:
#   - root pid alive with matching pidStart (pid-reuse-safe),
#   - any live process in the recorded pgid (skipped when it is our own group),
#   - any live descendant reachable from the root pid,
#   - any process whose command line carries the run id (survives reparenting),
#   - any file under the run dir modified within GLUERUN_TREE_ACTIVITY_WINDOW_SEC.
# Bounded conservatism: if lease_age_min >= GLUERUN_STALE_HARD_MINUTES, report
# dead regardless (prefer false-alive inside the window, never forever).
# args: task_id pid pid_start run_id pgid [lease_age_min]
gluerun_dispatch_tree_alive() {
  local task_id="$1" pid="$2" pid_start="$3" run_id="$4" pgid="${5:-0}" lease_age_min="${6:-}"
  if [[ -n "$lease_age_min" && "$lease_age_min" =~ ^[0-9]+$ ]] \
    && (( lease_age_min >= ${GLUERUN_STALE_HARD_MINUTES:-240} )); then
    return 1
  fi
  if gluerun_pid_alive "$pid"; then
    local now_start
    now_start="$(gluerun_dispatch_pid_start "$pid")"
    if [[ -z "$pid_start" || "$now_start" == "$pid_start" ]]; then
      return 0
    fi
  fi
  python3 - "$pid" "$pgid" "$run_id" <<'PY' && return 0
import os
import subprocess
import sys

pid_raw, pgid_raw, run_id = sys.argv[1:4]
try:
    root = int(pid_raw)
except ValueError:
    root = 0
try:
    pgid = int(pgid_raw)
except ValueError:
    pgid = 0

out = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid="],
                     capture_output=True, text=True).stdout
children = {}
groups = {}
for line in out.splitlines():
    f = line.split()
    if len(f) != 3:
        continue
    try:
        p, pp, pg = int(f[0]), int(f[1]), int(f[2])
    except ValueError:
        continue
    children.setdefault(pp, []).append(p)
    groups.setdefault(pg, []).append(p)

# Live descendant of the recorded root pid.
stack = [root]
seen = set()
while stack:
    p = stack.pop()
    for c in children.get(p, []):
        if c in seen:
            continue
        seen.add(c)
        stack.append(c)
if seen:
    sys.exit(0)

# Live member of the recorded process group — but never our own group (a
# non-detached dispatch shares the reconciler's pgid; that proves nothing).
own_pgid = os.getpgid(0)
if pgid > 1 and pgid != own_pgid and groups.get(pgid):
    sys.exit(0)

# Command line carrying the run id (orphan re-parented past the tree walk).
if run_id:
    probe = subprocess.run(["pgrep", "-f", run_id], capture_output=True, text=True)
    pids = [x for x in probe.stdout.split() if x.isdigit() and int(x) != os.getpid()]
    if pids:
        sys.exit(0)
sys.exit(1)
PY
  # Recent run-dir writes: an active runner streams logs even when the process
  # topology is unreadable.
  if [[ -n "$run_id" && -d "$GLUERUN_RUNS_DIR/$run_id" ]]; then
    if python3 - "$GLUERUN_RUNS_DIR/$run_id" "${GLUERUN_TREE_ACTIVITY_WINDOW_SEC:-120}" <<'PY'
import os
import sys
import time

base, window = sys.argv[1], int(sys.argv[2])
now = time.time()
for dirpath, _dirs, files in os.walk(base):
    for name in files:
        try:
            if now - os.path.getmtime(os.path.join(dirpath, name)) <= window:
                sys.exit(0)
        except OSError:
            continue
sys.exit(1)
PY
    then
      return 0
    fi
  fi
  return 1
}

# Kill a dispatch's process GROUP — but only when the recorded pgid proves a
# setsid leader (pgid == recorded pid), never our own group, never pgid <= 1.
# Bounds the field leak of orphan Vite/Playwright gate servers surviving their
# parked workers. GLUERUN_KILL_ORPHAN_PGROUP=0 disables.
gluerun_kill_dispatch_pgroup() {
  local task_id="$1"
  [[ "${GLUERUN_KILL_ORPHAN_PGROUP:-1}" == "1" ]] || return 1
  local record pgid pid
  record="$(gluerun_dispatch_record_path "$task_id")"
  [[ -f "$record" ]] || return 1
  pgid="$(gluerun_json_field "$record" pgid 2>/dev/null || true)"
  pid="$(gluerun_json_field "$record" pid 2>/dev/null || true)"
  [[ "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 ]] || return 1
  [[ "$pgid" == "$pid" ]] || return 1                      # setsid leader proven
  local own_pgid
  own_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$pgid" != "$own_pgid" ]] || return 1
  kill -TERM -- "-$pgid" 2>/dev/null || true
  local waited=0
  while pgrep -g "$pgid" >/dev/null 2>&1 && (( waited < 5 )); do
    sleep 1; waited=$((waited + 1))
  done
  if pgrep -g "$pgid" >/dev/null 2>&1; then
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
  gluerun_append_event "dispatch.pgroup_killed" "dispatch process group terminated" \
    "{\"taskId\":\"$task_id\",\"pgid\":$pgid}" 2>/dev/null || true
  return 0
}

# Reap finished/crashed dispatches. Echoes counter lines for the caller:
#   reaped_ok=N reaped_failures=N reaped_refused=N reaped_terminal=N workers_running=N
# Exit-code contract (l1-drive): 0 = ok/no-op, 2 = REFUSAL (preconditions
# unmet, no state consumed — never breaker input), 3 = TERMINAL (a decided
# outcome: parked/blocked — counts as failure), anything else = crash/infra.
# 0.4.0 counted every nonzero exit as a failure, so deterministic refusals
# (e.g. task-id collisions re-dispatching into a preserved worktree) pumped
# the breaker to a halt.
# For every record in state=launched:
#  - .exit file present -> reaped + classified per the contract
#  - no .exit -> whole-TREE liveness decides (gluerun_dispatch_tree_alive:
#    descendants, pgroup, run-id command lines, recent run-dir writes). The
#    0.4.0 root-pid-only check declared a dead wrapper with a live auditor
#    "crashed" and failed the lease under it (accepted work destroyed).
# args: run_id  (the CURRENT cycle's run id, for event attribution)
gluerun_reap_dispatches() {
  local run_id="$1"
  local reaped_ok=0 reaped_failures=0 reaped_refused=0 reaped_terminal=0 workers_running=0
  if [[ -d "$GLUERUN_DISPATCH_DIR" ]]; then
    local record tid state pid pid_start pgid rec_run ec lease_status outcome
    for record in "$GLUERUN_DISPATCH_DIR"/*.json; do
      [[ -f "$record" ]] || continue
      state="$(gluerun_json_field "$record" state 2>/dev/null || true)"
      [[ "$state" == "launched" ]] || continue
      tid="$(gluerun_json_field "$record" taskId 2>/dev/null || true)"
      [[ -n "$tid" ]] || continue
      pid="$(gluerun_json_field "$record" pid 2>/dev/null || true)"
      pid_start="$(gluerun_json_field "$record" pidStart 2>/dev/null || true)"
      pgid="$(gluerun_json_field "$record" pgid 2>/dev/null || true)"
      rec_run="$(gluerun_json_field "$record" runId 2>/dev/null || true)"
      if [[ -f "$(gluerun_dispatch_exit_path "$tid")" ]]; then
        ec="$(head -1 "$(gluerun_dispatch_exit_path "$tid")" 2>/dev/null | tr -d '[:space:]')"
        [[ "$ec" =~ ^[0-9]+$ ]] || ec=1
        case "$ec" in
          0) outcome="ok";       reaped_ok=$((reaped_ok + 1)) ;;
          2) outcome="refused";  reaped_refused=$((reaped_refused + 1)) ;;
          3) outcome="terminal"; reaped_terminal=$((reaped_terminal + 1)) ;;
          *) outcome="failed";   reaped_failures=$((reaped_failures + 1)) ;;
        esac
        gluerun_dispatch_record_finalize "$tid" "$ec" "$outcome"
        gluerun_append_event "origin.dispatch_reaped" "dispatch reaped" \
          "{\"runId\":\"$run_id\",\"taskId\":\"$tid\",\"exitCode\":$ec,\"outcome\":\"$outcome\"}"
        continue
      fi
      if gluerun_dispatch_tree_alive "$tid" "$pid" "$pid_start" "$rec_run" "${pgid:-0}"; then
        workers_running=$((workers_running + 1))
        continue
      fi
      lease_status="$(gluerun_lease_status "$tid" 2>/dev/null || true)"
      case "$lease_status" in
        planned|running|needs-review) gluerun_lease_set_status "$tid" "failed" 2>/dev/null || true ;;
      esac
      reaped_failures=$((reaped_failures + 1))
      gluerun_dispatch_record_finalize "$tid" "-1" "crashed"
      gluerun_append_event "origin.dispatch_reaped" "dispatch crashed (tree dead, no exit file)" \
        "{\"runId\":\"$run_id\",\"taskId\":\"$tid\",\"exitCode\":-1,\"outcome\":\"crashed\",\"leaseStatus\":\"$lease_status\"}"
    done
  fi
  echo "reaped_ok=$reaped_ok"
  echo "reaped_failures=$reaped_failures"
  echo "reaped_refused=$reaped_refused"
  echo "reaped_terminal=$reaped_terminal"
  echo "workers_running=$workers_running"
}

# --- L1 node leases (parallel-area planning) ---
# An L1 lease reserves a single DAG node (and, in V1, its whole area) so that
# only one L1 planner advances a given area at a time. Completion authority is
# unchanged: an L1 lease NEVER means "complete" — the gate-result.v0 record is
# the only completion truth. These helpers mirror the L2 task-lease helpers.

# Map a DAG area to its repo-relative write-scope prefix(es). V1 uses the single
# convention internal/<area>/, centralized here so V2 can extend it (e.g. to a
# real per-node ownedFiles manifest) in one place.
gluerun_l1_area_write_scopes() {
  local area="$1"
  [[ -n "$area" ]] || return 0
  # Consumer-provided area->path map (GLUERUN_AREA_PATHS: newline list of
  # "area=path1[:path2]"); unmapped areas fall back to GLUERUN_AREA_PREFIX + area.
  if [[ -n "${GLUERUN_AREA_PATHS:-}" ]]; then
    local line key val p
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      key="${line%%=*}"
      val="${line#*=}"
      if [[ "$key" == "$area" ]]; then
        local paths
        IFS=':' read -ra paths <<< "$val"
        for p in "${paths[@]}"; do
          [[ -n "$p" ]] && echo "$p"
        done
        return 0
      fi
    done <<< "$GLUERUN_AREA_PATHS"
  fi
  echo "${GLUERUN_AREA_PREFIX:-internal/}$area/"
}

# Validate a JSON string against a JSON-Schema subset (dependency-free; mirrors
# the rules dag.sh enforces on gate-results). Supports type, const, enum,
# minLength, pattern, format:date-time, array minItems/items, and object
# required/properties/additionalProperties. Exits non-zero with a stderr message
# on the first violation (fail-closed). args: <json-string> <schema-path> [root-label]
gluerun_json_schema_check() {
  python3 - "$2" "$1" "${3:-value}" <<'PY'
import json
import re
import sys
from datetime import datetime

schema_path, raw, root = sys.argv[1], sys.argv[2], sys.argv[3]
with open(schema_path, "r", encoding="utf-8") as f:
    schema = json.load(f)
try:
    data = json.loads(raw)
except Exception as exc:
    sys.stderr.write("invalid JSON: %s\n" % exc)
    sys.exit(2)


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(2)


def check(val, spec, where):
    kind = spec.get("type")
    if kind == "string" and not isinstance(val, str):
        fail(f"{where} must be a string")
    if kind == "boolean" and not isinstance(val, bool):
        fail(f"{where} must be a boolean")
    if kind == "array" and not isinstance(val, list):
        fail(f"{where} must be an array")
    if kind == "object" and not isinstance(val, dict):
        fail(f"{where} must be an object")
    if kind == "integer" and (not isinstance(val, int) or isinstance(val, bool)):
        fail(f"{where} must be an integer")
    if "const" in spec and val != spec["const"]:
        fail(f"{where} must equal {spec['const']!r}")
    if "enum" in spec and val not in spec["enum"]:
        fail(f"{where} must be one of {spec['enum']}")
    if kind == "string":
        min_len = spec.get("minLength")
        if min_len is not None and len(val) < min_len:
            fail(f"{where} must be at least {min_len} character(s)")
        if spec.get("format") == "date-time":
            try:
                datetime.fromisoformat(str(val).replace("Z", "+00:00"))
            except ValueError:
                fail(f"{where} must be an ISO-8601 date-time")
        pattern = spec.get("pattern")
        if pattern and not re.fullmatch(pattern, val):
            fail(f"{where} must match pattern {pattern}")
    if kind == "array":
        min_items = spec.get("minItems")
        if min_items is not None and len(val) < min_items:
            fail(f"{where} must have at least {min_items} item(s)")
        item_spec = spec.get("items", {})
        for idx, item in enumerate(val):
            check(item, item_spec, f"{where}[{idx}]")
    if kind == "object":
        props = spec.get("properties", {})
        if spec.get("additionalProperties") is False:
            unknown = sorted(set(val) - set(props))
            if unknown:
                fail(f"{where} has unknown field(s): {', '.join(unknown)}")
        for key in spec.get("required", []):
            if key not in val:
                fail(f"{where} missing required field: {key}")
        for key, child in props.items():
            if key in val:
                check(val[key], child, f"{where}.{key}" if where else key)


check(data, schema, root)
PY
}

# Load a verdict file as compact JSON, normalizing a legacy "pmgo.orchestration.*"
# schema id to "gluerun.orchestration.*" for validation purposes only (the file
# is never rewritten). Default mode "warn" keeps 0.4.0-era consumers alive with
# a stderr warning + schema.legacy_id_tolerated event; GLUERUN_LEGACY_SCHEMA_MODE=reject
# hard-fails with a migration pointer (post-migration hygiene). Prints the
# (possibly normalized) compact JSON on stdout.
gluerun_normalize_schema_id() {
  local file="$1" label="${2:-verdict}"
  python3 - "$file" "${GLUERUN_LEGACY_SCHEMA_MODE:-warn}" "$label" <<'PY'
import json
import sys

path, mode, label = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
schema = str(data.get("schema", ""))
if schema.startswith("pmgo.orchestration."):
    new = "gluerun.orchestration." + schema[len("pmgo.orchestration."):]
    if mode == "reject":
        print(
            f"{label}: legacy schema id {schema!r} — run migrations/v0-to-v1.sh "
            "or set GLUERUN_LEGACY_SCHEMA_MODE=warn",
            file=sys.stderr,
        )
        sys.exit(2)
    print(f"{label}: tolerating legacy schema id {schema!r} -> {new!r}", file=sys.stderr)
    data["schema"] = new
print(json.dumps(data, separators=(",", ":")))
PY
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    # Emit the tolerance event only when a rewrite actually happened.
    if grep -q '"schema"[[:space:]]*:[[:space:]]*"pmgo\.orchestration\.' "$file" 2>/dev/null; then
      gluerun_append_event "schema.legacy_id_tolerated" "legacy pmgo schema id tolerated" \
        "{\"file\":\"$file\",\"label\":\"$label\"}" 2>/dev/null || true
    fi
  fi
  return $rc
}

# Central audit-verdict validator (symmetric with gluerun_validate_decider_verdict —
# 0.4.0 validated decider verdicts centrally but audit verdicts nowhere, so a
# malformed auditor JSON silently poisoned acceptance decisions). Schema-checks
# against GLUERUN_AUDIT_SCHEMA plus cross-field checks: taskId must match when
# both sides are non-empty; runId mismatch is warn-only (infra retries reuse runs).
gluerun_validate_audit_verdict() {
  local verdict="$1" task_id="${2:-}" run_id="${3:-}"
  local data
  data="$(gluerun_normalize_schema_id "$verdict" "audit verdict")" || return $?
  gluerun_json_schema_check "$data" "$GLUERUN_AUDIT_SCHEMA" "audit verdict" || return $?
  python3 - "$verdict" "$task_id" "$run_id" <<'PY'
import json
import sys

path, task_id, run_id = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
verdict_task = data.get("taskId", "")
if task_id and verdict_task and verdict_task != task_id:
    print(
        "audit verdict taskId mismatch: expected %r, got %r" % (task_id, verdict_task),
        file=sys.stderr,
    )
    sys.exit(2)
verdict_run = data.get("runId", "")
if run_id and verdict_run and verdict_run != run_id:
    print(
        "audit verdict runId mismatch (warn-only): expected %r, got %r" % (run_id, verdict_run),
        file=sys.stderr,
    )
PY
}

gluerun_validate_decider_verdict() {
  local verdict="$1" failure_class="$2" task_id="${3:-}"
  local data
  data="$(gluerun_normalize_schema_id "$verdict" "decider verdict")" || return $?
  gluerun_json_schema_check "$data" "$GLUERUN_DECIDER_SCHEMA" "decider verdict" || return $?
  python3 - "$verdict" "$failure_class" "$task_id" <<'PY'
import json
import sys

path, failure_class, task_id = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
if data.get("failureClass") != failure_class:
    print(
        "decider verdict failureClass mismatch: expected %r, got %r"
        % (failure_class, data.get("failureClass")),
        file=sys.stderr,
    )
    sys.exit(2)
verdict_task = data.get("taskId")
if task_id and verdict_task and verdict_task != task_id:
    print(
        "decider verdict taskId mismatch: expected %r, got %r"
        % (task_id, verdict_task),
        file=sys.stderr,
    )
    sys.exit(2)
PY
}

gluerun_write_decider_verdict() {
  local out="$1" task_id="$2" failure_class="$3" action="$4" rationale="$5" next_owner="$6"
  mkdir -p "$(dirname "$out")"
  python3 - "$out" "$task_id" "$failure_class" "$action" "$rationale" "$next_owner" <<'PY'
import json
import sys
from datetime import datetime, timezone

out, task_id, failure_class, action, rationale, next_owner = sys.argv[1:7]
data = {
    "schema": "gluerun.orchestration.decider-verdict.v0",
    "failureClass": failure_class,
    "action": action,
    "rationale": rationale,
    "nextOwner": next_owner,
    "params": {"fallbackGeneratedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")},
}
if task_id:
    data["taskId"] = task_id
with open(out, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# Pretty-write a compact JSON string to a path, matching the repo's lease format
# (indent=2 + trailing newline). The JSON is passed as an argument (NOT stdin),
# since stdin is consumed by the heredoc that carries this script.
# args: <dest-path> <compact-json>
gluerun_write_json_pretty() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
data = json.loads(sys.argv[2])
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# ---- Supervisor briefing + ask (0.10.0) -------------------------------------
# Read-only overseer helpers. Every function here is INERT until an explicit
# supervise.sh / ask.sh spawn (or the autonomate interval gate) calls it, so
# merely sourcing lib.sh writes nothing and an ordinary reconcile cycle stays
# byte-identical to 0.9.0.

# The writable-settings menu the supervisor may PROPOSE (never apply). The real
# whitelist + typed validation lives server-side (_settings_write_spec); this is
# the human-facing knob list surfaced to the model as guidance / defense-in-depth.
gluerun_settings_whitelist_keys() {
  cat <<'EOF'
GLUERUN_CODEX_MODEL
GLUERUN_CODEX_SERVICE_TIER
GLUERUN_CODEX_PLANNER_REASONING_EFFORT
GLUERUN_CODEX_L2_REASONING_EFFORT
GLUERUN_CODEX_AUDITOR_REASONING_EFFORT
GLUERUN_MAX_CONCURRENT
GLUERUN_MAX_L1_CONCURRENT
GLUERUN_ENABLE_L1_PARALLEL
GLUERUN_L1_TASKS_PER_NODE
GLUERUN_L2_SLICE_BUDGET
GLUERUN_L2_SLICE_BUDGET_MAX
GLUERUN_MAX_RETRIES
GLUERUN_MAX_CONSEC_FAILS
GLUERUN_MAX_HOURS
GLUERUN_MIN_DISK_GB
GLUERUN_L1_STALE_MINUTES
GLUERUN_PLANNER_BACKOFF_SECONDS
GLUERUN_PLANNER_QUOTA_BACKOFF_SECONDS
GLUERUN_AUTO_INTEGRATE
GLUERUN_PUSH
GLUERUN_GENERATE
GLUERUN_SLEEP
GLUERUN_TARGET_BRANCH
GLUERUN_SUPERVISOR_INTERVAL_MIN
EOF
}

# Build the shared read-only situational digest into <out> as a delimited file.
# Sections (each clamped to 4000 chars, ~24KB ceiling): STATUS.md verbatim,
# ops health JSON, DAG frontier JSON, gate table JSON, the last 30 events
# (compact ts/type/message), the config env{} block, and the settings whitelist.
# Both supervise.sh and ask.sh consume this via gluerun_render_supervisor_prompt.
gluerun_supervisor_digest() {
  local out="$1"
  gluerun_ensure_state_dirs
  local status health frontier gates events cfgenv whitelist
  status="$(cat "$GLUERUN_STATUS_FILE" 2>/dev/null || true)"; [[ -n "$status" ]] || status="(no STATUS.md written yet)"
  health="$(bash "$GLUERUN_ENGINE_DIR/ops.sh" health --json 2>/dev/null || true)"; [[ -n "$health" ]] || health="{}"
  frontier="$(bash "$GLUERUN_ENGINE_DIR/dag.sh" next-areas 2>/dev/null || true)"; [[ -n "$frontier" ]] || frontier="{}"
  gates="$(bash "$GLUERUN_ENGINE_DIR/ops.sh" gates --json 2>/dev/null || true)"; [[ -n "$gates" ]] || gates="{}"
  events="$(tail -n 30 "$GLUERUN_EVENTS_FILE" 2>/dev/null | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
        print("%s  %s  %s" % (e.get("ts", ""), e.get("type", ""), e.get("message", "")))
    except Exception:
        pass
' 2>/dev/null || true)"
  [[ -n "$events" ]] || events="(no events yet)"
  cfgenv="$(python3 - "$GLUERUN_JSON_CONFIG_FILE" 2>/dev/null <<'PY' || true
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
    env = cfg.get("env") or {}
    for k in sorted(env):
        print("%s=%s" % (k, env[k]))
except Exception:
    pass
PY
)"
  [[ -n "$cfgenv" ]] || cfgenv="(no config env{})"
  whitelist="$(gluerun_settings_whitelist_keys)"
  python3 - "$out" "$status" "$health" "$frontier" "$gates" "$events" "$cfgenv" "$whitelist" <<'PY'
import sys
out = sys.argv[1]
keys = ["STATUS-MD", "HEALTH-JSON", "FRONTIER-JSON", "GATES-JSON", "EVENTS-TAIL", "CONFIG-ENV", "SETTINGS-WHITELIST"]
vals = sys.argv[2:9]
CLAMP = 4000
parts = []
for key, val in zip(keys, vals):
    s = (val or "").strip("\n")
    if len(s) > CLAMP:
        s = s[:CLAMP] + "\n…(truncated)"
    parts.append("<<<GLUERUN:%s>>>\n%s\n" % (key, s))
parts.append("<<<GLUERUN:END>>>\n")
with open(out, "w", encoding="utf-8") as f:
    f.write("".join(parts))
PY
}

# Render a supervisor/ask prompt template into <out> by substituting the digest
# sections for [STATUS-MD] [HEALTH-JSON] [FRONTIER-JSON] [GATES-JSON]
# [EVENTS-TAIL] [CONFIG-ENV] [SETTINGS-WHITELIST], plus [QUESTION] from the
# (optional) question FILE. The question is read from a file and written into the
# rendered prompt file ONLY — it never transits a runner argv.
gluerun_render_supervisor_prompt() {
  local tmpl="$1" digest="$2" out="$3" qfile="${4:-}"
  python3 - "$tmpl" "$digest" "$out" "$qfile" <<'PY'
import sys
tmpl_path, digest_path, out_path, qfile = sys.argv[1:5]
with open(tmpl_path, "r", encoding="utf-8") as f:
    tmpl = f.read()
sections = {}
cur = None
buf = []
with open(digest_path, "r", encoding="utf-8") as f:
    for line in f:
        s = line.rstrip("\n")
        if s.startswith("<<<GLUERUN:") and s.endswith(">>>"):
            if cur is not None:
                sections[cur] = "\n".join(buf).strip("\n")
            key = s[len("<<<GLUERUN:"):-3]
            if key == "END":
                cur = None
                break
            cur = key
            buf = []
        else:
            buf.append(line.rstrip("\n"))
    if cur is not None:
        sections[cur] = "\n".join(buf).strip("\n")
question = ""
if qfile:
    try:
        with open(qfile, "r", encoding="utf-8") as f:
            question = f.read().strip()
    except Exception:
        question = ""
repl = {
    "[STATUS-MD]": sections.get("STATUS-MD", ""),
    "[HEALTH-JSON]": sections.get("HEALTH-JSON", ""),
    "[FRONTIER-JSON]": sections.get("FRONTIER-JSON", ""),
    "[GATES-JSON]": sections.get("GATES-JSON", ""),
    "[EVENTS-TAIL]": sections.get("EVENTS-TAIL", ""),
    "[CONFIG-ENV]": sections.get("CONFIG-ENV", ""),
    "[SETTINGS-WHITELIST]": sections.get("SETTINGS-WHITELIST", ""),
    "[QUESTION]": question,
}
for needle, value in repl.items():
    tmpl = tmpl.replace(needle, value)
with open(out_path, "w", encoding="utf-8") as f:
    f.write(tmpl)
PY
}

# Validate an extracted supervisor report against GLUERUN_SUPERVISOR_SCHEMA
# (required schema/stage/narrative, additionalProperties false, string items),
# then post-check the constraints the shared checker does not cover: risks /
# nextSteps are <=8 strings and proposedSettings is a string->string map.
# Returns non-zero (with a stderr reason) on any violation. Symmetric with
# gluerun_validate_decider_verdict.
gluerun_validate_supervisor_report() {
  local file="$1" data
  data="$(python3 - "$file" <<'PY' 2>/dev/null || true
import json, sys
try:
    print(json.dumps(json.load(open(sys.argv[1])), separators=(",", ":")))
except Exception:
    sys.exit(2)
PY
)"
  [[ -n "$data" ]] || { echo "supervisor report: not parseable JSON" >&2; return 2; }
  gluerun_json_schema_check "$data" "$GLUERUN_SUPERVISOR_SCHEMA" "supervisor report" || return $?
  python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("risks", "nextSteps"):
    v = d.get(k)
    if v is None:
        continue
    if not isinstance(v, list) or len(v) > 8 or any(not isinstance(x, str) for x in v):
        print("supervisor report: %s must be at most 8 strings" % k, file=sys.stderr)
        sys.exit(2)
ps = d.get("proposedSettings")
if ps is not None:
    if not isinstance(ps, dict) or any(
        not isinstance(k, str) or not isinstance(val, str) for k, val in ps.items()
    ):
        print("supervisor report: proposedSettings must be a string->string map", file=sys.stderr)
        sys.exit(2)
PY
}

gluerun_l1_lease_path() {
  echo "$GLUERUN_L1_LEASES_DIR/$1.json"
}

gluerun_l1_lease_status() {
  local node="$1" lease
  lease="$(gluerun_l1_lease_path "$node")"
  [[ -f "$lease" ]] || return 1
  gluerun_json_field "$lease" status 2>/dev/null || true
}

gluerun_l1_lease_field() {
  local node="$1" field="$2" lease
  lease="$(gluerun_l1_lease_path "$node")"
  [[ -f "$lease" ]] || return 1
  gluerun_json_field "$lease" "$field" 2>/dev/null || true
}

# Write (create or overwrite) an L1 node lease. The candidate object is built,
# then FULLY validated against the schema (every field, incl. minLength/pattern/
# enum/additionalProperties) before anything is written — fail-closed, so a
# malformed lease (empty node, bad status/baseSha, unknown field) is never
# persisted and the leases dir is not even created. On update, startedAt is
# preserved and baseSha falls back to the prior value when omitted.
# args: node area stage layer status runId baseSha targetBranch [scopesJson]
gluerun_l1_lease_write() {
  local node="$1" area="$2" stage="$3" layer="$4" status="$5"
  local run_id="$6" base_sha="$7" target_branch="$8" scopes_json="${9:-}"
  if [[ -z "$scopes_json" ]]; then
    scopes_json="$(gluerun_l1_area_write_scopes "$area" \
      | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().split() if l]))')"
  fi
  local lease started=""
  lease="$(gluerun_l1_lease_path "$node")"
  if [[ -f "$lease" ]]; then
    started="$(gluerun_json_field "$lease" startedAt 2>/dev/null || true)"
    [[ -n "$base_sha" ]] || base_sha="$(gluerun_json_field "$lease" baseSha 2>/dev/null || true)"
  fi
  local data
  data="$(python3 - "$node" "$area" "$stage" "$layer" "$status" "$run_id" \
    "$base_sha" "$target_branch" "$scopes_json" "$started" <<'PY'
import json
import sys
from datetime import datetime, timezone

(node, area, stage, layer, status, run_id,
 base_sha, target_branch, scopes_raw, started) = sys.argv[1:11]
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
try:
    scopes = json.loads(scopes_raw) if scopes_raw else []
    if not isinstance(scopes, list):
        scopes = []
except Exception:
    scopes = []
data = {
    "schema": "gluerun.orchestration.l1-lease.v0",
    "node": node,
    "area": area,
    "stage": stage,
    "layer": layer,
    "status": status,
    "runId": run_id,
    "baseSha": base_sha,
    "targetBranch": target_branch,
    "allowedWriteScopes": [str(s) for s in scopes],
    "startedAt": started or now,
    "updatedAt": now,
}
print(json.dumps(data, separators=(",", ":")))
PY
)" || return $?
  gluerun_json_schema_check "$data" "$GLUERUN_L1_LEASE_SCHEMA" "l1 lease" || return $?
  mkdir -p "$GLUERUN_L1_LEASES_DIR"
  gluerun_write_json_pretty "$lease" "$data"
}

# Update only the status (and updatedAt) of an existing L1 lease. The full
# mutated object is re-validated against the schema; on any violation (e.g. a
# bogus status) the call fails and the existing lease is left untouched.
gluerun_l1_lease_set_status() {
  local node="$1" status="$2" lease
  lease="$(gluerun_l1_lease_path "$node")"
  [[ -f "$lease" ]] || return 1
  local data
  data="$(python3 - "$lease" "$status" <<'PY'
import json
import sys
from datetime import datetime, timezone
path, status = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["status"] = status
data["updatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
print(json.dumps(data, separators=(",", ":")))
PY
)" || return $?
  gluerun_json_schema_check "$data" "$GLUERUN_L1_LEASE_SCHEMA" "l1 lease" || return $?
  gluerun_write_json_pretty "$lease" "$data"
}

# Echo active L1 node ids (status in proposed|planning|active), sorted.
gluerun_l1_list_active() {
  local lease status node
  [[ -d "$GLUERUN_L1_LEASES_DIR" ]] || return 0
  while IFS= read -r lease; do
    [[ -n "$lease" ]] || continue
    status="$(gluerun_json_field "$lease" status 2>/dev/null || true)"
    case "$status" in
      proposed|planning|active)
        node="$(gluerun_json_field "$lease" node 2>/dev/null || true)"
        [[ -n "$node" ]] && echo "$node"
        ;;
    esac
  done < <(find "$GLUERUN_L1_LEASES_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)
}

# Report stale active L1 leases (status proposed|planning|active whose updatedAt
# exceeds GLUERUN_L1_STALE_MINUTES). REPORT ONLY — never auto-clears or reuses a
# lease, so a stale slot is surfaced for a human/decider, never silently
# reclaimed. Emits "<node> <status> <ageMinutes|unknown>" per stale lease.
gluerun_l1_list_stale() {
  local minutes="${GLUERUN_L1_STALE_MINUTES:-60}" lease status node updated
  [[ -d "$GLUERUN_L1_LEASES_DIR" ]] || return 0
  while IFS= read -r lease; do
    [[ -n "$lease" ]] || continue
    status="$(gluerun_json_field "$lease" status 2>/dev/null || true)"
    case "$status" in proposed|planning|active) ;; *) continue ;; esac
    node="$(gluerun_json_field "$lease" node 2>/dev/null || true)"
    updated="$(gluerun_json_field "$lease" updatedAt 2>/dev/null || true)"
    python3 - "$node" "$status" "$updated" "$minutes" <<'PY'
import sys
from datetime import datetime, timezone
node, status, updated, minutes = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
def age(u):
    if not u:
        return None
    try:
        t = datetime.fromisoformat(u.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (datetime.now(timezone.utc) - t).total_seconds() / 60.0
a = age(updated)
if a is None or a >= minutes:
    print("%s %s %s" % (node, status, "unknown" if a is None else int(a)))
PY
  done < <(find "$GLUERUN_L1_LEASES_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)
}

# Reclaim stale L1 planning leases (0.5.0). gluerun_l1_list_stale is
# report-only; in the field three orphaned `active` L1 leases from an
# interrupted planning run excluded their nodes from the frontier for hours
# with no recovery path short of hand-editing lease JSON. Marks each stale
# lease failed (frontier selection only excludes proposed|planning|active) and
# emits recover.l1_lease_reclaimed. Planners are short-lived; the wall-clock
# threshold (GLUERUN_L1_STALE_MINUTES) is conservative.
gluerun_l1_reclaim_stale() {
  local line node status age reclaimed=0
  while IFS=' ' read -r node status age; do
    [[ -n "$node" ]] || continue
    if ! gluerun_l1_lease_set_status "$node" failed; then
      echo "recover: could not reclassify l1 lease $node (see error above)" >&2
      continue
    fi
    gluerun_append_event "recover.l1_lease_reclaimed" "stale l1 planning lease reclassified failed" \
      "{\"node\":\"$node\",\"previousStatus\":\"$status\",\"ageMin\":\"$age\"}"
    echo "recover: reclaimed stale l1 lease $node ($status, ${age}m)"
    reclaimed=$((reclaimed + 1))
  done < <(gluerun_l1_list_stale)
  return 0
}

# Select up to `limit` ready L1 nodes for parallel planning. READ-ONLY: queries
# dag.sh next-areas and the existing l1-leases; writes nothing. Drops nodes that
# (a) already have an active L1 lease, (b) belong to an area that already has an
# active L1 lease (the V1 primary guard), or (c) overlap an active lease's
# allowedWriteScopes. Emits selected node ids in DAG order, one per line.
gluerun_select_l1_frontier() {
  local limit="${1:-1}"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=1
  [[ "$limit" -gt 0 ]] || return 0

  local frontier_json
  frontier_json="$("$(dirname "${BASH_SOURCE[0]}")/dag.sh" next-areas 2>/dev/null)" || return 0

  # Pre-resolve each candidate area's configured write scopes through the
  # config-driven map (gluerun_l1_area_write_scopes), so the overlap guard below
  # compares the SAME scopes the leases carry — not a hardcoded internal/<area>/.
  local _frontier_areas _area scopes_map_json="{}"
  _frontier_areas="$(printf '%s' "$frontier_json" | python3 -c '
import json, sys
try:
    frontier = json.load(sys.stdin).get("frontier", [])
except Exception:
    frontier = []
seen = []
for entry in frontier:
    area = entry.get("area")
    if area and str(area) not in seen:
        seen.append(str(area))
for area in seen:
    print(area)
')"
  while IFS= read -r _area; do
    [[ -n "$_area" ]] || continue
    scopes_map_json="$(gluerun_l1_area_write_scopes "$_area" | python3 -c '
import json, sys
area, current = sys.argv[1], json.loads(sys.argv[2])
current[area] = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(current, separators=(",", ":")))
' "$_area" "$scopes_map_json")"
  done <<< "$_frontier_areas"

  python3 - "$limit" "$GLUERUN_L1_LEASES_DIR" "$frontier_json" "$scopes_map_json" <<'PY'
import json
import os
import sys

limit = int(sys.argv[1])
leases_dir = sys.argv[2]
frontier_raw = sys.argv[3]
scopes_map_raw = sys.argv[4] if len(sys.argv) > 4 else "{}"

try:
    frontier = json.loads(frontier_raw).get("frontier", [])
except Exception:
    frontier = []

try:
    scopes_map = json.loads(scopes_map_raw)
    if not isinstance(scopes_map, dict):
        scopes_map = {}
except Exception:
    scopes_map = {}

ACTIVE = {"proposed", "planning", "active"}

def useful_scope(value):
    value = str(value or "").strip()
    if not value or "/" not in value or " " in value:
        return ""
    return value.rstrip("/")

def path_conflict(a, b):
    if not a or not b:
        return False
    return a == b or a.startswith(b.rstrip("/") + "/") or b.startswith(a.rstrip("/") + "/")

def any_conflict(left, right):
    return any(path_conflict(a, b) for a in left for b in right)

active_nodes = set()
active_areas = set()
active_scopes = []  # one scope-list per active lease

if os.path.isdir(leases_dir):
    for name in sorted(os.listdir(leases_dir)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(leases_dir, name), "r", encoding="utf-8") as f:
                lease = json.load(f)
        except Exception:
            continue
        if lease.get("status") not in ACTIVE:
            continue
        node = lease.get("node")
        area = lease.get("area")
        if node:
            active_nodes.add(node)
        if area:
            active_areas.add(area)
        scope = [s for s in (useful_scope(v) for v in lease.get("allowedWriteScopes", [])) if s]
        active_scopes.append(scope)

selected = []
selected_areas = set()
selected_scopes = []
for entry in frontier:                       # DAG order preserved
    if len(selected) >= limit:
        break
    node = entry.get("node")
    area = entry.get("area")
    if not node:
        continue
    if node in active_nodes:                  # (a) node already leased
        continue
    if area in active_areas:                  # (b) area already leased
        continue
    if area in selected_areas:                # one node per area within this batch
        continue
    if area:
        scope_list = scopes_map.get(str(area))
        if scope_list is None:
            # Area absent from the pre-resolved map: same fallback the config
            # loader uses (GLUERUN_AREA_PREFIX, default internal/) + area.
            prefix = os.environ.get("GLUERUN_AREA_PREFIX") or "internal/"
            scope_list = ["%s%s/" % (prefix, area)]
        scope = [useful_scope(v) for v in scope_list]
    else:
        scope = []
    scope = [s for s in scope if s]
    if any(any_conflict(scope, a) for a in active_scopes):    # (c) scope overlap vs active
        continue
    if any(any_conflict(scope, s) for s in selected_scopes):  # scope overlap within batch
        continue
    selected.append(node)
    selected_areas.add(area)
    selected_scopes.append(scope)

for node in selected:
    print(node)
PY
}

# Free space (whole GiB, floored) on the repo's filesystem. df -k is POSIX
# (1024-blocks) and identical on macOS and Linux; column 4 is Available in KiB.
# Flooring rounds DOWN free space, the safe direction for a guard.
gluerun_free_disk_gb() {
  df -k "$GLUERUN_ROOT" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1024 / 1024 }'
}

# Highest TASK-#### number observable across EVERY durable surface: task files
# (including tasks/superseded/ and any archive subdir), leases (filenames and
# taskId fields, incl. quarantined), dispatch records, worktree dirs, imported
# packet dirs, and agent/* branches. The 0.4.0 allocator scanned only the
# active tasks dir at maxdepth 1, so archiving the highest task let the next
# plan REUSE its id and collide with the preserved worktree/lease/branch
# (field audit: 4 collisions, 2 breaker halts, 1 destroyed lease).
gluerun_task_id_scan_max() {
  python3 - "$GLUERUN_TASKS_DIR" "$GLUERUN_LEASES_DIR" "$GLUERUN_DISPATCH_DIR" \
    "$GLUERUN_WORKTREES_DIR" "$GLUERUN_ORCH_DIR/packets/imported" "$GLUERUN_ROOT" <<'PY'
import os
import re
import subprocess
import sys

tasks_dir, leases_dir, dispatch_dir, worktrees_dir, imported_dir, root = sys.argv[1:7]
pat = re.compile(r"TASK-0*(\d+)")
best = 0


def see(text):
    global best
    for m in pat.finditer(text or ""):
        n = int(m.group(1))
        if n > best:
            best = n


for base in (tasks_dir,):
    for dirpath, _dirs, files in os.walk(base):
        for name in files:
            if name.startswith("TASK-") and name.endswith(".md"):
                see(name)
for base in (leases_dir, dispatch_dir):
    for dirpath, _dirs, files in os.walk(base) if os.path.isdir(base) else []:
        for name in files:
            see(name)
for base in (worktrees_dir, imported_dir):
    try:
        for name in os.listdir(base):
            see(name)
    except OSError:
        pass
try:
    out = subprocess.run(
        ["git", "-C", root, "for-each-ref", "--format=%(refname:short)", "refs/heads/agent/"],
        capture_output=True, text=True, timeout=10,
    ).stdout
    see(out)
except Exception:
    pass
print(best)
PY
}

# Allocate `count` fresh sequential task ids, printed one per line. Monotonic
# via a durable counter file seeded/self-healed from gluerun_task_id_scan_max on
# every allocation (a deleted or stale counter can never regress below observed
# reality). Serialized by a mkdir lock; gaps from failed planner runs are
# intentional — monotonicity is the invariant, not density.
gluerun_task_id_counter_file() {
  printf '%s' "${GLUERUN_TASK_ID_COUNTER_FILE:-$GLUERUN_STATE_DIR/task-id-counter}"
}

gluerun_task_id_next() {
  local count="${1:-1}"
  [[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] || count=1
  gluerun_ensure_state_dirs
  local counter lock
  counter="$(gluerun_task_id_counter_file)"
  mkdir -p "$(dirname "$counter")" 2>/dev/null || true
  lock="$counter.lock"
  local waited=0
  until mkdir "$lock" 2>/dev/null; do
    sleep 0.2
    waited=$((waited + 1))
    if (( waited >= 50 )); then
      echo "task-id allocator lock busy: $lock" >&2
      return 1
    fi
  done
  # shellcheck disable=SC2064
  trap "rmdir '$lock' 2>/dev/null || true" RETURN
  local stored=0 scan seed i
  if [[ -f "$counter" ]]; then
    stored="$(head -1 "$counter" 2>/dev/null | tr -d '[:space:]')"
    [[ "$stored" =~ ^[0-9]+$ ]] || stored=0
  fi
  scan="$(gluerun_task_id_scan_max)"
  [[ "$scan" =~ ^[0-9]+$ ]] || scan=0
  seed=$(( stored > scan ? stored : scan ))
  printf '%s\n' "$((seed + count))" >"$counter"
  for ((i = 1; i <= count; i++)); do
    printf 'TASK-%04d\n' "$((seed + i))"
  done
  rmdir "$lock" 2>/dev/null || true
  trap - RETURN
}

# Deprecated 0.4.0 alias: the old maxdepth-1 active-dir scan. Kept for any
# external caller; new code must use gluerun_task_id_next.
gluerun_max_task_id() {
  gluerun_task_id_scan_max
}

# Rewrite every WHOLE TASK-#### token equal to $2 with $3 in file $1. Token-safe
# (matches complete TASK-\d{4,} tokens and replaces only exact-id matches), so
# rewriting TASK-0001 can never corrupt TASK-0010/TASK-00011 the way an unanchored
# substring `sed s/.../.../g` would. No-op when the ids are equal/empty.
gluerun_rewrite_task_id_token() {
  local file="$1" from="$2" to="$3"
  [[ -n "$from" && -n "$to" && "$from" != "$to" ]] || return 0
  python3 - "$file" "$from" "$to" <<'PY'
import re
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()
new = re.sub(r"TASK-\d{4,}", lambda m: to if m.group(0) == frm else m.group(0), text)
with open(path, "w", encoding="utf-8") as f:
    f.write(new)
PY
}

# Plan up to GLUERUN_MAX_L1_CONCURRENT independent DAG nodes in parallel, then
# import their staged task proposals serially. Concurrent planners write ONLY to
# their private staging dir + their own lease + a private events file; the L0
# process (this function) is the only writer of the global tasks dir and global
# events. STOP and low disk fail closed. One planner failing never aborts or
# discards another's staged batch.
gluerun_l1_fanout() {
  local run_id="$1" base_sha="$2"
  if gluerun_stop_requested; then
    gluerun_append_event "origin.fanout_aborted" "STOP sentinel present; no l1 fanout" "{\"runId\":\"$run_id\"}"
    return 0
  fi
  local cap="${GLUERUN_MAX_L1_CONCURRENT:-3}"
  [[ "$cap" =~ ^[0-9]+$ && "$cap" -ge 1 ]] || cap=1
  local free_gb min_gb
  free_gb="$(gluerun_free_disk_gb)"; [[ "$free_gb" =~ ^[0-9]+$ ]] || free_gb=0
  min_gb="${GLUERUN_MIN_DISK_GB:-1}"
  [[ "$min_gb" =~ ^[0-9]+$ ]] || min_gb=1
  if [[ "$free_gb" -lt "$min_gb" ]]; then
    gluerun_append_event "origin.disk_pressure" "low disk; l1 fanout blocked" \
      "{\"runId\":\"$run_id\",\"freeGb\":$free_gb,\"minGb\":$min_gb}"
    gluerun_append_event "origin.fanout_aborted" "low disk; no l1 fanout" \
      "{\"runId\":\"$run_id\",\"freeGb\":$free_gb,\"minGb\":$min_gb}"
    echo "actuation: l1 fanout blocked by low disk (free=${free_gb}GiB min=${min_gb}GiB)"
    return 0
  fi
  local -a nodes=()
  mapfile -t nodes < <(gluerun_select_l1_frontier "$cap")
  # Pending-promotion pre-filter (0.5.0): nodes whose tasks are complete but
  # whose gate is unpublished must not be re-planned (duplicate churn).
  if [[ "${GLUERUN_SUPPRESS_UNPROMOTED_REPLAN:-1}" == "1" && "${#nodes[@]}" -gt 0 ]]; then
    local -a plannable=()
    local _n
    for _n in "${nodes[@]}"; do
      if gluerun_node_pending_promotion "$_n" 2>/dev/null; then
        echo "actuation: l1 fanout: skipped pending-promotion node=$_n"
      else
        plannable+=("$_n")
      fi
    done
    nodes=(${plannable[@]+"${plannable[@]}"})
  fi
  if [[ "${#nodes[@]}" -eq 0 ]]; then
    echo "actuation: l1 fanout: no eligible frontier nodes"
    return 0
  fi
  local plan_root="$GLUERUN_RUNS_DIR/$run_id/l1-staging"
  local planner_driver="${GLUERUN_L1_PLAN_NODE:-$(dirname "${BASH_SOURCE[0]}")/l1-plan-node.sh}"
  local tasks_per_node="${GLUERUN_L1_TASKS_PER_NODE:-1}"
  gluerun_append_event "origin.l1_fanout" "l1 fanout started" \
    "{\"runId\":\"$run_id\",\"cap\":$cap,\"nodes\":${#nodes[@]},\"freeGb\":$free_gb}"
  echo "actuation: l1 fanout cap=$cap nodes=${#nodes[@]} (${nodes[*]})"
  local -a pids=() pnodes=()
  local node node_dir
  for node in "${nodes[@]}"; do
    node_dir="$plan_root/$node"
    mkdir -p "$node_dir"
    ( "$planner_driver" --node "$node" --run-id "$run_id" --stage-dir "$node_dir" \
        --base-sha "$base_sha" --count "$tasks_per_node" ) >"$node_dir/plan.log" 2>&1 &
    pids+=("$!"); pnodes+=("$node")
  done
	  local -a import_nodes=()
	  local i ec planner_failures=0 import_rejections=0 import_out parsed_rejections
	  for i in "${!pids[@]}"; do
	    ec=0; wait "${pids[$i]}" || ec=$?
	    if [[ "$ec" -eq 0 ]]; then
	      import_nodes+=("${pnodes[$i]}")
	    else
	      planner_failures=$((planner_failures + 1))
	      gluerun_append_event "origin.l1_planner_failed" "l1 planner failed (isolated)" \
	        "{\"runId\":\"$run_id\",\"node\":\"${pnodes[$i]}\",\"exitCode\":$ec}"
	    fi
	  done
	  if [[ "${#import_nodes[@]}" -gt 0 ]]; then
	    import_out="$(gluerun_l1_import_staged "$run_id" "${import_nodes[@]}" 2>&1)" || true
	    printf '%s\n' "$import_out"
	    parsed_rejections="$(printf '%s\n' "$import_out" | sed -n 's/^l1_import_rejections=//p' | tail -1)"
	    [[ "$parsed_rejections" =~ ^[0-9]+$ ]] && import_rejections="$parsed_rejections"
	  fi
	  echo "l1_planner_failures=$planner_failures"
	  echo "l1_import_rejections=$import_rejections"
	  return 0
	}

# Serially import staged task proposals into the global tasks dir. Runs only in
# the single L0 process under the origin lock the caller already holds. Real
# TASK-#### ids are allocated sequentially (recomputed per node so ids stay
# globally monotonic no matter how many planners ran), and the per-node batch is
# imported all-or-nothing after validating shape (status/area/ownedFiles/
# dispatchMode). A node's lease is released on success, marked failed otherwise.
gluerun_l1_import_staged() {
	  local run_id="$1"; shift
	  local node stage_dir node_area cand
	  local import_rejections=0
	  for node in "$@"; do
    stage_dir="$GLUERUN_RUNS_DIR/$run_id/l1-staging/$node"
    local -a cands=()
    if [[ -d "$stage_dir" ]]; then
      mapfile -t cands < <(find "$stage_dir" -maxdepth 1 -name '*.candidate.md' -type f 2>/dev/null | sort)
    fi
	    if [[ "${#cands[@]}" -eq 0 ]]; then
	      if [[ -f "$stage_dir/NO-TASKS" ]]; then
	        # Valid empty batch (0.5.0): release the node lease, no rejection.
	        rm -f "$(gluerun_l1_lease_path "$node")" 2>/dev/null || true
	        gluerun_append_event "origin.l1_no_tasks" "planner returned a valid empty batch; node lease released" "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
	        echo "no-tasks:$node"
	        continue
	      fi
	      import_rejections=$((import_rejections + 1))
	      gluerun_l1_lease_set_status "$node" failed 2>/dev/null || true
	      gluerun_append_event "origin.l1_import_rejected" "no staged candidates" "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
	      continue
    fi
    node_area="$(gluerun_l1_lease_field "$node" area 2>/dev/null || true)"
	    if [[ -z "$node_area" ]]; then
      # Fail closed: a missing/unreadable lease means the node was never validly
      # planned (l1-plan-node writes the lease before planning). Import nothing.
	      import_rejections=$((import_rejections + 1))
	      gluerun_l1_lease_set_status "$node" failed 2>/dev/null || true
	      gluerun_append_event "origin.l1_import_rejected" "missing or unreadable l1 lease at import" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
      continue
    fi
    # Validate the whole batch first (all-or-nothing); real ids come from the
    # durable monotonic allocator AFTER validation succeeds (so a rejected
    # batch never burns ids).
	    local ok=1 real v_id v_status v_area v_owned v_mode
	    local duplicate_json="" duplicate_event_json=""
	    local -a src=() ids=() temps=()
    for cand in "${cands[@]}"; do
      v_id="$(gluerun_task_field "$cand" taskId 2>/dev/null || echo '')"
      v_status="$(gluerun_task_field "$cand" status 2>/dev/null || echo '')"
      v_area="$(gluerun_task_field "$cand" area 2>/dev/null || echo '')"
      v_owned="$(gluerun_task_field "$cand" ownedFiles 2>/dev/null || echo '[]')"
      v_mode="$(gluerun_task_field "$cand" dispatchMode 2>/dev/null || echo '')"
	      if [[ -z "$v_id" || "$v_status" != "ready" || "$v_area" != "$node_area" || "$v_owned" == "[]" || "$v_mode" != "canonical" ]]; then
	        ok=0; break
	      fi
	      if duplicate_json="$(gluerun_find_duplicate_task_signature "$cand" "$node" 2>/dev/null)"; then
	        ok=2; break
	      fi
	      src+=("$cand"); temps+=("$v_id")
	    done
	    if [[ "$ok" -eq 1 ]]; then
	      while IFS= read -r real; do
	        [[ -n "$real" ]] && ids+=("$real")
	      done < <(gluerun_task_id_next "${#src[@]}")
	      [[ ${#ids[@]} -eq ${#src[@]} ]] || ok=0
	    fi
	    if [[ "$ok" -eq 2 ]]; then
	      import_rejections=$((import_rejections + 1))
	      gluerun_l1_lease_set_status "$node" failed 2>/dev/null || true
	      duplicate_event_json="$(gluerun_duplicate_candidate_event_json "$run_id" "$node" "$duplicate_json")"
	      gluerun_append_event "origin.l1_import_rejected" "duplicate-candidate" "$duplicate_event_json"
	      echo "duplicate-candidate node=$node existing=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("existingTaskId",""))' "$duplicate_json")"
	      continue
	    fi
	    if [[ "$ok" -ne 1 ]]; then
	      import_rejections=$((import_rejections + 1))
	      gluerun_l1_lease_set_status "$node" failed 2>/dev/null || true
      gluerun_append_event "origin.l1_import_rejected" "staged batch failed validation" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
      continue
    fi
    # Rewrite each candidate's temp id (token-safe) to its real id and VERIFY the
    # result, all BEFORE promoting any file — so a botched rewrite fails the whole
    # node with nothing left in the global tasks dir (all-or-nothing).
    local j rid mv_ok=1
    local -a moved=()
    for j in "${!src[@]}"; do
      gluerun_rewrite_task_id_token "${src[$j]}" "${temps[$j]}" "${ids[$j]}" || { ok=0; break; }
      if [[ "$(gluerun_task_field "${src[$j]}" taskId 2>/dev/null || echo '')" != "${ids[$j]}" ]]; then
        ok=0; break
      fi
    done
	    if [[ "$ok" -ne 1 ]]; then
	      import_rejections=$((import_rejections + 1))
	      gluerun_l1_lease_set_status "$node" failed 2>/dev/null || true
      gluerun_append_event "origin.l1_import_rejected" "id rewrite verification failed" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
      continue
    fi
    # Promote all-or-nothing: guard every mv so a failure mid-batch (e.g. ENOSPC)
    # never aborts the whole import under `set -e`; on failure, roll back the files
    # already promoted so a partial batch never lands in the global tasks dir, mark
    # the node failed, and move on to the next node.
    for j in "${!src[@]}"; do
      # Collision preflight: never overwrite an existing task file. With the
      # monotonic allocator this cannot happen; if it does (foreign file, clock
      # rollback), reject the batch loudly instead of destroying state.
      if [[ -e "$GLUERUN_TASKS_DIR/${ids[$j]}.md" ]]; then
        gluerun_append_event "origin.task_id_collision" "refusing to overwrite existing task file" \
          "{\"runId\":\"$run_id\",\"node\":\"$node\",\"taskId\":\"${ids[$j]}\"}"
        mv_ok=0; break
      fi
      if mv "${src[$j]}" "$GLUERUN_TASKS_DIR/${ids[$j]}.md" 2>/dev/null; then
        moved+=("${ids[$j]}")
      else
        mv_ok=0; break
      fi
    done
	    if [[ "$mv_ok" -ne 1 ]]; then
	      import_rejections=$((import_rejections + 1))
	      for rid in "${moved[@]}"; do
        rm -f "$GLUERUN_TASKS_DIR/$rid.md" 2>/dev/null || true
      done
      gluerun_l1_lease_set_status "$node" failed 2>/dev/null || true
      gluerun_append_event "origin.l1_import_rejected" "promotion failed; rolled back partial batch" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\"}"
      continue
    fi
    for rid in "${moved[@]}"; do
      gluerun_append_event "planner.generated" "task imported from l1 plan" \
        "{\"runId\":\"$run_id\",\"node\":\"$node\",\"taskId\":\"$rid\"}"
      echo "generated:$rid"
    done
	    gluerun_l1_lease_set_status "$node" released 2>/dev/null || true
	  done
	  echo "l1_import_rejections=$import_rejections"
	}

# --- Context continuity (per-attempt archives, capsules, findings ledger) ----
# Everything in this section is ADDITIVE observability: a failure here must
# never abort a drive. Callers wrap these with `|| <warning event>` guards.

gluerun_sha256_file() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

gluerun_sha256_text() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "$1"
}

# --- Session affinity / runtime resume (T-E5) --------------------------------
# Runtime session reuse is a pure OPTIMIZATION: every gate or runtime failure
# degrades to a fresh run, never changing outcomes (only token cost). The runner
# writes a session-meta JSON describing the session it just ran; the host merges
# its authority fields and decides whether the NEXT run may resume it.
#
# session-meta schema (gluerun.orchestration.session-meta.v0):
#   provider, sessionId, model, effort, cwd, exitCode, createdAt   (runner-authored)
#   role, taskId, runId, runner, promptSha256, headShaAtCreate, lastUsedAttempt
#                                                                  (host-authored)

# Runner-side meta writers (called from codex-run.sh / claude-run.sh). They emit
# ONLY the runner-authored fields; the host adds the rest via _finalize. An empty
# sessionId is normal (parse miss / no session) and tells the host to go fresh.
gluerun_session_meta_write_provider() {
  local path="$1" provider="$2" session_id="$3" model="$4" effort="$5" cwd="$6" exit_code="$7"
  [[ -n "$path" ]] || return 0
  local created; created="$(gluerun_timestamp 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 - "$path" "$provider" "$session_id" "$model" "$effort" "$cwd" "$exit_code" "$created" <<'PY' 2>/dev/null || true
import json, sys
path, provider, sid, model, effort, cwd, ec, created = sys.argv[1:9]
try:
    rc = int(ec)
except Exception:
    rc = ec
doc = {
    "schema": "gluerun.orchestration.session-meta.v0",
    "provider": provider,
    "sessionId": sid,
    "model": model,
    "effort": effort,
    "cwd": cwd,
    "exitCode": rc,
    "createdAt": created,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY
}
gluerun_codex_session_meta_write() {
  # <path> <session_id> <model> <effort> <cwd> <exit_code>
  gluerun_session_meta_write_provider "$1" "codex" "$2" "$3" "$4" "$5" "$6"
}
gluerun_claude_session_meta_write() {
  # <path> <session_id> <model> <effort> <cwd> <exit_code>
  gluerun_session_meta_write_provider "$1" "claude" "$2" "$3" "$4" "$5" "$6"
}

# sha256 of the rendered BASE prompt (reuses gluerun_sha256_file). Missing file ->
# empty (the resume decider treats an empty/mismatched sha as a fresh trigger).
gluerun_prompt_sha() {
  local prompt_file="$1"
  [[ -n "$prompt_file" && -f "$prompt_file" ]] || { printf '%s' ""; return 0; }
  gluerun_sha256_file "$prompt_file" 2>/dev/null || printf '%s' ""
}

# Merge host-authority fields into the runner-written meta. If the runner wrote
# no meta (resume unsupported / parse miss), create a minimal one with an empty
# sessionId. NEVER fails the drive.
#   gluerun_session_meta_finalize <meta_path> <role> <task_id> <run_id> \
#                              <runner_basename> <prompt_sha> <head_sha> <attempt>
gluerun_session_meta_finalize() {
  local meta_path="$1" role="$2" task_id="$3" run_id="$4" runner="$5" prompt_sha="$6" head_sha="$7" attempt="$8"
  [[ -n "$meta_path" ]] || return 0
  python3 - "$meta_path" "$role" "$task_id" "$run_id" "$runner" "$prompt_sha" "$head_sha" "$attempt" <<'PY' 2>/dev/null || true
import json, sys
(path, role, task_id, run_id, runner, prompt_sha, head_sha, attempt) = sys.argv[1:9]
doc = {}
try:
    with open(path, "r", encoding="utf-8") as f:
        loaded = json.load(f)
    if isinstance(loaded, dict):
        doc = loaded
except Exception:
    doc = {}
doc.setdefault("schema", "gluerun.orchestration.session-meta.v0")
doc.setdefault("provider", "")
doc.setdefault("sessionId", "")
doc.setdefault("model", "")
doc.setdefault("effort", "")
doc.setdefault("cwd", "")
doc.setdefault("exitCode", "")
doc.setdefault("createdAt", "")
doc["role"] = role
doc["taskId"] = task_id
doc["runId"] = run_id
doc["runner"] = runner
doc["promptSha256"] = prompt_sha
doc["headShaAtCreate"] = head_sha
try:
    doc["lastUsedAttempt"] = int(attempt)
except Exception:
    doc["lastUsedAttempt"] = attempt
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY
}

# Decide whether the next run may resume the recorded session. Prints EXACTLY one
# line: `resume <sessionId>` or `fresh <reason>`. Gates evaluate in order; the
# FIRST failure wins and its name is the reason. Per-role meta FILES make
# cross-role reuse structurally impossible; gate 4 is defense-in-depth.
#   gluerun_session_resume_decide <meta_path> <role> <task_id> <run_id> \
#       <runner_basename> <prompt_sha> <worktree> <lineage_head>
gluerun_session_resume_decide() {
  local meta_path="$1" role="$2" task_id="$3" run_id="$4" runner="$5" prompt_sha="$6" worktree="$7" lineage_head="$8"

  # Gate 1: affinity disabled.
  if [[ "${GLUERUN_SESSION_AFFINITY:-1}" != "1" ]]; then
    printf 'fresh disabled\n'; return 0
  fi
  # Gate 2: meta missing/unparseable.
  if [[ ! -f "$meta_path" ]]; then
    printf 'fresh no-session\n'; return 0
  fi
  # Parse all fields in one python pass; emit each field on its OWN line (NUL is
  # awkward in bash 3.2; newline-per-field reads cleanly into an array even with
  # empty values, which a tab-delimited `read` collapses). A parse failure ->
  # "no-session". Each field's trailing newline is what delimits it; values here
  # are session ids / shas / paths and never contain newlines.
  local parsed
  parsed="$(python3 - "$meta_path" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        m = json.load(f)
    assert isinstance(m, dict)
except Exception:
    print("__UNPARSEABLE__")
    sys.exit(0)
def g(k):
    v = m.get(k, "")
    return "" if v is None else str(v).replace("\n", " ")
for val in (g("provider"), g("sessionId"), g("role"), g("taskId"), g("runId"),
            g("runner"), g("promptSha256"), g("createdAt"), g("headShaAtCreate"), g("cwd")):
    print(val)
PY
)"
  if [[ -z "$parsed" || "$parsed" == "__UNPARSEABLE__"* ]]; then
    printf 'fresh no-session\n'; return 0
  fi
  local m_fields=()
  while IFS= read -r line; do m_fields+=("$line"); done <<<"$parsed"
  local m_provider="${m_fields[0]:-}" m_sid="${m_fields[1]:-}" m_role="${m_fields[2]:-}"
  local m_task="${m_fields[3]:-}" m_run="${m_fields[4]:-}" m_runner="${m_fields[5]:-}"
  local m_psha="${m_fields[6]:-}" m_created="${m_fields[7]:-}" m_head="${m_fields[8]:-}" m_cwd="${m_fields[9]:-}"

  # Gate 3: provider or sessionId empty.
  if [[ -z "$m_provider" || -z "$m_sid" ]]; then
    printf 'fresh no-session-id\n'; return 0
  fi
  # Gate 4: role mismatch (defense-in-depth; per-role files should prevent this).
  if [[ "$m_role" != "$role" ]]; then
    printf 'fresh role-mismatch\n'; return 0
  fi
  # Gate 5: run mismatch (task or run).
  if [[ "$m_task" != "$task_id" || "$m_run" != "$run_id" ]]; then
    printf 'fresh run-mismatch\n'; return 0
  fi
  # Gate 6: runner changed.
  if [[ "$m_runner" != "$runner" ]]; then
    printf 'fresh runner-changed\n'; return 0
  fi
  # Gate 7: prompt template changed.
  if [[ "$m_psha" != "$prompt_sha" ]]; then
    printf 'fresh prompt-template-changed\n'; return 0
  fi
  # Gate 8: expired.
  local max_age="${GLUERUN_SESSION_MAX_AGE_SEC:-14400}"
  local age_ok
  age_ok="$(python3 - "$m_created" "$max_age" <<'PY' 2>/dev/null || true
import sys
from datetime import datetime, timezone
created, max_age = sys.argv[1], sys.argv[2]
try:
    max_age = int(max_age)
except Exception:
    max_age = 14400
if not created:
    print("EXPIRED"); sys.exit(0)
s = created.strip().replace("Z", "+00:00")
try:
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
except Exception:
    print("EXPIRED"); sys.exit(0)
age = (datetime.now(timezone.utc) - dt).total_seconds()
print("OK" if age <= max_age else "EXPIRED")
PY
)"
  if [[ "$age_ok" != "OK" ]]; then
    printf 'fresh expired\n'; return 0
  fi
  # Gate 9: lineage. If headShaAtCreate is empty we have nothing to test against —
  # allow (skip lineage); a non-empty head must be an ancestor of lineage_head.
  if [[ -n "$m_head" && -n "$lineage_head" ]]; then
    if ! git -C "$worktree" merge-base --is-ancestor "$m_head" "$lineage_head" 2>/dev/null; then
      printf 'fresh head-rewritten\n'; return 0
    fi
  fi
  # Gate 10: worktree moved.
  if [[ "$m_cwd" != "$worktree" ]]; then
    printf 'fresh worktree-moved\n'; return 0
  fi

  printf 'resume %s\n' "$m_sid"
}

# Stable finding identity: "f-" + first 12 hex chars of sha256 over the
# normalized text (backticks stripped, lowercased, whitespace collapsed to
# single spaces, trimmed) — so re-reports that differ only in formatting map to
# the same finding.
gluerun_finding_id() {
  python3 -c '
import hashlib, sys
text = sys.argv[1].replace("`", "").lower()
text = " ".join(text.split())
print("f-" + hashlib.sha256(text.encode("utf-8")).hexdigest()[:12])
' "$1"
}

# Per-attempt artifact archive (T-E1). Copies the attempt's mutable run-dir ROOT
# artifacts into <run_dir>/attempts/<n>/ (root files are never moved/renamed;
# the console keeps parsing them at the root) and upserts attempts/index.json.
#   gluerun_attempt_archive <run_dir> <n> <failure_class> <verdict> <head_sha> <decider_action> <authority>
# failure_class empty == accepted attempt (failure.txt records "accepted").
# Optional caller-provided globals: GLUERUN_ATTEMPT_TASK_ID (else packet.json's
# taskId), GLUERUN_ATTEMPT_STARTED_AT (else archive time).
gluerun_attempt_archive() {
  local run_dir="$1" n="$2" failure_class="$3" verdict="$4" head_sha="$5"
  local decider_action="$6" authority="$7"
  local dest="$run_dir/attempts/$n"
  mkdir -p "$dest"
  local f
  for f in l2-active-prompt.md auditor-active-prompt.md last-message.json packet.json worker-codex.log \
           scope-check.log gate-check.json gate-check.log secret-scan.log audit.json; do
    if [[ -f "$run_dir/$f" ]]; then cp "$run_dir/$f" "$dest/$f"; fi
  done
  for f in "$run_dir"/decision-*.json; do
    if [[ -f "$f" ]]; then cp "$f" "$dest/"; fi
  done
  printf '%s\n' "${failure_class:-accepted}" >"$dest/failure.txt"

  local run_id task_id started ended
  run_id="$(basename "$run_dir")"
  ended="$(gluerun_timestamp)"
  started="${GLUERUN_ATTEMPT_STARTED_AT:-$ended}"
  task_id="${GLUERUN_ATTEMPT_TASK_ID:-}"
  if [[ -z "$task_id" && -f "$run_dir/packet.json" ]]; then
    task_id="$(gluerun_json_field "$run_dir/packet.json" taskId 2>/dev/null || true)"
  fi
  python3 - "$run_dir/attempts/index.json" "$run_id" "$task_id" "$n" "$started" "$ended" \
    "$failure_class" "$verdict" "$head_sha" "$decider_action" "$authority" \
    "${GLUERUN_ATTEMPT_WORKER_STRATEGY:-}" "${GLUERUN_ATTEMPT_REVIEWER_STRATEGY:-}" <<'PY'
import json
import os
import sys

(path, run_id, task_id, n_raw, started, ended,
 failure_class, verdict, head_sha, decider_action, authority,
 worker_strategy, reviewer_strategy) = sys.argv[1:14]
n = int(n_raw)
data = {
    "schema": "gluerun.orchestration.attempts-index.v0",
    "runId": run_id,
    "taskId": task_id,
    "attempts": [],
    "updatedAt": ended,
}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            prev = json.load(f)
        if isinstance(prev.get("attempts"), list):
            data["attempts"] = [a for a in prev["attempts"] if isinstance(a, dict)]
        if not task_id:
            data["taskId"] = str(prev.get("taskId", ""))
    except Exception:
        pass
entry = {
    "n": n,
    "startedAt": started,
    "endedAt": ended,
    "failureClass": failure_class,
    "auditVerdict": verdict,
    "headSha": head_sha,
    "deciderAction": decider_action,
    "deciderAuthority": authority,
    "dir": f"attempts/{n}",
}
# Session-affinity strategy (T-E5): ADDITIVE index fields. Only emitted when the
# driver provided a strategy, so the existing index schema/shape is unchanged for
# any caller that doesn't set them.
if worker_strategy:
    entry["workerStrategy"] = worker_strategy
if reviewer_strategy:
    entry["reviewerStrategy"] = reviewer_strategy
attempts = [a for a in data["attempts"] if a.get("n") != n]
attempts.append(entry)
attempts.sort(key=lambda a: a.get("n", 0))
data["attempts"] = attempts
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  gluerun_append_event "l1.attempt_archived" "attempt artifacts archived" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"n\":$n,\"failureClass\":\"$failure_class\",\"verdict\":\"$verdict\"}" \
    2>/dev/null || true
}

# Implementer context capsule: a compact, hash-stamped summary of what the
# worker attempt produced, for later-wave session resume / fix prompts.
#   gluerun_capsule_write_implementer <run_dir> <n> <packet_json_path> <head_sha> <owned_json> <forbidden_json>
# ownedFiles/forbiddenFiles come from the ARGV (the driver's CURRENT post-amend
# scope), never from the packet. Every list is capped at 20 items. contentHash
# is sha256 over the canonical JSON (sorted keys, no whitespace) EXCLUDING
# createdAt/contentHash/packetSha256.
gluerun_capsule_write_implementer() {
  local run_dir="$1" n="$2" packet_path="$3" head_sha="$4" owned_json="$5" forbidden_json="$6"
  python3 - "$run_dir" "$n" "$packet_path" "$head_sha" "$owned_json" "$forbidden_json" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone

run_dir, n_raw, packet_path, head_sha, owned_raw, forbidden_raw = sys.argv[1:7]

def parse_list(raw):
    try:
        value = json.loads(raw)
        return value if isinstance(value, list) else []
    except Exception:
        return []

try:
    with open(packet_path, "r", encoding="utf-8") as f:
        packet = json.load(f)
    if not isinstance(packet, dict):
        packet = {}
except Exception:
    packet = {}

def plist(key):
    value = packet.get(key)
    return value if isinstance(value, list) else []

def cap(items):
    return items[:20]

with open(packet_path, "rb") as f:
    packet_sha = hashlib.sha256(f.read()).hexdigest()

capsule = {
    "schema": "gluerun.orchestration.context-capsule.v0",
    "role": "implementer",
    "taskId": str(packet.get("taskId", "")),
    "runId": str(packet.get("runId", "")),
    "attempt": int(n_raw),
    "headSha": head_sha,
    "baseRef": str(packet.get("baseRef", "")),
    "branch": str(packet.get("branch", "")),
    "ownedFiles": cap(parse_list(owned_raw)),
    "forbiddenFiles": cap(parse_list(forbidden_raw)),
    "changedFiles": cap(plist("changedFiles")),
    "commands": cap(plist("commands")),
    "tests": cap(plist("tests")),
    "blockers": cap(plist("blockers")),
    "nextAction": str(packet.get("nextAction", "")),
    "packetSha256": packet_sha,
}
hashable = {k: v for k, v in capsule.items() if k not in ("createdAt", "contentHash", "packetSha256")}
canonical = json.dumps(hashable, sort_keys=True, separators=(",", ":"))
capsule["contentHash"] = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
capsule["createdAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
with open(f"{run_dir}/implementer-capsule.json", "w", encoding="utf-8") as f:
    json.dump(capsule, f, indent=2)
    f.write("\n")
PY
}

# Reviewer context capsule: what the auditor reviewed and concluded.
#   gluerun_capsule_write_reviewer <run_dir> <n> <audit_json_path> <prior_head> <new_head>
# diffRange is "" on attempt 1 (empty prior_head). Tolerates junk/partial
# verdict JSON (auditors emit junk) — missing/odd fields degrade to empty
# values, never a crash. rationale is capped at 1500 chars.
gluerun_capsule_write_reviewer() {
  local run_dir="$1" n="$2" audit_path="$3" prior_head="$4" new_head="$5"
  python3 - "$run_dir" "$n" "$audit_path" "$prior_head" "$new_head" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone

run_dir, n_raw, audit_path, prior_head, new_head = sys.argv[1:6]

try:
    with open(audit_path, "r", encoding="utf-8") as f:
        audit = json.load(f)
    if not isinstance(audit, dict):
        audit = {}
except Exception:
    audit = {}

def alist(key):
    value = audit.get(key)
    if not isinstance(value, list):
        return []
    return [str(item) for item in value]

def finding_id(text):
    norm = " ".join(str(text).replace("`", "").lower().split())
    return "f-" + hashlib.sha256(norm.encode("utf-8")).hexdigest()[:12]

finding_ids = []
for text in alist("findings") + alist("requiredFixes"):
    fid = finding_id(text)
    if fid not in finding_ids:
        finding_ids.append(fid)

try:
    with open(audit_path, "rb") as f:
        audit_sha = hashlib.sha256(f.read()).hexdigest()
except Exception:
    audit_sha = ""

task_id = str(audit.get("taskId", "") or "")
run_id = str(audit.get("runId", "") or "")
if not task_id or not run_id:
    try:
        with open(f"{run_dir}/packet.json", "r", encoding="utf-8") as f:
            packet = json.load(f)
        task_id = task_id or str(packet.get("taskId", ""))
        run_id = run_id or str(packet.get("runId", ""))
    except Exception:
        pass

capsule = {
    "schema": "gluerun.orchestration.context-capsule.v0",
    "role": "reviewer",
    "taskId": task_id,
    "runId": run_id,
    "attempt": int(n_raw),
    "verdict": str(audit.get("verdict", "") or ""),
    "auditedHeadSha": new_head,
    "diffRange": f"{prior_head}..{new_head}" if prior_head else "",
    "findingIds": finding_ids,
    "evidenceReviewed": alist("evidenceReviewed"),
    "commandsRun": alist("commandsRun"),
    "rationale": str(audit.get("rationale", "") or "")[:1500],
    "auditSha256": audit_sha,
    "createdAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
with open(f"{run_dir}/reviewer-capsule.json", "w", encoding="utf-8") as f:
    json.dump(capsule, f, indent=2)
    f.write("\n")
PY
}

# Findings ledger: upsert <run_dir>/findings-status.json from one audit verdict.
#   gluerun_findings_ledger_update <run_dir> <n> <audit_json_path>
# Rules, in order:
#   1. every findings[]/requiredFixes[] string in the new audit is upserted by
#      id (lastSeenAttempt bumped); a previously RESOLVED finding that is
#      re-reported is REOPENED (resolvedAttempt/resolvedBy cleared);
#   2. a verdict findingsStatus object ({id: "resolved"|"still-open"}) is
#      applied: resolved -> status=resolved, resolvedAttempt=n,
#      resolvedBy="auditor-status";
#   3. verdict "accepted" resolves ALL open findings (resolvedBy
#      "audit-accepted");
#   4. absence alone never resolves anything.
# Echoes "open=K resolved=K new=K" on stdout; the caller emits the
# findings.ledger_updated event from those counts.
gluerun_findings_ledger_update() {
  local run_dir="$1" n="$2" audit_path="$3"
  python3 - "$run_dir" "$n" "$audit_path" <<'PY'
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

run_dir, n_raw, audit_path = sys.argv[1:4]
n = int(n_raw)
ledger_path = os.path.join(run_dir, "findings-status.json")

try:
    with open(audit_path, "r", encoding="utf-8") as f:
        audit = json.load(f)
    if not isinstance(audit, dict):
        audit = {}
except Exception:
    audit = {}

def alist(key):
    value = audit.get(key)
    if not isinstance(value, list):
        return []
    return [str(item) for item in value]

def finding_id(text):
    norm = " ".join(str(text).replace("`", "").lower().split())
    return "f-" + hashlib.sha256(norm.encode("utf-8")).hexdigest()[:12]

ledger = {}
if os.path.exists(ledger_path):
    try:
        with open(ledger_path, "r", encoding="utf-8") as f:
            ledger = json.load(f)
        if not isinstance(ledger, dict):
            ledger = {}
    except Exception:
        ledger = {}

task_id = str(audit.get("taskId", "") or ledger.get("taskId", "") or "")
run_id = str(audit.get("runId", "") or ledger.get("runId", "") or os.path.basename(run_dir.rstrip("/")))
findings = [f for f in ledger.get("findings", []) if isinstance(f, dict)] if isinstance(ledger.get("findings"), list) else []
by_id = {f.get("id"): f for f in findings if f.get("id")}

new_count = 0
# Rule 1: upsert every reported finding/requiredFix; reopen if resolved.
for source, key in (("finding", "findings"), ("requiredFix", "requiredFixes")):
    for text in alist(key):
        fid = finding_id(text)
        entry = by_id.get(fid)
        if entry is None:
            entry = {
                "id": fid,
                "text": str(text),
                "source": source,
                "status": "open",
                "firstSeenAttempt": n,
                "lastSeenAttempt": n,
                "resolvedAttempt": None,
                "resolvedBy": None,
            }
            findings.append(entry)
            by_id[fid] = entry
            new_count += 1
        else:
            entry["lastSeenAttempt"] = n
            if entry.get("status") == "resolved":
                entry["status"] = "open"
                entry["resolvedAttempt"] = None
                entry["resolvedBy"] = None

# Rule 2: explicit auditor findingsStatus map.
status_map = audit.get("findingsStatus")
if isinstance(status_map, dict):
    for fid, state in status_map.items():
        entry = by_id.get(str(fid))
        if entry is None:
            continue
        if str(state) == "resolved":
            entry["status"] = "resolved"
            entry["resolvedAttempt"] = n
            entry["resolvedBy"] = "auditor-status"

# Rule 3: an accepted verdict resolves everything still open.
if str(audit.get("verdict", "")) == "accepted":
    for entry in findings:
        if entry.get("status") == "open":
            entry["status"] = "resolved"
            entry["resolvedAttempt"] = n
            entry["resolvedBy"] = "audit-accepted"

now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
out = {
    "schema": "gluerun.orchestration.findings-ledger.v0",
    "taskId": task_id,
    "runId": run_id,
    "findings": findings,
    "updatedAt": now,
}
with open(ledger_path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
open_count = sum(1 for f in findings if f.get("status") == "open")
resolved_count = sum(1 for f in findings if f.get("status") == "resolved")
print(f"open={open_count} resolved={resolved_count} new={new_count}")
PY
}

# Structured fix prompt (T-E3). Renders <base_prompt> + appended retry sections
# (scope / authoritative findings / class-scoped evidence / LOW-authority prior
# summary) into <out_path>. Findings come ONLY from open ledger entries; if the
# ledger is missing/empty AND failure_class starts with "audit-", the legacy
# attempt_ctx tail is folded into the Evidence section as a fallback.
#   gluerun_render_fix_prompt <out> <base_prompt> <run_dir> <n> <failure_class> \
#     <attempt_ctx_file> <owned_json> <forbidden_json>
# Returns nonzero on any rendering error (caller falls back to legacy fix_hints).
gluerun_render_fix_prompt() {
  local out_path="$1" base_prompt="$2" run_dir="$3" n="$4" failure_class="$5"
  local attempt_ctx="$6" owned_json="$7" forbidden_json="$8"
  local gate_log="$run_dir/gate-check.log"
  local scope_log="$run_dir/scope-check.log"
  local capsule="$run_dir/implementer-capsule.json"
  local ledger="$run_dir/findings-status.json"
  python3 - "$out_path" "$base_prompt" "$ledger" "$capsule" "$n" "$failure_class" \
    "$attempt_ctx" "$gate_log" "$scope_log" "$owned_json" "$forbidden_json" \
    "$GLUERUN_CONTEXT_SECTION_MAX_CHARS" <<'PY'
import json
import os
import sys

(out_path, base_prompt, ledger_path, capsule_path, n_raw, failure_class,
 attempt_ctx, gate_log, scope_log, owned_raw, forbidden_raw, cap_raw) = sys.argv[1:13]
n = int(n_raw)
cap = int(cap_raw)
prev = n - 1
TRUNC = "\n[... section truncated to fit the context budget ...]"

def section_cap(text):
    if len(text) <= cap:
        return text
    keep = max(0, cap - len(TRUNC))
    return text[:keep] + TRUNC

def parse_list(raw):
    try:
        v = json.loads(raw)
        return [str(x) for x in v] if isinstance(v, list) else []
    except Exception:
        return []

def tail_chars(path, nbytes):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()[-nbytes:]
    except Exception:
        return ""

def tail_lines(path, count):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        return "\n".join(lines[-count:])
    except Exception:
        return ""

def scope_disallowed_block(path):
    # Extract the "disallowed paths:" block emitted by scope-check.sh, up to the
    # next "allowed prefixes:"/"forbidden prefixes:" header (forbidden-paths
    # block included when present).
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except Exception:
        return ""
    out, capture = [], False
    for line in lines:
        s = line.strip()
        if s.startswith("scope check failed; forbidden paths touched:") or \
           s.startswith("scope check failed; disallowed paths:"):
            capture = True
            out.append(line)
            continue
        if capture:
            if s.startswith("allowed prefixes:") or s.startswith("forbidden prefixes:"):
                break
            out.append(line)
    return "\n".join(out).strip()

with open(base_prompt, "r", encoding="utf-8") as f:
    base = f.read()

# --- Open findings from the ledger -------------------------------------------
open_findings = []
ledger_present = False
try:
    with open(ledger_path, "r", encoding="utf-8") as f:
        ledger = json.load(f)
    if isinstance(ledger, dict) and isinstance(ledger.get("findings"), list):
        ledger_present = True
        for entry in ledger["findings"]:
            if isinstance(entry, dict) and entry.get("status") == "open":
                open_findings.append(entry)
except Exception:
    ledger_present = False
open_findings.sort(key=lambda e: (e.get("firstSeenAttempt") or 0, str(e.get("id"))))

owned = parse_list(owned_raw)
forbidden = parse_list(forbidden_raw)

parts = []
parts.append(base.rstrip("\n"))
parts.append("")
parts.append(f"## Previous-attempt feedback (attempt {prev} failed: {failure_class})")
parts.append("")
parts.append("### Current scope (authoritative — supersedes the scope listed above if different)")
parts.append("Owned: " + (", ".join(owned) if owned else "(none)"))
parts.append("Forbidden: " + (", ".join(forbidden) if forbidden else "(none)"))
parts.append("")

# --- Authoritative findings ---------------------------------------------------
parts.append("### Authoritative findings — fix ALL of these (open items from the findings ledger)")
if open_findings:
    lines = []
    for e in open_findings:
        text = str(e.get("text", ""))[:500]
        lines.append(f"- [from attempt {e.get('firstSeenAttempt')}] ({e.get('id')}) {text}")
    parts.append(section_cap("\n".join(lines)))
else:
    parts.append("(no open ledger findings recorded)")
parts.append("")

# --- Evidence (class-scoped) --------------------------------------------------
parts.append("### Evidence (host logs, informational)")
if failure_class == "gate-red":
    evidence = tail_lines(gate_log, 40)
elif failure_class == "scope-violation":
    evidence = scope_disallowed_block(scope_log)
elif failure_class == "packet-invalid":
    evidence = tail_lines(attempt_ctx, 40)
else:
    evidence = tail_lines(attempt_ctx, 30)
# Fallback: empty/missing ledger AND an audit-* failure -> fold in the ctx tail.
if (not ledger_present or not open_findings) and failure_class.startswith("audit-"):
    legacy = tail_chars(attempt_ctx, 3000)
    if legacy:
        evidence = (evidence + "\n" + legacy) if evidence else legacy
parts.append(section_cap(evidence) if evidence else "(no evidence captured)")
parts.append("")

# --- Prior implementer summary (LOW authority) -------------------------------
capsule = None
try:
    with open(capsule_path, "r", encoding="utf-8") as f:
        c = json.load(f)
    if isinstance(c, dict):
        capsule = c
except Exception:
    capsule = None
if capsule is not None:
    parts.append("### Prior implementer summary (LOW authority — may be stale or wrong; trust the findings and the code)")
    parts.append("nextAction: " + str(capsule.get("nextAction", "")))
    blockers = capsule.get("blockers") if isinstance(capsule.get("blockers"), list) else []
    parts.append("blockers: " + (", ".join(str(b) for b in blockers[:5]) if blockers else "(none)"))
    changed = capsule.get("changedFiles") if isinstance(capsule.get("changedFiles"), list) else []
    parts.append("changedFiles: " + (", ".join(str(x) for x in changed[:20]) if changed else "(none)"))
    parts.append("")

parts.append("Address every Authoritative finding; do not relitigate resolved ones; stay in scope.")

with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(parts) + "\n")
PY
}

# Re-audit delta prompt (T-E4). Renders <base_audit_prompt> + re-audit context
# (prior findings/ledger status + fix diff since the auditor's last review +
# per-id verification targets + a findingsStatus output-contract addition) into
# <out_path>. n==1, missing reviewer capsule, or empty prior_head -> plain copy
# (byte-identical to the base audit prompt).
#   gluerun_render_reaudit_prompt <out> <base_audit_prompt> <run_dir> <n> \
#     <prior_head> <new_head> <worktree>
# Returns nonzero on rendering error (caller falls back to the base audit prompt).
gluerun_render_reaudit_prompt() {
  local out_path="$1" base_prompt="$2" run_dir="$3" n="$4" prior_head="$5"
  local new_head="$6" worktree="$7"
  local capsule="$run_dir/reviewer-capsule.json"
  local ledger="$run_dir/findings-status.json"
  if [[ "$n" -lt 2 || ! -f "$capsule" || -z "$prior_head" ]]; then
    cp "$base_prompt" "$out_path"
    return 0
  fi

  # Diff only when prior_head is a genuine ancestor of new_head; otherwise history
  # was rewritten (amend/rebase) and a range diff would be meaningless.
  local ancestry_ok="no" stat_out="" diff_out=""
  if git -C "$worktree" merge-base --is-ancestor "$prior_head" "$new_head" 2>/dev/null; then
    ancestry_ok="yes"
    stat_out="$(git -C "$worktree" diff --stat "$prior_head..$new_head" 2>/dev/null || true)"
    diff_out="$(git -C "$worktree" diff "$prior_head..$new_head" 2>/dev/null || true)"
  fi

  GLUERUN_REAUDIT_STAT="$stat_out" GLUERUN_REAUDIT_DIFF="$diff_out" \
  python3 - "$out_path" "$base_prompt" "$ledger" "$n" "$prior_head" "$new_head" "$ancestry_ok" <<'PY'
import json
import os
import sys

(out_path, base_prompt, ledger_path, n_raw, prior_head, new_head, ancestry_ok) = sys.argv[1:8]
DIFF_CAP = 12000
TRUNC = "\n[diff truncated to fit the context budget...]"

with open(base_prompt, "r", encoding="utf-8") as f:
    base = f.read()

findings = []
try:
    with open(ledger_path, "r", encoding="utf-8") as f:
        ledger = json.load(f)
    if isinstance(ledger, dict) and isinstance(ledger.get("findings"), list):
        findings = [e for e in ledger["findings"] if isinstance(e, dict)]
except Exception:
    findings = []
# Open first, then resolved; stable by id within each group.
findings.sort(key=lambda e: (0 if e.get("status") == "open" else 1, str(e.get("id"))))
open_findings = [e for e in findings if e.get("status") == "open"]

parts = [base.rstrip("\n"), ""]
parts.append(f"## Re-audit context (attempt {n_raw}; you previously audited {prior_head})")
parts.append("")
parts.append("### Your prior findings and current ledger status (authoritative)")
if findings:
    for e in findings:
        state = "open" if e.get("status") == "open" else "resolved"
        parts.append(f"- ({e.get('id')}) [{state}] {str(e.get('text', ''))}")
else:
    parts.append("(no ledger findings recorded)")

if ancestry_ok == "yes":
    stat = os.environ.get("GLUERUN_REAUDIT_STAT", "")
    diff = os.environ.get("GLUERUN_REAUDIT_DIFF", "")
    if len(diff) > DIFF_CAP:
        diff = diff[:max(0, DIFF_CAP - len(TRUNC))] + TRUNC
    parts.append(f"### Fix diff since your last audit ({prior_head}..{new_head})")
    parts.append(stat)
    parts.append(diff)
else:
    parts.append(
        f"History was rewritten since your last audit ({prior_head} is not an "
        f"ancestor of {new_head}); perform a full review of the current branch state."
    )

parts.append("### Verification targets")
parts.append("Verify each of these open finding ids is resolved by this diff; report per-id status:")
if open_findings:
    for e in open_findings:
        parts.append(f"- {e.get('id')}: {str(e.get('text', ''))[:200]}")
else:
    parts.append("(no open findings to verify)")

parts.append("### Output contract addition")
parts.append(
    'In addition to the audit-verdict fields, include an optional field '
    '"findingsStatus": an object mapping finding id -> "resolved" | "still-open" '
    "for every verification target above."
)

with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(parts) + "\n")
PY
}

# --- Kill switch + circuit breaker ---

gluerun_stop_requested() {
  [[ -f "$GLUERUN_STOP_FILE" ]]
}

gluerun_wake_file() {
  printf '%s' "${GLUERUN_WAKE_FILE:-$GLUERUN_STATE_DIR/WAKE}"
}

# Interruptible nap: sleeps `total` seconds in GLUERUN_SLEEP_POLL_SEC chunks,
# checking control files between chunks so a nap never outlives operator intent.
# Returns: 0 = slept the full duration; 1 = woken early (WAKE file consumed, or
# — with watch_backoff=1 — the planner backoff was cleared/expired); 2 = STOP.
# Never signal/kill sleep children to wake the loop: touch the WAKE file
# (gluerun wake) instead.
gluerun_interruptible_sleep() {
  local total="$1" watch_backoff="${2:-0}"
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  local poll="${GLUERUN_SLEEP_POLL_SEC:-10}"
  [[ "$poll" =~ ^[0-9]+$ && "$poll" -ge 1 ]] || poll=10
  local wake slept=0 chunk
  wake="$(gluerun_wake_file)"
  while (( slept < total )); do
    chunk=$(( total - slept < poll ? total - slept : poll ))
    sleep "$chunk"
    slept=$((slept + chunk))
    if gluerun_stop_requested; then
      return 2
    fi
    if [[ -f "$wake" ]]; then
      rm -f "$wake" 2>/dev/null || true
      return 1
    fi
    if [[ "$watch_backoff" == "1" ]] && ! gluerun_planner_backoff_active_json >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

gluerun_request_wake() {
  gluerun_ensure_state_dirs
  local wake
  wake="$(gluerun_wake_file)"
  : >"$wake"
  gluerun_append_event "autonomate.wake_requested" "operator requested wake" "{}"
  echo "wake requested ($wake)"
}

gluerun_breaker_count() {
  [[ -f "$GLUERUN_BREAKER_FILE" ]] || { echo 0; return 0; }
  gluerun_json_field "$GLUERUN_BREAKER_FILE" consecFails 2>/dev/null || echo 0
}

gluerun_breaker_reset() {
  gluerun_ensure_state_dirs
  printf '{"consecFails":0,"updatedAt":"%s"}\n' "$(gluerun_timestamp)" >"$GLUERUN_BREAKER_FILE"
}

# Increment the consecutive-failure counter; echo the new value.
gluerun_breaker_trip() {
  gluerun_ensure_state_dirs
  python3 - "$GLUERUN_BREAKER_FILE" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
path = sys.argv[1]
n = 0
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            n = int(json.load(f).get("consecFails", 0))
    except Exception:
        n = 0
n += 1
with open(path, "w", encoding="utf-8") as f:
    json.dump({"consecFails": n, "updatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")}, f)
    f.write("\n")
print(n)
PY
}

# Write a human-readable STATUS report (the thing the user reads after ~20h).
gluerun_write_status() {
  # args: iteration note
  local iteration="${1:-0}" note="${2:-}"
  gluerun_ensure_state_dirs
  local branch head ready active imported integrated decisions parked breaker stop
  branch="$(gluerun_current_branch 2>/dev/null || echo '?')"
  head="$(git -C "$GLUERUN_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
  ready="$(gluerun_list_ready_tasks 2>/dev/null | wc -l | tr -d ' ')"
  active="$(gluerun_active_lease_count 2>/dev/null || echo 0)"
  imported="$(gluerun_count_files "$GLUERUN_ORCH_DIR/packets/imported" -name '*.json' -not -name '*.audit.json')"
  integrated="$(grep -c '"integration.integrated"' "$GLUERUN_EVENTS_FILE" 2>/dev/null || echo 0)"
  parked="$(grep -c '"escalate-parked"\|"decider.parked"' "$GLUERUN_EVENTS_FILE" 2>/dev/null || echo 0)"
  breaker="$(gluerun_breaker_count)"
  stop="no"; gluerun_stop_requested && stop="yes"
  {
    echo "# gluerun Autonomous Status"
    echo ""
    echo "Updated: $(gluerun_timestamp)"
    echo "Generated by: reconcile iteration $iteration (pid $$) — snapshot as of the"
    echo "last cycle; may be stale while the loop idles. Live view: \`gluerun health\`."
    echo "Iteration: $iteration"
    echo "Note: ${note:-(running)}"
    echo "STOP requested: $stop"
    echo ""
    echo "- branch: \`$branch\` @ \`$head\`"
    echo "- ready tasks: $ready"
    echo "- active leases: $active"
    echo "- imported packets: $imported"
    echo "- integrations (lifetime): $integrated"
    echo "- parked escalations (lifetime): $parked"
    echo "- circuit-breaker consecutive failures: $breaker / ${GLUERUN_MAX_CONSEC_FAILS}"
    echo ""
    echo "## Recent decisions"
    echo ""
    grep '"decision.recorded"\|"decider.' "$GLUERUN_EVENTS_FILE" 2>/dev/null | tail -10 \
      | python3 -c 'import json,sys
for l in sys.stdin:
    try:
        e=json.loads(l); d=e.get("data",{})
        print("- %s  %s  %s" % (e.get("ts",""), e.get("type",""), json.dumps(d)))
    except Exception: pass' || true
    echo ""
    echo "## Recent events"
    echo ""
    tail -15 "$GLUERUN_EVENTS_FILE" 2>/dev/null | python3 -c 'import json,sys
for l in sys.stdin:
    try:
        e=json.loads(l); print("- %s  %s  %s" % (e.get("ts",""), e.get("type",""), e.get("message","")))
    except Exception: pass' || true
  } >"$GLUERUN_STATUS_FILE"
}

# Set the Status: header of a task markdown file in place.
gluerun_task_set_status() {
  local task_file="$1" status="$2"
  python3 - "$task_file" "$status" <<'PY'
import os
import re
import sys

path, status = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines(keepends=True)
out = []
done = False
in_header = True
for line in lines:
    if line.startswith("## "):
        in_header = False
    if in_header and not done and re.match(r"^Status:\s*", line):
        out.append(f"Status: {status}\n")
        done = True
    else:
        out.append(line)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write("".join(out))
os.replace(tmp, path)
PY
}

# Count leases whose status is an active/in-flight value.
gluerun_active_lease_count() {
  [[ -d "$GLUERUN_LEASES_DIR" ]] || { echo 0; return 0; }
  python3 - "$GLUERUN_LEASES_DIR" <<'PY'
import json
import os
import sys

leases_dir = sys.argv[1]
active = {"running", "planned", "needs-review"}
count = 0
try:
    names = sorted(os.listdir(leases_dir))
except OSError:
    print(0)
    raise SystemExit(0)
for name in names:
    if not name.endswith(".json"):
        continue
    path = os.path.join(leases_dir, name)
    if not os.path.isfile(path):
        continue
    try:
        with open(path, "r", encoding="utf-8") as f:
            status = json.load(f).get("status", "")
    except Exception:
        continue
    if status in active:
        count += 1
print(count)
PY
}

# Count git worktrees other than the primary repo worktree.
gluerun_extra_worktree_count() {
  git -C "$GLUERUN_ROOT" worktree list --porcelain \
    | awk -v root="$GLUERUN_ROOT" '/^worktree / {p=substr($0,10); if (p != root) c++} END {print c+0}'
}

# True (0) if a worktree path is registered with git.
gluerun_worktree_registered() {
  local path="$1"
  git -C "$GLUERUN_ROOT" worktree list --porcelain \
    | awk -v p="$path" '/^worktree / {if (substr($0,10) == p) found=1} END {exit found?0:1}'
}

gluerun_worktree_provision() {
  local worktree="$1" run_dir="${2:-}"
  local specs="${GLUERUN_PROVISION_FILES_JSON:-[]}"
  local allow="${GLUERUN_ENV_ALLOWLIST_JSON:-[]}"
  python3 - "$GLUERUN_ROOT" "$worktree" "$run_dir" "$specs" "$allow" <<'PY'
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
worktree = pathlib.Path(sys.argv[2]).resolve()
run_dir = pathlib.Path(sys.argv[3]).resolve() if sys.argv[3] else None
specs_raw, allow_raw = sys.argv[4], sys.argv[5]

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(2)

def load_list(raw, label):
    try:
        value = json.loads(raw or "[]")
    except Exception as exc:
        fail(f"{label} must be JSON: {exc}")
    if not isinstance(value, list):
        fail(f"{label} must be an array")
    return value

def clean_rel(value, label):
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty relative path")
    p = pathlib.PurePosixPath(value)
    if p.is_absolute() or any(part in ("", ".", "..") for part in p.parts):
        fail(f"{label} must be a clean relative path: {value!r}")
    return value

def under(base, path):
    try:
        path.relative_to(base)
        return True
    except ValueError:
        return False

def git_ignored(cwd, rel):
    return subprocess.run(
        ["git", "-C", str(cwd), "check-ignore", "-q", "--", rel],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0

specs = load_list(specs_raw, "provisionFiles")
allowlist = load_list(allow_raw, "envAllowlist")
copied = []
for idx, item in enumerate(specs):
    if not isinstance(item, dict):
        fail(f"provisionFiles[{idx}] must be an object")
    source = clean_rel(item.get("source"), f"provisionFiles[{idx}].source")
    target = clean_rel(item.get("target"), f"provisionFiles[{idx}].target")
    required = bool(item.get("required", False))
    src = root / source
    dst = worktree / target
    if not src.exists():
        if required:
            fail(f"required provision file missing: {source}")
        continue
    resolved = src.resolve()
    if not under(root, resolved):
        fail(f"provision source escapes repo: {source}")
    if not src.is_file():
        fail(f"provision source is not a file: {source}")
    if not git_ignored(root, source):
        fail(f"provision source is not gitignored: {source}")
    if not git_ignored(worktree, target):
        fail(f"provision target is not gitignored in worktree: {target}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    copied.append({"source": source, "target": target})

env_written = ""
if allowlist:
    name_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
    exact = set()
    prefixes = []
    for idx, pattern in enumerate(allowlist):
        if not isinstance(pattern, str) or not pattern:
            fail(f"envAllowlist[{idx}] must be a non-empty string")
        if pattern.endswith("*"):
            prefix = pattern[:-1]
            if not prefix or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", prefix):
                fail(f"envAllowlist[{idx}] has invalid prefix pattern: {pattern!r}")
            prefixes.append(prefix)
        else:
            if not name_re.match(pattern):
                fail(f"envAllowlist[{idx}] has invalid env name: {pattern!r}")
            exact.add(pattern)
    env_rel = ".gluerun-state/worktree-env.sh"
    if not git_ignored(worktree, env_rel):
        fail(f"worktree env file target is not gitignored: {env_rel}")
    env_path = worktree / env_rel
    env_path.parent.mkdir(parents=True, exist_ok=True)
    names = []
    for name in sorted(os.environ):
        if name in exact or any(name.startswith(prefix) for prefix in prefixes):
            if name_re.match(name):
                names.append(name)
    with open(env_path, "w", encoding="utf-8") as f:
        f.write("# generated by gluerun; sourced only for worktree prewarm/gate phases\n")
        for name in names:
            f.write(f"export {name}={shlex.quote(os.environ[name])}\n")
    env_written = str(env_path)

if run_dir:
    run_dir.mkdir(parents=True, exist_ok=True)
    with open(run_dir / "worktree-provision.json", "w", encoding="utf-8") as f:
        json.dump({"copied": copied, "envFile": env_written}, f, indent=2)
        f.write("\n")
print(json.dumps({"copied": copied, "envFile": env_written}, separators=(",", ":")))
PY
  local env_file="$worktree/.gluerun-state/worktree-env.sh"
  if [[ -f "$env_file" ]]; then
    export GLUERUN_WORKTREE_ENV_FILE="$env_file"
  fi
}

gluerun_worktree_env_configured() {
  [[ -n "${GLUERUN_ENV_ALLOWLIST_JSON:-}" && "${GLUERUN_ENV_ALLOWLIST_JSON:-[]}" != "[]" ]]
}

gluerun_run_in_worktree_env() {
  local worktree="$1"
  shift
  if gluerun_worktree_env_configured && [[ -n "${GLUERUN_WORKTREE_ENV_FILE:-}" && -f "$GLUERUN_WORKTREE_ENV_FILE" ]]; then
    (
      cd "$worktree"
      env -i \
        HOME="${HOME:-}" \
        PATH="${PATH:-/usr/bin:/bin}" \
        TMPDIR="${TMPDIR:-/tmp}" \
        SHELL="${SHELL:-/bin/sh}" \
        GLUERUN_ROOT="$GLUERUN_ROOT" \
        GLUERUN_STATE_DIR="$GLUERUN_STATE_DIR" \
        GLUERUN_ENGINE_HOME="$GLUERUN_ENGINE_HOME" \
        GLUERUN_WORKTREE_ENV_FILE="$GLUERUN_WORKTREE_ENV_FILE" \
        bash -c 'set -a; . "$GLUERUN_WORKTREE_ENV_FILE"; set +a; exec "$@"' bash "$@"
    )
  else
    ( cd "$worktree" && GLUERUN_ROOT="$GLUERUN_ROOT" GLUERUN_STATE_DIR="$GLUERUN_STATE_DIR" "$@" )
  fi
}

# Append a recovery event with the fields required by operating-model section 13.
gluerun_record_recovery() {
  # args: failure taskId branch strategy authority expectedEvidence nextOwner
  local failure="$1" task_id="$2" branch="$3" strategy="$4"
  local authority="${5:-origin}" expected="${6:-}" next_owner="${7:-origin}"
  local data
  data="$(python3 - "$failure" "$task_id" "$branch" "$strategy" "$authority" "$expected" "$next_owner" <<'PY'
import json
import sys
keys = ["failure", "taskId", "branch", "strategy", "authority", "expectedEvidence", "nextOwner"]
print(json.dumps(dict(zip(keys, sys.argv[1:8])), separators=(",", ":")))
PY
)"
  gluerun_append_event "recovery.action" "recovery action recorded" "$data"
}

# Write a machine-readable origin snapshot to .gluerun-state/origin-state.json.
gluerun_write_origin_state() {
  local run_id="$1"
  gluerun_ensure_state_dirs
  local branch head target inbox imported active worktrees
  branch="$(gluerun_current_branch)"
  head="$(git -C "$GLUERUN_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  target="${GLUERUN_TARGET_BRANCH:-}"
  inbox="$(gluerun_count_files "$GLUERUN_INBOX_DIR" -maxdepth 1 -name '*.json')"
  imported="$(gluerun_count_files "$GLUERUN_ORCH_DIR/packets/imported" -name '*.json' -not -name '*.audit.json')"
  active="$(gluerun_active_lease_count)"
  worktrees="$(gluerun_extra_worktree_count)"

  local ready_json leases_json
  # Snapshot telemetry should not pay the legacy O(ready × tasks) duplicate
  # signature scan. The dispatch frontier performs the authoritative duplicate,
  # dependency, lease, and scope checks before launching any worker.
  ready_json="$(gluerun_list_status_ready_tasks | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  if [[ -d "$GLUERUN_LEASES_DIR" ]]; then
    leases_json="$(find "$GLUERUN_LEASES_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  else
    leases_json="[]"
  fi

  # 0.5.0 (additive): gates{passed,total}, completedNodes, per-status
  # taskCounts, and writer provenance — 0.4.0 emitted none of these, so every
  # console/summary field reading them was null by construction.
  python3 - "$GLUERUN_ORIGIN_STATE_FILE" "$run_id" "$branch" "$head" "$target" \
    "$inbox" "$imported" "$active" "$worktrees" "$ready_json" "$leases_json" \
    "$GLUERUN_ORCH_DIR/gates" "$GLUERUN_TASKS_DIR" "${GLUERUN_DAG_FILE:-$GLUERUN_ORCH_DIR/dag.v0.json}" \
    "$$" "${GLUERUN_ORIGIN_STATE_ENTRY:-reconcile}" <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timezone

(path, run_id, branch, head, target, inbox, imported, active, worktrees,
 ready_json, leases_json, gates_dir, tasks_dir, dag_file, writer_pid, entry) = sys.argv[1:17]

total_nodes = 0
try:
    total_nodes = len(json.load(open(dag_file)).get("nodes", []))
except Exception:
    pass
completed = []
if os.path.isdir(gates_dir):
    for name in sorted(os.listdir(gates_dir)):
        if not name.endswith(".gate-result.json"):
            continue
        try:
            g = json.load(open(os.path.join(gates_dir, name)))
        except Exception:
            continue
        if g.get("status") == "passed":
            completed.append(str(g.get("node", name.removesuffix(".gate-result.json"))))

task_counts = {}
if os.path.isdir(tasks_dir):
    for name in sorted(os.listdir(tasks_dir)):
        if not name.startswith("TASK-") or not name.endswith(".md"):
            continue
        status = ""
        try:
            with open(os.path.join(tasks_dir, name), encoding="utf-8") as f:
                for i, line in enumerate(f):
                    if i > 40:
                        break
                    m = re.match(r"^Status:\s*(.+?)\s*$", line)
                    if m:
                        status = m.group(1).strip().lower()
                        break
        except OSError:
            continue
        if status:
            task_counts[status] = task_counts.get(status, 0) + 1

data = {
    "schema": "gluerun.orchestration.origin-state.v0",
    "runId": run_id,
    "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "generatedByPid": int(writer_pid),
    "generatedByEntry": entry,
    "branch": branch,
    "headSha": head,
    "targetBranch": target,
    "packets": {"inbox": int(inbox), "imported": int(imported)},
    "activeLeases": int(active),
    "extraWorktrees": int(worktrees),
    "gates": {"passed": len(completed), "total": total_nodes},
    "completedNodes": completed,
    "taskCounts": task_counts,
    "readyTasks": json.loads(ready_json),
    "leaseFiles": json.loads(leases_json),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# ---- Project modules (extensions) -------------------------------------------
# Load optional modules listed in GLUERUN_MODULES (space-separated names or paths),
# AFTER all generic engine functions are defined so a module's overrides win.
# A bare name resolves to <engine>/gluerun-ext/<name>.sh then <repo>/gluerun-ext/<name>.sh.
# The generic engine sets no modules; a project opts in via config `modules`.
if [[ -n "${GLUERUN_MODULES:-}" ]]; then
  for _gluerun_mod in $GLUERUN_MODULES; do
    if [[ -f "$_gluerun_mod" ]]; then
      # shellcheck disable=SC1090
      source "$_gluerun_mod"
    elif [[ -f "$GLUERUN_ENGINE_HOME/gluerun-ext/${_gluerun_mod}.sh" ]]; then
      # shellcheck disable=SC1090
      source "$GLUERUN_ENGINE_HOME/gluerun-ext/${_gluerun_mod}.sh"
    elif [[ -f "$GLUERUN_ROOT/gluerun-ext/${_gluerun_mod}.sh" ]]; then
      # shellcheck disable=SC1090
      source "$GLUERUN_ROOT/gluerun-ext/${_gluerun_mod}.sh"
    else
      echo "gluerun: module not found: $_gluerun_mod" >&2
      exit 2
    fi
  done
  unset _gluerun_mod
fi

# ---- Context-evolution loader (structural hook) -----------------------------
# Source every engine/ctx-*.sh once, in sorted order, AFTER all generic engine
# functions and modules are defined so context-evolution slices get the last
# word. This block is the ONLY place ctx-*.sh files load: later stages ship
# context logic as new engine/ctx-*.sh files, never by editing lib.sh again. A
# ctx file that fails to source is FATAL (fail closed) — never silently skipped.
# With zero ctx-*.sh present the loop is a no-op (byte-identical prior behavior).
for _gluerun_ctx in "$GLUERUN_ENGINE_DIR"/ctx-*.sh; do
  [[ -e "$_gluerun_ctx" ]] || continue
  # shellcheck disable=SC1090
  source "$_gluerun_ctx" \
    || { echo "gluerun: failed to source context file: $_gluerun_ctx" >&2; exit 2; }
done
unset _gluerun_ctx
