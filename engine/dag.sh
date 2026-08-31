#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-}"
[[ -n "$cmd" ]] || { echo "usage: $0 validate-dag|next-area|next-areas|area-gate|node-fields [NODE] | validate-gate-file PATH" >&2; exit 2; }
shift || true

dag_file="${SINGULAR_DAG_FILE:-$SINGULAR_ORCH_DIR/dag.v0.json}"
gates_dir="${SINGULAR_GATES_DIR:-$SINGULAR_ORCH_DIR/gates}"
gate_schema_v1="${SINGULAR_GATE_SCHEMA_V1:-$SINGULAR_SCHEMA_DIR/gate-result.v1.schema.json}"
gate_report_schema="${SINGULAR_GATE_REPORT_SCHEMA:-$SINGULAR_SCHEMA_DIR/gate-report.v0.schema.json}"
campaign_binding="$(singular_campaign_binding)" || {
  echo "campaign state is inconsistent; refusing gate evaluation" >&2
  exit 2
}

python3 - "$cmd" "$dag_file" "$gates_dir" "$SINGULAR_GATE_SCHEMA" "$gate_schema_v1" "$gate_report_schema" "$SINGULAR_ROOT" "$SCRIPT_DIR" "$campaign_binding" "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
from datetime import datetime

(
    cmd,
    dag_file,
    gates_dir,
    gate_schema_v0,
    gate_schema_v1,
    gate_report_schema,
    repo_root,
    engine_dir,
    current_campaign_binding,
    *args,
) = sys.argv[1:]
sys.path.insert(0, engine_dir)
from human_gate import validate_gate as validate_human_gate  # noqa: E402

# Proof-layer regime (generic, opt-in). A project lists its proof layers and any
# grandfathered node ids in its config; the generic engine leaves both empty.
proof_layers = set(filter(None, os.environ.get("SINGULAR_PROOF_LAYERS", "").split(",")))
proof_grandfather = set(filter(None, os.environ.get("SINGULAR_PROOF_GRANDFATHER", "").split(",")))

# Layer/kind vocabularies and required nodes are OPTIONAL manifest allowlists
# (top-level "layers", "kinds", "requiredNodes"). When absent, any non-empty
# string layer/kind is accepted and no node is mandatory — the generic engine
# carries no project-specific vocabulary.
required_node_fields = {"id", "stage", "area", "layer", "kind", "dependsOn", "requiredCompletion"}


class Violation(Exception):
    """A single contract breach, raised instead of exiting while collecting."""

    def __init__(self, message, code=2):
        super().__init__(message)
        self.message = message
        self.code = code


# Collecting mode exists for `singular gate validate`. fail() normally prints and
# exits, which is right for the loop -- the frontier read must stop at the first
# breach -- but it means a promoter learns about exactly ONE violation per run.
# A consumer hit four in a row, each hiding the next, each costing a loop
# restart. While collecting, fail() records the message and raises so the caller
# can move to the next INDEPENDENT check instead of the process dying.
#
# Every existing subcommand leaves _collecting false and is bit-for-bit
# unchanged.
_collecting = False
_violations = []


def fail(message, code=2):
    if _collecting:
        _violations.append(message)
        raise Violation(message, code)
    print(message, file=sys.stderr)
    sys.exit(code)


def collect(step):
    """Run one independent check; record its breach and keep going."""
    try:
        step()
    except Violation:
        pass


def load_dag():
    if not os.path.exists(dag_file):
        fail(f"dag file not found: {dag_file}")
    with open(dag_file, "r", encoding="utf-8") as f:
        data = json.load(f)
    validate_dag(data)
    return data


def validate_dag(data):
    if data.get("schema") != "singular.orchestration.dag.v0":
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
        human_gate = node.get("humanGate")
        if human_gate is not None:
            if not isinstance(human_gate, dict):
                fail(f"humanGate must be an object for {node_id}")
            if set(human_gate) != {"requestRef", "approvalRef"}:
                fail(f"humanGate for {node_id} requires only requestRef and approvalRef")
            if not all(isinstance(human_gate.get(key), str) and human_gate.get(key)
                       for key in ("requestRef", "approvalRef")):
                fail(f"humanGate references must be non-empty strings for {node_id}")
            if authority == "agent-review-allowed":
                fail(f"humanGate for {node_id} cannot use agent-review-allowed authority")

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


