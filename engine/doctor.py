#!/usr/bin/env python3
"""Structured, read-only operator preflight for gluerun.

The only write-like probe is a disposable detached Git worktree that is removed
before the check returns. Model-cache mutation is available only through the
explicit ``--repair-model-cache`` option and always preserves the original as a
timestamped backup.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Iterable

from capability_policy import strict_provider_arg_violation


CHECK_SCHEMA = "gluerun.doctor-report.v1"
REQUIRED_RUNNER_ARGUMENTS = {
    "--worktree",
    "--prompt-file",
    "--level",
    "--run-id",
    "--output-schema",
    "--output-last-message",
    "--no-output-capture",
    "--allow-prefix",
    "--session-meta",
    "--resume-session",
    "--role",
    "--capability-profile",
    "--result-file",
    "--describe-contract",
}
PROVIDERS = {
    "codex": ("codex-run.sh", "codex"),
    "claude": ("claude-run.sh", "claude"),
    "gemini": ("gemini-run.sh", "gemini"),
    "opencode": ("opencode-run.sh", "opencode"),
    "cursor": ("cursor-run.sh", "cursor-agent"),
    "grok": ("grok-run.sh", "grok"),
}
MODEL_ENV = {
    "codex": ("GLUERUN_CODEX_MODEL", "gpt-5.5"),
    "claude": ("GLUERUN_CLAUDE_MODEL", "claude-opus-4-8"),
    "gemini": ("GLUERUN_GEMINI_MODEL", ""),
    "opencode": ("GLUERUN_OPENCODE_MODEL", ""),
    "cursor": ("GLUERUN_CURSOR_MODEL", ""),
    "grok": ("GLUERUN_GROK_MODEL", "grok-build"),
}
MODEL_PATTERNS = {
    "codex": re.compile(r"^(?:gpt-|o[0-9]|codex-)"),
    "claude": re.compile(r"^(?:claude-|sonnet|opus|haiku)"),
    "gemini": re.compile(r"^(?:gemini-|auto$)"),
    "opencode": re.compile(r"^(?:[^/\s]+/[^/\s]+|auto)$"),
    "cursor": re.compile(r"^(?:auto$|gpt-|cursor-|claude-|sonnet|opus|o[0-9])"),
    "grok": re.compile(r"^grok-"),
}
BUILTIN_CAPABILITIES = {
    "filesystem",
    "git",
    "schemas",
    "skills",
    "runner-contract",
    "provider-executable",
}
DEPLOY_KINDS = {"deploy", "deployment", "release", "publish"}


def utc_now() -> str:
    return (
        dt.datetime.now(dt.UTC)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def compact(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def first_line(value: str, limit: int = 512) -> str:
    for line in value.splitlines():
        if line.strip():
            return line.strip()[:limit]
    return ""


def command(
    argv: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    timeout: int = 10,
) -> subprocess.CompletedProcess[str]:
    try:
        process = subprocess.Popen(
            argv,
            cwd=str(cwd) if cwd else None,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as exc:
        return subprocess.CompletedProcess(argv, 127, "", str(exc))
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            process.kill()
        stdout, stderr = process.communicate()
        return subprocess.CompletedProcess(
            argv,
            124,
            stdout or "",
            ((stderr or "") + f"\nprobe timed out after {timeout}s").strip(),
        )


def parse_version(text: str) -> tuple[int, ...] | None:
    match = re.search(r"(?<![0-9])([0-9]+)\.([0-9]+)(?:\.([0-9]+))?", text)
    if not match:
        return None
    return tuple(int(part or 0) for part in match.groups())


def safe_slug(value: str) -> str:
    slug = re.sub(r"[^a-z0-9._-]+", "-", value.lower()).strip("-")
    return slug[:80] or hashlib.sha256(value.encode()).hexdigest()[:12]


class Doctor:
    def __init__(
        self,
        *,
        engine: Path,
        repo: Path | None,
        bash: Path,
        bash_version: str,
        output_json: bool,
        repair_model_cache: bool,
    ) -> None:
        self.engine = engine.resolve()
        self.repo = repo.resolve() if repo else None
        self.bash = bash.resolve()
        self.bash_version = bash_version
        self.output_json = output_json
        self.repair_model_cache = repair_model_cache
        self.checks: list[dict[str, Any]] = []
        self.config: dict[str, Any] = {}
        self.runtime_env = dict(os.environ)
        self.runner: Path | None = None
        self.provider: str | None = None
        self.provider_bin: Path | None = None
        self.provider_version_output = ""
        self.runner_contract_ok = False

    def add(
        self,
        check_id: str,
        status: str,
        message: str,
        *,
        required_for: Iterable[str] = (),
        remediation: str = "",
        dedupe_key: str | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        severity = {
            "pass": "info",
            "skip": "info",
            "warn": "warning",
            "fail": "error",
        }[status]
        self.checks.append(
            {
                "id": check_id,
                "status": status,
                "severity": severity,
                "requiredFor": sorted(set(required_for)),
                "message": message,
                "remediation": remediation,
                "dedupeKey": dedupe_key or check_id,
                **({"details": details} if details else {}),
            }
        )

    def load_config(self) -> None:
        if not self.repo:
            self.add(
                "repo.present",
                "warn",
                "not in a git repo",
                remediation="Run doctor from the repository gluerun will operate.",
            )
            return
        config_path = self.repo / "gluerun.config.json"
        if not config_path.is_file():
            self.add(
                "repo.config",
                "warn",
                "no gluerun.config.json (run: gluerun init)",
                required_for=("configured-runs",),
                remediation="Run gluerun init, then review the generated configuration.",
            )
            return
        try:
            loaded = json.loads(config_path.read_text(encoding="utf-8"))
            if not isinstance(loaded, dict):
                raise ValueError("top level must be an object")
            self.config = loaded
            self.add(
                "repo.config",
                "pass",
                "repo config present",
                required_for=("configured-runs",),
            )
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            self.add(
                "repo.config",
                "fail",
                f"repo config is invalid: {exc}",
                required_for=("all-runs",),
                remediation="Repair gluerun.config.json before starting the engine.",
            )

    def basic_checks(self) -> None:
        bash_major = int(self.bash_version.split(".", 1)[0] or "0")
        if bash_major >= 4 and self.bash.is_file() and os.access(self.bash, os.X_OK):
            self.add(
                "runtime.bash",
                "pass",
                f"bash >= 4 ({self.bash_version}; {self.bash})",
                required_for=("all-runs",),
                details={"path": str(self.bash), "version": self.bash_version},
            )
        else:
            self.add(
                "runtime.bash",
                "fail",
                f"bash >= 4 required (found {self.bash_version}; {self.bash})",
                required_for=("all-runs",),
                remediation=(
                    "Install Bash >= 4 and set GLUERUN_BASH_BIN to its absolute path "
                    "in the process or service environment."
                ),
            )
        self.add(
            "runtime.python",
            "pass",
            f"python3 ({sys.executable})",
            required_for=("all-runs",),
            details={"path": sys.executable, "version": sys.version.split()[0]},
        )
        git_bin = shutil.which("git")
        if git_bin:
            version = command([git_bin, "--version"]).stdout.strip()
            self.add(
                "runtime.git",
                "pass",
                f"git ({version or git_bin})",
                required_for=("all-runs",),
                details={"path": git_bin},
            )
        else:
            self.add(
                "runtime.git",
                "fail",
                "git is not available",
                required_for=("all-runs",),
                remediation="Install Git and make it available on PATH.",
            )
        version = "?"
        try:
            version = (self.engine / "VERSION").read_text(encoding="utf-8").strip()
        except OSError:
            pass
        if (self.engine / "engine/lib.sh").is_file():
            self.add(
                "engine.resolved",
                "pass",
                f"engine resolved ({self.engine}, v{version})",
                required_for=("all-runs",),
                details={"path": str(self.engine), "version": version},
            )
        else:
            self.add(
                "engine.resolved",
                "fail",
                f"engine has no engine/lib.sh: {self.engine}",
                required_for=("all-runs",),
                remediation="Install the pinned engine or correct GLUERUN_ENGINE_HOME.",
            )
        if self.repo:
            self.add(
                "repo.present",
                "pass",
                f"repo: {self.repo}",
                required_for=("all-runs",),
                details={"path": str(self.repo)},
            )

    def effective_environment(self) -> None:
        if not self.repo or not (self.engine / "engine/lib.sh").is_file():
            return
        script = r'''
source "$1/engine/lib.sh" >/dev/null || exit $?
exec "$2" -c 'import json,os; print(json.dumps(dict(os.environ),separators=(",",":")))'
'''
        env = dict(os.environ)
        env["GLUERUN_ROOT"] = str(self.repo)
        env["GLUERUN_ENGINE_HOME"] = str(self.engine)
        result = command(
            [str(self.bash), "-c", script, "_", str(self.engine), sys.executable],
            cwd=self.repo,
            env=env,
        )
        if result.returncode != 0:
            detail = first_line(result.stderr or result.stdout)
            self.add(
                "runtime.config-load",
                "fail",
                f"selected runtime configuration failed to load: {detail}",
                required_for=("all-runs",),
                remediation="Repair the repository or local gluerun configuration.",
            )
            return
        try:
            data = json.loads(result.stdout)
            if not isinstance(data, dict):
                raise ValueError("environment record is not an object")
            self.runtime_env = {str(k): str(v) for k, v in data.items()}
            self.add(
                "runtime.config-load",
                "pass",
                "selected runtime configuration loads",
                required_for=("all-runs",),
            )
        except (json.JSONDecodeError, ValueError) as exc:
            self.add(
                "runtime.config-load",
                "fail",
                f"selected runtime configuration returned invalid data: {exc}",
                required_for=("all-runs",),
                remediation="Inspect output emitted while sourcing engine/lib.sh.",
            )

    def schema_checks(self) -> None:
        schema_dir = self.engine / "schemas"
        try:
            engine_schema = (self.engine / "SCHEMA_VERSION").read_text(
                encoding="utf-8"
            ).strip()
        except OSError:
            engine_schema = ""
        repo_schema = str(self.config.get("schemaVersion", "") or "")
        if engine_schema and repo_schema and engine_schema != repo_schema:
            self.add(
                "schema.version",
                "fail",
                f"schemaVersion mismatch: repo {repo_schema} vs engine {engine_schema}",
                required_for=("all-runs",),
                remediation="Run gluerun migrate.",
            )
        elif engine_schema:
            suffix = repo_schema or "not declared"
            status = "pass" if repo_schema else "warn"
            self.add(
                "schema.version",
                status,
                f"engine schema: {engine_schema}; repo schema: {suffix}",
                required_for=("all-runs",),
                remediation="" if repo_schema else "Declare schemaVersion in gluerun.config.json.",
            )
        parsed: dict[Path, dict[str, Any]] = {}
        errors: list[str] = []

        authoritative_paths = sorted(schema_dir.glob("*.schema.json"))
        authoritative_names = {path.name for path in authoritative_paths}
        ids: dict[str, str] = {}
        for path in authoritative_paths:
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
                if (
                    not isinstance(value, dict)
                    or not isinstance(value.get("$schema"), str)
                    or not value["$schema"]
                    or not isinstance(value.get("$id"), str)
                    or not value["$id"]
                ):
                    raise ValueError("missing object $schema/$id")
                duplicate = ids.get(value["$id"])
                if duplicate:
                    raise ValueError(f"duplicate $id also used by {duplicate}")
                ids[value["$id"]] = path.name
                parsed[path] = value
            except (OSError, json.JSONDecodeError, ValueError) as exc:
                errors.append(f"authoritative/{path.name}: {exc}")
        if not authoritative_paths:
            errors.append("authoritative schema bundle is empty")

        consumer_dirs: list[tuple[str, Path]] = [
            ("engine-consumer", schema_dir / "orchestration")
        ]
        if (
            self.repo
            and repo_schema
            and repo_schema == engine_schema
        ):
            repo_consumer = self.repo / "schemas" / "orchestration"
            try:
                is_engine_consumer = (
                    repo_consumer.resolve()
                    == (schema_dir / "orchestration").resolve()
                )
            except OSError:
                is_engine_consumer = False
            if not is_engine_consumer:
                consumer_dirs.append(("repo-consumer", repo_consumer))

        consumer_counts: dict[str, int] = {}
        consumer_extensions: dict[str, list[str]] = {}
        for label, directory in consumer_dirs:
            if not directory.is_dir():
                errors.append(f"{label}: schema directory missing ({directory})")
                consumer_counts[label] = 0
                consumer_extensions[label] = []
                continue
            consumer_paths = sorted(directory.glob("*.schema.json"))
            consumer_names = {path.name for path in consumer_paths}
            consumer_counts[label] = len(consumer_paths)
            missing_names = sorted(authoritative_names - consumer_names)
            unexpected_names = sorted(consumer_names - authoritative_names)
            allowed_extensions = unexpected_names if label == "repo-consumer" else []
            consumer_extensions[label] = allowed_extensions
            if missing_names:
                errors.append(
                    f"{label}: missing schema copies: {', '.join(missing_names)}"
                )
            if unexpected_names and label != "repo-consumer":
                errors.append(
                    f"{label}: unexpected schema copies: {', '.join(unexpected_names)}"
                )
            for path in consumer_paths:
                try:
                    value = json.loads(path.read_text(encoding="utf-8"))
                    if (
                        not isinstance(value, dict)
                        or not isinstance(value.get("$schema"), str)
                        or not value["$schema"]
                        or not isinstance(value.get("$id"), str)
                        or not value["$id"]
                    ):
                        raise ValueError("missing object $schema/$id")
                except (OSError, json.JSONDecodeError, ValueError) as exc:
                    errors.append(f"{label}/{path.name}: {exc}")
                    continue
                authoritative = schema_dir / path.name
                if authoritative.is_file():
                    try:
                        if authoritative.read_bytes() != path.read_bytes():
                            errors.append(
                                f"{label}/{path.name}: consumer copy differs "
                                "from authoritative schema"
                            )
                    except OSError as exc:
                        errors.append(f"{label}/{path.name}: {exc}")
        if errors:
            self.add(
                "schema.bundle",
                "fail",
                f"schemas missing, invalid, or drifted: {'; '.join(errors[:8])}",
                required_for=("all-runs",),
                remediation="Restore the engine schema bundle and regenerate consumer mirrors.",
                details={
                    "authoritativeSchemaCount": len(authoritative_paths),
                    "consumerSchemaCounts": consumer_counts,
                    "consumerExtensions": consumer_extensions,
                    "errors": errors[:100],
                },
            )
        else:
            extension_count = sum(
                len(names) for names in consumer_extensions.values()
            )
            self.add(
                "schema.bundle",
                "pass",
                (
                    f"all {len(parsed)} authoritative schemas are present and "
                    f"byte-identical in {len(consumer_dirs)} consumer bundle(s); "
                    f"{extension_count} consumer-only extension(s) validated"
                ),
                required_for=("all-runs",),
                details={
                    "authoritativeSchemaCount": len(parsed),
                    "consumerSchemaCounts": consumer_counts,
                    "consumerExtensions": consumer_extensions,
                },
            )
        runner_schema = parsed.get(schema_dir / "runner-result.v0.schema.json")
        fixture = {
            "schema": "gluerun.orchestration.runner-result.v0",
            "contractVersion": 1,
            "provider": "codex",
            "runId": "doctor-fixture",
            "role": "doctor",
            "capabilityProfile": "doctor-core",
            "exitCode": 0,
            "outcome": "succeeded",
            "failureClass": "none",
            "providerErrorRef": None,
            "outputRef": None,
            "recordedAt": "2026-07-24T00:00:00Z",
        }
        fixture_errors = self.validate_simple_schema(runner_schema, fixture)
        if fixture_errors:
            self.add(
                "schema.fixture.runner-result",
                "fail",
                f"runner-result schema fixture failed: {'; '.join(fixture_errors)}",
                required_for=("provider-runs",),
                remediation="Repair runner-result.v0 schema/fixture compatibility.",
            )
        else:
            self.add(
                "schema.fixture.runner-result",
                "pass",
                "runner-result schema fixture validates",
                required_for=("provider-runs",),
            )

    @staticmethod
    def validate_simple_schema(
        schema: dict[str, Any] | None, value: dict[str, Any]
    ) -> list[str]:
        if not schema:
            return ["schema missing"]
        errors: list[str] = []
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                errors.append(f"missing {key}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in properties:
                    errors.append(f"unexpected {key}")
        for key, spec in properties.items():
            if key not in value or not isinstance(spec, dict):
                continue
            item = value[key]
            if "const" in spec and item != spec["const"]:
                errors.append(f"{key} const mismatch")
            if "enum" in spec and item not in spec["enum"]:
                errors.append(f"{key} enum mismatch")
            expected = spec.get("type")
            expected_types = expected if isinstance(expected, list) else [expected]
            type_ok = False
            for candidate in expected_types:
                type_ok = type_ok or {
                    "string": isinstance(item, str),
                    "integer": isinstance(item, int) and not isinstance(item, bool),
                    "boolean": isinstance(item, bool),
                    "null": item is None,
                    "object": isinstance(item, dict),
                    "array": isinstance(item, list),
                    None: True,
                }.get(candidate, True)
            if not type_ok:
                errors.append(f"{key} type mismatch")
        return errors

    def repo_hygiene_checks(self) -> None:
        codex_dir = Path(
            self.runtime_env.get(
                "CODEX_HOME", str(Path(self.runtime_env.get("HOME", str(Path.home()))) / ".codex")
            )
        )
        hooks = codex_dir / "hooks.json"
        if hooks.is_file():
            try:
                json.loads(hooks.read_text(encoding="utf-8"))
                self.add(
                    "codex.hooks",
                    "pass",
                    "~/.codex/hooks.json parses",
                    required_for=("codex-runs",),
                )
            except (OSError, json.JSONDecodeError) as exc:
                self.add(
                    "codex.hooks",
                    "fail",
                    f"~/.codex/hooks.json is not valid JSON: {exc}",
                    required_for=("codex-runs",),
                    remediation="Repair the file or replace it with an empty JSON object.",
                )
        else:
            self.add(
                "codex.hooks",
                "skip",
                "~/.codex/hooks.json is absent",
                required_for=("codex-runs",),
            )
        if not self.repo:
            return
        hits: list[str] = []
        for base in (
            self.repo / "docs/orchestration/prompts",
            self.repo / "schemas",
        ):
            if not base.is_dir():
                continue
            for path in base.rglob("*"):
                if path.suffix not in {".json", ".md"} or not path.is_file():
                    continue
                try:
                    if '"pmgo.' in path.read_text(encoding="utf-8", errors="replace"):
                        hits.append(str(path.relative_to(self.repo)))
                except OSError:
                    continue
                if len(hits) >= 5:
                    break
        if hits:
            self.add(
                "schema.legacy-ids",
                "fail",
                f"legacy pmgo.* schema ids found: {', '.join(hits)}",
                required_for=("all-runs",),
                remediation="Run migrations/v0-to-v1.sh or gluerun migrate.",
            )
        else:
            self.add(
                "schema.legacy-ids",
                "pass",
                "no legacy pmgo.* schema ids in prompts/schemas",
                required_for=("all-runs",),
            )
        for name in ("autonomate.pid", "console.pid"):
            path = self.repo / ".gluerun-state" / name
            if not path.is_file():
                continue
            try:
                pid = int(path.read_text(encoding="utf-8").strip())
                os.kill(pid, 0)
            except (OSError, ValueError):
                self.add(
                    f"state.pidfile.{safe_slug(name)}",
                    "warn",
                    f"stale pidfile {path}",
                    remediation="Restart the process or remove this stale pidfile.",
                    dedupe_key=f"pidfile:{path}",
                )

    def resolve_runner(self) -> None:
        raw = self.runtime_env.get(
            "GLUERUN_RUNNER", str(self.engine / "engine/codex-run.sh")
        )
        runner = Path(raw)
        if not runner.is_absolute() and self.repo:
            runner = self.repo / runner
        self.runner = runner.resolve()
        for provider, (runner_name, _) in PROVIDERS.items():
            if self.runner.name == runner_name:
                self.provider = provider
                break
        if self.runner.is_file() and os.access(self.runner, os.X_OK):
            self.add(
                "runner.selected",
                "pass",
                f"selected runner: {self.runner}",
                required_for=("provider-runs",),
                details={"path": str(self.runner), "provider": self.provider or "custom"},
            )
        else:
            self.add(
                "runner.selected",
                "fail",
                f"selected runner is not executable: {self.runner}",
                required_for=("provider-runs",),
                remediation="Select an executable runner in gluerun.config.json.",
            )

    def check_runner_contract(self) -> None:
        if not self.runner or not self.runner.is_file():
            return
        result = command(
            [str(self.runner), "--describe-contract"],
            cwd=self.repo,
            env=self.runtime_env,
        )
        if result.returncode != 0:
            detail = first_line(result.stderr or result.stdout)
            self.add(
                "runner.contract-v1",
                "fail",
                f"selected runner contract probe failed (exit {result.returncode}): {detail}",
                required_for=("provider-runs",),
                remediation=(
                    "Upgrade the runner to contract v1. Legacy custom runners cannot "
                    "start strict-profile or structured-error runs."
                ),
            )
            return
        try:
            contract = json.loads(result.stdout)
            arguments = set(contract.get("arguments", []))
            missing = sorted(REQUIRED_RUNNER_ARGUMENTS - arguments)
            errors = []
            if contract.get("schema") != "gluerun.runner-contract.v1":
                errors.append("wrong schema")
            if contract.get("version") != 1:
                errors.append("wrong version")
            if missing:
                errors.append("missing " + ",".join(missing))
            if "--stage-dir" in arguments:
                errors.append("forbidden orchestration argument --stage-dir")
            if (
                contract.get("structuredResult")
                != "gluerun.orchestration.runner-result.v0"
            ):
                errors.append("wrong structured result")
            if (
                contract.get("structuredProviderError")
                != "gluerun.orchestration.provider-error.v0"
            ):
                errors.append("wrong provider error")
            if errors:
                raise ValueError("; ".join(errors))
            self.runner_contract_ok = True
            self.add(
                "runner.contract-v1",
                "pass",
                "selected runner implements contract v1",
                required_for=("provider-runs",),
                details={
                    "provider": contract.get("provider"),
                    "arguments": sorted(arguments),
                },
            )
        except (json.JSONDecodeError, ValueError) as exc:
            self.add(
                "runner.contract-v1",
                "fail",
                f"selected runner returned an invalid contract: {exc}",
                required_for=("provider-runs",),
                remediation="Upgrade or repair the selected provider runner.",
            )

    def resolve_provider_executable(self) -> None:
        if not self.provider:
            self.add(
                "provider.executable",
                "skip",
                "custom runner owns provider executable resolution",
                required_for=("custom-runner",),
            )
            return
        command_name = PROVIDERS[self.provider][1]
        configured = (
            self.runtime_env.get("GLUERUN_CODEX_BIN", "")
            if self.provider == "codex"
            else ""
        )
        if configured:
            path = Path(configured)
            if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
                self.add(
                    "provider.executable",
                    "fail",
                    f"selected Codex executable could not be resolved: {configured}",
                    required_for=("selected-provider",),
                    remediation=(
                        "Set GLUERUN_CODEX_BIN to an absolute executable path. "
                        "An explicit broken path never falls back to PATH."
                    ),
                )
                return
            # Preserve the operator-selected spelling (notably macOS /var vs
            # /private/var) so diagnostics name the exact configured path.
            resolved = str(path)
        else:
            resolved = shutil.which(command_name, path=self.runtime_env.get("PATH"))
        if not resolved:
            self.add(
                "provider.executable",
                "fail",
                f"selected {self.provider} executable is not on PATH",
                required_for=("selected-provider",),
                remediation=f"Install {command_name} or select a different runner.",
            )
            return
        self.provider_bin = Path(resolved)
        label = "Codex" if self.provider == "codex" else self.provider
        self.add(
            "provider.executable",
            "pass",
            f"selected {label} executable: {self.provider_bin}",
            required_for=("selected-provider",),
            details={"provider": self.provider, "path": str(self.provider_bin)},
        )
        result = command(
            [str(self.provider_bin), "--version"],
            cwd=self.repo,
            env=self.runtime_env,
        )
        combined = (result.stdout or "") + (result.stderr or "")
        if result.returncode == 0:
            self.provider_version_output = combined
            shown = first_line(combined) or "version probe passed"
            self.add(
                "provider.spawn",
                "pass",
                f"selected {label} spawn: {shown}",
                required_for=("selected-provider",),
                details={"version": shown},
            )
        else:
            detail = first_line(combined)
            self.add(
                "provider.spawn",
                "fail",
                f"selected {label} spawn probe failed (exit {result.returncode}): {detail}",
                required_for=("selected-provider",),
                remediation="Repair the exact selected executable before starting the engine.",
            )

    def provider_auth(self) -> None:
        if not self.provider or not self.provider_bin:
            return
        label = "Codex" if self.provider == "codex" else self.provider
        argv: list[str] | None = None
        if self.provider == "codex":
            argv = [str(self.provider_bin), "login", "status"]
        elif self.provider == "claude":
            argv = [str(self.provider_bin), "auth", "status"]
        elif self.provider == "opencode":
            argv = [str(self.provider_bin), "auth", "list"]
        if argv:
            result = command(argv, cwd=self.repo, env=self.runtime_env)
            combined = (result.stdout or "") + (result.stderr or "")
            if result.returncode == 0:
                self.add(
                    "provider.authentication",
                    "pass",
                    f"selected {label} authentication",
                    required_for=("selected-provider",),
                )
            else:
                self.add(
                    "provider.authentication",
                    "fail",
                    (
                        f"selected {label} authentication probe failed "
                        f"(exit {result.returncode}): {first_line(combined)}"
                    ),
                    required_for=("selected-provider",),
                    remediation=f"Authenticate the exact selected {label} executable.",
                )
            return
        home = Path(self.runtime_env.get("HOME", str(Path.home())))
        authenticated = False
        hint = ""
        if self.provider == "gemini":
            authenticated = bool(
                self.runtime_env.get("GEMINI_API_KEY")
                or self.runtime_env.get("GOOGLE_API_KEY")
                or (home / ".gemini/oauth_creds.json").is_file()
            )
            hint = "set GEMINI_API_KEY/GOOGLE_API_KEY or sign in with Gemini"
        elif self.provider == "cursor":
            authenticated = bool(
                self.runtime_env.get("CURSOR_API_KEY")
                or (home / ".cursor/cli-config.json").is_file()
            )
            hint = "set CURSOR_API_KEY or run cursor-agent login"
        elif self.provider == "grok":
            authenticated = True
        self.add(
            "provider.authentication",
            "pass" if authenticated else "fail",
            (
                f"selected {label} authentication"
                if authenticated
                else f"selected {label} authentication is not configured"
            ),
            required_for=("selected-provider",),
            remediation="" if authenticated else hint,
        )

    def model_checks(self) -> None:
        for provider, (env_name, default) in MODEL_ENV.items():
            model = self.runtime_env.get(env_name, default)
            if not model:
                continue
            valid = bool(MODEL_PATTERNS[provider].search(model))
            selected = provider == self.provider
            status = "pass" if valid else ("fail" if selected else "warn")
            if valid:
                message = f"{provider} model: {model}"
            else:
                message = f"{env_name} '{model}' has an unrecognized prefix (typo?)"
            self.add(
                f"model.selection.{provider}",
                status,
                message,
                required_for=("selected-provider",) if selected else (),
                remediation=(
                    "" if valid else f"Set {env_name} to a model ID accepted by {provider}."
                ),
            )
        if self.provider != "codex":
            self.add(
                "model.availability",
                "skip",
                "selected provider exposes no offline model inventory",
                required_for=("selected-provider",),
                remediation="Confirm the configured model with the provider before a large run.",
            )
            return
        env_name, default = MODEL_ENV["codex"]
        wanted = self.runtime_env.get(env_name, default)
        cache = self.codex_cache_path()
        try:
            data = json.loads(cache.read_text(encoding="utf-8"))
            slugs = {
                str(item.get("slug"))
                for item in data.get("models", [])
                if isinstance(item, dict) and item.get("slug")
            }
            if wanted in slugs:
                self.add(
                    "model.availability",
                    "pass",
                    f"configured Codex model is present in the local inventory: {wanted}",
                    required_for=("selected-provider",),
                )
            else:
                self.add(
                    "model.availability",
                    "fail",
                    f"configured Codex model is absent from the local inventory: {wanted}",
                    required_for=("selected-provider",),
                    remediation="Choose a model listed by the selected Codex installation.",
                )
        except FileNotFoundError:
            self.add(
                "model.availability",
                "warn",
                f"Codex model availability cannot be verified without a local inventory: {wanted}",
                required_for=("selected-provider",),
                remediation="Run the selected Codex CLI once to refresh its model inventory.",
            )
        except (OSError, json.JSONDecodeError) as exc:
            self.add(
                "model.availability",
                "skip",
                f"Codex model inventory is unreadable: {exc}",
                required_for=("selected-provider",),
                remediation="Run gluerun doctor --repair-model-cache to preserve and refresh it.",
                dedupe_key="codex:model-cache",
            )

    def codex_cache_path(self) -> Path:
        base = self.runtime_env.get("CODEX_HOME")
        if base:
            return Path(base) / "models_cache.json"
        return Path(self.runtime_env.get("HOME", str(Path.home()))) / ".codex/models_cache.json"

    def maybe_repair_model_cache(self) -> None:
        if not self.repair_model_cache:
            return
        cache = self.codex_cache_path()
        if not cache.is_file():
            self.add(
                "model-cache.repair",
                "skip",
                f"model cache is absent; nothing to back up: {cache}",
                remediation="Run Codex to regenerate its model inventory.",
            )
            return
        try:
            digest = hashlib.sha256(cache.read_bytes()).hexdigest()
            stamp = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
            backup = cache.with_name(
                f"{cache.name}.bak-{stamp}-{digest[:12]}"
            )
            if backup.exists():
                raise FileExistsError(f"backup already exists: {backup}")
            os.replace(cache, backup)
            self.add(
                "model-cache.repair",
                "pass",
                f"model cache preserved as {backup}; Codex will regenerate it",
                remediation="Run the selected Codex CLI once to regenerate the cache.",
                details={"backup": str(backup), "sha256": digest},
            )
        except OSError as exc:
            self.add(
                "model-cache.repair",
                "fail",
                f"model cache backup-and-repair failed: {exc}",
                remediation="Check file ownership and free space, then retry explicitly.",
            )

    def model_cache_compatibility(self) -> None:
        if self.provider != "codex":
            self.add(
                "model-cache.compatibility",
                "skip",
                "Codex model cache is not used by the selected provider",
                required_for=("codex-runs",),
            )
            return
        cache = self.codex_cache_path()
        if not cache.is_file():
            self.add(
                "model-cache.compatibility",
                "skip",
                "Codex model cache is absent",
                required_for=("codex-runs",),
                remediation="Run Codex once to populate its model inventory.",
            )
            return
        try:
            data = json.loads(cache.read_text(encoding="utf-8"))
            if not isinstance(data, dict) or not isinstance(data.get("models"), list):
                raise ValueError("expected an object with a models array")
            cache_version_text = str(data.get("client_version", ""))
            cache_version = parse_version(cache_version_text)
            cli_version = parse_version(self.provider_version_output)
            incompatible_fields = sorted(
                {
                    "supports_reasoning_summaries"
                    for item in data["models"]
                    if isinstance(item, dict)
                    and "supports_reasoning_summaries" in item
                }
            )
            newer = bool(cache_version and cli_version and cache_version > cli_version)
            if newer or incompatible_fields:
                reasons = []
                if newer:
                    reasons.append(
                        f"cache client {cache_version_text} is newer than selected CLI "
                        f"{'.'.join(map(str, cli_version or ())) or '?'}"
                    )
                if incompatible_fields:
                    reasons.append("unsupported fields: " + ", ".join(incompatible_fields))
                self.add(
                    "model-cache.compatibility",
                    "warn",
                    "Codex model cache may be incompatible: " + "; ".join(reasons),
                    required_for=("codex-runs",),
                    remediation=(
                        "Upgrade the selected Codex CLI or run "
                        "gluerun doctor --repair-model-cache. Repair always keeps a backup."
                    ),
                    dedupe_key="codex:model-cache",
                    details={
                        "cachePath": str(cache),
                        "cacheClientVersion": cache_version_text or None,
                        "selectedCliVersion": (
                            ".".join(map(str, cli_version)) if cli_version else None
                        ),
                    },
                )
            else:
                self.add(
                    "model-cache.compatibility",
                    "pass",
                    "Codex model cache is compatible with the selected CLI",
                    required_for=("codex-runs",),
                )
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            self.add(
                "model-cache.compatibility",
                "warn",
                f"Codex model cache is invalid or unreadable: {exc}",
                required_for=("codex-runs",),
                remediation=(
                    "Run gluerun doctor --repair-model-cache. The original is backed up "
                    "before Codex regenerates it."
                ),
                dedupe_key="codex:model-cache",
            )

    def disposable_worktree(self) -> None:
        if not self.repo:
            return
        probe_parent = Path(tempfile.mkdtemp(prefix="gluerun-doctor-worktree-"))
        probe = probe_parent / "checkout"
        result = command(
            ["git", "-C", str(self.repo), "worktree", "add", "--detach", str(probe), "HEAD"],
            timeout=20,
        )
        cleanup_error = ""
        expected = command(["git", "-C", str(self.repo), "rev-parse", "HEAD"]).stdout.strip()
        actual = ""
        if result.returncode == 0:
            actual = command(["git", "-C", str(probe), "rev-parse", "HEAD"]).stdout.strip()
            cleanup = command(
                ["git", "-C", str(self.repo), "worktree", "remove", "--force", str(probe)],
                timeout=20,
            )
            if cleanup.returncode != 0:
                cleanup_error = first_line(cleanup.stderr or cleanup.stdout)
        shutil.rmtree(probe_parent, ignore_errors=True)
        if result.returncode == 0 and actual == expected and not cleanup_error:
            self.add(
                "git.disposable-worktree",
                "pass",
                "disposable worktree creation and cleanup succeeded",
                required_for=("worker-runs", "audit-runs"),
                details={"head": expected},
            )
        else:
            detail = cleanup_error or first_line(result.stderr or result.stdout)
            self.add(
                "git.disposable-worktree",
                "fail",
                f"disposable worktree probe failed: {detail or 'HEAD mismatch'}",
                required_for=("worker-runs", "audit-runs"),
                remediation="Repair Git worktree metadata and verify the repository has a HEAD commit.",
            )

    def mcp_names(self) -> set[str]:
        names: set[str] = set()
        if self.repo:
            path = self.repo / ".mcp.json"
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                servers = data.get("mcpServers", {})
                if isinstance(servers, dict):
                    names.update(map(str, servers))
            except (OSError, json.JSONDecodeError):
                pass
        home = Path(self.runtime_env.get("HOME", str(Path.home())))
        try:
            data = json.loads((home / ".claude.json").read_text(encoding="utf-8"))
            servers = data.get("mcpServers", {})
            if isinstance(servers, dict):
                names.update(map(str, servers))
        except (OSError, json.JSONDecodeError):
            pass
        try:
            text = (home / ".codex/config.toml").read_text(encoding="utf-8")
            names.update(
                re.findall(r"^\[mcp_servers\.([^\]]+)\]", text, flags=re.MULTILINE)
            )
        except OSError:
            pass
        return names

    def plugin_names(self) -> set[str]:
        names: set[str] = set()
        roots = [
            self.engine / "plugin",
            Path(self.runtime_env.get("HOME", str(Path.home()))) / ".codex/plugins",
        ]
        for root in roots:
            try:
                names.update(path.name for path in root.iterdir() if path.is_dir())
            except OSError:
                pass
        return names

    def capability_profiles(self) -> None:
        profiles = self.config.get("capabilityProfiles")
        role_profiles = self.config.get("roleProfiles")
        registry = self.config.get("capabilities", {})
        if profiles is None and role_profiles is None:
            self.add(
                "capability.profiles",
                "pass",
                (
                    "capability profiles: built-in local-only defaults "
                    "(external MCP/plugins are lazy and disabled)"
                ),
                required_for=("provider-runs",),
                details={
                    "startup": "lazy",
                    "required": ["filesystem", "git", "schemas", "runner-contract"],
                    "optional": [],
                },
            )
            return
        shape_errors: list[str] = []
        if not isinstance(profiles, dict) or not profiles:
            shape_errors.append("capabilityProfiles must be a non-empty object")
            profiles = {}
        if not isinstance(role_profiles, dict) or not role_profiles:
            shape_errors.append("roleProfiles must be a non-empty object")
            role_profiles = {}
        if not isinstance(registry, dict):
            shape_errors.append("capabilities must be an object")
            registry = {}

        schema_match = re.fullmatch(
            r"v([0-9]+)", str(self.config.get("schemaVersion", ""))
        )
        strict_default = bool(
            schema_match and int(schema_match.group(1)) >= 2
        )
        provider_keys = set(PROVIDERS) | {"default"}
        parsed_profiles: dict[str, dict[str, Any]] = {}

        def valid_argv(value: Any, label: str) -> list[str] | None:
            if not isinstance(value, list) or len(value) > 64:
                shape_errors.append(
                    f"{label} must be an argv array with at most 64 entries"
                )
                return None
            for argument in value:
                if (
                    not isinstance(argument, str)
                    or not argument
                    or len(argument) > 4096
                    or argument != argument.strip()
                    or any(ord(char) < 32 or ord(char) == 127 for char in argument)
                ):
                    shape_errors.append(
                        f"{label} entries must be bounded, non-empty strings "
                        "without control or edge whitespace"
                    )
                    return None
            return value

        def provider_argv_map(value: Any, label: str) -> dict[str, list[str]]:
            if isinstance(value, list):
                parsed = valid_argv(value, label)
                return {"default": parsed} if parsed is not None else {}
            if not isinstance(value, dict):
                shape_errors.append(
                    f"{label} must be an argv array or provider-to-argv object"
                )
                return {}
            unknown = sorted(set(value) - provider_keys)
            if unknown:
                shape_errors.append(
                    f"{label} has unsupported providers: "
                    f"{', '.join(map(str, unknown))}"
                )
            validated: dict[str, list[str]] = {}
            for provider_name, argv in value.items():
                if provider_name not in provider_keys:
                    continue
                parsed = valid_argv(argv, f"{label}.{provider_name}")
                if parsed is not None:
                    validated[provider_name] = parsed
            return validated

        def selected_argv(
            values: dict[str, list[str]], provider_name: str | None
        ) -> list[str]:
            if not provider_name:
                return []
            return list(values.get(provider_name, values.get("default", [])))

        for profile_name, profile in profiles.items():
            if (
                not isinstance(profile_name, str)
                or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", profile_name)
                is None
            ):
                shape_errors.append(
                    "capabilityProfiles keys must be safe non-empty profile names"
                )
                continue
            if not isinstance(profile, dict):
                shape_errors.append(f"profile {profile_name} must be an object")
                continue
            if profile.get("startup", "lazy") != "lazy":
                shape_errors.append(f"profile {profile_name} startup must be lazy")
            strict = profile.get("strict", strict_default)
            if not isinstance(strict, bool):
                shape_errors.append(f"profile {profile_name}.strict must be boolean")
                strict = strict_default
            required = profile.get("required", [])
            optional = profile.get("optional", [])
            if not isinstance(required, list) or not all(
                isinstance(item, str) and item for item in required
            ):
                shape_errors.append(f"profile {profile_name}.required must be strings")
                required = []
            if not isinstance(optional, list) or not all(
                isinstance(item, str) and item for item in optional
            ):
                shape_errors.append(f"profile {profile_name}.optional must be strings")
                optional = []
            required_values = list(dict.fromkeys(required))
            optional_values = [
                item for item in dict.fromkeys(optional) if item not in required_values
            ]
            provider_args_map = provider_argv_map(
                profile.get("providerArgs", []),
                f"profile {profile_name}.providerArgs",
            )
            capability_args_raw = profile.get("capabilityArgs", {})
            capability_args_maps: dict[str, dict[str, list[str]]] = {}
            if not isinstance(capability_args_raw, dict):
                shape_errors.append(
                    f"profile {profile_name}.capabilityArgs must map capability "
                    "IDs to provider argv"
                )
                capability_args_raw = {}
            declared_capabilities = set(required_values) | set(optional_values)
            undeclared = sorted(set(capability_args_raw) - declared_capabilities)
            if undeclared:
                shape_errors.append(
                    f"profile {profile_name}.capabilityArgs contains undeclared "
                    f"capabilities: {', '.join(map(str, undeclared))}"
                )
            for capability, argv_config in capability_args_raw.items():
                if capability not in declared_capabilities:
                    continue
                capability_args_maps[capability] = provider_argv_map(
                    argv_config,
                    f"profile {profile_name}.capabilityArgs.{capability}",
                )

            if strict:
                for provider_name in ("codex", "claude", "gemini", "opencode"):
                    combined = selected_argv(provider_args_map, provider_name)
                    for capability in required_values + optional_values:
                        for argument in selected_argv(
                            capability_args_maps.get(capability, {}), provider_name
                        ):
                            if argument not in combined:
                                combined.append(argument)
                    violation = strict_provider_arg_violation(
                        provider_name, combined
                    )
                    if violation:
                        shape_errors.append(
                            f"profile {profile_name}: {violation}"
                        )
            selected_capability_args = {
                capability: selected_argv(values, self.provider)
                for capability, values in capability_args_maps.items()
            }
            parsed_profiles[profile_name] = {
                "strict": strict,
                "required": required_values,
                "optional": optional_values,
                "providerArgs": selected_argv(provider_args_map, self.provider),
                "capabilityArgs": selected_capability_args,
            }

        active: dict[str, dict[str, set[str]]] = {}
        strict_unactivated_optional: dict[str, set[str]] = {}
        active_profiles: set[str] = set()
        for role, profile_name in role_profiles.items():
            if (
                not isinstance(role, str)
                or not role
                or not isinstance(profile_name, str)
                or not profile_name
            ):
                shape_errors.append("roleProfiles entries must map non-empty strings")
                continue
            profile = parsed_profiles.get(profile_name)
            if profile is None:
                shape_errors.append(f"role {role} references missing profile {profile_name}")
                continue
            active_profiles.add(profile_name)
            required = profile["required"]
            optional = profile["optional"]
            for level, values in (("required", required), ("optional", optional)):
                for capability in values:
                    target = active.setdefault(
                        capability, {"required": set(), "optional": set()}
                    )
                    target[level].add(role)
                    descriptor = registry.get(capability)
                    activation_required = capability == "skills" or (
                        capability.startswith(("mcp:", "plugin:"))
                        or (
                            isinstance(descriptor, dict)
                            and descriptor.get("type") in {"mcp", "plugin"}
                        )
                    )
                    if (
                        level == "optional"
                        and profile["strict"]
                        and activation_required
                        and not profile["capabilityArgs"].get(capability)
                    ):
                        strict_unactivated_optional.setdefault(capability, set()).add(
                            role
                        )
        if self.provider in {"cursor", "grok"}:
            for profile_name in sorted(active_profiles):
                profile = parsed_profiles[profile_name]
                if profile["strict"] and not profile["providerArgs"]:
                    shape_errors.append(
                        f"profile {profile_name} is strict, but {self.provider} has "
                        "no proven built-in isolation mode; configure a validated "
                        f"providerArgs.{self.provider} argv array or set strict:false"
                    )
        for profile_name in sorted(active_profiles):
            profile = parsed_profiles[profile_name]
            if not profile["strict"]:
                continue
            for capability in profile["required"]:
                descriptor = registry.get(capability)
                external = capability == "skills" or (
                    capability.startswith(("mcp:", "plugin:"))
                    or (
                        isinstance(descriptor, dict)
                        and descriptor.get("type") in {"mcp", "plugin"}
                    )
                )
                if external and not profile["capabilityArgs"].get(capability):
                    shape_errors.append(
                        f"profile {profile_name} requires external capability "
                        f"{capability}, but strict isolation requires "
                        f"capabilityArgs.{capability}"
                    )
        if shape_errors:
            self.add(
                "capability.profiles",
                "fail",
                "capability profile configuration is invalid: "
                + "; ".join(shape_errors[:8]),
                required_for=("provider-runs",),
                remediation=(
                    "Define lazy capabilityProfiles and map each runner role through "
                    "roleProfiles."
                ),
            )
            return
        self.add(
            "capability.profiles",
            "pass",
            f"capability profiles valid ({len(profiles)} profiles, {len(role_profiles)} roles)",
            required_for=tuple(map(str, role_profiles)),
            details={
                "startup": "lazy",
                "strictDefault": strict_default,
                "strictProfiles": sorted(
                    name
                    for name, profile in parsed_profiles.items()
                    if profile["strict"]
                ),
                "activatedCapabilities": sorted(
                    {
                        capability
                        for profile in parsed_profiles.values()
                        for capability, argv in profile["capabilityArgs"].items()
                        if argv
                    }
                ),
            },
        )
        mcp = self.mcp_names()
        plugins = self.plugin_names()
        for capability, consumers in sorted(active.items()):
            required_roles = consumers["required"]
            optional_roles = consumers["optional"] - required_roles
            unactivated_roles = strict_unactivated_optional.get(capability, set())
            availability_optional_roles = optional_roles - unactivated_roles
            required = bool(required_roles)
            available, reason = self.capability_available(
                capability, registry, mcp, plugins
            )
            if available:
                status = "pass"
                roles = required_roles | optional_roles
                message = f"capability available: {capability}"
            elif required:
                status = "fail"
                roles = required_roles
                message = f"required capability unavailable: {capability} ({reason})"
            elif availability_optional_roles:
                status = "warn"
                roles = availability_optional_roles
                message = f"optional capability unavailable: {capability} ({reason})"
            else:
                continue
            self.add(
                f"capability.{safe_slug(capability)}",
                status,
                message,
                required_for=roles,
                remediation=(
                    ""
                    if available
                    else "Install/configure the capability or remove it from the profile."
                ),
                dedupe_key=f"capability:{capability}",
            )
        for capability, roles in sorted(strict_unactivated_optional.items()):
            self.add(
                f"capability.activation.{safe_slug(capability)}",
                "warn",
                (
                    f"optional capability not activated by strict isolation: "
                    f"{capability} (capabilityArgs.{capability} absent)"
                ),
                required_for=roles,
                remediation=(
                    f"Add validated capabilityArgs.{capability} argv bound to this "
                    "exact capability only if it is needed."
                ),
                dedupe_key=f"capability-activation:{capability}",
            )

    def capability_available(
        self,
        capability: str,
        registry: dict[str, Any],
        mcp: set[str],
        plugins: set[str],
    ) -> tuple[bool, str]:
        if capability in BUILTIN_CAPABILITIES:
            values = {
                "filesystem": bool(self.repo and self.repo.is_dir()),
                "git": shutil.which("git") is not None,
                "schemas": (self.engine / "schemas").is_dir(),
                "skills": (self.engine / "plugin/skills").is_dir()
                or bool(self.repo and (self.repo / ".agents/skills").is_dir()),
                "runner-contract": self.runner_contract_ok,
                "provider-executable": self.provider_bin is not None,
            }
            return values[capability], "built-in preflight failed"
        if capability.startswith("mcp:"):
            name = capability.split(":", 1)[1]
            return name in mcp, f"MCP server {name} is not configured"
        if capability.startswith("plugin:"):
            name = capability.split(":", 1)[1]
            return name in plugins, f"plugin {name} is not installed"
        if capability.startswith("executable:"):
            name = capability.split(":", 1)[1]
            return shutil.which(name, path=self.runtime_env.get("PATH")) is not None, (
                f"{name} is not on PATH"
            )
        if capability.startswith("file:"):
            raw = capability.split(":", 1)[1]
            path = Path(raw)
            if not path.is_absolute() and self.repo:
                path = self.repo / path
            return path.is_file(), f"{path} is missing"
        descriptor = registry.get(capability)
        if not isinstance(descriptor, dict):
            return False, "no capability descriptor"
        kind = descriptor.get("type")
        value = descriptor.get("value") or descriptor.get("name")
        if kind == "builtin":
            return bool(descriptor.get("available", True)), "disabled"
        if kind == "executable" and isinstance(value, str):
            return shutil.which(value, path=self.runtime_env.get("PATH")) is not None, (
                f"{value} is not on PATH"
            )
        if kind == "file" and isinstance(value, str):
            path = Path(value)
            if not path.is_absolute() and self.repo:
                path = self.repo / path
            return path.is_file(), f"{path} is missing"
        if kind == "mcp" and isinstance(value, str):
            return value in mcp, f"MCP server {value} is not configured"
        if kind == "plugin" and isinstance(value, str):
            return value in plugins, f"plugin {value} is not installed"
        if kind == "environment" and isinstance(value, str):
            return bool(self.runtime_env.get(value)), f"environment variable {value} is absent"
        return False, "unsupported capability descriptor"

    def bootstrap_check(self) -> None:
        if not self.repo:
            return
        config: Any = self.config.get("bootstrap")
        if config is None:
            raw = self.runtime_env.get("GLUERUN_BOOTSTRAP_JSON", "")
            if raw:
                try:
                    config = json.loads(raw)
                except json.JSONDecodeError as exc:
                    self.add(
                        "bootstrap.dry-run",
                        "fail",
                        f"bootstrap configuration is invalid JSON: {exc}",
                        required_for=("worker-runs",),
                        remediation="Repair GLUERUN_BOOTSTRAP_JSON.",
                    )
                    return
        if config is None:
            self.add(
                "bootstrap.dry-run",
                "skip",
                "worktree bootstrap is not configured",
                required_for=("worker-runs",),
            )
            return
        if not isinstance(config, dict):
            self.add(
                "bootstrap.dry-run",
                "fail",
                "bootstrap configuration must be an object",
                required_for=("worker-runs",),
                remediation="Repair the bootstrap section in gluerun.config.json.",
            )
            return
        helper = self.engine / "engine/bootstrap-worktree.sh"
        env = dict(self.runtime_env)
        env["GLUERUN_ROOT"] = str(self.repo)
        env["GLUERUN_ENGINE_HOME"] = str(self.engine)
        env["GLUERUN_BOOTSTRAP_JSON"] = compact(config)
        result = command(
            [str(helper), "--worktree", str(self.repo), "--dry-run"],
            cwd=self.repo,
            env=env,
            timeout=20,
        )
        if result.returncode == 0:
            try:
                record = json.loads(result.stdout)
            except json.JSONDecodeError:
                record = {}
            self.add(
                "bootstrap.dry-run",
                "pass",
                "bootstrap configuration and lockfiles validate in dry-run mode",
                required_for=("worker-runs",),
                details={
                    "lockfiles": record.get("lockfiles", []),
                    "sharedLinks": record.get("sharedLinks", 0),
                    "required": record.get("required", True),
                },
            )
        else:
            self.add(
                "bootstrap.dry-run",
                "fail",
                f"bootstrap dry-run failed: {first_line(result.stderr or result.stdout)}",
                required_for=("worker-runs",),
                remediation="Repair lockfiles, shared-store allowlists, or bootstrap paths.",
            )

    def resource_check(self) -> None:
        if not self.repo:
            return
        helper = self.engine / "engine/resource-plan.sh"
        env = dict(self.runtime_env)
        env["GLUERUN_ROOT"] = str(self.repo)
        resources = self.config.get("resources", {})
        if isinstance(resources, dict):
            mappings = {
                "diskReserveBytes": "GLUERUN_DISK_RESERVE_BYTES",
                "estimatedWorktreeBytes": "GLUERUN_ESTIMATED_WORKTREE_BYTES",
                "maxConcurrent": "GLUERUN_MAX_L1_CONCURRENT",
            }
            for source, target in mappings.items():
                if source in resources and target not in os.environ:
                    env[target] = str(resources[source])
        result = command([str(helper), "--json"], cwd=self.repo, env=env, timeout=20)
        if result.returncode != 0:
            self.add(
                "resources.adaptive-disk",
                "fail",
                f"adaptive disk calculation failed: {first_line(result.stderr or result.stdout)}",
                required_for=("worker-runs",),
                remediation="Correct disk reserve, estimate, and concurrency settings.",
            )
            return
        try:
            record = json.loads(result.stdout)
            effective = int(record["effectiveSlots"])
            configured = int(record["configuredSlots"])
            if effective == 0:
                status = "fail"
            elif effective < configured:
                status = "warn"
            else:
                status = "pass"
            self.add(
                "resources.adaptive-disk",
                status,
                (
                    f"adaptive disk capacity: {effective}/{configured} worker slots "
                    f"({record.get('reason', 'unknown')})"
                ),
                required_for=("worker-runs",),
                remediation=(
                    ""
                    if status == "pass"
                    else "Free disk, lower concurrency, or tune the documented reserve/estimate."
                ),
                details=record,
            )
        except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
            self.add(
                "resources.adaptive-disk",
                "fail",
                f"adaptive disk calculation returned invalid data: {exc}",
                required_for=("worker-runs",),
                remediation="Repair engine/resource-plan.sh.",
            )

    def governance_checks(self) -> None:
        compatibility = self.config.get("legacyCompatibility", {})
        if compatibility is None:
            compatibility = {}
        if not isinstance(compatibility, dict):
            self.add(
                "governance.unbound-waivers",
                "fail",
                "legacyCompatibility must be an object",
                required_for=("schema-v2-runs",),
                remediation="Use legacyCompatibility.unboundWaivers as a boolean.",
            )
            return
        selected = compatibility.get("unboundWaivers", False)
        if not isinstance(selected, bool):
            self.add(
                "governance.unbound-waivers",
                "fail",
                "legacyCompatibility.unboundWaivers must be a boolean",
                required_for=("schema-v2-runs",),
                remediation="Set it to false, or explicitly true only during migration.",
            )
        elif selected:
            self.add(
                "governance.unbound-waivers",
                "warn",
                "legacy artifact-unbound accept-waivers are explicitly enabled",
                required_for=("legacy-compatibility",),
                remediation="Migrate approvals to exact-artifact human gates, then disable the switch.",
            )
        else:
            self.add(
                "governance.unbound-waivers",
                "pass",
                "artifact-unbound accept-waivers are disabled",
                required_for=("schema-v2-runs",),
            )

    def deployment_credentials(self) -> None:
        if not self.repo:
            return
        dag = self.repo / "docs/orchestration/dag.v0.json"
        if not dag.is_file():
            self.add(
                "deployment.credentials",
                "skip",
                "no deployment-capable node is ready",
                required_for=("deployment",),
            )
            return
        result = command(
            [str(self.bash), str(self.engine / "engine/dag.sh"), "next-areas"],
            cwd=self.repo,
            env=self.runtime_env,
            timeout=20,
        )
        if result.returncode != 0:
            self.add(
                "deployment.credentials",
                "skip",
                "deployment credentials not checked because no DAG frontier is available",
                required_for=("deployment",),
            )
            return
        try:
            frontier = json.loads(result.stdout).get("frontier", [])
        except (json.JSONDecodeError, AttributeError):
            frontier = []
        deploy_nodes = [
            item
            for item in frontier
            if isinstance(item, dict)
            and any(
                str(item.get(key, "")).lower() in DEPLOY_KINDS
                or "deploy" in str(item.get(key, "")).lower()
                for key in ("kind", "layer", "stage")
            )
        ]
        if not deploy_nodes:
            self.add(
                "deployment.credentials",
                "skip",
                "no deployment-capable node is ready",
                required_for=("deployment",),
            )
            return
        declarations = self.config.get("deploymentCredentials", [])
        normalized: list[dict[str, Any]] = []
        if isinstance(declarations, dict):
            for ident, value in declarations.items():
                if isinstance(value, str):
                    normalized.append({"id": ident, "env": value})
                elif isinstance(value, dict):
                    normalized.append({"id": ident, **value})
        elif isinstance(declarations, list):
            normalized = [item for item in declarations if isinstance(item, dict)]
        ready_ids = {str(item.get("node")) for item in deploy_nodes}
        ready_traits = ready_ids | {
            str(item.get(key))
            for item in deploy_nodes
            for key in ("kind", "layer", "stage")
        }
        applicable = []
        malformed = []
        for item in normalized:
            ident = item.get("id")
            env_name = item.get("env")
            required_for = item.get("requiredFor", [])
            if not isinstance(ident, str) or not isinstance(env_name, str):
                malformed.append(str(ident or "?"))
                continue
            if required_for and (
                not isinstance(required_for, list)
                or not any(str(value) in ready_traits or value == "*" for value in required_for)
            ):
                continue
            applicable.append((ident, env_name))
        if malformed:
            self.add(
                "deployment.credentials",
                "fail",
                f"deployment credential declarations are malformed: {', '.join(malformed)}",
                required_for=ready_ids,
                remediation="Each declaration needs string id and env fields.",
            )
            return
        if not applicable:
            self.add(
                "deployment.credentials",
                "warn",
                "deployment-capable node is ready but no credential requirements are declared",
                required_for=ready_ids,
                remediation="Declare deploymentCredentials in gluerun.config.json.",
            )
            return
        missing = [ident for ident, env_name in applicable if not self.runtime_env.get(env_name)]
        if missing:
            self.add(
                "deployment.credentials",
                "fail",
                f"deployment credentials are missing: {', '.join(missing)}",
                required_for=ready_ids,
                remediation="Provide the declared credentials through the operator environment.",
                details={"missing": missing, "readyNodes": sorted(ready_ids)},
            )
        else:
            self.add(
                "deployment.credentials",
                "pass",
                f"deployment credentials available for: {', '.join(sorted(ready_ids))}",
                required_for=ready_ids,
                details={
                    "credentialIds": [ident for ident, _ in applicable],
                    "readyNodes": sorted(ready_ids),
                },
            )

    def run(self) -> int:
        self.basic_checks()
        self.load_config()
        self.effective_environment()
        self.schema_checks()
        self.repo_hygiene_checks()
        self.resolve_runner()
        self.check_runner_contract()
        self.resolve_provider_executable()
        self.provider_auth()
        self.maybe_repair_model_cache()
        self.model_checks()
        self.model_cache_compatibility()
        self.disposable_worktree()
        self.capability_profiles()
        self.bootstrap_check()
        self.resource_check()
        self.governance_checks()
        self.deployment_credentials()
        failed = sum(item["status"] == "fail" for item in self.checks)
        warned = sum(item["status"] == "warn" for item in self.checks)
        passed = sum(item["status"] == "pass" for item in self.checks)
        skipped = sum(item["status"] == "skip" for item in self.checks)
        report = {
            "schema": CHECK_SCHEMA,
            "generatedAt": utc_now(),
            "ok": failed == 0,
            "repo": str(self.repo) if self.repo else None,
            "engine": str(self.engine),
            "summary": {
                "passed": passed,
                "warnings": warned,
                "failed": failed,
                "skipped": skipped,
            },
            "checks": self.checks,
        }
        if self.output_json:
            print(json.dumps(report, indent=2, sort_keys=False))
        else:
            print("gluerun doctor")
            markers = {"pass": "ok", "warn": "warn", "fail": "FAIL", "skip": "info"}
            for item in self.checks:
                print(f"  {markers[item['status']]:<5} {item['message']} [{item['id']}]")
                if item["status"] in {"warn", "fail"} and item["remediation"]:
                    print(f"        remediation: {item['remediation']}")
        return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Structured gluerun operator preflight")
    parser.add_argument("--engine-home", required=True)
    parser.add_argument("--repo-root", default="")
    parser.add_argument("--bash", required=True)
    parser.add_argument("--bash-version", required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--repair-model-cache", action="store_true")
    args = parser.parse_args()
    return Doctor(
        engine=Path(args.engine_home),
        repo=Path(args.repo_root) if args.repo_root else None,
        bash=Path(args.bash),
        bash_version=args.bash_version,
        output_json=args.json,
        repair_model_cache=args.repair_model_cache,
    ).run()


if __name__ == "__main__":
    raise SystemExit(main())
