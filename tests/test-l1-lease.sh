#!/usr/bin/env bash
set -euo pipefail

# Regression tests for the L1 node-lease data layer (read-only foundation for
# safe parallel-area planning). Pure bash + fixtures; no codex, no live state.
# Exercises singular_l1_lease_* helpers and singular_select_l1_frontier directly.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Hermetic guard: this checkout may itself be docked as a singular consumer
# (singular.config.json at the repo root). Source lib.sh against a pristine
# empty root so no consumer config (runner, areaPrefix, env{}) leaks into
# test sandboxes; each test exports its own SINGULAR_ROOT afterwards.
export SINGULAR_ROOT="$(mktemp -d)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg: missing '$needle' in: $haystack"
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$msg: unexpected '$needle' in: $haystack"
}

make_repo() {
  local root="$1"
  # NOTE: .singular-state/l1-leases is intentionally NOT pre-created — the lease
  # write path creates it, and test_ensure_state_dirs_stays_dormant asserts that
  # ordinary commands leave it absent.
  mkdir -p "$root/docs/orchestration/gates" \
    "$root/docs/orchestration/tasks" \
    "$root/schemas/orchestration" \
    "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/schemas/dag.v0.schema.json" "$root/schemas/orchestration/dag.v0.schema.json"
  cp "$ENGINE_HOME/schemas/gate-result.v0.schema.json" "$root/schemas/orchestration/gate-result.v0.schema.json"
  cp "$ENGINE_HOME/schemas/l1-lease.v0.schema.json" "$root/schemas/orchestration/l1-lease.v0.schema.json"
  cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "singular.orchestration.dag.v0",
  "nodes": [
    {
      "id": "D0.contract",
      "stage": "D0",
      "area": "kernel",
      "layer": "contract",
      "kind": "contract",
      "dependsOn": [],
      "requiredCompletion": "contract_complete"
    },
    {
      "id": "D1.contract",
      "stage": "D1",
      "area": "artifact",
      "layer": "contract",
      "kind": "contract",
      "dependsOn": ["D0.contract"],
      "requiredCompletion": "contract_complete"
    },
    {
      "id": "S0.storage_substrate_base",
      "stage": "S0",
      "area": "storage",
      "layer": "storage_substrate_base",
      "kind": "substrate",
      "dependsOn": ["D0.contract"],
      "requiredCompletion": "storage_substrate_ready"
    },
    {
      "id": "D1.storage_proof",
      "stage": "D1",
      "area": "artifact",
      "layer": "storage_proof",
      "kind": "storage",
      "dependsOn": ["D1.contract", "S0.storage_substrate_base"],
      "requiredCompletion": "storage_proof_complete"
    }
  ]
}
EOF
  cat >"$root/docs/orchestration/gates/D0.contract.gate-result.json" <<'EOF'
{
  "schema": "singular.orchestration.gate-result.v0",
  "node": "D0.contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "grandfathered",
  "evidence": [
    { "kind": "source-path", "ref": "internal/kernel", "description": "test gate" }
  ],
  "decidedBy": "test",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  make_repo "$tmp/repo"
  export SINGULAR_ROOT="$tmp/repo"
  export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_TARGET_BRANCH="target"
  # Functions read these globals live, so overriding after sourcing lib.sh is
  # sufficient to retarget the helpers at the fixture.
  export SINGULAR_L1_LEASES_DIR="$SINGULAR_STATE_DIR/l1-leases"
  export SINGULAR_L1_LEASE_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/l1-lease.v0.schema.json"
  export SINGULAR_GATE_SCHEMA="$SINGULAR_ROOT/schemas/orchestration/gate-result.v0.schema.json"
}

test_l1_lease_write_and_read() {
  with_fixture
  singular_l1_lease_write S0.storage_substrate_base storage S0 storage_substrate_base proposed RUN-x abc1234 target
  assert_contains "$(singular_l1_lease_status S0.storage_substrate_base)" "proposed" "lease status round-trips"
  assert_contains "$(singular_l1_lease_field S0.storage_substrate_base allowedWriteScopes)" "internal/storage/" "lease defaults write scope to internal/<area>/"
}

