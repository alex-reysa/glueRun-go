#!/usr/bin/env bash
# ctx-metrics.sh — read-only orchestration metrics extractor.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior.
#
# STRICTLY READ-ONLY: it reads each run's attempts index
# (runs/<runId>/attempts/index.json, schema singular.orchestration.attempts-index.v0),
# node-private L1 planner runner events, and the global events log (events.ndjson),
# then emits metrics as JSON on stdout. It never creates, modifies, or deletes a
# run artifact, index, or event.
#
# Public entry point:
#   singular_ctx_metrics_json [runs_dir] [events_file]
#     runs_dir     defaults to ${SINGULAR_RUNS_DIR:-}
#     events_file  defaults to ${SINGULAR_EVENTS_FILE:-}
#   Missing/empty inputs are NOT an error: they yield a well-formed metrics
#   object with zeroed counts (fail safe).
#
# Output shape (stable; keys sorted; deterministic for a given input set):
#   {
#     "schema": "singular.orchestration.ctx-metrics.v0",
#     "perTask": [                      # one entry per runs/<runId>/attempts/index.json,
#                                       # sorted by (taskId, runId)
#       {
#         "runId": <str>,
#         "taskId": <str>,
#         "attemptsTotal": <int>,       # number of attempt entries in the index
#         "attemptsToAccept": <int|null>,   # n of the first accepted attempt, else null
#         "accepted": <bool>,           # whether any attempt was accepted
#         "failureClassCounts": { <class>: <int> },      # "" -> "accepted"
#         "auditVerdictCounts": { <verdict>: <int> },    # "" -> "none"
#         "workerStrategyCounts": { <strategy>: <int> }, # absent field not counted
#         "reviewerStrategyCounts": { <strategy>: <int> },
#         "deciderAuthorityCounts": { <authority>: <int> }  # "" -> "none"
#       }, ...
#     ],
#     "aggregate": {                    # totals/distributions across all runs
#       "runsTotal": <int>,
#       "attemptsTotal": <int>,
#       "acceptedRuns": <int>,
#       "failureClassCounts": { <class>: <int> },
#       "auditVerdictCounts": { <verdict>: <int> },
#       "workerStrategyCounts": { <strategy>: <int> },
#       "reviewerStrategyCounts": { <strategy>: <int> },
#       "deciderAuthorityCounts": { <authority>: <int> },
#       "strategySelectedReasonCounts": { <reason>: <int> }  # from events log:
#           # data.reason of every context.strategy_selected event
#       "campaign": {                  # event-evidence-backed campaign SLOs
#         "availability": { ... },      # says when a value cannot be measured
#         "state": <"active"|"ended"|null>,
#         "startedAt": <RFC3339|null>,
#         "endedAt": <RFC3339|null>,    # explicit matching campaign.ended only
#         "startSource": <event type|null>,
#         "observedEndedAt": <RFC3339|null>,
#         "observedDurationSeconds": <int|null>,
#         "timeToFirstPlanningSeconds": <int|null>,
#         "timeToFirstImplementationSeconds": <int|null>,
#         "timeToFirstIntegrationSeconds": <int|null>,
#         "counters": { ... },
#         "stop": { ... },
#         "usefulThroughput": { ... }
#       }
#     }
#   }
# An attempt is "accepted" when its failureClass is "" / "accepted" / "none".
# JSON is emitted with sorted keys and a trailing newline so downstream consumers
# and tests can pin the exact bytes.

singular_ctx_metrics_json() {
  local runs_dir="${1:-${SINGULAR_RUNS_DIR:-}}"
  local events_file="${2:-${SINGULAR_EVENTS_FILE:-}}"
  python3 - "$runs_dir" "$events_file" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

runs_dir, events_file = sys.argv[1], sys.argv[2]

ACCEPTED_CLASSES = {"", "accepted", "none"}


def bump(counter, key):
    counter[key] = counter.get(key, 0) + 1


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def parse_timestamp(value):
    """Return an aware UTC datetime for an RFC3339 event timestamp, else None.

    Event timestamps are evidence, not a clock we are permitted to reconstruct.
    Consequently malformed or absent timestamps are ignored for durations while
    their event counters remain available.
    """
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc)


