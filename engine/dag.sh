#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-}"
[[ -n "$cmd" ]] || { echo "usage: $0 validate-dag|next-area|next-areas|area-gate|node-fields [NODE]" >&2; exit 2; }
shift || true

dag_file="${GLUERUN_DAG_FILE:-$GLUERUN_ORCH_DIR/dag.v0.json}"
gates_dir="${GLUERUN_GATES_DIR:-$GLUERUN_ORCH_DIR/gates}"

python3 - "$cmd" "$dag_file" "$gates_dir" "$GLUERUN_GATE_SCHEMA" "$GLUERUN_ROOT" "$@" <<'PY'
import hashlib
import json
import os
import re
import sys
from datetime import datetime

cmd, dag_file, gates_dir, gate_schema, repo_root, *args = sys.argv[1:]

# Proof-layer regime (generic, opt-in). A project lists its proof layers and any
# grandfathered node ids in its config; the generic engine leaves both empty.
proof_layers = set(filter(None, os.environ.get("GLUERUN_PROOF_LAYERS", "").split(",")))
proof_grandfather = set(filter(None, os.environ.get("GLUERUN_PROOF_GRANDFATHER", "").split(",")))

# Layer/kind vocabularies and required nodes are OPTIONAL manifest allowlists
# (top-level "layers", "kinds", "requiredNodes"). When absent, any non-empty
# string layer/kind is accepted and no node is mandatory — the generic engine
# carries no project-specific vocabulary.
required_node_fields = {"id", "stage", "area", "layer", "kind", "dependsOn", "requiredCompletion"}


def fail(message, code=2):
    print(message, file=sys.stderr)
    sys.exit(code)


def load_dag():
    if not os.path.exists(dag_file):
        fail(f"dag file not found: {dag_file}")
    with open(dag_file, "r", encoding="utf-8") as f:
        data = json.load(f)
    validate_dag(data)
    return data


def validate_dag(data):
    if data.get("schema") != "gluerun.orchestration.dag.v0":
        fail("unsupported DAG schema")
    nodes = data.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        fail("dag.nodes must be a non-empty array")

    # Optional, manifest-declared vocabularies. None => accept any non-empty string.
    allowed_layers = data.get("layers")
    allowed_kinds = data.get("kinds")
    required_nodes = data.get("requiredNodes", [])

    seen = set()
    by_id = {}
    for idx, node in enumerate(nodes):
        if not isinstance(node, dict):
            fail(f"node[{idx}] must be an object")
        missing = sorted(required_node_fields - set(node))
        if missing:
            fail(f"node[{idx}] missing required fields: {', '.join(missing)}")
        node_id = str(node.get("id", ""))
        if not node_id:
            fail(f"node[{idx}] has empty id")
        if node_id in seen:
            fail(f"duplicate node id: {node_id}")
        seen.add(node_id)
        by_id[node_id] = node
        layer = node.get("layer")
        if not isinstance(layer, str) or not layer:
            fail(f"layer must be a non-empty string for {node_id}")
        if allowed_layers is not None and layer not in allowed_layers:
            fail(f"unknown layer for {node_id}: {layer}")
        kind = node.get("kind")
        if not isinstance(kind, str) or not kind:
            fail(f"kind must be a non-empty string for {node_id}")
        if allowed_kinds is not None and kind not in allowed_kinds:
            fail(f"unknown kind for {node_id}: {kind}")
        if not isinstance(node.get("dependsOn"), list):
            fail(f"dependsOn must be an array for {node_id}")
        authority = node.get("authority")
        if authority is not None and authority not in ("operator", "agent-review-allowed"):
            fail(f"unknown authority for {node_id}: {authority} (operator | agent-review-allowed)")

    for req in required_nodes:
        if req not in by_id:
            fail(f"missing required node: {req}")

    for node in nodes:
        for dep in node.get("dependsOn", []):
            if dep not in by_id:
                fail(f"unknown dependency for {node['id']}: {dep}")

    visiting = set()
    visited = set()

    def visit(node_id, stack):
        if node_id in visiting:
            fail("cycle detected: " + " -> ".join(stack + [node_id]))
        if node_id in visited:
            return
        visiting.add(node_id)
        for dep in by_id[node_id].get("dependsOn", []):
            visit(dep, stack + [node_id])
        visiting.remove(node_id)
        visited.add(node_id)

    for node in nodes:
        visit(node["id"], [])


def gate_path(node_id):
    return os.path.join(gates_dir, f"{node_id}.gate-result.json")


def load_gate_schema():
    if not os.path.exists(gate_schema):
        fail(f"gate schema not found: {gate_schema}")
    with open(gate_schema, "r", encoding="utf-8") as f:
        return json.load(f)


