#!/usr/bin/env python3
"""Content-addressed working-tree guard for read-only agent runs.

A read-only run is allowed to read the repository and run read-only shell, but
must not leave the working tree changed. The CLIs cannot all enforce that
in-process, so the engine takes a snapshot before the run and puts the tree back
afterwards.

The snapshot this module takes is of *content*, not of paths. That distinction
is the whole point, and it is worth stating why, because the path-diff guard it
replaces was wrong in four separate ways that all trace back to the same
mistake: a list of paths cannot describe a state you want to return to.

  1. A file already dirty before the run appears in the "before" path list, so a
     path diff sees no change when the agent overwrites it. The agent's write
     survived, which is precisely what the guard exists to prevent.
  2. A path diff has only one place to restore *from*: HEAD. So any file the
     guard did decide to revert lost whatever uncommitted work was in it —
     including work written by somebody else while the run was in flight.
  3. `git checkout -- <path>` restores from the *index*, so an agent that ran
     `git add` kept its mutation, and a staged new file survived entirely.
  4. Untracked files that appeared during the window were `rm -rf`'d on the
     assumption the agent created them. Read-only runs execute against
     $GLUERUN_ROOT for up to 1200s while the rest of the engine keeps working in
     that same directory, so this deleted freshly imported task files — the
     engine destroying its own control state.

So: capture the exact bytes and the exact index entry of everything that is
already dirty, remember which paths were clean (their pre-run state *is* HEAD,
no capture needed), and afterwards put every changed path back to what it was.
The restore target is "the state before this run", not "HEAD".

The fourth defect deserves a second mechanism, because content-addressing alone
cannot fix it: when a file appears during the window there is no signal in the
filesystem saying whether the agent or a concurrent writer created it. So the
guard never destroys anything. Every byte it removes or overwrites is copied
into a quarantine directory next to the journal first, with a manifest. The
working tree still ends up contained; the data still exists. Callers should also
pass --exclude for directories the engine itself writes, so the common
concurrent-writer case does not trip the guard at all.

SIGKILL remains uncoverable: nothing runs in the killed process. That is what
`sweep` is for — a journal outlives its run, so a later invocation can find one
whose owner is gone and finish the restore.

Subcommands
    capture   snapshot a worktree into a journal directory
    restore   put the worktree back to the captured state, and consume the journal
    sweep     restore any journal in a root directory whose owner process is gone

Exit status is 0 whenever the guard did what it was asked, whether or not it had
to change anything; callers read `outcome` in the JSON result to tell those
apart. A nonzero exit means the guard itself could not run.
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys

SCHEMA = "gluerun.orchestration.readonly-guard.v0"

# A read-only run should have nothing dirty to preserve, or very little. A huge
# dirty set means the caller pointed the guard at something it was not designed
# for (a build tree, a vendored dependency dump), and silently spending minutes
# hashing it would be worse than declining. On overflow the journal degrades to
# report-only: it still records what it saw, and restore refuses to act rather
# than acting on a partial picture.
DEFAULT_MAX_FILES = 2000
DEFAULT_MAX_BYTES = 64 * 1024 * 1024

GIT_LINK = 0o160000
SYMLINK = 0o120000


class GuardError(RuntimeError):
    """The guard could not do its job. Never used for "the tree was dirty"."""


# --------------------------------------------------------------------------
# git plumbing
# --------------------------------------------------------------------------


def git(worktree: str, *args: str, stdin: bytes | None = None) -> bytes:
    proc = subprocess.run(
        ["git", "-C", worktree, *args],
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        raise GuardError(f"git {' '.join(args)}: {detail or proc.returncode}")
    return proc.stdout


def git_ok(worktree: str, *args: str, stdin: bytes | None = None) -> bool:
    """Run git, report success. For operations whose failure is informative but
    not fatal — a restore that cannot fix one path should still fix the rest."""
    proc = subprocess.run(
        ["git", "-C", worktree, *args],
        input=stdin,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc.returncode == 0


def nul_fields(raw: bytes) -> list[bytes]:
    parts = raw.split(b"\0")
    if parts and parts[-1] == b"":
        parts.pop()
    return parts


def decode(path: bytes) -> str:
    """Repo-relative path as text.

    Everything downstream (JSON, comparisons, pathspecs) works in text, so the
    decode has to be lossless and reversible. surrogateescape is both: bytes
    that are not valid UTF-8 survive a round trip through str and back. This is
    the whole reason the module reads git's -z forms instead of its default
    output, which quotes and escapes non-ASCII paths into something
    `git checkout --` will not accept. A localization program is exactly the
    workload that has such paths.
    """
    return path.decode("utf-8", "surrogateescape")


def encode(path: str) -> bytes:
    return path.encode("utf-8", "surrogateescape")


def read_index(worktree: str) -> dict[str, dict]:
    """path -> {mode, sha, stage} for every index entry."""
    entries: dict[str, dict] = {}
    for field in nul_fields(git(worktree, "ls-files", "-s", "-z")):
        meta, _, path = field.partition(b"\t")
        if not path:
            continue
        bits = meta.split()
        if len(bits) != 3:
            continue
        mode, sha, stage = bits
        entries[decode(path)] = {
            "mode": mode.decode("ascii"),
            "sha": sha.decode("ascii"),
            "stage": int(stage),
        }
    return entries


def read_status(worktree: str) -> dict[str, str]:
    """path -> two-letter porcelain XY code for everything not clean.

    `git status --porcelain=v1 -z` emits `XY <path>\\0`, except renames and
    copies, which emit `XY <new>\\0<old>\\0` — the second field is a payload of
    the first record, not a record of its own. Both paths matter to the guard,
    so it claims both.
    """
    raw = git(worktree, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    fields = nul_fields(raw)
    out: dict[str, str] = {}
    i = 0
    while i < len(fields):
        field = fields[i]
        i += 1
        if len(field) < 4:
            continue
        code = field[:2].decode("ascii", "replace")
        path = decode(field[3:])
        out[path] = code
        if code[0] in ("R", "C"):
            if i < len(fields):
                out[decode(fields[i])] = code
                i += 1
    return out


# --------------------------------------------------------------------------
# worktree state
# --------------------------------------------------------------------------


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def worktree_state(worktree: str, path: str) -> dict:
    """Present-ness, content hash and mode of one path, as it is on disk now.

    Directories read as absent: a path the guard tracks is a file, and a
    directory standing where a file belongs is a state restore has to replace,
    not preserve.
    """
    full = os.path.join(worktree, os.fsdecode(encode(path)))
    try:
        info = os.lstat(full)
    except OSError:
        return {"present": False}
    if stat.S_ISLNK(info.st_mode):
        target = os.readlink(full)
        return {
            "present": True,
            "kind": "symlink",
            "sha256": sha256_bytes(os.fsencode(target)),
            "size": len(os.fsencode(target)),
            "mode": SYMLINK,
        }
    if not stat.S_ISREG(info.st_mode):
        return {"present": False}
    mode = 0o100755 if info.st_mode & stat.S_IXUSR else 0o100644
    try:
        with open(full, "rb") as stream:
            data = stream.read()
    except OSError as exc:
        raise GuardError(f"cannot read {path}: {exc}") from exc
    return {
        "present": True,
        "kind": "file",
        "sha256": sha256_bytes(data),
        "size": len(data),
        "mode": mode,
    }


def read_payload(worktree: str, path: str) -> bytes:
    full = os.path.join(worktree, os.fsdecode(encode(path)))
    if os.path.islink(full):
        return os.fsencode(os.readlink(full))
    with open(full, "rb") as stream:
        return stream.read()


def same_worktree_state(left: dict, right: dict) -> bool:
    if not left.get("present") and not right.get("present"):
        return True
    if left.get("present") != right.get("present"):
        return False
    return (
        left.get("sha256") == right.get("sha256")
        and left.get("mode") == right.get("mode")
    )


def same_index_state(left: dict | None, right: dict | None) -> bool:
    if left is None and right is None:
        return True
    if left is None or right is None:
        return False
    return left.get("mode") == right.get("mode") and left.get("sha") == right.get("sha")


# --------------------------------------------------------------------------
# excludes
# --------------------------------------------------------------------------


def normalize_exclude(raw: str) -> str:
    return raw.strip().strip("/")


def is_excluded(path: str, excludes: list[str]) -> bool:
    for prefix in excludes:
        if not prefix:
            continue
        if path == prefix or path.startswith(prefix + "/"):
            return True
    return False


# --------------------------------------------------------------------------
# journal storage
# --------------------------------------------------------------------------


def blob_path(journal_dir: str, digest: str) -> str:
    return os.path.join(journal_dir, "blobs", digest)


def store_blob(journal_dir: str, data: bytes) -> str:
    digest = sha256_bytes(data)
    dest = blob_path(journal_dir, digest)
    if not os.path.exists(dest):
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        tmp = dest + ".tmp"
        with open(tmp, "wb") as stream:
            stream.write(data)
        os.replace(tmp, dest)
    return digest


def load_blob(journal_dir: str, digest: str) -> bytes:
    with open(blob_path(journal_dir, digest), "rb") as stream:
        return stream.read()


def write_json(path: str, payload: dict) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, sort_keys=True)
        stream.write("\n")
    os.replace(tmp, path)


def read_json(path: str) -> dict:
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


# --------------------------------------------------------------------------
# capture
# --------------------------------------------------------------------------


def cmd_capture(args: argparse.Namespace) -> int:
    worktree = os.path.abspath(args.worktree)
    journal_dir = os.path.abspath(args.journal)
    excludes = [normalize_exclude(e) for e in (args.exclude or [])]

    os.makedirs(journal_dir, exist_ok=True)
    journal = {
        "schema": SCHEMA,
        "worktree": worktree,
        "excludes": excludes,
        "ownerPid": args.owner_pid if args.owner_pid is not None else os.getppid(),
        "label": args.label or "",
        "degraded": False,
        "degradedReason": "",
        "head": "",
        "trackedBefore": [],
        "entries": {},
    }

    try:
        head = git(worktree, "rev-parse", "HEAD").decode("ascii", "replace").strip()
    except GuardError:
        # An unborn branch is a legitimate state; the guard just has no HEAD to
        # fall back to for clean paths. Everything relevant will be untracked
        # and therefore captured by content anyway.
        head = ""
    journal["head"] = head

    try:
        index = read_index(worktree)
        status = read_status(worktree)
    except GuardError as exc:
        journal["degraded"] = True
        journal["degradedReason"] = str(exc)
        write_json(os.path.join(journal_dir, "journal.json"), journal)
        print(json.dumps({"outcome": "degraded", "reason": str(exc)}))
        return 0

    journal["trackedBefore"] = sorted(index)

    dirty = [p for p in sorted(status) if not is_excluded(p, excludes)]
    if len(dirty) > args.max_files:
        journal["degraded"] = True
        journal["degradedReason"] = (
            f"dirty set of {len(dirty)} paths exceeds --max-files {args.max_files}"
        )
        write_json(os.path.join(journal_dir, "journal.json"), journal)
        print(
            json.dumps(
                {"outcome": "degraded", "reason": journal["degradedReason"]}
            )
        )
        return 0

    total_bytes = 0
    for path in dirty:
        entry: dict = {"status": status[path]}
        state = worktree_state(worktree, path)
        if state.get("present"):
            total_bytes += int(state.get("size") or 0)
            if total_bytes > args.max_bytes:
                journal["degraded"] = True
                journal["degradedReason"] = (
                    f"dirty content exceeds --max-bytes {args.max_bytes}"
                )
                break
            entry["worktree"] = {
                "present": True,
                "kind": state["kind"],
                "sha256": store_blob(journal_dir, read_payload(worktree, path)),
                "mode": state["mode"],
            }
        else:
            entry["worktree"] = {"present": False}
        ix = index.get(path)
        entry["index"] = None if ix is None else dict(ix)
        journal["entries"][path] = entry

    write_json(os.path.join(journal_dir, "journal.json"), journal)
    outcome = "degraded" if journal["degraded"] else "captured"
    print(
        json.dumps(
            {
                "outcome": outcome,
                "reason": journal["degradedReason"],
                "captured": len(journal["entries"]),
                "journal": journal_dir,
            }
        )
    )
    return 0


# --------------------------------------------------------------------------
# restore
# --------------------------------------------------------------------------


def quarantine(journal_dir: str, worktree: str, path: str, actions: list) -> bool:
    """Copy a path's current bytes aside before the guard destroys them.

    Nothing the guard removes or overwrites is unrecoverable. This is what makes
    it safe to run against a live repository that other processes are writing
    to: worst case the guard is wrong about who wrote a file, and the answer is
    a move rather than a loss.
    """
    src = os.path.join(worktree, os.fsdecode(encode(path)))
    dest = os.path.join(journal_dir, "quarantine", os.fsdecode(encode(path)))
    try:
        os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
        if os.path.islink(src):
            target = os.readlink(src)
            if os.path.lexists(dest):
                os.remove(dest)
            os.symlink(target, dest)
        else:
            shutil.copy2(src, dest)
        return True
    except OSError as exc:
        actions.append(
            {"path": path, "action": "quarantine-failed", "detail": str(exc)}
        )
        return False


def remove_path(worktree: str, path: str) -> None:
    full = os.path.join(worktree, os.fsdecode(encode(path)))
    try:
        if os.path.islink(full) or os.path.isfile(full):
            os.remove(full)
        elif os.path.isdir(full):
            shutil.rmtree(full)
    except OSError as exc:
        if exc.errno != errno.ENOENT:
            raise GuardError(f"cannot remove {path}: {exc}") from exc


def write_path(worktree: str, path: str, data: bytes, mode: int) -> None:
    full = os.path.join(worktree, os.fsdecode(encode(path)))
    parent = os.path.dirname(full)
    if parent:
        os.makedirs(parent, exist_ok=True)
    if os.path.lexists(full):
        remove_path(worktree, path)
    if mode == SYMLINK:
        os.symlink(os.fsdecode(data), full)
        return
    tmp = full + ".gluerun-restore.tmp"
    with open(tmp, "wb") as stream:
        stream.write(data)
    os.chmod(tmp, 0o755 if mode == 0o100755 else 0o644)
    os.replace(tmp, full)


def apply_index(worktree: str, sets: list[tuple[str, dict]], removes: list[str],
                actions: list) -> None:
    if removes:
        payload = b"".join(encode(p) + b"\0" for p in removes)
        if not git_ok(worktree, "update-index", "--force-remove", "-z", "--stdin",
                      stdin=payload):
            for p in removes:
                actions.append({"path": p, "action": "index-remove-failed"})
    if sets:
        records = []
        for path, entry in sets:
            records.append(
                f"{entry['mode']} {entry['sha']} {entry.get('stage', 0)}\t".encode("ascii")
                + encode(path)
                + b"\0"
            )
        if not git_ok(worktree, "update-index", "-z", "--index-info",
                      stdin=b"".join(records)):
            for path, _ in sets:
                actions.append({"path": path, "action": "index-restore-failed"})


def checkout_head(worktree: str, paths: list[str], actions: list) -> None:
    """Return clean-before paths to HEAD, in both the index and the worktree.

    Pathspecs are written with :(literal) magic because a real path may contain
    glob metacharacters or a leading colon, and --pathspec-file-nul is the only
    input form that survives a path git's default output would have quoted.
    """
    if not paths:
        return
    payload = b"".join(b":(literal)" + encode(p) + b"\0" for p in paths)
    if git_ok(
        worktree,
        "checkout",
        "HEAD",
        "--pathspec-from-file=-",
        "--pathspec-file-nul",
        stdin=payload,
    ):
        return
    for path in paths:
        single = b":(literal)" + encode(path) + b"\0"
        if not git_ok(
            worktree,
            "checkout",
            "HEAD",
            "--pathspec-from-file=-",
            "--pathspec-file-nul",
            stdin=single,
        ):
            actions.append({"path": path, "action": "checkout-failed"})


def cmd_restore(args: argparse.Namespace) -> int:
    journal_dir = os.path.abspath(args.journal)
    journal_file = os.path.join(journal_dir, "journal.json")
    if not os.path.exists(journal_file):
        print(json.dumps({"outcome": "no-journal", "journal": journal_dir}))
        return 0

    journal = read_json(journal_file)
    worktree = journal.get("worktree") or ""
    excludes = journal.get("excludes") or []
    mode = args.mode or "restore"

    result = {
        "schema": SCHEMA,
        "journal": journal_dir,
        "worktree": worktree,
        "mode": mode,
        "outcome": "clean",
        "actions": [],
        "quarantine": os.path.join(journal_dir, "quarantine"),
    }

    if journal.get("degraded"):
        result["outcome"] = "degraded"
        result["reason"] = journal.get("degradedReason") or "capture degraded"
        finish(journal_dir, result, args)
        return 0

    if not os.path.isdir(worktree):
        result["outcome"] = "degraded"
        result["reason"] = "worktree is gone"
        finish(journal_dir, result, args)
        return 0

    try:
        index_now = read_index(worktree)
        status_now = read_status(worktree)
    except GuardError as exc:
        result["outcome"] = "degraded"
        result["reason"] = str(exc)
        finish(journal_dir, result, args)
        return 0

    entries = journal.get("entries") or {}
    tracked_before = set(journal.get("trackedBefore") or [])

    candidates = set(entries)
    candidates.update(p for p in status_now if not is_excluded(p, excludes))
    candidates = {p for p in candidates if not is_excluded(p, excludes)}

    actions: list = result["actions"]
    index_sets: list[tuple[str, dict]] = []
    index_removes: list[str] = []
    checkout_paths: list[str] = []

    for path in sorted(candidates):
        current_ix = index_now.get(path)
        if current_ix is not None and current_ix.get("stage", 0) != 0:
            # An unmerged path is a conflict state the guard has no business
            # rewriting; report it and leave it exactly as it is.
            actions.append({"path": path, "action": "skipped-unmerged"})
            continue
        try:
            current_wt = worktree_state(worktree, path)
        except GuardError as exc:
            actions.append({"path": path, "action": "unreadable", "detail": str(exc)})
            continue

        if path in entries:
            want_wt = entries[path].get("worktree") or {"present": False}
            want_ix = entries[path].get("index")
            wt_differs = not same_worktree_state(current_wt, want_wt)
            ix_differs = not same_index_state(current_ix, want_ix)
            if not wt_differs and not ix_differs:
                continue
            if mode == "report":
                actions.append({"path": path, "action": "would-restore-dirty"})
                continue
            if wt_differs:
                if current_wt.get("present"):
                    quarantine(journal_dir, worktree, path, actions)
                if want_wt.get("present"):
                    write_path(
                        worktree,
                        path,
                        load_blob(journal_dir, want_wt["sha256"]),
                        int(want_wt.get("mode") or 0o100644),
                    )
                else:
                    remove_path(worktree, path)
                actions.append({"path": path, "action": "restored-dirty"})
            if ix_differs:
                if want_ix is None:
                    index_removes.append(path)
                else:
                    index_sets.append((path, want_ix))
                actions.append({"path": path, "action": "restored-index"})
            continue

        # Not journaled: the path was either clean at capture (its pre-run state
        # is HEAD, by definition of clean) or did not exist at all.
        if path not in status_now:
            continue
        if path in tracked_before:
            if mode == "report":
                actions.append({"path": path, "action": "would-revert-to-head"})
                continue
            if current_wt.get("present"):
                quarantine(journal_dir, worktree, path, actions)
            checkout_paths.append(path)
            actions.append({"path": path, "action": "reverted-to-head"})
            continue

        if mode == "report":
            actions.append({"path": path, "action": "would-quarantine-new"})
            continue
        if current_wt.get("present"):
            quarantine(journal_dir, worktree, path, actions)
        remove_path(worktree, path)
        if current_ix is not None:
            index_removes.append(path)
        actions.append({"path": path, "action": "quarantined-new"})

    if mode != "report":
        apply_index(worktree, index_sets, index_removes, actions)
        checkout_head(worktree, checkout_paths, actions)

    if actions:
        result["outcome"] = "reported" if mode == "report" else "restored"
    finish(journal_dir, result, args)
    return 0


def finish(journal_dir: str, result: dict, args: argparse.Namespace) -> None:
    counts: dict[str, int] = {}
    for action in result["actions"]:
        counts[action["action"]] = counts.get(action["action"], 0) + 1
    result["counts"] = counts
    write_json(os.path.join(journal_dir, "result.json"), result)
    print(json.dumps({k: v for k, v in result.items() if k != "actions"}))
    if getattr(args, "consume", False) and result["outcome"] != "degraded":
        # Blobs are the bulk of the journal and are useless once restore has
        # run; the quarantine and the result are the parts an operator needs.
        shutil.rmtree(os.path.join(journal_dir, "blobs"), ignore_errors=True)
        try:
            os.remove(os.path.join(journal_dir, "journal.json"))
        except OSError:
            pass


# --------------------------------------------------------------------------
# sweep
# --------------------------------------------------------------------------


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def cmd_sweep(args: argparse.Namespace) -> int:
    root = os.path.abspath(args.root)
    swept = []
    if os.path.isdir(root):
        for name in sorted(os.listdir(root)):
            journal_dir = os.path.join(root, name)
            journal_file = os.path.join(journal_dir, "journal.json")
            if not os.path.exists(journal_file):
                continue
            try:
                journal = read_json(journal_file)
            except (OSError, ValueError):
                continue
            owner = int(journal.get("ownerPid") or 0)
            if pid_alive(owner) and not args.force:
                continue
            sub = argparse.Namespace(
                journal=journal_dir, mode=args.mode, consume=True, quiet=True
            )
            cmd_restore(sub)
            swept.append(journal_dir)
    print(json.dumps({"outcome": "swept", "journals": len(swept)}))
    return 0


# --------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    cap = sub.add_parser("capture")
    cap.add_argument("--worktree", required=True)
    cap.add_argument("--journal", required=True)
    cap.add_argument("--exclude", action="append", default=[])
    cap.add_argument("--label", default="")
    cap.add_argument("--owner-pid", type=int, default=None)
    cap.add_argument("--max-files", type=int, default=DEFAULT_MAX_FILES)
    cap.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    cap.set_defaults(func=cmd_capture)

    res = sub.add_parser("restore")
    res.add_argument("--journal", required=True)
    res.add_argument("--mode", choices=["restore", "report"], default="restore")
    res.add_argument("--consume", action="store_true")
    res.set_defaults(func=cmd_restore)

    swp = sub.add_parser("sweep")
    swp.add_argument("--root", required=True)
    swp.add_argument("--mode", choices=["restore", "report"], default="restore")
    swp.add_argument("--force", action="store_true")
    swp.set_defaults(func=cmd_sweep)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except GuardError as exc:
        print(json.dumps({"outcome": "error", "reason": str(exc)}), file=sys.stderr)
        return 88


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