def format_timestamp(value):
    if value is None:
        return None
    return value.isoformat().replace("+00:00", "Z")


def data_object(event):
    data = event.get("data")
    return data if isinstance(data, dict) else {}


def accepted_import(event):
    """True only when a packet-import event explicitly says it was accepted."""
    if event.get("type") != "packet.imported":
        return False
    data = data_object(event)
    verdict = str(data.get("verdict", "")).lower()
    mode = str(data.get("acceptanceMode", "")).lower()
    return verdict in {"accept", "accepted"} or mode in {
        "accepted", "accepted-waiver", "accept-waiver", "waived"
    }


def campaign_metrics(events, events_readable, private_runner_events):
    """Derive campaign SLOs without treating absent evidence as a zero.

    Scope is the latest explicit ``campaign.started`` event, when one exists,
    through the first later ``campaign.ended`` carrying the same campaignId.
    Legacy logs fall back to the first ``autonomate.started`` and remain an open
    observation window.  Journal positions define membership; timestamps are
    used only for durations and to conservatively place private L1 runner events.
    No index is used to synthesize timestamps.
    """
    unavailable = {
        "eventsReadable": events_readable,
        "timestampEvents": 0,
        "roleInvocationEvents": False,
        "providerInvocationEvents": False,
        "invocationSource": None,
        "attemptIdentityEvents": False,
    }
    empty = {
        "availability": unavailable,
        "state": None,
        "startedAt": None,
        "endedAt": None,
        "startSource": None,
        "observedEndedAt": None,
        "observedDurationSeconds": None,
        "firstPlanningAt": None,
        "timeToFirstPlanningSeconds": None,
        "firstImplementationAt": None,
        "timeToFirstImplementationSeconds": None,
        "firstIntegrationAt": None,
        "timeToFirstIntegrationSeconds": None,
        "counters": {
            "acceptedImports": None,
            "acceptedTasks": None,
            "integrations": None,
            "promotions": None,
            "roleInvocationCounts": None,
            "providerInvocationCounts": None,
            "modelCalls": None,
            "plannerCriticCalls": None,
            "plannerCriticCallFraction": None,
            "identicalAttemptLineageReentries": None,
        },
        "stop": {
            "closedIntervals": None,
            "openIntervals": None,
            "closedSeconds": None,
            "observedOpenSeconds": None,
            "openSince": None,
        },
        "usefulThroughput": {
            "integrationsPerObservedActiveHour": None,
            "observedActiveSeconds": None,
        },
    }
    if not events and not private_runner_events:
        return empty

    stamped = []
    for position, event in enumerate(events):
        stamp = parse_timestamp(event.get("ts"))
        if stamp is not None:
            stamped.append((stamp, position, event))
    unavailable["timestampEvents"] = len(stamped)

    # Lifecycle boundaries are append-order facts.  Do not pick the "latest"
    # campaign by timestamp: a recovered journal may contain out-of-order clocks,
    # while its record order still says which campaign was activated last.
    stamped.sort(key=lambda item: (item[0], item[1]))
    explicit_starts = [(position, event) for position, event in enumerate(events)
                       if event.get("type") == "campaign.started"]
    legacy_starts = [(position, event) for position, event in enumerate(events)
                     if event.get("type") == "autonomate.started"]
    if explicit_starts:
        start_position, start_event = explicit_starts[-1]
    elif legacy_starts:
        start_position, start_event = legacy_starts[0]
    else:
        # Event totals can still be useful, but SLO timing is unavailable with no
        # campaign/autonomate anchor. Do not substitute the journal's first event.
        start_position = start_event = None
    start_stamp = parse_timestamp(start_event.get("ts")) if start_event is not None else None

    # Only an explicit end for this exact campaign closes the window.  An end for
    # an older/other campaign is unrelated control-plane evidence and must not
    # truncate the current campaign's metrics.
    end_position = None
    end_event = None
    if start_event is not None and start_event.get("type") == "campaign.started":
        campaign_id = data_object(start_event).get("campaignId")
        for position in range(start_position + 1, len(events)):
            candidate = events[position]
            if (candidate.get("type") == "campaign.ended"
                    and data_object(candidate).get("campaignId") == campaign_id):
                end_position = position
                end_event = candidate
                break
    end_stamp = parse_timestamp(end_event.get("ts")) if end_event is not None else None
    campaign_state = None if start_event is None else ("ended" if end_event is not None else "active")

    # Use original journal positions rather than event equality: recovered logs
    # may legitimately contain byte-identical event envelopes.  The matching end
    # is included so endedAt and the observed duration share the same boundary.
    scoped = [event for position, event in enumerate(events)
              if (start_position is None or position >= start_position)
              and (end_position is None or position <= end_position)]

    def position_in_scope(position):
        return ((start_position is None or position >= start_position)
                and (end_position is None or position <= end_position))

    def private_runner_in_scope(event):
        # Private planner journals have no position in the authoritative global
        # event stream.  Include them only when their timestamp proves membership
        # in the selected campaign window; otherwise fail closed on attribution.
        if start_event is None:
            return True
        stamp = parse_timestamp(event.get("ts"))
        if stamp is None or start_stamp is None or stamp < start_stamp:
            return False
        if end_event is not None:
            return end_stamp is not None and stamp <= end_stamp
        return True

    def first_stamped(types):
        matching = [item for item in stamped if position_in_scope(item[1])
                    and item[2].get("type") in types]
        return matching[0][0] if matching else None

    planning_types = {
        "origin.l1_fanout", "planner.staged", "planner.generated",
        "planner.no_tasks", "planner.failed", "plan.critiqued", "plan.revised",
    }
    implementation_types = {"l1.dispatch_started"}
    integration_types = {"integration.integrated"}

    first_planning = first_stamped(planning_types)
    first_implementation = first_stamped(implementation_types)
    first_integration = first_stamped(integration_types)
    scoped_stamps = [item[0] for item in stamped
                     if start_position is not None and position_in_scope(item[1])]

    accepted_import_events = [event for event in scoped if event.get("type") == "packet.imported"]
    accepted_import_count = sum(1 for event in accepted_import_events if accepted_import(event))
    # A packet-import without an explicit acceptance field is deliberately not
    # included in the accepted-import total.  Surface partial availability rather
    # than silently presenting the lower bound as the complete count.
    accepted_import_unknown = len(accepted_import_events) - accepted_import_count

    # Acceptance publication can complete either on the ordinary L1 path or on
    # evidence-only resume.  Count durable acceptance identities, not event rows:
    # a crash/replay may append both envelopes for the same task/run.
    accepted_identities = set()
    for position, event in enumerate(events):
        if not position_in_scope(position) or event.get("type") not in {
            "l1.task_accepted", "l1.accepted_evidence_resume_completed"
        }:
            continue
        data = data_object(event)
        task_id = data.get("taskId")
        run_id = data.get("runId")
        if isinstance(task_id, str) and task_id:
            accepted_identities.add(("task-run", task_id, run_id if isinstance(run_id, str) else ""))
        elif isinstance(run_id, str) and run_id:
            accepted_identities.add(("run", run_id))
        else:
            # Malformed legacy evidence has no stable task/run identity. Preserve
            # a distinct lower-bound envelope without allowing exact replays to
            # inflate the count.
            accepted_identities.add(("event", json.dumps(event, sort_keys=True, separators=(",", ":"))))

    exact_role_counts = {}
    exact_provider_counts = {}
    proxy_role_counts = {}
    proxy_provider_counts = {}
    identity_seen = False
    reentries = 0
    role_event_seen = False
    provider_event_seen = False
    reentry_types = {"plan.attempt_reused", "attempt.reentered", "lineage.reentered"}

    # Private parallel-planner journals are not merged into the L0 event stream.
    # Recover their runner.completed authority here, deduping by runnerResultRef.
    # For legacy no-ref private rows, an exact envelope fingerprint prevents a
    # copied global/private event from becoming two model calls; global no-ref
    # rows retain their original per-row semantics.
    exact_runner_events = []
    seen_runner_refs = set()
    global_no_ref_fingerprints = set()
    private_no_ref_fingerprints = set()

    def runner_ref(event):
        value = data_object(event).get("runnerResultRef")
        if not isinstance(value, str) or not value.strip():
            return None
        return os.path.normcase(os.path.normpath(value.strip()))

    def runner_fingerprint(event):
        return json.dumps(event, sort_keys=True, separators=(",", ":"))

    for event in scoped:
        typ = event.get("type")
        data = data_object(event)
        # runner.completed is emitted by the shared normalized-result writer and
        # is the exact model-call authority.  Older journals have only routing
        # events; retain those as an explicitly labelled proxy, but never add
        # both sources together or one provider call would be double-counted.
        if typ == "runner.completed":
            ref = runner_ref(event)
            if ref is None:
                global_no_ref_fingerprints.add(runner_fingerprint(event))
                exact_runner_events.append(event)
            elif ref not in seen_runner_refs:
                seen_runner_refs.add(ref)
                exact_runner_events.append(event)
        elif typ in {"context.strategy_selected", "runner.invoked", "provider.invoked"}:
            role = data.get("role")
            if isinstance(role, str) and role:
                bump(proxy_role_counts, role)
            provider = data.get("provider")
            if isinstance(provider, str) and provider:
                bump(proxy_provider_counts, provider)
        identity = data.get("attemptIdentity") or data.get("lineageIdentity")
        if isinstance(identity, str) and identity:
            identity_seen = True
            if typ in reentry_types:
                reentries += 1

    for event in private_runner_events:
        if not private_runner_in_scope(event):
            continue
        stamp = parse_timestamp(event.get("ts"))
        if start_position is not None and stamp is not None:
            scoped_stamps.append(stamp)
        ref = runner_ref(event)
        if ref is not None:
            if ref in seen_runner_refs:
                continue
            seen_runner_refs.add(ref)
        else:
            fingerprint = runner_fingerprint(event)
            if fingerprint in global_no_ref_fingerprints or fingerprint in private_no_ref_fingerprints:
                continue
            private_no_ref_fingerprints.add(fingerprint)
        exact_runner_events.append(event)

    for event in exact_runner_events:
        data = data_object(event)
        role = data.get("role")
        if isinstance(role, str) and role:
            bump(exact_role_counts, role)
            role_event_seen = True
        provider = data.get("provider")
        if isinstance(provider, str) and provider:
            bump(exact_provider_counts, provider)
            provider_event_seen = True

    if exact_role_counts or exact_provider_counts:
        invocation_source = "runner.completed"
        role_counts = exact_role_counts
        provider_counts = exact_provider_counts
    elif proxy_role_counts or proxy_provider_counts:
        invocation_source = "routing-proxy"
        role_counts = proxy_role_counts
        provider_counts = proxy_provider_counts
        role_event_seen = bool(role_counts)
        provider_event_seen = bool(provider_counts)
    else:
        invocation_source = None
        role_counts = {}
        provider_counts = {}
    unavailable["roleInvocationEvents"] = role_event_seen
    unavailable["providerInvocationEvents"] = provider_event_seen
    unavailable["invocationSource"] = invocation_source
    unavailable["attemptIdentityEvents"] = identity_seen

    model_calls = sum(role_counts.values()) if role_event_seen else None
    planner_critic_calls = None
    planner_critic_fraction = None
    if model_calls is not None:
        planner_critic_calls = sum(
            count for role, count in role_counts.items()
            if role in {"planner", "critic", "plan-critic"}
        )
        if model_calls > 0:
            planner_critic_fraction = planner_critic_calls / model_calls

    integrations = sum(1 for event in scoped if event.get("type") == "integration.integrated")
    # A matching campaign.ended timestamp is the authoritative terminal clock.
    # For an active campaign, the latest scoped global/private observation is the
    # end of the measurement window, not a claim that the campaign has ended.
    observed_end = end_stamp if end_stamp is not None else (max(scoped_stamps) if scoped_stamps else None)
    observed_duration = None
    if start_stamp is not None and observed_end is not None:
        observed_duration = max(0, int((observed_end - start_stamp).total_seconds()))

    stop_started = None
    stop_closed = 0
    stop_seconds = 0
    for stamp, position, event in stamped:
        if not position_in_scope(position):
            continue
        typ = event.get("type")
        if typ == "operator.stop_requested" and stop_started is None:
            stop_started = stamp
        elif typ == "operator.resume_requested" and stop_started is not None:
            stop_closed += 1
            stop_seconds += max(0, int((stamp - stop_started).total_seconds()))
            stop_started = None

    # An unclosed STOP is still inactive time through the observed boundary.  It
    # remains reported separately from completed intervals so operators can tell
    # a presently paused campaign from historical pause time.
    observed_open_seconds = 0
    if stop_started is not None and observed_end is not None:
        observed_open_seconds = max(0, int((observed_end - stop_started).total_seconds()))
    active_seconds = None
    throughput = None
    if observed_duration is not None:
        active_seconds = max(0, observed_duration - stop_seconds - observed_open_seconds)
        if active_seconds > 0:
            throughput = integrations / (active_seconds / 3600)

    def elapsed(stamp):
        if start_stamp is None or stamp is None:
            return None
        return max(0, int((stamp - start_stamp).total_seconds()))

    empty.update({
        "availability": unavailable,
        "state": campaign_state,
        "startedAt": format_timestamp(start_stamp),
        "endedAt": format_timestamp(end_stamp),
        "startSource": start_event.get("type") if start_event is not None else None,
        "observedEndedAt": format_timestamp(observed_end),
        "observedDurationSeconds": observed_duration,
        "firstPlanningAt": format_timestamp(first_planning),
        "timeToFirstPlanningSeconds": elapsed(first_planning),
        "firstImplementationAt": format_timestamp(first_implementation),
        "timeToFirstImplementationSeconds": elapsed(first_implementation),
        "firstIntegrationAt": format_timestamp(first_integration),
        "timeToFirstIntegrationSeconds": elapsed(first_integration),
        "counters": {
            "acceptedImports": accepted_import_count if accepted_import_unknown == 0 else None,
            "acceptedImportsConfirmed": accepted_import_count,
            "acceptedImportsAvailability": "partial" if accepted_import_unknown else "available",
            "acceptedTasks": len(accepted_identities),
            "integrations": integrations,
            "promotions": sum(1 for event in scoped if event.get("type") == "gate_promotion.completed"),
            "roleInvocationCounts": role_counts if role_event_seen else None,
            "providerInvocationCounts": provider_counts if provider_event_seen else None,
            "modelCalls": model_calls,
            "plannerCriticCalls": planner_critic_calls,
            "plannerCriticCallFraction": planner_critic_fraction,
            "identicalAttemptLineageReentries": reentries if identity_seen else None,
        },
        "stop": {
            "closedIntervals": stop_closed,
            "openIntervals": 1 if stop_started is not None else 0,
            "closedSeconds": stop_seconds,
            "observedOpenSeconds": observed_open_seconds,
            "openSince": format_timestamp(stop_started),
        },
        "usefulThroughput": {
            "integrationsPerObservedActiveHour": throughput,
            "observedActiveSeconds": active_seconds,
        },
    })
    return empty


