#!/usr/bin/env python3
"""Symlink-safe atomic publication below one trusted repository root."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import secrets
import stat
import sys


DIRECTORY_FLAGS = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


class UnsafePath(RuntimeError):
    pass


def _open_parent(root_raw: str, destination_raw: str, create: bool) -> tuple[int, str]:
    root = os.path.abspath(root_raw)
    destination = os.path.abspath(destination_raw)
    try:
        root_stat = os.lstat(root)
    except OSError as exc:
        raise UnsafePath(f"publication root is unavailable: {exc}") from exc
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        raise UnsafePath("publication root must be a real directory")
    try:
        contained = os.path.commonpath((root, destination)) == root
    except ValueError:
        contained = False
    if not contained or destination == root:
        raise UnsafePath(f"destination escapes publication root: {destination_raw}")
    relative = os.path.relpath(destination, root)
    parts = Path(relative).parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise UnsafePath(f"unsafe publication destination: {destination_raw}")

    directory_fd = os.open(root, DIRECTORY_FLAGS)
    try:
        for component in parts[:-1]:
            try:
                value = os.stat(component, dir_fd=directory_fd, follow_symlinks=False)
            except FileNotFoundError:
                if not create:
                    raise UnsafePath(f"destination parent is missing: {component}")
                os.mkdir(component, mode=0o755, dir_fd=directory_fd)
                value = os.stat(component, dir_fd=directory_fd, follow_symlinks=False)
            if stat.S_ISLNK(value.st_mode) or not stat.S_ISDIR(value.st_mode):
                raise UnsafePath(f"destination parent is not a real directory: {component}")
            next_fd = os.open(component, DIRECTORY_FLAGS, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
        return directory_fd, parts[-1]
    except Exception:
        os.close(directory_fd)
        raise


def _regular_identity(directory_fd: int, leaf: str) -> str | None:
    try:
        value = os.stat(leaf, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(value.st_mode) or not stat.S_ISREG(value.st_mode):
        raise UnsafePath(f"publication destination is not a regular file: {leaf}")
    descriptor = os.open(leaf, os.O_RDONLY | NOFOLLOW, dir_fd=directory_fd)
    digest = hashlib.sha256()
    try:
        opened_stat = os.fstat(descriptor)
        if not stat.S_ISREG(opened_stat.st_mode):
            raise UnsafePath(f"publication destination is not a regular file: {leaf}")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    finally:
        os.close(descriptor)
    return f"{digest.hexdigest()}:{stat.S_IMODE(opened_stat.st_mode):04o}"


def _backup_regular(directory_fd: int, leaf: str, destination: str) -> str:
    source_fd = os.open(leaf, os.O_RDONLY | NOFOLLOW, dir_fd=directory_fd)
    source_before = os.fstat(source_fd)
    if not stat.S_ISREG(source_before.st_mode):
        os.close(source_fd)
        raise UnsafePath(f"publication destination is not a regular file: {leaf}")
    output_fd = os.open(
        destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600
    )
    os.fchmod(output_fd, stat.S_IMODE(source_before.st_mode))
    digest = hashlib.sha256()
    try:
        with os.fdopen(source_fd, "rb", closefd=False) as input_stream, os.fdopen(
            output_fd, "wb", closefd=False
        ) as output:
            for block in iter(lambda: input_stream.read(1024 * 1024), b""):
                digest.update(block)
                output.write(block)
            output.flush()
            os.fsync(output.fileno())
        source_after = os.fstat(source_fd)
        if (
            source_before.st_dev,
            source_before.st_ino,
            source_before.st_size,
            source_before.st_mtime_ns,
        ) != (
            source_after.st_dev,
            source_after.st_ino,
            source_after.st_size,
            source_after.st_mtime_ns,
        ):
            raise UnsafePath("destination changed while its rollback backup was prepared")
    finally:
        os.close(source_fd)
        os.close(output_fd)
    return f"{digest.hexdigest()}:{stat.S_IMODE(source_before.st_mode):04o}"


def prepare(root: str, destination: str, backup: str) -> None:
    directory_fd, leaf = _open_parent(root, destination, create=True)
    try:
        try:
            value = os.stat(leaf, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            print("no\t-")
            return
        if stat.S_ISLNK(value.st_mode) or not stat.S_ISREG(value.st_mode):
            raise UnsafePath(f"publication destination is not a regular file: {leaf}")
        backup_parent = os.path.dirname(os.path.abspath(backup))
        if not os.path.isdir(backup_parent):
            raise UnsafePath("transaction backup parent is unavailable")
        identity = _backup_regular(directory_fd, leaf, backup)
        print(f"yes\t{identity}")
    finally:
        os.close(directory_fd)


def _atomic_install(
    root: str,
    destination: str,
    source: str,
    expected_existed: str | None = None,
    expected_identity: str | None = None,
) -> None:
    directory_fd, leaf = _open_parent(root, destination, create=True)
    temporary = f".singular-publish-{secrets.token_hex(16)}.tmp"
    try:
        if expected_existed is not None:
            current = _regular_identity(directory_fd, leaf)
            if expected_existed == "yes":
                if current is None or current != expected_identity:
                    raise UnsafePath("destination changed after rollback backup")
            elif current is not None:
                raise UnsafePath("destination appeared after rollback preparation")

        source_stat = os.lstat(source)
        if stat.S_ISLNK(source_stat.st_mode) or not stat.S_ISREG(source_stat.st_mode):
            raise UnsafePath(f"publication source is not a regular file: {source}")
        temporary_fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW,
            0o600,
            dir_fd=directory_fd,
        )
        os.fchmod(temporary_fd, stat.S_IMODE(source_stat.st_mode))
        try:
            with open(source, "rb") as input_stream, os.fdopen(
                temporary_fd, "wb", closefd=False
            ) as output:
                for block in iter(lambda: input_stream.read(1024 * 1024), b""):
                    output.write(block)
                output.flush()
                os.fsync(output.fileno())
        finally:
            os.close(temporary_fd)
        os.replace(temporary, leaf, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        os.fsync(directory_fd)
    except Exception:
        try:
            os.unlink(temporary, dir_fd=directory_fd)
        except OSError:
            pass
        raise
    finally:
        os.close(directory_fd)


def rollback(root: str, destination: str, existed: str, backup: str) -> None:
    if existed == "yes":
        _atomic_install(root, destination, backup)
        return
    directory_fd, leaf = _open_parent(root, destination, create=False)
    try:
        current = _regular_identity(directory_fd, leaf)
        if current is not None:
            os.unlink(leaf, dir_fd=directory_fd)
            os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    publish_parser = subparsers.add_parser("publish")
    rollback_parser = subparsers.add_parser("rollback")
    for item in (prepare_parser, publish_parser, rollback_parser):
        item.add_argument("--root", required=True)
        item.add_argument("--destination", required=True)
    prepare_parser.add_argument("--backup", required=True)
    publish_parser.add_argument("--source", required=True)
    publish_parser.add_argument("--expected-existed", choices=("yes", "no"), required=True)
    publish_parser.add_argument("--expected-identity", required=True)
    rollback_parser.add_argument("--existed", choices=("yes", "no"), required=True)
    rollback_parser.add_argument("--backup", required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "prepare":
            prepare(arguments.root, arguments.destination, arguments.backup)
        elif arguments.command == "publish":
            _atomic_install(
                arguments.root,
                arguments.destination,
                arguments.source,
                arguments.expected_existed,
                arguments.expected_identity,
            )
        else:
            rollback(
                arguments.root,
                arguments.destination,
                arguments.existed,
                arguments.backup,
            )
    except (OSError, UnsafePath) as exc:
        print(f"safe publication refused: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
