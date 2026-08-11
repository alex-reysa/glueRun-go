# Contributing

Thanks for taking the time to improve singular.

Before opening a PR:

- Run `bash tests/run.sh`.
- Keep `engine/` generic. Project-specific rules belong in opt-in modules under
  `singular-ext/` or in a consumer repo's `singular.config.json` /
  `singular.config.sh`.
- Do not commit `.singular-state/`, `.worktrees/`, `.singular-evidence/`, local env
  files, generated logs, or other runtime artifacts.
- Preserve the public CLI names, `SINGULAR_*` env vars, and
  `singular.orchestration.*` schema namespace unless the change is an intentional
  versioned migration.

For behavior changes, include focused regression coverage in `tests/` or
`singular-ext/tests/`.
