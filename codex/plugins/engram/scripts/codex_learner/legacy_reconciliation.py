"""Retrospective legacy interval review; no provider or memory mutations.

The caller explicitly pins a reviewed bundle. That pin is semantic review
authority, not a historical execution seal. Only one preserved successful
remember and one expired, authoritative failed-BEGIN remember are supported by
the original profile. A separately typed profile supports an expired replacement
update followed by an authoritative failed-BEGIN remember. A third evidence-only
profile accounts for one completed private permanent remember and no new writes.
Current V2 admission, exact source/parser, current row readback and historical
records are checked separately. All publication uses the normal coordinator.
"""
from __future__ import annotations

import base64
import copy
from dataclasses import dataclass
import datetime as dt
import functools
import os
from pathlib import Path
import re
import sqlite3
import stat
import time

from . import admission, execution_context as context, execution_manifest as codec
from . import file_identity, host_admission, migration as durable, transcript
from . import publication_coordinator as coordinator, publication_journal as publication
from . import legacy_expired_update as expired_update, legacy_completed_remember as completed_remember

KIND = "legacy_no_new_mutation"
RESULT = "legacy_reconciled_no_new_mutation"
MAX = 4 * 1024 * 1024
ROLES = {"run": "run.json", "result": "result.json", "audit": "mcp-audit.jsonl",
         "provider": "provider.jsonl", "transport": "transport.json", "schema": "schema.json"}
READ_TOOLS = {"recall", "graph", "list_topics", "stats", "timeline"}
DISPOSITIONS = {"already_represented_expired", "dated_progress", "original_intents_accounted"}
ARTIFACTS = {"legacy-reconciliation-assessment.json", "legacy-coverage-capture.json",
             "legacy-coverage-assessment.json", "legacy-residual-duplicate-assessment.json",
             "legacy-success-independent-readback.json", "legacy-residual-duplicate-target.private.json",
             "legacy-write-intents.private.json"}
ROW_FIELDS = ("globalId", "content", "project", "topic", "source", "isPrivate",
              "createdAt", "modifiedAt", "expiresAt", "deletedAt")
REVIEWED_ACCOUNTING = "reviewed_legacy_accounting"


def accounting_review(value):
    """A complete retrospective decision, never a recovered provider seal.

    The caller pins the entire reviewed document. Counts and projects are data;
    every eligible message and every historical mutation must have a disposition.
    Only permanent private remembers can enter the executable residual plan.
    """
    from . import operation_gateway as gateway
    import math
    codec._keys(value, {"schema_version", "kind", "status", "session_id", "legacy_run_id",
        "previous_run_id", "historical_request_id", "source", "parser", "history", "rows",
        "row_content", "store_identity", "preserve_without_replay", "message_dispositions",
        "attempts", "operations", "qualifications"})
    _require(type(value["schema_version"]) is int and value["schema_version"] == 1
             and value["kind"] == REVIEWED_ACCOUNTING
             and value["status"] == "reviewed_candidate_not_live_dispatch_authority", "invalid_accounting")
    admission._uuid(value["session_id"], 7)
    for name in ("legacy_run_id", "previous_run_id"):
        _identifier(value[name])
    _require(value["legacy_run_id"] != value["previous_run_id"], "invalid_previous_run")
    if value["historical_request_id"] is not None:
        _identifier(value["historical_request_id"])
    _require(value["qualifications"] == {"origin": "explicit_retrospective_full_review",
        "historical_run_status": "failed", "historical_execution_sealed": False,
        "source_binding_grade": "current_bounded_reconstruction",
        "current_cross_provider_capability": "unverified"}, "qualification_changed")
    source = value["source"]
    codec._keys(source, {"identity", "start", "end", "interval_sha256", "excerpt_sha256", "parser_sha256"})
    file_identity.validate(source["identity"])
    codec._integer(source["start"]); codec._integer(source["end"], source["start"] + 1)
    _require(source["end"] - source["start"] <= context.MAX_SCAN, "invalid_interval")
    for key in ("interval_sha256", "excerpt_sha256", "parser_sha256"):
        codec._digest(source[key])
    parser = value["parser"]
    codec._keys(parser, {"input", "next", "max_chars", "record_count", "diagnostics"})
    context._parser_state(parser["input"]); context._parser_state(parser["next"])
    _require(parser["input"]["offset"] == source["start"] and parser["next"]["offset"] == source["end"],
             "parser_interval_changed")
    codec._integer(parser["max_chars"], 1, 48000); codec._integer(parser["record_count"], 1, context.MAX_SCAN)
    codec._keys(value["history"], {"run", "result", "audit", "provider", "transport", "previous_run"})
    for digest in value["history"].values(): codec._digest(digest)
    codec._keys(value["store_identity"], {"device", "inode", "uid"})
    for number in value["store_identity"].values(): codec._integer(number)
    rows = value["rows"]
    _require(type(rows) is list and len(rows) <= 64, "invalid_rows")
    ids = []
    for row in rows:
        codec._keys(row, (set(ROW_FIELDS) - {"content"}) | {"content_sha256"})
        _require(codec._uuid(row["globalId"]) == row["globalId"], "noncanonical_row_id")
        ids.append(row["globalId"]); codec._digest(row["content_sha256"])
        for key in ("project", "topic", "source"): codec._string(row[key], 4096, nonempty=False)
        _require(type(row["isPrivate"]) is int and row["isPrivate"] in (0, 1) and row["deletedAt"] is None,
                 "invalid_row_privacy")
        for key in ("createdAt", "modifiedAt", "expiresAt"):
            _require(type(row[key]) in (int, float) and math.isfinite(row[key]), "invalid_row_date")
    _require(len(ids) == len(set(ids)), "duplicate_row_id")
    codec._keys(value["row_content"], set(ids))
    for row in rows:
        text = value["row_content"][row["globalId"]]; codec._string(text, 65536)
        _require(durable.digest(text.encode()) == row["content_sha256"], "row_content_changed")
    codec._keys(value["preserve_without_replay"], {"memory_ids"})
    preserved = value["preserve_without_replay"]["memory_ids"]
    _require(type(preserved) is list and len(preserved) <= 32
             and len(preserved) == len(set(preserved)) and set(preserved) <= set(ids), "preserved_ids_changed")
    attempts, operations, messages = value["attempts"], value["operations"], value["message_dispositions"]
    _require(type(attempts) is list and len(attempts) <= 32 and type(operations) is list
             and len(operations) <= 5 and type(messages) is list and 1 <= len(messages) <= 128,
             "accounting_limit")
    labels = ["op_" + str(i) for i in range(1, len(operations) + 1)]
    _require([op.get("id") for op in operations] == labels, "operation_inventory")
    attempt_ids = []
    for attempt in attempts:
        codec._keys(attempt, {"item_id", "audit_id", "tool", "arguments", "native_result_sha256",
                             "disposition", "memory_ids", "operations", "rationale"})
        _identifier(attempt["item_id"]); attempt_ids.append(attempt["item_id"])
        codec._integer(attempt["audit_id"], 0, (1 << 31) - 1)
        codec._digest(attempt["native_result_sha256"]); codec._string(attempt["rationale"], 4096)
        _require(attempt["tool"] in {"remember", "update"}, "unsupported_historical_mutation")
        gateway.mutation(attempt["tool"], attempt["arguments"])
        _require(attempt["disposition"] in {"preserved_success", "affirmative_no_write", "expired_no_write"},
                 "unknown_historical_outcome")
        _require(type(attempt["memory_ids"]) is list and type(attempt["operations"]) is list
                 and len(attempt["operations"]) <= 1 and set(attempt["operations"]) <= set(labels), "attempt_changed")
        if attempt["disposition"] == "preserved_success":
            _require(len(attempt["memory_ids"]) == 1 and set(attempt["memory_ids"]) <= set(preserved)
                     and attempt["operations"] == [], "preserved_write_is_executable")
        else:
            _require(attempt["memory_ids"] == [] and (attempt["disposition"] != "expired_no_write"
                     or attempt["operations"] == []), "expired_or_unknown_write_is_executable")
    _require(len(attempt_ids) == len(set(attempt_ids)) and set(preserved) == {
        mid for a in attempts if a["disposition"] == "preserved_success" for mid in a["memory_ids"]},
        "preserved_attempt_coverage")
    for index, message in enumerate(messages, 1):
        codec._keys(message, {"index", "role", "sha256", "record", "body", "disposition",
                             "memory_ids", "operations", "attempt_ids", "rationale"})
        _require(message["index"] == index and type(message["index"]) is int and message["role"] == "assistant"
                 and message["disposition"] in {"preserved", "covered", "expired", "dated_progress", "residual"},
                 "message_disposition_changed")
        codec._digest(message["sha256"]); codec._string(message["rationale"], 4096)
        _require(type(message["memory_ids"]) is list and set(message["memory_ids"]) <= set(ids)
                 and type(message["operations"]) is list and set(message["operations"]) <= set(labels)
                 and type(message["attempt_ids"]) is list and set(message["attempt_ids"]) <= set(attempt_ids), "message_unbound")
        _require(bool(message["operations"]) == (message["disposition"] == "residual"), "message_operation_changed")
        if message["disposition"] in {"preserved", "covered"}:
            _require(bool(message["memory_ids"]), "coverage_row_missing")
        linked=[a for a in attempts if a['item_id'] in message['attempt_ids']]
        if message['disposition']=='expired':
            _require(bool(message['memory_ids']) or any(a['disposition']=='expired_no_write' for a in linked),
                     'expired_coverage_missing')
        if message['disposition']=='residual':
            _require(not any(a['disposition']=='expired_no_write' for a in linked),'temporary_intent_not_executable')
        if message["disposition"] == "preserved":
            _require(set(message["memory_ids"]) <= set(preserved), "preserved_message_changed")
        for mid in message["memory_ids"]:
            row = rows[ids.index(mid)]
            if message["disposition"] == "expired": _require(row["expiresAt"] < time.time(), "row_not_expired")
            if message["disposition"] == "covered": _require(row["expiresAt"] > time.time(), "coverage_expired")
    _require({a for message in messages for a in message['attempt_ids']}==set(attempt_ids),
             'historical_message_coverage_changed')
    for op in operations:
        codec._keys(op, {"id", "tool", "arguments", "arguments_canonical_sha256", "messages", "attempt_ids",
                        "duplicate_review"})
        args = op["arguments"]
        codec._keys(args, {"content", "project", "topic", "source", "is_private", "force"}, {"parent_id"})
        _require(op["tool"] == "remember" and args["is_private"] is True and args["force"] is False
                 and args["source"] == "codex-session:" + value["session_id"], "unsupported_residual_policy")
        gateway.mutation("remember", args)
        _require(durable.digest(codec.encode(args)) == op["arguments_canonical_sha256"], "review_payload_changed")
        expected_messages = [m["index"] for m in messages if op["id"] in m["operations"]]
        _require(op["messages"] == expected_messages and bool(expected_messages), "residual_source_unbound")
        _require(op["attempt_ids"] == [a["item_id"] for a in attempts if op["id"] in a["operations"]],
                 "residual_attempt_unbound")
        _require(set(op['attempt_ids']) <= {a for m in messages if op['id'] in m['operations'] for a in m['attempt_ids']},
                 'residual_attempt_source_unbound')
        for attempt in attempts:
            if op["id"] in attempt["operations"]:
                _require(attempt["disposition"] == "affirmative_no_write" and attempt["tool"] == "remember"
                         and _same(attempt["arguments"], args), "historical_intent_changed_or_renewed")
            if "expires_in_days" in attempt["arguments"]:
                _require(not all(args.get(k)==attempt["arguments"].get(k) for k in ("content","project","topic")),
                         "temporary_intent_not_executable")
        duplicate = op["duplicate_review"]
        codec._keys(duplicate, {"decision", "compared_memory_ids", "rationale"})
        codec._string(duplicate["rationale"], 4096)
        _require(duplicate["decision"] == "distinct_reviewed_fact" and type(duplicate["compared_memory_ids"]) is list
                 and len(duplicate['compared_memory_ids'])==len(ids)
                 and set(duplicate["compared_memory_ids"]) == set(ids), "duplicate_review_unbound")
        _require(all(args['content'] != body for body in value['row_content'].values()), 'residual_already_present')
        if "parent_id" in args:
            parent = codec._uuid(args["parent_id"])
            _require(parent in ids and rows[ids.index(parent)]["isPrivate"] == 1
                     and rows[ids.index(parent)]["expiresAt"] > time.time(), "parent_unavailable_or_shared")
    return value


