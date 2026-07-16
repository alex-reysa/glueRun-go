# Durable artifacts — canonical file map, field names, jq cookbook

Field naming differs per artifact BY DESIGN (each schema is versioned and
durable; they will not be renamed). This table is the authority — the field
audit showed supervisors guessing `nodeId`/`status`/`result` and producing
wrong counts twice.

| Artifact | Path | Id field | Outcome field |
|---|---|---|---|
| gate result | `docs/orchestration/gates/<node>.gate-result.json` | `node` | `status` (`passed/failed/blocked/proposed`) + `authoritative` bool |
| gate review (0.5.0) | `docs/orchestration/gates/evidence/<node>.review.json` | `node` | `verdict` (`pass/fail`) + `reviewer{kind,id}` |
| audit verdict | `.gluerun-state/runs/<RUN>/audit.json` | `taskId` | `verdict` (`accepted/needs-fix/blocked/needs-human`) |
| decider verdict | `.gluerun-state/runs/<RUN>/decision-<class>.json` | `taskId` | `action` (`retry/…/escalate-parked`) + `failureClass` |
| state packet | `.gluerun-state/inbox/<RUN>.json`, `docs/orchestration/packets/imported/<TASK>/` | `taskId` | `status` (`needs-review/accepted`) |
| L2 lease | `.gluerun-state/leases/<TASK>.json` | `taskId` | `status` (`planned/running/needs-review/accepted/integrated/failed/blocked/cancelled/superseded/stale`) |
| L1 lease | `.gluerun-state/l1-leases/<node>.json` | `node` | `status` (`proposed/planning/active/released/failed`) |
| dispatch record | `.gluerun-state/dispatch/<TASK>.json` (+`.exit`) | `taskId` | `state` (`launched/reaped`) + `outcome` (`ok/refused/terminal/failed/crashed`) |
| events journal | `.gluerun-state/events.ndjson` (**ndjson, not .jsonl/.log**) | `type` | per-type `data{}` |
| task file | `docs/orchestration/tasks/<TASK>.md` (superseded → `tasks/superseded/`) | header `# TASK-XXXX:` | header `Status:` (+ `DAG node:`, `Supersedes:`, `Superseded by:`) |
| planner backoff | `.gluerun-state/planner-backoff.json` | — | `failureClass` + `until` + `logRef` (never empty for quota since 0.5.0) |
| breaker | `.gluerun-state/circuit.json` | — | `consecFails` |
| origin state | `.gluerun-state/origin-state.json` | — | `gates{passed,total}`, `completedNodes`, `taskCounts` (0.5.0) |

Control files: `STOP` (halt), `WAKE` (end current nap), `console.url` /
`console.pid` (live console), `task-id-counter` (monotonic allocator).

## jq cookbook

Prefer `gluerun health --json` / `gluerun gates --json` over hand-rolled
queries; these cover the rest.

```bash
# 1. Decider outcomes, most recent last (field gotcha: action+failureClass,
#    not "result"):
jq -r 'select(.type=="decider.verdict")
       | [.ts, .data.taskId, .data.failureClass, .data.action] | @tsv' \
  .gluerun-state/events.ndjson | tail -20

# 2. Gate progress without the console (field gotcha: .node not .nodeId):
jq -r '[.node, .status, .evidenceClass] | @tsv' \
  docs/orchestration/gates/*.gate-result.json

# 3. Non-terminal leases (what is actually holding slots):
jq -r 'select(.status=="running" or .status=="planned" or .status=="needs-review")
       | [.taskId, .status, .runId, .updatedAt] | @tsv' \
  .gluerun-state/leases/*.json

# 4. Why a task was last rejected (field gotcha: verdict, not status):
jq -r '[.taskId, .verdict, (.requiredFixes // [] | join("; "))] | @tsv' \
  .gluerun-state/runs/<RUN>/audit.json

# 5. Parked tasks and their reasons from the journal:
jq -r 'select(.type=="l1.task_terminal")
       | [.ts, .data.taskId, .data.action, .data.lastFailure] | @tsv' \
  .gluerun-state/events.ndjson

# 6. Frontier and exactly why each excluded node is excluded:
gluerun next-areas --explain | jq '{frontier: [.frontier[].node], excluded}'
```
