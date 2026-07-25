#!/usr/bin/env python3
"""Bind an audit-verdict.v1 verification aggregate to the host classification."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


AUDIT_V1 = "gluerun.orchestration.audit-verdict.v1"
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-report", type=Path, required=True)
    parser.add_argument("--verdict", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        print(bind(args.host_report, args.verdict))
    except ValueError as exc:
        raise SystemExit(f"audit-verdict-host-bind: {exc}") from exc


if __name__ == "__main__":
    main()
