# Schema migrations

The engine's data contract version lives in the root `SCHEMA_VERSION` file
(currently `v2`). Each consumer repo declares the schema it was scaffolded
against in `singular.config.json` → `schemaVersion`. When an engine release bumps
`SCHEMA_VERSION`, it must ship migration scripts here so existing repos can
catch up via `singular migrate`.

## Naming contract

```
migrations/<fromSchema>-to-<toSchema>.sh      e.g. v0-to-v1.sh
```

- `<fromSchema>` / `<toSchema>` are schema version tokens (`v0`, `v1`, ...),
  exactly as written in `SCHEMA_VERSION` and in `singular.config.json`.
- One script per single step. A repo two schemas behind is migrated by the
  chain (`v0-to-v1.sh`, then `v1-to-v2.sh`) — never by a skip-level script.

## Execution (what `singular migrate` does)

1. Reads the repo's `singular.config.json` `schemaVersion` and the resolved
   engine's `SCHEMA_VERSION`.
2. If they match: prints "up to date" and exits 0 (no-op).
3. If the repo is behind: discovers `migrations/<current>-to-*.sh` in the
   engine install and runs the chain in ascending order, one step at a time,
   until the repo reaches the engine's schema version.
4. Each script is invoked as `bash <script> <repo-root>` — the target repo's
   absolute path is `$1`. Scripts run with the engine install as their
   on-disk location; they must not assume any particular CWD.
5. **After each script exits 0, `singular migrate` itself rewrites
   `schemaVersion` in the repo's `singular.config.json` to the script's
   `<toSchema>`.** Scripts must NOT edit `schemaVersion` themselves; they
   migrate content, the runner does the bookkeeping.
6. If a script exits nonzero, migration stops immediately; the repo's
   `schemaVersion` is left at the last completed step.

## Dry run (`singular migrate --dry-run`)

`singular migrate --dry-run` walks the same discovery as step 3 and prints the
resolved chain — one `would run: <script> (<from> -> <to>)` line per step —
then exits.

- It invokes nothing: no migration script is executed, and `schemaVersion` is
  never written.
- It is also the classifier for an unresolvable chain: a missing step fails
  there ("no migration found for X -> Y"), before the repository is touched.
- Migration scripts themselves have **no dry-run protocol**. They are never
  invoked with a "pretend" flag, must not implement one, and must not try to
  detect one — a script that runs is a script that migrates.
- The operator-facing safety therefore comes from outside the script: the chain
  plan above, plus `singular setup`, which hashes every gate result before
  migrating (`.singular-state/setup/gates-pre-migrate.json`) and afterwards
  verifies each historical verdict (`node`, `status`, `authoritative`,
  `recordedAt`) survived, refusing to report success when one did not.

## What a migration script may touch

Only per-repo, committed orchestration surface in the target repo (`$1`):

- `singular.config.json` — key renames/moves/shape changes (except
  `schemaVersion`, see above).
- `docs/orchestration/**` — DAG manifest, task packets, area docs, gate docs,
  prompt skeletons.
- `schemas/orchestration/**` — consumer copies of the engine's public schema
  bundle. A migration may replace engine-owned basenames after staging and
  validating the complete authoritative set; consumer-only custom schemas must
  be preserved.

A migration script must NOT touch: engine files, `~/.singular/`, `.singular-state/`
(runtime state), `.worktrees/`, the repo's source code, or `.singular-version`
(engine pinning is `singular update`'s job, not a schema concern). Scripts should
be idempotent where practical — re-running on an already-migrated repo must
not corrupt it.

## Missing migrations are a hard error

If a repo's `schemaVersion` is behind the engine's and no
`<current>-to-*.sh` script exists for the next step, `singular migrate` fails
with a nonzero exit ("no migration found for X -> Y; see CHANGELOG.md").
There is no silent fallback: a schema bump without a shipped migration path
is a release bug. `singular doctor` reports the same mismatch as a FAIL, and
`singular update` warns and points at `singular migrate` when the freshly pinned
engine's schema differs from the repo's.

The current public contract is `v2`. `migrations/v0-to-v1.sh` backfills the
original scaffold and rewrites legacy `pmgo.orchestration.*` namespace
references to `singular.orchestration.*`. `migrations/v1-to-v2.sh` stages and
validates the authoritative schema bundle, replaces matching consumer mirrors,
adds the role/capability, evidence, bootstrap, resource, and control-state
configuration defaults when absent, and creates the human-gate and strict-gate
baseline directories. Existing v0 artifacts remain readable; v1 result
artifacts are written only after the migration runner advances the repo to v2.
