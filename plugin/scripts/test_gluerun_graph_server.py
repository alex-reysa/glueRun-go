#!/usr/bin/env python3
"""Unit tests for the read-only session-terminal log parsing in gluerun_graph_server.

These cover the *pure* parsing layer — classify_codex_record, parse_log_lines,
and the byte-cursor read_log_window — with no orchestration repo required. Run:

    python3 -m unittest scripts.test_gluerun_graph_server
    python3 scripts/test_gluerun_graph_server.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

import gluerun_graph_server as srv

# Every module global apply_console_adapter may mutate — tests that apply an
# adapter snapshot these first and restore them afterwards so the rest of the
# suite keeps seeing the pristine built-ins.
ADAPTER_GLOBALS = [
    "CONSOLE_ADAPTER", "ROLE_CATALOG", "ROLE_PROMPT_MAP", "EVENT_MAP", "NOISE_EVENT_TYPES",
    "TASK_ID_RE", "NODE_ID_RE", "AREA_ID_RE",
    "_PLANNER_AREA_RE", "_PLANNER_NODE_RE", "_PLANNER_STAGE_RE", "_PLANNER_LAYER_RE",
    "SETTINGS_SPEC", "DAG_REL", "STAGE_DOC_REL", "GATES_REL", "TASKS_DIR_REL", "AREAS_DIR_REL",
    "STATE_DIR_REL", "EVENTS_LOG_REL", "AUTONOMATE_LOG_REL", "STATUS_REL", "CIRCUIT_REL",
    "STOP_REL", "ORCH_SCRIPTS_REL", "PLATFORM_VISION_REL", "CONSOLE_COMMANDS",
    "PROCESS_MATCHERS", "CODEX_LOG_NAMES", "PLAIN_LOG_NAMES", "SETTINGS_SOURCE",
]

# The engine event types that must arrive via the adapter ONLY (the built-in
# EVENT_MAP must not gain them).
NEW_ENGINE_EVENT_TYPES = [
    "context.strategy_selected", "context.resume_failed", "findings.ledger_updated",
    "l1.attempt_archived", "audit.infra_retry", "worker.infra_retry",
    "decider.fast_path", "l1.preflight_failed",
]


def apply_adapter_with_restore(testcase: unittest.TestCase, adapter: dict) -> None:
    saved = {name: getattr(srv, name) for name in ADAPTER_GLOBALS}

    def restore() -> None:
        for name, val in saved.items():
            setattr(srv, name, val)

    testcase.addCleanup(restore)
    srv.apply_console_adapter(adapter)


class ClassifyCodexRecordTests(unittest.TestCase):
    def test_agent_message_completed(self) -> None:
        rec = srv.classify_codex_record(
            {"type": "item.completed", "item": {"id": "item_0", "type": "agent_message", "text": "  hello  "}}
        )
        self.assertEqual(rec, {"kind": "message", "role": "agent", "id": "item_0",
                               "text": "hello", "truncated": False})

    def test_agent_message_started_is_dropped(self) -> None:
        # item.started agent_message carries no text yet — should be dropped.
        self.assertIsNone(srv.classify_codex_record(
            {"type": "item.started", "item": {"id": "item_0", "type": "agent_message"}}))

    def test_agent_message_truncation(self) -> None:
        big = "x" * (srv.AGENT_MSG_CAP + 50)
        rec = srv.classify_codex_record(
            {"type": "item.completed", "item": {"type": "agent_message", "text": big}})
        self.assertTrue(rec["truncated"])
        self.assertEqual(len(rec["text"]), srv.AGENT_MSG_CAP)

    def test_command_execution_completed(self) -> None:
        rec = srv.classify_codex_record({
            "type": "item.completed",
            "item": {"id": "item_1", "type": "command_execution",
                     "command": "go test ./...", "aggregated_output": "ok\n",
                     "exit_code": 0, "status": "completed"},
        })
        self.assertEqual(rec["kind"], "command")
        self.assertEqual(rec["command"], "go test ./...")
        self.assertEqual(rec["exitCode"], 0)
        self.assertEqual(rec["status"], "completed")
        self.assertEqual(rec["output"], "ok\n")

    def test_command_execution_started_in_progress(self) -> None:
        rec = srv.classify_codex_record({
            "type": "item.started",
            "item": {"id": "item_1", "type": "command_execution",
                     "command": "sleep 1", "aggregated_output": "", "exit_code": None,
                     "status": "in_progress"},
        })
        self.assertEqual(rec["status"], "in_progress")
        self.assertIsNone(rec["exitCode"])

    def test_command_output_tail_capped(self) -> None:
        out = "L" * (srv.CMD_OUTPUT_CAP + 200)
        rec = srv.classify_codex_record({
            "type": "item.completed",
            "item": {"type": "command_execution", "command": "x", "aggregated_output": out, "exit_code": 0},
        })
        self.assertTrue(rec["outputTruncated"])
        self.assertEqual(len(rec["output"]), srv.CMD_OUTPUT_CAP)

    def test_file_change(self) -> None:
        rec = srv.classify_codex_record({
            "type": "item.completed",
            "item": {"id": "item_25", "type": "file_change", "status": "completed",
                     "changes": [{"path": "/a/b/foo.go", "kind": "add"}]},
        })
        self.assertEqual(rec["kind"], "file")
        self.assertEqual(rec["changes"], [{"path": "/a/b/foo.go", "kind": "add"}])

    def test_turn_completed_usage(self) -> None:
        rec = srv.classify_codex_record({"type": "turn.completed", "usage": {"output_tokens": 24196}})
        self.assertEqual(rec["kind"], "meta")
        self.assertIn("24196", rec["text"])

    def test_thread_and_turn_started(self) -> None:
        self.assertEqual(srv.classify_codex_record({"type": "thread.started"})["text"], "thread started")
        self.assertEqual(srv.classify_codex_record({"type": "turn.started"})["text"], "turn started")

    def test_orchestration_event_line(self) -> None:
        rec = srv.classify_codex_record(
            {"ts": "2026-06-04T15:00:35Z", "type": "l1.dispatch_started",
             "message": "l1 dispatch started", "data": {"taskId": "TASK-0477"}})
        self.assertEqual(rec["kind"], "event")
        self.assertEqual(rec["eventType"], "l1.dispatch_started")
        self.assertEqual(rec["ts"], "2026-06-04T15:00:35Z")
        self.assertEqual(rec["text"], "l1 dispatch started")


class ParseLogLinesTests(unittest.TestCase):
    def test_mixed_worker_log(self) -> None:
        lines = [
            '{"type":"thread.started","thread_id":"abc"}',
            '{"type":"turn.started"}',
            '2026-06-04T14:25:45.962429Z  WARN codex_core::exec: transient retry on tool call',
            '{"type":"item.completed","item":{"type":"agent_message","text":"Doing TDD."}}',
            '{"type":"item.completed","item":{"id":"item_1","type":"command_execution",'
            '"command":"go test","aggregated_output":"ok","exit_code":0,"status":"completed"}}',
            '',  # blank lines dropped
        ]
        recs = srv.parse_log_lines(lines)
        kinds = [r["kind"] for r in recs]
        self.assertEqual(kinds, ["meta", "meta", "log", "message", "command"])
        warn = recs[2]
        self.assertEqual(warn["level"], "WARN")
        self.assertEqual(warn["ts"], "2026-06-04T14:25:45.962429Z")
        self.assertTrue(warn["text"].startswith("codex_core::exec"))

    def test_planner_batch_agent_message(self) -> None:
        payload = json.dumps({"schema": "gluerun.orchestration.task-batch.v0", "tasks": [{"taskId": "TASK-0475"}]})
        line = json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": payload}})
        recs = srv.parse_log_lines([line])
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]["kind"], "message")
        self.assertIn("task-batch.v0", recs[0]["text"])

    def test_raw_mode_returns_verbatim(self) -> None:
        lines = ['{"type":"turn.started"}', "plain text line"]
        recs = srv.parse_log_lines(lines, raw=True)
        self.assertTrue(all(r["kind"] == "log" for r in recs))
        self.assertEqual(recs[0]["text"], '{"type":"turn.started"}')

    def test_malformed_json_falls_back_to_log(self) -> None:
        recs = srv.parse_log_lines(['{"type": broken'])
        self.assertEqual(recs[0]["kind"], "log")
        self.assertEqual(recs[0]["text"], '{"type": broken')

    def test_plain_line_without_iso_prefix(self) -> None:
        recs = srv.parse_log_lines(["last_message=/path/to/file"])
        self.assertEqual(recs[0], {"kind": "log", "text": "last_message=/path/to/file"})

    def test_codex_loader_noise_dropped_in_parsed_kept_in_raw(self) -> None:
        noise = "2026-06-04T14:25:53Z  WARN codex_core_skills::loader: ignoring interface.icon_small: x"
        manifest = "2026-06-04T14:25:45Z  WARN codex_core_plugins::manifest: ignoring interface.defaultPrompt[0]"
        signal = '{"type":"item.completed","item":{"type":"agent_message","text":"real work"}}'
        parsed = srv.parse_log_lines([noise, manifest, signal])
        self.assertEqual([r["kind"] for r in parsed], ["message"])  # both WARNs dropped
        raw = srv.parse_log_lines([noise, manifest, signal], raw=True)
        self.assertEqual(len(raw), 3)  # raw keeps every line verbatim
        self.assertTrue(all(r["kind"] == "log" for r in raw))


class ReadLogWindowTests(unittest.TestCase):
    def _write(self, text: str) -> Path:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".log", delete=False)
        tmp.write(text)
        tmp.flush()
        tmp.close()
        path = Path(tmp.name)
        self.addCleanup(path.unlink)
        return path

    def test_initial_tail_then_forward_advances(self) -> None:
        path = self._write("line1\nline2\nline3\n")
        first = srv.read_log_window(path, None)
        self.assertEqual(first["rawLines"], ["line1", "line2", "line3"])
        self.assertEqual(first["cursor"], first["size"])
        self.assertFalse(first["reset"])
        # No new bytes -> empty, cursor stable (idempotent follow poll).
        again = srv.read_log_window(path, first["cursor"])
        self.assertEqual(again["rawLines"], [])
        self.assertEqual(again["cursor"], first["cursor"])

    def test_forward_read_picks_up_appended_lines(self) -> None:
        path = self._write("a\nb\n")
        first = srv.read_log_window(path, None)
        with path.open("a") as fh:
            fh.write("c\nd\n")
        nxt = srv.read_log_window(path, first["cursor"])
        self.assertEqual(nxt["rawLines"], ["c", "d"])
        self.assertEqual(nxt["cursor"], nxt["size"])

    def test_trailing_partial_line_not_consumed(self) -> None:
        path = self._write("complete\npartial-no-newline")
        win = srv.read_log_window(path, None)
        # Only the newline-terminated line is consumed; the cursor stops before
        # the partial tail so the next poll re-reads it once it completes.
        self.assertEqual(win["rawLines"], ["complete"])
        self.assertLess(win["cursor"], win["size"])
        # Complete the partial line, then the next forward read yields it.
        with path.open("a") as fh:
            fh.write("-done\n")
        nxt = srv.read_log_window(path, win["cursor"])
        self.assertEqual(nxt["rawLines"], ["partial-no-newline-done"])

    def test_stale_cursor_resets_to_tail(self) -> None:
        path = self._write("x\ny\nz\n")
        win = srv.read_log_window(path, 10_000_000)
        self.assertTrue(win["reset"])
        self.assertEqual(win["rawLines"], ["x", "y", "z"])

    def test_oversized_single_line_is_skipped(self) -> None:
        # A single line longer than the window must not stall the cursor forever.
        path = self._write("Z" * 5000)
        win = srv.read_log_window(path, 0, max_bytes=1024)
        self.assertEqual(win["cursor"], 1024)
        self.assertTrue(win["rawLines"][0].startswith("[line too long"))

    def test_missing_file(self) -> None:
        win = srv.read_log_window(Path("/no/such/file.log"), None)
        self.assertEqual(win["rawLines"], [])
        self.assertEqual(win["size"], 0)

    def test_unicode_line_separators_do_not_oversplit(self) -> None:
        # A JSON record whose text contains a literal U+2028 / NEL must stay ONE
        # physical line — only \n terminates a record (str.splitlines would split here).
        payload = '{"type":"item.completed","item":{"type":"agent_message","text":"a bc"}}'
        path = self._write(payload + "\n")
        win = srv.read_log_window(path, None)
        self.assertEqual(len(win["rawLines"]), 1)
        recs = srv.parse_log_lines(win["rawLines"])
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]["kind"], "message")
        self.assertIn(" ", recs[0]["text"])


class PlannerPromptTests(unittest.TestCase):
    def test_parses_area_node_stage_layer(self) -> None:
        text = (
            "# L1 Area Planner Prompt\n\n"
            "You are the glueRun-go Area Planner for area `workflow`. You keep going.\n\n"
            "Executable DAG node: `D2.service`\nStage: `D2`\nLayer: `service`\n"
        )
        info = srv._parse_planner_prompt(text)
        self.assertEqual(info, {"area": "workflow", "node": "D2.service", "stage": "D2", "layer": "service"})

    def test_missing_fields_are_none(self) -> None:
        self.assertEqual(srv._parse_planner_prompt("nothing here"),
                         {"area": None, "node": None, "stage": None, "layer": None})


class WorkerStateTests(unittest.TestCase):
    def test_terminal_lease_statuses_win(self) -> None:
        self.assertEqual(srv._worker_state("blocked", None, True, True), "blocked")
        self.assertEqual(srv._worker_state("failed", None, True, True), "failed")
        self.assertEqual(srv._worker_state("accepted", None, True, True), "awaiting")
        self.assertEqual(srv._worker_state("integrated", None, True, True), "integrated")

    def test_running_lease_active_while_worktree_backs_it(self) -> None:
        # A running worker stays active through a long quiet model turn (stale log)
        # as long as its worktree is present; only a vanished worktree reads stale.
        self.assertEqual(srv._worker_state("running", None, False, True), "active")
        self.assertEqual(srv._worker_state("running", None, True, False), "active")
        self.assertEqual(srv._worker_state("running", None, False, False), "stale")

    def test_no_lease_uses_packet_and_freshness(self) -> None:
        self.assertEqual(srv._worker_state(None, "needs-review", False, False), "awaiting")
        self.assertEqual(srv._worker_state(None, None, True, False), "active")
        self.assertEqual(srv._worker_state(None, None, False, False), "stale")


# --------------------------------------------------------------------------- #
# Provenance pure-parser tests                                                  #
# --------------------------------------------------------------------------- #

def _ev(etype, ts, **data):
    return {"type": etype, "ts": ts, "message": etype, "data": data}


class ProjectEventTests(unittest.TestCase):
    def test_worker_failure_toned_red_with_reason(self) -> None:
        row = srv.project_event(_ev("l1.worker_completed", "2026-06-05T10:00:00Z",
                                    runId="RUN-1", exitCode=1, failure="no state packet"))
        self.assertEqual(row["tone"], "red")
        self.assertFalse(row["advancing"])
        self.assertIn("exited 1", row["label"])
        self.assertEqual(row["reason"], "no state packet")

    def test_worker_success_is_advancing_forest(self) -> None:
        row = srv.project_event(_ev("l1.worker_completed", "t", runId="RUN-1", exitCode=0))
        self.assertEqual(row["tone"], "forest")
        self.assertTrue(row["advancing"])
        self.assertIsNone(row["reason"])

    def test_integration_label_carries_merge_commit(self) -> None:
        row = srv.project_event(_ev("integration.integrated", "t", taskId="TASK-1",
                                    mergeCommit="db81fc7edb285", branch="agent/x"))
        self.assertEqual(row["tone"], "violet")
        self.assertIn("db81fc7", row["label"])

    def test_audit_non_accepted_is_amber(self) -> None:
        row = srv.project_event(_ev("l1.audit_completed", "t", verdict="needs-fix"))
        self.assertEqual(row["tone"], "amber")
        self.assertFalse(row["advancing"])

    def test_node_suffix_appended(self) -> None:
        row = srv.project_event(_ev("planner.staged", "t", node="D6.storage_spec", taskId="TASK-9"))
        self.assertTrue(row["label"].endswith("D6.storage_spec"))
        self.assertEqual(row["nodeId"], "D6.storage_spec")

    def test_unknown_type_falls_back_to_message(self) -> None:
        row = srv.project_event({"type": "weird.thing", "ts": "t", "message": "hi", "data": {}})
        self.assertEqual(row["tone"], "gray")
        self.assertEqual(row["label"], "hi")


class BuildEventsIndexTests(unittest.TestCase):
    def _lines(self):
        return [
            json.dumps(_ev("planner.generated", "t1", taskId="TASK-1", node="D1.contract", runId="O-1")),
            json.dumps(_ev("integration.skipped", "t2", taskId="TASK-1")),   # noise
            json.dumps(_ev("l1.dispatch_started", "t3", taskId="TASK-1", branch="agent/a", runId="R-1")),
            json.dumps(_ev("integration.integrated", "t4", branch="agent/a", mergeCommit="abc1234")),
            "not json",
        ]

    def test_buckets_and_noise_dropped(self) -> None:
        idx = srv.build_events_index(self._lines())
        self.assertIn("TASK-1", idx["by_task"])
        self.assertEqual(len(idx["by_task"]["TASK-1"]), 2)          # skipped dropped
        self.assertIn("agent/a", idx["by_branch"])
        self.assertIn("D1.contract", idx["by_node"])
        types = [r["type"] for r in idx["tail_rows"]]
        self.assertNotIn("integration.skipped", types)


class BuildOriginChainTests(unittest.TestCase):
    def test_orders_by_phase_when_ts_tie(self) -> None:
        # All same second; must still read in lifecycle order via phase rank.
        evs = [
            _ev("l1.committed", "2026-06-05T10:00:00Z", runId="R"),
            _ev("planner.generated", "2026-06-05T10:00:00Z", runId="O", node="D1.contract"),
            _ev("l1.dispatch_started", "2026-06-05T10:00:00Z", runId="R", branch="b"),
        ]
        chain = srv.build_origin_chain(evs)
        self.assertEqual([c["type"] for c in chain],
                         ["planner.generated", "l1.dispatch_started", "l1.committed"])

    def test_branch_integration_folded_in_and_deduped(self) -> None:
        task_evs = [_ev("l1.dispatch_started", "t1", taskId="T", branch="agent/a", runId="R")]
        branch_evs = [
            _ev("integration.integrated", "t9", branch="agent/a", mergeCommit="deadbeef"),
            _ev("integration.integrated", "t9", branch="agent/a", mergeCommit="deadbeef"),  # dup
        ]
        chain = srv.build_origin_chain(task_evs, branch_evs, "agent/a")
        integ = [c for c in chain if c["type"] == "integration.integrated"]
        self.assertEqual(len(integ), 1)
        self.assertEqual(integ[0]["extra"]["mergeCommit"], "deadbeef")


class ResolveProvenanceLinkTests(unittest.TestCase):
    def test_events_confidence(self) -> None:
        evs = [
            _ev("planner.generated", "t", node="D6.storage_spec", runId="O-1"),
            _ev("l1.dispatch_started", "t", runId="R-1", branch="agent/x", batchId="O-1-batch"),
        ]
        link = srv.resolve_task_provenance_link(evs, {"runId": "R-9"})
        self.assertEqual(link["linkConfidence"], "events")
        self.assertEqual(link["parentNode"], "D6.storage_spec")
        self.assertEqual(link["stage"], "D6")
        self.assertEqual(link["workerRunId"], "R-1")
        self.assertEqual(link["plannerRunId"], "O-1")

    def test_lease_confidence_when_no_node_event(self) -> None:
        link = srv.resolve_task_provenance_link([], {"runId": "R-1", "batchId": "B-1", "branch": "b"})
        self.assertEqual(link["linkConfidence"], "lease")
        self.assertIsNone(link["parentNode"])
        self.assertEqual(link["workerRunId"], "R-1")

    def test_none_confidence(self) -> None:
        link = srv.resolve_task_provenance_link([], None)
        self.assertEqual(link["linkConfidence"], "none")


class ParsePlannerBatchTests(unittest.TestCase):
    def test_title_match(self) -> None:
        batch = {"tasks": [
            {"taskId": "TASK-0001", "markdown": "# TASK-0001: Recovery plan storage\n..."},
            {"taskId": "TASK-0002", "markdown": "# TASK-0002: Replay result deviation storage specification\n..."},
        ]}
        m = srv.parse_planner_batch(batch, "Replay result deviation storage specification")
        self.assertEqual(m["localId"], "TASK-0002")
        self.assertEqual(m["candidateCount"], 2)

    def test_no_match_returns_count_only(self) -> None:
        batch = {"tasks": [{"taskId": "TASK-0001", "markdown": "# TASK-0001: Something else\n"}]}
        m = srv.parse_planner_batch(batch, "Totally different title")
        self.assertIsNone(m["localId"])
        self.assertEqual(m["candidateCount"], 1)


class ParseDagTests(unittest.TestCase):
    def setUp(self) -> None:
        self.reg = srv.parse_dag({"nodes": [
            {"id": "D1.contract", "stage": "D1", "area": "artifact", "layer": "contract"},
            {"id": "S0.storage_substrate_base", "stage": "S0", "area": "storage", "layer": "base"},
        ]})

    def test_indexes(self) -> None:
        self.assertIn("D1.contract", self.reg["by_id"])
        self.assertEqual(len(self.reg["by_area"]["artifact"]), 1)
        self.assertEqual(len(self.reg["by_stage"]["S0"]), 1)

    def test_node_id_validity_and_traversal_rejection(self) -> None:
        self.assertTrue(srv.node_id_valid("D1.contract", self.reg))
        self.assertTrue(srv.node_id_valid("S0.storage_substrate_base", self.reg))
        self.assertFalse(srv.node_id_valid("../etc/passwd", self.reg))
        self.assertFalse(srv.node_id_valid("D1/contract", self.reg))
        self.assertFalse(srv.node_id_valid("D9.unknown", self.reg))  # well-formed but absent


class StageCardTests(unittest.TestCase):
    DOC = ("# Plan\n## 7. Stage Cards\n"
           "### D0: Shared Kernel Spine\nD0 body line\nmore D0\n"
           "### D1: Artifact Kernel\nD1 body line\n"
           "## 8. Next\n").splitlines()

    def test_finds_card_and_stops_at_next_heading(self) -> None:
        card = srv.find_stage_card(self.DOC, "D0")
        self.assertEqual(card["section"], "D0: Shared Kernel Spine")
        self.assertIn("D0 body line", card["text"])
        self.assertNotIn("D1 body", card["text"])

    def test_no_card_returns_none(self) -> None:
        self.assertIsNone(srv.find_stage_card(self.DOC, "S0"))

    def test_hash_stable_and_sensitive(self) -> None:
        h1 = srv.stage_section_hash("abc")
        self.assertEqual(h1, srv.stage_section_hash("abc"))
        self.assertNotEqual(h1, srv.stage_section_hash("abc "))
        self.assertTrue(h1.startswith("sha256:"))

    def test_build_source_refs_shape_and_s0_empty(self) -> None:
        node = {"stage": "D1", "description": "Artifact stuff.", "requiredCompletion": "contract_complete"}
        refs = srv.build_source_refs(node, self.DOC)
        self.assertEqual(len(refs), 1)
        self.assertEqual(refs[0]["document"], srv.STAGE_DOC_REL)
        self.assertIn("contract_complete", refs[0]["reason"])
        self.assertTrue(refs[0]["contentHash"].startswith("sha256:"))
        s0 = srv.build_source_refs({"stage": "S0", "description": "x"}, self.DOC)
        self.assertEqual(s0, [])


class SynthesizeGateBlockingTests(unittest.TestCase):
    def test_passed_has_empty_reason(self) -> None:
        out = srv.synthesize_gate_blocking({"status": "passed"}, set())
        self.assertEqual(out["reason"], "")

    def test_blocked_lists_missing_and_upstream(self) -> None:
        gate = {"status": "blocked", "rationale": "closeout incomplete",
                "upstreamGates": ["D0.contract"],
                "evidence": [{"kind": "task-set", "taskIds": ["TASK-1", "TASK-2"]}]}
        out = srv.synthesize_gate_blocking(gate, {"TASK-1"}, {"D0.contract": "blocked"})
        self.assertIn("TASK-2", out["missingTaskIds"])
        self.assertIn("TASK-1", out["acceptedTaskIds"])
        self.assertIn("D0.contract", out["upstreamBlockers"])
        self.assertIn("blocked", out["reason"].lower())

    def test_absent_stale_invalid(self) -> None:
        self.assertIn("No promotion", srv.synthesize_gate_blocking({"status": "absent"}, set())["reason"])
        self.assertIn("stale", srv.synthesize_gate_blocking({"status": "stale"}, set())["reason"])
        self.assertIn("invalid", srv.synthesize_gate_blocking({"status": "invalid"}, set())["reason"])

    def test_none_gate(self) -> None:
        out = srv.synthesize_gate_blocking(None, set())
        self.assertIn("No gate result", out["reason"])


class DetectDuplicateTasksTests(unittest.TestCase):
    def test_identical_owned_files_flagged(self) -> None:
        leases = [
            {"taskId": "TASK-A", "area": "binding", "status": "integrated",
             "ownedFiles": ["x.go", "x_test.go"], "updatedAt": "2026-01-01"},
            {"taskId": "TASK-B", "area": "binding", "status": "superseded",
             "ownedFiles": ["x.go", "x_test.go"], "updatedAt": "2026-01-02"},
        ]
        dups = srv.detect_duplicate_tasks(leases)
        self.assertIn("TASK-B", dups)
        self.assertEqual(dups["TASK-B"]["duplicateOf"], "TASK-A")
        self.assertEqual(dups["TASK-B"]["confidence"], "high")
        self.assertNotIn("TASK-A", dups)

    def test_distinct_files_no_flag(self) -> None:
        leases = [
            {"taskId": "TASK-A", "area": "binding", "status": "integrated", "ownedFiles": ["a.go"]},
            {"taskId": "TASK-B", "area": "binding", "status": "integrated", "ownedFiles": ["b.go"]},
        ]
        self.assertEqual(srv.detect_duplicate_tasks(leases), {})


class EventsOverlayTests(unittest.TestCase):
    def test_bounded_read_types_filter_and_noise(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / ".gluerun-state").mkdir()
            (repo / "docs/orchestration").mkdir(parents=True)
            (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps(
                {"nodes": [{"id": "D1.contract", "stage": "D1", "area": "artifact"}]}))
            lines = [
                json.dumps(_ev("integration.skipped", "t0", taskId="T0")),       # dropped
                json.dumps(_ev("planner.generated", "t1", taskId="T1", node="D1.contract")),
                json.dumps(_ev("l1.committed", "t2", taskId="T1", headSha="abcdef0")),
            ]
            (repo / ".gluerun-state/events.ndjson").write_text("\n".join(lines) + "\n")
            # no filter: noise excluded, area resolved for node rows
            res = srv.collect_events_overlay(repo, None, 100, None)
            types = [r["type"] for r in res["rows"]]
            self.assertNotIn("integration.skipped", types)
            row = [r for r in res["rows"] if r["type"] == "planner.generated"][0]
            self.assertEqual(row["areaId"], "artifact")
            # types filter keeps only the requested type
            only = srv.collect_events_overlay(repo, None, 100, {"l1.committed"})
            self.assertEqual([r["type"] for r in only["rows"]], ["l1.committed"])
            self.assertEqual(res["cursor"], res["size"])


class PlanOverviewTests(unittest.TestCase):
    def test_parse_shell_default(self) -> None:
        text = 'GLUERUN_CODEX_MODEL="${GLUERUN_CODEX_MODEL:-gpt-5.5}"\n' \
               'GLUERUN_MAX_DISPATCH="${GLUERUN_MAX_DISPATCH:-$max_concurrent}"\n' \
               'GLUERUN_L2_SLICE_BUDGET="${GLUERUN_L2_SLICE_BUDGET:-1}"\n'
        self.assertEqual(srv.parse_shell_default(text, "GLUERUN_CODEX_MODEL"), "gpt-5.5")
        self.assertEqual(srv.parse_shell_default(text, "GLUERUN_MAX_DISPATCH"), "$max_concurrent")
        self.assertEqual(srv.parse_shell_default(text, "GLUERUN_L2_SLICE_BUDGET"), "1")
        self.assertIsNone(srv.parse_shell_default(text, "GLUERUN_NOT_PRESENT"))

    def test_compute_plan_progress(self) -> None:
        registry = srv.parse_dag({"nodes": [
            {"id": "D0.contract", "stage": "D0", "area": "kernel", "layer": "contract"},
            {"id": "D1.contract", "stage": "D1", "area": "artifact", "layer": "contract"},
            {"id": "D1.service", "stage": "D1", "area": "artifact", "layer": "service"},
            {"id": "S0.base", "stage": "S0", "area": "storage", "layer": "base"},
        ]})
        gates = {"D0.contract": "passed", "D1.contract": "passed", "S0.base": "passed"}
        progress, stages, frontier = srv.compute_plan_progress(registry, gates)
        self.assertEqual(progress, {"passedNodes": 3, "totalNodes": 4, "pct": 75})
        d1 = [s for s in stages if s["stage"] == "D1"][0]
        self.assertEqual((d1["passed"], d1["total"], d1["status"]), (1, 2, "active"))
        # D0/S0 complete; ordering puts D-stages before S-stages
        self.assertEqual([s["stage"] for s in stages], ["D0", "D1", "S0"])
        self.assertEqual([f["nodeId"] for f in frontier], ["D1.service"])

    def test_collect_settings_typed_shape(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            orch = repo / "scripts" / "orchestration"
            orch.mkdir(parents=True)
            (orch / "lib.sh").write_text(
                'GLUERUN_L2_SLICE_BUDGET="${GLUERUN_L2_SLICE_BUDGET:-2}"\n'
                'GLUERUN_ENABLE_L1_PARALLEL="${GLUERUN_ENABLE_L1_PARALLEL:-0}"\n'
            )
            (orch / "autonomate.sh").write_text(
                'export GLUERUN_AUTO_INTEGRATE="${GLUERUN_AUTO_INTEGRATE:-1}"\n'
            )
            (orch / "codex-run.sh").write_text("")
            (orch / "reconcile.sh").write_text("")
            groups = srv.collect_settings(repo)
            # every group carries title + category alias + layout
            self.assertTrue(all(g["title"] == g["category"] and "layout" in g for g in groups))
            self.assertEqual(groups[0]["layout"], "matrix")  # models group
            flat = {it["envKey"]: it for g in groups for it in g["items"]}
            # parsed default wins over fallback; metadata is carried through
            self.assertEqual(flat["GLUERUN_L2_SLICE_BUDGET"]["value"], "2")
            self.assertEqual(flat["GLUERUN_L2_SLICE_BUDGET"]["kind"], "count")
            # duration unit is split OUT of the label, not baked in parens
            loop = flat["GLUERUN_MAX_HOURS"]
            self.assertEqual((loop["unit"], loop["label"]), ("h", "loop budget"))
            # booleans expose boolValue, never rendered as raw 0/1 downstream
            self.assertIs(flat["GLUERUN_ENABLE_L1_PARALLEL"]["boolValue"], False)
            self.assertIs(flat["GLUERUN_AUTO_INTEGRATE"]["boolValue"], True)
            # derived dispatch stays an honest non-resolved string
            self.assertEqual(flat["GLUERUN_MAX_DISPATCH"]["kind"], "derived")
            self.assertEqual(flat["GLUERUN_MAX_DISPATCH"]["value"], "follows max concurrent")
            # every item carries meaning help text
            self.assertTrue(all(isinstance(it["meaning"], str) for it in flat.values()))

    def test_compute_loop_pulse(self) -> None:
        import json as _json
        now = srv._iso_to_epoch("2026-06-05T21:00:00Z")
        ev = lambda t, **d: _json.dumps({"type": t, "ts": d.pop("ts"), "data": d})
        lines = [
            ev("planner.generated", ts="2026-06-05T20:55:00Z", taskId="T1", area="evidence"),
            ev("planner.generated", ts="2026-06-05T20:54:00Z", taskId="T2", area="recovery"),
            ev("integration.integrated", ts="2026-06-05T20:58:00Z", taskId="T2"),
            ev("integration.integrated", ts="2026-06-05T20:59:00Z", taskId="T1"),  # newest advance
            ev("integration.integrated", ts="2026-06-05T11:00:00Z", taskId="T0"),  # old, out of window
        ]
        index = srv.build_events_index(lines)
        registry = srv.parse_dag({"nodes": [
            {"id": "D5.x", "stage": "D5", "area": "evidence", "layer": "service"},
            {"id": "D6.y", "stage": "D6", "area": "recovery", "layer": "service"},
            {"id": "S0.base", "stage": "S0", "area": "storage", "layer": "base"},
        ]})
        gates = {"S0.base": "passed"}  # D5.x / D6.y absent => frontier
        pulse, activity = srv.compute_loop_pulse(index, registry, gates, now)
        # newest advance is T1 (evidence) -> active area; old T0 excluded from the 1h window
        self.assertEqual(pulse["activeArea"], "evidence")
        self.assertEqual(pulse["recentIntegrations"], 2)
        self.assertEqual(pulse["lastIntegrationAt"], "2026-06-05T20:59:00Z")
        # frontier areas only (storage/S0 passed is dropped); evidence flagged active + has throughput
        areas = {a["area"]: a for a in activity}
        self.assertEqual(set(areas), {"evidence", "recovery"})
        self.assertTrue(areas["evidence"]["active"])
        self.assertEqual(areas["evidence"]["recentIntegrations"], 1)
        self.assertFalse(areas["recovery"]["active"])
        self.assertEqual([n["id"] for n in areas["evidence"]["nodes"]], ["D5.x"])

    def test_parse_status_md(self) -> None:
        text = ("# glueRun-go Autonomous Status\nUpdated: 2026-06-05T13:28:30Z\nIteration: 6\n"
                "Note: stopped (STOP sentinel)\nSTOP requested: yes\n"
                "- branch: `codex/gluerun-bootstrap-target` @ `c0d342d`\n"
                "- ready tasks: 5\n- active leases: 0\n- imported packets: 536\n"
                "- integrations (lifetime): 535\n- parked escalations (lifetime): 71\n"
                "- circuit-breaker consecutive failures: 0 / 5\n")
        s = srv.parse_status_md(text)
        self.assertEqual(s["iteration"], 6)
        self.assertEqual(s["note"], "stopped (STOP sentinel)")
        self.assertTrue(s["stopRequested"])
        self.assertEqual(s["integrationsLifetime"], 535)
        self.assertEqual(s["parkedLifetime"], 71)
        self.assertEqual(s["branch"], "codex/gluerun-bootstrap-target")
        self.assertEqual(s["breaker"], "0 / 5")


# --------------------------------------------------------------------------- #
# Console adapter tests (C1/C2/C3)                                              #
# --------------------------------------------------------------------------- #

class ConsoleAdapterPrecedenceTests(unittest.TestCase):
    """repo override > engine-shipped > built-in, merged per top-level KEY."""

    def _fixture(self, base: Path) -> tuple[Path, Path]:
        repo = base / "repo"
        (repo / "docs/orchestration").mkdir(parents=True)
        engine = base / "engine-home"
        (engine / "plugin/adapters").mkdir(parents=True)
        return repo, engine

    def test_per_key_precedence_repo_over_engine_over_builtin(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo, engine = self._fixture(Path(d))
            # (b) engine-shipped: provides commands AND noiseEventTypes
            (engine / "plugin/adapters/console-adapter.v0.json").write_text(json.dumps({
                "schema": "gluerun.console-adapter.v0",
                "commands": {"status": ["gluerun", "status"]},
                "noiseEventTypes": ["engine.noise"],
            }))
            # (a2) repo adapter file: provides noiseEventTypes only
            (repo / "docs/orchestration/console-adapter.json").write_text(json.dumps({
                "noiseEventTypes": ["repo.noise"],
            }))
            # (a1) inline console block: provides commands only
            (repo / "gluerun.config.json").write_text(json.dumps({
                "schemaVersion": "v0",
                "console": {"commands": {"status": ["custom", "status"]}},
            }))
            merged = srv.load_console_adapter(repo, str(engine))
            builtin = srv.builtin_console_adapter()
            # commands: inline repo block wins over the engine layer
            self.assertEqual(merged["commands"], {"status": ["custom", "status"]})
            # noiseEventTypes: repo file wins over the engine layer
            self.assertEqual(merged["noiseEventTypes"], ["repo.noise"])
            # untouched keys fall through to built-in
            self.assertEqual(merged["rolePromptMap"], builtin["rolePromptMap"])
            self.assertEqual(merged["paths"], builtin["paths"])
            # applying merges dict-valued keys over the built-in (per-key merge:
            # a repo that only overrides `commands.status` keeps everything else)
            apply_adapter_with_restore(self, merged)
            self.assertEqual(srv.CONSOLE_COMMANDS["status"], ["custom", "status"])
            self.assertEqual(srv.CONSOLE_COMMANDS["nextArea"], ["make", "orch-next-area"])
            self.assertEqual(srv.NOISE_EVENT_TYPES, {"repo.noise"})

    def test_engine_layer_alone_and_builtin_fallthrough(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo, engine = self._fixture(Path(d))
            (engine / "plugin/adapters/console-adapter.v0.json").write_text(json.dumps({
                "commands": {"status": ["gluerun", "status"]},
            }))
            merged = srv.load_console_adapter(repo, str(engine))
            self.assertEqual(merged["commands"], {"status": ["gluerun", "status"]})
            # no adapter at all -> pure built-in document
            none = srv.load_console_adapter(repo, None)
            self.assertEqual(none, srv.builtin_console_adapter())

    def test_schema_version_selects_engine_adapter_file(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo, engine = self._fixture(Path(d))
            (repo / "gluerun.config.json").write_text(json.dumps({"schemaVersion": "v1"}))
            (engine / "plugin/adapters/console-adapter.v0.json").write_text(json.dumps({
                "commands": {"status": ["wrong", "file"]}}))
            (engine / "plugin/adapters/console-adapter.v1.json").write_text(json.dumps({
                "commands": {"status": ["right", "file"]}}))
            merged = srv.load_console_adapter(repo, str(engine))
            self.assertEqual(merged["commands"], {"status": ["right", "file"]})

    def test_malformed_layer_warns_and_falls_through(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo, engine = self._fixture(Path(d))
            (engine / "plugin/adapters/console-adapter.v0.json").write_text("{not json")
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                merged = srv.load_console_adapter(repo, str(engine))
            self.assertIn("malformed", err.getvalue())
            self.assertEqual(merged, srv.builtin_console_adapter())

    def test_bad_key_keeps_builtin_for_that_key_only(self) -> None:
        bad = dict(srv.builtin_console_adapter())
        bad["idPatterns"] = {"task": "(unbalanced", "node": "x", "area": "y"}
        bad["commands"] = {"status": ["gluerun", "status"]}
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            apply_adapter_with_restore(self, bad)
        self.assertIn("idPatterns", err.getvalue())
        self.assertEqual(srv.TASK_ID_RE.pattern, r"^TASK-\d+$")  # built-in kept
        self.assertEqual(srv.CONSOLE_COMMANDS["status"], ["gluerun", "status"])  # good key applied


class TargetBranchFlowTests(unittest.TestCase):
    """C4: a config-driven targetBranch flows into env injection, the drift
    check, and the snapshot — never the baked-in default."""

    def test_config_branch_flows_to_env_drift_and_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / "gluerun.config.json").write_text(json.dumps(
                {"targetBranch": "custom/integration"}))
            self.assertEqual(srv.load_repo_target_branch(repo), "custom/integration")
            saved = srv.TARGET_BRANCH
            self.addCleanup(lambda: setattr(srv, "TARGET_BRANCH", saved))
            srv.TARGET_BRANCH = srv.load_repo_target_branch(repo)  # what main() does
            # subprocess env injection
            res = srv.run_command(repo, ["sh", "-c", 'printf %s "$GLUERUN_TARGET_BRANCH"'])
            self.assertEqual(res["stdout"], "custom/integration")
            # drift check + snapshot field
            saved_procs = srv.collect_processes
            self.addCleanup(lambda: setattr(srv, "collect_processes", saved_procs))
            srv.collect_processes = lambda: []
            snap = srv.collect_snapshot(repo)
            self.assertEqual(snap["targetBranch"], "custom/integration")
            self.assertEqual(
                snap["git"]["drift"]["raw"]["cmd"],
                ["git", "rev-list", "--left-right", "--count",
                 "origin/custom/integration...custom/integration"])


class CliProjectFixtureTests(unittest.TestCase):
    """C3: a CLI project (no Makefile, no scripts/orchestration) with
    GLUERUN_ENGINE_HOME + the shipped v0 adapter gets gluerun commands and reads its
    settings defaults from the engine's own scripts."""

    SHIPPED_ADAPTER = Path(srv.__file__).resolve().parent.parent / "adapters/console-adapter.v0.json"

    def test_gluerun_commands_and_engine_settings_source(self) -> None:
        if not self.SHIPPED_ADAPTER.is_file():
            # The standalone plugin copy ships the console adapterless (the engine
            # owns plugin/adapters/); skip rather than error when it isn't co-located.
            self.skipTest(f"shipped adapter not co-located: {self.SHIPPED_ADAPTER}")
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            repo = base / "cli-project"
            repo.mkdir()
            (repo / "gluerun.config.json").write_text(json.dumps(
                {"schemaVersion": "v0", "targetBranch": "main"}))
            engine = base / "engine-home"
            (engine / "plugin/adapters").mkdir(parents=True)
            (engine / "plugin/adapters/console-adapter.v0.json").write_text(
                self.SHIPPED_ADAPTER.read_text())
            (engine / "engine").mkdir()
            (engine / "engine/lib.sh").write_text(
                'GLUERUN_MAX_CONCURRENT="${GLUERUN_MAX_CONCURRENT:-4}"\n')
            (engine / "engine/codex-run.sh").write_text("")
            (engine / "engine/reconcile.sh").write_text("")
            (engine / "engine/autonomate.sh").write_text("")
            saved_env = os.environ.get("GLUERUN_ENGINE_HOME")

            def restore_env() -> None:
                if saved_env is None:
                    os.environ.pop("GLUERUN_ENGINE_HOME", None)
                else:
                    os.environ["GLUERUN_ENGINE_HOME"] = saved_env

            self.addCleanup(restore_env)
            os.environ["GLUERUN_ENGINE_HOME"] = str(engine)
            apply_adapter_with_restore(self, srv.load_console_adapter(repo, str(engine)))
            # commands are the gluerun CLI equivalents, not make orch-* targets
            self.assertEqual(srv.CONSOLE_COMMANDS["status"], ["gluerun", "status"])
            self.assertEqual(srv.CONSOLE_COMMANDS["validateDag"], ["gluerun", "validate-dag"])
            self.assertEqual(srv.console_command("areaGate", node="D1.contract"),
                             ["gluerun", "area-gate", "D1.contract"])
            # settings source resolves to the engine's scripts via the template
            self.assertEqual(srv.SETTINGS_SOURCE, "{engineHome}/engine")
            self.assertEqual(srv.resolve_settings_dir(repo), engine / "engine")
            flat = {it["envKey"]: it for g in srv.collect_settings(repo) for it in g["items"]}
            self.assertEqual(flat["GLUERUN_MAX_CONCURRENT"]["value"], "4")
            # the new engine event types arrive via the shipped adapter
            for etype in NEW_ENGINE_EVENT_TYPES:
                self.assertIn(etype, srv.EVENT_MAP)
            row = srv.project_event(_ev("context.strategy_selected", "t", taskId="TASK-1"))
            self.assertEqual(row["label"], "Context strategy selected")

    def test_settings_source_engine_home_fallback_without_adapter(self) -> None:
        # No adapter, but GLUERUN_ENGINE_HOME set -> engine/*.sh; unset -> legacy repo dir.
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            saved_env = os.environ.get("GLUERUN_ENGINE_HOME")

            def restore_env() -> None:
                if saved_env is None:
                    os.environ.pop("GLUERUN_ENGINE_HOME", None)
                else:
                    os.environ["GLUERUN_ENGINE_HOME"] = saved_env

            self.addCleanup(restore_env)
            os.environ["GLUERUN_ENGINE_HOME"] = "/opt/gluerun-engine"
            self.assertEqual(srv.resolve_settings_dir(repo), Path("/opt/gluerun-engine/engine"))
            os.environ.pop("GLUERUN_ENGINE_HOME", None)
            self.assertEqual(srv.resolve_settings_dir(repo), repo / "scripts/orchestration")