def per_task(index):
    attempts = index.get("attempts")
    if not isinstance(attempts, list):
        attempts = []
    attempts = [a for a in attempts if isinstance(a, dict)]

    failure = {}
    verdict = {}
    worker = {}
    reviewer = {}
    authority = {}
    accepted_to = None
    for a in sorted(attempts, key=lambda x: x.get("n", 0)):
        fc = str(a.get("failureClass", ""))
        fc_key = "accepted" if fc in ACCEPTED_CLASSES else fc
        bump(failure, fc_key)
        bump(verdict, str(a.get("auditVerdict", "")) or "none")
        bump(authority, str(a.get("deciderAuthority", "")) or "none")
        if "workerStrategy" in a and a.get("workerStrategy"):
            bump(worker, str(a["workerStrategy"]))
        if "reviewerStrategy" in a and a.get("reviewerStrategy"):
            bump(reviewer, str(a["reviewerStrategy"]))
        if fc in ACCEPTED_CLASSES and accepted_to is None:
            try:
                accepted_to = int(a.get("n"))
            except (TypeError, ValueError):
                accepted_to = None
    return {
        "runId": str(index.get("runId", "")),
        "taskId": str(index.get("taskId", "")),
        "attemptsTotal": len(attempts),
        "attemptsToAccept": accepted_to,
        "accepted": accepted_to is not None,
        "failureClassCounts": failure,
        "auditVerdictCounts": verdict,
        "workerStrategyCounts": worker,
        "reviewerStrategyCounts": reviewer,
        "deciderAuthorityCounts": authority,
    }


