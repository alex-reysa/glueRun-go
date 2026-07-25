#!/usr/bin/env python3
"""Normalize a gate command and strict adapter sidecar into gate-report.v0."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import sys
from typing import Any


def sha_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha_file(path: Path) -> str:
    return sha_bytes(path.read_bytes())


def evidence_binding(report: dict[str, Any]) -> str:
    bound = {
        "headSha": report.get("headSha"),
        "commandSha256": report.get("commandSha256"),
        "rawExitCode": report.get("rawExitCode"),
        "logSha256": report.get("logSha256"),
        "outcome": report.get("outcome"),
        "baselineSha256": report.get("baselineSha256", ""),
    }
    return sha_bytes(
        json.dumps(bound, sort_keys=True, separators=(",", ":")).encode("utf-8")
    )


def failures(data: Any, label: str) -> list[dict[str, str]]:
    if not isinstance(data, list):
        raise ValueError(f"{label} must be an array")
    output = []
    seen = set()
    for item in data:
        if not isinstance(item, dict) or set(item) - {"signature", "title"}:
            raise ValueError(f"{label} entries require signature and optional title")
        signature = item.get("signature")
        if not isinstance(signature, str) or not signature:
            raise ValueError(f"{label} signature must be non-empty")
        if signature in seen:
            raise ValueError(f"{label} contains duplicate signature: {signature}")
        seen.add(signature)
        record = {"signature": signature}
        if isinstance(item.get("title"), str):
            record["title"] = item["title"]
        output.append(record)
    return output


def read_object(path: Path, schema: str) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("schema") != schema:
        raise ValueError(f"invalid {schema} record: {path}")
    return data


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--command", required=True)
    parser.add_argument("--raw-exit-code", required=True, type=int)
    parser.add_argument("--log-ref", required=True)
    parser.add_argument("--log-path", required=True)
    parser.add_argument("--observation")
    parser.add_argument("--baseline")
    parser.add_argument("--require-observation", action="store_true")
    parser.add_argument(
        "--integrity-status",
        choices=("verified", "violation", "not-checked"),
        default="not-checked",
    )
    parser.add_argument("--changed-path", action="append", default=[])
    parser.add_argument("--duration-ms", type=int, default=0)
    parser.add_argument(
        "--phase",
        choices=("worker", "audit-verification", "integration", "other"),
        default="other",
    )
    parser.add_argument(
        "--workspace-kind",
        choices=("worker", "disposable", "evidence-only", "integration"),
        default="worker",
    )
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    log_path = Path(args.log_path)
    command_sha = sha_bytes(args.command.encode("utf-8"))
    observed: list[dict[str, str]] = []
    infrastructure = False
    observation: dict[str, Any] = {}
    observation_path = Path(args.observation) if args.observation else None
    if observation_path and observation_path.is_file():
        observation = read_object(
            observation_path, "gluerun.orchestration.gate-observation.v0"
        )
        observed = failures(observation.get("failures"), "observation.failures")
        infrastructure = bool(observation.get("infrastructureFailure"))
    elif args.require_observation:
        raise ValueError("strict gate observation missing")
    elif args.raw_exit_code != 0:
        # A non-zero command without a strict adapter report is an unexpected
        # product failure. Raw stdout is never mined for signatures.
        observed = [{"signature": "gate-command-nonzero-without-report"}]

    baseline_path = Path(args.baseline) if args.baseline else None
    baseline_failures: list[dict[str, str]] = []
    baseline_sha = None
    if baseline_path:
        if not baseline_path.is_file():
            raise ValueError(f"baseline file missing: {baseline_path}")
        if not observation_path or not observation_path.is_file():
            raise ValueError(
                "strict gate observation missing for acknowledged baseline"
            )
        baseline = read_object(
            baseline_path, "gluerun.orchestration.gate-baseline.v0"
        )
        if baseline.get("commandSha256") != command_sha:
            raise ValueError("baseline command hash mismatch")
        baseline_failures = failures(baseline.get("failures"), "baseline.failures")
        baseline_sha = sha_file(baseline_path)

    expected_by_sig = {item["signature"]: item for item in baseline_failures}
    observed_by_sig = {item["signature"]: item for item in observed}
    expected = [
        observed_by_sig[key] for key in observed_by_sig if key in expected_by_sig
    ]
    unexpected = [
        observed_by_sig[key] for key in observed_by_sig if key not in expected_by_sig
    ]
    resolved = [
        expected_by_sig[key] for key in expected_by_sig if key not in observed_by_sig
    ]

    terminal_infrastructure = ""
    if args.raw_exit_code in {124, 137, 143}:
        terminal_infrastructure = "gate-command-timeout"
    elif args.raw_exit_code != 0 and not observed and not infrastructure:
        terminal_infrastructure = f"unknown-terminal-exit:{args.raw_exit_code}"

    # An integrity violation invalidates the attempt even when output also
    # resembles an assertion. Otherwise a genuine structured product signal
    # remains actionable when unrelated infrastructure symptoms coexist.
    if args.integrity_status == "violation":
        outcome = "inconclusive-infrastructure"
    elif unexpected:
        outcome = "failed-product"
    elif infrastructure or terminal_infrastructure:
        outcome = "inconclusive-infrastructure"
    elif observed:
        outcome = "passed-with-acknowledged-baseline"
    elif args.raw_exit_code == 0:
        outcome = "passed"
    else:
        outcome = "failed-product"

    record: dict[str, Any] = {
        "schema": "gluerun.orchestration.gate-report.v0",
        "taskId": args.task_id,
        "runId": args.run_id,
        "headSha": args.head_sha,
        "command": args.command,
        "commandSha256": command_sha,
        "outcome": outcome,
        "expectedFailures": expected,
        "unexpectedFailures": unexpected,
        "resolvedExpectedFailures": resolved,
        "rawExitCode": args.raw_exit_code,
        "logRef": args.log_ref,
        "logSha256": sha_file(log_path),
        "logBytes": log_path.stat().st_size,
        "durationMs": max(0, args.duration_ms),
        "phase": args.phase,
        "workspaceKind": args.workspace_kind,
        "evidenceOnly": False,
        "sourceIntegrity": {
            "status": args.integrity_status,
            "changedPaths": sorted(set(args.changed_path)),
        },
        "failureSignals": [item["signature"] for item in unexpected],
        "infrastructureSignals": sorted(
            set(
                (
                    [
                        str(
                            observation.get("infrastructureReason")
                            or "adapter-infrastructure-failure"
                        )
                    ]
                    if infrastructure
                    else []
                )
                + ([terminal_infrastructure] if terminal_infrastructure else [])
                + (
                    ["source-integrity-violation"]
                    if args.integrity_status == "violation"
                    else []
                )
            )
        ),
        "recordedAt": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }
    if baseline_path:
        record["baselineRef"] = str(baseline_path)
        record["baselineSha256"] = baseline_sha
    record["evidenceBindingSha256"] = evidence_binding(record)
    Path(args.output).write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(outcome)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(f"gate-report: {exc}") from exc