def load_gate_schema(schema_id):
    paths = {
        "singular.orchestration.gate-result.v0": gate_schema_v0,
        "singular.orchestration.gate-result.v1": gate_schema_v1,
    }
    path = paths.get(schema_id)
    if path is None:
        fail(f"unsupported gate-result schema: {schema_id!r}")
    if not os.path.exists(path):
        fail(f"gate schema not found: {path}")
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def resolve_schema_ref(spec, schema_root, where):
    ref = spec.get("$ref")
    if ref is None:
        return spec
    if not isinstance(ref, str) or not ref.startswith("#/") or schema_root is None:
        fail(f"{where} uses unsupported schema reference: {ref!r}")
    resolved = schema_root
    for part in ref[2:].split("/"):
        key = part.replace("~1", "/").replace("~0", "~")
        if not isinstance(resolved, dict) or key not in resolved:
            fail(f"{where} uses unresolved schema reference: {ref}")
        resolved = resolved[key]
    if not isinstance(resolved, dict):
        fail(f"{where} schema reference does not resolve to an object: {ref}")
    return resolved


def check_against_spec(val, spec, where, schema_root=None):
    spec = resolve_schema_ref(spec, schema_root, where)
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
    if kind == "integer" and "minimum" in spec and val < spec["minimum"]:
        fail(f"{where} must be at least {spec['minimum']}")
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
            check_against_spec(
                item, item_spec, f"{where}[{idx}]", schema_root=schema_root
            )
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
                check_against_spec(
                    val[key],
                    child_spec,
                    f"{where}.{key}",
                    schema_root=schema_root,
                )


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


repo_root_path = Path(repo_root).resolve()


def safe_repo_artifact(ref, label):
    if not isinstance(ref, str) or not ref:
        fail(f"{label} must be a non-empty repository-relative path")
    try:
        relative = Path(ref)
    except (OSError, ValueError) as exc:
        fail(f"{label} is invalid: {ref!r} ({exc})")
    if relative.is_absolute() or not relative.parts or ".." in relative.parts:
        fail(f"{label} must be a safe repository-relative path: {ref}")
    target = repo_root_path.joinpath(*relative.parts)
    cursor = repo_root_path
    for part in relative.parts[:-1]:
        cursor = cursor / part
        try:
            mode = cursor.lstat().st_mode
        except OSError as exc:
            fail(f"{label} does not exist: {ref} ({exc})")
        if stat.S_ISLNK(mode):
            fail(f"{label} traverses a symlink: {ref}")
    try:
        mode = target.lstat().st_mode
    except OSError as exc:
        fail(f"{label} does not exist: {ref} ({exc})")
    return target, mode


def source_artifact_sha256(ref, label):
    target, mode = safe_repo_artifact(ref, label)

    def file_digest(path):
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.digest()

    if stat.S_ISREG(mode):
        return file_digest(target).hex()
    if stat.S_ISLNK(mode):
        digest = hashlib.sha256()
        digest.update(b"singular-symlink.v0\0")
        digest.update(os.fsencode(os.readlink(target)))
        return digest.hexdigest()
    if not stat.S_ISDIR(mode):
        fail(f"{label} has unsupported artifact type: {ref}")

    digest = hashlib.sha256()
    digest.update(b"singular-tree.v0\0")

    def frame(kind, relative, payload=b""):
        body = kind + b"\0" + os.fsencode(relative) + b"\0" + payload
        digest.update(len(body).to_bytes(8, "big"))
        digest.update(body)

    def visit(directory, prefix):
        with os.scandir(directory) as entries:
            ordered = sorted(entries, key=lambda item: os.fsencode(item.name))
        for entry in ordered:
            relative = entry.name if not prefix else f"{prefix}/{entry.name}"
            entry_mode = entry.stat(follow_symlinks=False).st_mode
            if stat.S_ISLNK(entry_mode):
                frame(b"L", relative, os.fsencode(os.readlink(entry.path)))
            elif stat.S_ISREG(entry_mode):
                frame(b"F", relative, file_digest(Path(entry.path)))
            elif stat.S_ISDIR(entry_mode):
                frame(b"D", relative)
                visit(entry.path, relative)
            else:
                fail(f"{label} has unsupported artifact type: {ref}/{relative}")

    visit(target, "")
    return digest.hexdigest()


def regular_repo_file(ref, label):
    target, mode = safe_repo_artifact(ref, label)
    if not stat.S_ISREG(mode):
        fail(f"{label} must reference a regular file: {ref}")
    return target