per_task_list = []
if runs_dir and os.path.isdir(runs_dir):
    for run in sorted(os.listdir(runs_dir)):
        idx_path = os.path.join(runs_dir, run, "attempts", "index.json")
        if not os.path.isfile(idx_path):
            continue
        index = read_json(idx_path)
        if not isinstance(index, dict):
            continue
        if not index.get("runId"):
            index["runId"] = run
        per_task_list.append(per_task(index))

per_task_list.sort(key=lambda t: (t["taskId"], t["runId"]))

# Aggregate distributions across all runs.
agg_failure = {}
agg_verdict = {}
agg_worker = {}
agg_reviewer = {}
agg_authority = {}
attempts_total = 0
accepted_runs = 0
for t in per_task_list:
    attempts_total += t["attemptsTotal"]
    if t["accepted"]:
        accepted_runs += 1
    for src, dst in (
        (t["failureClassCounts"], agg_failure),
        (t["auditVerdictCounts"], agg_verdict),
        (t["workerStrategyCounts"], agg_worker),
        (t["reviewerStrategyCounts"], agg_reviewer),
        (t["deciderAuthorityCounts"], agg_authority),
    ):
        for k, v in src.items():
            dst[k] = dst.get(k, 0) + v

# Read the event log exactly once.  Individual malformed records are ignored,
# which makes the extractor safe over an append-in-progress journal.  The
# campaign metrics below retain availability metadata so a missing timestamp is
# never transformed into a made-up duration or an optimistic zero.
events = []
events_readable = False
if events_file and os.path.isfile(events_file):
    try:
        with open(events_file, "r", encoding="utf-8") as f:
            events_readable = True
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(ev, dict):
                    events.append(ev)
    except OSError:
        pass

