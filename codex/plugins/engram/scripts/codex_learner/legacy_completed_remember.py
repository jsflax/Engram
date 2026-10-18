"""Evidence-only profile for one completed permanent private remember.

The externally pinned review accounts for every message in a bounded historical
interval. This neither replays a mutation nor changes the old failed run. It
does not reconstruct omitted argument defaults: the native acknowledgement and
current exact row independently establish the preserved memory's semantics.
"""
from __future__ import annotations

import datetime as dt
import math
from pathlib import Path
import re

KIND = "reviewed_completed_remember_no_new_mutation"
ARTIFACTS = {"completed-remember-coverage.json", "completed-remember-independent-review.json",
             "completed-remember-readback.json", "completed-remember-intent.private.json"}
DISPOSITIONS = {"represented_by_preserved_remember", "represented_and_dated_progress", "dated_progress"}
PERMANENT_EXPIRY = 64092211200


def _common():
    from . import legacy_reconciliation
    return legacy_reconciliation


def validate_review(review):
    L = _common()
    row = review["rows"][0]
    L._require(review["preserved_memory_ids"] == [row["globalId"]]
               and row["isPrivate"] == 1 and row["expiresAt"] == PERMANENT_EXPIRY,
               "completed_row_unbound")
    for key in ("createdAt", "modifiedAt", "expiresAt"):
        L._require(math.isfinite(row[key]), "invalid_row_date")
    L._require(type(review["attempts"]) is list and len(review["attempts"]) == 1,
               "mutation_count_changed")
    L._require(type(review["messages"]) is list and 1 <= len(review["messages"]) <= 128,
               "invalid_message_count")
    previous_end = review["source"]["start_offset"]
    for index, message in enumerate(review["messages"], 1):
        L.codec._keys(message, {"index", "role", "sha256", "disposition", "memory_ids",
                                "record", "body", "rationale"})
        L._require(type(message["index"]) is int and message["index"] == index
                   and message["role"] == "assistant" and message["disposition"] in DISPOSITIONS,
                   "unsupported_message")
        L.codec._digest(message["sha256"])
        L.codec._string(message["rationale"], 4096)
        expected_ids = [] if message["disposition"] == "dated_progress" else review["preserved_memory_ids"]
        L._require(message["memory_ids"] == expected_ids, "message_row_unbound")
        record, body = message["record"], message["body"]
        L.codec._keys(record, {"start_offset", "end_offset", "sha256"})
        L.codec._integer(record["start_offset"], previous_end, review["source"]["end_offset"])
        L.codec._integer(record["end_offset"], record["start_offset"] + 1, review["source"]["end_offset"])
        L.codec._digest(record["sha256"])
        previous_end = record["end_offset"]
        L.codec._keys(body, {"sha256", "chars"})
        L.codec._digest(body["sha256"])
        L.codec._integer(body["chars"], 1, 48000)


