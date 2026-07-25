#!/usr/bin/env python3
"""Shared provider-executable resolution.

The python twin of ``gluerun_resolve_codex_bin`` (engine/lib.sh). Bash stays
authoritative for the runtime hot path — codex-run.sh resolves once per provider
invocation, and shelling a python interpreter there would add latency to every
planner/worker/auditor run and make a broken python break all orchestration.
This module exists so the two *diagnostic* consumers — ``gluerun doctor`` and
the console's Providers surface — answer the identical question the same way.
``tests/test-provider-resolver-parity.sh`` pins the two implementations
together; edit one and you must edit the other.

Why this module exists at all: the console daemon never sources lib.sh
(cli/gluerun execs it with only GLUERUN_ENGINE_HOME), so it used to resolve the
provider with a bare ``shutil.which`` over its own PATH. A field run showed the
Providers card reporting an unauthenticated /opt/homebrew/bin/codex while the
orchestration was actually driving a different Codex entirely.

Stdlib only, no engine imports — mirrors engine/capability_policy.py.
"""

from __future__ import annotations

from dataclasses import dataclass
import os
import shutil
from typing import Mapping

# Resolution outcomes. The console needs "explicitly configured but broken" to
# be distinguishable from "nothing on PATH": the first is an operator
# misconfiguration that must never silently fall back to some other binary, the
# second is a plain missing install.
OK = "ok"
NOT_ABSOLUTE = "not-absolute"              # override set, not an absolute path
NOT_EXECUTABLE = "not-executable"          # override set, missing or not +x
NOT_ON_PATH = "not-on-path"                # no override, nothing found
PATH_NOT_EXECUTABLE = "path-not-executable"  # PATH hit, but not +x

# Only codex has a strict override today. Providers absent from this map resolve
# by PATH alone, and a codex override must never leak into their resolution.
OVERRIDE_ENV_KEYS = {"codex": "GLUERUN_CODEX_BIN"}


@dataclass(frozen=True)
class ProviderResolution:
    """One provider's resolved executable plus why it resolved that way."""

    provider: str
    binary: str
    path: str | None
    source: str          # "configured" | "path" | "none"
    outcome: str
    configured: str | None
    override_key: str | None
    message: str
    exit_code: int       # 0 | 2 | 127 — mirrors gluerun_resolve_codex_bin's rc

    @property
    def ok(self) -> bool:
        return self.outcome == OK


def _first_existing_on_path(binary: str, search_path: str) -> str | None:
    """First PATH entry holding a file named ``binary``, executable or not."""
    for entry in search_path.split(os.pathsep):
        if not entry:
            continue
        candidate = os.path.join(entry, binary)
        if os.path.isfile(candidate):
            return candidate
    return None


def resolve_provider_bin(provider: str, binary: str,
                         env: Mapping[str, str]) -> ProviderResolution:
    """Resolve ``binary`` exactly as engine/lib.sh does.

    ``env`` must be the environment the ENGINE would see, not os.environ: config
    ``env{}`` is exported over the process environment by lib.sh, so a console
    reading only its own environment sees a different answer than the runner.
    """
    override_key = OVERRIDE_ENV_KEYS.get(provider)
    configured = (env.get(override_key) or "").strip() if override_key else ""

    if configured:
        if not os.path.isabs(configured):
            return ProviderResolution(
                provider=provider, binary=binary, path=None, source="none",
                outcome=NOT_ABSOLUTE, configured=configured,
                override_key=override_key,
                message=f"{override_key} must be an absolute path: {configured}",
                exit_code=2)
        # An explicitly configured executable that is broken is a hard stop. It
        # is NEVER replaced by another PATH candidate — silently running a
        # different binary than the operator pinned is the whole defect.
        if not (os.path.isfile(configured) and os.access(configured, os.X_OK)):
            return ProviderResolution(
                provider=provider, binary=binary, path=None, source="none",
                outcome=NOT_EXECUTABLE, configured=configured,
                override_key=override_key,
                message=f"{override_key} is not executable: {configured}",
                exit_code=127)
        # Preserved as the operator spelled it: on macOS realpath() would
        # rewrite /var -> /private/var and the path would stop matching what
        # they configured.
        return ProviderResolution(
            provider=provider, binary=binary, path=configured,
            source="configured", outcome=OK, configured=configured,
            override_key=override_key, message="", exit_code=0)

    # `path=""` (not None) is deliberate: shutil.which(None) falls back to
    # os.environ/os.defpath, which would reintroduce exactly the split-brain
    # this module exists to remove. An empty PATH must mean "found nothing".
    search_path = env.get("PATH", "")
    found = shutil.which(binary, path=search_path)
    if not found:
        # Match `command -v` exactly. Verified bash behaviour: it prefers an
        # executable candidate (like shutil.which), but when the ONLY candidate
        # on PATH is non-executable it returns that path anyway. lib.sh then
        # reports "resolved ... is not executable", which is a materially better
        # diagnostic than "not found" — it tells the operator the binary is
        # right there with the wrong mode. shutil.which alone would lose that.
        found = _first_existing_on_path(binary, search_path)
    if not found:
        hint = f" (set {override_key})" if override_key else ""
        return ProviderResolution(
            provider=provider, binary=binary, path=None, source="none",
            outcome=NOT_ON_PATH, configured=None, override_key=override_key,
            message=f"{binary} CLI not found on PATH{hint}", exit_code=127)

    # Match bash's `cd "$(dirname)" && pwd -P` — it resolves symlinks in the
    # DIRECTORY only, leaving the final component alone.
    if not os.path.isabs(found):
        found = os.path.join(os.path.realpath(os.path.dirname(found)),
                             os.path.basename(found))
    if not os.access(found, os.X_OK):
        return ProviderResolution(
            provider=provider, binary=binary, path=None, source="none",
            outcome=PATH_NOT_EXECUTABLE, configured=None,
            override_key=override_key,
            message=f"resolved {binary} CLI is not executable: {found}",
            exit_code=127)
    return ProviderResolution(
        provider=provider, binary=binary, path=found, source="path",
        outcome=OK, configured=None, override_key=override_key,
        message="", exit_code=0)


def resolve_codex_bin(env: Mapping[str, str]) -> ProviderResolution:
    """Convenience wrapper — the parity target for gluerun_resolve_codex_bin."""
    return resolve_provider_bin("codex", "codex", env)
