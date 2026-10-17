"""Strict retrospective profile for one expired replacement update.

This module validates evidence only. It never calls a provider or memory writer.
The externally pinned review authorizes a retrospective semantic assessment; it
does not recover a historical execution seal or prove continuous persistence.
"""
from __future__ import annotations

import datetime as dt
import math
from pathlib import Path
import re

KIND = "reviewed_expired_replacement_update_no_new_mutation"
ARTIFACTS = {"expired-update-coverage.json", "expired-update-independent-review.json",
             "expired-update-readback.json", "expired-update-intents.private.json"}
BEGIN_BUSY_TEXT = "Memory was not stored: the database was busy before the write transaction started. Retry on a later turn."
NO_WRITE = "not_stored_transaction_not_started"
DISPOSITIONS = {"represented_by_replacement_update", "expired_no_write_remember", "transient_or_ineligible"}
ATTRIBUTIONS = {"assistant_observation", "assistant_plan_or_proposal", "task_scoped_limitation"}
DAY = 86400


def _common():
    # Deferred to avoid an import cycle; the common module owns publication and
    # all filesystem/readback operations. This helper has no alternate entrypoint.
    from . import legacy_reconciliation
    return legacy_reconciliation


def _span(value, length, *, sentence=False):
    L = _common()
    keys = {"index", "start", "end", "sha256"} if sentence else {
        "id", "sentence_index", "start", "end", "sha256", "disposition", "rationale", "attribution"}
    L.codec._keys(value, keys)
    L.codec._integer(value["start"], 0, length)
    L.codec._integer(value["end"], 1, length)
    L._require(value["start"] < value["end"], "invalid_coverage_span")
    L.codec._digest(value["sha256"])


def validate_review(review):
    """Additional shape constraints; common bindings are checked by the caller."""
    L = _common()
    row = review["rows"][0]
    L._require(review["preserved_memory_ids"] == [row["globalId"]], "update_row_unbound")
    for key in ("createdAt", "modifiedAt", "expiresAt"):
        L._require(math.isfinite(row[key]), "invalid_row_date")
    L._require(type(review["attempts"]) is list and len(review["attempts"]) == 2,
               "mutation_count_changed")
    L._require(type(review["messages"]) is list and len(review["messages"]) == 13,
               "invalid_message_count")
    seen = set()
    last_end = review["source"]["start_offset"]
    for index, message in enumerate(review["messages"], 1):
        L.codec._keys(message, {"index", "role", "sha256", "disposition", "memory_ids",
                               "record", "body", "sentences", "clauses"})
        L._require(type(message["index"]) is int and message["index"] == index
                   and message["role"] == "assistant" and message["disposition"] == "reviewed_no_new_mutation",
                   "unsupported_message")
        L.codec._digest(message["sha256"])
        record, body = message["record"], message["body"]
        L.codec._keys(record, {"start_offset", "end_offset", "sha256"})
        L.codec._integer(record["start_offset"], last_end, review["source"]["end_offset"])
        L.codec._integer(record["end_offset"], record["start_offset"] + 1, review["source"]["end_offset"])
        L.codec._digest(record["sha256"])
        last_end = record["end_offset"]
        L.codec._keys(body, {"sha256", "chars"})
        L.codec._digest(body["sha256"])
        L.codec._integer(body["chars"], 1, 48000)
        sentences, clauses = message["sentences"], message["clauses"]
        L._require(type(sentences) is list and 1 <= len(sentences) <= 256
                   and type(clauses) is list and 1 <= len(clauses) <= 512, "invalid_clause_count")
        previous_end = 0
        for ordinal, sentence in enumerate(sentences, 1):
            _span(sentence, body["chars"], sentence=True)
            L._require(type(sentence["index"]) is int and sentence["index"] == ordinal
                       and sentence["start"] >= previous_end, "invalid_sentence_order")
            previous_end = sentence["end"]
        previous_end = 0
        for clause in clauses:
            _span(clause, body["chars"])
            L._identifier(clause["id"])
            L._require(clause["id"] not in seen, "duplicate_clause")
            seen.add(clause["id"])
            L.codec._integer(clause["sentence_index"], 1, len(sentences))
            sentence = sentences[clause["sentence_index"] - 1]
            L._require(sentence["start"] <= clause["start"] < clause["end"] <= sentence["end"]
                       and clause["start"] >= previous_end
                       and clause["disposition"] in DISPOSITIONS and clause["attribution"] in ATTRIBUTIONS,
                       "unsupported_clause")
            previous_end = clause["end"]
            L.codec._string(clause["rationale"], 4096)
            L._require(clause["attribution"] != "assistant_plan_or_proposal"
                       or clause["disposition"] != "represented_by_replacement_update", "proposal_promoted_to_fact")
            L._require(clause["attribution"] != "task_scoped_limitation"
                       or clause["disposition"] == "transient_or_ineligible", "limitation_promoted_to_fact")
        expected_ids = review["preserved_memory_ids"] if any(
            c["disposition"] == "represented_by_replacement_update" for c in clauses) else []
        L._require(L._same(message["memory_ids"], expected_ids), "message_row_unbound")