def _trace(review, history):
    """Closed single-turn trace; notices never forgive failed tools/turns."""
    L = _common()
    provider, audit = (L._lines(L._raw(history[key])) for key in ("provider", "audit"))
    L._require(len(provider) >= 3 and len(audit) >= 4, "incomplete_history")
    L.codec._keys(provider[0], {"type", "thread_id"})
    L._require(provider[0]["type"] == "thread.started", "provider_start_missing")
    L.codec._uuid(provider[0]["thread_id"])
    L._require(provider[1] == {"type": "turn.started"} and provider[-1].get("type") == "turn.completed",
               "provider_not_terminal")
    L.codec._keys(provider[-1], {"type"}, {"usage"})
    if "usage" in provider[-1]:
        usage = provider[-1]["usage"]
        L._require(type(usage) is dict and set(usage) <= {"input_tokens", "cached_input_tokens",
                   "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"}, "invalid_usage")
        for value in usage.values():
            L.codec._integer(value)
    calls, pending, notices, messages = [], None, 0, []
    for event in provider[2:-1]:
        kind = event.get("type")
        if kind == "error":
            L.codec._keys(event, {"type", "message"})
            L.codec._string(event["message"], 4096)
            notices += 1
            L._require(notices <= 16, "provider_notice_limit")
            continue
        L.codec._keys(event, {"type", "item"})
        item = event["item"]
        L._require(type(item) is dict, "invalid_provider_item")
        if item.get("type") in {"agent_message", "reasoning"}:
            L.codec._keys(item, {"id", "type", "text"})
            L._identifier(item["id"])
            L.codec._string(item["text"], 65536)
            L._require(kind == "item.completed" and pending is None, "unexpected_provider_item")
            if item["type"] == "agent_message":
                messages.append(item["text"])
            continue
        L.codec._keys(item, {"id", "type", "server", "tool", "arguments", "result", "error", "status"})
        L._identifier(item["id"])
        L._require(item["type"] == "mcp_tool_call" and item["server"] == "memory"
                   and item["tool"] in L.READ_TOOLS | {"remember"}
                   and type(item["arguments"]) is dict and item["error"] is None,
                   "unaccounted_provider_tool")
        if kind == "item.started":
            L._require(pending is None and item["status"] == "in_progress" and item["result"] is None,
                       "provider_overlap")
            pending = item
        else:
            L._require(kind == "item.completed" and pending is not None and item["status"] == "completed"
                       and all(L._same(item[k], pending[k]) for k in ("id", "type", "server", "tool", "arguments")),
                       "provider_result_changed")
            L.codec._keys(item["result"], {"content", "structured_content"})
            L._require(type(item["result"]["content"]) is list, "invalid_tool_result")
            calls.append((pending, item))
            pending = None
    L._require(pending is None and 1 <= len(calls) <= 32
               and len({start["id"] for start, _ in calls}) == len(calls), "unfinished_call")
    L._require(audit[0] == {"event": "relay_started"}, "relay_start_changed")
    finish = audit[-1]
    L.codec._keys(finish, {"event", "child_reaped", "cleanup_overrun", "peak_inflight"},
                  {"peak_client_queue_bytes", "peak_server_queue_bytes"})
    L._require(finish["event"] == "relay_finished" and finish["child_reaped"] is True
               and finish["cleanup_overrun"] is False and type(finish["peak_inflight"]) is int
               and finish["peak_inflight"] == 1, "relay_not_terminal")
    for key in ("peak_client_queue_bytes", "peak_server_queue_bytes"):
        if key in finish:
            L.codec._integer(finish[key])
    results, active, interrupted, ids, compatibility = [], None, False, set(), False
    for index, event in enumerate(audit[1:-1], 1):
        kind = event.get("event")
        if kind == "initialize_compat":
            L._require(event == {"event": kind, "omitted_capability": "codex/auth-change"}
                       and active is None and not results and not compatibility, "unknown_audit_event")
            compatibility = True
        elif kind == "relay_interrupted":
            L._require(event == {"event": kind} and active is None and not interrupted
                       and index == len(audit) - 2, "relay_interruption_changed")
            interrupted = True
        elif kind == "tool_call":
            L.codec._keys(event, {"event", "id", "tool"})
            L.codec._integer(event["id"], 0, (1 << 31) - 1)
            L._require(active is None and event["id"] not in ids and len(results) < len(calls)
                       and event["tool"] == calls[len(results)][0]["tool"], "unaccounted_call")
            ids.add(event["id"])
            active = event
        else:
            L.codec._keys(event, {"event", "id", "tool", "ok", "memory_ids", "forwarded"})
            L._require(kind == "tool_result" and active is not None
                       and type(event["id"]) is int and event["id"] == active["id"]
                       and event["tool"] == active["tool"] and event["ok"] is True
                       and event["forwarded"] is True and event["memory_ids"] == (
                           review["preserved_memory_ids"] if event["tool"] == "remember" else []),
                       "unmatched_or_failed_result")
            results.append(event)
            active = None
    L._require(active is None and len(results) == len(calls), "call_correlation_changed")
    return calls, results, notices, interrupted, messages


