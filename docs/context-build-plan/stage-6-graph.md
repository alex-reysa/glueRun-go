# Stage 6 — Provenance graph projection (M6)

> **Gate-passed** — this stage's nodes are complete; evidence in `../orchestration/gates/`.

Purpose: the durable semantic layer — as a PROJECTION. The graph is derived
from the event log, decision records, gate results, critiques, and ledgers. It
is rebuildable from scratch at any time and is never written directly by a
model. The system must remain fully recoverable with the graph deleted.

Entry condition (operator judgment, recorded in the node gate): M0–M5 metrics
show in-lineage continuity earning its cost — otherwise stop after M5 and
re-scope; the graph is the most expensive component and is justified only by
evidence.

## Node `graph-contract` (area: graph, layer: contract, single-slice)

Design task — operator reviews the diff before integration.

- `schemas/context-graph.v0.schema.json`: append-only JSONL under
  `.singular-state/graph/` — `nodes.jsonl` + `edges.jsonl`.
  - Node types: goal, plan-batch, plan-version, critique, finding, assumption,
    task, attempt, commit, gate-result, audit, decision, capsule.
  - Edge types: `depends_on`, `derived_from`, `revises`, `critiques`,
    `accepts_observation`, `rejects_observation`, `implements`, `verifies`,
    `contradicts`, `invalidates`, `supersedes`.
  - Every node carries `evidenceClass: authoritative | claim` —
    `authoritative` ONLY for host-verified records (gate results, commits,
    scope/secret scans); every model-authored statement is `claim`. Every node
    carries provenance (source record path + hash).
- A written mapping table in this file's task: which existing event/record
  types project to which node/edge types.

Exit gate: schema validates fixtures; mapping table covers every event type
used by Stages 0–5; suite green.

## Node `graph-projector` (area: graph, layer: engine_runtime)

- `engine/ctx-graph.sh`: idempotent projector — full rebuild
  (`singular graph rebuild`) and incremental append (`singular graph sync`,
  cursor over the event log). `cli/singular` hook chains behind
  `metrics-extract` for that file.
- Determinism: same inputs → byte-identical graph (stable ids: hash of source
  record identity).
- `singular graph query` minimal read API: neighbors, lineage walk
  (task → plan-version → critiques → findings → dispositions), and
  `open-contradictions` (contradicts/invalidates edges with no superseding
  resolution).
- Graph files covered by `artifact-secret-scan`.
- Behind `SINGULAR_CTX_GRAPH=0`.
- Tests `tests/test-ctx-graph.sh`: rebuild determinism; sync≡rebuild on
  fixtures; query outputs; authoritative/claim separation preserved.

Exit gate: suite green; rebuild ≡ sync on a fixture corpus; deleting the graph
and rebuilding is loss-free.

## Node `subgraph-rehydrate` (area: graph, layer: engine_runtime)

- Upgrade Stage 5 rehydration: packets assembled by SUBGRAPH SELECTION —
  lineage walk from the task node (its plan version, surviving critique
  findings, open assumptions, contradiction flags) instead of flat
  per-artifact concatenation. Same caps, same manifest recording, same taint.
- Selection is deterministic and rule-based (lineage + open-status filters);
  no relevance scoring in v0.
- A/B hook: arms can now compare flat-capsule rehydration vs subgraph
  rehydration.
- Tests: selection fixtures (deep lineage, rejected observations excluded,
  contradictions surfaced first); cap behavior; manifest accuracy.

Exit gate: suite green; fixture lineage produces the documented selection.