def _envelope(finish, *, error):
    """Strict supported Codex projection of the native MCP result.

    This profile supports the retained Codex projection, which omits native
    isError and normalizes structuredContent to structured_content (including
    null for a plain-text acknowledgement). Omission is not reconstructed as evidence:
    completion status plus the separately checked gateway audit remain required.
    """
    L = _common()
    L._require(finish.get("status") == ("failed" if error else "completed")
               and finish.get("error") is None, "provider_status_changed")
    result = finish.get("result")
    L.codec._keys(result, {"content", "structured_content"})
    content = result["content"]
    L._require(type(content) is list and len(content) == 1 and type(content[0]) is dict
               and set(content[0]) == {"type", "text"} and content[0]["type"] == "text",
               "native_content_changed")
    L.codec._string(content[0]["text"], 65536)
    return result, content[0]["text"]


def validate_history(review, history):
    L = _common()
    began, ended, mutations = L._serial_history(review, history, {"update", "remember"}, strict_projection=True)
    run = L._json(L._raw(history["run"]))
    L._require(run.get("request_id") == review["historical_request_id"], "historical_request_changed")
    L._require(len(mutations) == len(review["attempts"]) == 2
               and [start["tool"] for start, _, _ in mutations] == ["update", "remember"],
               "unsupported_mutation_sequence")
    row = review["rows"][0]
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    L._require(now > ended.timestamp() + 14 * DAY, "intent_not_expired")
    for index, ((start, finish, audit), expected) in enumerate(zip(mutations, review["attempts"])):
        L.codec._keys(expected, {"item_id", "audit_id", "arguments_sha256", "native_result_sha256",
                                "disposition", "memory_ids"})
        L._identifier(expected["item_id"])
        L.codec._integer(expected["audit_id"], 0, (1 << 31) - 1)
        for key in ("arguments_sha256", "native_result_sha256"):
            L.codec._digest(expected[key])
        L._require(start["id"] == expected["item_id"] and audit["id"] == expected["audit_id"]
                   and L.durable.digest(L.codec.encode(start["arguments"])) == expected["arguments_sha256"]
                   and L.durable.digest(L.codec.encode(finish["result"])) == expected["native_result_sha256"],
                   "attempt_changed")
        args = start["arguments"]
        L.codec._keys(args, {"id", "content", "source", "expires_in_days"} if index == 0 else {
            "content", "expires_in_days", "force", "is_private", "project", "source", "topic"})
        L._require(type(args["expires_in_days"]) is int and args["expires_in_days"] == 14
                   and args["source"] == "codex-session:" + review["session_id"], "unsupported_intent")
        L.codec._string(args["content"], 65536)
        L.codec._string(args["source"], 4096)
        result, text = _envelope(finish, error=index == 1)
        audit_fields = {"event", "id", "tool", "ok", "memory_ids", "forwarded"}
        if index == 0:
            L.codec._keys(audit, audit_fields)
            L._require(args["id"] == L.codec._uuid(args["id"]) == row["globalId"]
                       and expected["disposition"] == "original_success_preserved"
                       and expected["memory_ids"] == review["preserved_memory_ids"]
                       and audit["ok"] is True and audit["memory_ids"] == expected["memory_ids"]
                       and result.get("structured_content") is None, "success_changed")
            # The source format identifies the same UUID and lists exactly the
            # three supported edit modes. Previous values are acknowledgement
            # text only, never evidence of an independently observed prior row.
            header = re.match(r"^Updated memory \(id: ([0-9A-Fa-f-]{36}), project: ([^\n]*), topic: ([^\n]*)\)\.\nChanges:\n", text)
            L._require(header is not None and L.codec._uuid(header[1]) == args["id"]
                       and header[2] == row["project"] and header[3] == row["topic"], "native_update_ack_changed")
            changes = text[header.end():]
            change_match = re.fullmatch(r"content: [^\n]*\.\.\. → ([^\n]+)\.\.\.\nsource: [^\n]* → "
                        + re.escape(args["source"]) + r"\nexpires: [^\n]+ → (?!permanent$)[^\n]+", changes)
            L._require(change_match is not None and args["content"].startswith(change_match[1]),
                       "native_update_changes_changed")
            # Native uses locale-dependent DateFormatter.medium without time.
            # Do not invent a historical locale/timezone or infer the REAL
            # expiry from this display; exact expiry is independently bound
            # below. Swift's preview counts grapheme clusters, so validate it
            # as a nonempty prefix rather than a Python character count.
            L._require(row["content_sha256"] == L.durable.digest(args["content"].encode("utf-8"))
                       and row["source"] == args["source"] and row["deletedAt"] is None
                       and row["createdAt"] <= row["modifiedAt"]
                       and began.timestamp() <= row["modifiedAt"] <= ended.timestamp()
                       and began.timestamp() <= row["expiresAt"] - 14 * DAY <= ended.timestamp()
                       and row["expiresAt"] < now, "success_readback_mismatch")
        else:
            L.codec._keys(audit, audit_fields | {"write_outcome", "write_outcome_version"})
            for key in ("project", "topic"):
                L.codec._string(args[key], 4096, nonempty=False)
            L._require(args["is_private"] is True and args["force"] is False
                       and expected["disposition"] == "original_no_write_expired"
                       and expected["memory_ids"] == [] and audit["memory_ids"] == []
                       and audit["ok"] is False and type(audit["write_outcome_version"]) is int
                       and audit["write_outcome_version"] == 1 and audit["write_outcome"] == NO_WRITE,
                       "no_write_changed")
            structured = result.get("structured_content")
            L._require(text == BEGIN_BUSY_TEXT and type(structured) is dict
                       and set(structured) == {"engram_write_receipt"}, "native_no_write_missing")
            receipt = structured["engram_write_receipt"]
            L._require(type(receipt) is dict and type(receipt.get("schema_version")) is int
                       and L._same(receipt, {"schema_version": 1, "tool": "remember", "memory_ids": [],
                            "reason": "database_busy", "write_outcome": NO_WRITE}), "native_no_write_missing")
    return review["preserved_memory_ids"]