def repo_file(path):
    return str(regular_repo_file(path, "command-log logRef"))


def task_set_sha256(evidence):
    payload = {"ref": evidence["ref"], "taskIds": evidence["taskIds"]}
    encoded = json.dumps(
        payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def validate_v1_evidence_hashes(data, node_id):
    if data.get("schema") != "singular.orchestration.gate-result.v1":
        return

    def check(idx, evidence):
        label = f"gate-result.v1 for {node_id} evidence[{idx}]"
        kind = evidence.get("kind")
        if kind == "source-path":
            actual = source_artifact_sha256(evidence.get("ref"), f"{label} ref")
        elif kind == "task-set":
            if not isinstance(evidence.get("taskIds"), list):
                fail(f"{label} task-set requires taskIds")
            actual = task_set_sha256(evidence)
        elif kind == "command-log":
            log_ref = evidence.get("logRef")
            if not isinstance(log_ref, str) or not log_ref:
                fail(f"{label} command-log requires logRef")
            actual = sha256_file(regular_repo_file(log_ref, f"{label} logRef"))
        elif kind in ("gate-report", "human-approval"):
            actual = sha256_file(
                regular_repo_file(evidence.get("ref"), f"{label} ref")
            )
        else:
            fail(f"{label} has unsupported evidence kind: {kind!r}")
        if actual != evidence.get("sha256"):
            fail(
                f"{label} sha256 mismatch: expected {evidence.get('sha256')} "
                f"actual {actual}"
            )

    # Evidence items are independent of one another, so while collecting each
    # one reports separately instead of the first hiding the rest. Outside
    # collecting mode fail() still exits and collect() is a transparent wrapper
    # (SystemExit passes straight through it).
    for idx, evidence in enumerate(data.get("evidence", [])):
        collect(lambda idx=idx, evidence=evidence: check(idx, evidence))


def load_json_object(path, label):
    try:
        with path.open("r", encoding="utf-8") as stream:
            value = json.load(stream)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"{label} is unreadable: {path} ({exc})")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object: {path}")
    return value


def validate_object_against_schema(value, schema_path, label):
    try:
        with open(schema_path, "r", encoding="utf-8") as stream:
            schema = json.load(stream)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"{label} schema is unreadable: {schema_path} ({exc})")
    check_against_spec(value, schema, label, schema_root=schema)