test_l1_lease_schema_rejects_bad_status() {
  with_fixture
  local rc=0
  singular_l1_lease_write D1.contract artifact D1 contract bogus RUN-x abc1234 target 2>/dev/null || rc=$?
  [[ "$rc" -ne 0 ]] || fail "bad status must fail closed"
  [[ ! -f "$(singular_l1_lease_path D1.contract)" ]] || fail "rejected lease must not be written"
}

test_select_frontier_disjoint_areas_accepted() {
  with_fixture
  local out
  out="$(singular_select_l1_frontier 5)"
  assert_contains "$out" "D1.contract" "disjoint-area frontier includes D1.contract"
  assert_contains "$out" "S0.storage_substrate_base" "disjoint-area frontier includes S0"
  # DAG declaration order: D1.contract precedes S0.
  assert_contains "${out%%S0.storage_substrate_base*}" "D1.contract" "frontier preserves DAG order"
}

test_select_frontier_limit_respected() {
  with_fixture
  local out
  out="$(singular_select_l1_frontier 1)"
  assert_contains "$out" "D1.contract" "limit=1 returns the first DAG-order node"
  assert_not_contains "$out" "S0.storage_substrate_base" "limit=1 stops after one node"
}

test_select_frontier_duplicate_node_rejected() {
  with_fixture
  singular_l1_lease_write S0.storage_substrate_base storage S0 storage_substrate_base active RUN-x abc1234 target
  local out
  out="$(singular_select_l1_frontier 5)"
  assert_not_contains "$out" "S0.storage_substrate_base" "an active-leased node is not re-selected"
  assert_contains "$out" "D1.contract" "an unleased node in another area is still selected"
}

test_select_frontier_same_area_rejected() {
  with_fixture
  # Lease a node that is NOT in the frontier but shares the artifact area, to
  # isolate the area-exclusion guard from the duplicate-node guard.
  singular_l1_lease_write X1.other artifact X1 contract active RUN-x abc1234 target
  local out
  out="$(singular_select_l1_frontier 5)"
  assert_not_contains "$out" "D1.contract" "a frontier node whose area is already leased is excluded"
  assert_contains "$out" "S0.storage_substrate_base" "a node in a free area is still selected"
}

test_select_frontier_scope_overlap_excluded() {
  with_fixture
  # Lease with a non-matching area but an artifact write scope, to isolate the
  # scope-overlap guard from the area-exclusion guard.
  singular_l1_lease_write X2.ghost ghostarea X2 contract active RUN-x abc1234 target '["internal/artifact/"]'
  local out
  out="$(singular_select_l1_frontier 5)"
  assert_not_contains "$out" "D1.contract" "a node whose write scope overlaps an active lease is excluded"
  assert_contains "$out" "S0.storage_substrate_base" "a node with a non-overlapping scope is still selected"
}

test_l1_stale_reported_not_reused() {
  with_fixture
  singular_l1_lease_write S0.storage_substrate_base storage S0 storage_substrate_base active RUN-x abc1234 target
  local lease before after stale frontier
  lease="$(singular_l1_lease_path S0.storage_substrate_base)"
  before="$(shasum -a 256 "$lease" | awk '{print $1}')"
  stale="$(SINGULAR_L1_STALE_MINUTES=0 singular_l1_list_stale)"
  after="$(shasum -a 256 "$lease" | awk '{print $1}')"
  assert_contains "$stale" "S0.storage_substrate_base" "a stale active lease is reported"
  [[ "$before" == "$after" ]] || fail "stale detection must not mutate the lease (report only)"
  # A stale lease still blocks its slot — it is surfaced, never silently reused.
  frontier="$(singular_select_l1_frontier 5)"
  assert_not_contains "$frontier" "S0.storage_substrate_base" "a stale lease still blocks re-selection"
}