def check_against_spec(val, spec, where):
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
            check_against_spec(item, item_spec, f"{where}[{idx}]")
    if kind == "object":
        props = spec.get("properties", {})
        if spec.get("additionalProperties") is False:
            unknown = sorted(set(val) - set(props))
            if unknown:
                fail(f"{where} has unknown field(s): {', '.join(unknown)}")
        missing = [key for key in spec.get("required", []) if key not in val]
        if missing:
            fail(f"{where} missing required field(s): {', '.join(sorted(missing))}")
        for key, child_spec in props.items():
            if key in val:
                check_against_spec(val[key], child_spec, f"{where}.{key}")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def repo_file(path):
    if os.path.isabs(path):
        fail(f"logRef must be repository-relative: {path}")
    return os.path.normpath(os.path.join(repo_root, path))


def validate_deterministic_proof_gate(data, node_id):
    # A "proof layer" (declared via GLUERUN_PROOF_LAYERS) is a node class whose
    # passing gate must carry BOTH a green command-log AND an expected-FAIL "red"
    # skip-guard log proving the proof is not vacuous (it fails when its real
    # dependency is stripped). The GENERIC engine declares no proof layers: with
    # GLUERUN_PROOF_LAYERS empty, is_proof is always False and this enforces only the
    # standard deterministic-proof rule (every command-log exits 0, hash matches,
    # logRef exists). A project re-enables the red/green regime by listing its
    # proof layers (and any grandfathered node ids) in its own config.
    node_layer = by_id.get(node_id, {}).get("layer")
    is_proof = node_layer in proof_layers
    grandfathered = node_id in proof_grandfather
    # Trust-boundary guard: a passed+authoritative proof-layer gate (other than a
    # grandfathered node) MUST declare evidenceClass=="deterministic-proof" so it
    # cannot escape the red/green skip-guard by labeling itself with another
    # schema-legal evidenceClass. Without this the early return below would turn
    # the validator into a no-op for such a gate.
    if (
        data.get("status") == "passed"
        and data.get("authoritative") is True
        and is_proof
        and not grandfathered
        and data.get("evidenceClass") != "deterministic-proof"
    ):
        fail(
            f"proof-layer gate for {node_id} must declare evidenceClass='deterministic-proof' "
            "(no other evidenceClass is permitted for a non-grandfathered proof layer); "
            "this prevents bypassing the mandatory red/green skip-guard"
        )
    if not (
        data.get("status") == "passed"
        and data.get("authoritative") is True
        and data.get("evidenceClass") == "deterministic-proof"
    ):
        return
    # dag.sh is the FINAL AUTHORITY: it re-hashes every log and (for proof layers)
    # requires the red here, so a green-only proof gate is rejected regardless of
    # how it was produced. The non-zero-exit red is permitted only for proof
    # layers; every other layer keeps the strict every-log-exit-0 rule.
    command_logs = [e for e in data.get("evidence", []) if e.get("kind") == "command-log"]
    if not command_logs:
        fail(f"deterministic-proof gate for {node_id} requires command-log evidence")
    green_logs = 0
    red_logs = 0
    for idx, evidence in enumerate(command_logs):
        label = f"deterministic-proof gate for {node_id} evidence[{idx}]"
        for key in ("command", "exitCode", "logRef", "sha256", "headSha"):
            if key not in evidence:
                fail(f"{label} missing required field: {key}")
        is_skip_guard_red = is_proof and str(evidence.get("ref", "")).endswith("-skip-guard-red")
        if evidence["exitCode"] == 0:
            if is_skip_guard_red:
                fail(f"{label} skip-guard red command-log must have non-zero exitCode")
            green_logs += 1
        elif is_proof:
            if not is_skip_guard_red:
                fail(f"{label} non-zero command-log must be marked as skip-guard red with a ref ending in -skip-guard-red")
            red_logs += 1
        else:
            fail(f"{label} exitCode must be 0")
        path = repo_file(evidence["logRef"])
        if not os.path.exists(path):
            fail(f"{label} logRef does not exist: {evidence['logRef']}")
        actual = sha256_file(path)
        if actual != evidence["sha256"]:
            fail(f"{label} sha256 mismatch for {evidence['logRef']}: expected {evidence['sha256']} actual {actual}")
    if is_proof and green_logs < 1:
        fail(f"proof-layer gate for {node_id} requires at least one passing (exitCode 0) command-log")
    if is_proof and not grandfathered and red_logs < 1:
        fail(f"proof-layer gate for {node_id} requires a red skip-guard command-log (a non-zero-exit run proving the proof fails when its real dependency is stripped)")