def validate_history(review, history):
    L = _common()
    run, previous, result = (L._json(L._raw(history[k])) for k in ("run", "previous_run", "result"))
    calls, audit, notices, interrupted, messages = _trace(review, history)
    L._require(run.get("session_id") == review["session_id"] and run.get("status") == "failed"
               and run.get("reason") == "unverified_completion" and type(run.get("returncode")) is int
               and run["returncode"] == 0 and run.get("turn_completed") is True
               and run.get("provider_error") is bool(notices) and run.get("unexpected_tool") is False
               and run.get("timed_out", False) is False
               and run.get("request_id") == review["historical_request_id"]
               and run.get("end_offset") == review["source"]["end_offset"], "history_not_terminal")
    if "reconciliation_required" in run:
        L._require(run["reconciliation_required"] == {"run_id": review["legacy_run_id"],
                   "reason": "successful_or_unverified_write", "memory_ids": review["preserved_memory_ids"]},
                   "historical_gate_changed")
    for key, expected in (("tool_calls", len(calls)), ("write_calls", 1), ("tool_errors", int(interrupted))):
        L._require(type(run.get(key)) is int and run[key] == expected, "historical_counts_changed")
    L._require(run.get("writes") == [{"tool": "remember", "memory_ids": review["preserved_memory_ids"]}]
               and run.get("outcome") == "stored", "historical_writes_changed")
    began, ended = L._time(run["started_at"]), L._time(run["ended_at"])
    L._require(began <= ended and ended - began < dt.timedelta(hours=1), "invalid_run_window")
    L._require(previous.get("session_id") == review["session_id"] and previous.get("status") == "succeeded"
               and previous.get("end_offset") == review["source"]["start_offset"], "start_uncorroborated")
    L.codec._keys(result, {"outcome", "summary", "memory_ids"})
    L.codec._string(result["summary"], 65536)
    L._require(result["outcome"] == "stored" and type(result["memory_ids"]) is list
               and len(result["memory_ids"]) == 1
               and [L.codec._uuid(value) for value in result["memory_ids"]] == review["preserved_memory_ids"]
               and bool(messages) and L._same(L._json(messages[-1].encode()), result), "final_result_changed")
    writes = [(start, finish, event) for (start, finish), event in zip(calls, audit) if start["tool"] == "remember"]
    L._require(len(writes) == 1, "mutation_count_changed")
    start, finish, event = writes[0]
    attempt = review["attempts"][0]
    L.codec._keys(attempt, {"item_id", "audit_id", "arguments_sha256", "native_result_sha256", "disposition", "memory_ids"})
    L._require(attempt["item_id"] == start["id"] and type(attempt["audit_id"]) is int
               and attempt["audit_id"] == event["id"] and attempt["disposition"] == "original_success_preserved"
               and attempt["memory_ids"] == review["preserved_memory_ids"]
               and attempt["arguments_sha256"] == L.durable.digest(L.codec.encode(start["arguments"]))
               and attempt["native_result_sha256"] == L.durable.digest(L.codec.encode(finish["result"])), "attempt_changed")
    args = start["arguments"]
    L.codec._keys(args, {"content", "project", "topic", "source", "force"}, {"is_private"})
    L.codec._string(args["content"], 65536)
    for key in ("project", "topic", "source"):
        L.codec._string(args[key], 4096)
    L._require(args["source"] == "codex-session:" + review["session_id"] and args["force"] is False
               and ("is_private" not in args or args["is_private"] is True), "unsupported_intent")
    native, text = L.expired_update._envelope(finish, error=False)
    row = review["rows"][0]
    uuid = r"[0-9A-Fa-f-]{36}"
    header = re.match(r"^Stored memory \(id: (" + uuid + r"), project: " + re.escape(args["project"])
        + r", topic: " + re.escape(args["topic"]) + r", private: true(?:, auto-linked to \[id:" + uuid
        + r"\](?:, \[id:" + uuid + r"\])*)?\): ", text)
    L._require(native["structured_content"] is None and header is not None
               and L.codec._uuid(header[1]) == row["globalId"], "native_remember_ack_changed")
    preview = text[header.end():]
    L._require(bool(preview) and (preview == args["content"] or preview.endswith("...")
               and bool(preview[:-3]) and args["content"].startswith(preview[:-3])), "native_remember_preview_changed")
    L._require(row["content_sha256"] == L.durable.digest(args["content"].encode())
               and all(row[k] == args[k] for k in ("project", "topic", "source"))
               # Native initializes these with distinct clock reads. Neither
               # timestamp supplies an ordering proof for the other.
               and began.timestamp() <= row["createdAt"] <= ended.timestamp()
               and began.timestamp() <= row["modifiedAt"] <= ended.timestamp(),
               "success_readback_mismatch")
    return review["preserved_memory_ids"]


