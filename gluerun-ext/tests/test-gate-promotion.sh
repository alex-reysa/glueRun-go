#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

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
  mkdir -p "$root/docs/orchestration/gates" \
    "$root/docs/orchestration/packets/imported" \
    "$root/docs/orchestration/tasks" \
    "$root/schemas/orchestration" \
    "$root/.gluerun-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/schemas/gate-result.v0.schema.json" "$root/schemas/orchestration/gate-result.v0.schema.json"
  cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "gluerun.orchestration.dag.v0",
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
      "dependsOn": ["S0.storage_substrate_base"],
      "requiredCompletion": "storage_proof_complete"
    }
  ]
}
EOF
  cat >"$root/docs/orchestration/project-state.md" <<'EOF'
# Project State
EOF
  cat >"$root/docs/orchestration/gates/D0.contract.gate-result.json" <<'EOF'
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "D0.contract",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "grandfathered",
  "evidence": [
    {
      "kind": "source-path",
      "ref": "internal/kernel",
      "description": "Existing D0 kernel contract package."
    }
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
  export GLUERUN_ROOT="$tmp/repo"
  export GLUERUN_ORCH_DIR="$GLUERUN_ROOT/docs/orchestration"
  export GLUERUN_TASKS_DIR="$GLUERUN_ORCH_DIR/tasks"
  export GLUERUN_STATE_DIR="$GLUERUN_ROOT/.gluerun-state"
  export GLUERUN_RUNS_DIR="$GLUERUN_STATE_DIR/runs"
  export GLUERUN_INBOX_DIR="$GLUERUN_STATE_DIR/inbox"
  export GLUERUN_TARGET_BRANCH="target"
  # promote-gate.sh and the storage-proof red/green regime are a GLUERUN-owned
  # extension (this test moves to gluerun-ext/ with promote-gate.sh). Declare the
  # proof-layer config so the generic dag.sh validator applies the red/green rule.
  export GLUERUN_PROOF_LAYERS="storage_proof"
  export GLUERUN_PROOF_GRANDFATHER="D1.storage_proof,D2.storage_proof"
  export GLUERUN_MODULES="storage-proof"
  export GLUERUN_PROMOTER="$ENGINE_HOME/gluerun-ext/promote-gate.sh"
  # GLUERUN's real gate command (a no-Go fixture makes it fail, as the prod-guard test expects)
  export GLUERUN_DEFAULT_GATE_CMD="go build ./... && go vet ./... && go test ./..."
  # Fixtures may override the storage-proof green/red commands to run offline;
  # this flag is what makes those overrides honorable (production never sets it).
  export GLUERUN_TEST_FIXTURE=1
}

	write_task() {
	  local task_id="$1"
	  cat >"$GLUERUN_TASKS_DIR/$task_id.md" <<EOF
# $task_id: fixture

Status: integrated
Area: storage
Target branch: \`target\`
Worker branch: \`agent/storage/$task_id-fixture\`
Test policy: \`strict_test_first\`
Gate command: \`go build ./... && go vet ./... && go test ./...\`
Dispatch mode: canonical
Depends on: []
EOF
		}

	write_scoped_task() {
	  local task_id="$1" status="$2" area="$3" title="$4" objective="$5"
	  shift 5
	  {
	    echo "# $task_id: $title"
	    echo ""
	    echo "Status: $status"
	    echo "Area: $area"
	    echo "Target branch: \`target\`"
	    echo "Worker branch: \`agent/$area/$task_id-fixture\`"
	    echo "Test policy: \`strict_test_first\`"
	    echo "Gate command: \`true\`"
	    echo "Dispatch mode: canonical"
	    echo "Depends on: []"
	    echo ""
	    echo "## Objective"
	    echo ""
	    echo "$objective"
	    echo ""
	    echo "## Scope"
	    echo ""
	    echo "Owned files:"
	    echo ""
	    local owned
	    for owned in "$@"; do
	      echo "- \`$owned\`"
	    done
	    echo ""
	    echo "Forbidden files:"
	    echo ""
	    echo "- Any file outside the owned scope."
	  } >"$GLUERUN_TASKS_DIR/$task_id.md"
	}

	write_service_alias_task() {
	  write_scoped_task "$1" integrated artifact \
	    "Artifact alias lifecycle-state runtime query" \
	    "Implement the artifact alias lifecycle-state runtime query for D1.service." \
	    "internal/artifact/service_runtime_alias_lifecycle_state_lookup.go" \
	    "internal/artifact/service_runtime_alias_lifecycle_state_lookup_test.go"
	}

	write_service_member_task() {
	  write_scoped_task "$1" integrated artifact \
	    "Artifact collection member-version runtime query" \
	    "Implement the artifact collection member-version runtime query for D1.service." \
	    "internal/artifact/service_runtime_collection_member_lookup.go" \
	    "internal/artifact/service_runtime_collection_member_lookup_test.go"
	}

	write_service_completeness_task() {
	  write_scoped_task "$1" integrated artifact \
	    "Artifact collection completeness runtime query" \
	    "Implement the artifact collection completeness runtime query for D1.service." \
	    "internal/artifact/service_runtime_collection_completeness_lookup.go" \
	    "internal/artifact/service_runtime_collection_completeness_lookup_test.go"
	}

	write_service_required_task() {
	  write_scoped_task "$1" integrated artifact \
	    "Artifact collection required-member coverage runtime check" \
	    "Implement the artifact collection required-member coverage runtime check for D1.service." \
	    "internal/artifact/service_runtime_collection_required_coverage.go" \
	    "internal/artifact/service_runtime_collection_required_coverage_test.go"
	}

	write_workflow_record_storage_task() {
	  write_scoped_task "$1" integrated workflow \
	    "Workflow storage record coverage specification" \
	    "Specify workflow storage record coverage for D2.storage_spec." \
	    "internal/workflow/storage_record_coverage_spec.go" \
	    "internal/workflow/storage_record_coverage_spec_test.go"
	}

	write_workflow_materialization_task() {
	  write_scoped_task "$1" integrated workflow \
	    "Workflow storage materialization path specification" \
	    "Specify workflow storage materialization paths for D2.storage_spec." \
	    "internal/workflow/storage_materialization_path_spec.go" \
	    "internal/workflow/storage_materialization_path_spec_test.go"
	}

	write_workflow_exact_ref_task() {
	  write_scoped_task "$1" integrated workflow \
	    "Workflow storage exact ref boundary specification" \
	    "Specify workflow storage exact ref boundaries for D2.storage_spec." \
	    "internal/workflow/storage_exact_ref_boundary_spec.go" \
	    "internal/workflow/storage_exact_ref_boundary_spec_test.go"
	}

	write_workflow_authority_task() {
	  write_scoped_task "$1" integrated workflow \
	    "Workflow storage authority boundary specification" \
	    "Specify workflow storage authority boundaries for D2.storage_spec." \
	    "internal/workflow/storage_authority_boundary_spec.go" \
	    "internal/workflow/storage_authority_boundary_spec_test.go"
	}

write_storage_promotable_tasks() {
  local task_id
  for task_id in \
    TASK-0313 TASK-0314 TASK-0316 TASK-0318 TASK-0320 TASK-0322 \
    TASK-0324 TASK-0326 TASK-0328 TASK-0330 TASK-0332 TASK-0334 \
    TASK-0336 TASK-0338 TASK-0340 TASK-0342 TASK-0344 TASK-0346 TASK-0348
  do
    write_task "$task_id"
  done
}

# The 30 integrated workflow contract slices that prove D2.contract
# (workflow templates, immutable template versions, workflow runs, node runs,
# role contracts) — the same shape D1.contract used (TASK-0001..0018).
WORKFLOW_CONTRACT_TASKS=(
  TASK-0019 TASK-0020 TASK-0021 TASK-0022 TASK-0023 TASK-0024
  TASK-0025 TASK-0026 TASK-0027 TASK-0028 TASK-0029 TASK-0030
  TASK-0031 TASK-0032 TASK-0033 TASK-0034 TASK-0035 TASK-0036
  TASK-0037 TASK-0038 TASK-0039 TASK-0040 TASK-0041 TASK-0042
  TASK-0043 TASK-0044 TASK-0045 TASK-0046 TASK-0047 TASK-0048
)

BINDING_CONTRACT_TASKS=(
  TASK-0049 TASK-0050 TASK-0051 TASK-0052 TASK-0053 TASK-0054
  TASK-0055 TASK-0056 TASK-0057 TASK-0058 TASK-0059 TASK-0060
  TASK-0061 TASK-0062 TASK-0063 TASK-0064 TASK-0065 TASK-0066
  TASK-0067 TASK-0068 TASK-0069 TASK-0070 TASK-0071 TASK-0369
)

DISPATCH_CONTRACT_TASKS=(
  TASK-0072 TASK-0073 TASK-0074 TASK-0075 TASK-0076 TASK-0077
  TASK-0078 TASK-0079 TASK-0080 TASK-0081 TASK-0082 TASK-0083
  TASK-0084 TASK-0085 TASK-0086 TASK-0087 TASK-0088 TASK-0089
  TASK-0090 TASK-0091 TASK-0092 TASK-0093 TASK-0094 TASK-0095
  TASK-0096
)

EVIDENCE_CONTRACT_TASKS=(
  TASK-0097 TASK-0098 TASK-0099 TASK-0100 TASK-0101 TASK-0102
  TASK-0103 TASK-0104 TASK-0105 TASK-0106 TASK-0107 TASK-0108
  TASK-0109 TASK-0110 TASK-0111 TASK-0112 TASK-0113 TASK-0114
  TASK-0115 TASK-0116 TASK-0117 TASK-0118 TASK-0119 TASK-0120
  TASK-0121 TASK-0122 TASK-0123 TASK-0124 TASK-0125 TASK-0126
  TASK-0127 TASK-0128 TASK-0129 TASK-0130 TASK-0131
)

RECOVERY_CONTRACT_TASKS=(
  TASK-0132 TASK-0133 TASK-0134 TASK-0135 TASK-0136 TASK-0137
  TASK-0138 TASK-0139 TASK-0140 TASK-0141 TASK-0142 TASK-0143
  TASK-0144 TASK-0145 TASK-0146 TASK-0147 TASK-0148 TASK-0149
  TASK-0150 TASK-0151 TASK-0152 TASK-0153 TASK-0154 TASK-0155
  TASK-0156 TASK-0157 TASK-0158 TASK-0159 TASK-0160 TASK-0161
  TASK-0162 TASK-0163 TASK-0164 TASK-0165 TASK-0166 TASK-0167
  TASK-0168 TASK-0169 TASK-0170 TASK-0171
)

SCHEDULER_CONTRACT_TASKS=()
for n in $(seq 172 312); do
  SCHEDULER_CONTRACT_TASKS+=("$(printf 'TASK-%04d' "$n")")
done

write_workflow_contract_tasks() {
  local task_id
  for task_id in "${WORKFLOW_CONTRACT_TASKS[@]}"; do
    write_task "$task_id"
  done
}

# Write every required workflow contract task EXCEPT one (left non-integrated)
# so D2.contract is eligible but its readiness predicate is unmet.
write_workflow_contract_tasks_missing() {
  local skip="$1" task_id
  for task_id in "${WORKFLOW_CONTRACT_TASKS[@]}"; do
    [[ "$task_id" == "$skip" ]] && continue
    write_task "$task_id"
  done
}

write_binding_contract_tasks() {
  local task_id
  for task_id in "${BINDING_CONTRACT_TASKS[@]}"; do
    write_task "$task_id"
  done
}

write_binding_contract_tasks_missing() {
  local skip="$1" task_id
  for task_id in "${BINDING_CONTRACT_TASKS[@]}"; do
    [[ "$task_id" == "$skip" ]] && continue
    write_task "$task_id"
  done
}

write_dispatch_contract_tasks() {
  local task_id
  for task_id in "${DISPATCH_CONTRACT_TASKS[@]}"; do
    write_task "$task_id"
  done
}

write_dispatch_contract_tasks_missing() {
  local skip="$1" task_id
  for task_id in "${DISPATCH_CONTRACT_TASKS[@]}"; do
    [[ "$task_id" == "$skip" ]] && continue
    write_task "$task_id"
  done
}

write_evidence_contract_tasks() {
  local task_id
  for task_id in "${EVIDENCE_CONTRACT_TASKS[@]}"; do
    write_task "$task_id"
  done
}

write_evidence_contract_tasks_missing() {
  local skip="$1" task_id
  for task_id in "${EVIDENCE_CONTRACT_TASKS[@]}"; do
    [[ "$task_id" == "$skip" ]] && continue
    write_task "$task_id"
  done
}

write_recovery_contract_tasks() {
  local task_id
  for task_id in "${RECOVERY_CONTRACT_TASKS[@]}"; do
    write_task "$task_id"
  done
}

write_recovery_contract_tasks_missing() {
  local skip="$1" task_id
  for task_id in "${RECOVERY_CONTRACT_TASKS[@]}"; do
    [[ "$task_id" == "$skip" ]] && continue
    write_task "$task_id"
  done
}

write_scheduler_contract_tasks() {
  local task_id
  for task_id in "${SCHEDULER_CONTRACT_TASKS[@]}"; do
    write_task "$task_id"
  done
}

write_scheduler_contract_tasks_missing() {
  local skip="$1" task_id
  for task_id in "${SCHEDULER_CONTRACT_TASKS[@]}"; do
    [[ "$task_id" == "$skip" ]] && continue
    write_task "$task_id"
  done
}

# Minimal valid grandfathered passing gate, for prerequisite nodes.
write_passed_gate() {
  cat >"$GLUERUN_ORCH_DIR/gates/$1.gate-result.json" <<EOF
{
  "schema": "gluerun.orchestration.gate-result.v0",
  "node": "$1",
  "status": "passed",
  "authoritative": true,
  "evidenceClass": "grandfathered",
  "evidence": [ { "kind": "source-path", "ref": "$2", "description": "prerequisite gate" } ],
  "decidedBy": "test",
  "recordedAt": "2026-06-01T00:00:00Z"
}
EOF
}

# Write a deterministic-proof storage_proof gate carrying ONLY a green
# command-log (no red skip-guard), to probe dag.sh's final-authority validation.
write_green_only_storage_proof_gate() {
  local node="$1" log_ref="$2" sha="$3" head="$4"
  python3 - "$GLUERUN_ORCH_DIR/gates/$node.gate-result.json" "$node" "$log_ref" "$sha" "$head" <<'PY'
import json, sys
out, node, log_ref, sha, head = sys.argv[1:6]
gate = {
    "schema": "gluerun.orchestration.gate-result.v0",
    "node": node, "status": "passed", "authoritative": True,
    "evidenceClass": "deterministic-proof",
    "evidence": [
        {"kind": "source-path", "ref": "internal/x", "description": "src"},
        {"kind": "command-log", "ref": "green-only-regression", "description": "green",
         "command": "c", "exitCode": 0, "logRef": log_ref, "sha256": sha, "headSha": head},
    ],
    "decidedBy": "test", "recordedAt": "2026-06-04T00:00:00Z",
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(gate, f)
PY
}

# Write a deterministic-proof storage_proof gate carrying a green command-log plus
# an arbitrary failed command-log that is NOT the storage-stripped skip-guard.
write_storage_proof_gate_with_unmarked_failed_log() {
  local node="$1" log_ref="$2" sha="$3" head="$4"
  python3 - "$GLUERUN_ORCH_DIR/gates/$node.gate-result.json" "$node" "$log_ref" "$sha" "$head" <<'PY'
import json, sys
out, node, log_ref, sha, head = sys.argv[1:6]
gate = {
    "schema": "gluerun.orchestration.gate-result.v0",
    "node": node, "status": "passed", "authoritative": True,
    "evidenceClass": "deterministic-proof",
    "evidence": [
        {"kind": "source-path", "ref": "internal/x", "description": "src"},
        {"kind": "command-log", "ref": "green-regression", "description": "green",
         "command": "c", "exitCode": 0, "logRef": log_ref, "sha256": sha, "headSha": head},
        {"kind": "command-log", "ref": "random-failed-command", "description": "not skip guard",
         "command": "exit 9", "exitCode": 9, "logRef": log_ref, "sha256": sha, "headSha": head},
    ],
    "decidedBy": "test", "recordedAt": "2026-06-04T00:00:00Z",
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(gate, f)
PY
}

write_valid_storage_proof_gate() {
  local node="$1" source_ref="$2"
  mkdir -p "$GLUERUN_ORCH_DIR/gates/evidence"
  local log_ref="docs/orchestration/gates/evidence/${node}.valid-storage-proof.txt"
  printf 'valid-storage-proof\n' > "$GLUERUN_ROOT/$log_ref"
  local sha head
  sha="$(shasum -a 256 "$GLUERUN_ROOT/$log_ref" | awk '{print $1}')"
  head="$(git -C "$GLUERUN_ROOT" rev-parse HEAD)"
  python3 - "$GLUERUN_ORCH_DIR/gates/$node.gate-result.json" "$node" "$source_ref" "$log_ref" "$sha" "$head" <<'PY'
import json, sys
out, node, source_ref, log_ref, sha, head = sys.argv[1:7]
gate = {
    "schema": "gluerun.orchestration.gate-result.v0",
    "node": node,
    "status": "passed",
    "authoritative": True,
    "evidenceClass": "deterministic-proof",
    "evidence": [
        {"kind": "source-path", "ref": source_ref, "description": "prerequisite durable proof"},
        {"kind": "command-log", "ref": f"{node}-green", "description": "green",
         "command": "true", "exitCode": 0, "logRef": log_ref, "sha256": sha, "headSha": head},
        {"kind": "command-log", "ref": f"{node}-skip-guard-red", "description": "red",
         "command": "exit 7", "exitCode": 7, "logRef": log_ref, "sha256": sha, "headSha": head},
    ],
    "decidedBy": "test",
    "recordedAt": "2026-06-05T00:00:00Z",
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(gate, f)
PY
}

		# A subgraph mirroring the real D1/D2/D3 frontier so promote-or-block can be
		# exercised for storage proof, service, contract, and workflow storage spec.
		write_subgraph_dag() {
	  cat >"$GLUERUN_ORCH_DIR/dag.v0.json" <<'EOF'
{
  "schema": "gluerun.orchestration.dag.v0",
  "nodes": [
    { "id": "D0.contract", "stage": "D0", "area": "kernel", "layer": "contract", "kind": "contract", "dependsOn": [], "requiredCompletion": "contract_complete" },
    { "id": "D1.contract", "stage": "D1", "area": "artifact", "layer": "contract", "kind": "contract", "dependsOn": ["D0.contract"], "requiredCompletion": "contract_complete" },
    { "id": "S0.storage_substrate_base", "stage": "S0", "area": "storage", "layer": "storage_substrate_base", "kind": "substrate", "dependsOn": ["D0.contract"], "requiredCompletion": "storage_substrate_ready" },
    { "id": "D1.storage_spec", "stage": "D1", "area": "artifact", "layer": "storage_spec", "kind": "storage", "dependsOn": ["D1.contract"], "requiredCompletion": "storage_spec_complete" },
    { "id": "D1.storage_proof", "stage": "D1", "area": "artifact", "layer": "storage_proof", "kind": "storage", "dependsOn": ["D1.storage_spec", "S0.storage_substrate_base"], "requiredCompletion": "storage_proof_complete" },
    { "id": "D1.service", "stage": "D1", "area": "artifact", "layer": "service", "kind": "runtime", "dependsOn": ["D1.storage_proof"], "requiredCompletion": "service_complete" },
    { "id": "D2.contract", "stage": "D2", "area": "workflow", "layer": "contract", "kind": "contract", "dependsOn": ["D1.contract"], "requiredCompletion": "contract_complete" },
    { "id": "D2.storage_spec", "stage": "D2", "area": "workflow", "layer": "storage_spec", "kind": "storage", "dependsOn": ["D2.contract", "D1.storage_spec"], "requiredCompletion": "storage_spec_complete" },
    { "id": "D2.storage_proof", "stage": "D2", "area": "workflow", "layer": "storage_proof", "kind": "storage", "dependsOn": ["D2.storage_spec", "D1.storage_proof"], "requiredCompletion": "storage_proof_complete" },
    { "id": "D3.contract", "stage": "D3", "area": "binding", "layer": "contract", "kind": "contract", "dependsOn": ["D2.contract"], "requiredCompletion": "contract_complete" },
    { "id": "D3.storage_spec", "stage": "D3", "area": "binding", "layer": "storage_spec", "kind": "storage", "dependsOn": ["D3.contract", "D2.storage_spec"], "requiredCompletion": "storage_spec_complete" },
    { "id": "D3.storage_proof", "stage": "D3", "area": "binding", "layer": "storage_proof", "kind": "storage", "dependsOn": ["D3.storage_spec", "D2.storage_proof"], "requiredCompletion": "storage_proof_complete" },
    { "id": "D3.binding_runtime", "stage": "D3", "area": "binding", "layer": "binding_runtime", "kind": "runtime", "dependsOn": ["D3.storage_proof", "D2.service"], "requiredCompletion": "runtime_complete" },
    { "id": "D4.contract", "stage": "D4", "area": "dispatch", "layer": "contract", "kind": "contract", "dependsOn": ["D3.contract"], "requiredCompletion": "contract_complete" },
    { "id": "D4.storage_spec", "stage": "D4", "area": "dispatch", "layer": "storage_spec", "kind": "storage", "dependsOn": ["D4.contract", "D3.storage_spec"], "requiredCompletion": "storage_spec_complete" },
    { "id": "D4.storage_proof", "stage": "D4", "area": "dispatch", "layer": "storage_proof", "kind": "storage", "dependsOn": ["D4.storage_spec", "D3.storage_proof"], "requiredCompletion": "storage_proof_complete" },
    { "id": "D4.dispatch_runtime", "stage": "D4", "area": "dispatch", "layer": "dispatch_runtime", "kind": "runtime", "dependsOn": ["D4.storage_proof", "D3.binding_runtime"], "requiredCompletion": "runtime_complete" },
    { "id": "D5.contract", "stage": "D5", "area": "evidence", "layer": "contract", "kind": "contract", "dependsOn": ["D4.contract"], "requiredCompletion": "contract_complete" },
    { "id": "D5.storage_spec", "stage": "D5", "area": "evidence", "layer": "storage_spec", "kind": "storage", "dependsOn": ["D5.contract", "D4.storage_spec"], "requiredCompletion": "storage_spec_complete" },
    { "id": "D6.contract", "stage": "D6", "area": "recovery", "layer": "contract", "kind": "contract", "dependsOn": ["D5.contract"], "requiredCompletion": "contract_complete" },
    { "id": "D7.contract", "stage": "D7", "area": "scheduler", "layer": "contract", "kind": "contract", "dependsOn": ["D6.contract"], "requiredCompletion": "contract_complete" },
    { "id": "D2.service", "stage": "D2", "area": "workflow", "layer": "service", "kind": "runtime", "dependsOn": ["D2.storage_proof", "D1.service"], "requiredCompletion": "service_complete" },
    { "id": "D8.contract", "stage": "D8", "area": "product", "layer": "contract", "kind": "product_api", "dependsOn": ["D7.contract"], "requiredCompletion": "contract_complete" }
  ]
}
EOF
	}

test_promote_storage_substrate_gate_writes_authoritative_gate() {
  with_fixture
  write_storage_promotable_tasks
  local out gate
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" S0.storage_substrate_base 2>&1)"
  assert_contains "$out" "promoted node=S0.storage_substrate_base" "promotion reports promoted gate"
  gate="$GLUERUN_ORCH_DIR/gates/S0.storage_substrate_base.gate-result.json"
  [[ -f "$gate" ]] || fail "promotion did not write S0 gate"
  "$SCRIPT_DIR/dag.sh" area-gate S0.storage_substrate_base >/dev/null
  python3 - "$gate" "$GLUERUN_ROOT" <<'PY'
import hashlib
import json
import os
import sys
gate_path, root = sys.argv[1:3]
with open(gate_path, "r", encoding="utf-8") as f:
    gate = json.load(f)
if "layer" in gate or "requiredCompletion" in gate:
    raise SystemExit("gate contains candidate-only fields")
if gate["status"] != "passed" or gate["authoritative"] is not True:
    raise SystemExit("gate is not authoritative passed")
if gate["upstreamGates"] != ["D0.contract"]:
    raise SystemExit("wrong upstream gates")
command_log = gate["evidence"][2]
log_path = os.path.join(root, command_log["logRef"])
with open(log_path, "rb") as f:
    digest = hashlib.sha256(f.read()).hexdigest()
if digest != command_log["sha256"]:
    raise SystemExit("sha mismatch")
if command_log["exitCode"] != 0:
    raise SystemExit("command exit not zero")
PY
}

test_promote_gate_refuses_missing_integrated_evidence() {
  with_fixture
  local out
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" S0.storage_substrate_base 2>&1 || true)"
  assert_contains "$out" "required task not integrated" "promotion refuses missing evidence tasks"
  [[ ! -f "$GLUERUN_ORCH_DIR/gates/S0.storage_substrate_base.gate-result.json" ]] || fail "promotion wrote gate despite missing evidence"
}

test_promote_gate_refuses_unknown_node() {
  with_fixture
  local out rc=0
  # D9.bogus is in no promote/block registry; D2.contract is now supported.
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D9.bogus 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "promotion exited zero for an unsupported explicit node"
  assert_contains "$out" "unsupported gate promotion node" "promotion refuses an unregistered node"
}

test_promote_gate_propagates_failed_command_exit() {
  with_fixture
  write_storage_promotable_tasks
  local out rc=0
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="exit 23" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" S0.storage_substrate_base 2>&1)" || rc=$?
  [[ "$rc" -eq 23 ]] || fail "promotion command failure exit was not propagated: got $rc"
  assert_contains "$out" "gate promotion command failed node=S0.storage_substrate_base exit=23" "promotion reports failed command"
  [[ ! -f "$GLUERUN_ORCH_DIR/gates/S0.storage_substrate_base.gate-result.json" ]] || fail "promotion wrote gate despite failed command"
}

gate_status() {
  python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f).get("status", ""))
PY
}

test_unproven_storage_proof_stays_planner_eligible() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D1.contract internal/artifact
  write_passed_gate S0.storage_substrate_base internal/storage
  write_passed_gate D1.storage_spec internal/artifact
  # No durable proof integrated yet: the node must NOT be blocked. An authoritative
  # block would exclude it from the planner frontier, but L1 must stay free to build
  # the durable proof. It is skipped (no gate) and remains planner-eligible; the
  # red/green skip-guard certifies it later at promote time.
  "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.storage_proof >/dev/null 2>&1 || true
  [[ ! -f "$GLUERUN_ORCH_DIR/gates/D1.storage_proof.gate-result.json" ]] || fail "unproven storage_proof must not write a gate"
  assert_contains "$("$SCRIPT_DIR/dag.sh" next-areas)" '"node":"D1.storage_proof"' "unproven storage_proof stays on the planner frontier"
  "$SCRIPT_DIR/dag.sh" node-fields D1.storage_proof >/dev/null || fail "unproven storage_proof must remain planner-eligible"
}

test_unproven_storage_proof_does_not_advance_downstream() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D1.contract internal/artifact
  write_passed_gate S0.storage_substrate_base internal/storage
  write_passed_gate D1.storage_spec internal/artifact
  # Skipping (not promoting) an unproven storage_proof must NOT advance its
  # dependents: D1.service depends on D1.storage_proof, which is not passed.
  "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.storage_proof >/dev/null 2>&1 || true
  local out
  out="$("$SCRIPT_DIR/dag.sh" next-areas)"
  assert_not_contains "$out" '"node":"D1.service"' "an unproven storage_proof must not make a downstream node eligible"
  if "$SCRIPT_DIR/dag.sh" area-gate D1.service >/dev/null 2>&1; then
    fail "downstream of an unproven storage_proof must stay gated"
  fi
}

test_human_provision_block_is_idempotent_and_excludes_planner() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D1.contract internal/artifact
  write_passed_gate S0.storage_substrate_base internal/storage
  write_passed_gate D1.storage_spec internal/artifact
  write_task TASK-0368
  # Ready proof but no resolvable DSN -> authoritative HumanProvisionRequired
  # block. That block IS authoritative, so (a) it excludes the node from the
  # planner and (b) re-running with no DSN is a no-op (already-blocked).
  env -u GLUERUN_STORAGE_PROOF_DATABASE_URL -u GLUERUN_DATABASE_URL \
    GLUERUN_PROMOTE_GATE_COMMAND="printf 'ok\n'" \
    "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.storage_proof >/dev/null 2>&1 || true
  local out rc=0
  out="$("$SCRIPT_DIR/dag.sh" node-fields D1.storage_proof 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "a HumanProvisionRequired node must not be planner eligible"
  assert_contains "$out" "node has authoritative blocked gate: D1.storage_proof" "node-fields reports the authoritative block"
  out="$(env -u GLUERUN_STORAGE_PROOF_DATABASE_URL -u GLUERUN_DATABASE_URL \
        GLUERUN_PROMOTE_GATE_COMMAND="printf 'ok\n'" \
        "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.storage_proof 2>&1 || true)"
  assert_contains "$out" "already-blocked node=D1.storage_proof" "re-running with no DSN is idempotent"
}

test_generic_storage_proof_promotes_from_owned_repository_files() {
  with_fixture
  write_subgraph_dag
  # D3.storage_proof has NO explicit promoter arm; it must resolve generically
  # from any integrated task that owns the durable binding repository proof files.
  write_passed_gate D3.storage_spec internal/binding
  write_passed_gate D2.storage_proof internal/workflow
  write_scoped_task TASK-9001 integrated binding \
    "Durable binding repository round-trip proof" \
    "Implement the durable binding storage proof for D3.storage_proof." \
    "internal/binding/storage_repository.go" \
    "internal/binding/storage_repository_test.go"
  local out gate
  out="$(GLUERUN_STORAGE_PROOF_DATABASE_URL="postgres://fixture/skip-guard" \
        GLUERUN_PROOF_RED_COMMAND="exit 7" \
        GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" \
        "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D3.storage_proof 2>&1)"
  assert_contains "$out" "promoted node=D3.storage_proof" "D3.storage_proof auto-promotes from owned durable-proof files with no per-node registry arm"
  assert_contains "$out" "skip-guard-red=" "generic storage_proof promotion records a red skip-guard log"
  gate="$GLUERUN_ORCH_DIR/gates/D3.storage_proof.gate-result.json"
  assert_contains "$(gate_status "$gate")" "passed" "generic storage_proof promotion writes a passed gate"
  "$SCRIPT_DIR/dag.sh" area-gate D3.storage_proof >/dev/null
  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
if gate["evidence"][0]["ref"] != "internal/binding":
    raise SystemExit(f"unexpected source ref: {gate['evidence'][0]['ref']}")
if "TASK-9001" not in gate["evidence"][1]["taskIds"]:
    raise SystemExit("resolved durable-proof task missing from evidence")
if gate.get("upstreamGates") != ["D3.storage_spec", "D2.storage_proof"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates')}")
logs = [e for e in gate["evidence"] if e.get("kind") == "command-log"]
if not any(e["exitCode"] != 0 and "skip-guard-red" in e["ref"] for e in logs):
    raise SystemExit("generic storage_proof promotion missing skip-guard red command-log")
PY
}

test_promote_storage_proof_after_durable_task_integrated() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D1.contract internal/artifact
  write_passed_gate S0.storage_substrate_base internal/storage
  write_passed_gate D1.storage_spec internal/artifact
  "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.storage_proof >/dev/null 2>&1
  write_task TASK-0368

  local out gate
  out="$(GLUERUN_STORAGE_PROOF_DATABASE_URL="postgres://fixture/skip-guard" \
        GLUERUN_PROOF_RED_COMMAND="exit 7" \
        GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" \
        "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.storage_proof 2>&1)"
  assert_contains "$out" "promoted node=D1.storage_proof" "integrated durable proof supersedes the blocked D1.storage_proof gate"
  assert_contains "$out" "skip-guard-red=" "promotion records a red skip-guard log"
  gate="$GLUERUN_ORCH_DIR/gates/D1.storage_proof.gate-result.json"
  assert_contains "$(gate_status "$gate")" "passed" "storage_proof gate status is passed after durable proof"
  "$SCRIPT_DIR/dag.sh" area-gate D1.storage_proof >/dev/null
  local frontier
  frontier="$("$SCRIPT_DIR/dag.sh" next-areas)"
  assert_not_contains "$frontier" '"node":"D1.storage_proof"' "promoted storage_proof leaves the frontier"
  assert_contains "$frontier" '"node":"D1.service"' "promoted storage_proof advances downstream service work"
  python3 - "$gate" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
if "TASK-0368" not in gate["evidence"][1]["taskIds"]:
    raise SystemExit("TASK-0368 missing from promoted storage proof evidence")
upstream = set(gate.get("upstreamGates", []))
if upstream != {"D1.storage_spec", "S0.storage_substrate_base"}:
    raise SystemExit(f"unexpected upstream gates: {sorted(upstream)}")
logs = [e for e in gate["evidence"] if e.get("kind") == "command-log"]
if not any(e["exitCode"] == 0 for e in logs):
    raise SystemExit("promoted storage proof has no passing (green) command-log")
reds = [e for e in logs if e["exitCode"] != 0]
if not reds:
    raise SystemExit("promoted storage proof missing skip-guard red command-log")
if not any("skip-guard-red" in e["ref"] for e in reds):
    raise SystemExit("red command-log is not marked skip-guard-red")
PY
}

test_promote_d2_storage_proof_after_durable_task_integrated() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D1.storage_proof internal/artifact
  write_passed_gate D2.storage_spec internal/workflow
  "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D2.storage_proof >/dev/null 2>&1
  write_task TASK-0470

  local out gate
  out="$(GLUERUN_STORAGE_PROOF_DATABASE_URL="postgres://fixture/skip-guard" \
        GLUERUN_PROOF_RED_COMMAND="exit 7" \
        GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" \
        "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D2.storage_proof 2>&1)"
  assert_contains "$out" "promoted node=D2.storage_proof" "integrated durable workflow proof supersedes the blocked D2.storage_proof gate"
  gate="$GLUERUN_ORCH_DIR/gates/D2.storage_proof.gate-result.json"
  assert_contains "$(gate_status "$gate")" "passed" "D2.storage_proof gate status is passed after durable workflow proof"
  "$SCRIPT_DIR/dag.sh" area-gate D2.storage_proof >/dev/null
  local frontier
  frontier="$("$SCRIPT_DIR/dag.sh" next-areas)"
  assert_not_contains "$frontier" '"node":"D2.storage_proof"' "promoted D2.storage_proof leaves the frontier"
  python3 - "$gate" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
if gate["evidence"][0]["ref"] != "internal/workflow":
    raise SystemExit(f"unexpected source ref: {gate['evidence'][0]['ref']}")
if "TASK-0470" not in gate["evidence"][1]["taskIds"]:
    raise SystemExit("TASK-0470 missing from promoted workflow storage proof evidence")
if gate.get("upstreamGates", []) != ["D2.storage_spec", "D1.storage_proof"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates', [])}")
logs = [e for e in gate["evidence"] if e.get("kind") == "command-log"]
if not any(e["exitCode"] == 0 for e in logs):
    raise SystemExit("promoted workflow storage proof has no passing (green) command-log")
if not any(e["exitCode"] != 0 and "skip-guard-red" in e["ref"] for e in logs):
    raise SystemExit("promoted workflow storage proof missing skip-guard red command-log")
PY
}

test_storage_proof_refuses_vacuous_proof_when_skip_guard_passes() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D1.contract internal/artifact
  write_passed_gate S0.storage_substrate_base internal/storage
  write_passed_gate D1.storage_spec internal/artifact
  write_task TASK-0368
  local out rc=0
  # The RED skip-guard "passing" (exit 0) means the proof did NOT fail without
  # real storage — it is vacuous/mocked. Promotion must be refused and no passing
  # gate written; the node stays planner-eligible for a real proof.
  out="$(GLUERUN_STORAGE_PROOF_DATABASE_URL="postgres://fixture/skip-guard" \
        GLUERUN_PROOF_RED_COMMAND="true" \
        GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" \
        "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.storage_proof 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "vacuous storage proof (red passed) must not promote with exit 0"
  assert_contains "$out" "skip-guard RED passed with storage stripped" "refusal names the vacuous skip-guard"
  if "$SCRIPT_DIR/dag.sh" area-gate D1.storage_proof >/dev/null 2>&1; then
    fail "a refused (vacuous) storage proof must not pass area-gate"
  fi
  assert_contains "$("$SCRIPT_DIR/dag.sh" next-areas)" '"node":"D1.storage_proof"' "a refused vacuous proof leaves the node planner-eligible"
}

test_storage_proof_requires_external_database_when_unresolvable() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D1.contract internal/artifact
  write_passed_gate S0.storage_substrate_base internal/storage
  write_passed_gate D1.storage_spec internal/artifact
  write_task TASK-0368
  local out gate rationale
  # No DSN in the environment and no env files in the fixture: the one
  # legitimate stop. Promotion must record an authoritative HumanProvisionRequired
  # block rather than fake or silently skip the proof.
  out="$(env -u GLUERUN_STORAGE_PROOF_DATABASE_URL -u GLUERUN_DATABASE_URL \
        GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" \
        "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.storage_proof 2>&1)"
  assert_contains "$out" "blocked node=D1.storage_proof" "unresolvable DSN records a block, not a promotion"
  gate="$GLUERUN_ORCH_DIR/gates/D1.storage_proof.gate-result.json"
  assert_contains "$(gate_status "$gate")" "blocked" "HumanProvisionRequired gate status is blocked"
  rationale="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rationale"])' "$gate")"
  assert_contains "$rationale" "HumanProvisionRequired" "rationale marks an external-resource stop"
  assert_contains "$rationale" "GLUERUN_STORAGE_PROOF_DATABASE_URL" "rationale names the exact remediation env var"
  if "$SCRIPT_DIR/dag.sh" area-gate D1.storage_proof >/dev/null 2>&1; then
    fail "a HumanProvisionRequired gate must not pass area-gate"
  fi
}

test_storage_proof_dsn_from_env_file_does_not_leak_or_hijack() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D1.contract internal/artifact
  write_passed_gate S0.storage_substrate_base internal/storage
  write_passed_gate D1.storage_spec internal/artifact
  write_task TASK-0368
  # The DSN is available ONLY via the dedicated proof env file, which also carries
  # a control var (GLUERUN_PROMOTE_GATE_COMMAND) and an extra secret. Resolving the
  # DSN must NOT import the control var (which would hijack the green command) and
  # must NOT leak any secret value into output or committed evidence.
  mkdir -p "$GLUERUN_STATE_DIR"
  cat >"$GLUERUN_STATE_DIR/gluerun-storage-proof.env" <<'EOF'
export GLUERUN_STORAGE_PROOF_DATABASE_URL='postgres://proof-user:topsecretvalue@db.example/proof'
export GLUERUN_PROMOTE_GATE_COMMAND='exit 99'
export PGPASSWORD='another-secret-value'
EOF
  local out gate
  out="$(env -u GLUERUN_STORAGE_PROOF_DATABASE_URL -u GLUERUN_DATABASE_URL \
        GLUERUN_PROOF_RED_COMMAND="exit 1" \
        GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" \
        "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.storage_proof 2>&1)"
  # If the env file's GLUERUN_PROMOTE_GATE_COMMAND='exit 99' had leaked into the
  # shell, the green command would fail with exit 99 instead of promoting.
  assert_contains "$out" "promoted node=D1.storage_proof" "DSN resolves from the env file without importing its control vars"
  assert_not_contains "$out" "exit=99" "env-file GLUERUN_PROMOTE_GATE_COMMAND must not hijack the green command"
  gate="$GLUERUN_ORCH_DIR/gates/D1.storage_proof.gate-result.json"
  [[ -f "$gate" ]] || fail "gate was not written under the real gates dir"
  assert_not_contains "$out" "topsecretvalue" "DSN value must not leak to promotion output"
  assert_not_contains "$(cat "$gate")" "topsecretvalue" "DSN value must not leak into committed gate evidence"
  assert_not_contains "$(cat "$gate")" "another-secret-value" "env-file secrets must not leak into committed gate evidence"
}

test_dag_requires_red_skip_guard_for_non_grandfathered_storage_proof() {
  with_fixture
  write_subgraph_dag
  mkdir -p "$GLUERUN_ORCH_DIR/gates/evidence"
  local log="docs/orchestration/gates/evidence/green-only.txt"
  printf 'green-ok\n' > "$GLUERUN_ROOT/$log"
  local sha head
  sha="$(shasum -a 256 "$GLUERUN_ROOT/$log" | awk '{print $1}')"
  head="$(git -C "$GLUERUN_ROOT" rev-parse HEAD)"
  # dag.sh is the final authority: a green-only storage_proof gate must be
  # rejected for a non-grandfathered node, regardless of how it was produced.
  write_green_only_storage_proof_gate D3.storage_proof "$log" "$sha" "$head"
  local out rc=0
  out="$("$SCRIPT_DIR/dag.sh" area-gate D3.storage_proof 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "a green-only D3.storage_proof gate must be rejected by dag.sh"
  assert_contains "$out" "requires a red skip-guard" "dag.sh names the missing red skip-guard"
  # The two grandfathered nodes remain accepted with a single green.
  write_green_only_storage_proof_gate D1.storage_proof "$log" "$sha" "$head"
  "$SCRIPT_DIR/dag.sh" area-gate D1.storage_proof >/dev/null || fail "grandfathered D1.storage_proof green-only gate must still pass"
}

test_dag_rejects_unmarked_failed_storage_proof_log() {
  with_fixture
  write_subgraph_dag
  mkdir -p "$GLUERUN_ORCH_DIR/gates/evidence"
  local log="docs/orchestration/gates/evidence/green-plus-unmarked-red.txt"
  printf 'green-and-unmarked-red\n' > "$GLUERUN_ROOT/$log"
  local sha head
  sha="$(shasum -a 256 "$GLUERUN_ROOT/$log" | awk '{print $1}')"
  head="$(git -C "$GLUERUN_ROOT" rev-parse HEAD)"
  write_storage_proof_gate_with_unmarked_failed_log D3.storage_proof "$log" "$sha" "$head"
  local out rc=0
  out="$("$SCRIPT_DIR/dag.sh" area-gate D3.storage_proof 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "a storage_proof failed command-log must not count as red unless marked skip-guard-red"
  assert_contains "$out" "non-zero command-log must be marked as skip-guard red" "dag.sh rejects arbitrary failed logs as storage-proof red evidence"
}

test_storage_proof_ignores_command_overrides_without_fixture_flag() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D3.storage_spec internal/binding
  write_passed_gate D2.storage_proof internal/workflow
  write_scoped_task TASK-9002 integrated binding \
    "Durable binding repository round-trip proof" \
    "Implement the durable binding storage proof for D3.storage_proof." \
    "internal/binding/storage_repository.go" \
    "internal/binding/storage_repository_test.go"
  # Simulate production by removing GLUERUN_TEST_FIXTURE. The printf green override
  # and the 'true' red override MUST be ignored: the real `go build/vet/test ./...`
  # green then runs in a repo with no Go module and fails, so promotion is refused
  # at the green step. (If the override leaked into production, 'true' would make
  # the red pass and a vacuous proof could promote — the failure mode this guards.)
  local out rc=0
  out="$(env -u GLUERUN_TEST_FIXTURE \
        GLUERUN_STORAGE_PROOF_DATABASE_URL="postgres://fixture/skip-guard" \
        GLUERUN_PROOF_RED_COMMAND="true" \
        GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" \
        "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D3.storage_proof 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "production (no fixture flag) must not honor command overrides"
  assert_contains "$out" "gate promotion command failed" "the real green regression runs (overrides ignored) and fails in a no-module fixture"
  [[ ! -f "$GLUERUN_ORCH_DIR/gates/D3.storage_proof.gate-result.json" ]] || fail "must not promote when overrides are ignored"
}

test_promote_d2_contract_when_ready() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D1.contract internal/artifact
  write_workflow_contract_tasks
  local out gate
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D2.contract 2>&1)"
  assert_contains "$out" "promoted node=D2.contract" "ready D2.contract promotes"
  gate="$GLUERUN_ORCH_DIR/gates/D2.contract.gate-result.json"
  [[ -f "$gate" ]] || fail "promotion did not write D2.contract gate"
  assert_contains "$(gate_status "$gate")" "passed" "promoted D2.contract gate status is passed"
  "$SCRIPT_DIR/dag.sh" area-gate D2.contract >/dev/null
}

test_block_d2_contract_when_not_ready() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D1.contract internal/artifact
  write_workflow_contract_tasks_missing TASK-0048
  local out gate
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D2.contract 2>&1)"
  assert_contains "$out" "blocked node=D2.contract" "not-ready D2.contract is blocked, not promoted"
  gate="$GLUERUN_ORCH_DIR/gates/D2.contract.gate-result.json"
  assert_contains "$(gate_status "$gate")" "blocked" "not-ready D2.contract gate status is blocked"
  local rationale
  rationale="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rationale"])' "$gate")"
  assert_contains "$rationale" "TASK-0048" "blocked rationale names the unmet readiness predicate"
  if "$SCRIPT_DIR/dag.sh" area-gate D2.contract >/dev/null 2>&1; then
    fail "a blocked D2.contract must not pass area-gate"
  fi
}

	test_block_then_promote_supersedes() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D1.contract internal/artifact
  write_workflow_contract_tasks_missing TASK-0048
  GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D2.contract >/dev/null 2>&1
  # Satisfy the readiness predicate, then re-run: the block must be superseded.
  write_task TASK-0048
  local out
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D2.contract 2>&1)"
  assert_contains "$out" "promoted node=D2.contract" "a satisfied predicate supersedes a prior block"
	  assert_contains "$(gate_status "$GLUERUN_ORCH_DIR/gates/D2.contract.gate-result.json")" "passed" "superseded gate is now passed"
	}

	test_block_d1_service_uses_capability_signatures_not_original_task_ids() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D1.storage_proof internal/artifact
	  # TASK-0451 is a duplicate of the original alias closeout slice; its integrated
	  # capability must satisfy that predicate so the block names only remaining gaps.
	  write_service_alias_task TASK-0451
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.service 2>&1)"
	  assert_contains "$out" "blocked node=D1.service" "incomplete D1.service writes a blocked gate"
	  gate="$GLUERUN_ORCH_DIR/gates/D1.service.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "blocked" "D1.service closeout gate is blocked"
	  local gate_json rationale
	  gate_json="$(cat "$gate")"
	  rationale="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rationale"])' "$gate")"
	  assert_not_contains "$gate_json" "TASK-0435" "integrated duplicate TASK-0451 satisfies the alias predicate"
	  assert_contains "$gate_json" "TASK-0436" "missing collection member predicate is named"
	  assert_contains "$gate_json" "TASK-0437" "missing collection completeness predicate is named"
	  assert_contains "$gate_json" "TASK-0438" "missing required coverage predicate is named"
	  assert_contains "$rationale" "collection member-version" "blocked rationale names missing capability"
	  if "$SCRIPT_DIR/dag.sh" area-gate D1.service >/dev/null 2>&1; then
	    fail "a blocked D1.service gate must not pass area-gate"
	  fi
	}

	test_promote_d1_service_when_all_capability_signatures_integrated() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D1.storage_proof internal/artifact
	  write_service_alias_task TASK-0451
	  write_service_member_task TASK-0436
	  write_service_completeness_task TASK-0437
	  write_service_required_task TASK-0438
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.service 2>&1)"
	  assert_contains "$out" "promoted node=D1.service" "complete D1.service promotes"
	  gate="$GLUERUN_ORCH_DIR/gates/D1.service.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "passed" "D1.service gate is passed"
	  "$SCRIPT_DIR/dag.sh" area-gate D1.service >/dev/null
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
task_ids = gate["evidence"][1]["taskIds"]
for task_id in ("TASK-0451", "TASK-0436", "TASK-0437", "TASK-0438"):
    if task_id not in task_ids:
        raise SystemExit(f"missing service evidence task {task_id}")
if "TASK-0435" in task_ids:
    raise SystemExit("original blocked alias task should not be required when TASK-0451 satisfies the signature")
if gate.get("upstreamGates") != ["D1.storage_proof"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates')}")
PY
	}

	test_preblocked_d1_service_can_promote_from_new_capability_signature_task() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D1.storage_proof internal/artifact
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.service 2>&1)"
	  assert_contains "$out" "blocked node=D1.service" "incomplete D1.service writes initial blocked gate"
	  write_service_alias_task TASK-0451
	  write_service_member_task TASK-0452
	  write_service_completeness_task TASK-0437
	  write_service_required_task TASK-0438
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D1.service 2>&1)"
	  assert_contains "$out" "promoted node=D1.service" "preblocked D1.service promotes once capability signatures land"
	  gate="$GLUERUN_ORCH_DIR/gates/D1.service.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "passed" "D1.service gate is passed after capability match"
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
task_ids = gate["evidence"][1]["taskIds"]
if "TASK-0452" not in task_ids:
    raise SystemExit(f"new duplicate-by-capability task was not cited: {task_ids}")
if "TASK-0436" in task_ids:
    raise SystemExit("original blocked member task should not be required when TASK-0452 satisfies the signature")
PY
	}

	test_block_d2_storage_spec_with_split_upstream_gates() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D1.storage_spec internal/artifact
	  write_passed_gate D2.contract internal/workflow
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D2.storage_spec 2>&1)"
	  assert_contains "$out" "blocked node=D2.storage_spec" "incomplete D2.storage_spec writes a blocked gate"
	  gate="$GLUERUN_ORCH_DIR/gates/D2.storage_spec.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "blocked" "D2.storage_spec closeout gate is blocked"
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
if gate.get("upstreamGates") != ["D2.contract", "D1.storage_spec"]:
    raise SystemExit(f"upstream gates were not split: {gate.get('upstreamGates')}")
task_ids = set(gate["evidence"][1]["taskIds"])
for task_id in ("TASK-0439", "TASK-0440", "TASK-0441", "TASK-0442"):
    if task_id not in task_ids:
        raise SystemExit(f"missing storage spec predicate {task_id}")
PY
	  if "$SCRIPT_DIR/dag.sh" area-gate D2.storage_spec >/dev/null 2>&1; then
	    fail "a blocked D2.storage_spec gate must not pass area-gate"
	  fi
	}

test_promote_d2_storage_spec_when_all_capability_signatures_integrated() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D1.storage_spec internal/artifact
	  write_passed_gate D2.contract internal/workflow
	  write_workflow_record_storage_task TASK-0439
	  write_workflow_materialization_task TASK-0440
	  write_workflow_exact_ref_task TASK-0441
	  write_workflow_authority_task TASK-0442
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D2.storage_spec 2>&1)"
	  assert_contains "$out" "promoted node=D2.storage_spec" "complete D2.storage_spec promotes"
	  gate="$GLUERUN_ORCH_DIR/gates/D2.storage_spec.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "passed" "D2.storage_spec gate is passed"
	  "$SCRIPT_DIR/dag.sh" area-gate D2.storage_spec >/dev/null
	}

	test_block_d3_contract_when_continuation_closeout_missing() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D2.contract internal/workflow
	  write_binding_contract_tasks_missing TASK-0369
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D3.contract 2>&1)"
	  assert_contains "$out" "blocked node=D3.contract" "incomplete D3.contract writes a blocked gate"
	  gate="$GLUERUN_ORCH_DIR/gates/D3.contract.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "blocked" "D3.contract gate is blocked"
	  local rationale
	  rationale="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rationale"])' "$gate")"
	  assert_contains "$rationale" "TASK-0369" "blocked D3.contract rationale names the missing continuation predicate"
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
if gate.get("upstreamGates") != ["D2.contract"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates')}")
task_ids = set(gate["evidence"][1]["taskIds"])
if "TASK-0369" not in task_ids:
    raise SystemExit(f"missing continuation closeout task in blocked evidence: {task_ids}")
PY
	  if "$SCRIPT_DIR/dag.sh" area-gate D3.contract >/dev/null 2>&1; then
	    fail "a blocked D3.contract gate must not pass area-gate"
	  fi
	}

	test_promote_d3_contract_when_binding_contract_tasks_integrated() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D2.contract internal/workflow
	  write_binding_contract_tasks
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D3.contract 2>&1)"
	  assert_contains "$out" "promoted node=D3.contract" "complete D3.contract promotes"
	  gate="$GLUERUN_ORCH_DIR/gates/D3.contract.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "passed" "D3.contract gate is passed"
	  "$SCRIPT_DIR/dag.sh" area-gate D3.contract >/dev/null
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
task_ids = gate["evidence"][1]["taskIds"]
for task_id in ("TASK-0049", "TASK-0071", "TASK-0369"):
    if task_id not in task_ids:
        raise SystemExit(f"missing binding contract evidence task {task_id}")
if gate.get("upstreamGates") != ["D2.contract"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates')}")
PY
	}

	test_block_d4_contract_when_dispatch_reconstruction_missing() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D3.contract internal/binding
	  write_dispatch_contract_tasks_missing TASK-0096
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D4.contract 2>&1)"
	  assert_contains "$out" "blocked node=D4.contract" "incomplete D4.contract writes a blocked gate"
	  gate="$GLUERUN_ORCH_DIR/gates/D4.contract.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "blocked" "D4.contract gate is blocked"
	  local rationale
	  rationale="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rationale"])' "$gate")"
	  assert_contains "$rationale" "TASK-0096" "blocked D4.contract rationale names the missing reconstruction predicate"
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
if gate.get("upstreamGates") != ["D3.contract"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates')}")
task_ids = set(gate["evidence"][1]["taskIds"])
if "TASK-0096" not in task_ids:
    raise SystemExit(f"missing dispatch reconstruction task in blocked evidence: {task_ids}")
PY
	  if "$SCRIPT_DIR/dag.sh" area-gate D4.contract >/dev/null 2>&1; then
	    fail "a blocked D4.contract gate must not pass area-gate"
	  fi
	}

	test_promote_d4_contract_when_dispatch_contract_tasks_integrated() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D3.contract internal/binding
	  write_dispatch_contract_tasks
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D4.contract 2>&1)"
	  assert_contains "$out" "promoted node=D4.contract" "complete D4.contract promotes"
	  gate="$GLUERUN_ORCH_DIR/gates/D4.contract.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "passed" "D4.contract gate is passed"
	  "$SCRIPT_DIR/dag.sh" area-gate D4.contract >/dev/null
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
task_ids = gate["evidence"][1]["taskIds"]
for task_id in ("TASK-0072", "TASK-0084", "TASK-0096"):
    if task_id not in task_ids:
        raise SystemExit(f"missing dispatch contract evidence task {task_id}")
if gate.get("upstreamGates") != ["D3.contract"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates')}")
PY
	}

	test_block_d5_contract_when_evidence_history_consistency_missing() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D4.contract internal/dispatch
	  write_evidence_contract_tasks_missing TASK-0131
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D5.contract 2>&1)"
	  assert_contains "$out" "blocked node=D5.contract" "incomplete D5.contract writes a blocked gate"
	  gate="$GLUERUN_ORCH_DIR/gates/D5.contract.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "blocked" "D5.contract gate is blocked"
	  local rationale
	  rationale="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rationale"])' "$gate")"
	  assert_contains "$rationale" "TASK-0131" "blocked D5.contract rationale names the missing finding history predicate"
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
if gate.get("upstreamGates") != ["D4.contract"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates')}")
task_ids = set(gate["evidence"][1]["taskIds"])
if "TASK-0131" not in task_ids:
    raise SystemExit(f"missing finding history consistency task in blocked evidence: {task_ids}")
PY
	  if "$SCRIPT_DIR/dag.sh" area-gate D5.contract >/dev/null 2>&1; then
	    fail "a blocked D5.contract gate must not pass area-gate"
	  fi
	}

	test_promote_d5_contract_when_evidence_contract_tasks_integrated() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D4.contract internal/dispatch
	  write_evidence_contract_tasks
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D5.contract 2>&1)"
	  assert_contains "$out" "promoted node=D5.contract" "complete D5.contract promotes"
	  gate="$GLUERUN_ORCH_DIR/gates/D5.contract.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "passed" "D5.contract gate is passed"
	  "$SCRIPT_DIR/dag.sh" area-gate D5.contract >/dev/null
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
task_ids = gate["evidence"][1]["taskIds"]
for task_id in ("TASK-0097", "TASK-0104", "TASK-0128", "TASK-0131"):
    if task_id not in task_ids:
        raise SystemExit(f"missing evidence contract task {task_id}")
if gate.get("upstreamGates") != ["D4.contract"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates')}")
PY
	}

	test_block_d6_contract_when_replay_reconstruction_missing() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D5.contract internal/evidence
	  write_recovery_contract_tasks_missing TASK-0171
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D6.contract 2>&1)"
	  assert_contains "$out" "blocked node=D6.contract" "incomplete D6.contract writes a blocked gate"
	  gate="$GLUERUN_ORCH_DIR/gates/D6.contract.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "blocked" "D6.contract gate is blocked"
	  local rationale
	  rationale="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rationale"])' "$gate")"
	  assert_contains "$rationale" "TASK-0171" "blocked D6.contract rationale names the missing replay reconstruction predicate"
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
if gate.get("upstreamGates") != ["D5.contract"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates')}")
task_ids = set(gate["evidence"][1]["taskIds"])
if "TASK-0171" not in task_ids:
    raise SystemExit(f"missing replay reconstruction task in blocked evidence: {task_ids}")
PY
	  if "$SCRIPT_DIR/dag.sh" area-gate D6.contract >/dev/null 2>&1; then
	    fail "a blocked D6.contract gate must not pass area-gate"
	  fi
	}

	test_promote_d6_contract_when_recovery_contract_tasks_integrated() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D5.contract internal/evidence
	  write_recovery_contract_tasks
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D6.contract 2>&1)"
	  assert_contains "$out" "promoted node=D6.contract" "complete D6.contract promotes"
	  gate="$GLUERUN_ORCH_DIR/gates/D6.contract.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "passed" "D6.contract gate is passed"
	  "$SCRIPT_DIR/dag.sh" area-gate D6.contract >/dev/null
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
task_ids = gate["evidence"][1]["taskIds"]
for task_id in ("TASK-0132", "TASK-0141", "TASK-0163", "TASK-0171"):
    if task_id not in task_ids:
        raise SystemExit(f"missing recovery contract task {task_id}")
if gate.get("upstreamGates") != ["D5.contract"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates')}")
PY
	}

	test_block_d7_contract_when_scheduler_reconciliation_missing() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D6.contract internal/recovery
	  write_scheduler_contract_tasks_missing TASK-0312
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D7.contract 2>&1)"
	  assert_contains "$out" "blocked node=D7.contract" "incomplete D7.contract writes a blocked gate"
	  gate="$GLUERUN_ORCH_DIR/gates/D7.contract.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "blocked" "D7.contract gate is blocked"
	  local rationale
	  rationale="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rationale"])' "$gate")"
	  assert_contains "$rationale" "TASK-0312" "blocked D7.contract rationale names the missing run advancement reconciliation predicate"
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
if gate.get("upstreamGates") != ["D6.contract"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates')}")
task_ids = set(gate["evidence"][1]["taskIds"])
if "TASK-0312" not in task_ids:
    raise SystemExit(f"missing scheduler reconciliation task in blocked evidence: {task_ids}")
PY
	  if "$SCRIPT_DIR/dag.sh" area-gate D7.contract >/dev/null 2>&1; then
	    fail "a blocked D7.contract gate must not pass area-gate"
	  fi
	}

	test_promote_d7_contract_when_scheduler_contract_tasks_integrated() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D6.contract internal/recovery
	  write_scheduler_contract_tasks
	  local out gate
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D7.contract 2>&1)"
	  assert_contains "$out" "promoted node=D7.contract" "complete D7.contract promotes"
	  gate="$GLUERUN_ORCH_DIR/gates/D7.contract.gate-result.json"
	  assert_contains "$(gate_status "$gate")" "passed" "D7.contract gate is passed"
	  "$SCRIPT_DIR/dag.sh" area-gate D7.contract >/dev/null
	  python3 - "$gate" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    gate = json.load(f)
task_ids = gate["evidence"][1]["taskIds"]
for task_id in ("TASK-0172", "TASK-0212", "TASK-0266", "TASK-0312"):
    if task_id not in task_ids:
        raise SystemExit(f"missing scheduler contract task {task_id}")
if gate.get("upstreamGates") != ["D6.contract"]:
    raise SystemExit(f"unexpected upstream gates: {gate.get('upstreamGates')}")
PY
	}

	test_frontier_blocks_closeout_nodes_without_noop() {
	  with_fixture
	  write_subgraph_dag
	  write_passed_gate D1.storage_proof internal/artifact
	  write_passed_gate D1.storage_spec internal/artifact
	  write_passed_gate D2.contract internal/workflow
	  local out
	  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" --frontier 2>&1)"
	  assert_contains "$out" "blocked node=D1.service" "frontier blocks service closeout instead of skipping it"
	  assert_contains "$out" "blocked node=D2.storage_spec" "frontier blocks workflow storage-spec closeout instead of skipping it"
	  assert_contains "$out" "blocked node=D3.contract" "frontier blocks D3.contract closeout instead of skipping it"
	  assert_not_contains "$out" "no promotable frontier gates" "frontier mode does not silently no-op on closeout nodes"
	}

test_frontier_promotes_ready_and_skips_unproven_storage_proof() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D1.contract internal/artifact
  write_passed_gate S0.storage_substrate_base internal/storage
  write_passed_gate D1.storage_spec internal/artifact
  write_workflow_contract_tasks
  local out
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" --frontier 2>&1)"
  assert_contains "$out" "promoted node=D2.contract" "frontier mode promotes the ready contract node"
  assert_not_contains "$out" "blocked node=D1.storage_proof" "an unproven storage_proof is skipped, not blocked"
  [[ ! -f "$GLUERUN_ORCH_DIR/gates/D1.storage_proof.gate-result.json" ]] || fail "unproven storage_proof must not get a gate in frontier mode"
  assert_not_contains "$out" "no promotable frontier gates" "frontier mode does not silently no-op on the real frontier"
  assert_contains "$("$SCRIPT_DIR/dag.sh" next-areas)" '"node":"D1.storage_proof"' "unproven storage_proof remains planner-eligible after a frontier pass"
}

test_reconcile_auto_promotes_before_generation() {
  with_fixture
  write_storage_promotable_tasks
  local out
  out="$(GLUERUN_AUTO_PROMOTE_GATES=1 GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" GLUERUN_GENERATE=0 "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1)"
  assert_contains "$out" "promotion: promoted node=S0.storage_substrate_base" "reconcile auto-promotes ready candidate gate"
  "$SCRIPT_DIR/dag.sh" area-gate S0.storage_substrate_base >/dev/null
  out="$("$SCRIPT_DIR/dag.sh" next-areas)"
  assert_not_contains "$out" '"node":"S0.storage_substrate_base"' "promoted S0 leaves frontier"
  assert_contains "$out" '"node":"D1.storage_proof"' "dependent node becomes eligible after promotion"
}

# --- Change-set A: frontier completion predicates for D2.service / D8.contract /
# --- D3.storage_spec, plus the dag.sh grandfathered-evidenceClass bypass guard.

# Write one integrated, owned-file-scoped task per capability (impl + test) so a
# signature-mode predicate resolves each capability by its owned files.
write_owned_capability_tasks() {
  local area="$1"; shift
  # Persistent counter so multiple calls in one test never collide on task IDs.
  : "${WOCT_IDX:=9100}"
  local base
  for base in "$@"; do
    write_scoped_task "TASK-$WOCT_IDX" integrated "$area" \
      "$base capability fixture" "Integrate $base for a signature predicate." \
      "internal/$area/$base.go" "internal/$area/${base}_test.go"
    WOCT_IDX=$((WOCT_IDX + 1))
  done
}

test_promote_d2_service_when_all_service_signatures_integrated() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D2.storage_proof internal/workflow
  write_passed_gate D1.service internal/artifact
  write_owned_capability_tasks workflow \
    service_fixed_template_publication service_fixed_workflow_bootstrap \
    service_fixed_workflow_snapshot service_run_instantiation \
    service_initial_node_run_persistence service_run_snapshot \
    service_run_output_projection service_output_artifact_lookup \
    service_input_artifact_lookup service_node_run_lookup \
    service_node_run_terminal_snapshot service_workflow_run_status_event \
    service_runtime
  local out gate
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D2.service 2>&1)"
  assert_contains "$out" "promoted node=D2.service" "D2.service promotes when all 13 service capability signatures are integrated"
  gate="$GLUERUN_ORCH_DIR/gates/D2.service.gate-result.json"
  assert_contains "$(gate_status "$gate")" "passed" "D2.service gate is passed"
  "$SCRIPT_DIR/dag.sh" area-gate D2.service >/dev/null
}

test_promote_d8_contract_when_all_product_signatures_integrated() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D7.contract internal/scheduler
  write_owned_capability_tasks product \
    command_envelope query_envelope projection_ref command_result \
    projection_staleness spec_studio_projection canvas_runtime_status_projection \
    canvas_node_projection canvas_edge_projection canvas_graph_projection \
    dispatch_tree_projection
  local out gate
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D8.contract 2>&1)"
  assert_contains "$out" "promoted node=D8.contract" "D8.contract promotes when all 11 product contract signatures are integrated"
  gate="$GLUERUN_ORCH_DIR/gates/D8.contract.gate-result.json"
  assert_contains "$(gate_status "$gate")" "passed" "D8.contract gate is passed"
  "$SCRIPT_DIR/dag.sh" area-gate D8.contract >/dev/null
}

test_d3_storage_spec_skips_not_blocks_when_required_spec_missing() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D3.contract internal/binding
  write_passed_gate D2.storage_spec internal/workflow
  # Integrate 17 of the 19 required binding storage specs; omit the immutable change
  # boundary and resolved workspace context attachment specs (the accepted-but-not-
  # integrated slices in production) so D3.storage_spec is incomplete.
  write_owned_capability_tasks binding \
    storage_record_coverage_spec storage_materialization_path_spec \
    storage_exact_ref_boundary_spec storage_authority_boundary_spec \
    storage_context_pack_spec storage_context_explanation_spec \
    storage_context_staleness_invalidation_spec storage_credential_attachment_spec \
    storage_credential_binding_ref_spec storage_policy_evaluation_spec \
    storage_policy_preflight_attachment_spec storage_resolved_dispatch_binding_spec \
    storage_resolved_dispatch_idempotency_spec storage_resolved_runtime_selection_spec \
    storage_workspace_attempt_isolation_spec storage_workspace_lease_history_spec \
    storage_workspace_snapshot_manifest_spec
  local out
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" --frontier 2>&1)"
  # An incomplete storage_spec must SKIP (no gate, stays planner-eligible), never
  # block: an authoritative block would exclude it from the planner and strand
  # D3.storage_proof's eventual red/green proof.
  assert_not_contains "$out" "blocked node=D3.storage_spec" "incomplete D3.storage_spec must skip, not block"
  [[ ! -f "$GLUERUN_ORCH_DIR/gates/D3.storage_spec.gate-result.json" ]] || fail "skipped D3.storage_spec must not get an authoritative gate"
  assert_contains "$("$SCRIPT_DIR/dag.sh" next-areas)" '"node":"D3.storage_spec"' "incomplete D3.storage_spec stays planner-eligible"
}

test_dag_rejects_grandfathered_evidenceclass_bypass_for_storage_proof() {
  with_fixture
  write_subgraph_dag
  # The evidenceClass bypass: a non-grandfathered storage_proof gate that labels
  # itself "grandfathered" would otherwise skip the entire red/green validator via
  # dag.sh's early return. dag.sh must reject it; the exemption stays node-ID-scoped.
  write_passed_gate D3.storage_proof internal/binding
  local out rc=0
  out="$("$SCRIPT_DIR/dag.sh" area-gate D3.storage_proof 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "a grandfathered-evidenceClass D3.storage_proof gate must be rejected"
  assert_contains "$out" "must declare evidenceClass='deterministic-proof'" "dag.sh names the grandfathered evidenceClass bypass"
  # Layer-scoped: grandfathered stays legal for the D1/D2 storage proofs and for
  # non-storage_proof layers (contract).
  write_passed_gate D1.storage_proof internal/artifact
  "$SCRIPT_DIR/dag.sh" area-gate D1.storage_proof >/dev/null || fail "grandfathered D1.storage_proof must still pass"
  write_passed_gate D0.contract internal/kernel
  "$SCRIPT_DIR/dag.sh" area-gate D0.contract >/dev/null || fail "grandfathered D0.contract (non-storage_proof) must still pass"
}

test_d2_service_and_d8_contract_skip_not_block_when_a_signature_is_missing() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D2.storage_proof internal/workflow
  write_passed_gate D1.service internal/artifact
  write_passed_gate D7.contract internal/scheduler
  # D2.service and D8.contract are signature predicates that are NOT in
  # node_is_promote_or_block: a missing capability must make them SKIP (stay
  # planner-eligible), never write an authoritative blocked gate (which would
  # exclude them from the planner and, for D8.contract, strand D8.projection_storage).
  # Integrate every capability EXCEPT one for each node.
  write_owned_capability_tasks workflow \
    service_fixed_template_publication service_fixed_workflow_bootstrap \
    service_fixed_workflow_snapshot service_run_instantiation \
    service_initial_node_run_persistence service_run_snapshot \
    service_run_output_projection service_output_artifact_lookup \
    service_input_artifact_lookup service_node_run_lookup \
    service_node_run_terminal_snapshot service_workflow_run_status_event
  write_owned_capability_tasks product \
    command_envelope query_envelope projection_ref command_result \
    projection_staleness spec_studio_projection canvas_runtime_status_projection \
    canvas_node_projection canvas_edge_projection canvas_graph_projection
  local out
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" --frontier 2>&1)"
  assert_not_contains "$out" "blocked node=D2.service" "incomplete D2.service must skip, not block"
  assert_not_contains "$out" "blocked node=D8.contract" "incomplete D8.contract must skip, not block"
  [[ ! -f "$GLUERUN_ORCH_DIR/gates/D2.service.gate-result.json" ]] || fail "skipped D2.service must not get an authoritative gate"
  [[ ! -f "$GLUERUN_ORCH_DIR/gates/D8.contract.gate-result.json" ]] || fail "skipped D8.contract must not get an authoritative gate"
  local frontier
  frontier="$("$SCRIPT_DIR/dag.sh" next-areas)"
  assert_contains "$frontier" '"node":"D2.service"' "incomplete D2.service stays planner-eligible"
  assert_contains "$frontier" '"node":"D8.contract"' "incomplete D8.contract stays planner-eligible"
}

test_promote_d3_storage_spec_when_all_capability_signatures_integrated() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D3.contract internal/binding
  write_passed_gate D2.storage_spec internal/workflow
  # All 20 required binding storage-spec capabilities integrated (the foundational
  # storage_spec unit plus the 19 closeout slices) -> D3.storage_spec promotes.
  write_owned_capability_tasks binding \
    storage_spec storage_record_coverage_spec storage_materialization_path_spec \
    storage_exact_ref_boundary_spec storage_authority_boundary_spec \
    storage_context_pack_spec storage_context_explanation_spec \
    storage_context_staleness_invalidation_spec storage_credential_attachment_spec \
    storage_credential_binding_ref_spec storage_policy_evaluation_spec \
    storage_policy_preflight_attachment_spec storage_resolved_dispatch_binding_spec \
    storage_resolved_dispatch_idempotency_spec storage_resolved_runtime_selection_spec \
    storage_workspace_attempt_isolation_spec storage_workspace_lease_history_spec \
    storage_workspace_snapshot_manifest_spec storage_immutable_change_boundary_spec \
    storage_resolved_workspace_context_attachment_spec
  local out gate
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D3.storage_spec 2>&1)"
  assert_contains "$out" "promoted node=D3.storage_spec" "D3.storage_spec promotes once all 20 binding storage-spec signatures are integrated"
  gate="$GLUERUN_ORCH_DIR/gates/D3.storage_spec.gate-result.json"
  assert_contains "$(gate_status "$gate")" "passed" "D3.storage_spec gate is passed"
  "$SCRIPT_DIR/dag.sh" area-gate D3.storage_spec >/dev/null
}

test_promote_d3_binding_runtime_when_all_runtime_signatures_integrated() {
  with_fixture
  write_subgraph_dag
  write_valid_storage_proof_gate D3.storage_proof internal/binding
  write_passed_gate D2.service internal/workflow
  write_owned_capability_tasks binding \
    service_runtime runtime_resolved_dispatch_idempotency_query \
    runtime_resolved_runtime_selection_query runtime_resolved_workspace_context_attachment_query \
    runtime_resolved_credential_attachment_query runtime_resolved_policy_budget_preflight_query \
    runtime_context_explanation_query runtime_resolved_continuation_policy_query \
    runtime_context_staleness_invalidation_query runtime_workspace_boundary_query \
    runtime_idempotent_resolution_command runtime_reconstruction_bundle_query \
    runtime_workflow_conformance_check runtime_workspace_lease_usability_guard
  local out gate
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D3.binding_runtime 2>&1)"
  assert_contains "$out" "promoted node=D3.binding_runtime" "D3.binding_runtime promotes when all 14 binding runtime signatures are integrated"
  gate="$GLUERUN_ORCH_DIR/gates/D3.binding_runtime.gate-result.json"
  assert_contains "$(gate_status "$gate")" "passed" "D3.binding_runtime gate is passed"
  "$SCRIPT_DIR/dag.sh" area-gate D3.binding_runtime >/dev/null
}

test_d3_binding_runtime_and_d4_storage_spec_skip_not_block_when_a_signature_is_missing() {
  with_fixture
  write_subgraph_dag
  write_valid_storage_proof_gate D3.storage_proof internal/binding
  write_passed_gate D2.service internal/workflow
  write_passed_gate D4.contract internal/dispatch
  write_passed_gate D3.storage_spec internal/binding
  write_owned_capability_tasks binding \
    service_runtime runtime_resolved_dispatch_idempotency_query \
    runtime_resolved_runtime_selection_query runtime_resolved_workspace_context_attachment_query \
    runtime_resolved_credential_attachment_query runtime_resolved_policy_budget_preflight_query \
    runtime_context_explanation_query runtime_resolved_continuation_policy_query \
    runtime_context_staleness_invalidation_query runtime_workspace_boundary_query \
    runtime_idempotent_resolution_command runtime_reconstruction_bundle_query \
    runtime_workflow_conformance_check
  write_owned_capability_tasks dispatch \
    storage_agent_dispatch_spec storage_tool_invocation_spec \
    storage_record_coverage_spec storage_materialization_path_spec \
    storage_exact_ref_boundary_spec storage_authority_boundary_spec \
    storage_dispatch_status_transition_spec storage_tool_status_transition_spec \
    storage_dispatch_tree_query_spec storage_tool_invocation_timeline_query_spec \
    storage_dispatch_output_artifact_refs_query_spec storage_runtime_raw_output_refs_query_spec \
    storage_dispatch_usage_rollup_inputs_query_spec
  local out frontier
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" --frontier 2>&1)"
  assert_not_contains "$out" "blocked node=D3.binding_runtime" "incomplete D3.binding_runtime must skip, not block"
  assert_not_contains "$out" "blocked node=D4.storage_spec" "incomplete D4.storage_spec must skip, not block"
  [[ ! -f "$GLUERUN_ORCH_DIR/gates/D3.binding_runtime.gate-result.json" ]] || fail "skipped D3.binding_runtime must not get an authoritative gate"
  [[ ! -f "$GLUERUN_ORCH_DIR/gates/D4.storage_spec.gate-result.json" ]] || fail "skipped D4.storage_spec must not get an authoritative gate"
  frontier="$("$SCRIPT_DIR/dag.sh" next-areas)"
  assert_contains "$frontier" '"node":"D3.binding_runtime"' "incomplete D3.binding_runtime stays planner-eligible"
  assert_contains "$frontier" '"node":"D4.storage_spec"' "incomplete D4.storage_spec stays planner-eligible"
}

test_promote_d4_storage_spec_when_all_dispatch_storage_signatures_integrated() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D4.contract internal/dispatch
  write_passed_gate D3.storage_spec internal/binding
  write_owned_capability_tasks dispatch \
    storage_agent_dispatch_spec storage_tool_invocation_spec \
    storage_record_coverage_spec storage_materialization_path_spec \
    storage_exact_ref_boundary_spec storage_authority_boundary_spec \
    storage_dispatch_status_transition_spec storage_tool_status_transition_spec \
    storage_dispatch_tree_query_spec storage_tool_invocation_timeline_query_spec \
    storage_dispatch_output_artifact_refs_query_spec storage_runtime_raw_output_refs_query_spec \
    storage_dispatch_usage_rollup_inputs_query_spec storage_tool_side_effect_audit_query_spec
  local out gate
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D4.storage_spec 2>&1)"
  assert_contains "$out" "promoted node=D4.storage_spec" "D4.storage_spec promotes when all 14 dispatch storage-spec signatures are integrated"
  gate="$GLUERUN_ORCH_DIR/gates/D4.storage_spec.gate-result.json"
  assert_contains "$(gate_status "$gate")" "passed" "D4.storage_spec gate is passed"
  "$SCRIPT_DIR/dag.sh" area-gate D4.storage_spec >/dev/null
}

test_promote_d4_dispatch_runtime_when_all_runtime_signatures_integrated() {
  with_fixture
  write_subgraph_dag
  write_valid_storage_proof_gate D4.storage_proof internal/dispatch
  write_passed_gate D3.binding_runtime internal/binding
  write_owned_capability_tasks dispatch \
    runtime_dispatch_start_service runtime_tool_invocation_service
  local out gate
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D4.dispatch_runtime 2>&1)"
  assert_contains "$out" "promoted node=D4.dispatch_runtime" "D4.dispatch_runtime promotes when both dispatch runtime signatures are integrated"
  gate="$GLUERUN_ORCH_DIR/gates/D4.dispatch_runtime.gate-result.json"
  assert_contains "$(gate_status "$gate")" "passed" "D4.dispatch_runtime gate is passed"
  "$SCRIPT_DIR/dag.sh" area-gate D4.dispatch_runtime >/dev/null
}

test_promote_d5_storage_spec_when_all_evidence_storage_signatures_integrated() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D5.contract internal/evidence
  write_passed_gate D4.storage_spec internal/dispatch
  write_owned_capability_tasks evidence \
    storage_evidence_bundle_spec storage_finding_set_spec \
    storage_policy_evaluation_spec storage_decision_record_spec \
    storage_gate_decision_spec storage_waiver_detail_spec
  local out gate
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D5.storage_spec 2>&1)"
  assert_contains "$out" "promoted node=D5.storage_spec" "D5.storage_spec promotes when all 6 evidence storage-spec signatures are integrated"
  gate="$GLUERUN_ORCH_DIR/gates/D5.storage_spec.gate-result.json"
  assert_contains "$(gate_status "$gate")" "passed" "D5.storage_spec gate is passed"
  "$SCRIPT_DIR/dag.sh" area-gate D5.storage_spec >/dev/null
}

test_d4_dispatch_runtime_and_d5_storage_spec_skip_not_block_when_a_signature_is_missing() {
  with_fixture
  write_subgraph_dag
  write_valid_storage_proof_gate D4.storage_proof internal/dispatch
  write_passed_gate D3.binding_runtime internal/binding
  write_passed_gate D5.contract internal/evidence
  write_passed_gate D4.storage_spec internal/dispatch
  write_owned_capability_tasks dispatch runtime_dispatch_start_service
  write_owned_capability_tasks evidence \
    storage_evidence_bundle_spec storage_finding_set_spec \
    storage_policy_evaluation_spec storage_decision_record_spec \
    storage_gate_decision_spec
  local out frontier
  out="$(GLUERUN_PROMOTE_GATE_COMMAND="printf 'promotion-ok\n'" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" --frontier 2>&1)"
  assert_not_contains "$out" "blocked node=D4.dispatch_runtime" "incomplete D4.dispatch_runtime must skip, not block"
  assert_not_contains "$out" "blocked node=D5.storage_spec" "incomplete D5.storage_spec must skip, not block"
  [[ ! -f "$GLUERUN_ORCH_DIR/gates/D4.dispatch_runtime.gate-result.json" ]] || fail "skipped D4.dispatch_runtime must not get an authoritative gate"
  [[ ! -f "$GLUERUN_ORCH_DIR/gates/D5.storage_spec.gate-result.json" ]] || fail "skipped D5.storage_spec must not get an authoritative gate"
  frontier="$("$SCRIPT_DIR/dag.sh" next-areas)"
  assert_contains "$frontier" '"node":"D4.dispatch_runtime"' "incomplete D4.dispatch_runtime stays planner-eligible"
  assert_contains "$frontier" '"node":"D5.storage_spec"' "incomplete D5.storage_spec stays planner-eligible"
}

test_promote_d4_storage_proof_when_dispatch_proof_signatures_integrated() {
  with_fixture
  write_subgraph_dag
  write_passed_gate D4.storage_spec internal/dispatch
  write_valid_storage_proof_gate D3.storage_proof internal/binding
  write_owned_capability_tasks dispatch \
    storage_agent_dispatch_repository storage_tool_invocation_repository
  local out gate
  out="$(GLUERUN_TEST_FIXTURE=1 GLUERUN_STORAGE_PROOF_DATABASE_URL="postgres://fixture/skip-guard" GLUERUN_PROMOTE_GATE_COMMAND="printf 'green\n'" GLUERUN_PROOF_RED_COMMAND="printf 'red\n'; exit 1" "$ENGINE_HOME/gluerun-ext/promote-gate.sh" D4.storage_proof 2>&1)"
  assert_contains "$out" "promoted node=D4.storage_proof" "D4.storage_proof promotes when both dispatch durable proof signatures are integrated"
  gate="$GLUERUN_ORCH_DIR/gates/D4.storage_proof.gate-result.json"
  assert_contains "$(gate_status "$gate")" "passed" "D4.storage_proof gate is passed"
  "$SCRIPT_DIR/dag.sh" area-gate D4.storage_proof >/dev/null
  python3 - "$gate" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    gate = json.load(f)
if gate.get("evidenceClass") != "deterministic-proof":
    raise SystemExit("D4 storage proof must use deterministic-proof evidence")
if not any(e.get("kind") == "command-log" and e.get("exitCode", 0) != 0 and str(e.get("ref", "")).endswith("-skip-guard-red") for e in gate.get("evidence", [])):
    raise SystemExit("D4 storage proof gate missing marked red skip-guard command log")
PY
}

test_promote_storage_substrate_gate_writes_authoritative_gate
test_promote_gate_refuses_missing_integrated_evidence
test_promote_gate_refuses_unknown_node
test_promote_gate_propagates_failed_command_exit
test_reconcile_auto_promotes_before_generation
test_unproven_storage_proof_stays_planner_eligible
test_unproven_storage_proof_does_not_advance_downstream
test_human_provision_block_is_idempotent_and_excludes_planner
test_generic_storage_proof_promotes_from_owned_repository_files
test_promote_storage_proof_after_durable_task_integrated
	test_promote_d2_storage_proof_after_durable_task_integrated
	test_storage_proof_refuses_vacuous_proof_when_skip_guard_passes
	test_storage_proof_requires_external_database_when_unresolvable
	test_storage_proof_dsn_from_env_file_does_not_leak_or_hijack
	test_dag_requires_red_skip_guard_for_non_grandfathered_storage_proof
	test_dag_rejects_unmarked_failed_storage_proof_log
	test_storage_proof_ignores_command_overrides_without_fixture_flag
	test_promote_d2_contract_when_ready
	test_block_d2_contract_when_not_ready
	test_block_then_promote_supersedes
	test_block_d1_service_uses_capability_signatures_not_original_task_ids
	test_promote_d1_service_when_all_capability_signatures_integrated
	test_preblocked_d1_service_can_promote_from_new_capability_signature_task
	test_block_d2_storage_spec_with_split_upstream_gates
	test_promote_d2_storage_spec_when_all_capability_signatures_integrated
	test_block_d3_contract_when_continuation_closeout_missing
	test_promote_d3_contract_when_binding_contract_tasks_integrated
	test_block_d4_contract_when_dispatch_reconstruction_missing
	test_promote_d4_contract_when_dispatch_contract_tasks_integrated
	test_frontier_promotes_ready_and_skips_unproven_storage_proof
	test_frontier_blocks_closeout_nodes_without_noop
	test_promote_d2_service_when_all_service_signatures_integrated
	test_promote_d8_contract_when_all_product_signatures_integrated
	test_d3_storage_spec_skips_not_blocks_when_required_spec_missing
	test_dag_rejects_grandfathered_evidenceclass_bypass_for_storage_proof
	test_d2_service_and_d8_contract_skip_not_block_when_a_signature_is_missing
	test_promote_d3_storage_spec_when_all_capability_signatures_integrated
	test_promote_d3_binding_runtime_when_all_runtime_signatures_integrated
	test_d3_binding_runtime_and_d4_storage_spec_skip_not_block_when_a_signature_is_missing
	test_promote_d4_storage_spec_when_all_dispatch_storage_signatures_integrated
	test_promote_d4_dispatch_runtime_when_all_runtime_signatures_integrated
	test_promote_d5_storage_spec_when_all_evidence_storage_signatures_integrated
	test_d4_dispatch_runtime_and_d5_storage_spec_skip_not_block_when_a_signature_is_missing
	test_promote_d4_storage_proof_when_dispatch_proof_signatures_integrated

echo "gate promotion tests passed"
