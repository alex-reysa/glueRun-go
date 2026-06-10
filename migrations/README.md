# Schema migrations

The engine's data contract version lives in the root `SCHEMA_VERSION` file
(currently `v0`). Each consumer repo declares the schema it was scaffolded
against in `gluerun.config.json` → `schemaVersion`. When an engine release bumps
`SCHEMA_VERSION`, it must ship migration scripts here so existing repos can
catch up via `gluerun migrate`.

## Naming contract

```
migrations/<fromSchema>-to-<toSchema>.sh      e.g. v0-to-v1.sh
```

- `<fromSchema>` / `<toSchema>` are schema version tokens (`v0`, `v1`, ...),
  exactly as written in `SCHEMA_VERSION` and in `gluerun.config.json`.
- One script per single step. A repo two schemas behind is migrated by the
  chain (`v0-to-v1.sh`, then `v1-to-v2.sh`) — never by a skip-level script.

## Execution (what `gluerun migrate` does)

1. Reads the repo's `gluerun.config.json` `schemaVersion` and the resolved
   engine's `SCHEMA_VERSION`.
2. If they match: prints "up to date" and exits 0 (no-op).
3. If the repo is behind: discovers `migrations/<current>-to-*.sh` in the
   engine install and runs the chain in ascending order, one step at a time,
   until the repo reaches the engine's schema version.
4. Each script is invoked as `bash <script> <repo-root>` — the target repo's
   absolute path is `$1`. Scripts run with the engine install as their
   on-disk location; they must not assume any particular CWD.
5. **After each script exits 0, `gluerun migrate` itself rewrites
   `schemaVersion` in the repo's `gluerun.config.json` to the script's
   `<toSchema>`.** Scripts must NOT edit `schemaVersion` themselves; they
   migrate content, the runner does the bookkeeping.
6. If a script exits nonzero, migration stops immediately; the repo's
   `schemaVersion` is left at the last completed step.

## What a migration script may touch

Only per-repo, committed orchestration surface in the target repo (`$1`):

- `gluerun.config.json` — key renames/moves/shape changes (except
  `schemaVersion`, see above).
- `docs/orchestration/**` — DAG manifest, task packets, area docs, gate docs,
  prompt skeletons.

A migration script must NOT touch: engine files, `~/.gluerun/`, `.gluerun-state/`
(runtime state), `.worktrees/`, the repo's source code, or `.gluerun-version`
(engine pinning is `gluerun update`'s job, not a schema concern). Scripts should
be idempotent where practical — re-running on an already-migrated repo must
not corrupt it.

## Missing migrations are a hard error

If a repo's `schemaVersion` is behind the engine's and no
`<current>-to-*.sh` script exists for the next step, `gluerun migrate` fails
with a nonzero exit ("no migration found for X -> Y; see CHANGELOG.md").
There is no silent fallback: a schema bump without a shipped migration path
is a release bug. `gluerun doctor` reports the same mismatch as a FAIL, and
`gluerun update` warns and points at `gluerun migrate` when the freshly pinned
engine's schema differs from the repo's.

`v0` → `v0` today means the mechanism ships with zero actual migrations; the
first real script lands together with the first `SCHEMA_VERSION` bump.
