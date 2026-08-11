#!/usr/bin/env bash
# Covers the first engine/generate-tasks.sh driver-hook slice of DAG node
# `planner-session-meta`: wiring the already-integrated
# singular_ctx_planner_session_path / singular_ctx_planner_session_finalize into a
# real planner run, default-OFF behind SINGULAR_PLANNER_SESSION. Asserts:
#   (a) knob ON + a successful stub batch -> the runner is invoked with
#       --session-meta "$(singular_ctx_planner_session_path <node>)" AND a valid
#       finalized singular.orchestration.session-meta.v0 meta is written at
#       .singular-state/sessions/planner/<node>.json with role "planner",
#       node == the planned node, and headShaAtCreate == the target-branch head
#       resolved at planning time;
#   (b) knob ON + a planner-failed stub (non-zero rc) -> NO finalized meta
#       (evidence invariance: a rejected planner lineage is not extended);
#   (c) knob OFF (unset / =0) -> no meta written and the runner is invoked with
#       NO --session-meta argument (byte-identical to prior behavior).
# Everything runs in an isolated SINGULAR_ROOT/SINGULAR_STATE_DIR — never the real
# repo or its state dir.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }

NODE="planner-session-meta"

# --- Isolated repo fixture ---------------------------------------------------
make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/prompts" \
    "$root/docs/orchestration/tasks" \
    "$root/schemas/orchestration" \
    "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$root/docs/orchestration/prompts/l1-planner.md"
  cp "$ENGINE_HOME/schemas/task-batch.v0.schema.json" "$root/schemas/orchestration/task-batch.v0.schema.json"
  cp "$ENGINE_HOME/schemas/dag.v0.schema.json" "$root/schemas/orchestration/dag.v0.schema.json"
  cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "singular.orchestration.dag.v0",
  "layers": ["engine_runtime"],
  "kinds": ["runtime"],
  "nodes": [
    {
      "id": "planner-session-meta",
      "stage": "S1-planner-persistence",
      "area": "session",
      "layer": "engine_runtime",
      "kind": "runtime",
      "dependsOn": [],
      "requiredCompletion": "Planner runs persist finalized session-meta per node."
    }
  ]
}
EOF
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  FIXTURE_TMP="$tmp"
  make_repo "$tmp/repo"
  export SINGULAR_ROOT="$tmp/repo"
  export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_TARGET_BRANCH="target"
  STUB_ARGS_FILE="$SINGULAR_ROOT/stub-args.txt"
  export STUB_ARGS_FILE
  rm -f "$STUB_ARGS_FILE"
}

cleanup() { [[ -n "${FIXTURE_TMP:-}" ]] && rm -rf "$FIXTURE_TMP"; }
trap cleanup EXIT