# Parallel L1 planners intentionally write to node-private journals because they
# are not L0 authorities.  Those files still contain exact runner.completed call
# evidence, so metrics reads only that event type from the fixed staging shape.
# Malformed/partially appended rows are ignored just like the global journal.
private_runner_events = []
if runs_dir and os.path.isdir(runs_dir):
    try:
        run_names = sorted(os.listdir(runs_dir))
    except OSError:
        run_names = []
    for run_name in run_names:
        staging_dir = os.path.join(runs_dir, run_name, "l1-staging")
        if not os.path.isdir(staging_dir):
            continue
        try:
            node_names = sorted(os.listdir(staging_dir))
        except OSError:
            continue
        for node_name in node_names:
            private_events_path = os.path.join(
                staging_dir, node_name, "planner-events.ndjson"
            )
            if not os.path.isfile(private_events_path):
                continue
            try:
                with open(private_events_path, "r", encoding="utf-8") as stream:
                    for line in stream:
                        try:
                            event = json.loads(line)
                        except (TypeError, json.JSONDecodeError):
                            continue
                        if isinstance(event, dict) and event.get("type") == "runner.completed":
                            private_runner_events.append(event)
            except OSError:
                continue

# Strategy-selected reason counts from the event log (existing field retained).
reason_counts = {}
for ev in events:
    if ev.get("type") != "context.strategy_selected":
        continue
    data = data_object(ev)
    bump(reason_counts, str(data.get("reason", "")) or "none")

