"""Real runner publications over private v2 fixtures; no provider/native calls."""
import contextlib
import copy
import fcntl
import importlib
import json
import os
import signal
import time
import unittest
from unittest import mock

import test_execution_context as fixtures

R = importlib.import_module("codex_learner.runner_publication")
M = importlib.import_module("codex_learner.memory_proxy")
C, J, F, T = fixtures.C, fixtures.J, fixtures.F, fixtures.T
Q, P = R.coordinator, R.publication
SID, write_json = fixtures.SID, fixtures.write_json


class RunnerPublicationTests(unittest.TestCase):
    def setUp(self):
        # Composition deliberately avoids discovering the fixture's own tests.
        # Its subprocess, socket and SQLite guards remain enabled even in the
        # forked children. Only the read-only native scope probe is substituted.
        self.f = fixtures.ExecutionContextTests(methodName="runTest")
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.f.fence.close()
        from suite_support import fixture_spawn_gate
        gate = importlib.import_module("codex_learner.spawn_admission")
        self.enterContext(fixture_spawn_gate(gate, self.f.root / "gate"))
        (self.f.root / "runs").chmod(0o700)
        self.config = {"max_chars": 2000, "max_scan_bytes": 4096, "retry_seconds": 60}
        self.pending = self.f.root / "pending" / (SID + ".json")
        write_json(self.pending, self.f.request)
        self.service = R.Publications(self.f.root, self.f.config_path, self.f.plugin)
        self.paths = self.service.paths(SID)
        self.probe = mock.patch.object(R.operation_probe, "probe_scope", side_effect=self.scope)
        self.probe_mock = self.probe.start()
        self.addCleanup(self.probe.stop)
        status = mock.patch.object(R.operation_probe, "probe_statuses",
                                   side_effect=AssertionError("unexpected status probe"))
        self.status_probe_mock = status.start()
        self.addCleanup(status.stop)

    def scope(self, transport, *, writer_fence, expected_binding):
        self.assertTrue(writer_fence.verify(expected_binding))
        self.assertEqual(transport["command"], str(self.f.runtime))
        return copy.deepcopy(self.f.scope)

    @contextlib.contextmanager
    def locks(self):
        with contextlib.ExitStack() as stack:
            for name in ("worker.lock", "enqueue.lock"):
                fd = os.open(self.f.root / name, os.O_RDWR | os.O_CREAT, 0o600)
                stack.callback(os.close, fd)
                fcntl.flock(fd, fcntl.LOCK_EX)
                stack.callback(fcntl.flock, fd, fcntl.LOCK_UN)
            yield

    def begin(self):
        with self.locks():
            return self.service.begin(self.f.request, self.f.state, self.f.excerpt, self.config)

    def empty(self, *, records=True):
        with self.f.path.open("r+b") as stream:
            stream.truncate(self.f.frontier)
            stream.seek(self.f.frontier)
            if records:
                stream.write(J.encode({"type": "turn_context", "payload": {"turn_id": "next-turn"}}) + b"\n")
                stream.write(J.encode({"type": "event_msg", "payload": {
                    "type": "agent_reasoning", "text": "PRIVATE excluded text"}}) + b"\n")
        return T.read_excerpt(self.f.path, self.f.frontier, stable_identity=True,
                              max_chars=self.config["max_chars"], max_scan_bytes=self.config["max_scan_bytes"])

    def parser(self, excerpt):
        with self.locks():
            return self.service.parser(self.f.request, self.f.state, excerpt,
                C._next_parser(excerpt), self.config, reason="no_visible_content")

    def current(self):
        return tuple(path.read_bytes() if path.exists() else None
                     for path in (self.f.state_path, self.f.record_path, self.pending))

    def proxy_config(self, execution):
        manifest, _ = J.read_manifest(execution.paths.run_dir)
        backend = J._json(J._unseal(manifest["inputs"]["backend_config"]))
        return {"execution": execution.specification(), "transport": execution.context.transport,
                "audit_path": str(execution.paths.run_dir / "mcp-audit.jsonl"),
                "provenance": "codex-session:" + SID, "max_tool_calls": 10, "max_writes": 3,
                "allowed_tools": sorted(R.memory_config.allowed_tools(backend["memory"], M.ALLOWED_TOOLS))}

    def recover(self):
        with self.locks():
            return self.service.recover(SID, self.config)

    def finish(self, execution):
        with self.locks():
            return self.service.finish(execution, self.config)

    def provider_files(self, execution, *, kind="read", observation=True, success=True):
        """Synthetic process facts plus real proxy/gateway intent/receipt files.

        No provider/native code runs. The process guards inherited from the base
        fixture remain enabled. Only the native reply itself is synthetic.
        """
        run = execution.paths.run_dir
        R.settlement.record_provider_dispatch(run, execution.context.manifest_sha256,
            lambda manifest, phase: execution.context.validate_inputs(manifest, "before_forward"))
        audit = [{"event": "relay_started"}]
        memories = []
        if kind == "read":
            audit.extend([{"event": "tool_call", "id": 1, "tool": "recall"},
                          {"event": "tool_result", "id": 1, "tool": "recall", "ok": True,
                           "memory_ids": [], "forwarded": True}])
        else:
            with contextlib.ExitStack() as cleanup:
                gateway, fence, _ = M.durable_execution(self.proxy_config(execution), cleanup)
                operation, message = gateway.prepare(1, "remember", {
                    "content": "PRIVATE exact fixture mutation", "source": "codex-session:" + SID,
                    "is_private": True})
                self.assertEqual(message["params"]["name"], "operation_apply")
                audit.append({"event": "tool_call", "id": 1, "tool": "remember"})
                if kind == "unresolved":
                    def absent(transport, *, recovery_fence, expected_binding, expected_scope,
                               requests, validate_inputs, limits=None):
                        self.assertEqual(recovery_fence.mode, "exclusive")
                        self.assertIs(recovery_fence.verify(expected_binding), True)
                        self.assertEqual(transport, execution.context.transport)
                        self.assertEqual(expected_scope, self.f.scope)
                        self.assertIs(validate_inputs("before_status_probe"), True)
                        responses = [{"kind": "absent", "operationID": request["operationID"],
                                      "scope": expected_scope} for request in requests]
                        for request, response in zip(requests, responses):
                            J._response(response, request, None)
                        return responses
                    self.status_probe_mock.side_effect = absent
                    audit.append({"event": "tool_result", "id": 1, "tool": "remember", "ok": False,
                                  "memory_ids": [], "forwarded": True})
                else:
                    memory = "a1111111-2222-4333-8444-555555555555"
                    receipt = {"version": 1, "operationID": operation, "scope": self.f.scope,
                               "payloadDigest": "d" * 64, "mutation": "remember", "outcome": kind,
                               "memoryIDs": [memory], "edgeIDs": [], "committedAt": 800000000.25}
                    value = {"version": 1, "kind": "committed", "receipt": receipt}
                    response = {"jsonrpc": "2.0", "id": 1, "result": {
                        "isError": False, "structuredContent": {"engram_operation": value},
                        "content": [{"type": "text", "text": J.encode({"engram_operation": value}).decode()}]}}
                    self.assertEqual(gateway.finish(operation, response), receipt)
                    memories = [memory] if kind == "applied" else []
                    audit.append({"event": "tool_result", "id": 1, "tool": "remember", "ok": True,
                                  "memory_ids": memories, "forwarded": True, "operation_version": 1,
                                  "operation_id": operation, "operation_outcome": kind,
                                  "operation_payload_digest": receipt["payloadDigest"]})
        audit.append({"event": "relay_finished", "child_reaped": True, "cleanup_overrun": False})
        R.durable._new(run / "mcp-audit.jsonl", b"".join(J.encode(item) + b"\n" for item in audit))
        R.durable._new(run / "result.json", J.encode({"outcome": "stored" if memories else "no_new_memories",
            "summary": "PRIVATE synthetic process result", "memory_ids": memories}))
        if observation:
            R.settlement.persist_observation(run, {
                "started": True, "terminated": True, "returncode": 0 if success else 1,
                "turn_completed": success, "provider_error": not success,
                "unexpected_tool": False, "tool_errors": int(kind == "unresolved"),
                "reason": None if success else "provider_failed"})
        return memories

    def kill_at(self, action, boundary):
        error_path = self.f.base / "child-error.txt"
        pid = os.fork()
        if pid == 0:
            try:
                def crash(label):
                    if label == boundary:
                        os.kill(os.getpid(), signal.SIGKILL)
                Q._boundary = crash
                P._boundary = crash
                result = action()
                if isinstance(result, R.Execution):
                    result.close()
                os._exit(3)  # The requested boundary must be reached.
            except BaseException as error:
                error_path.write_text(type(error).__name__ + ": " + str(error))
                os._exit(2)
        deadline = time.monotonic() + 15
        while True:
            reaped, status = os.waitpid(pid, os.WNOHANG)
            if reaped:
                break
            if time.monotonic() >= deadline:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
                self.fail("publication fixture deadline")
            time.sleep(0.01)
        detail = error_path.read_text() if error_path.exists() else "boundary was not reached"
        self.assertTrue(os.WIFSIGNALED(status), detail)
        self.assertEqual(os.WTERMSIG(status), signal.SIGKILL)

    def test_begin_preserves_cursor_pending_and_pins_proxy_authority(self):
        before = self.current()
        execution = self.begin()
        self.addCleanup(execution.close)
        self.assertEqual(self.probe_mock.call_count, 1)
        self.assertEqual(self.f.state_path.read_bytes(), before[0])
        self.assertEqual(self.pending.read_bytes(), before[2])
        manifest, digest = J.read_manifest(execution.paths.run_dir)
        self.assertEqual(J._unseal(manifest["inputs"]["cursor"]), before[0])
        self.assertEqual(manifest["expected_scope"], self.f.scope)
        record = json.loads(self.f.record_path.read_bytes())
        self.assertEqual(record["processing_execution"], {"run_id": execution.paths.run_dir.name, "manifest_sha256": digest})
        completed = Q.read_completed(self.paths, session_id=SID, **execution.marker)
        self.assertEqual(completed["completion"]["disposition"], "none")
        self.assertFalse((self.paths.session_directory / "active.json").exists())
        with contextlib.ExitStack() as cleanup:
            operations, held, transport = M.durable_execution(self.proxy_config(execution), cleanup)
            self.assertIsNotNone(operations)
            self.assertTrue(held.verify(manifest["fencing"]))
            self.assertEqual(transport, execution.context.transport)

    def test_proxy_cannot_raise_sealed_budgets_or_change_route(self):
        execution = self.begin()
        self.addCleanup(execution.close)
        original = self.proxy_config(execution)
        for changed in ({"max_tool_calls": 1000}, {"max_writes": 1000},
                        {"max_writes": True}, {"provenance": "other-session"},
                        {"audit_path": str(self.f.base / "unbound-audit")},
                        {"allowed_tools": []}):
            with self.subTest(changed=changed), contextlib.ExitStack() as cleanup:
                with self.assertRaises(M.ProxyError):
                    M.durable_execution({**original, **changed}, cleanup)
        self.assertFalse((execution.paths.run_dir / "mcp-audit.jsonl").exists())

    def test_same_id_pending_replacement_refuses_before_begin_or_parser_publication(self):
        for parser_only in (False, True):
            with self.subTest(parser_only=parser_only):
                self.setUp()
                excerpt = self.empty() if parser_only else self.f.excerpt
                write_json(self.pending, {**self.f.request, "turn_id": "changed-turn"})
                before = self.current()
                with self.assertRaisesRegex(ValueError, "request_changed_before"):
                    self.parser(excerpt) if parser_only else self.begin()
                self.assertEqual(self.current(), before)
                self.assertFalse((self.paths.session_directory / "active.json").exists())

    def test_changed_source_during_probe_refuses_before_processing(self):
        before = self.current()
        def changed(*args, **kwargs):
            self.f.path.write_bytes(self.f.path.read_bytes().replace(b"PRIVATE", b"CHANGED"))
            return self.scope(*args, **kwargs)
        self.probe_mock.side_effect = changed
        with self.assertRaises(ValueError):
            self.begin()
        self.assertEqual(self.current(), before)
        self.assertFalse((self.paths.session_directory / "active.json").exists())

    def test_parser_empty_eof_and_excluded_records_publish_without_probe(self):
        for records in (False, True):
            with self.subTest(records=records):
                self.setUp()
                excerpt = self.empty(records=records)
                result = self.parser(excerpt)
                self.assertEqual(result, "no_change")
                self.assertEqual(result.request_id, self.f.request["request_id"])
                self.assertEqual(C._parser_state(json.loads(self.f.state_path.read_bytes())), C._next_parser(excerpt))
                self.assertEqual(json.loads(self.f.record_path.read_bytes())["processing"], None)
                self.assertFalse(self.pending.exists())
                self.probe_mock.assert_not_called()

    def test_visible_text_cannot_take_parser_only_shortcut(self):
        before = self.current()
        with self.assertRaisesRegex(ValueError, "visible_content_not_covered"):
            self.parser(self.f.excerpt)
        self.assertEqual(self.current(), before)
        self.probe_mock.assert_not_called()

    def test_parser_partial_page_keeps_original_pending_for_continuation(self):
        self.empty()
        with self.f.path.open("rb") as stream:
            stream.seek(self.f.frontier)
            first_line_bytes = len(stream.readline())
        excerpt = T.read_excerpt(self.f.path, self.f.frontier, stable_identity=True,
                                 max_chars=self.config["max_chars"], max_scan_bytes=first_line_bytes)
        self.assertTrue(excerpt.has_more)
        self.assertFalse(excerpt.text)
        pending = self.pending.read_bytes()
        self.assertEqual(self.parser(excerpt), "more")
        self.assertEqual(self.pending.read_bytes(), pending)
        self.assertEqual(C._parser_state(json.loads(self.f.state_path.read_bytes())), C._next_parser(excerpt))
        self.assertFalse((self.paths.session_directory / "active.json").exists())
        self.probe_mock.assert_not_called()

    def test_begin_sigkill_preserves_cursor_and_queue_across_marker_boundaries(self):
        for phase in ("ticket_directory_fsynced", "index_created", "index_directory_fsynced",
                      "admission_replaced", "published_replaced", "processing_publication_installed",
                      "ack_intent_installed", "completion_installed", "active_unlinked"):
            with self.subTest(phase=phase):
                self.setUp()
                before = self.current()
                self.kill_at(self.begin, phase)
                if phase == "index_created":
                    with self.assertRaises(ValueError):
                        self.recover()
                else:
                    self.recover()
                if phase in {"ticket_directory_fsynced", "index_created"}:
                    self.assertEqual(self.current(), before)
                else:
                    state = json.loads(self.f.state_path.read_bytes())
                    self.assertEqual(C._parser_state(state), C._parser_state(self.f.state))
                    self.assertEqual(state["status"], "failed")
                    self.assertEqual(json.loads(self.f.record_path.read_bytes())["processing"], None)
                    self.assertEqual(json.loads(self.pending.read_bytes())["pause_reason"], "failed")
                    self.assertFalse((self.paths.session_directory / "active.json").exists())
                    run = self.f.root / "runs" / state["last_run"]
                    self.assertFalse((run / "provider-dispatch.json").exists())
                    self.assertEqual(json.loads((run / "settlement.json").read_bytes())["reason"], "never_dispatched")
                self.probe_mock.assert_not_called()  # Probe occurred only in killed child.

    def test_parser_sigkill_recovers_pair_and_queue_at_publication_boundaries(self):
        for phase in ("index_directory_fsynced", "admission_replaced", "state_replaced", "published_replaced",
                      "ack_intent_installed", "pending_mutated", "completion_installed", "active_unlinked"):
            with self.subTest(phase=phase):
                self.setUp()
                excerpt = self.empty()
                self.kill_at(lambda: self.parser(excerpt), phase)
                self.recover()
                self.assertEqual(C._parser_state(json.loads(self.f.state_path.read_bytes())), C._next_parser(excerpt))
                self.assertFalse(self.pending.exists())
                self.assertFalse((self.paths.session_directory / "active.json").exists())

    def test_published_parser_preserves_newer_enqueue_and_latest_event(self):
        excerpt = self.empty()
        self.kill_at(lambda: self.parser(excerpt), "published_replaced")
        self.f.append("PRIVATE newer text must remain queued")
        newer = {**self.f.request, "request_id": "newer-request", "turn_id": "newer-turn"}
        write_json(self.pending, newer)
        record = json.loads(self.f.record_path.read_bytes())
        write_json(self.f.record_path, {**record, "last_event": "b" * 64})
        before = self.current()
        result = self.recover()
        self.assertEqual(result, "no_change")
        self.assertEqual(self.current(), before)
        self.assertLess(json.loads(self.f.state_path.read_bytes())["offset"], self.f.path.stat().st_size)

    def test_published_parser_rejects_same_id_replacement_and_source_change(self):
        for tamper in ("pending", "source"):
            with self.subTest(tamper=tamper):
                self.setUp()
                excerpt = self.empty()
                self.kill_at(lambda: self.parser(excerpt), "published_replaced")
                if tamper == "pending":
                    write_json(self.pending, {**self.f.request, "turn_id": "changed-turn"})
                else:
                    self.f.path.write_bytes(self.f.path.read_bytes().replace(b"PRIVATE", b"CHANGED"))
                before = self.current()
                with self.assertRaises(ValueError):
                    self.recover()
                self.assertEqual(self.current(), before)
                self.assertTrue((self.paths.session_directory / "active.json").exists())

    def test_finish_applied_unchanged_and_read_only_require_real_settlement(self):
        for kind in ("applied", "unchanged", "read"):
            with self.subTest(kind=kind):
                self.setUp()
                execution = self.begin()
                self.addCleanup(execution.close)
                memories = self.provider_files(execution, kind=kind)
                run = execution.paths.run_dir
                dispatch = (run / "provider-dispatch.json").read_bytes()
                result = self.finish(execution)
                self.assertEqual(result, "succeeded")
                self.assertEqual(result.request_id, self.f.request["request_id"])
                state = json.loads(self.f.state_path.read_bytes())
                self.assertEqual(C._parser_state(state), C._next_parser(self.f.excerpt))
                self.assertEqual(state["status"], "succeeded")
                settled = json.loads((run / "settlement.json").read_bytes())
                self.assertEqual(settled["memory_ids"], memories)
                self.assertEqual(settled["applied_write_calls"], int(kind == "applied"))
                self.assertEqual(settled["unchanged_write_calls"], int(kind == "unchanged"))
                self.assertEqual(state["successful_coverage"]["receipt_sha256"],
                                 J.sha256((run / "successful-coverage.json").read_bytes()))
                self.assertFalse(self.pending.exists())
                self.assertIsNone(self.recover())
                self.assertEqual((run / "provider-dispatch.json").read_bytes(), dispatch)
                self.assertEqual(self.probe_mock.call_count, 1)
                self.status_probe_mock.assert_not_called()
                with contextlib.ExitStack() as cleanup, self.assertRaises(ValueError):
                    M.durable_execution(self.proxy_config(execution), cleanup)

    def test_public_recovery_settles_existing_run_without_second_provider(self):
        execution = self.begin()
        self.provider_files(execution, kind="applied")
        execution.close()
        run = execution.paths.run_dir
        retained = {p: p.read_bytes() for p in run.iterdir()
                    if p.name in R.settlement.FIXED or p.name.startswith("operation-")}
        result = self.recover()
        self.assertEqual(result, "succeeded")
        self.assertEqual(self.probe_mock.call_count, 1)
        for path, raw in retained.items():
            self.assertEqual(path.read_bytes(), raw)
        self.assertEqual(C._parser_state(json.loads(self.f.state_path.read_bytes())), C._next_parser(self.f.excerpt))
        self.assertIsNone(self.recover())

    def test_finish_failure_and_uncertainty_preserve_original_parser_and_receipts(self):
        for kind, observation, success, expected in (
            ("read", True, False, "failed"),
            ("applied", True, False, "reconciliation_required"),
            ("applied", False, True, "reconciliation_required"),
            ("unresolved", True, True, "failed"),
        ):
            with self.subTest(kind=kind, observation=observation, success=success):
                self.setUp()
                execution = self.begin()
                self.addCleanup(execution.close)
                memories = self.provider_files(execution, kind=kind, observation=observation, success=success)
                execution.close()
                result = self.recover()
                self.assertEqual(result, expected)
                state = json.loads(self.f.state_path.read_bytes())
                self.assertEqual(C._parser_state(state), C._parser_state(self.f.state))
                self.assertEqual(state["status"], expected)
                self.assertEqual(json.loads(self.pending.read_bytes())["pause_reason"], expected)
                self.assertFalse((execution.paths.run_dir / "successful-coverage.json").exists())
                if expected == "reconciliation_required":
                    self.assertEqual(state["reconciliation_required"]["memory_ids"], memories)
                self.assertEqual(self.probe_mock.call_count, 1)
                self.assertEqual(self.status_probe_mock.call_count, int(kind == "unresolved"))

    def test_proven_absent_failure_keeps_cursor_and_accepts_next_natural_event(self):
        runner = importlib.import_module("codex_learner.runner")
        execution = self.begin()
        self.addCleanup(execution.close)
        self.provider_files(execution, kind="unresolved", success=False)
        self.assertEqual(self.finish(execution), "failed")
        state = json.loads(self.f.state_path.read_bytes())
        self.assertEqual(C._parser_state(state), C._parser_state(self.f.state))
        self.assertNotIn("reconciliation_required", state)
        self.assertFalse((execution.paths.run_dir / "successful-coverage.json").exists())
        self.assertEqual(json.loads(self.pending.read_bytes())["pause_reason"], "failed")
        self.f.append("PRIVATE next natural turn remains eligible.")
        payload = {"session_id": SID, "transcript_path": str(self.f.path), "cwd": str(self.f.project),
                   "hook_event_name": "Stop", "turn_id": "next-natural-turn"}
        with mock.patch.object(runner, "event_log"):
            self.assertTrue(runner.enqueue(self.f.root, payload, spawn=False))
        pending = json.loads(self.pending.read_bytes())
        self.assertNotIn("pause_reason", pending)
        self.assertNotEqual(pending["request_id"], self.f.request["request_id"])
        self.assertEqual(C._parser_state(json.loads(self.f.state_path.read_bytes())), C._parser_state(state))
        # Actual process_request enforces the existing backoff before launching.
        with mock.patch.object(runner, "publications", return_value=self.service):
            with runner.lock_file(self.f.root / "worker.lock"):
                outcome = runner.process_request(self.f.root, pending,
                    {**runner.DEFAULTS, **self.config, "min_chars": 0},
                    invoke=mock.Mock(side_effect=AssertionError("backoff must not invoke provider")))
        self.assertEqual(outcome, "backoff")

    def test_finish_sigkill_public_recovery_preserves_exact_settlement_and_never_redispatches(self):
        for phase in ("ticket_directory_fsynced", "index_directory_fsynced", "admission_replaced",
                      "state_replaced", "published_replaced", "ack_intent_installed",
                      "pending_mutated", "completion_installed", "active_unlinked"):
            with self.subTest(phase=phase):
                self.setUp()
                execution = self.begin()
                self.provider_files(execution, kind="applied")
                execution.close()  # Do not keep a parent SH descriptor across fork.
                self.kill_at(lambda: self.finish(execution), phase)
                run = execution.paths.run_dir
                settled = (run / "settlement.json").read_bytes()
                dispatch = (run / "provider-dispatch.json").read_bytes()
                result = self.recover()
                self.assertEqual(result, None if phase == "active_unlinked" else "succeeded")
                self.assertEqual((run / "settlement.json").read_bytes(), settled)
                self.assertEqual((run / "provider-dispatch.json").read_bytes(), dispatch)
                self.assertEqual(C._parser_state(json.loads(self.f.state_path.read_bytes())), C._next_parser(self.f.excerpt))
                self.assertEqual(json.loads(self.f.record_path.read_bytes())["processing"], None)
                self.assertFalse(self.pending.exists())
                self.assertFalse((self.paths.session_directory / "active.json").exists())
                self.assertEqual(self.probe_mock.call_count, 1)

    def test_newer_pending_during_provider_and_after_publication_is_preserved(self):
        for crash in (False, True):
            with self.subTest(crash=crash):
                self.setUp()
                execution = self.begin()
                self.provider_files(execution)
                if crash:
                    execution.close()
                    self.kill_at(lambda: self.finish(execution), "published_replaced")
                self.f.append("PRIVATE later message remains queued")
                newer = {**self.f.request, "request_id": "newer-stop", "turn_id": "newer-turn"}
                write_json(self.pending, newer)
                record = json.loads(self.f.record_path.read_bytes())
                write_json(self.f.record_path, {**record, "last_event": "e" * 64})
                pending = self.pending.read_bytes()
                result = self.recover() if crash else self.finish(execution)
                self.assertEqual(result, "succeeded")
                self.assertEqual(self.pending.read_bytes(), pending)
                self.assertEqual(json.loads(self.f.record_path.read_bytes())["last_event"], "e" * 64)
                self.assertEqual(C._parser_state(json.loads(self.f.state_path.read_bytes())), C._next_parser(self.f.excerpt))
                self.assertLess(self.f.excerpt.next_offset, self.f.path.stat().st_size)

    def test_missing_or_changed_inputs_hold_public_recovery_without_queue_or_cursor_effects(self):
        for damage in ("source", "runtime", "config", "activation", "manifest_missing", "manifest_changed",
                       "marker_missing", "pending_missing", "pending_same_id", "observation_changed"):
            with self.subTest(damage=damage):
                self.setUp()
                execution = self.begin()
                self.provider_files(execution)
                execution.close()
                run = execution.paths.run_dir
                if damage == "source":
                    self.f.path.write_bytes(self.f.path.read_bytes().replace(b"PRIVATE", b"CHANGED"))
                elif damage == "runtime":
                    self.f.runtime.write_bytes(self.f.runtime.read_bytes() + b"changed")
                elif damage == "config":
                    self.f.config_path.write_text(self.f.config_text + 'disabled_tools = ["remember", "update", "connect"]\n')
                elif damage == "activation":
                    write_json(self.f.root / "admission.json", {**self.f.policy, "enabled": False})
                elif damage == "manifest_missing":
                    (run / "execution-manifest.json").unlink()
                elif damage == "manifest_changed":
                    value, _ = J.read_manifest(run)
                    write_json(run / "execution-manifest.json", {**value, "host": "changed"})
                elif damage == "marker_missing":
                    (run / "processing-publication.json").unlink()
                elif damage == "pending_missing":
                    self.pending.unlink()
                elif damage == "pending_same_id":
                    write_json(self.pending, {**self.f.request, "turn_id": "different-turn"})
                else:
                    self.kill_at(lambda: self.finish(execution), "published_replaced")
                    value = json.loads((run / "provider-observation.json").read_bytes())
                    value["observation"]["returncode"] = 1
                    write_json(run / "provider-observation.json", value)
                before = self.current()
                with self.assertRaises((ValueError, OSError)):
                    self.recover()
                self.assertEqual(self.current(), before)
                self.assertEqual(self.probe_mock.call_count, 1)

    def test_successful_partial_page_keeps_original_pending(self):
        self.f.append("PRIVATE next page")
        size = self.f.excerpt.next_offset - self.f.frontier
        self.f.excerpt = T.read_excerpt(self.f.path, self.f.frontier, stable_identity=True,
                                       max_chars=self.config["max_chars"], max_scan_bytes=size)
        self.assertTrue(self.f.excerpt.has_more)
        before = self.pending.read_bytes()
        execution = self.begin()
        self.provider_files(execution)
        self.assertEqual(self.finish(execution), "more")
        self.assertEqual(self.pending.read_bytes(), before)
        self.assertEqual(C._parser_state(json.loads(self.f.state_path.read_bytes())), C._next_parser(self.f.excerpt))


if __name__ == "__main__":
    unittest.main(verbosity=2)