class UnknownEventTypeRenderingTests(unittest.TestCase):
    def test_builtin_event_map_does_not_gain_new_engine_types(self) -> None:
        for etype in NEW_ENGINE_EVENT_TYPES:
            self.assertNotIn(etype, srv.builtin_console_adapter()["eventMap"])

    def test_unknown_types_in_events_ndjson_render_gracefully(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / ".gluerun-state").mkdir()
            lines = [json.dumps(_ev(t, "2026-06-09T00:00:00Z", taskId="TASK-1"))
                     for t in NEW_ENGINE_EVENT_TYPES + ["totally.unknown_type"]]
            (repo / ".gluerun-state/events.ndjson").write_text("\n".join(lines) + "\n")
            res = srv.collect_events_overlay(repo, None, 100, None)  # must not raise
            self.assertEqual(len(res["rows"]), len(lines))
            by_type = {r["type"]: r for r in res["rows"]}
            for etype in NEW_ENGINE_EVENT_TYPES + ["totally.unknown_type"]:
                row = by_type[etype]
                # sane default: message text as label, muted tone, control phase
                self.assertEqual(row["label"], etype)  # _ev sets message=etype
                self.assertEqual(row["tone"], "gray")
                self.assertEqual(row["phase"], "control")
                self.assertFalse(row["advancing"])