# Role and ceremony accounting (0.21.0). Every provider invocation leaves a
# runner-result sidecar (singular.orchestration.runner-result.v0) with its role,
# outcome, failure class and, when the provider reports it, token usage. Those
# sidecars are the only complete record of what the model calls were spent on;
# the field audit that found 88% of invocations going to planners and critics
# had to reconstruct this by hand. Scan them (bounded, read-only) so the
# question "what fraction of model work was ceremony?" is one command.
CONTROL_PLANE_ROLES = {"planner", "critic", "auditor", "decider", "supervisor", "assistant"}
role_stats = {}
runner_results_scanned = 0
if runs_dir and os.path.isdir(runs_dir):
    for dirpath, dirnames, filenames in os.walk(runs_dir):
        # Attempt archives duplicate live sidecars; count each invocation once.
        dirnames[:] = [d for d in dirnames if d not in ("attempts", "worker-evidence")]
        for name in filenames:
            if "runner-result" not in name or not name.endswith(".json"):
                continue
            record = read_json(os.path.join(dirpath, name))
            if not isinstance(record, dict) or record.get("schema") != "singular.orchestration.runner-result.v0":
                continue
            runner_results_scanned += 1
            role = str(record.get("role") or "unknown")
            stats = role_stats.setdefault(role, {
                "invocations": 0,
                "outcomes": {},
                "failureClasses": {},
                "usageRecords": 0,
                "inputTokens": 0,
                "cachedInputTokens": 0,
                "outputTokens": 0,
            })
            stats["invocations"] += 1
            bump(stats["outcomes"], str(record.get("outcome") or "unknown"))
            bump(stats["failureClasses"], str(record.get("failureClass") or "none"))
            usage = record.get("usage")
            if isinstance(usage, dict):
                stats["usageRecords"] += 1
                for key in ("inputTokens", "cachedInputTokens", "outputTokens"):
                    value = usage.get(key)
                    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
                        stats[key] += value
