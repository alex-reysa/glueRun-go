#!/usr/bin/env python3
"""Bind an audit-verdict.v1 verification aggregate to the host classification."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


AUDIT_V1 = "singular.orchestration.audit-verdict.v1"
CLASSIFICATIONS = {
    "passed",
    "failed-product",
    "inconclusive-infrastructure",
    "not-rerun-evidence-verified",
}
HOST_ALIASES = {
    "passed-with-acknowledged-baseline": "passed",
}


def read_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object")
    return value


def host_classification(report: dict[str, Any]) -> str:
    raw = str(report.get("outcome") or "")
    classification = HOST_ALIASES.get(raw, raw)
    if classification not in CLASSIFICATIONS:
        raise ValueError(f"unsupported host verification classification: {raw!r}")
    return classification


def model_aggregate(verdict: dict[str, Any]) -> tuple[str, list[str]]:
    if verdict.get("schema") != AUDIT_V1:
        raise ValueError("audit verdict is not audit-verdict.v1")
    results = verdict.get("verificationResults")
    if not isinstance(results, list) or not results:
        raise ValueError("audit-verdict.v1 verificationResults must be non-empty")
    statuses: list[str] = []
    for index, result in enumerate(results):
        if not isinstance(result, dict):
            raise ValueError(f"verificationResults[{index}] must be an object")
        status = result.get("status")
        if status not in CLASSIFICATIONS:
            raise ValueError(
                f"verificationResults[{index}] has unsupported status: {status!r}"
            )
        statuses.append(status)

    unique = set(statuses)
    if "failed-product" in unique:
        aggregate = "failed-product"
    elif "inconclusive-infrastructure" in unique:
        aggregate = "inconclusive-infrastructure"
    elif unique == {"passed"}:
        aggregate = "passed"
    elif unique == {"not-rerun-evidence-verified"}:
        aggregate = "not-rerun-evidence-verified"
    else:
        raise ValueError(
            "audit-verdict.v1 mixes passed and not-rerun-evidence-verified "
            "verification classifications"
        )
    return aggregate, statuses


def bind(host_report: Path, verdict_path: Path | None) -> str:
    host = host_classification(read_object(host_report, "host verification report"))
    if verdict_path is None:
        return host

    verdict = read_object(verdict_path, "audit verdict")
    aggregate, statuses = model_aggregate(verdict)
    if host == "not-rerun-evidence-verified" and "passed" in statuses:
        raise ValueError(
            "evidence-only host verification cannot be represented as passed"
        )
    if aggregate != host:
        raise ValueError(
            "audit-verdict.v1 verification aggregate does not match host "
            f"classification: model={aggregate} host={host}"
        )
    return aggregate


def normalize(
    host_report: Path, verdict_path: Path, command: str, evidence_ref: str
) -> str:
    """Rewrite the verdict's verificationResults to the host classification.

    The host owns the classification; the model was only asked to echo it. When
    the echo disagrees (or is malformed), the model's product judgment is kept
    and its verification aggregate is replaced by one host-authored result. The
    original verdict is preserved beside the file for the record. A verdict
    that already matches is left byte-identical.
    """
    host = host_classification(read_object(host_report, "host verification report"))
    verdict = read_object(verdict_path, "audit verdict")
    if verdict.get("schema") != AUDIT_V1:
        raise ValueError("audit verdict is not audit-verdict.v1")
    reason = ""
    try:
        aggregate, statuses = model_aggregate(verdict)
        if host == "not-rerun-evidence-verified" and "passed" in statuses:
            reason = f"model reported passed for evidence-only host verification"
        elif aggregate != host:
            reason = f"model={aggregate} host={host}"
    except ValueError as exc:
        reason = str(exc)
    if not reason:
        return host
    backup = verdict_path.with_name(verdict_path.name + ".pre-normalize.json")
    backup.write_text(json.dumps(verdict, indent=2) + "\n", encoding="utf-8")
    verdict["verificationResults"] = [
        {
            "status": host,
            "command": command or "(host verification)",
            "evidenceRefs": [evidence_ref or str(host_report)],
            "rationale": (
                "host-authoritative verification classification; the auditor's "
                f"own aggregate was replaced ({reason})"
            ),
        }
    ]
    temporary = verdict_path.with_name(verdict_path.name + ".normalize.tmp")
    temporary.write_text(json.dumps(verdict, indent=2) + "\n", encoding="utf-8")
    temporary.replace(verdict_path)
    print(f"audit-verdict-host-bind: normalized verificationResults ({reason})",
          file=sys.stderr)
    return host


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-report", type=Path, required=True)
    parser.add_argument("--verdict", type=Path)
    parser.add_argument("--normalize", action="store_true",
                        help="rewrite a mismatched verdict to the host classification")
    parser.add_argument("--command", default="")
    parser.add_argument("--evidence-ref", default="")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        if args.normalize:
            if args.verdict is None:
                raise ValueError("--normalize requires --verdict")
            print(normalize(args.host_report, args.verdict, args.command, args.evidence_ref))
        else:
            print(bind(args.host_report, args.verdict))
    except ValueError as exc:
        raise SystemExit(f"audit-verdict-host-bind: {exc}") from exc


if __name__ == "__main__":
    main()