def validate_assessments(review, images):
    L = _common()
    reports = {name: L._json(L._raw(value)) for name, value in images.items()}
    schemas = {
        "completed-remember-coverage.json": {"source", "parser", "messages", "attempts", "parser_diagnostics", "record_count"},
        "completed-remember-independent-review.json": {"coverage_sha256", "decision", "message_count", "source_anchors_verified", "additional_eligible_operations", "unresolved_observations"},
        "completed-remember-readback.json": {"row", "store_identity", "mode"},
        "completed-remember-intent.private.json": {"provider_file_sha256", "attempt", "original_outbound_native_arguments"},
    }
    for name, report in reports.items():
        L.codec._keys(report, {"schema_version", "session_id", "run_id"} | schemas[name])
        L._require(type(report["schema_version"]) is int and report["schema_version"] == 1
                   and report["session_id"] == review["session_id"] and report["run_id"] == review["legacy_run_id"],
                   "assessment_selection_changed")
    coverage = reports["completed-remember-coverage.json"]
    for key in ("source", "parser", "messages", "attempts"):
        L._require(L._same(coverage[key], review[key]), "coverage_binding_changed")
    diagnostics = coverage["parser_diagnostics"]
    L.codec._keys(diagnostics, {"malformed_records", "excluded_records", "inherited_records", "duplicate_messages", "redacted_messages"})
    for key, value in diagnostics.items():
        L.codec._integer(value, 0, L.context.MAX_SCAN)
        L._require(key == "excluded_records" or value == 0, "parser_coverage_incomplete")
    L._require(type(coverage["record_count"]) is int
               and coverage["record_count"] == diagnostics["excluded_records"] + len(review["messages"]), "record_coverage_changed")
    independent = reports["completed-remember-independent-review.json"]
    L._require(independent["coverage_sha256"] == review["artifacts"]["completed-remember-coverage.json"]
               and independent["decision"] == "approved" and independent["source_anchors_verified"] is True
               and type(independent["message_count"]) is int and independent["message_count"] == len(review["messages"])
               and type(independent["additional_eligible_operations"]) is int and independent["additional_eligible_operations"] == 0
               and type(independent["unresolved_observations"]) is int and independent["unresolved_observations"] == 0,
               "independent_review_changed")
    readback = reports["completed-remember-readback.json"]
    L._require(readback["mode"] == "guarded_exact_uuid_read_only" and L._same(readback["row"], review["rows"][0])
               and L._same(readback["store_identity"], review["store_identity"]), "independent_success_changed")
    intent = reports["completed-remember-intent.private.json"]
    L._require(intent["provider_file_sha256"] == review["history"]["provider"]
               and L._same(intent["attempt"], review["attempts"][0])
               and L.durable.digest(L.codec.encode(intent["original_outbound_native_arguments"]))
                   == review["attempts"][0]["arguments_sha256"], "retained_intent_changed")


def validate_source(request, review, excerpt, chunks):
    L = _common()
    L._require(all(value == 0 for key, value in excerpt.diagnostics.items() if key != "excluded_records"),
               "parser_coverage_incomplete")
    source = review["source"]
    current_turn = review["parser"]["input"]["current_turn_id"]
    found, record_count = 0, 0
    with L.transcript._rollout_stream(Path(request["transcript_path"]), stable_identity=True) as stream:
        stream.seek(source["start_offset"])
        position = source["start_offset"]
        while position < source["end_offset"]:
            raw = stream.readline(source["end_offset"] - position)
            L._require(raw.endswith(b"\n"), "record_boundary_changed")
            # Source records use the already bounded transcript interval, not
            # the smaller retained-report limit. Keep the strict JSON checks.
            record = L.codec._json(raw, maximum=min(L.context.MAX_SCAN, source["end_offset"] - position))
            L._require(type(record) is dict, "invalid_source_record")
            record_count += 1
            payload = record.get("payload")
            if type(payload) is dict and (record.get("type") == "turn_context"
                    or record.get("type") == "event_msg" and payload.get("type") == "task_started"):
                current_turn = L.transcript._string(payload.get("turn_id")) or current_turn
            visible = L.transcript._visible_message(record, current_turn)
            if visible is not None:
                role, body, _, _, _ = visible
                L._require(role == "assistant" and found < len(review["messages"])
                           and L.transcript.redact_secrets(body) == body, "source_message_changed")
                message = review["messages"][found]
                L._require(L._same(message["record"], {"start_offset": position, "end_offset": position + len(raw),
                           "sha256": L.durable.digest(raw)}) and chunks[found] == "[ASSISTANT]\n" + body
                           and message["body"] == {"sha256": L.durable.digest(body.encode()), "chars": len(body)},
                           "record_anchor_changed")
                found += 1
            position += len(raw)
    L._require(found == len(review["messages"]) and record_count == excerpt.diagnostics["excluded_records"] + found,
               "record_coverage_changed")
    return {"record_count": record_count, "parser_diagnostics": excerpt.diagnostics}
