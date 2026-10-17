"""Entirely synthetic replacement-UPDATE evidence in private disposable files."""
from __future__ import annotations

from contextlib import closing
import copy
import importlib
import os
import re
import sqlite3

from legacy_fixture import (LegacyFixture, REPOSITORY_ROOT, SID, RUN_ID,
                            SUCCESS_ID, HISTORICAL_REQUEST, encode, digest,
                            write_json)


def fixture_parent():
    parent = REPOSITORY_ROOT.parent
    for name in ("tests", "tmp"):
        parent = parent / name
        if not parent.exists():
            parent.mkdir(mode=0o700)
        info = parent.lstat()
        if parent.is_symlink() or not parent.is_dir() or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Synthetic fixture parent must be owned, private and nonsymlink")
    return parent.resolve(strict=True)


class ExpiredUpdateFixture(LegacyFixture):
    """Thirteen invented messages, one old row and two fully linked attempts."""

    def __init__(self, module=None):
        self.converted = False
        super().__init__(module, fixture_parent=fixture_parent())
        self.profile = importlib.import_module("codex_learner.legacy_expired_update")
        self.converted = True
        self.messages = [
            "PRIVATE synthetic replacement finding was recorded. A temporary check was being prepared.",
            "PRIVATE synthetic review identified a temporary evaluation risk. A later review was planned.",
            "PRIVATE synthetic handoff was being prepared. Its progress is temporary.",
            "PRIVATE synthetic metadata remained unverified in one task. No general capability was established.",
            "PRIVATE synthetic replacement finding was repeated. The next check was only proposed.",
            "PRIVATE synthetic review recommended exposing the evaluation risk. That recommendation was not an adopted rule.",
            "PRIVATE synthetic package transfer was reported complete. This was routine progress.",
            "PRIVATE synthetic temporary resources awaited inspection. That intermediate state was later superseded.",
            "PRIVATE synthetic permission concerned one command. It supplied no standing authorization.",
            "PRIVATE synthetic future guard was proposed. The proposal did not establish its implementation.",
            "PRIVATE synthetic bundle checks were being prepared. They did not establish application acceptance.",
            "PRIVATE synthetic review was still in progress. No additional durable result was stated.",
            "PRIVATE synthetic handoff was planned. No additional memory operation was justified."]
        with self.path.open("r+b") as stream:
            stream.truncate(self.start)
        for message in self.messages:
            self.append(message)
        self.excerpt = self.L.transcript.read_excerpt(
            self.path, self.start, max_chars=4000, max_scan_bytes=20000,
            recent_messages=self.state["recent_messages"],
            current_turn_id=self.state["current_turn_id"], stable_identity=True)
        self.end = self.excerpt.next_offset
        row = self.memory(SUCCESS_ID, "PRIVATE synthetic replacement content with bounded historical validity.")
        row["createdAt"] -= 45 * 86400
        self.row_values = [row]
        with closing(sqlite3.connect(self.store)) as database:
            database.execute("DELETE FROM Memory WHERE globalId != ?", (SUCCESS_ID,))
            database.execute("UPDATE Memory SET createdAt=?,content=? WHERE globalId=?",
                             (row["createdAt"], row["content"], SUCCESS_ID))
            database.commit()
        self.update_args = {"id": SUCCESS_ID, "content": row["content"],
                            "source": row["source"], "expires_in_days": 14}
        self.remember_args = {"content": "PRIVATE synthetic evaluation risk and reporting recommendation.",
            "project": "fixture-project", "topic": "fixture-topic", "source": row["source"],
            "is_private": True, "force": False, "expires_in_days": 14}
        self.update_result = {"content": [{"type": "text", "text":
            "Updated memory (id: " + SUCCESS_ID.upper() + ", project: fixture-project, topic: fixture-topic).\n"
            "Changes:\ncontent: synthetic prior content... → " + row["content"][:40] + "...\n"
            "source: synthetic prior source → " + row["source"] + "\n"
            "expires: Never → Jan 17, 2026"}], "structured_content": None}
        self.remember_result = {"content": [{"type": "text", "text": self.profile.BEGIN_BUSY_TEXT}],
            "structured_content": {"engram_write_receipt": {"schema_version": 1,
                "tool": "remember", "memory_ids": [], "reason": "database_busy",
                "write_outcome": "not_stored_transaction_not_started"}}}
        self.audit_success_override = {}
        self.audit_failure_override = {}
        self.update_finish_override = {}
        self.remember_finish_override = {}
        self.run_started = "2026-01-03T08:32:00Z"
        self.run_ended = "2026-01-03T08:33:21Z"
        for name in self.review["artifacts"]:
            (self.evidence / name).unlink()
        self.review.update(kind="reviewed_expired_replacement_update_no_new_mutation", artifacts={},
            rows=[self.row_readback(row)], source={**self.review["source"], "end_offset": self.end,
                "interval_sha256": digest(self.path.read_bytes()[self.start:self.end]),
                "excerpt_sha256": digest(self.excerpt.text.encode())},
            parser={**self.review["parser"], "next": self.L.context._next_parser(self.excerpt)})
        self.review["messages"] = self.message_reviews()
        self.rebuild_history()

    def message_reviews(self):
        values, offset = [], self.start
        for index, message in enumerate(self.messages, 1):
            raw = encode({"type": "event_msg", "payload": {"type": "agent_message", "message": message}})
            sentences, clauses = [], []
            for number, match in enumerate(re.finditer(r"\S.*?(?:[.!?](?=\s|$)|$)", message), 1):
                start, end = match.span()
                anchor = {"index": number, "start": start, "end": end,
                          "sha256": digest(message[start:end].encode())}
                sentences.append(anchor)
                disposition = ("represented_by_replacement_update" if number == 1 and index in (1, 5)
                    else "expired_no_write_remember" if number == 1 and index in (2, 6)
                    else "transient_or_ineligible")
                attribution = ("assistant_plan_or_proposal" if index in (3, 6, 10, 13)
                    else "task_scoped_limitation" if index == 4 else "assistant_observation")
                clauses.append({"id": "M%02dC%02d" % (index, number), "sentence_index": number,
                    "start": start, "end": end, "sha256": anchor["sha256"],
                    "disposition": disposition, "attribution": attribution,
                    "rationale": "Synthetic clause individually reviewed; historical coverage or temporary status only."})
            values.append({"index": index, "role": "assistant",
                "sha256": digest(("[ASSISTANT]\n" + message).encode()),
                "disposition": "reviewed_no_new_mutation",
                "memory_ids": [SUCCESS_ID] if any(c["disposition"] == "represented_by_replacement_update" for c in clauses) else [],
                "record": {"start_offset": offset, "end_offset": offset + len(raw), "sha256": digest(raw)},
                "body": {"sha256": digest(message.encode()), "chars": len(message)},
                "sentences": sentences, "clauses": clauses})
            offset += len(raw)
        assert offset == self.end
        return values

    def rebuild_history(self):
        provider = [{"type": "thread.started", "thread_id": SID}, {"type": "turn.started"}]
        audit, attempts = [{"event": "relay_started"}], []
        operations = [("stats", {}, {"content": [{"type": "text", "text": "synthetic read"}]}),
            ("update", self.update_args, self.update_result),
            ("remember", self.remember_args, self.remember_result)]
        for number, (tool, args, native) in enumerate(operations, 1):
            item = {"id": "tool-" + str(number), "type": "mcp_tool_call", "server": "memory",
                    "tool": tool, "arguments": copy.deepcopy(args), "result": None,
                    "error": None, "status": "in_progress"}
            finish = {**item, "result": copy.deepcopy(native), "status": "failed" if number == 3 else "completed", "error": None}
            if number in (2, 3):
                finish.update(self.update_finish_override if number == 2 else self.remember_finish_override)
            provider.extend([{"type": "item.started", "item": item}, {"type": "item.completed", "item": finish}])
            result = {"event": "tool_result", "id": number, "tool": tool, "forwarded": True,
                      "ok": number != 3, "memory_ids": [SUCCESS_ID] if number == 2 else []}
            if number == 3:
                result.update(write_outcome_version=1, write_outcome="not_stored_transaction_not_started")
            if number in (2, 3):
                result.update(self.audit_success_override if number == 2 else self.audit_failure_override)
            audit.extend([{"event": "tool_call", "id": number, "tool": tool}, result])
            if number in (2, 3):
                attempts.append({"item_id": item["id"], "audit_id": number,
                    "arguments_sha256": digest(self.L.codec.encode(args)),
                    "native_result_sha256": digest(self.L.codec.encode(finish["result"])),
                    "disposition": "original_success_preserved" if number == 2 else "original_no_write_expired",
                    "memory_ids": [SUCCESS_ID] if number == 2 else []})
        provider.append({"type": "turn.completed"})
        audit.append({"event": "relay_finished", "child_reaped": True, "cleanup_overrun": False, "peak_inflight": 1})
        run = {"session_id": SID, "request_id": HISTORICAL_REQUEST, "status": "failed",
            "reason": "unverified_completion", "returncode": 0, "turn_completed": True,
            "provider_error": False, "unexpected_tool": False, "end_offset": self.end,
            "started_at": self.run_started, "ended_at": self.run_ended, "write_calls": 1, "tool_calls": 3}
        self.attempts = attempts
        self.history.update(run=encode(run), provider=b"".join(encode(e) for e in provider),
                            audit=b"".join(encode(e) for e in audit))
        self.review["attempts"] = attempts
        self.sync_history()

    def sync_history(self):
        for role, name in self.L.ROLES.items():
            path = self.run_dir / name
            path.write_bytes(self.history[role])
            path.chmod(0o644 if role == "result" else 0o600)
        self.review["history"] = {role: digest(raw) for role, raw in self.history.items()}
        self.write_assessments()
        self.write_review()

    def write_assessments(self):
        if not self.converted:
            return super().write_assessments()
        common = {"schema_version": 1, "session_id": SID, "run_id": RUN_ID}
        self.review["artifacts"] = {}
        def report(name, value):
            path = self.evidence / name
            write_json(path, {**common, **value})
            self.review["artifacts"][name] = digest(path.read_bytes())
        report("expired-update-coverage.json", {"source": self.review["source"], "parser": self.review["parser"],
            "messages": self.review["messages"], "attempts": self.review["attempts"],
            "parser_diagnostics": {"malformed_records": 0, "excluded_records": 0, "inherited_records": 0,
                                   "duplicate_messages": 0, "redacted_messages": 0},
            "record_count": 13, "conclusion": {"additional_eligible_operations": 0,
                "unresolved_observations": 0, "proposal": "expired_no_new_write", "semantic_review_complete": True}})
        report("expired-update-independent-review.json", {
            "coverage_sha256": self.review["artifacts"]["expired-update-coverage.json"], "decision": "approved",
            "message_count": 13, "clause_count": sum(len(m["clauses"]) for m in self.review["messages"]),
            "source_anchors_verified": True, "additional_eligible_operations": 0, "unresolved_observations": 0})
        report("expired-update-readback.json", {"row": self.review["rows"][0], "mode": "guarded_exact_uuid_read_only",
            "matches_historical_update": {"content": True, "source": True, "original_expiry": True, "modified_at": True}})
        report("expired-update-intents.private.json", {"provider_file_sha256": self.review["history"]["provider"],
            "intents": [{"provider_item_id": attempt["item_id"], "audit_rpc_id": attempt["audit_id"],
                "arguments_canonical_json_sha256": attempt["arguments_sha256"],
                "original_outbound_native_arguments": args} for attempt, args in
                zip(self.attempts, (self.update_args, self.remember_args))]})

    def refresh_review(self):
        self.write_assessments()
        self.write_review()

    def rewrite_report(self, name, change):
        """Re-pin a synthetic report, retaining independently meaningful links."""
        value = self.L._json((self.evidence / name).read_bytes())
        change(value)
        write_json(self.evidence / name, value)
        self.review["artifacts"][name] = digest((self.evidence / name).read_bytes())
        if name == "expired-update-coverage.json":
            independent = self.L._json((self.evidence / "expired-update-independent-review.json").read_bytes())
            independent["coverage_sha256"] = self.review["artifacts"][name]
            write_json(self.evidence / "expired-update-independent-review.json", independent)
            self.review["artifacts"]["expired-update-independent-review.json"] = digest(
                (self.evidence / "expired-update-independent-review.json").read_bytes())
        self.write_review()

    def change_row_and_repin(self, field, value):
        self.row_values[0][field] = value
        self.update_row(field + "=?", (value,))
        self.review["rows"][0] = self.row_readback(self.row_values[0])
        self.refresh_review()
