"""Synthetic native Codex rollout fixtures; no personal rollout data in tests."""

from __future__ import annotations

from dataclasses import asdict
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from codex_learner.transcript import (  # noqa: E402
    TranscriptError,
    inspect_rollout,
    read_excerpt,
    redact_secrets,
)


def record(kind, payload, ordinal=None):
    value = {"timestamp": "2026-09-09T22:00:00Z", "type": kind, "payload": payload}
    if ordinal is not None:
        value["ordinal"] = ordinal
    return value


def meta(**overrides):
    return record("session_meta", {"id": "child-123", "cwd": "/tmp/project", "source": "vscode", **overrides})


def message(role, text, *, phase=None, turn_id=None, item_id=None, ordinal=None):
    payload = {"type": "message", "role": role, "content": [{"type": "input_text" if role == "user" else "output_text", "text": text}]}
    if phase is not None:
        payload["phase"] = phase
    if turn_id:
        payload["internal_chat_message_metadata_passthrough"] = {"turn_id": turn_id}
    if item_id:
        payload["id"] = item_id
    return record("response_item", payload, ordinal)


def event(role, text, **extra):
    return record("event_msg", {"type": "user_message" if role == "user" else "agent_message", "message": text, **extra})


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "rollout.jsonl"

    def write(self, *records, suffix=b""):
        pieces = [json.dumps(item, ensure_ascii=False).encode("utf-8") + b"\n" for item in records]
        self.path.write_bytes(b"".join(pieces) + suffix)
        return [sum(map(len, pieces[:i])) for i in range(len(pieces) + 1)]

    def test_only_visible_user_decisions_and_assistant_outcomes(self):
        self.write(
            meta(),
            message("developer", "SECRET developer instruction"),
            message("system", "SECRET system instruction"),
            message("user", "Keep the camera gate closed."),
            message("assistant", "SECRET hidden reasoning", phase="analysis"),
            record("response_item", {"type": "reasoning", "summary": [{"type": "summary_text", "text": "SECRET reasoning summary"}]}),
            record("response_item", {"type": "function_call_output", "output": "SECRET tool result"}),
            record("response_item", {"type": "custom_tool_call", "input": "SECRET shell argument"}),
            record("compacted", {"message": "SECRET summary", "replacement_history": [message("user", "SECRET inherited request")]}),
            message("assistant", "The queue is healthy.", phase="commentary"),
            message("assistant", "Validation passed; the gate remains closed.", phase="final_answer"),
            record("response_item", {"type": "agent_message", "content": "SECRET agent coordination"}),
            record("event_msg", {"type": "item_completed", "item": {"type": "Reasoning", "raw_content": ["SECRET"]}}),
            record("event_msg", {"type": "task_complete", "last_agent_message": "Should not duplicate final answer"}),
        )
        excerpt = read_excerpt(self.path)
        self.assertEqual(excerpt.message_count, 3)
        self.assertNotIn("SECRET", excerpt.text)
        self.assertIn("Keep the camera gate closed.", excerpt.text)
        self.assertIn("Validation passed", excerpt.text)
        self.assertNotIn("Should not duplicate", excerpt.text)
        self.assertFalse(excerpt.has_more)
        self.assertEqual(excerpt.next_offset, self.path.stat().st_size)

    def test_event_fallback_and_current_item_completed_mirrors(self):
        self.write(
            meta(),
            record("event_msg", {"type": "task_started", "turn_id": "turn-1"}),
            event("user", "Please retain the existing experiment."),
            message("user", "Please retain the existing experiment.", item_id="response-user-id", turn_id="turn-1"),
            record("event_msg", {"type": "item_completed", "turn_id": "turn-1", "item": {"type": "UserMessage", "id": "different-event-user-id", "content": [{"type": "text", "text": "Please retain the existing experiment."}]}}),
            message("assistant", "Retained.", phase="final", item_id="assistant-id"),
            event("assistant", "Retained."),
            record("event_msg", {"type": "item_completed", "turn_id": "turn-1", "item": {"type": "AgentMessage", "id": "assistant-id", "phase": "final_answer", "content": [{"type": "text", "text": "Retained."}]}}),
            record("event_msg", {"type": "task_started", "turn_id": "turn-2"}),
            event("user", "Please retain the existing experiment."),
        )
        excerpt = read_excerpt(self.path)
        self.assertEqual(excerpt.message_count, 3)
        self.assertEqual(excerpt.text.count("Retained."), 1)
        self.assertEqual(excerpt.text.count("Please retain"), 2)
        self.assertEqual(excerpt.diagnostics["duplicate_messages"], 4)

    def test_repeated_genuine_identical_messages_are_not_deduplicated(self):
        self.write(meta(), message("user", "yes"), message("user", "yes"))
        self.assertEqual(read_excerpt(self.path).message_count, 2)

    def test_cross_batch_dedup_state_is_hash_only(self):
        bounds = self.write(
            meta(),
            record("event_msg", {"type": "task_started", "turn_id": "turn-1"}),
            message("user", "Retain the queue."),
            event("user", "Retain the queue."),
            message("assistant", "Retained."),
        )
        first = read_excerpt(self.path, max_scan_bytes=bounds[3] - bounds[1])
        self.assertEqual(first.next_offset, bounds[3])
        self.assertEqual(first.message_count, 1)
        self.assertNotIn("Retain the queue", json.dumps(first.recent_messages))
        state = json.loads(json.dumps(first.recent_messages))
        second = read_excerpt(self.path, first.next_offset, recent_messages=state, current_turn_id=first.current_turn_id)
        self.assertEqual(second.message_count, 1)
        self.assertEqual(second.text, "[ASSISTANT]\nRetained.")
        self.assertEqual(second.diagnostics["duplicate_messages"], 1)
        self.assertEqual(state, first.recent_messages, "input cursor state must not be mutated")

    def test_bounded_batch_never_skips_unprocessed_visible_messages(self):
        bounds = self.write(meta(), message("user", "first"), message("assistant", "second"), message("user", "third"))
        first = read_excerpt(self.path, max_chars=15)
        self.assertEqual(first.text, "[USER]\nfirst")
        self.assertEqual(first.next_offset, bounds[2])
        self.assertTrue(first.has_more)
        self.assertIsNone(first.blocked_reason)
        second = read_excerpt(self.path, first.next_offset, recent_messages=first.recent_messages, max_chars=100)
        self.assertIn("second", second.text)
        self.assertIn("third", second.text)
        self.assertFalse(second.has_more)

    def test_single_oversized_message_remains_pending(self):
        bounds = self.write(meta(), message("user", "a" * 100), message("user", "tail"))
        excerpt = read_excerpt(self.path, max_chars=20)
        self.assertEqual(excerpt.next_offset, bounds[1])
        self.assertEqual(excerpt.text, "")
        self.assertEqual(excerpt.blocked_reason, "message_exceeds_char_limit")
        self.assertEqual(read_excerpt(self.path, excerpt.next_offset, max_chars=200).message_count, 2)

    def test_scan_limit_does_not_advance_inside_a_record(self):
        bounds = self.write(meta(), message("user", "a" * 100))
        excerpt = read_excerpt(self.path, max_scan_bytes=12)
        self.assertEqual(excerpt.next_offset, bounds[1])
        self.assertEqual(excerpt.blocked_reason, "record_exceeds_scan_limit")

    def test_partial_utf8_final_line_is_retried_after_append(self):
        encoded = json.dumps(message("user", "café 🦉"), ensure_ascii=False).encode("utf-8") + b"\n"
        cut = encoded.index("🦉".encode("utf-8")) + 2
        bounds = self.write(meta(), message("assistant", "earlier"), suffix=encoded[:cut])
        first = read_excerpt(self.path)
        self.assertEqual(first.next_offset, bounds[-1])
        self.assertEqual(first.blocked_reason, "partial_final_record")
        self.assertEqual(first.message_count, 1)
        with self.path.open("ab") as stream:
            stream.write(encoded[cut:])
        second = read_excerpt(self.path, first.next_offset, recent_messages=first.recent_messages)
        self.assertIn("café 🦉", second.text)
        self.assertFalse(second.has_more)

    def test_complete_json_without_newline_is_not_consumed_early(self):
        bounds = self.write(meta(), suffix=json.dumps(message("user", "wait")).encode())
        excerpt = read_excerpt(self.path)
        self.assertEqual(excerpt.next_offset, bounds[-1])
        self.assertEqual(excerpt.blocked_reason, "partial_final_record")

    def test_malformed_complete_lines_are_explicitly_counted(self):
        self.write(meta())
        with self.path.open("ab") as stream:
            stream.write(b"not-json\n[]\n\xff\n")
            stream.write(json.dumps(message("assistant", "Survived malformed records.")).encode() + b"\n")
        excerpt = read_excerpt(self.path)
        self.assertEqual(excerpt.diagnostics["malformed_records"], 3)
        self.assertIn("Survived", excerpt.text)
        self.assertFalse(excerpt.has_more)

    def test_fork_prefers_own_id_and_skips_materialized_inherited_ordinals(self):
        header = meta(session_id="parent", forked_from_id="parent", subagent_history_start_ordinal=5,
                      source={"subagent": {"thread_spawn": {"parent_thread_id": "parent"}}})
        header["ordinal"] = 0
        parent_header = meta(id="parent", cwd="/tmp/parent")
        parent_header["ordinal"] = 1
        self.write(header, parent_header, message("user", "inherited private request", ordinal=2),
                   message("assistant", "inherited result", ordinal=4),
                   message("user", "new child request", ordinal=5),
                   message("assistant", "new child result", ordinal=6))
        excerpt = read_excerpt(self.path)
        self.assertEqual(excerpt.metadata.session_id, "child-123")
        self.assertEqual(excerpt.metadata.cwd, "/tmp/project")
        self.assertEqual(excerpt.metadata.parent_session_id, "parent")
        self.assertEqual(excerpt.message_count, 2)
        self.assertNotIn("inherited", excerpt.text)
        self.assertEqual(excerpt.diagnostics["inherited_records"], 3)

    def test_paginated_fork_never_opens_history_base(self):
        header = meta(forked_from_id="parent", history_mode="paginated", forked_from_ordinal_exclusive=3021,
                      history_base={"thread_id": "parent", "end_ordinal_exclusive": 3021, "end_byte_offset": 12_000_000})
        header["ordinal"] = 3021
        self.write(header, message("user", "Local fork request", ordinal=3022))
        excerpt = read_excerpt(self.path)
        self.assertTrue(excerpt.metadata.fork_boundary_known)
        self.assertEqual(excerpt.message_count, 1)
        self.assertEqual(excerpt.metadata.history_start_ordinal, 3021)

    def test_fork_continuing_parent_ordinals_without_history_base(self):
        header = meta(forked_from_id="parent", forked_from_ordinal_exclusive=100)
        header["ordinal"] = 100
        self.write(header, message("user", "New request", ordinal=101))
        self.assertEqual(read_excerpt(self.path).message_count, 1)

    def test_unknown_fork_boundary_fails_closed(self):
        self.write(meta(forked_from_id="parent"), message("user", "May be inherited"))
        excerpt = read_excerpt(self.path)
        self.assertEqual(excerpt.next_offset, 0)
        self.assertEqual(excerpt.blocked_reason, "ambiguous_fork_history")
        self.assertEqual(excerpt.text, "")

    def test_missing_ordinal_in_known_fork_does_not_leak_history(self):
        bounds = self.write(meta(forked_from_id="parent", subagent_history_start_ordinal=5), message("user", "May be inherited"))
        excerpt = read_excerpt(self.path)
        self.assertEqual(excerpt.next_offset, bounds[1])
        self.assertEqual(excerpt.blocked_reason, "missing_fork_ordinal")
        self.assertEqual(excerpt.text, "")

    def test_redaction_and_injected_context_exclusion(self):
        secrets = ["sk-proj-" + "x" * 32, "xoxb-1234567890-abcdefghijkl", "hunter2", "abcdef.secret.token"]
        text = "API_KEY=" + secrets[0] + "\npassword: '" + secrets[2] + "'\nAuthorization: Bearer " + secrets[3] + "\n" + secrets[1]
        self.write(meta(), message("user", "<environment_context>PRIVATE unrelated context</environment_context>"), message("user", text))
        excerpt = read_excerpt(self.path)
        for secret in secrets:
            self.assertNotIn(secret, excerpt.text)
        self.assertNotIn("PRIVATE unrelated", excerpt.text)
        self.assertEqual(excerpt.diagnostics["redacted_messages"], 1)
        self.assertIn("[REDACTED]", excerpt.text)

    def test_private_key_and_password_url_redaction(self):
        text = "Keep plan.\n-----BEGIN OPENSSH PRIVATE KEY-----\nsecretvalue\n-----END OPENSSH PRIVATE KEY-----\nhttps://user:secretpass@example.test/path"
        safe = redact_secrets(text)
        self.assertIn("Keep plan.", safe)
        self.assertNotIn("secretvalue", safe)
        self.assertNotIn("secretpass", safe)
        self.assertNotIn("truncatedsecret", redact_secrets("-----BEGIN PRIVATE KEY-----\ntruncatedsecret"))

    def test_images_and_unknown_content_parts_are_never_serialized(self):
        self.write(meta(), record("response_item", {"type": "message", "role": "user", "content": [
            {"type": "input_image", "image_url": "data:SECRET"},
            {"type": "reasoning_text", "text": "SECRET hidden"},
            {"type": "input_text", "text": "Use this fixture."},
        ]}))
        excerpt = read_excerpt(self.path)
        self.assertNotIn("SECRET", excerpt.text)
        self.assertIn("Use this fixture.", excerpt.text)

    def test_cursor_must_be_binary_record_boundary_and_not_past_eof(self):
        self.write(meta(), message("user", "café"))
        with self.assertRaises(TranscriptError):
            read_excerpt(self.path, 3)
        with self.assertRaises(TranscriptError):
            read_excerpt(self.path, self.path.stat().st_size + 1)
        with self.assertRaises(TranscriptError):
            read_excerpt(self.path, True)

    def test_initial_metadata_is_required_and_must_be_complete(self):
        self.write(message("user", "not metadata"))
        with self.assertRaises(TranscriptError):
            inspect_rollout(self.path)
        self.path.write_bytes(json.dumps(meta()).encode())
        with self.assertRaises(TranscriptError):
            inspect_rollout(self.path)

    def test_result_and_cursor_are_json_serializable(self):
        self.write(meta(), message("user", "remember this"))
        parsed = json.loads(json.dumps(asdict(read_excerpt(self.path))))
        self.assertEqual(parsed["metadata"]["session_id"], "child-123")


if __name__ == "__main__":
    unittest.main()
