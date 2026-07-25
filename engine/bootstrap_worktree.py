#!/usr/bin/env python3
"""Validate and apply deterministic, contained worktree bootstrap configuration."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from typing import Any


def inside(parent: Path, child: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except (OSError, ValueError):
        return False


def repo_relative(root: Path, raw: str, label: str, *, follow_final: bool = True) -> Path:
    rel = Path(raw)
    if rel.is_absolute() or ".." in rel.parts or str(rel) in {"", "."}:
        raise ValueError(f"{label} must be a clean repository-relative path: {raw}")
    raw_path = root / rel
    path = raw_path.resolve() if follow_final else raw_path.parent.resolve() / raw_path.name
    containment_path = path if follow_final else path.parent
    if not inside(root, containment_path):
        raise ValueError(f"{label} escapes worktree: {raw}")
    return path


def git(worktree: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(worktree), *args],
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def bootstrap_inputs(
    worktree: Path, lockfile_paths: dict[str, Path]
) -> tuple[str, dict[str, str]]:
    head = git(worktree, "rev-parse", "--verify", "HEAD").stdout.strip()
    if not head:
        raise SystemExit("bootstrap: worktree HEAD is unavailable")
    hashes = {
        raw: sha256_file(path)
        for raw, path in sorted(lockfile_paths.items())
    }
    return head, hashes


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--worktree", required=True)
    parser.add_argument("--config-json", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    worktree = Path(args.worktree).resolve()
    state_dir = Path(args.state_dir).resolve()
    if not inside(repo.parent, worktree) and worktree != repo:
        # Worktrees may be outside the repository but must still be real worktrees.
        git(worktree, "rev-parse", "--show-toplevel")
    config = json.loads(args.config_json)
    if not isinstance(config, dict):
        raise SystemExit("bootstrap: configuration must be an object")
    command = config.get("command")
    if command is not None and not isinstance(command, str):
        raise SystemExit("bootstrap: command must be a string")
    required = bool(config.get("required", True))
    lockfiles = config.get("lockfiles", [])
    command_items = config.get("commands", [])
    links = config.get("sharedLinks", [])
    roots = config.get("sharedStoreRoots", [])
    if not all(isinstance(item, str) for item in lockfiles):
        raise SystemExit("bootstrap: lockfiles must be strings")
    if not isinstance(command_items, list):
        raise SystemExit("bootstrap: commands must be an array")
    commands: list[dict[str, Any]] = []
    if command:
        commands.append(
            {
                "command": command,
                "required": required,
                "lockfiles": list(lockfiles),
            }
        )
    for index, item in enumerate(command_items):
        if not isinstance(item, dict):
            raise SystemExit(f"bootstrap: commands[{index}] must be an object")
        extra = set(item) - {"command", "required", "lockfiles"}
        if extra:
            raise SystemExit(
                f"bootstrap: commands[{index}] has unknown fields: "
                + ", ".join(sorted(extra))
            )
        item_command = item.get("command")
        if not isinstance(item_command, str) or not item_command.strip():
            raise SystemExit(
                f"bootstrap: commands[{index}].command must be a non-empty string"
            )
        item_required = item.get("required", required)
        if not isinstance(item_required, bool):
            raise SystemExit(
                f"bootstrap: commands[{index}].required must be a boolean"
            )
        item_lockfiles = item.get("lockfiles", lockfiles)
        if not isinstance(item_lockfiles, list) or not all(
            isinstance(value, str) for value in item_lockfiles
        ):
            raise SystemExit(
                f"bootstrap: commands[{index}].lockfiles must be strings"
            )
        commands.append(
            {
                "command": item_command,
                "required": item_required,
                "lockfiles": item_lockfiles,
            }
        )
    allowed_roots = [Path(item).expanduser().resolve() for item in roots if isinstance(item, str)]

    declared_lockfiles = list(
        dict.fromkeys(
            [
                *lockfiles,
                *[
                    raw
                    for item in commands
                    for raw in item.get("lockfiles", [])
                ],
            ]
        )
    )
    lockfile_paths: dict[str, Path] = {}
    for raw in declared_lockfiles:
        path = repo_relative(worktree, raw, "lockfile")
        if not path.is_file():
            raise SystemExit(f"bootstrap: required lockfile missing: {raw}")
        if git(worktree, "ls-files", "--error-unmatch", "--", raw, check=False).returncode != 0:
            raise SystemExit(f"bootstrap: lockfile must be tracked: {raw}")
        lockfile_paths[raw] = path
    head_sha, lockfile_hashes = bootstrap_inputs(worktree, lockfile_paths)

    planned_links = []
    if not isinstance(links, list):
        raise SystemExit("bootstrap: sharedLinks must be an array")
    for item in links:
        if not isinstance(item, dict) or set(item) != {"source", "target"}:
            raise SystemExit("bootstrap: shared link requires source and target")
        source = Path(str(item["source"])).expanduser().resolve()
        if not any(inside(root, source) or source == root for root in allowed_roots):
            raise SystemExit(f"bootstrap: shared link source is not allowlisted: {source}")
        if not source.exists():
            raise SystemExit(f"bootstrap: shared link source is missing: {source}")
        target_raw = str(item["target"])
        target = repo_relative(
            worktree, target_raw, "shared link target", follow_final=False
        )
        if git(worktree, "ls-files", "--error-unmatch", "--", target_raw, check=False).returncode == 0:
            raise SystemExit(f"bootstrap: shared link target is tracked: {target_raw}")
        if git(worktree, "check-ignore", "-q", "--", target_raw, check=False).returncode != 0:
            raise SystemExit(f"bootstrap: shared link target must be gitignored: {target_raw}")
        if target.exists() and not target.is_symlink():
            raise SystemExit(f"bootstrap: shared link target already exists: {target_raw}")
        planned_links.append((source, target))

    config_bytes = json.dumps(config, sort_keys=True, separators=(",", ":")).encode()
    config_sha = hashlib.sha256(config_bytes).hexdigest()
    worktree_key = hashlib.sha256(str(worktree).encode()).hexdigest()
    marker = state_dir / "bootstrap" / f"{worktree_key}.json"
    try:
        previous = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        previous = {}
    if (
        previous.get("schema") == "gluerun.orchestration.bootstrap-result.v0"
        and previous.get("configSha256") == config_sha
        and previous.get("worktree") == str(worktree)
        and previous.get("headSha") == head_sha
        and previous.get("lockfileSha256") == lockfile_hashes
    ):
        print(json.dumps({"status": "already-complete", "marker": str(marker)}, separators=(",", ":")))
        return
    if args.dry_run:
        print(json.dumps({
            "status": "valid",
            "required": required,
            "commands": len(commands),
            "lockfiles": declared_lockfiles,
            "headSha": head_sha,
            "lockfileSha256": lockfile_hashes,
            "sharedLinks": len(planned_links),
        }, separators=(",", ":")))
        return

    for source, target in planned_links:
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink():
            if target.resolve() != source:
                target.unlink()
                target.symlink_to(source, target_is_directory=source.is_dir())
        else:
            target.symlink_to(source, target_is_directory=source.is_dir())

    command_results = []
    for index, item in enumerate(commands):
        result = subprocess.run(
            ["/bin/bash", "-lc", item["command"]],
            cwd=worktree,
            text=True,
        )
        command_results.append(
            {
                "index": index,
                "required": item["required"],
                "exitCode": result.returncode,
                "commandSha256": hashlib.sha256(
                    item["command"].encode("utf-8")
                ).hexdigest(),
            }
        )
        if result.returncode != 0 and item["required"]:
            raise SystemExit(result.returncode)
        if result.returncode != 0:
            print(
                json.dumps(
                    {
                        "status": "optional-failed",
                        "index": index,
                        "exitCode": result.returncode,
                    },
                    separators=(",", ":"),
                )
            )

    completed_head_sha, completed_lockfile_hashes = bootstrap_inputs(
        worktree, lockfile_paths
    )
    if (
        completed_head_sha != head_sha
        or completed_lockfile_hashes != lockfile_hashes
    ):
        raise SystemExit(
            "bootstrap: HEAD or declared lockfile bytes changed during bootstrap"
        )

    atomic_json(marker, {
        "schema": "gluerun.orchestration.bootstrap-result.v0",
        "worktree": str(worktree),
        "configSha256": config_sha,
        "headSha": head_sha,
        "lockfileSha256": lockfile_hashes,
        "commands": command_results,
        "completedAt": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    })
    print(json.dumps({"status": "completed", "marker": str(marker)}, separators=(",", ":")))


if __name__ == "__main__":
    main()