# Stub runner: records every arg it received (so the test can assert on the
# presence/value of --session-meta), then emits a single valid canonical task
# batch for the `session` area.
make_success_stub() {
  local stub="$1"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${STUB_ARGS_FILE:?}"
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message|-o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 2
python3 - "$out" <<'PY'
import json, sys
md = (
    "# TASK-0001: planner session hook slice\n\n"
    "Status: ready\n"
    "Area: session\n"
    "Target branch: `target`\n"
    "Worker branch: `agent/session/TASK-0001-hook`\n"
    "Test policy: `strict_test_first`\n"
    "Gate command: `bash tests/run.sh`\n"
    "Dispatch mode: canonical\n"
    "Depends on: []\n\n"
    "## Objective\n\nWire the planner session-meta hook.\n\n"
    "## Scope\n\nOwned files:\n\n"
    "- `engine/generate-tasks.sh`\n"
    "- `tests/test-generate-tasks-planner-session-hook.sh`\n\n"
    "Forbidden files:\n\n- `engine/lib.sh`\n\n"
    "## Acceptance Criteria\n\n- Tests first.\n"
)
batch = {
    "schema": "singular.orchestration.task-batch.v0",
    "tasks": [{"taskId": "TASK-0001", "markdown": md}],
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(batch, f)
PY
EOF
  chmod +x "$stub"
}

# Stub runner: records args then exits non-zero (planner-failed).
make_failing_stub() {
  local stub="$1"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${STUB_ARGS_FILE:?}"
exit 7
EOF
  chmod +x "$stub"
}

meta_path() { printf '%s/sessions/planner/%s.json' "$SINGULAR_STATE_DIR" "$NODE"; }
stub_has_session_meta() { grep -qx -- '--session-meta' "$STUB_ARGS_FILE"; }

# ---------------------------------------------------------------------------
# (a) knob ON + successful stub -> finalized meta + runner saw --session-meta.
# ---------------------------------------------------------------------------
test_on_success_finalizes() {
  with_fixture
  local stub="$SINGULAR_ROOT/success-stub.sh"
  make_success_stub "$stub"
  local head; head="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  local out
  out="$(SINGULAR_PLANNER_SESSION=1 SINGULAR_RUNNER="$stub" \
    "$SCRIPT_DIR/generate-tasks.sh" --node "$NODE" --count 1 2>&1 || true)"
  [[ "$out" == *"generated:"* || "$out" == *"staged:"* ]] \
    || fail "ON/success: planner did not accept the batch: $out"

  local mp; mp="$(meta_path)"
  [[ -f "$mp" ]] || fail "ON/success: no finalized meta at $mp (out=$out)"
  python3 - "$mp" "$NODE" "$head" <<'PY' || fail "ON/success: finalized meta invalid"
import json, sys
path, node, head = sys.argv[1:4]
doc = json.load(open(path))
assert doc.get("schema") == "singular.orchestration.session-meta.v0", doc
assert doc.get("role") == "planner", doc
assert doc.get("node") == node, doc
assert doc.get("headShaAtCreate") == head, doc
print("ok")
PY

  stub_has_session_meta || fail "ON/success: runner NOT invoked with --session-meta"
  local expected; expected="$SINGULAR_STATE_DIR/sessions/planner/$NODE.json"
  grep -qx -- "$expected" "$STUB_ARGS_FILE" \
    || fail "ON/success: runner --session-meta value not the canonical path $expected"
  echo "PASS: ON/success finalizes and passes --session-meta"
}

# ---------------------------------------------------------------------------
# (b) knob ON + planner-failed stub -> NO finalized meta.
# ---------------------------------------------------------------------------
test_on_failure_no_meta() {
  with_fixture
  local stub="$SINGULAR_ROOT/failing-stub.sh"
  make_failing_stub "$stub"
  local out
  out="$(SINGULAR_PLANNER_SESSION=1 SINGULAR_RUNNER="$stub" \
    "$SCRIPT_DIR/generate-tasks.sh" --node "$NODE" --count 1 2>&1 || true)"
  [[ "$out" == *"planner-failed"* ]] || fail "ON/failure: expected planner-failed, got: $out"
  local mp; mp="$(meta_path)"
  [[ ! -e "$mp" ]] || fail "ON/failure: a resumable meta was written for a failed planner run at $mp"
  echo "PASS: ON/failure writes no meta"
}

# ---------------------------------------------------------------------------
# (c) knob OFF -> no meta and no --session-meta on the runner invocation.
# ---------------------------------------------------------------------------
test_off_no_meta_no_flag() {
  with_fixture
  local stub="$SINGULAR_ROOT/success-stub.sh"
  make_success_stub "$stub"
  local out
  out="$(SINGULAR_RUNNER="$stub" \
    "$SCRIPT_DIR/generate-tasks.sh" --node "$NODE" --count 1 2>&1 || true)"
  [[ "$out" == *"generated:"* || "$out" == *"staged:"* ]] \
    || fail "OFF: planner did not accept the batch: $out"
  local mp; mp="$(meta_path)"
  [[ ! -e "$mp" ]] || fail "OFF: finalized meta written while knob OFF at $mp"
  ! stub_has_session_meta || fail "OFF: runner invoked with --session-meta while knob OFF"

  # Explicit =0 behaves identically.
  rm -f "$STUB_ARGS_FILE"
  out="$(SINGULAR_PLANNER_SESSION=0 SINGULAR_RUNNER="$stub" \
    "$SCRIPT_DIR/generate-tasks.sh" --node "$NODE" --count 1 2>&1 || true)"
  [[ ! -e "$mp" ]] || fail "OFF(=0): finalized meta written while knob OFF at $mp"
  ! stub_has_session_meta || fail "OFF(=0): runner invoked with --session-meta while knob OFF"
  echo "PASS: OFF writes no meta and passes no --session-meta"
}

test_on_success_finalizes
test_on_failure_no_meta
test_off_no_meta_no_flag
echo "generate-tasks planner-session-hook tests passed"
