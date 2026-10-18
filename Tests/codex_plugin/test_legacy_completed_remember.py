"""Synthetic completed-remember review: real read-only rows and paired journals."""
import copy
import importlib
import json
import unittest
from unittest import mock

from legacy_fixture import LegacyFixture, SID, RUN_ID, SUCCESS_ID, DUPLICATE_ID, encode, digest, write_json
import test_legacy_acceptance as acceptance

L = acceptance.L


class CompletedFixture(LegacyFixture):
    def __init__(self):
        super().__init__(L)
        self.messages = ["PRIVATE durable synthetic observation represented by the preserved row."] + [
            "PRIVATE dated synthetic progress " + str(index) + "." for index in range(2, 7)]
        self.path.write_bytes(self.path.read_bytes()[:self.start])
        for message in self.messages:
            self.append(message)
        self.excerpt = L.transcript.read_excerpt(self.path, self.start, max_chars=4000, max_scan_bytes=20000,
            recent_messages=self.state["recent_messages"], current_turn_id=self.state["current_turn_id"], stable_identity=True)
        self.end = self.excerpt.next_offset
        self.request["pause_reason"] = "reconciliation_required"
        write_json(self.pending_path, self.request)
        self.row_values = self.row_values[:1]
        self.row_values[0]["expiresAt"] = float(L.completed_remember.PERMANENT_EXPIRY)
        self.update_row("expiresAt=?", (self.row_values[0]["expiresAt"],))
        self.review.update(kind=L.completed_remember.KIND, historical_request_id=None,
            rows=[self.row_readback(self.row_values[0])], artifacts={})
        self.review["source"].update(end_offset=self.end,
            interval_sha256=digest(self.path.read_bytes()[self.start:self.end]), excerpt_sha256=digest(self.excerpt.text.encode()))
        self.review["parser"]["next"] = L.context._next_parser(self.excerpt)
        position, messages = self.start, []
        for index, (raw, body) in enumerate(zip(self.path.read_bytes()[self.start:self.end].splitlines(keepends=True), self.messages), 1):
            messages.append({"index": index, "role": "assistant", "sha256": digest(("[ASSISTANT]\n" + body).encode()),
                "disposition": "represented_by_preserved_remember" if index == 1 else "dated_progress",
                "memory_ids": [SUCCESS_ID] if index == 1 else [], "rationale": "Synthetic complete-message review.",
                "record": {"start_offset": position, "end_offset": position + len(raw), "sha256": digest(raw)},
                "body": {"sha256": digest(body.encode()), "chars": len(body)}})
            position += len(raw)
        self.review["messages"] = messages
        row = self.row_values[0]
        self.args = {key: row[key] for key in ("content", "project", "topic", "source")}
        self.args["force"] = False  # Privacy/TTL were omitted, never supplied by recovery.
        self.result = {"outcome": "stored", "summary": "PRIVATE synthetic final report", "memory_ids": [SUCCESS_ID]}
        self.provider = [{"type": "thread.started", "thread_id": SID}, {"type": "turn.started"},
                         {"type": "error", "message": "Synthetic recoverable notice 1"}]
        self.audit = [{"event": "relay_started"}, {"event": "initialize_compat", "omitted_capability": "codex/auth-change"}]
        for index, tool in enumerate(("recall", "recall", "recall", "remember"), 2):
            args = self.args if tool == "remember" else {"query": "PRIVATE fixture topic " + str(index)}
            native = {"content": [{"type": "text", "text": "PRIVATE synthetic recall"}], "structured_content": None}
            if tool == "remember":
                native["content"][0]["text"] = ("Stored memory (id: " + SUCCESS_ID.upper() + ", project: "
                    + row["project"] + ", topic: " + row["topic"] + ", private: true, auto-linked to [id:"
                    + DUPLICATE_ID.upper() + "]): " + row["content"])
            item = {"id": "tool-" + str(index), "type": "mcp_tool_call", "server": "memory", "tool": tool,
                    "arguments": copy.deepcopy(args), "result": None, "error": None, "status": "in_progress"}
            self.provider.extend([{"type": "item.started", "item": item}, {"type": "item.completed",
                "item": {**copy.deepcopy(item), "status": "completed", "result": native}}])
            self.audit.extend([{"event": "tool_call", "id": index, "tool": tool}, {"event": "tool_result",
                "id": index, "tool": tool, "ok": True, "forwarded": True,
                "memory_ids": [SUCCESS_ID] if tool == "remember" else []}])
        self.provider.extend([{"type": "error", "message": "Synthetic recoverable notice 2"},
            {"type": "item.completed", "item": {"id": "final", "type": "agent_message", "text": json.dumps(self.result)}},
            {"type": "turn.completed", "usage": {"input_tokens": 100, "output_tokens": 20}}])
        self.audit.extend([{"event": "relay_interrupted"}, {"event": "relay_finished", "child_reaped": True,
            "cleanup_overrun": False, "peak_inflight": 1, "peak_client_queue_bytes": 1024, "peak_server_queue_bytes": 2048}])
        self.run = {"session_id": SID, "status": "failed", "reason": "unverified_completion", "returncode": 0,
            "provider_error": True, "unexpected_tool": False, "turn_completed": True, "tool_calls": 4,
            "tool_errors": 1, "write_calls": 1, "outcome": "stored", "end_offset": self.end,
            "started_at": "2026-01-03T08:32:00Z", "ended_at": "2026-01-03T08:33:21Z",
            "writes": [{"tool": "remember", "memory_ids": [SUCCESS_ID]}]}
        self.refresh_history()

    def refresh_history(self):
        self.history.update(provider=b"".join(encode(e) for e in self.provider), audit=b"".join(encode(e) for e in self.audit),
                            run=encode(self.run), result=encode(self.result))
        for role, name in L.ROLES.items():
            path = self.run_dir / name
            path.write_bytes(self.history[role])
            path.chmod(0o644 if role == "result" else 0o600)
        start = next(e["item"] for e in self.provider if e.get("type") == "item.started" and e["item"]["tool"] == "remember")
        finish = next(e["item"] for e in self.provider if e.get("type") == "item.completed" and e.get("item", {}).get("tool") == "remember")
        self.args = start["arguments"]
        self.review["attempts"] = [{"item_id": start["id"], "audit_id": 5, "arguments_sha256": digest(L.codec.encode(self.args)),
            "native_result_sha256": digest(L.codec.encode(finish["result"])), "disposition": "original_success_preserved",
            "memory_ids": [SUCCESS_ID]}]
        self.review["history"] = {key: digest(value) for key, value in self.history.items()}
        self.refresh_review()

    def refresh_review(self):
        common = {"schema_version": 1, "session_id": SID, "run_id": RUN_ID}
        artifacts = self.review["artifacts"] = {}
        def report(name, value):
            write_json(self.evidence / name, {**common, **value})
            artifacts[name] = digest((self.evidence / name).read_bytes())
        report("completed-remember-coverage.json", {**{key: self.review[key] for key in ("source", "parser", "messages", "attempts")},
            "parser_diagnostics": self.excerpt.diagnostics, "record_count": 6})
        report("completed-remember-independent-review.json", {"coverage_sha256": artifacts["completed-remember-coverage.json"],
            "decision": "approved", "message_count": len(self.review["messages"]), "source_anchors_verified": True,
            "additional_eligible_operations": 0, "unresolved_observations": 0})
        report("completed-remember-readback.json", {"row": self.review["rows"][0], "store_identity": self.review["store_identity"],
            "mode": "guarded_exact_uuid_read_only"})
        report("completed-remember-intent.private.json", {"provider_file_sha256": self.review["history"]["provider"],
            "attempt": self.review["attempts"][0], "original_outbound_native_arguments": self.args})
        self.write_review()


