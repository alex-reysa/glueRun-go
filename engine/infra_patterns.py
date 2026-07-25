"""Shared loader for the gate's infrastructure log signatures.

Two modules classify gate output and they are one character apart in name:
`gate-report.py` is the v0 log-heuristic adapter, `gate_report.py` the v2
normalizer. The hyphenated one cannot be imported by name, so for a long time
the only copy of the infrastructure patterns lived inside it — which meant the
v2 path, the one every current consumer takes, had no infrastructure detection
at all. A gate that could not run reported as a product defect, and the decider
spent the retry budget asking a model to fix code that was never broken.

Both modules import this. The patterns themselves live in
engine/infra-patterns.tsv, next to the file rather than inside it, following
engine/secret-patterns.tsv — a table that two languages have to agree on belongs
in data, not duplicated in code.
"""

from __future__ import annotations

import os
import re
from typing import Iterable

PATTERNS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "infra-patterns.tsv")

# Only "strict" signatures may reach the v2 normalizer: there, an infrastructure
# verdict parks the task unconditionally, so a false positive is fatal rather
# than merely wasteful. See engine/infra-patterns.tsv for the full reasoning.
STRICT = "strict"
ALL = "all"

_CACHE: dict[str, tuple[tuple[str, re.Pattern[str]], ...]] = {}


def load(
    scope: str = ALL, path: str | None = None
) -> tuple[tuple[str, re.Pattern[str]], ...]:
    if path is None and scope in _CACHE:
        return _CACHE[scope]
    source = path or PATTERNS_FILE
    compiled: list[tuple[str, re.Pattern[str]]] = []
    try:
        with open(source, encoding="utf-8") as stream:
            for line in stream:
                line = line.rstrip("\n")
                if not line or line.lstrip().startswith("#"):
                    continue
                fields = line.split("\t")
                if len(fields) < 3:
                    continue
                row_scope, label, expression = (f.strip() for f in fields[:3])
                if not label or not expression:
                    continue
                if scope == STRICT and row_scope != STRICT:
                    continue
                try:
                    compiled.append((label, re.compile(expression, re.I)))
                except re.error:
                    # A malformed row must not take the gate down with it: a
                    # classifier that refuses to load turns every gate result
                    # into a crash, which is strictly worse than one missing
                    # signature.
                    continue
    except OSError:
        compiled = []
    result = tuple(compiled)
    if path is None:
        _CACHE[scope] = result
    return result


def matches(
    text: str,
    patterns: Iterable[tuple[str, re.Pattern[str]]] | None = None,
    scope: str = ALL,
) -> list[str]:
    """Labels whose signature appears in `text`, sorted and deduplicated."""
    active = patterns if patterns is not None else load(scope)
    return sorted({label for label, pattern in active if pattern.search(text)})