def _require(value, reason):
    if not value:
        raise ValueError("legacy_reconciliation_" + reason)


def _safe(function):
    @functools.wraps(function)
    def call(*args, **kwargs):
        try:
            return function(*args, **kwargs)
        except ValueError as error:
            if str(error).startswith("legacy_reconciliation_"):
                raise
            raise ValueError("legacy_reconciliation_invalid_or_changed") from None
        except (OSError, TypeError, KeyError, AttributeError, OverflowError, RuntimeError,
                sqlite3.Error, RecursionError, StopIteration, UnicodeError):
            raise ValueError("legacy_reconciliation_unavailable_or_changed") from None
    return call


def _same(a, b):
    return durable.encode(a) == durable.encode(b)


def _boundary(label):
    """Fixture seam; never controls production authorization."""


def _identifier(value):
    _require(type(value) is str and re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value), "invalid_identifier")


def _sealed(raw):
    return publication._image(raw)


def _raw(image):
    # Historical audit/provider evidence is JSONL, unlike journal pair images.
    # Preserve and authenticate arbitrary raw bytes without parsing as one JSON
    # object. Pair old/new images continue using publication._raw unchanged.
    codec._keys(image, {"bytes", "sha256"})
    codec._digest(image["sha256"])
    codec._string(image["bytes"], 4 * ((admission.MAX_BYTES + 2) // 3))
    raw = base64.b64decode(image["bytes"], validate=True)
    _require(len(raw) <= admission.MAX_BYTES and _same(_sealed(raw), image), "raw_image_changed")
    return raw


def _json(raw):
    return codec._json(raw, maximum=MAX)


def _time(value):
    _require(type(value) is str and len(value) <= 64, "invalid_time")
    result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    _require(result.tzinfo is not None, "invalid_time")
    return result


@dataclass(frozen=True)
class LegacyPaths:
    root: Path
    evidence_directory: Path
    package_root: Path
    candidate_store: Path

    def check(self, *, import_evidence=False):
        for path in (self.root, self.package_root, self.candidate_store):
            _require(isinstance(path, Path) and path.is_absolute()
                     and path.resolve(strict=True) == path, "untrusted_path")
        for path in (self.root, self.package_root):
            durable._directory(path)
        _require(isinstance(self.evidence_directory, Path) and self.evidence_directory.is_absolute(),
                 "untrusted_evidence_path")
        if import_evidence:
            _require(not durable._directory(self.evidence_directory).st_mode & 0o077, "nonprivate_evidence")
        _require(not self.root.stat().st_mode & 0o077, "nonprivate_directory")
        # The import directory is used only by prepare. Frozen reviewed bytes
        # live in the immutable plan; recovery never follows an old report path.
        return {key: str(getattr(self, key)) for key in ("root", "package_root", "candidate_store")}


def _runtime(paths):
    # Pin only the bounded implementation paths actually used by this command.
    modules = (Path(__file__), Path(context.__file__), Path(transcript.__file__), Path(codec.__file__),
               Path(admission.__file__), Path(host_admission.__file__), Path(file_identity.__file__),
               Path(durable.__file__), Path(publication.__file__), Path(coordinator.__file__),
               Path(expired_update.__file__), Path(completed_remember.__file__))
    result = {}
    for path in modules:
        raw, identity = durable._read(path, private=False, maximum=1024 * 1024)
        _require(not identity["mode"] & 0o022, "unsafe_runtime")
        result[path.name] = {"path": str(path), "sha256": durable.digest(raw)}
    return result


def _read_historical(root, run_id, role):
    _identifier(run_id)
    path = root / "runs" / run_id / ROLES[role]
    raw, identity = durable._read(path, private=role != "result", maximum=1024 * 1024)
    _require(not identity["mode"] & 0o022, "unsafe_history")
    return raw


def _rows(paths, expected, *, count=2):
    """Exact UUID read-only snapshot; no recall, SQL from evidence, or counters."""
    _require(type(expected) is list and len(expected) == count, "invalid_row_count")
    ids = [codec._uuid(row["globalId"]) for row in expected]
    _require(len(set(ids)) == len(ids), "duplicate_row_id")
    before = paths.candidate_store.lstat()
    _require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
             and before.st_nlink == 1, "unsafe_store")
    deadline = time.monotonic() + 3
    database = sqlite3.connect(paths.candidate_store.as_uri() + "?mode=ro", uri=True, timeout=0.2)
    try:
        database.execute("PRAGMA query_only=ON")
        database.set_progress_handler(lambda: int(time.monotonic() >= deadline), 1000)
        database.execute("BEGIN")
        actual = []
        for memory_id in ids:
            columns = ['CASE WHEN length(CAST("content" AS BLOB)) <= 65536 THEN "content" ELSE NULL END'
                       if key == "content" else ('substr("' + key + '",1,4097)' if key in ("project", "topic", "source")
                                                 else '"' + key + '"') for key in ROW_FIELDS]
            records = database.execute('SELECT ' + ','.join(columns)
                + ' FROM "Memory" WHERE "globalId" = ? COLLATE NOCASE LIMIT 2', (memory_id,)).fetchall()
            _require(len(records) == 1 and time.monotonic() < deadline, "row_missing_or_ambiguous")
            row = dict(zip(ROW_FIELDS, records[0]))
            row["globalId"] = codec._uuid(row["globalId"])
            _require(type(row["content"]) is str and len(row["content"].encode()) <= 65536,
                     "invalid_content")
            row["content_sha256"] = durable.digest(row.pop("content").encode("utf-8"))
            actual.append(row)
        _require(database.total_changes == 0, "unexpected_database_change")
        database.rollback()
    finally:
        database.close()
    after = paths.candidate_store.lstat()
    identity = {"device": before.st_dev, "inode": before.st_ino, "uid": before.st_uid}
    _require(identity == {"device": after.st_dev, "inode": after.st_ino, "uid": after.st_uid}
             and _same(actual, expected), "readback_changed")
    return identity


def _lines(raw):
    lines = raw.splitlines()
    _require(0 < len(lines) <= 1024, "invalid_line_count")
    return [_json(line) for line in lines]


def _serial_history(review, history, write_tools, *, strict_projection=False):
    """Correlate the complete serial trace under an explicit profile allowlist."""
    run = _json(_raw(history["run"]))
    _require(run.get("session_id") == review["session_id"] and run.get("status") == "failed"
             and run.get("reason") == "unverified_completion" and type(run.get("returncode")) is int
             and run["returncode"] == 0 and run.get("turn_completed") is True
             and (run.get("provider_error") is None or run.get("provider_error") is False)
             and (run.get("unexpected_tool") is None or run.get("unexpected_tool") is False)
             and run.get("end_offset") == review["source"]["end_offset"], "history_not_terminal")
    began, ended = _time(run["started_at"]), _time(run["ended_at"])
    _require(began <= ended and ended - began < dt.timedelta(hours=1), "invalid_run_window")
    previous = _json(_raw(history["previous_run"]))
    _require(previous.get("session_id") == review["session_id"] and previous.get("status") == "succeeded"
             and previous.get("end_offset") == review["source"]["start_offset"], "start_uncorroborated")
    provider = _lines(_raw(history["provider"]))
    audit = _lines(_raw(history["audit"]))
    _require(provider[-1].get("type") == "turn.completed", "provider_not_terminal")
    _require(audit[0].get("event") == "relay_started" and audit[-1].get("event") == "relay_finished"
             and audit[-1].get("child_reaped") is True and audit[-1].get("cleanup_overrun") is False
             and type(audit[-1].get("peak_inflight")) is int and audit[-1]["peak_inflight"] == 1,
             "relay_not_terminal")
    calls, results, active = [], [], None
    for event in audit[1:-1]:
        kind = event.get("event")
        if kind == "tool_call":
            _require(active is None and event.get("tool") in READ_TOOLS | write_tools, "unaccounted_call")
            if strict_projection:
                codec._keys(event, {"event", "id", "tool"})
            codec._integer(event.get("id"), 0, (1 << 31) - 1)
            active = event
            calls.append(event)
        elif kind == "tool_result":
            codec._integer(event.get("id"), 0, (1 << 31) - 1)
            _require(active is not None and event.get("id") == active.get("id")
                     and event.get("tool") == active.get("tool") and event.get("forwarded") is True,
                     "unmatched_result")
            results.append(event)
            active = None
        else:
            _require(kind in {"initialize_compat", "relay_interrupted"} and active is None,
                     "unknown_audit_event")
    _require(active is None and len({str(item.get("id")) for item in calls}) == len(calls), "unfinished_call")
    started, completed, pending = [], [], None
    _require(provider[0].get("type") == "thread.started" and provider[1].get("type") == "turn.started",
             "provider_start_missing")
    for event in provider[2:-1]:
        item = event.get("item", {})
        if item.get("type") != "mcp_tool_call":
            _require(event.get("type") == "item.completed" and type(item) is dict
                     and set(item) == {"id", "type", "text"}
                     and item["type"] in {"agent_message", "reasoning"}
                     and type(item["text"]) is str and pending is None,
                     "unexpected_provider_item")
            continue
        _require(item.get("server") == "memory" and item.get("tool") in READ_TOOLS | write_tools,
                 "unaccounted_provider_tool")
        if strict_projection:
            codec._keys(item, {"id", "type", "server", "tool", "arguments", "result", "error", "status"})
            _identifier(item["id"])
            _require(item["error"] is None, "provider_error_changed")
        if event.get("type") == "item.started":
            _require(pending is None, "provider_overlap")
            if strict_projection:
                _require(item["status"] == "in_progress" and item["result"] is None, "provider_start_changed")
            pending = item
            started.append(item)
        elif event.get("type") == "item.completed":
            _require(pending is not None and item.get("id") == pending.get("id")
                     and item.get("tool") == pending.get("tool")
                     and _same(item.get("arguments"), pending.get("arguments")), "provider_result_changed")
            if strict_projection:
                _require(item["status"] in {"completed", "failed"}
                         and (item["tool"] not in READ_TOOLS or item["status"] == "completed"),
                         "provider_status_changed")
            completed.append(item)
            pending = None
        else:
            _require(False, "unknown_provider_event")
    _require(pending is None and len(started) == len(calls)
             and [item["tool"] for item in started] == [item["tool"] for item in calls],
             "call_correlation_changed")
    if strict_projection:
        _require(len({item["id"] for item in started}) == len(started), "duplicate_provider_id")
    mutations = [(a, b, c) for a, b, c in zip(started, completed, results) if a["tool"] in write_tools]
    return began, ended, mutations


def accounting_history(review, history):
    """Account exact acknowledgements even when the old relay omitted its tail.

    Missing terminal relay telemetry is disclosed, not turned into a successful
    historical execution. Every serial provider call still needs its matching
    gateway result; every mutation needs native success or affirmative no-write.
    An unmatched call, unknown tool or ambiguous result keeps the original hold.
    """
    accounting_review(review)
    codec._keys(history, set(review["history"]))
    for role, digest in review["history"].items():
        _require(durable.digest(_raw(history[role])) == digest, "history_changed")
    run, previous = (_json(_raw(history[key])) for key in ("run", "previous_run"))
    _require(run.get("session_id") == review["session_id"] and run.get("status") == "failed"
             and type(run.get("returncode")) is int and run.get("unexpected_tool", False) is False
             and run.get("end_offset") == review["source"]["end"]
             and run.get("request_id") == review["historical_request_id"], "history_not_terminal")
    began, ended = _time(run["started_at"]), _time(run["ended_at"])
    _require(began <= ended and ended - began < dt.timedelta(hours=1), "invalid_run_window")
    _require(previous.get("session_id") == review["session_id"] and previous.get("status") == "succeeded"
             and previous.get("end_offset") == review["source"]["start"], "start_uncorroborated")
    gateway = _json(_raw(history['transport']))
    codec._keys(gateway, {'transport','audit_path','provenance','allowed_tools','max_tool_calls','max_writes'})
    _require(gateway['provenance']=='codex-session:'+review['session_id']
             and type(gateway['allowed_tools']) is list and len(gateway['allowed_tools'])==len(set(gateway['allowed_tools']))
             and set(gateway['allowed_tools'])<=READ_TOOLS|{'remember','update','connect'},'historical_gateway_changed')
    codec._integer(gateway['max_tool_calls'],1,1000);codec._integer(gateway['max_writes'],0,1000)
    audit_path=Path(gateway['audit_path'])
    _require(audit_path.is_absolute() and audit_path.parts[-3:]==('runs',review['legacy_run_id'],'mcp-audit.jsonl'),
             'historical_gateway_changed')
    transport=gateway['transport']
    codec._keys(transport,{'command'},{'type','args','env','env_vars','cwd'})
    codec._string(transport['command'],4096)
    _require(transport.get('type','stdio')=='stdio' and type(transport.get('args',[])) is list
             and all(type(arg) is str for arg in transport.get('args',[]))
             and type(transport.get('env',{})) is dict and all(type(k) is str and type(v) is str
                 for k,v in transport.get('env',{}).items())
             and type(transport.get('env_vars',[])) is list and all(type(v) is str for v in transport.get('env_vars',[]))
             and (transport.get('cwd') is None or type(transport['cwd']) is str and Path(transport['cwd']).is_absolute()),
             'historical_transport_changed')
    retained_result=_json(_raw(history['result']))
    codec._keys(retained_result,{'outcome','summary','memory_ids'})
    codec._string(retained_result['summary'],65536,nonempty=False)
    _require(retained_result['outcome'] in {'stored','no_new_memories','failed'}
             and type(retained_result['memory_ids']) is list and len(retained_result['memory_ids'])<=32,
             'historical_result_changed')
    for mid in retained_result['memory_ids']:codec._uuid(mid)
    provider, audit = (_lines(_raw(history[key])) for key in ("provider", "audit"))
    _require(len(provider) >= 3 and provider[0].get("type") == "thread.started"
             and provider[1] == {"type": "turn.started"}
             and provider[-1].get("type") in {"turn.completed", "turn.failed"}, "provider_not_terminal")
    calls, pending = [], None
    for event in provider[2:-1]:
        kind, item = event.get("type"), event.get("item")
        if kind == "error":
            codec._keys(event, {"type", "message"}); codec._string(event["message"], 4096)
            continue
        _require(type(item) is dict, "unknown_provider_event")
        if item.get("type") in {"agent_message", "reasoning"}:
            _require(kind == "item.completed" and pending is None, "unaccounted_provider_item")
            codec._keys(item, {"id", "type", "text"}); codec._string(item["text"], 65536)
            continue
        _require(item.get("type") == "mcp_tool_call" and item.get("server") == "memory"
                 and item.get("tool") in READ_TOOLS | {"remember", "update"}, "unaccounted_provider_tool")
        _identifier(item.get("id"))
        if kind == "item.started":
            _require(pending is None and item.get("result") is None, "provider_overlap")
            pending = item
        else:
            _require(kind == "item.completed" and pending is not None and all(
                _same(item.get(key), pending.get(key)) for key in ("id", "tool", "server", "type", "arguments")),
                "provider_result_changed")
            calls.append((pending, item)); pending = None
    _require(pending is None and len(calls) <= 64 and len({a["id"] for a, _ in calls}) == len(calls), "unfinished_call")
    _require(len(calls)<=gateway['max_tool_calls'] and all(a['tool'] in gateway['allowed_tools'] for a,_ in calls),
             'historical_gateway_changed')
    _require(audit[0] == {"event": "relay_started"}, "relay_start_changed")
    ended_relay = audit[-1].get("event") == "relay_finished"
    if ended_relay:
        _require(audit[-1].get("child_reaped") is True and audit[-1].get("cleanup_overrun") is False,
                 "relay_cleanup_failed")
    results, active, seen, interrupted = [], None, set(), False
    for event in audit[1:-1] if ended_relay else audit[1:]:
        kind = event.get("event")
        if kind == "initialize_compat":
            _require(active is None and not results and not interrupted, "unknown_audit_event")
        elif kind == "relay_interrupted":
            _require(active is None and not interrupted, "unknown_audit_event"); interrupted = True
        elif kind == "tool_call":
            codec._keys(event, {"event", "id", "tool"}); codec._integer(event["id"], 0, (1 << 31) - 1)
            _require(not interrupted and active is None and event["id"] not in seen
                     and len(results) < len(calls) and event["tool"] == calls[len(results)][0]["tool"], "unaccounted_call")
            seen.add(event["id"]); active = event
        else:
            codec._keys(event, {"event", "id", "tool", "ok", "memory_ids", "forwarded"},
                        {"write_outcome", "write_outcome_version"})
            _require(kind == "tool_result" and active is not None and event.get("id") == active["id"]
                     and event.get("tool") == active["tool"] and event.get("forwarded") is True,
                     "unmatched_result")
            results.append(event); active = None
    _require(active is None and len(calls) == len(results), "unfinished_call")
    mutations = [(a, b, event) for (a, b), event in zip(calls, results) if a["tool"] not in READ_TOOLS]
    _require(len(mutations) == len(review["attempts"]), "attempt_coverage_changed")
    _require(len(mutations)<=gateway['max_writes'],'historical_gateway_changed')
    _require(type(run.get('tool_calls')) is int and run['tool_calls']==len(calls)
             and type(run.get('write_calls')) is int and run['write_calls']==sum(
                 attempt['disposition']=='preserved_success' for attempt in review['attempts'])
             and _same(run.get('writes'),[{'tool':a['tool'],'memory_ids':a['memory_ids']}
                 for a in review['attempts'] if a['disposition']=='preserved_success']), 'historical_inventory_changed')
    rows = {row["globalId"]: row for row in review["rows"]}
    for (start, finish, event), attempt in zip(mutations, review["attempts"]):
        args = start["arguments"]
        _require(start["id"] == attempt["item_id"] and event["id"] == attempt["audit_id"]
                 and start["tool"] == attempt["tool"] and _same(args, attempt["arguments"])
                 and durable.digest(codec.encode(finish.get("result"))) == attempt["native_result_sha256"],
                 "attempt_changed")
        _require(args.get("source", gateway['provenance']) == gateway['provenance'],
                 "historical_source_changed")
        if attempt["disposition"] == "preserved_success":
            mid = attempt["memory_ids"][0]; row = rows[mid]; body = review["row_content"][mid]
            native, text = expired_update._envelope(finish, error=False)
            _require(event.get("ok") is True and [codec._uuid(v) for v in event.get("memory_ids", [])] == [mid]
                     and native["structured_content"] is None and row["isPrivate"] == 1
                     and args.get("is_private",True) is True and args.get("force",False) is False
                     and "write_outcome" not in event and "write_outcome_version" not in event, "success_changed")
            prefix = r"^Stored memory \(id: ([0-9A-Fa-f-]{36})," if start["tool"] == "remember" else r"^Updated memory \(id: ([0-9A-Fa-f-]{36}),"
            match = re.match(prefix, text)
            _require(match is not None and codec._uuid(match[1]) == mid, "native_ack_changed")
            if start["tool"] == "remember":
                _require(body == args["content"] and all(row[k] == args.get(k, "") for k in ("project", "topic"))
                         and ', private: true' in text and began.timestamp() <= row["createdAt"] <= ended.timestamp(),
                         "success_readback_mismatch")
            else:
                _require(codec._uuid(args["id"]) == mid and (body == args["content"] if "content" in args else
                         "append" in args and body.endswith(args["append"]) and body.count(args['append'])==1)
                         and began.timestamp() <= row["modifiedAt"] <= ended.timestamp(), "success_readback_mismatch")
            if "source" in args: _require(row["source"] == args["source"], "success_source_changed")
            if "expires_in_days" in args:
                ttl=args["expires_in_days"]
                _require(type(ttl) is int and ttl>0 and began.timestamp()+ttl*86400<=row["expiresAt"]<=ended.timestamp()+ttl*86400,
                         "historical_expiry_changed")
        else:
            native, text = expired_update._envelope(finish, error=True)
            receipt = native["structured_content"]
            receipt = receipt.get("engram_write_receipt") if type(receipt) is dict else None
            _require(start["tool"] == "remember" and text == expired_update.BEGIN_BUSY_TEXT and event.get("ok") is False
                     and event.get("memory_ids") == [] and event.get("write_outcome_version") == 1
                     and type(event.get("write_outcome_version")) is int
                     and event.get("write_outcome") == expired_update.NO_WRITE
                     and type(receipt) is dict and type(receipt.get("schema_version")) is int
                     and receipt == {"schema_version": 1, "tool": "remember", "memory_ids": [],
                         "reason": "database_busy", "write_outcome": expired_update.NO_WRITE}, "native_no_write_missing")
            ttl = args.get("expires_in_days")
            if attempt["disposition"] == "expired_no_write":
                _require(type(ttl) is int and ttl > 0 and time.time() > ended.timestamp() + ttl * 86400,
                         "intent_not_expired")
            elif attempt["operations"]:
                _require(ttl is None and "expires_in_days" not in args, "temporary_intent_not_executable")
    return {"attempts": len(mutations), "relay_terminal_retained": ended_relay,
            "historical_execution_sealed": False}


def accounting_source(request, review):
    accounting_review(review)
    source, parser = review["source"], review["parser"]
    _require(request["identity"] == source["identity"] and context._parser_runtime()["sha256"] == source["parser_sha256"]
             and context._interval(request["transcript_path"], source["identity"], source["start"], source["end"])
                == source["interval_sha256"], "source_changed")
    excerpt = transcript.read_excerpt(request["transcript_path"], source["start"], max_chars=parser["max_chars"],
        max_scan_bytes=source["end"] - source["start"], recent_messages=parser["input"]["recent_messages"],
        current_turn_id=parser["input"]["current_turn_id"], stable_identity=True)
    _require(excerpt.metadata.identity == source["identity"] and excerpt.metadata.session_id == review["session_id"]
             and excerpt.blocked_reason is None and _same(context._next_parser(excerpt), parser["next"])
             and durable.digest(excerpt.text.encode()) == source["excerpt_sha256"]
             and _same(excerpt.diagnostics, parser["diagnostics"]), "parser_output_changed")
    chunks = excerpt.text.split("\n\n[ASSISTANT]\n")
    _require(chunks[0].startswith("[ASSISTANT]\n"), "unsupported_message_role")
    chunks = [chunks[0]] + ["[ASSISTANT]\n" + item for item in chunks[1:]]
    _require(len(chunks) == excerpt.message_count == len(review["message_dispositions"])
             and all(durable.digest(text.encode()) == item["sha256"] for text, item in zip(chunks, review["message_dispositions"])),
             "message_coverage_changed")
    # Reuse the existing complete record projection: no malformed, truncated,
    # oversized, redacted or duplicate eligible record may silently disappear.
    adapted = {"source": {"start_offset": source["start"], "end_offset": source["end"]},
               "parser": parser, "messages": review["message_dispositions"]}
    projection = completed_remember.validate_source(request, adapted, excerpt, chunks)
    _require(projection["record_count"] == parser["record_count"], "record_coverage_changed")
    _require(context._interval(request["transcript_path"], source["identity"], source["start"], source["end"])
             == source["interval_sha256"] and context._parser_runtime()["sha256"] == source["parser_sha256"], "source_changed")
    return excerpt


def _history(review, history):
    """Validate exact serial native attempts, not provider prose."""
    if review["kind"] == completed_remember.KIND:
        return completed_remember.validate_history(review, history)
    if review["kind"] == expired_update.KIND:
        return expired_update.validate_history(review, history)
    began, ended, mutations = _serial_history(review, history, {"remember"})
    _require(len(mutations) == len(review["attempts"]) == 2, "mutation_count_changed")
    retained = []
    for (start, finish, result), expected in zip(mutations, review["attempts"]):
        codec._keys(expected, {"item_id", "audit_id", "arguments_sha256", "native_result_sha256",
                              "disposition", "memory_ids"})
        _identifier(expected["item_id"])
        codec._integer(expected["audit_id"], 0, (1 << 31) - 1)
        _require(type(expected["memory_ids"]) is list and len(expected["memory_ids"]) <= 1, "invalid_memory_ids")
        for key in ("arguments_sha256", "native_result_sha256"):
            codec._digest(expected[key])
        _require(start["id"] == expected["item_id"] and result["id"] == expected["audit_id"]
                 and durable.digest(codec.encode(start["arguments"])) == expected["arguments_sha256"]
                 and durable.digest(codec.encode(finish["result"])) == expected["native_result_sha256"],
                 "attempt_changed")
        args = start["arguments"]
        codec._keys(args, {"content", "expires_in_days", "force", "is_private", "project", "source", "topic"})
        _require(type(args) is dict and type(args.get("expires_in_days")) is int
                 and args["expires_in_days"] == 14 and type(args["is_private"]) is bool and type(args["force"]) is bool
                 and args.get("source") == "codex-session:" + review["session_id"],
                 "unsupported_intent")
        codec._string(args["content"], 65536)
        for key in ("project", "source", "topic"):
            codec._string(args[key], 4096, nonempty=False)
        _require(dt.datetime.now(dt.timezone.utc) > ended + dt.timedelta(days=14), "intent_not_expired")
        if expected["disposition"] == "original_success_preserved":
            _require(result.get("ok") is True and len(expected["memory_ids"]) == 1
                     and result.get("memory_ids") == expected["memory_ids"], "success_changed")
            memory_id = codec._uuid(expected["memory_ids"][0])
            row = next((r for r in review["rows"] if r["globalId"] == memory_id), None)
            _require(row is not None and row["content_sha256"] == durable.digest(args["content"].encode())
                     and all(row[k] == args[k] for k in ("project", "topic", "source"))
                     and row["isPrivate"] == int(args["is_private"]) and row["deletedAt"] is None
                     and type(row["expiresAt"]) in (int, float)
                     and began.timestamp() <= row["createdAt"] <= ended.timestamp()
                     and (began + dt.timedelta(days=14)).timestamp() <= row["expiresAt"]
                         <= (ended + dt.timedelta(days=14)).timestamp()
                     and row["expiresAt"] < dt.datetime.now(dt.timezone.utc).timestamp(), "success_readback_mismatch")
            retained.append(memory_id)
        else:
            _require(expected["disposition"] == "original_no_write_expired"
                     and expected["memory_ids"] == [] and result.get("ok") is False
                     and result.get("memory_ids") == [] and type(result.get("write_outcome_version")) is int
                     and result["write_outcome_version"] == 1
                     and result.get("write_outcome") == "not_stored_transaction_not_started", "no_write_changed")
            receipt = finish["result"].get("structured_content", {}).get("engram_write_receipt")
            _require(_same(receipt, {"schema_version": 1, "tool": "remember", "memory_ids": [],
                     "reason": "database_busy", "write_outcome": "not_stored_transaction_not_started"}),
                     "native_no_write_missing")
    _require(len(retained) == 1 and set(review["preserved_memory_ids"]) == set(retained), "preserved_ids_changed")
    return retained


def _review(value):
    codec._keys(value, {"version", "kind", "session_id", "legacy_run_id", "previous_run_id",
        "historical_request_id", "source", "parser", "messages", "attempts", "rows", "store_identity",
        "preserved_memory_ids", "artifacts", "history", "qualifications"})
    codec._version(value["version"])
    is_update = value["kind"] == expired_update.KIND
    is_completed = value["kind"] == completed_remember.KIND
    _require(is_update or is_completed or value["kind"] == "reviewed_legacy_no_new_mutation", "invalid_review")
    admission._uuid(value["session_id"], 7)
    for key in ("legacy_run_id", "previous_run_id", "historical_request_id"):
        # Older completed runs did not retain a request ID. Do not invent one.
        if key != "historical_request_id" or not is_completed or value[key] is not None:
            _identifier(value[key])
    _require(value["legacy_run_id"] != value["previous_run_id"], "invalid_previous_run")
    codec._keys(value["history"], set(ROLES) | {"previous_run"})
    _require(type(value["artifacts"]) is dict
             and set(value["artifacts"]) == (completed_remember.ARTIFACTS if is_completed else
                 expired_update.ARTIFACTS if is_update else ARTIFACTS), "invalid_artifacts")
    for name, digest in value["artifacts"].items():
        _require(re.fullmatch(r"[a-z][a-z0-9.-]{0,100}\.json", name), "invalid_artifact_name")
        codec._digest(digest)
    for digest in value["history"].values():
        codec._digest(digest)
    _require(_same(value["qualifications"], {"historical_run_status": "failed",
        "historical_execution_sealed": False, "source_binding_grade": "current_bounded_reconstruction",
        "current_cross_provider_capability": "unverified"}), "qualification_changed")
    codec._keys(value["source"], {"identity", "start_offset", "end_offset", "interval_sha256", "excerpt_sha256"})
    file_identity.validate(value["source"]["identity"])
    for key in ("interval_sha256", "excerpt_sha256"):
        codec._digest(value["source"][key])
    codec._keys(value["parser"], {"input", "next", "runtime_sha256", "max_chars"})
    for key in ("input", "next"):
        codec._keys(value["parser"][key], {"offset", "recent_messages", "current_turn_id"})
    context._parser_state(value["parser"]["input"])
    context._parser_state(value["parser"]["next"])
    codec._digest(value["parser"]["runtime_sha256"])
    codec._integer(value["parser"]["max_chars"], 1, 48000)
    codec._keys(value["store_identity"], {"device", "inode", "uid"})
    for field in value["store_identity"].values():
        codec._integer(field)
    _require(type(value["rows"]) is list and len(value["rows"]) == (1 if is_update or is_completed else 2), "invalid_rows")
    for row in value["rows"]:
        codec._keys(row, (set(ROW_FIELDS) - {"content"}) | {"content_sha256"})
        _require(codec._uuid(row["globalId"]) == row["globalId"], "noncanonical_row_id")
        codec._digest(row["content_sha256"])
        for key in ("project", "topic", "source"):
            codec._string(row[key], 4096, nonempty=False)
        _require(type(row["isPrivate"]) is int and row["isPrivate"] in (0, 1), "invalid_privacy")
        for key in ("createdAt", "modifiedAt", "expiresAt"):
            _require(type(row[key]) in (int, float), "invalid_row_date")
        _require(row["deletedAt"] is None, "row_deleted")
    _require(type(value["preserved_memory_ids"]) is list and len(value["preserved_memory_ids"]) == 1,
             "invalid_preserved_ids")
    codec._uuid(value["preserved_memory_ids"][0])
    if is_completed:
        completed_remember.validate_review(value)
        return value
    if is_update:
        expired_update.validate_review(value)
        return value
    _require(type(value["messages"]) is list and 1 <= len(value["messages"]) <= 128, "invalid_messages")
    for index, message in enumerate(value["messages"], 1):
        codec._keys(message, {"index", "role", "sha256", "disposition", "memory_ids"})
        _require(type(message["index"]) is int and message["index"] == index
                 and message["role"] == "assistant" and message["disposition"] in DISPOSITIONS,
                 "unsupported_message")
        codec._digest(message["sha256"])
        _require(type(message["memory_ids"]) is list and len(message["memory_ids"]) <= 2,
                 "invalid_message_ids")
        for memory_id in message["memory_ids"]:
            codec._uuid(memory_id)
    return value


def _assessment_links(review, images):
    """Bind the reviewed decision to the actual independent retained reports."""
    if review["kind"] == completed_remember.KIND:
        return completed_remember.validate_assessments(review, images)
    if review["kind"] == expired_update.KIND:
        return expired_update.validate_assessments(review, images)
    reports = {name: _json(_raw(image)) for name, image in images.items()}
    for name, report in reports.items():
        _require(type(report.get("schema_version")) is int and report["schema_version"] == 1,
                 "assessment_version_changed")
        if name != "legacy-residual-duplicate-target.private.json":
            _require(report.get("session_id") == review["session_id"]
                     and report.get("run_id") == review["legacy_run_id"], "assessment_selection_changed")
    original = reports["legacy-reconciliation-assessment.json"]
    capture = reports["legacy-coverage-capture.json"]
    coverage = reports["legacy-coverage-assessment.json"]
    duplicate = reports["legacy-residual-duplicate-assessment.json"]
    readback = reports["legacy-success-independent-readback.json"]
    target = reports["legacy-residual-duplicate-target.private.json"]["row"]
    intents = reports["legacy-write-intents.private.json"]
    source = review["source"]
    interval = [source["start_offset"], source["end_offset"]]
    reconstructed = original["source_reconstruction"]
    _require(original["state"]["pending_request_id"] == review["historical_request_id"]
             and reconstructed["candidate_start_offset"] == interval[0]
             and reconstructed["recorded_failed_end_offset"] == interval[1]
             and reconstructed["candidate_interval_sha256"] == source["interval_sha256"]
             and reconstructed["reconstructed_excerpt_sha256"] == source["excerpt_sha256"]
             and capture["source_interval"] == interval and capture["source_identity"] == source["identity"]
             and capture["interval_sha256"] == source["interval_sha256"]
             and capture["excerpt"]["sha256"] == source["excerpt_sha256"], "assessment_source_changed")
    bindings = coverage["input_bindings"]
    _require(bindings["source_interval"] == interval and bindings["source_interval_sha256"] == source["interval_sha256"]
             and bindings["excerpt"]["sha256"] == source["excerpt_sha256"]
             and bindings["independent_success_readback_sha256"] == review["artifacts"]["legacy-success-independent-readback.json"]
             and bindings["private_original_intents_sha256"] == review["artifacts"]["legacy-write-intents.private.json"]
             and duplicate["input_bindings"]["coverage_assessment_sha256"] == review["artifacts"]["legacy-coverage-assessment.json"]
             and duplicate["input_bindings"]["original_assessment_sha256"] == review["artifacts"]["legacy-reconciliation-assessment.json"],
             "assessment_links_changed")
    conclusions = duplicate["conclusions"]
    _require(conclusions["no_justified_new_mutation_from_retained_candidate_interval"] is True
             and conclusions["historical_original_provider_completed_successfully"] is False
             and conclusions["historical_execution_manifest_or_excerpt_seal_recovered"] is False
             and conclusions["current_cross_provider_capability"] == "unverified"
             and conclusions["cursor_advancement_or_gate_release_performed"] is False,
             "unsupported_review_conclusion")
    categories = {"already_represented_by_existing_expired_qualified_memory; no_new_mutation": "already_represented_expired",
        "dated_assistant_progress; no_new_durable_fact_supported": "dated_progress",
        "two_original_intents_accounted; original_success_preserved; original_no_write_expired; no_new_mutation": "original_intents_accounted"}
    mapping = {}
    for group in duplicate["candidate_interval_dispositions"]:
        _require(group["disposition"] in categories, "unsupported_disposition")
        for index in group["message_indexes"]:
            _require(type(index) is int and index not in mapping, "duplicate_message_disposition")
            mapping[index] = categories[group["disposition"]]
    _require(mapping == {item["index"]: item["disposition"] for item in review["messages"]}, "incomplete_message_review")
    successful = next(row for row in review["rows"] if row["globalId"] == review["preserved_memory_ids"][0])
    _require(readback["memory_id"] == successful["globalId"] and readback["content_sha256"] == successful["content_sha256"]
             and all(readback["matches_historical_successful_intent"].get(key) is True
                     for key in ("content", "project", "topic", "source", "is_private")), "independent_success_changed")
    for public, column in (("created_at", "createdAt"), ("modified_at", "modifiedAt"), ("expires_at", "expiresAt")):
        _require(abs(_time(readback[public]).timestamp() - successful[column]) < 0.000002, "independent_date_changed")
    _require(readback["deleted_at"] is None, "independent_success_deleted")
    target = {key: target[key] for key in ROW_FIELDS}
    target["globalId"] = codec._uuid(target["globalId"])
    target["content_sha256"] = durable.digest(target.pop("content").encode("utf-8"))
    pinned_target = next((row for row in review["rows"] if row["globalId"] == target["globalId"]), None)
    _require(pinned_target is not None, "independent_duplicate_missing")
    # The retained readback report renders native REAL Unix dates as ISO text.
    # Permit only its bounded microsecond rendering loss, then compare every
    # other field exactly. Live SQL rows still match the pinned REALs exactly.
    for key in ("createdAt", "modifiedAt", "expiresAt"):
        if type(target[key]) is str:
            _require(abs(_time(target[key]).timestamp() - pinned_target[key]) <= 0.000002,
                     "independent_duplicate_date_changed")
            target[key] = pinned_target[key]
    _require(any(_same(target, row) for row in review["rows"])
             and target["globalId"] not in review["preserved_memory_ids"]
             and duplicate["coverage_mapping"]["existing_memory_id"] == target["globalId"]
             and duplicate["coverage_mapping"]["content_sha256"] == target["content_sha256"]
             and intents["provider_file_sha256"] == review["history"]["provider"]
             and len(intents["intents"]) == len(review["attempts"]), "independent_duplicate_or_intent_changed")
    for retained, expected in zip(intents["intents"], review["attempts"]):
        _require(retained["provider_item_id"] == expected["item_id"] and retained["audit_rpc_id"] == expected["audit_id"]
                 and retained["arguments_canonical_json_sha256"] == expected["arguments_sha256"]
                 and durable.digest(codec.encode(retained["original_outbound_native_arguments"])) == expected["arguments_sha256"],
                 "retained_intent_changed")
    for message in review["messages"]:
        expected_ids = ([target["globalId"]] if message["disposition"] == "already_represented_expired"
                        else review["preserved_memory_ids"] if message["disposition"] == "original_intents_accounted" else [])
        _require(message["memory_ids"] == expected_ids, "message_provenance_changed")


def _source(request, review):
    source, parser = review["source"], review["parser"]
    _require(context._parser_runtime()["sha256"] == parser["runtime_sha256"], "parser_changed")
    start, end = source["start_offset"], source["end_offset"]
    _require(type(start) is int and type(end) is int and 0 <= start < end
             and end - start <= context.MAX_SCAN and parser["input"]["offset"] == start
             and parser["next"]["offset"] == end and request["identity"] == source["identity"],
             "invalid_interval")
    path = request["transcript_path"]
    _require(context._interval(path, source["identity"], start, end) == source["interval_sha256"], "source_changed")
    excerpt = transcript.read_excerpt(path, start, max_chars=parser["max_chars"], max_scan_bytes=end - start,
        recent_messages=parser["input"]["recent_messages"], current_turn_id=parser["input"]["current_turn_id"],
        stable_identity=True)
    _require(excerpt.metadata.identity == source["identity"] and excerpt.metadata.session_id == review["session_id"]
             and excerpt.next_offset == end and excerpt.blocked_reason is None
             and durable.digest(excerpt.text.encode()) == source["excerpt_sha256"]
             and _same(context._next_parser(excerpt), parser["next"]), "parser_output_changed")
    chunks = excerpt.text.split("\n\n[ASSISTANT]\n")
    _require(chunks[0].startswith("[ASSISTANT]\n"), "unsupported_message_role")
    chunks = [chunks[0]] + ["[ASSISTANT]\n" + chunk for chunk in chunks[1:]]
    _require(len(chunks) == excerpt.message_count == len(review["messages"])
             and all(durable.digest(chunk.encode()) == item["sha256"] for chunk, item in zip(chunks, review["messages"])),
             "message_coverage_changed")
    projection = None
    if review["kind"] == completed_remember.KIND:
        projection = completed_remember.validate_source(request, review, excerpt, chunks)
    elif review["kind"] == expired_update.KIND:
        projection = expired_update.validate_source(request, review, excerpt, chunks)
    _require(context._interval(path, source["identity"], start, end) == source["interval_sha256"]
             and context._parser_runtime()["sha256"] == parser["runtime_sha256"], "source_changed")
    return projection


def _selected(paths, session_id):
    names = admission.state_paths(paths.root, session_id)
    return coordinator.Paths(names["sessions"], names["admissions"], names["pending"],
                             paths.root / "publications" / session_id)


def _active_if_present(selected, session_id):
    # Older installed learners have no publication container. Read-only
    # preparation must not create one, and absence cannot contain an active
    # ticket. Existing containers still receive the coordinator's full checks.
    parent = selected.session_directory.parent
    if not os.path.lexists(parent):
        durable._directory(parent.parent)
        return None
    return coordinator._active(selected, session_id)


def _pending_pause(request, *, completed=False):
    # Structural queue validation, not authority to accept a held interval.
    # Every historical profile separately authenticates its state/gate, source,
    # history and readback. Keep the keyword for existing residual callers.
    _identifier(request.get("request_id"))
    if "paused_request_id" in request or "pause_reason" in request:
        _require(request.get("paused_request_id") == request["request_id"]
                 and request.get("pause_reason") in {"batch_limit", "failed", "backoff", "blocked",
                                                      "reconciliation_required"},
                 "unsupported_pending_pause")


def _reference(review, reconciliation_id, digest):
    return {"version": 1, "id": reconciliation_id, "legacy_run_id": review["legacy_run_id"],
            "evidence_sha256": digest, "interval": {k: v for k, v in review["source"].items() if k != "identity"},
            "memory_ids": review["preserved_memory_ids"]}


def _proposal(state, record, review, reconciliation_id, digest):
    result = copy.deepcopy(state)
    result.update(review["parser"]["next"])
    result.update(status=RESULT, last_reconciliation=_reference(review, reconciliation_id, digest))
    del result["reconciliation_required"]
    return result, {**record, "state_sha256": durable.object_digest(result)}


def _validate(paths, plan):
    codec._keys(plan, {"version", "kind", "id", "paths", "runtime", "review", "review_sha256",
                      "artifacts", "history", "inputs", "next_state", "next_admission"})
    codec._version(plan["version"])
    admission._uuid(plan["id"], 4)
    _require(plan["kind"] == KIND and plan["paths"] == paths.check()
             and _same(plan["runtime"], _runtime(paths)), "plan_binding_changed")
    review_raw = _raw(plan["review"])
    _require(durable.digest(review_raw) == plan["review_sha256"], "review_changed")
    review = _review(_json(review_raw))
    codec._keys(plan["inputs"], {"state", "admission", "pending"})
    values = {key: _json(publication._raw(image, old=True)) for key, image in plan["inputs"].items()}
    request, state, record = values["pending"], values["state"], values["admission"]
    _pending_pause(request)
    binding = admission.check(paths.root, request)
    _require(binding.get("mode") == host_admission.MODE_V2 and _same(request["admission"], binding)
             and _same(state.get("admission"), binding) and _same(record.get("binding"), binding)
             and record.get("state_sha256") == durable.object_digest(state)
             and record.get("processing") is None and "processing_execution" not in record
             and state.get("session_id") == review["session_id"] == request.get("session_id")
             and state.get("identity") == request.get("identity") == binding["identity"]
             and state.get("transcript_path") == request.get("transcript_path")
             and state.get("last_run") == review["legacy_run_id"] and state.get("status") == "reconciliation_required"
             and _same(context._parser_state(state), review["parser"]["input"])
             and state["offset"] >= binding["frontier_offset"], "held_pair_changed")
    _require(_same(state.get("reconciliation_required"), {"run_id": review["legacy_run_id"],
        "reason": "successful_or_unverified_write", "memory_ids": review["preserved_memory_ids"]}), "gate_changed")
    codec._keys(plan["artifacts"], set(review["artifacts"]))
    for name, digest in review["artifacts"].items():
        raw = _raw(plan["artifacts"][name])
        _json(raw)
        _require(durable.digest(raw) == digest, "artifact_changed")
    _assessment_links(review, plan["artifacts"])
    codec._keys(plan["history"], set(review["history"]))
    for role, digest in review["history"].items():
        raw = _raw(plan["history"][role])
        current = (_read_historical(paths.root, review["previous_run_id"], "run") if role == "previous_run"
                   else _read_historical(paths.root, review["legacy_run_id"], role))
        _require(raw == current and durable.digest(raw) == digest, "history_changed")
    _history(review, plan["history"])
    _require(_rows(paths, review["rows"], count=1 if review["kind"] in {expired_update.KIND, completed_remember.KIND} else 2)
             == review["store_identity"], "store_changed")
    row_ids = {row["globalId"] for row in review["rows"]}
    for message in review["messages"]:
        _require(set(message["memory_ids"]) <= row_ids, "message_row_unbound")
        if message["disposition"] == "already_represented_expired":
            _require(len(message["memory_ids"]) == 1, "duplicate_row_missing")
            row = next(r for r in review["rows"] if r["globalId"] == message["memory_ids"][0])
            _require(type(row["expiresAt"]) in (int, float) and row["expiresAt"] < time.time()
                     and row["deletedAt"] is None, "duplicate_not_retained_expired")
    projection = _source(request, review)
    if review["kind"] in {expired_update.KIND, completed_remember.KIND}:
        name = "completed-remember-coverage.json" if review["kind"] == completed_remember.KIND else "expired-update-coverage.json"
        coverage = _json(_raw(plan["artifacts"][name]))
        _require(_same(projection, {key: coverage[key] for key in ("record_count", "parser_diagnostics")}),
                 "structural_coverage_changed")
    expected_state, expected_record = _proposal(state, record, review, plan["id"], plan["review_sha256"])
    _require(_same(plan["next_state"], expected_state) and _same(plan["next_admission"], expected_record),
             "proposal_changed")
    _require(_same(admission.check(paths.root, request), binding), "admission_changed")
    return review, values


@_safe
def prepare(paths, *, session_id, legacy_run_id, reviewed_bundle_sha256, reconciliation_id):
    """No live writes. The explicit outer digest pins the reviewed decision."""
    _require(type(paths) is LegacyPaths, "invalid_paths")
    paths.check(import_evidence=True)
    admission._uuid(session_id, 7)
    admission._uuid(reconciliation_id, 4)
    _identifier(legacy_run_id)
    codec._digest(reviewed_bundle_sha256)
    with durable.Locks(paths.root) as locks:
        review_raw, _ = durable._read(paths.evidence_directory / "review.json", maximum=MAX)
        _require(durable.digest(review_raw) == reviewed_bundle_sha256, "review_pin_changed")
        review = _review(_json(review_raw))
        _require(review["session_id"] == session_id and review["legacy_run_id"] == legacy_run_id, "selection_changed")
        selected = _selected(paths, session_id)
        _require(_active_if_present(selected, session_id) is None, "active_publication")
        inputs = {}
        for role in ("state", "admission", "pending"):
            raw, identity = durable._read(getattr(selected, role))
            inputs[role] = publication._image(raw, identity)
        state, record = (_json(publication._raw(inputs[role], old=True)) for role in ("state", "admission"))
        next_state, next_admission = _proposal(state, record, review, reconciliation_id, reviewed_bundle_sha256)
        artifacts = {name: _sealed(durable._read(paths.evidence_directory / name)[0]) for name in review["artifacts"]}
        history = {role: _sealed(_read_historical(paths.root,
            review["previous_run_id"] if role == "previous_run" else legacy_run_id,
            "run" if role == "previous_run" else role)) for role in review["history"]}
        plan = {"version": 1, "kind": KIND, "id": reconciliation_id, "paths": paths.check(), "runtime": _runtime(paths),
                "review": _sealed(review_raw), "review_sha256": reviewed_bundle_sha256, "artifacts": artifacts,
                "history": history, "inputs": inputs, "next_state": next_state, "next_admission": next_admission}
        _require(len(durable.encode(plan)) <= MAX, "plan_too_large")
        _validate(paths, plan)
        for role, image in inputs.items():
            _require(durable._read(getattr(selected, role)) == (publication._raw(image, old=True), image["identity"]),
                     "preimage_changed")
        locks.verify()
        return plan


def _work(paths, identifier, *, create=False):
    admission._uuid(identifier, 4)
    parent = paths.root / "reconciliations"
    directory = parent / identifier
    if create:
        durable._mkdir(parent)
        durable._mkdir(directory)
    _require(not durable._directory(directory).st_mode & 0o077, "unsafe_reconciliation_directory")
    return directory


def _receipt(plan, review, reference, completed):
    return {"version": 1, "session_id": review["session_id"],
        "reference": _reference(review, plan["id"], plan["review_sha256"]),
        "kind": "legacy_interval_reconciliation", "status": "reconciled_no_new_mutation",
        "plan_sha256": durable.digest(durable.encode(plan)), "publication": reference,
        "completion_sha256": durable.digest(durable.encode(completed["completion"])),
        "historical_run_status": "failed", "historical_execution_sealed": False,
        "source_binding_grade": "current_bounded_reconstruction", "native_mutations_performed": 0}


def _validator(paths, plan, plan_sha256, locks):
    def validate(view, phase):
        locks.verify()
        review, values = _validate(paths, plan)
        _require(view["ticket_id"] == plan["id"] and view["session_id"] == review["session_id"]
                 and view["request_id"] == values["pending"]["request_id"]
                 and _same(view["input_evidence"], {"kind": KIND, "id": plan["id"], "plan_sha256": plan_sha256})
                 and view["run_evidence"] is None
                 and _same(view["outcome"], {"result": RESULT, "queue_action": "keep", "pause_reason": None}),
                 "ticket_changed")
        proposal = view["publication"]
        for role in ("state", "admission"):
            _require(_same(proposal["records"][role]["old"], plan["inputs"][role])
                     and publication._raw(proposal["records"][role]["new"]) == durable.encode(plan["next_" + role]),
                     "publication_changed")
        _require(_same(view["pending"], plan["inputs"]["pending"]), "pending_binding_changed")
        selected = _selected(paths, review["session_id"])
        published = selected.session_directory / "journals" / plan["id"] / "published.json"
        if not os.path.lexists(published):
            publication._positions(proposal, publication.Paths(selected.state, selected.admission, published.parent))
        else:
            expected_receipt = {"schema_version": 1, "kind": publication.KIND, "status": "published",
                "transition_id": view["ticket_id"], "session_id": view["session_id"],
                "request_id": view["request_id"], "prepared_sha256": view["prepared_sha256"],
                "admission_sha256": proposal["records"]["admission"]["new"]["sha256"],
                "state_sha256": proposal["records"]["state"]["new"]["sha256"]}
            _require(durable._read(published)[0] == durable.encode(expected_receipt), "published_receipt_changed")
            _require(durable._read(selected.state)[0] == durable.encode(plan["next_state"]), "published_state_changed")
            current = _json(durable._read(selected.admission)[0])
            expected = plan["next_admission"]
            _require(_same({k: v for k, v in current.items() if k != "last_event"},
                           {k: v for k, v in expected.items() if k != "last_event"}), "published_admission_changed")
        pending_raw, pending_identity = durable._read(selected.pending)
        current_pending = _json(pending_raw)
        _pending_pause(current_pending)
        _require(_same(admission.check(paths.root, current_pending), values["pending"]["admission"]), "pending_not_admitted")
        if current_pending["request_id"] == values["pending"]["request_id"]:
            original_pending = plan["inputs"]["pending"]
            _require((pending_raw, pending_identity)
                     == (publication._raw(original_pending, old=True), original_pending["identity"]),
                     "same_request_changed")
        locks.verify()
        return True
    return validate


def _finish(paths, plan, digest, locks):
    review, _ = _validate(paths, plan)
    selected = _selected(paths, review["session_id"])
    work = _work(paths, plan["id"])
    reference_path = work / "publication-reference.json"
    active = coordinator._active(selected, review["session_id"])
    validate = _validator(paths, plan, digest, locks)
    if active is not None:
        _require(active[0]["ticket_id"] == plan["id"], "other_active_publication")
        summary = coordinator.recover(selected, session_id=review["session_id"], validate=validate)
        reference = {key: summary[key] for key in ("ticket_id", "ticket_sha256")}
        locks.verify()
        coordinator._immutable(reference_path, reference, "legacy_publication_reference")
        locks.verify()
        _boundary("publication_reference_durable")
        coordinator.acknowledge(selected, session_id=review["session_id"], validate=validate)
    else:
        reference = _json(durable._read(reference_path)[0])
    codec._keys(reference, {"ticket_id", "ticket_sha256"})
    _require(reference["ticket_id"] == plan["id"], "reference_changed")
    completed = coordinator.read_completed(selected, session_id=review["session_id"], **reference)
    validate({**completed["ticket"], "publication": completed["publication"]}, "completion")
    result = _receipt(plan, review, reference, completed)
    locks.verify()
    coordinator._immutable(work / "receipt.json", result, "legacy_receipt")
    locks.verify()
    _boundary("receipt_durable")
    return result


@_safe
def apply(paths, *, plan, plan_sha256):
    codec._digest(plan_sha256)
    _require(durable.digest(durable.encode(plan)) == plan_sha256, "plan_pin_changed")
    with durable.Locks(paths.root) as locks:
        review, values = _validate(paths, plan)
        selected = _selected(paths, review["session_id"])
        locks.verify()
        work = _work(paths, plan["id"], create=True)
        coordinator._immutable(work / "plan.json", plan, "legacy_plan")
        locks.verify()
        _boundary("plan_durable")
        durable._mkdir(paths.root / "publications")
        active = coordinator._active(selected, review["session_id"])
        if active is None and not os.path.lexists(work / "publication-reference.json"):
            for role, image in plan["inputs"].items():
                _require(durable._read(getattr(selected, role)) == (publication._raw(image, old=True), image["identity"]),
                         "preimage_changed")
            coordinator.start(selected, ticket_id=plan["id"], session_id=review["session_id"],
                request_id=values["pending"]["request_id"], binding=values["pending"]["admission"],
                expected_old_state_sha256=plan["inputs"]["state"]["sha256"],
                expected_old_admission_sha256=plan["inputs"]["admission"]["sha256"],
                expected_pending_sha256=plan["inputs"]["pending"]["sha256"],
                new_state=plan["next_state"], new_admission=plan["next_admission"],
                input_evidence={"kind": KIND, "id": plan["id"], "plan_sha256": plan_sha256}, run_evidence=None,
                outcome={"result": RESULT, "queue_action": "keep", "pause_reason": None},
                validate=_validator(paths, plan, plan_sha256, locks))
        return _finish(paths, plan, plan_sha256, locks)


@_safe
def recover(paths, *, session_id, reconciliation_id, plan_sha256):
    admission._uuid(session_id, 7)
    codec._digest(plan_sha256)
    with durable.Locks(paths.root) as locks:
        raw, _ = durable._read(_work(paths, reconciliation_id) / "plan.json", maximum=MAX)
        _require(durable.digest(raw) == plan_sha256, "plan_pin_changed")
        plan = _json(raw)
        review, _ = _validate(paths, plan)
        _require(plan["id"] == reconciliation_id and review["session_id"] == session_id, "selection_changed")
        return _finish(paths, plan, plan_sha256, locks)


class _CallerLocks:
    """Trusted runner callback; never supplied by evidence or command input."""
    def __init__(self, check):
        _require(callable(check), "caller_lock_guard_required")
        self.check = check

    def verify(self):
        _require(self.check() is True, "caller_locks_changed")


def _load_pinned_plan(paths, identifier, digest):
    codec._digest(digest)
    raw, _ = durable._read(_work(paths, identifier) / "plan.json", maximum=MAX)
    _require(durable.digest(raw) == digest, "plan_pin_changed")
    plan = _json(raw)
    _require(plan.get("id") == identifier and durable.encode(plan) == raw, "plan_changed")
    return plan


def needs_recovery(root, session_id):
    """Bounded discovery only; matching metadata is never publication authority.

    Inspect fixed state/receipt/reference/completion files only. A missing or
    malformed proof keeps recovery discoverable; an already recorded completion
    does not trigger private plan, transcript, history, or database reads on each
    worker loop. The locked recovery path performs full integrity validation.
    """
    admission._uuid(session_id, 7)
    _require(isinstance(root, Path) and root.is_absolute(), "untrusted_path")
    try:
        state_raw, _ = durable._read(admission.state_paths(root, session_id)["sessions"], absent=True)
        if state_raw is None:
            return False
        state = _json(state_raw)
        if "last_reconciliation" not in state and state.get("status") != RESULT:
            return False
        reference = state["last_reconciliation"]
        codec._keys(reference, {"version", "id", "legacy_run_id", "evidence_sha256", "interval", "memory_ids"})
        _require(type(reference["version"]) is int and reference["version"] == 1, "invalid_reference")
        admission._uuid(reference["id"], 4)
        _require(type(reference["legacy_run_id"]) is str
                 and re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}", reference["legacy_run_id"]),
                 "invalid_reference")
        codec._digest(reference["evidence_sha256"])
        interval = reference["interval"]
        codec._keys(interval, {"start_offset", "end_offset", "interval_sha256", "excerpt_sha256"})
        for key in ("start_offset", "end_offset"):
            codec._integer(interval[key], high=(1 << 63) - 1)
        _require(interval["end_offset"] > interval["start_offset"], "invalid_interval")
        for key in ("interval_sha256", "excerpt_sha256"):
            codec._digest(interval[key])
        _require(type(reference["memory_ids"]) is list and len(reference["memory_ids"]) <= 20, "invalid_ids")
        ids = [codec._uuid(value) for value in reference["memory_ids"]]
        _require(len(set(ids)) == len(ids), "invalid_ids")
        work = root / "reconciliations" / reference["id"]
        receipt = _json(durable._read(work / "receipt.json", maximum=65536)[0])
        codec._keys(receipt, {"version", "kind", "status", "session_id", "reference", "plan_sha256",
            "publication", "completion_sha256", "historical_run_status", "historical_execution_sealed",
            "source_binding_grade", "native_mutations_performed"})
        _require(type(receipt["version"]) is int and receipt["version"] == 1
                 and receipt["kind"] == "legacy_interval_reconciliation"
                 and receipt["status"] == "reconciled_no_new_mutation" and receipt["session_id"] == session_id
                 and _same(receipt["reference"], reference) and receipt["historical_run_status"] == "failed"
                 and receipt["historical_execution_sealed"] is False
                 and receipt["source_binding_grade"] == "current_bounded_reconstruction"
                 and type(receipt["native_mutations_performed"]) is int and receipt["native_mutations_performed"] == 0,
                 "receipt_changed")
        codec._digest(receipt["plan_sha256"])
        codec._digest(receipt["completion_sha256"])
        pinned = receipt["publication"]
        codec._keys(pinned, {"ticket_id", "ticket_sha256"})
        codec._digest(pinned["ticket_sha256"])
        _require(pinned["ticket_id"] == reference["id"] and _same(pinned,
            _json(durable._read(work / "publication-reference.json", maximum=65536)[0])), "reference_changed")
        raw, _ = durable._read(root / "publications" / session_id / "records" / reference["id"] / "completion.json",
                               maximum=262144)
        completion = _json(raw)
        codec._keys(completion, {"version", "ticket_id", "ticket_sha256", "published_sha256", "ack_intent_sha256",
                                 "outcome", "disposition", "pending"})
        _require(durable.digest(raw) == receipt["completion_sha256"]
                 and type(completion["version"]) is int and completion["version"] == 1
                 and all(completion[key] == pinned[key] for key in ("ticket_id", "ticket_sha256"))
                 and _same(completion["outcome"], {"result": RESULT, "queue_action": "keep", "pause_reason": None})
                 and completion["disposition"] in ("original", "newer") and type(completion["pending"]) is dict,
                 "completion_changed")
        for key in ("published_sha256", "ack_intent_sha256"):
            codec._digest(completion[key])
        return False
    except (OSError, ValueError, TypeError, KeyError, AttributeError, OverflowError, RuntimeError,
            RecursionError, UnicodeError):
        return True


