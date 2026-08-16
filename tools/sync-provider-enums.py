#!/usr/bin/env python3
"""Write the provider enums in schemas/ from engine/providers.json.

A provider the engine can dispatch but the result schema rejects fails at write
time -- after the work is done, in the one place the run has no way to report.
Four files carry that enum (two authoritative schemas and their orchestration
mirrors), so adding provider N+1 used to mean four hand edits that nothing but
reviewer attention kept in step.

Edits are surgical: only the enum array inside the ``provider`` property is
rewritten, so the diff a reviewer reads is exactly the list that changed.

    python3 tools/sync-provider-enums.py            # write
    python3 tools/sync-provider-enums.py --check    # exit 1 if anything drifts

``tests/test-provider-spec.sh`` asserts the same equality, so a forgotten run
fails the suite rather than shipping.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))

import provider_spec  # noqa: E402  (path set above)

PROVIDER_ENUM = re.compile(
    r'("provider"\s*:\s*\{(?:[^{}]|\{[^{}]*\})*?"enum"\s*:\s*)\[[^\]]*\]',
    re.S,
)


def rendered(names: list[str]) -> str:
    return "[" + ", ".join(json.dumps(name) for name in names) + "]"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="report drift, write nothing")
    args = parser.parse_args(argv)

    names = provider_spec.names()
    replacement = rendered(names)
    drifted: list[str] = []
    written: list[str] = []
    for path in sorted((ROOT / "schemas").rglob("*.json")):
        text = path.read_text(encoding="utf-8")
        if not PROVIDER_ENUM.search(text):
            continue
        updated = PROVIDER_ENUM.sub(lambda m: m.group(1) + replacement, text)
        if updated == text:
            continue
        rel = path.relative_to(ROOT).as_posix()
        if args.check:
            drifted.append(rel)
            continue
        path.write_text(updated, encoding="utf-8")
        written.append(rel)

    if args.check:
        for rel in drifted:
            print(f"provider enum is out of date: {rel}", file=sys.stderr)
        if drifted:
            print(
                "run: python3 tools/sync-provider-enums.py",
                file=sys.stderr,
            )
            return 1
        print(f"provider enums match the spec: {', '.join(names)}")
        return 0

    for rel in written:
        print(f"updated {rel}")
    if not written:
        print("provider enums already match the spec")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