def validate_strict_gate_report(data, node_id):
    report_ref = data.get("gateReportRef")
    report_items = [
        item for item in data.get("evidence", []) if item.get("kind") == "gate-report"
    ]
    if not isinstance(report_ref, str) or not report_ref:
        fail(f"deterministic-proof gate for {node_id} requires gateReportRef")
    if len(report_items) != 1:
        fail(
            f"deterministic-proof gate for {node_id} requires exactly one "
            "gate-report evidence item"
        )
    if report_items[0].get("ref") != report_ref:
        fail(
            f"deterministic-proof gate for {node_id} gateReportRef does not "
            "match its gate-report evidence item"
        )

    report_path = regular_repo_file(
        report_ref, f"deterministic-proof gate for {node_id} gateReportRef"
    )
    report = load_json_object(report_path, f"gate report for {node_id}")
    # The report's own schema — where the ^TASK-[0-9]{4,} taskId pattern lives,
    # one of the four violations a consumer's promoter hit in sequence. It is
    # independent of the hash checks below, so while collecting it must not hide
    # them (nor they it).
    collect(lambda: validate_object_against_schema(
        report, gate_report_schema, f"gate report for {node_id}"
    ))

    outcome = report.get("outcome")
    status = data.get("status")
    expected_status = (
        "passed-with-acknowledged-baseline"
        if outcome == "passed-with-acknowledged-baseline"
        else "passed"
    )
    if outcome not in ("passed", "passed-with-acknowledged-baseline"):
        fail(
            f"deterministic-proof gate for {node_id} cannot pass with gate "
            f"report outcome {outcome!r}"
        )
    if status != expected_status:
        fail(
            f"deterministic-proof gate for {node_id} status {status!r} does "
            f"not match gate report outcome {outcome!r}"
        )
    if data.get("verificationClassification") != "passed":
        fail(
            f"deterministic-proof gate for {node_id} requires "
            "verificationClassification='passed'"
        )

    command = report.get("command")
    command_sha = hashlib.sha256(command.encode("utf-8")).hexdigest()
    if command_sha != report.get("commandSha256"):
        fail(f"gate report for {node_id} commandSha256 mismatch")
    # The log ref and its hashes: independent of the baseline, the task-set
    # binding and the command-log binding below. Collected separately so a bad
    # path here does not conceal a bad path there — the exact sequence that made
    # a consumer restart their loop four times.
    def check_report_log():
        report_log = regular_repo_file(
            report.get("logRef"), f"gate report for {node_id} logRef"
        )
        if sha256_file(report_log) != report.get("logSha256"):
            fail(f"gate report for {node_id} logSha256 mismatch")
        if report_log.stat().st_size != report.get("logBytes"):
            fail(f"gate report for {node_id} logBytes mismatch")

    collect(check_report_log)

    baseline_ref = report.get("baselineRef")
    baseline_sha = report.get("baselineSha256")

    def check_baseline():
        if (baseline_ref is None) != (baseline_sha is None):
            fail(
                f"gate report for {node_id} must provide baselineRef and "
                "baselineSha256 together"
            )
        if baseline_ref is not None:
            baseline_path = regular_repo_file(
                baseline_ref, f"gate report for {node_id} baselineRef"
            )
            if sha256_file(baseline_path) != baseline_sha:
                fail(f"gate report for {node_id} baselineSha256 mismatch")
            baseline = load_json_object(
                baseline_path, f"gate baseline for {node_id}"
            )
            if baseline.get("schema") != "singular.orchestration.gate-baseline.v0":
                fail(f"gate baseline for {node_id} has unsupported schema")
            if baseline.get("commandSha256") != command_sha:
                fail(f"gate baseline for {node_id} commandSha256 mismatch")

    collect(check_baseline)
    if outcome == "passed-with-acknowledged-baseline":
        if baseline_ref is None or not report.get("expectedFailures"):
            fail(
                f"acknowledged-baseline gate report for {node_id} requires a "
                "bound baseline and expected failures"
            )
    elif report.get("rawExitCode") != 0:
        fail(f"passed gate report for {node_id} must have rawExitCode 0")
    if report.get("unexpectedFailures"):
        fail(f"passing gate report for {node_id} has unexpected failures")
    if report.get("failureSignals"):
        fail(f"passing gate report for {node_id} has failure signals")
    if report.get("infrastructureSignals"):
        fail(f"passing gate report for {node_id} has infrastructure signals")
    source_integrity = report.get("sourceIntegrity")
    if isinstance(source_integrity, dict) and source_integrity.get("status") == "violation":
        fail(f"passing gate report for {node_id} has a source integrity violation")

    bound = {
        "headSha": report.get("headSha"),
        "commandSha256": report.get("commandSha256"),
        "rawExitCode": report.get("rawExitCode"),
        "logSha256": report.get("logSha256"),
        "outcome": report.get("outcome"),
        "baselineSha256": report.get("baselineSha256", ""),
    }
    actual_binding = hashlib.sha256(
        json.dumps(bound, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    if actual_binding != report.get("evidenceBindingSha256"):
        fail(f"gate report for {node_id} evidenceBindingSha256 mismatch")

    def check_command_log_binding():
        command_logs = [
            item
            for item in data.get("evidence", [])
            if item.get("kind") == "command-log"
        ]
        matching_logs = [
            item
            for item in command_logs
            if item.get("command") == command
            and item.get("exitCode") == report.get("rawExitCode")
            and item.get("logRef") == report.get("logRef")
            and item.get("sha256") == report.get("logSha256")
            and item.get("headSha") == report.get("headSha")
        ]
        if len(matching_logs) != 1:
            fail(
                f"gate report for {node_id} must bind exactly one matching "
                "command-log evidence item"
            )

    collect(check_command_log_binding)
    def check_task_set_binding():
        task_ids = {
            task_id
            for item in data.get("evidence", [])
            if item.get("kind") == "task-set"
            for task_id in item.get("taskIds", [])
        }
        if report.get("taskId") not in task_ids:
            fail(
                f"gate report for {node_id} taskId is not present in its "
                "hash-bound task-set evidence"
            )

    collect(check_task_set_binding)


def validate_v1_verification(data, node_id):
    if data.get("schema") != "singular.orchestration.gate-result.v1":
        return
    passing = (
        data.get("status") in ("passed", "passed-with-acknowledged-baseline")
        and data.get("authoritative") is True
    )
    if not passing:
        return
    classification = data.get("verificationClassification")
    if not isinstance(classification, str):
        fail(
            f"authoritative passing gate-result.v1 for {node_id} requires "
            "verificationClassification"
        )
    if data.get("evidenceClass") == "deterministic-proof":
        validate_strict_gate_report(data, node_id)
    elif classification != "not-rerun-evidence-verified":
        fail(
            f"non-executable authoritative gate-result.v1 for {node_id} "
            "requires verificationClassification="
            "'not-rerun-evidence-verified'"
        )


def validate_deterministic_proof_gate(data, node_id):
    # A "proof layer" (declared via SINGULAR_PROOF_LAYERS) is a node class whose
    # passing gate must carry BOTH a green command-log AND an expected-FAIL "red"
    # skip-guard log proving the proof is not vacuous (it fails when its real
    # dependency is stripped). The GENERIC engine declares no proof layers: with
    # SINGULAR_PROOF_LAYERS empty, is_proof is always False and this enforces only the
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
        data.get("status") in ("passed", "passed-with-acknowledged-baseline")
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
        data.get("status") in ("passed", "passed-with-acknowledged-baseline")
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


# Validate a gate-result against the schema declared by the record before it is
# ever trusted. v2 consumers write v1, while existing v0 records remain valid.
# The selected schema remains the source of truth and every proof-layer rule is
# applied identically after structural validation.
def validate_gate(data, path, node_id):
    schema = load_gate_schema(data.get("schema"))
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
            check_against_spec(
                data[key],
                spec,
                f"gate for {node_id} field '{key}'",
                schema_root=schema,
            )
    recorded_campaign_binding = data.get("campaignBinding")
    if current_campaign_binding == "legacy":
        # Historical unbound gates remain compatible only in an unfrozen
        # legacy repository. A gate explicitly bound to a former campaign can
        # never regain authority merely because that campaign was ended.
        if recorded_campaign_binding not in (None, "legacy"):
            fail(
                f"gate for {node_id} belongs to campaign "
                f"{recorded_campaign_binding!r}, current binding is legacy ({path})"
            )
    elif recorded_campaign_binding != current_campaign_binding:
        fail(
            f"gate for {node_id} campaign binding mismatch: expected "
            f"{current_campaign_binding!r}, actual {recorded_campaign_binding!r} ({path})"
        )
    blocker_class = data.get("blockerClass")
    if blocker_class is not None:
        if data.get("status") != "blocked" or data.get("authoritative") is not True:
            fail(
                f"gate for {node_id} blockerClass is valid only on an "
                f"authoritative blocked gate ({path})"
            )
    validate_v1_evidence_hashes(data, node_id)
    validate_v1_verification(data, node_id)
    validate_deterministic_proof_gate(data, node_id)


def gate_data(node_id):
    path = gate_path(node_id)
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        # A corrupt gate file must never take down the whole frontier
        # computation (0.5.0): treat it as not-passed and say so on stderr —
        # fail-closed for the node, fail-soft for the DAG.
        print(f"warning: unreadable gate file for {node_id}: {path} ({exc})", file=sys.stderr)
        return None
    validate_gate(data, path, node_id)
    if data.get("node") != node_id:
        fail(f"gate node mismatch for {node_id}: {path}")
    return data


human_gate_cache = {}


def human_gate_state(node_id):
    if node_id in human_gate_cache:
        return human_gate_cache[node_id]
    config = by_id.get(node_id, {}).get("humanGate")
    if not isinstance(config, dict):
        result = None
    else:
        result = validate_human_gate(
            Path(repo_root).resolve(),
            config["requestRef"],
            config["approvalRef"],
            node_id,
        )
    human_gate_cache[node_id] = result
    return result


def gate_passed(node_id):
    data = gate_data(node_id)
    passed = bool(
        data
        and data.get("status") in ("passed", "passed-with-acknowledged-baseline")
        and data.get("authoritative") is True
    )
    if not passed:
        return False
    human = human_gate_state(node_id)
    if human is not None and human.get("state") != "approved":
        return False
    return True


def gate_blocker_class(node_id):
    """Return the normalized durable lifecycle blocker class, if any.

    Old gate-result records used only status=blocked. They remain readable and
    fail closed as blocked-external until a promoter rewrites them with an
    explicit machine-readable class. This avoids silently resuming work that a
    historical operator intended to park.
    """
    data = gate_data(node_id)
    if not (
        data
        and data.get("status") == "blocked"
        and data.get("authoritative") is True
    ):
        return None
    blocker_class = data.get("blockerClass")
    if blocker_class in ("needs-work", "blocked-external"):
        return blocker_class
    return "blocked-external"


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
        if gate_blocker_class(node_id) == "blocked-external":
            continue
        if node.get("humanGate") is not None:
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
    # --explain (0.5.0): also emit excluded[] with per-node exclusion reasons —
    # the field run's operator had to source lib.sh internals to learn why the
    # frontier was empty.
    explain = "--explain" in args
    frontier = []
    excluded = []
    all_passed = True
    for node in nodes:
        node_id = node["id"]
        if gate_passed(node_id):
            if explain:
                excluded.append({"node": node_id, "reason": "gate-passed"})
            continue
        all_passed = False
        blocker_class = gate_blocker_class(node_id)
        if blocker_class == "blocked-external":
            if explain:
                excluded.append({"node": node_id, "reason": "blocked-external"})
            continue
        human = human_gate_state(node_id)
        if human is not None:
            if explain:
                excluded.append({
                    "node": node_id,
                    "reason": f"human-gate-{human.get('state', 'invalid')}",
                    "owner": human.get("owner"),
                    "detail": human.get("reason"),
                })
            continue
        unmet = [dep for dep in node.get("dependsOn", []) if not gate_passed(dep)]
        if unmet:
            if explain:
                excluded.append({"node": node_id, "reason": "deps-not-gated", "unmetDeps": unmet})
            continue
        entry = {key: node[key] for key in ("stage", "area", "layer", "kind", "requiredCompletion")}
        entry["node"] = node_id
        if blocker_class == "needs-work":
            entry["lifecycle"] = "needs-work"
        frontier.append(entry)
    result = {"frontier": frontier}
    if explain:
        result["excluded"] = excluded
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
    blocker_class = gate_blocker_class(node_id)
    if blocker_class == "blocked-external":
        fail(
            f"node has authoritative blocked gate: {node_id} "
            "(blocked-external; requires external input or explicit override)"
        )
    human = human_gate_state(node_id)
    if human is not None:
        fail(f"node awaits human gate: {node_id} ({human.get('state')}: {human.get('reason')})")
    if not all(gate_passed(dep) for dep in node.get("dependsOn", [])):
        fail(f"node dependencies are not all gated: {node_id}")
    for key in ("id", "stage", "area", "layer", "kind", "requiredCompletion"):
        out_key = "node" if key == "id" else key
        print(f"{out_key}={node[key]}")
    print(f"authority={node.get('authority', 'operator')}")
    if blocker_class == "needs-work":
        print("lifecycle=needs-work")
elif cmd == "validate-gate-file":
    # Report EVERY contract breach in one pass, not just the first.
    #
    # fail() exits, which is right for the loop but means a promoter learns one
    # violation per run. A consumer's promoter hit four in sequence — absolute
    # evidence[].ref, absolute gateReportRef, a task-set hashed by their own
    # convention, and a taskId that did not match ^TASK-[0-9]{4,} — each hidden
    # by the one before it, each costing a loop restart and hours of wall clock.
    #
    # Coverage is honest rather than total: the independent units (each evidence
    # item, the report schema, the log refs and hashes, the baseline, the
    # command-log binding, the task-set binding) all report together. Checks
    # that genuinely cannot proceed — an unreadable gate file, a missing
    # gateReportRef — still stop that branch, because everything after them
    # would be noise.
    if len(args) != 1:
        fail("usage: dag.sh validate-gate-file PATH", 2)
    gate_file = Path(args[0])
    if not gate_file.is_file():
        fail(f"gate file not found: {gate_file}", 2)
    try:
        with open(gate_file, "r", encoding="utf-8") as f:
            gate_doc = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"gate file is not readable JSON: {gate_file} ({exc})", 2)
    if not isinstance(gate_doc, dict):
        fail(f"gate file must contain an object: {gate_file}", 2)
    validated_node = gate_doc.get("node") or "(unnamed node)"

    _collecting = True
    collect(lambda: validate_gate(gate_doc, str(gate_file), validated_node))
    _collecting = False

    if _violations:
        print(
            f"{len(_violations)} contract violation(s) in {gate_file}:",
            file=sys.stderr,
        )
        for violation in _violations:
            print(f"  - {violation}", file=sys.stderr)
        sys.exit(2)
    print(f"gate-valid node={validated_node} file={gate_file}")
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
    fail("usage: dag.sh validate-dag|next-area|next-areas|area-gate|node-fields [NODE] | validate-gate-file PATH", 2)
PY