@_safe
def recover_locked(paths, *, session_id, verify_locks):
    """Recover metadata while the runner continuously owns worker -> enqueue.

    Caller-provided paths and an exact-True ownership guard are mandatory. No
    global provider lock is acquired in reverse order: the selected historical
    relay and every mutation must already be terminal, and recovery never runs a
    provider or memory operation. The command APIs retain their full lock order.
    Returns None when there is no selected incomplete legacy publication or an
    authenticated final receipt already exists. A partial proof remains held.
    """
    _require(type(paths) is LegacyPaths, "invalid_paths")
    paths.check()
    admission._uuid(session_id, 7)
    locks = _CallerLocks(verify_locks)
    locks.verify()
    selected = _selected(paths, session_id)
    active = _active_if_present(selected, session_id)
    if active is not None:
        evidence = active[0]["input_evidence"]
        if evidence.get("kind") != KIND:
            return None
        codec._keys(evidence, {"kind", "id", "plan_sha256"})
        _require(active[0]["ticket_id"] == evidence["id"], "active_reference_changed")
        plan = _load_pinned_plan(paths, evidence["id"], evidence["plan_sha256"])
        review, _ = _validate(paths, plan)
        _require(review["session_id"] == session_id, "selection_changed")
        locks.verify()
        return _finish(paths, plan, evidence["plan_sha256"], locks)
    state_raw, _ = durable._read(selected.state, absent=True)
    if state_raw is None:
        return None
    state = _json(state_raw)
    reference = state.get("last_reconciliation")
    if reference is None:
        _require("last_reconciliation" not in state and state.get("status") != RESULT,
                 "missing_reconciliation_reference")
        return None
    codec._keys(reference, {"version", "id", "legacy_run_id", "evidence_sha256", "interval", "memory_ids"})
    work = _work(paths, reference["id"])
    if os.path.lexists(work / "receipt.json"):
        read_completed(paths, session_id=session_id, reference=reference)
        locks.verify()
        return None
    # The state reference alone is not completion authority. Authenticate the
    # plan digest through its already-pinned coordinator completion first.
    pinned = _json(durable._read(work / "publication-reference.json")[0])
    codec._keys(pinned, {"ticket_id", "ticket_sha256"})
    _require(pinned["ticket_id"] == reference["id"], "retired_reference_changed")
    completed = coordinator.read_completed(selected, session_id=session_id, **pinned)
    evidence = completed["ticket"]["input_evidence"]
    codec._keys(evidence, {"kind", "id", "plan_sha256"})
    _require(evidence["kind"] == KIND and evidence["id"] == reference["id"], "retired_evidence_changed")
    plan = _load_pinned_plan(paths, reference["id"], evidence["plan_sha256"])
    review, _ = _validate(paths, plan)
    _require(review["session_id"] == session_id
             and state_raw == durable.encode(plan["next_state"])
             and _same(reference, _reference(review, plan["id"], plan["review_sha256"])),
             "retired_state_changed")
    locks.verify()
    return _finish(paths, plan, evidence["plan_sha256"], locks)