class CompletedRememberTests(unittest.TestCase):
    no_external_effects = acceptance.LegacyAcceptanceTests.no_external_effects

    def fixture(self):
        value = CompletedFixture()
        self.addCleanup(value.close)
        return value

    def refused(self, f):
        before, history, database = f.current(), f.history_snapshot(), f.store.read_bytes()
        with self.no_external_effects(f), self.assertRaises(ValueError):
            f.prepare()
        self.assertEqual(f.current(), before)
        self.assertEqual(f.history_snapshot(), history)
        self.assertEqual(f.store.read_bytes(), database)
        self.assertFalse((f.root / "reconciliations").exists())

    def test_completed_notice_turn_reconciles_only_metadata_and_next_interval_is_available(self):
        f = self.fixture()
        history, database, pending = f.history_snapshot(), f.store.read_bytes(), f.pending_path.read_bytes()
        with self.no_external_effects(f):
            plan = f.prepare()
            result = f.apply(plan)
            self.assertEqual(f.recover(plan), result)
            self.assertEqual(f.apply(plan), result)
        state = json.loads(f.state_path.read_bytes())
        self.assertEqual(state["offset"], f.end)
        self.assertEqual(state["status"], L.RESULT)
        self.assertNotIn("reconciliation_required", state)
        self.assertEqual(state["last_run"], RUN_ID)
        self.assertEqual(state["last_success_at"], f.state["last_success_at"])
        self.assertEqual(f.pending_path.read_bytes(), pending)
        self.assertEqual(result["native_mutations_performed"], 0)
        self.assertEqual(result["historical_run_status"], "failed")
        self.assertEqual(f.history_snapshot(), history)
        self.assertEqual(f.store.read_bytes(), database)
        self.assertFalse(L.needs_recovery(f.root, SID))
        f.append("A newly eligible subsequent synthetic message.")
        R = importlib.import_module("codex_learner.runner")
        payload = {"session_id": SID, "transcript_path": str(f.path), "cwd": str(f.project),
                   "turn_id": "next-turn", "hook_event_name": "Stop"}
        with self.no_external_effects(f):
            request = R.validate_request(payload, f.root)
            self.assertEqual(request["session_id"], SID)
            self.assertTrue(R.enqueue(f.root, payload, spawn=False))
            queued = json.loads(f.pending_path.read_bytes())
            self.assertEqual(queued["turn_id"], "next-turn")
            self.assertNotIn("pause_reason", queued)
            excerpt = L.transcript.read_excerpt(f.path, state["offset"], max_chars=4000, max_scan_bytes=20000,
                recent_messages=state["recent_messages"], current_turn_id=state["current_turn_id"], stable_identity=True)
        self.assertEqual(excerpt.message_count, 1)
        self.assertIn("newly eligible", excerpt.text)
        self.assertNotIn("PRIVATE", excerpt.text)

    def test_uppercase_final_uuid_matches_canonical_row_without_rewriting_history(self):
        case_id = "a1111111-b222-4333-8444-55555555555f"
        with mock.patch("legacy_fixture.SUCCESS_ID", case_id), mock.patch(__name__ + ".SUCCESS_ID", case_id):
            f = self.fixture()
            f.result["memory_ids"] = [SUCCESS_ID.upper()]
            f.provider[-2]["item"]["text"] = json.dumps(f.result)
            f.refresh_history()
            history, database = f.history_snapshot(), f.store.read_bytes()
            with self.no_external_effects(f):
                plan = f.prepare()
                result = f.apply(plan)
            self.assertEqual(result["native_mutations_performed"], 0)
            self.assertEqual(f.history_snapshot(), history)
            self.assertEqual(f.store.read_bytes(), database)
            # Semantic UUID equality must not hide a changed final provider result.
            f = self.fixture()
            f.result["memory_ids"] = [SUCCESS_ID.upper()]
            f.refresh_history()
            self.refused(f)

    def test_terminal_tool_and_cleanup_errors_refuse_even_with_rehashed_reports(self):
        changes = {
            "turn-failed": lambda f: f.provider.insert(-1, {"type": "turn.failed", "error": {"message": "failure"}}),
            "post-completion-error": lambda f: f.provider.append({"type": "error", "message": "too late"}),
            "second-start": lambda f: f.provider.insert(-1, {"type": "turn.started"}),
            "nonzero-exit": lambda f: f.run.update(returncode=1),
            "timeout": lambda f: f.run.update(timed_out=True),
            "read-failed": lambda f: f.provider[4]["item"].update(status="failed"),
            "write-uncertain": lambda f: f.audit[-3].update(ok=False),
            "missing-cleanup": lambda f: f.audit.pop(),
            "cleanup-overrun": lambda f: f.audit[-1].update(cleanup_overrun=True),
            "unreaped": lambda f: f.audit[-1].update(child_reaped=False),
            "extra-audit-field": lambda f: f.audit[0].update(unknown=True),
            "wrong-final-ids": lambda f: f.result.update(memory_ids=[DUPLICATE_ID]),
            "missing-accounting": lambda f: f.run.update(writes=[]),
        }
        for name, change in changes.items():
            with self.subTest(case=name):
                f = self.fixture()
                change(f)
                f.refresh_history()
                self.refused(f)

    def test_no_additional_or_failed_mutation_can_be_accounted_as_a_notice(self):
        for tool in ("remember", "update", "forget"):
            with self.subTest(tool=tool):
                f = self.fixture()
                extra = copy.deepcopy(f.provider[9:11])
                for event in extra:
                    event["item"]["tool"] = tool
                    event["item"]["id"] = "extra-write"
                f.provider[-1:-1] = extra
                f.refresh_history()
                self.refused(f)

    def test_omitted_defaults_are_not_invented_and_ttl_force_or_privacy_changes_refuse(self):
        for key, value in (("expires_in_days", 0), ("expires_in_days", 14), ("parent_id", SUCCESS_ID),
                           ("force", True), ("is_private", False), ("source", "codex-session:wrong")):
            with self.subTest(field=key, value=value):
                f = self.fixture()
                for event in f.provider:
                    if event.get("item", {}).get("tool") == "remember":
                        event["item"]["arguments"][key] = value
                f.refresh_history()
                self.refused(f)

    def test_native_ack_requires_own_id_privacy_and_exact_content_not_neighbor_ids(self):
        for case in ("wrong-id", "public", "wrong-content", "structured", "extra-content", "error"):
            with self.subTest(case=case):
                f = self.fixture()
                finish = next(e["item"] for e in f.provider if e.get("type") == "item.completed" and e.get("item", {}).get("tool") == "remember")
                text = finish["result"]["content"][0]["text"]
                if case == "wrong-id":
                    finish["result"]["content"][0]["text"] = text.replace("id: " + SUCCESS_ID.upper(), "id: " + DUPLICATE_ID.upper())
                elif case == "public":
                    finish["result"]["content"][0]["text"] = text.replace(", private: true", "")
                elif case == "wrong-content":
                    finish["result"]["content"][0]["text"] = text.replace(f.args["content"], "different content")
                elif case == "structured":
                    finish["result"]["structured_content"] = {"error": "uncertain"}
                elif case == "extra-content":
                    finish["result"]["content"].append({"type": "text", "text": "contradiction"})
                else:
                    finish["error"] = {"message": "failed"}
                f.refresh_history()
                self.refused(f)

    def test_native_timestamp_reads_need_not_be_ordered_but_stay_in_original_window(self):
        f = self.fixture()
        f.row_values[0]["modifiedAt"] -= 0.0001
        f.update_row("modifiedAt=?", (f.row_values[0]["modifiedAt"],))
        f.review["rows"] = [f.row_readback(f.row_values[0])]
        f.refresh_review()
        with self.no_external_effects(f):
            plan = f.prepare()
        self.assertEqual(L._json(L._raw(plan["review"]))["rows"], f.review["rows"])

    def test_missing_duplicate_or_unreviewed_message_and_record_anchors_refuse(self):
        for case in ("missing", "duplicate", "body", "record", "rationale", "extra-memory", "unresolved"):
            with self.subTest(case=case):
                f = self.fixture()
                if case == "missing": f.review["messages"].pop()
                elif case == "duplicate": f.review["messages"][1] = copy.deepcopy(f.review["messages"][0])
                elif case == "body": f.review["messages"][0]["body"]["sha256"] = "0" * 64
                elif case == "record": f.review["messages"][0]["record"]["start_offset"] += 1
                elif case == "rationale": f.review["messages"][0]["rationale"] = ""
                elif case == "extra-memory": f.review["messages"][0]["memory_ids"] = [DUPLICATE_ID]
                else: f.review["messages"][0]["disposition"] = "unreviewed"
                f.refresh_review()
                self.refused(f)

    def test_changed_row_source_history_and_authority_hold_without_writes(self):
        for case in ("content", "expiry", "privacy", "deletion", "source", "history", "admission", "pending"):
            with self.subTest(case=case):
                f = self.fixture()
                with self.no_external_effects(f): plan = f.prepare()
                if case == "content": f.update_row("content=?", ("changed",))
                elif case == "expiry": f.update_row("expiresAt=expiresAt+1", ())
                elif case == "privacy": f.update_row("isPrivate=0", ())
                elif case == "deletion": f.update_row("deletedAt=1", ())
                elif case == "source": f.path.write_bytes(f.path.read_bytes().replace(b"PRIVATE durable", b"CHANGED durable", 1))
                elif case == "history": (f.run_dir / "run.json").write_bytes(f.history["run"] + b" ")
                elif case == "admission": write_json(f.record_path, {**f.record, "processing": "other"})
                else: write_json(f.pending_path, {**f.request, "pause_reason": "unknown"})
                before, history, database = f.current(), f.history_snapshot(), f.store.read_bytes()
                with self.no_external_effects(f), self.assertRaises(ValueError): f.apply(plan)
                self.assertEqual(f.current(), before)
                self.assertEqual(f.history_snapshot(), history)
                self.assertEqual(f.store.read_bytes(), database)

    def test_interrupted_paired_publication_recovers_once_and_preserves_newer_pending(self):
        for boundary in ("active_directory_fsynced", "before_retire"):
            with self.subTest(boundary=boundary):
                f = self.fixture()
                with self.no_external_effects(f): plan = f.prepare()
                def stop(label):
                    if label == boundary: raise RuntimeError("synthetic crash boundary")
                with self.no_external_effects(f), mock.patch.object(L.coordinator, "_boundary", side_effect=stop), self.assertRaises(ValueError):
                    f.apply(plan)
                pending, _ = f.newer_pending()
                history, database = f.history_snapshot(), f.store.read_bytes()
                with self.no_external_effects(f):
                    result = f.recover(plan)
                    self.assertEqual(f.recover(plan), result)
                self.assertEqual(json.loads(f.state_path.read_bytes())["offset"], f.end)
                self.assertEqual(f.pending_path.read_bytes(), pending)
                self.assertEqual(f.history_snapshot(), history)
                self.assertEqual(f.store.read_bytes(), database)


if __name__ == "__main__":
    unittest.main()