# Validate a gate-result against gate-result.v0.schema.json before it is ever
# trusted. The schema file is the single source of truth (no rule duplication);
# any violation fails closed via fail() (exit 2) so an incomplete or malformed
# authoritative record can never advance the frontier.
def validate_gate(data, path, node_id):
    schema = load_gate_schema()
    props = schema.get("properties", {})
    if schema.get("additionalProperties") is False:
        unknown = sorted(set(data) - set(props))
        if unknown:
            fail(f"gate for {node_id} has unknown field(s): {', '.join(unknown)} ({path})")
    missing = [key for key in schema.get("required", []) if key not in data]
    if missing:
        fail(f"gate for {node_id} missing required field(s): {', '.join(sorted(missing))} ({path})")
    for key, spec in props.items():
        if key in data:
            check_against_spec(data[key], spec, f"gate for {node_id} field '{key}'")
    validate_deterministic_proof_gate(data, node_id)


def gate_data(node_id):
    path = gate_path(node_id)
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    validate_gate(data, path, node_id)
    if data.get("node") != node_id:
        fail(f"gate node mismatch for {node_id}: {path}")
    return data


def gate_passed(node_id):
    data = gate_data(node_id)
    return bool(data and data.get("status") == "passed" and data.get("authoritative") is True)


def gate_authoritative_blocked(node_id):
    data = gate_data(node_id)
    return bool(data and data.get("status") == "blocked" and data.get("authoritative") is True)


data = load_dag()
nodes = data["nodes"]
by_id = {node["id"]: node for node in nodes}

if cmd == "validate-dag":
    print("ok")
elif cmd == "next-area":
    all_passed = True
    for node in nodes:
        node_id = node["id"]
        if gate_passed(node_id):
            continue
        all_passed = False
        if gate_authoritative_blocked(node_id):
            continue
        if all(gate_passed(dep) for dep in node.get("dependsOn", [])):
            for key in ("id", "stage", "area", "layer", "kind", "requiredCompletion"):
                out_key = "node" if key == "id" else key
                print(f"{out_key}={node[key]}")
            sys.exit(0)
    if all_passed:
        print("all-nodes-complete")
        sys.exit(0)
    fail("no eligible DAG node; dependencies are not gated")
elif cmd == "next-areas":
    # Plural, read-only frontier: every node that is itself ungated AND whose
    # dependencies are ALL gate-passed. Readiness is a pure function of the
    # authoritative gate files — a node selected this pass is never treated as
    # "virtually complete", so a node whose dependency is merely in progress
    # (no passing gate) is correctly excluded. Emits a single line of JSON so a
    # console/reconciler can consume the whole frontier; next-area is unchanged.
    frontier = []
    all_passed = True
    for node in nodes:
        node_id = node["id"]
        if gate_passed(node_id):
            continue
        all_passed = False
        if gate_authoritative_blocked(node_id):
            continue
        if all(gate_passed(dep) for dep in node.get("dependsOn", [])):
            entry = {key: node[key] for key in ("stage", "area", "layer", "kind", "requiredCompletion")}
            entry["node"] = node_id
            frontier.append(entry)
    result = {"frontier": frontier}
    if all_passed:
        result["allComplete"] = True
    print(json.dumps(result, separators=(",", ":")))
    sys.exit(0)
elif cmd == "node-fields":
    # Emit a single node's planning fields (key=value, same shape as next-area)
    # IFF it is eligible to plan now: not itself gate-passed AND all deps gated.
    # This is the exact readiness predicate next-areas uses, so a --node planner
    # can never target an ineligible node.
    if len(args) != 1:
        fail("usage: dag.sh node-fields NODE", 2)
    node_id = args[0]
    if node_id not in by_id:
        fail(f"unknown node: {node_id}")
    node = by_id[node_id]
    if gate_passed(node_id):
        fail(f"node already gate-passed: {node_id}")
    if gate_authoritative_blocked(node_id):
        fail(f"node has authoritative blocked gate: {node_id}")
    if not all(gate_passed(dep) for dep in node.get("dependsOn", [])):
        fail(f"node dependencies are not all gated: {node_id}")
    for key in ("id", "stage", "area", "layer", "kind", "requiredCompletion"):
        out_key = "node" if key == "id" else key
        print(f"{out_key}={node[key]}")
    print(f"authority={node.get('authority', 'operator')}")
elif cmd == "area-gate":
    if len(args) != 1:
        fail("usage: dag.sh area-gate NODE", 2)
    node_id = args[0]
    if node_id not in by_id:
        fail(f"unknown node: {node_id}")
    if not gate_passed(node_id):
        fail(f"gate result not passed for {node_id}")
    print(f"gate-passed node={node_id}")
else:
    fail("usage: dag.sh validate-dag|next-area|next-areas|area-gate|node-fields [NODE]", 2)
PY