@_safe
def read_completed(paths, *, session_id, reference):
    """Full integrity inspection for CLI/review, NOT the passive hook-status path.

    Historical terminal files and coordinator proofs are checked. Source/store
    are intentionally not re-read here: this authenticates a completed
    retrospective disposition, not fresh current memory or source truth.
    Passive hook status uses a separate small completion projection and never
    imports this module or reads its private plan/provider records.
    """
    admission._uuid(session_id, 7)
    codec._keys(reference, {"version", "id", "legacy_run_id", "evidence_sha256", "interval", "memory_ids"})
    work = _work(paths, reference["id"])
    raw, _ = durable._read(work / "plan.json", maximum=MAX)
    plan = _json(raw)
    review = _review(_json(_raw(plan["review"])))
    _require(plan["kind"] == KIND and plan["id"] == reference["id"] and review["session_id"] == session_id
             and _same(reference, _reference(review, plan["id"], plan["review_sha256"]))
             and durable.digest(_raw(plan["review"])) == plan["review_sha256"], "health_reference_changed")
    publication_ref = _json(durable._read(work / "publication-reference.json")[0])
    codec._keys(publication_ref, {"ticket_id", "ticket_sha256"})
    _require(publication_ref["ticket_id"] == plan["id"], "health_publication_changed")
    completed = coordinator.read_completed(_selected(paths, session_id), session_id=session_id, **publication_ref)
    ticket = completed["ticket"]
    _require(_same(ticket["input_evidence"], {"kind": KIND, "id": plan["id"], "plan_sha256": durable.digest(raw)})
             and ticket["outcome"]["result"] == RESULT, "health_ticket_changed")
    _require(_same(_json(publication._raw(completed["publication"]["records"]["state"]["new"])), plan["next_state"])
             and _same(plan["next_state"].get("last_reconciliation"), reference), "health_decision_changed")
    receipt = _json(durable._read(work / "receipt.json")[0])
    _require(_same(receipt, _receipt(plan, review, publication_ref, completed)), "health_receipt_changed")
    _history(review, plan["history"])
    for role in ("run", "audit", "provider"):
        _require(_read_historical(paths.root, review["legacy_run_id"], role) == _raw(plan["history"][role]),
                 "health_history_changed")
    return copy.deepcopy(receipt)