class NoAdapterSnapshotIdentityTests(unittest.TestCase):
    """HARD back-compat gate: with no adapter resolvable, the key endpoint
    payloads must be deep-equal to those produced by the committed (HEAD)
    server run as a module against the same fixture."""

    FIXED_NOW = "2026-06-09T12:00:00Z"
    FIXED_DISK = {"df": {"ok": True}, "du": {"ok": True},
                  "capacityPercent": 50, "free": "100Gi", "watch": False}

    def _build_fixture(self, repo: Path) -> None:
        (repo / "docs/orchestration/tasks").mkdir(parents=True)
        (repo / "docs/orchestration/gates").mkdir(parents=True)
        (repo / "docs/orchestration/areas/artifact").mkdir(parents=True)
        (repo / ".gluerun-state/leases").mkdir(parents=True)
        (repo / "scripts/orchestration").mkdir(parents=True)
        (repo / "gluerun.config.json").write_text(json.dumps(
            {"schemaVersion": "v0", "targetBranch": "agent/integration"}))
        (repo / "docs/orchestration/tasks/TASK-0001.md").write_text(
            "# TASK-0001: Sample slice\n"
            "Status: integrated\nArea: artifact\nTarget Branch: `agent/integration`\n"
            "Worker Branch: `agent/task-0001`\nTest Policy: `test-first`\n"
            "Gate Command: `go test ./...`\nDepends On: []\n\n"
            "## Objective\nDo a sample thing.\n\n## Acceptance Criteria\n- it works\n")
        (repo / "docs/orchestration/areas/artifact/state.md").write_text("# artifact\n")
        (repo / ".gluerun-state/leases/TASK-0001.json").write_text(json.dumps({
            "taskId": "TASK-0001", "status": "integrated", "owner": "l2-developer",
            "runId": "RUN-1", "area": "artifact", "branch": "agent/task-0001",
            "worktree": str(repo / ".worktrees/none"), "updatedAt": "2026-06-08T10:00:00Z",
            "ownedFiles": ["a.go"]}))
        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps({"nodes": [
            {"id": "D0.contract", "stage": "D0", "area": "kernel", "layer": "contract",
             "description": "Kernel contract.", "requiredCompletion": "contract_complete"},
            {"id": "D1.contract", "stage": "D1", "area": "artifact", "layer": "contract",
             "description": "Artifact contract.", "requiredCompletion": "contract_complete",
             "dependsOn": ["D0.contract"]}]}))
        (repo / "docs/orchestration/gates/D0.contract.gate-result.json").write_text(
            json.dumps({"node": "D0.contract", "status": "passed", "authoritative": True,
                        "evidence": [{"kind": "task-set", "taskIds": ["TASK-0001"]}]}))
        (repo / "docs/plan-and-dag.md").write_text(
            "# Plan\n## 7. Stage Cards\n### D0: Kernel\nD0 body\n### D1: Artifact\nD1 body\n")
        events = [
            _ev("planner.generated", "2026-06-08T09:00:00Z", taskId="TASK-0001",
                node="D1.contract", runId="ORIGIN-1", area="artifact"),
            _ev("l1.dispatch_started", "2026-06-08T09:01:00Z", taskId="TASK-0001",
                runId="RUN-1", branch="agent/task-0001"),
            _ev("integration.skipped", "2026-06-08T09:02:00Z", taskId="TASK-0001"),
            _ev("integration.integrated", "2026-06-08T09:03:00Z", taskId="TASK-0001",
                branch="agent/task-0001", mergeCommit="abc1234def"),
            # unknown-to-the-built-in type: both servers must degrade identically
            _ev("worker.infra_retry", "2026-06-08T09:04:00Z", taskId="TASK-0001"),
        ]
        (repo / ".gluerun-state/events.ndjson").write_text(
            "\n".join(json.dumps(e) for e in events) + "\n")
        (repo / ".gluerun-state/autonomate.out.log").write_text("loop line 1\nloop line 2\n")
        (repo / ".gluerun-state/STATUS.md").write_text(
            "# glueRun-go Autonomous Status\nUpdated: 2026-06-08T10:00:00Z\nIteration: 3\n"
            "Note: running\n- ready tasks: 1\n- integrations (lifetime): 12\n")
        (repo / ".gluerun-state/circuit.json").write_text(json.dumps({"consecFails": 0}))
        (repo / "scripts/orchestration/lib.sh").write_text(
            'GLUERUN_MAX_CONCURRENT="${GLUERUN_MAX_CONCURRENT:-2}"\n'
            'GLUERUN_TARGET_BRANCH="${GLUERUN_TARGET_BRANCH:-agent/integration}"\n')
        (repo / ".gluerun-state/.env").write_text("GLUERUN_SLEEP=5\nDATABASE_URL=secret\n")

    def _load_head_module(self, tmp: Path):
        root = Path(srv.__file__).resolve().parents[2]
        proc = subprocess.run(
            ["git", "-C", str(root), "show", "HEAD:plugin/scripts/gluerun_graph_server.py"],
            capture_output=True, text=True)
        if proc.returncode != 0:
            self.skipTest(f"cannot read HEAD server from git: {proc.stderr.strip()}")
        path = tmp / "gluerun_graph_server_head.py"
        path.write_text(proc.stdout)
        spec = importlib.util.spec_from_file_location("gluerun_graph_server_head", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def _pin(self, mod) -> None:
        """Pin the only honestly-volatile inputs (clock, live ps, live df/du)
        identically in a module; everything else must match for real."""
        mod.utc_now = lambda: self.FIXED_NOW
        mod.collect_processes = lambda: []
        mod.collect_disk = lambda repo: dict(self.FIXED_DISK)

    def test_key_endpoints_identical_to_head_without_adapter(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            repo = base / "repo"
            repo.mkdir()
            self._build_fixture(repo)
            saved_env = os.environ.pop("GLUERUN_ENGINE_HOME", None)
            if saved_env is not None:
                self.addCleanup(lambda: os.environ.__setitem__("GLUERUN_ENGINE_HOME", saved_env))
            head = self._load_head_module(base)
            saved = {n: getattr(srv, n) for n in
                     ("utc_now", "collect_processes", "collect_disk", "TARGET_BRANCH")}
            self.addCleanup(lambda: [setattr(srv, n, v) for n, v in saved.items()])
            self._pin(srv)
            self._pin(head)
            # mirror main() startup for both servers; no adapter is resolvable here
            srv.TARGET_BRANCH = srv.load_repo_target_branch(repo)
            apply_adapter_with_restore(self, srv.load_console_adapter(repo, None))
            head.TARGET_BRANCH = head.load_repo_target_branch(repo)

            def wire(payload) -> str:  # exactly what send_json serializes
                return json.dumps(payload, indent=2)

            # /api/state is intentionally NOT compared since 0.5.0: the built-in
            # probes went native (no make orch-* subprocesses), gateD0/gateD1
            # were replaced by orchestration.gates, and disk.du became a
            # non-blocking background peek — see NativeFrontierTests /
            # ValidateDagNativeTests / SnapshotNoSubprocessTests below.
            # /api/overview (includes settings groups)
            self.assertEqual(wire(srv.collect_overview(repo)), wire(head.collect_overview(repo)))
            self.assertEqual(wire(srv.collect_settings(repo)), wire(head.collect_settings(repo)))
            # /api/events live overlay
            self.assertEqual(wire(srv.collect_events_overlay(repo, None, 120, None)),
                             wire(head.collect_events_overlay(repo, None, 120, None)))
            # /api/task detail
            self.assertEqual(wire(srv.collect_task_detail(repo, "TASK-0001")),
                             wire(head.collect_task_detail(repo, "TASK-0001")))
            # /api/roles static catalog
            self.assertEqual(wire(srv.ROLE_CATALOG), wire(head.ROLE_CATALOG))


class ProcessMatcherSemanticsTests(unittest.TestCase):
    """The matcher rewrite must filter ps output exactly like the inline checks."""

    PS = "\n".join([
        "  PID  PPID COMMAND",
        "  100     1 bash scripts/orchestration/autonomate.sh",
        "  101     1 codex --cd /x/GLUERUN exec something",
        "  102     1 python3 plugin/scripts/gluerun_graph_server.py --repo .",   # excluded
        "  103     1 rg --files",                                            # not matched
        "  104     1 bash /repo/.worktrees/task-1/run.sh",
        "  105     1 some autonomate thing | Cursor Helper",                 # excluded (lowered)
    ])

    def test_filtering_matches_legacy_semantics(self) -> None:
        saved = srv.run_command
        self.addCleanup(lambda: setattr(srv, "run_command", saved))
        srv.run_command = lambda repo, cmd, timeout=5: {"ok": True, "stdout": self.PS}
        rows = srv.collect_processes()
        pids = [r["pid"] for r in rows]
        self.assertEqual(pids, ["100", "101", "104"])


class NativeFrontierTests(unittest.TestCase):
    """O1 (0.5.0): compute_frontier_native must replicate `engine/dag.sh
    next-areas` exactly — file-order iteration, passed+authoritative completes,
    blocked+authoritative excludes, all-deps-gated joins the frontier."""

    ENTRY_KEYS = {"node", "stage", "area", "layer", "kind", "requiredCompletion"}

    def _node(self, node_id: str, deps: list[str]) -> dict:
        return {"id": node_id, "stage": node_id.split(".")[0], "area": "core",
                "layer": "contract", "kind": "build", "dependsOn": deps,
                "requiredCompletion": "done"}

    def _write_dag(self, repo: Path, nodes: list[dict]) -> None:
        (repo / "docs/orchestration/gates").mkdir(parents=True, exist_ok=True)
        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps(
            {"schema": "gluerun.orchestration.dag.v0", "nodes": nodes}))

    def _gate(self, repo: Path, node_id: str, status: str, authoritative: bool = True) -> None:
        (repo / "docs/orchestration/gates" / f"{node_id}.gate-result.json").write_text(
            json.dumps({"node": node_id, "status": status, "authoritative": authoritative}))

    def test_membership_and_entry_shape(self) -> None:
        # 4 nodes: passed, ready, dep-blocked, authoritative-blocked.
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write_dag(repo, [
                self._node("D0.passed", []),
                self._node("D1.ready", ["D0.passed"]),
                self._node("D2.depblocked", ["D1.ready"]),
                self._node("D3.authblocked", []),
            ])
            self._gate(repo, "D0.passed", "passed")
            self._gate(repo, "D3.authblocked", "blocked")
            out = srv.compute_frontier_native(repo)
            self.assertEqual([f["node"] for f in out["frontier"]], ["D1.ready"])
            self.assertNotIn("allComplete", out)
            entry = out["frontier"][0]
            self.assertEqual(set(entry), self.ENTRY_KEYS)
            self.assertEqual(entry["stage"], "D1")
            self.assertEqual(entry["area"], "core")
            self.assertEqual(entry["requiredCompletion"], "done")

    def test_non_authoritative_blocked_stays_eligible(self) -> None:
        # dag.sh only excludes blocked gates that are ALSO authoritative.
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write_dag(repo, [self._node("D0.a", [])])
            self._gate(repo, "D0.a", "blocked", authoritative=False)
            out = srv.compute_frontier_native(repo)
            self.assertEqual([f["node"] for f in out["frontier"]], ["D0.a"])

    def test_all_complete(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write_dag(repo, [self._node("D0.a", []), self._node("D1.b", ["D0.a"])])
            self._gate(repo, "D0.a", "passed")
            self._gate(repo, "D1.b", "passed")
            out = srv.compute_frontier_native(repo)
            self.assertEqual(out, {"frontier": [], "allComplete": True})

    def test_unreadable_gate_json_reads_not_passed(self) -> None:
        # A corrupt gate file is not-passed (never raises): the node stays on the
        # frontier and its dependents stay excluded.
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write_dag(repo, [self._node("D0.a", []), self._node("D1.b", ["D0.a"])])
            (repo / "docs/orchestration/gates/D0.a.gate-result.json").write_text("{not json")
            out = srv.compute_frontier_native(repo)
            self.assertEqual([f["node"] for f in out["frontier"]], ["D0.a"])
            self.assertNotIn("allComplete", out)

    def test_passed_but_not_authoritative_does_not_complete(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write_dag(repo, [self._node("D0.a", []), self._node("D1.b", ["D0.a"])])
            self._gate(repo, "D0.a", "passed", authoritative=False)
            out = srv.compute_frontier_native(repo)
            # D0.a not complete (stays frontier-eligible); D1.b dep not gated.
            self.assertEqual([f["node"] for f in out["frontier"]], ["D0.a"])


class ValidateDagNativeTests(unittest.TestCase):
    """O1 (0.5.0): validate_dag_native structural checks + run_command envelope."""

    def _write(self, repo: Path, nodes: list[dict]) -> None:
        (repo / "docs/orchestration").mkdir(parents=True, exist_ok=True)
        (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps(
            {"schema": "gluerun.orchestration.dag.v0", "nodes": nodes}))

    def _node(self, node_id: str, deps: list[str]) -> dict:
        return {"id": node_id, "stage": "D0", "area": "core", "layer": "contract",
                "kind": "build", "dependsOn": deps, "requiredCompletion": "done"}

    def test_valid_dag_ok_envelope(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write(repo, [self._node("D0.a", []), self._node("D0.b", ["D0.a"])])
            out = srv.validate_dag_native(repo)
            self.assertEqual(out, {"ok": True, "exit": 0, "stdout": "ok", "stderr": "",
                                   "cmd": ["native:validate-dag"], "native": True})

    def test_duplicate_id_fails(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write(repo, [self._node("D0.a", []), self._node("D0.a", [])])
            out = srv.validate_dag_native(repo)
            self.assertFalse(out["ok"])
            self.assertEqual(out["exit"], 1)
            self.assertIn("duplicate node id: D0.a", out["stdout"])

    def test_unknown_dependency_fails(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            self._write(repo, [self._node("D0.a", ["D9.ghost"])])
            out = srv.validate_dag_native(repo)
            self.assertFalse(out["ok"])
            self.assertIn("unknown dependency for D0.a: D9.ghost", out["stdout"])

    def test_missing_required_fields_fail(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            node = self._node("D0.a", [])
            del node["layer"], node["kind"]
            self._write(repo, [node])
            out = srv.validate_dag_native(repo)
            self.assertFalse(out["ok"])
            self.assertIn("missing required fields: kind, layer", out["stdout"])

    def test_missing_dag_file_fails_soft(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            out = srv.validate_dag_native(Path(d))
            self.assertFalse(out["ok"])
            self.assertIn("missing or unreadable", out["stdout"])


class SnapshotNoSubprocessTests(unittest.TestCase):
    """O1 (0.5.0) hard guarantee: with the built-in (non-adapter) probe
    commands, collect_snapshot never shells out to make."""

    def test_collect_snapshot_runs_no_make(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / ".gluerun-state").mkdir()
            (repo / "docs/orchestration/tasks").mkdir(parents=True)
            (repo / "docs/orchestration/gates").mkdir(parents=True)
            (repo / "docs/orchestration/dag.v0.json").write_text(json.dumps({
                "schema": "gluerun.orchestration.dag.v0",
                "nodes": [{"id": "D0.a", "stage": "D0", "area": "core", "layer": "contract",
                           "kind": "build", "dependsOn": [], "requiredCompletion": "done"}]}))
            calls: list[list[str]] = []
            real_run = subprocess.run

            def recording_run(cmd, *args, **kwargs):
                calls.append([str(p) for p in cmd])
                return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="stubbed")

            saved = srv.subprocess.run
            self.addCleanup(lambda: setattr(srv.subprocess, "run", saved))
            srv.subprocess.run = recording_run
            snap = srv.collect_snapshot(repo)
            first_argv = [c[0] for c in calls if c]
            self.assertNotIn("make", first_argv)
            # sanity: the probes are the native envelopes, not subprocess runs
            self.assertTrue(snap["orchestration"]["status"].get("native"))
            self.assertTrue(snap["orchestration"]["validateDag"].get("native"))
            self.assertEqual(snap["orchestration"]["gates"],
                             {"passed": 0, "total": 1, "byNode": {"D0.a": "absent"}})
            self.assertEqual(
                [f["node"] for f in snap["orchestration"]["nextAreas"]["frontier"]], ["D0.a"])
            self.assertEqual(snap["orchestration"]["nextArea"]["node"], "D0.a")
            self.assertNotIn("gateD0", snap["orchestration"])
            self.assertNotIn("gateD1", snap["orchestration"])
            del real_run  # only kept for clarity: restoration goes through addCleanup


class SnapshotCacheStaleServeTests(unittest.TestCase):
    """O1 (0.5.0): a stale cache hit returns immediately (marked stale/computing)
    while one background refresh recomputes; the refreshed value then serves."""

    def test_stale_serve_then_background_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            release = threading.Event()
            counter = {"n": 0}

            def slow_snapshot(_repo):
                counter["n"] += 1
                if counter["n"] > 1:      # only refreshes block; the priming call is instant
                    release.wait(5)
                return {"n": counter["n"]}

            saved = srv.collect_snapshot
            self.addCleanup(lambda: setattr(srv, "collect_snapshot", saved))
            srv.collect_snapshot = slow_snapshot

            cache = srv.SnapshotCache(ttl=0.05)
            self.assertEqual(cache.get(repo), {"n": 1})    # cold start blocks + primes
            time.sleep(0.1)                                # expire the TTL

            t0 = time.monotonic()
            stale = cache.get(repo)                        # refresh is blocked on `release`
            self.assertLess(time.monotonic() - t0, 1.0, "stale get must not block")
            self.assertEqual(stale["n"], 1)
            self.assertTrue(stale["stale"])
            self.assertTrue(stale["computing"])
            self.assertIsInstance(stale["snapshotAgeSeconds"], int)

            release.set()
            deadline = time.monotonic() + 5
            current: dict = {}
            while time.monotonic() < deadline:
                current = cache.get(repo)
                if current.get("n", 0) >= 2 and not current.get("stale"):
                    break
                time.sleep(0.02)
            self.assertGreaterEqual(current.get("n", 0), 2, "background refresh never landed")
            self.assertNotIn("stale", current)
            self.assertIsNone(cache.last_error)

    def test_background_refresh_failure_recorded_not_raised(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            counter = {"n": 0}

            def flaky_snapshot(_repo):
                counter["n"] += 1
                if counter["n"] > 1:
                    raise RuntimeError("boom")
                return {"n": 1}

            saved = srv.collect_snapshot
            self.addCleanup(lambda: setattr(srv, "collect_snapshot", saved))
            srv.collect_snapshot = flaky_snapshot
            cache = srv.SnapshotCache(ttl=0.05)
            cache.get(repo)
            time.sleep(0.1)
            stale = cache.get(repo)     # kicks the failing refresh; must not raise
            self.assertTrue(stale["stale"])
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and cache.last_error is None:
                time.sleep(0.02)
            self.assertIn("boom", cache.last_error or "")
            self.assertIsNotNone(cache.age_seconds())


class DiskUsageCacheTests(unittest.TestCase):
    """O1 (0.5.0): the du walk lives in its own background cache; a cold peek
    never blocks on it."""

    def test_cold_peek_non_blocking_then_value_lands(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            release = threading.Event()

            def slow_du(_repo, cmd, timeout=60):
                release.wait(5)
                return {"ok": True, "exit": 0, "stdout": "du-output", "stderr": "", "cmd": cmd}

            saved = srv.run_command
            srv.run_command = slow_du
            try:
                cache = srv.DiskUsageCache(ttl=300)
                t0 = time.monotonic()
                cold = cache.peek(repo)
                self.assertLess(time.monotonic() - t0, 1.0, "cold peek must not block on du")
                self.assertEqual(cold, {"computing": True})
                release.set()
                deadline = time.monotonic() + 5
                value: dict = {}
                while time.monotonic() < deadline:
                    value = cache.peek(repo)
                    if "ageSeconds" in value:
                        break
                    time.sleep(0.02)
                self.assertEqual(value.get("stdout"), "du-output")
                self.assertIsInstance(value.get("ageSeconds"), int)
                self.assertNotIn("computing", value)  # fresh again after the refresh
            finally:
                srv.run_command = saved

    def test_stale_peek_returns_last_value_and_recomputes_once(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            release = threading.Event()
            counter = {"n": 0}

            def counting_du(_repo, cmd, timeout=60):
                counter["n"] += 1
                if counter["n"] > 1:
                    release.wait(5)
                return {"ok": True, "exit": 0, "stdout": f"du-{counter['n']}", "stderr": "", "cmd": cmd}

            saved = srv.run_command
            srv.run_command = counting_du
            try:
                cache = srv.DiskUsageCache(ttl=0.05)
                cache.peek(repo)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and cache.peek(repo) == {"computing": True}:
                    time.sleep(0.02)
                time.sleep(0.1)  # expire the TTL
                stale = cache.peek(repo)       # second compute blocks on `release`
                self.assertEqual(stale.get("stdout"), "du-1")
                self.assertTrue(stale.get("computing"))
                stale2 = cache.peek(repo)      # refresh already in flight: no second thread
                self.assertEqual(stale2.get("stdout"), "du-1")
                release.set()
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and cache.peek(repo).get("stdout") != "du-2":
                    time.sleep(0.02)
                self.assertEqual(cache.peek(repo).get("stdout"), "du-2")
            finally:
                release.set()
                srv.run_command = saved


class ProbeOverrideEscapeHatchTests(unittest.TestCase):
    """The adapter escape hatch: an explicitly configured probe command still
    runs as a subprocess; the pristine built-in resolves to native."""

    def test_builtin_commands_not_overridden(self) -> None:
        for name in ("status", "validateDag", "nextArea", "nextAreas"):
            self.assertFalse(srv.probe_command_overridden(name), name)

    def test_adapter_command_marks_probe_overridden(self) -> None:
        adapter = dict(srv.builtin_console_adapter())
        adapter["commands"] = {"status": ["gluerun", "status"]}
        apply_adapter_with_restore(self, adapter)
        self.assertTrue(srv.probe_command_overridden("status"))
        # deep-merged untouched keys remain built-in -> still native
        self.assertFalse(srv.probe_command_overridden("validateDag"))
        self.assertFalse(srv.probe_command_overridden("nextAreas"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