def validate_assessments(review, images):
    L = _common()
    reports = {name: L._json(L._raw(image)) for name, image in images.items()}
    common = {"schema_version", "session_id", "run_id"}
    schemas = {
        "expired-update-coverage.json": {"source", "parser", "messages", "attempts", "parser_diagnostics", "record_count", "conclusion"},
        "expired-update-independent-review.json": {"coverage_sha256", "decision", "message_count", "clause_count",
            "source_anchors_verified", "additional_eligible_operations", "unresolved_observations"},
        "expired-update-readback.json": {"row", "mode", "matches_historical_update"},
        "expired-update-intents.private.json": {"provider_file_sha256", "intents"},
    }
    for name, report in reports.items():
        L.codec._keys(report, common | schemas[name])
        L._require(type(report["schema_version"]) is int and report["schema_version"] == 1
                   and report["session_id"] == review["session_id"] and report["run_id"] == review["legacy_run_id"],
                   "assessment_selection_changed")
    coverage = reports["expired-update-coverage.json"]
    for key in ("source", "parser", "messages", "attempts"):
        L._require(L._same(coverage[key], review[key]), "coverage_binding_changed")
    diagnostics = coverage["parser_diagnostics"]
    L.codec._keys(diagnostics, {"malformed_records", "excluded_records", "inherited_records", "duplicate_messages", "redacted_messages"})
    for key, value in diagnostics.items():
        L.codec._integer(value, 0, L.context.MAX_SCAN)
        L._require(key == "excluded_records" or value == 0, "parser_coverage_incomplete")
    L._require(type(coverage["record_count"]) is int
               and coverage["record_count"] == diagnostics["excluded_records"] + 13
               and L._same(coverage["conclusion"], {"additional_eligible_operations": 0,
                   "unresolved_observations": 0, "proposal": "expired_no_new_write", "semantic_review_complete": True}),
               "semantic_coverage_incomplete")
    independent = reports["expired-update-independent-review.json"]
    L._require(independent["coverage_sha256"] == review["artifacts"]["expired-update-coverage.json"]
               and independent["decision"] == "approved" and independent["source_anchors_verified"] is True
               and type(independent["message_count"]) is int and independent["message_count"] == 13
               and type(independent["clause_count"]) is int
               and independent["clause_count"] == sum(len(m["clauses"]) for m in review["messages"])
               and type(independent["additional_eligible_operations"]) is int and independent["additional_eligible_operations"] == 0
               and type(independent["unresolved_observations"]) is int and independent["unresolved_observations"] == 0,
               "independent_review_changed")
    readback = reports["expired-update-readback.json"]
    L._require(readback["mode"] == "guarded_exact_uuid_read_only"
               and L._same(readback["row"], review["rows"][0])
               and L._same(readback["matches_historical_update"], {"content": True, "source": True,
                   "original_expiry": True, "modified_at": True}), "independent_success_changed")
    intents = reports["expired-update-intents.private.json"]
    L._require(intents["provider_file_sha256"] == review["history"]["provider"]
               and type(intents["intents"]) is list and len(intents["intents"]) == 2, "retained_intent_changed")
    for actual, expected in zip(intents["intents"], review["attempts"]):
        L.codec._keys(actual, {"provider_item_id", "audit_rpc_id", "arguments_canonical_json_sha256",
                              "original_outbound_native_arguments"})
        L._require(actual["provider_item_id"] == expected["item_id"] and actual["audit_rpc_id"] == expected["audit_id"]
                   and actual["arguments_canonical_json_sha256"] == expected["arguments_sha256"]
                   and L.durable.digest(L.codec.encode(actual["original_outbound_native_arguments"])) == expected["arguments_sha256"],
                   "retained_intent_changed")