control_invocations = sum(v["invocations"] for k, v in role_stats.items() if k in CONTROL_PLANE_ROLES)
implementer_invocations = sum(v["invocations"] for k, v in role_stats.items() if k == "implementer")
model_invocations = sum(v["invocations"] for v in role_stats.values())
control_input = sum(v["inputTokens"] for k, v in role_stats.items() if k in CONTROL_PLANE_ROLES)
implementer_input = sum(v["inputTokens"] for k, v in role_stats.items() if k == "implementer")
total_input = sum(v["inputTokens"] for v in role_stats.values())
integrations = sum(1 for ev in events if ev.get("type") == "integration.integrated")
accepted = sum(1 for ev in events if ev.get("type") == "l1.task_accepted")
ceremony = {
    "runnerResultsScanned": runner_results_scanned,
    "modelInvocations": model_invocations,
    "controlPlaneInvocations": control_invocations,
    "implementerInvocations": implementer_invocations,
    "controlPlaneInvocationFraction": (
        round(control_invocations / model_invocations, 4) if model_invocations else None),
    "controlPlaneInputTokens": control_input,
    "implementerInputTokens": implementer_input,
    "controlPlaneInputTokenFraction": (
        round(control_input / total_input, 4) if total_input else None),
    "acceptedTasks": accepted,
    "integrations": integrations,
    "invocationsPerAcceptedTask": (
        round(model_invocations / accepted, 2) if accepted else None),
    "invocationsPerIntegration": (
        round(model_invocations / integrations, 2) if integrations else None),
    "inputTokensPerIntegration": (
        round(total_input / integrations) if integrations and total_input else None),
}

metrics = {
    "schema": "singular.orchestration.ctx-metrics.v0",
    "perTask": per_task_list,
    "aggregate": {
        "roles": role_stats,
        "ceremony": ceremony,
        "runsTotal": len(per_task_list),
        "attemptsTotal": attempts_total,
        "acceptedRuns": accepted_runs,
        "failureClassCounts": agg_failure,
        "auditVerdictCounts": agg_verdict,
        "workerStrategyCounts": agg_worker,
        "reviewerStrategyCounts": agg_reviewer,
        "deciderAuthorityCounts": agg_authority,
        "strategySelectedReasonCounts": reason_counts,
        "campaign": campaign_metrics(events, events_readable, private_runner_events),
    },
}
json.dump(metrics, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
}
