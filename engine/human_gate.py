#!/usr/bin/env python3
"""Exact-artifact human gate request, approval, and validation helpers."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any


REQUEST_SCHEMA = "singular.orchestration.human-gate.v0"
APPROVAL_SCHEMA = "singular.orchestration.human-approval.v0"
GATE_RESULT_V0 = "singular.orchestration.gate-result.v0"
GATE_RESULT_V1 = "singular.orchestration.gate-result.v1"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
QUESTION_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
REQUEST_FIELDS = {
    "schema",
    "gateId",
    "node",
    "approvalType",
    "requiredOwner",
    "questions",
    "artifacts",
    "blockedNodes",
    "createdAt",
    "expiresAt",
}
APPROVAL_FIELDS = {
    "schema",
    "gateId",
    "node",
    "requestRef",
    "requestSha256",
    "approver",
    "decision",
    "answers",
    "artifacts",
    "evidence",
    "rationale",
    "approvedAt",
    "expiresAt",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_time(value: str) -> dt.datetime:
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp must include timezone")
    return parsed.astimezone(dt.UTC)


def utc_now(value: str | None = None) -> dt.datetime:
    """Current time, with an explicit argument winning over an injected clock.

    SINGULAR_NOW exists because expiry evaluation reaches this module through two
    doors: the human-gate CLI, which takes --now, and dag.sh's frontier
    evaluation, which does not. Without an injectable clock a test fixture with
    a fixed expiresAt is a time bomb — it passes until the wall clock rolls past
    the expiry and then fails forever, with nothing in the diff to explain why.
    Mirrors SINGULAR_CONTROL_COMMIT_NOW_EPOCH in reconcile.sh.
    """
    if value:
        return parse_time(value)
    injected = os.environ.get("SINGULAR_NOW")
    if injected:
        return parse_time(injected)
    return dt.datetime.now(dt.UTC)


def iso(value: dt.datetime) -> str:
    return value.astimezone(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def repo_path(repo: Path, ref: str, *, must_exist: bool = True) -> Path:
    candidate = Path(ref)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise ValueError(f"reference must be repository-relative: {ref}")
    resolved = (repo / candidate).resolve()
    try:
        resolved.relative_to(repo.resolve())
    except ValueError as exc:
        raise ValueError(f"reference escapes repository: {ref}") from exc
    if must_exist and not resolved.is_file():
        raise ValueError(f"referenced file does not exist: {ref}")
    return resolved


def read_json(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"JSON object required: {path}")
    return data


def repo_schema_version(repo: Path) -> str:
    try:
        config = read_json(repo / "singular.config.json")
    except (OSError, ValueError, json.JSONDecodeError):
        return ""
    value = config.get("schemaVersion")
    return value if isinstance(value, str) else ""


def atomic_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, raw = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    temporary = Path(raw)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def validate_reference_entries(
    value: Any,
    *,
    label: str,
    require_nonempty: bool,
) -> str | None:
    if not isinstance(value, list) or (require_nonempty and not value):
        qualifier = "non-empty " if require_nonempty else ""
        return f"{label} must be a {qualifier}array"
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, dict) or set(item) != {"ref", "sha256"}:
            return f"invalid {label} entry"
        ref = item.get("ref")
        digest = item.get("sha256")
        if not nonempty_string(ref):
            return f"invalid {label} reference"
        ref_path = Path(ref)
        if ref_path.is_absolute() or ".." in ref_path.parts:
            return f"unsafe {label} reference: {ref}"
        if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
            return f"invalid {label} sha256"
        if ref in seen:
            return f"duplicate {label} reference: {ref}"
        seen.add(ref)
    return None


def validate_request_document(
    request: Any,
    *,
    expected_node: str | None = None,
) -> tuple[str | None, dt.datetime | None, dt.datetime | None]:
    if not isinstance(request, dict):
        return "request must be an object", None, None
    missing = REQUEST_FIELDS - set(request)
    extra = set(request) - REQUEST_FIELDS
    if missing:
        return f"request missing required fields: {', '.join(sorted(missing))}", None, None
    if extra:
        return f"request has unexpected fields: {', '.join(sorted(extra))}", None, None
    if request.get("schema") != REQUEST_SCHEMA:
        return "unsupported request schema", None, None
    for field in ("gateId", "node", "approvalType", "requiredOwner"):
        if not nonempty_string(request.get(field)):
            return f"request {field} must be a non-empty string", None, None
    if expected_node is not None and request.get("node") != expected_node:
        return "request node mismatch", None, None

    questions = request.get("questions")
    if not isinstance(questions, list) or not questions:
        return "request questions must be a non-empty array", None, None
    question_ids: set[str] = set()
    for question in questions:
        if (
            not isinstance(question, dict)
            or set(question) != {"id", "prompt", "required"}
        ):
            return "invalid request question", None, None
        question_id = question.get("id")
        if (
            not isinstance(question_id, str)
            or QUESTION_ID_RE.fullmatch(question_id) is None
        ):
            return "invalid request question id", None, None
        if question_id in question_ids:
            return f"duplicate request question id: {question_id}", None, None
        if not nonempty_string(question.get("prompt")):
            return f"request question prompt is empty: {question_id}", None, None
        if question.get("required") is not True:
            return f"request question must be mandatory: {question_id}", None, None
        question_ids.add(question_id)

    artifact_error = validate_reference_entries(
        request.get("artifacts"),
        label="request artifact",
        require_nonempty=True,
    )
    if artifact_error:
        return artifact_error, None, None

    blocked_nodes = request.get("blockedNodes")
    if not isinstance(blocked_nodes, list) or not all(
        nonempty_string(item) for item in blocked_nodes
    ):
        return "request blockedNodes must be an array of non-empty strings", None, None
    if len(set(blocked_nodes)) != len(blocked_nodes):
        return "request blockedNodes must not contain duplicates", None, None
    if request.get("node") in blocked_nodes:
        return "request cannot block its own node", None, None

    try:
        created_at = parse_time(request["createdAt"])
        expires_at = parse_time(request["expiresAt"])
    except (TypeError, ValueError):
        return "invalid request timestamps", None, None
    if expires_at <= created_at:
        return "request expiry must be after creation", None, None
    return None, created_at, expires_at


def validate_approval_document(
    approval: Any,
    *,
    request: dict[str, Any],
    request_ref: str,
    request_sha256: str,
) -> tuple[str | None, dt.datetime | None]:
    if not isinstance(approval, dict):
        return "approval must be an object", None
    missing = APPROVAL_FIELDS - set(approval)
    extra = set(approval) - APPROVAL_FIELDS
    if missing:
        return f"approval missing required fields: {', '.join(sorted(missing))}", None
    if extra:
        return f"approval has unexpected fields: {', '.join(sorted(extra))}", None
    if approval.get("schema") != APPROVAL_SCHEMA:
        return "unsupported approval schema", None
    for field in ("gateId", "node", "requestRef", "approver", "rationale"):
        if not nonempty_string(approval.get(field)):
            return f"approval {field} must be a non-empty string", None
    if approval.get("gateId") != request.get("gateId") or approval.get("node") != request.get("node"):
        return "approval identity mismatch", None
    if approval.get("requestRef") != request_ref:
        return "approval request reference mismatch", None
    if (
        not isinstance(approval.get("requestSha256"), str)
        or SHA256_RE.fullmatch(approval["requestSha256"]) is None
    ):
        return "invalid approval requestSha256", None
    if approval.get("requestSha256") != request_sha256:
        return "request changed after approval", None
    if approval.get("approver") != request.get("requiredOwner"):
        return "approval owner mismatch", None
    if approval.get("decision") not in {"approved", "rejected"}:
        return "invalid approval decision", None
    if approval.get("expiresAt") != request.get("expiresAt"):
        return "approval expiry does not match request", None

    answers = approval.get("answers")
    if not isinstance(answers, dict):
        return "approval answers must be an object", None
    question_ids = {question["id"] for question in request["questions"]}
    if set(answers) != question_ids:
        missing_answers = sorted(question_ids - set(answers))
        extra_answers = sorted(set(answers) - question_ids)
        if missing_answers:
            return f"required question unanswered: {missing_answers[0]}", None
        return f"approval has answer for unknown question: {extra_answers[0]}", None
    for question_id, answer in answers.items():
        if not nonempty_string(answer):
            return f"required question unanswered: {question_id}", None

    artifact_error = validate_reference_entries(
        approval.get("artifacts"),
        label="approval artifact",
        require_nonempty=True,
    )
    if artifact_error:
        return artifact_error, None
    if approval.get("artifacts") != request.get("artifacts"):
        return "approval artifact set differs from request", None

    evidence_error = validate_reference_entries(
        approval.get("evidence"),
        label="approval evidence",
        require_nonempty=True,
    )
    if evidence_error:
        return evidence_error, None

    try:
        approved_at = parse_time(approval["approvedAt"])
        approval_expiry = parse_time(approval["expiresAt"])
        request_created = parse_time(request["createdAt"])
        request_expiry = parse_time(request["expiresAt"])
    except (TypeError, ValueError):
        return "invalid approval timestamps", None
    if approval_expiry != request_expiry:
        return "approval expiry does not match request", None
    if approved_at < request_created:
        return "approval predates request creation", None
    if approved_at >= request_expiry:
        return "approval was recorded after request expiry", None
    return None, approval_expiry


def validate_gate(
    repo: Path,
    request_ref: str,
    approval_ref: str,
    expected_node: str,
    *,
    now: dt.datetime | None = None,
) -> dict[str, Any]:
    now = now or utc_now()
    try:
        request_path = repo_path(repo, request_ref)
    except (OSError, TypeError, ValueError) as exc:
        return {"state": "pending", "reason": str(exc), "node": expected_node}
    try:
        request = read_json(request_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return {"state": "invalid", "reason": f"invalid request document: {exc}", "node": expected_node}
    base = {
        "node": expected_node,
        "gateId": request.get("gateId"),
        "owner": request.get("requiredOwner"),
        "requestRef": request_ref,
        "approvalRef": approval_ref,
    }
    request_error, _, request_expiry = validate_request_document(
        request, expected_node=expected_node
    )
    if request_error or request_expiry is None:
        return {**base, "state": "invalid", "reason": request_error or "invalid request"}
    if now >= request_expiry:
        return {**base, "state": "expired", "reason": "request expired"}
    try:
        approval_path = repo_path(repo, approval_ref)
    except (OSError, TypeError, ValueError) as exc:
        return {**base, "state": "pending", "reason": str(exc)}
    try:
        approval = read_json(approval_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return {**base, "state": "invalid", "reason": f"invalid approval document: {exc}"}
    approval_error, approval_expiry = validate_approval_document(
        approval,
        request=request,
        request_ref=request_ref,
        request_sha256=sha256_file(request_path),
    )
    if approval_error:
        state = "stale" if approval_error in {
            "request changed after approval",
            "approval expiry does not match request",
            "approval artifact set differs from request",
        } else "invalid"
        return {**base, "state": state, "reason": approval_error}
    if approval.get("decision") == "rejected":
        return {**base, "state": "rejected", "reason": "approval rejected"}
    assert approval_expiry is not None
    if now >= approval_expiry:
        return {**base, "state": "expired", "reason": "approval expired"}

    requested_artifacts = request.get("artifacts")
    for artifact in requested_artifacts:
        try:
            path = repo_path(repo, str(artifact["ref"]))
            actual = sha256_file(path)
        except (KeyError, OSError, ValueError) as exc:
            return {**base, "state": "stale", "reason": str(exc)}
        if actual != artifact.get("sha256"):
            return {
                **base,
                "state": "stale",
                "reason": f"artifact changed after approval: {artifact.get('ref')}",
            }

    for item in approval["evidence"]:
        try:
            path = repo_path(repo, str(item["ref"]))
            actual = sha256_file(path)
        except (KeyError, OSError, ValueError) as exc:
            return {**base, "state": "stale", "reason": str(exc)}
        if actual != item.get("sha256"):
            return {
                **base,
                "state": "stale",
                "reason": f"approval evidence changed: {item.get('ref')}",
            }
    return {
        **base,
        "state": "approved",
        "reason": "exact owner, questions, expiry, and artifact hashes verified",
        "expiresAt": request["expiresAt"],
        "blockedNodes": request.get("blockedNodes", []),
    }


def parse_pair(raw: str, label: str) -> tuple[str, str]:
    if "=" not in raw:
        raise ValueError(f"{label} must use key=value form")
    key, value = raw.split("=", 1)
    if not key or not value:
        raise ValueError(f"{label} must use non-empty key=value form")
    return key, value


def request_command(args: argparse.Namespace) -> None:
    repo = Path(args.repo).resolve()
    questions = []
    question_ids: set[str] = set()
    for raw in args.question:
        key, prompt = parse_pair(raw, "--question")
        if key in question_ids:
            raise ValueError(f"duplicate --question id: {key}")
        question_ids.add(key)
        questions.append({"id": key, "prompt": prompt, "required": True})
    artifacts = []
    artifact_refs: set[str] = set()
    for ref in args.artifact:
        if ref in artifact_refs:
            raise ValueError(f"duplicate --artifact reference: {ref}")
        artifact_refs.add(ref)
        path = repo_path(repo, ref)
        artifacts.append({"ref": ref, "sha256": sha256_file(path)})
    request_path = repo_path(repo, args.request_ref, must_exist=False)
    if request_path in {repo_path(repo, ref) for ref in artifact_refs}:
        raise ValueError("request document cannot overwrite an approved artifact")
    created_at = utc_now(args.now)
    record = {
        "schema": REQUEST_SCHEMA,
        "gateId": args.gate_id,
        "node": args.node,
        "approvalType": args.approval_type,
        "requiredOwner": args.owner,
        "questions": questions,
        "artifacts": artifacts,
        "blockedNodes": args.blocked_node,
        "createdAt": iso(created_at),
        "expiresAt": iso(parse_time(args.expires_at)),
    }
    request_error, _, _ = validate_request_document(record, expected_node=args.node)
    if request_error:
        raise ValueError(request_error)
    atomic_json(request_path, record)


def approve_command(args: argparse.Namespace) -> None:
    repo = Path(args.repo).resolve()
    request_path = repo_path(repo, args.request_ref)
    request = read_json(request_path)
    request_error, _, _ = validate_request_document(request, expected_node=args.node)
    if request_error:
        raise ValueError(request_error)
    answer_pairs = [parse_pair(raw, "--answer") for raw in args.answer]
    if len({key for key, _ in answer_pairs}) != len(answer_pairs):
        raise ValueError("duplicate --answer id")
    answers = dict(answer_pairs)
    evidence = []
    evidence_refs: set[str] = set()
    for ref in args.evidence:
        if ref in evidence_refs:
            raise ValueError(f"duplicate --evidence reference: {ref}")
        evidence_refs.add(ref)
        path = repo_path(repo, ref)
        evidence.append({"ref": ref, "sha256": sha256_file(path)})
    now = utc_now(args.now)
    record = {
        "schema": APPROVAL_SCHEMA,
        "gateId": request["gateId"],
        "node": args.node,
        "requestRef": args.request_ref,
        "requestSha256": sha256_file(request_path),
        "approver": args.approver,
        "decision": args.decision,
        "answers": answers,
        "artifacts": request["artifacts"],
        "evidence": evidence,
        "rationale": args.rationale,
        "approvedAt": iso(now),
        "expiresAt": request["expiresAt"],
    }
    approval_path = repo_path(repo, args.approval_ref, must_exist=False)
    if approval_path == request_path:
        raise ValueError("approval document must not overwrite its request")
    if args.gate_result_ref:
        gate_result_path = repo_path(repo, args.gate_result_ref, must_exist=False)
        if gate_result_path in {request_path, approval_path}:
            raise ValueError("gate result must not overwrite request or approval")
    atomic_json(approval_path, record)
    result = validate_gate(repo, args.request_ref, args.approval_ref, args.node, now=now)
    if result["state"] != ("approved" if args.decision == "approved" else "rejected"):
        approval_path.unlink(missing_ok=True)
        raise ValueError(result["reason"])
    if args.decision == "approved" and args.gate_result_ref:
        write_v1 = repo_schema_version(repo) == "v2"
        gate = {
            "schema": GATE_RESULT_V1 if write_v1 else GATE_RESULT_V0,
            "node": args.node,
            "status": "passed",
            "authoritative": True,
            "campaignBinding": os.environ.get("SINGULAR_CAMPAIGN_BINDING", "legacy"),
            "evidenceClass": "human-approval",
            "evidence": [
                {
                    "kind": "source-path",
                    "ref": args.request_ref,
                    "sha256": sha256_file(request_path),
                },
                {
                    "kind": "source-path",
                    "ref": args.approval_ref,
                    "sha256": sha256_file(approval_path),
                },
            ],
            "decidedBy": args.approver,
            "rationale": args.rationale,
            "recordedAt": iso(now),
        }
        if write_v1:
            gate.update(
                {
                    "verificationClassification": "not-rerun-evidence-verified",
                    "humanGateRef": args.request_ref,
                    "humanApprovalRef": args.approval_ref,
                    "blockedNodes": request.get("blockedNodes", []),
                }
            )
        atomic_json(repo_path(repo, args.gate_result_ref, must_exist=False), gate)
    print(json.dumps(result, separators=(",", ":")))


def status_command(args: argparse.Namespace) -> None:
    result = validate_gate(
        Path(args.repo).resolve(),
        args.request_ref,
        args.approval_ref,
        args.node,
        now=utc_now(args.now),
    )
    print(json.dumps(result, separators=(",", ":")))
    if args.require_approved and result["state"] != "approved":
        raise SystemExit(1)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    subs = root.add_subparsers(dest="command", required=True)

    request = subs.add_parser("request")
    request.add_argument("--repo", required=True)
    request.add_argument("--node", required=True)
    request.add_argument("--gate-id", required=True)
    request.add_argument("--approval-type", required=True)
    request.add_argument("--owner", required=True)
    request.add_argument("--expires-at", required=True)
    request.add_argument("--request-ref", required=True)
    request.add_argument("--question", action="append", default=[], required=True)
    request.add_argument("--artifact", action="append", default=[], required=True)
    request.add_argument("--blocked-node", action="append", default=[])
    request.add_argument("--now")
    request.set_defaults(handler=request_command)

    approve = subs.add_parser("approve")
    approve.add_argument("--repo", required=True)
    approve.add_argument("--node", required=True)
    approve.add_argument("--request-ref", required=True)
    approve.add_argument("--approval-ref", required=True)
    approve.add_argument("--gate-result-ref")
    approve.add_argument("--approver", required=True)
    approve.add_argument("--decision", choices=("approved", "rejected"), default="approved")
    approve.add_argument("--answer", action="append", default=[])
    approve.add_argument("--evidence", action="append", default=[])
    approve.add_argument("--rationale", required=True)
    approve.add_argument("--now")
    approve.set_defaults(handler=approve_command)

    status = subs.add_parser("status")
    status.add_argument("--repo", required=True)
    status.add_argument("--node", required=True)
    status.add_argument("--request-ref", required=True)
    status.add_argument("--approval-ref", required=True)
    status.add_argument("--now")
    status.add_argument("--require-approved", action="store_true")
    status.set_defaults(handler=status_command)
    return root


def main() -> None:
    args = parser().parse_args()
    try:
        args.handler(args)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(f"human-gate: {exc}") from exc


if __name__ == "__main__":
    main()