def _body_coverage(body, message):
    L = _common()
    L._require(len(body) == message["body"]["chars"]
               and L.durable.digest(body.encode("utf-8")) == message["body"]["sha256"], "body_anchor_changed")
    sentence_covered, clause_covered = set(), set()
    for spans, covered in ((message["sentences"], sentence_covered), (message["clauses"], clause_covered)):
        for span in spans:
            value = body[span["start"]:span["end"]]
            L._require(value.strip() and L.durable.digest(value.encode("utf-8")) == span["sha256"], "clause_anchor_changed")
            covered.update(range(span["start"], span["end"]))
    required = {index for index, char in enumerate(body) if not char.isspace()}
    L._require(required <= sentence_covered and required <= clause_covered, "incomplete_clause_coverage")


def validate_source(request, review, excerpt, chunks):
    """Recheck whole JSONL records and exact eligible bodies within the interval.

    The ordinary parser has already reproduced the full excerpt. This bounded
    pass adds record coordinates and body/sentence/clause proofs. No scan outside
    the already selected interval, no memory search, and no alternate parser.
    """
    L = _common()
    L._require(all(value == 0 for key, value in excerpt.diagnostics.items() if key != "excluded_records"),
               "parser_coverage_incomplete")
    source = review["source"]
    current_turn = review["parser"]["input"]["current_turn_id"]
    found, record_count = [], 0
    with L.transcript._rollout_stream(Path(request["transcript_path"]), stable_identity=True) as stream:
        stream.seek(source["start_offset"])
        position = source["start_offset"]
        while position < source["end_offset"]:
            raw = stream.readline(source["end_offset"] - position)
            L._require(raw.endswith(b"\n"), "record_boundary_changed")
            record = L._json(raw)
            L._require(type(record) is dict, "invalid_source_record")
            record_count += 1
            payload = record.get("payload")
            if type(payload) is dict and (record.get("type") == "turn_context"
                    or record.get("type") == "event_msg" and payload.get("type") == "task_started"):
                current_turn = L.transcript._string(payload.get("turn_id")) or current_turn
            visible = L.transcript._visible_message(record, current_turn)
            if visible is not None:
                role, body, _, _, _ = visible
                L._require(role == "assistant" and len(found) < 13
                           and L.transcript.redact_secrets(body) == body, "source_message_changed")
                message = review["messages"][len(found)]
                L._require(L._same(message["record"], {"start_offset": position, "end_offset": position + len(raw),
                           "sha256": L.durable.digest(raw)}) and chunks[len(found)] == "[ASSISTANT]\n" + body,
                           "record_anchor_changed")
                _body_coverage(body, message)
                found.append(message)
            position += len(raw)
    L._require(len(found) == 13 and record_count == excerpt.diagnostics["excluded_records"] + 13,
               "record_coverage_changed")
    # Bind independently reviewed structural diagnostics to this reconstruction,
    # rather than accepting their asserted completeness alone.
    return {"record_count": record_count, "parser_diagnostics": excerpt.diagnostics}
