# Stage 1 — Planner session persistence (M1)

Purpose: planner sessions become durable, addressable working memory per DAG
node. Today `generate-tasks.sh` invokes the runner with no `--session-meta`; the
planner's session id is discarded.

## Node `planner-session-meta` (area: session, layer: engine_runtime)

Owns the first hooks in `generate-tasks.sh` and `l1-plan-node.sh` (Stage 3's
`plan-revision-loop` chains behind this node for those files).

- `engine/ctx-planner-session.sh`: canonical per-node planner session-meta path
  `.gluerun-state/sessions/planner/<node>.json` (state dir, NOT docs/ — session
  ids are runtime state, not repo truth), reusing the existing
  `gluerun.orchestration.session-meta.v0` shape with `role: "planner"` and a new
  optional `node` field.
- Hook `generate-tasks.sh` (and the staged path in `l1-plan-node.sh`) to pass
  `--session-meta` to the runner and finalize host fields after a successful
  batch (reuse `gluerun_session_meta_finalize`; lineage anchor = the target
  branch head at planning time). Behind `GLUERUN_PLANNER_SESSION=0`.
- Failed/invalid planner runs must NOT finalize a resumable meta (a session that
  produced rejected output is not a lineage we extend blindly — Stage 3 revision
  is the deliberate exception, driven by critique findings).
- Test `tests/test-ctx-planner-session.sh` with a stub runner: meta written on
  success with correct role/node fields; not finalized on planner-failed; knob
  OFF → byte-identical.

Exit gate: suite green; stub planning run under the knob yields a valid
finalized meta; `planner-failed` yields none.

## Node `planner-resume-gates` (area: session, layer: engine_runtime)

- `engine/ctx-planner-resume.sh`: `gluerun_planner_resume_decide` — the
  planner-role variant of the resume decision. Same shape (`resume <id>` /
  `fresh <reason>`, ordered fail-closed gates, first failure names the reason),
  with these deltas from the task-role decider:
  - REPLACE runId-equality (gate 5) with **node lineage**: meta.node must equal
    the target node, and meta's recorded branch-head anchor must be an ancestor
    of the current target-branch head (`merge-base --is-ancestor`).
  - KEEP: affinity/enable knob, meta-parse, provider/sessionId, role gate
    (`planner` only — advocate/skeptic line), runner-changed,
    prompt-template-changed (sha of the planner TEMPLATE, not the rendered
    prompt — the rendering varies per frontier by design), max-age, cwd.
  - SHA ALIGNMENT (binding, added after TASK-0008 review): the integrated
    finalize hook in `generate-tasks.sh` currently stores the RENDERED
    prompt's sha in `promptSha256`. Comparing template-vs-rendered would
    permanently force `fresh prompt-template-changed` and silently neuter
    planner resume. This slice must align BOTH sides on the TEMPLATE sha
    (`docs/orchestration/prompts/l1-planner.md`): change the finalize call
    site (re-own `engine/generate-tasks.sh`) or normalize inside
    `gluerun_ctx_planner_session_finalize` (re-own
    `engine/ctx-planner-session.sh`), and treat a meta whose stored sha
    matches neither convention as `fresh no-session`. Add a test proving
    finalize→decide round-trips to `resume` across two frontiers with
    different rendered prompts but the same template.
  - ADD: **session lease** — `.gluerun-state/sessions/planner/<node>.lease`
    acquired before resume, released after; a held lease → `fresh leased`
    (parallel L1 fanout must never resume one session concurrently).
- `generate-tasks.sh` consults it only when `GLUERUN_PLANNER_SESSION=1`;
  resume-refused (rc 86) falls back to fresh within the same run, mirroring the
  worker path.
- Emit `context.strategy_selected` events with `role: "planner"` and the gate
  reason, so `ctx-metrics.sh` sees planner routing like any other role.
- Test `tests/test-ctx-planner-resume.sh`: every gate individually forces
  `fresh <reason>`; happy path resumes; lease contention forces fresh; rc-86
  fallback proceeds fresh in-run.

Exit gate: suite green; all gate reasons observable in events from fixtures.
