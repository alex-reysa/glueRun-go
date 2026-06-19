# Contributing

Thanks for taking the time to improve glueRun-go.

Before opening a PR:

- Run `bash tests/run.sh`.
- Keep `engine/` generic. Project-specific rules belong in opt-in modules under
  `gluerun-ext/` or in a consumer repo's `gluerun.config.json` /
  `gluerun.config.sh`.
- Do not commit `.gluerun-state/`, `.worktrees/`, `.gluerun-evidence/`, local env
  files, generated logs, or other runtime artifacts.
- Preserve the public CLI names, `GLUERUN_*` env vars, and
  `gluerun.orchestration.*` schema namespace unless the change is an intentional
  versioned migration.

For behavior changes, include focused regression coverage in `tests/` or
`gluerun-ext/tests/`.