test_l1_lease_set_status_releases_slot() {
  with_fixture
  singular_l1_lease_write S0.storage_substrate_base storage S0 storage_substrate_base active RUN-x abc1234 target
  assert_contains "$(singular_l1_list_active)" "S0.storage_substrate_base" "active lease is listed"
  singular_l1_lease_set_status S0.storage_substrate_base released
  assert_not_contains "$(singular_l1_list_active)" "S0.storage_substrate_base" "released lease drops from active list"
  assert_contains "$(singular_select_l1_frontier 5)" "S0.storage_substrate_base" "releasing a lease frees the node for re-selection"
}

test_l1_lease_rejects_empty_node() {
  with_fixture
  local rc=0
  singular_l1_lease_write "" storage S0 storage_substrate_base proposed RUN-x abc1234 target 2>/dev/null || rc=$?
  [[ "$rc" -ne 0 ]] || fail "empty node must be rejected (schema minLength)"
  [[ ! -e "$SINGULAR_L1_LEASES_DIR/.json" ]] || fail "a rejected empty-node lease must not be written"
}

test_l1_lease_rejects_bad_basesha() {
  with_fixture
  local rc=0
  singular_l1_lease_write S0.storage_substrate_base storage S0 storage_substrate_base active RUN-x NOTHEX target 2>/dev/null || rc=$?
  [[ "$rc" -ne 0 ]] || fail "a non-hex baseSha must be rejected (schema pattern)"
  [[ ! -f "$(singular_l1_lease_path S0.storage_substrate_base)" ]] || fail "a rejected baseSha lease must not be written"
}

test_l1_lease_set_status_rejects_bogus() {
  with_fixture
  singular_l1_lease_write S0.storage_substrate_base storage S0 storage_substrate_base active RUN-x abc1234 target
  local lease before after rc=0
  lease="$(singular_l1_lease_path S0.storage_substrate_base)"
  before="$(shasum -a 256 "$lease" | awk '{print $1}')"
  singular_l1_lease_set_status S0.storage_substrate_base totally-bogus 2>/dev/null || rc=$?
  after="$(shasum -a 256 "$lease" | awk '{print $1}')"
  [[ "$rc" -ne 0 ]] || fail "set_status must reject a bogus status (full re-validation)"
  [[ "$before" == "$after" ]] || fail "a rejected set_status must leave the existing lease untouched"
  assert_contains "$(singular_l1_lease_status S0.storage_substrate_base)" "active" "status stays valid after a rejected update"
}

test_l1_lease_write_preserves_started_at() {
  with_fixture
  singular_l1_lease_write S0.storage_substrate_base storage S0 storage_substrate_base proposed RUN-x abc1234 target
  local s1 s2
  s1="$(singular_l1_lease_field S0.storage_substrate_base startedAt)"
  singular_l1_lease_write S0.storage_substrate_base storage S0 storage_substrate_base active RUN-y abc1234 target
  s2="$(singular_l1_lease_field S0.storage_substrate_base startedAt)"
  [[ -n "$s1" && "$s1" == "$s2" ]] || fail "startedAt must be preserved across updates (s1=$s1 s2=$s2)"
}

test_ensure_state_dirs_stays_dormant() {
  with_fixture
  [[ ! -d "$SINGULAR_L1_LEASES_DIR" ]] || fail "fixture must start without an l1-leases dir"
  singular_ensure_state_dirs
  [[ ! -d "$SINGULAR_L1_LEASES_DIR" ]] || fail "ensure_state_dirs must not create the l1-leases dir (strict dormancy)"
}

test_l1_lease_write_and_read
test_l1_lease_schema_rejects_bad_status
test_select_frontier_disjoint_areas_accepted
test_select_frontier_limit_respected
test_select_frontier_duplicate_node_rejected
test_select_frontier_same_area_rejected
test_select_frontier_scope_overlap_excluded
test_l1_stale_reported_not_reused
test_l1_lease_set_status_releases_slot
test_l1_lease_rejects_empty_node
test_l1_lease_rejects_bad_basesha
test_l1_lease_set_status_rejects_bogus
test_l1_lease_write_preserves_started_at
test_ensure_state_dirs_stays_dormant

echo "l1 lease tests passed"
