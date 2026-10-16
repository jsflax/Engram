"""Bind already-policy-checked learner writes to immutable native operations.

This module never launches a backend, grants replay, or advances a cursor. The
runner seals the manifest before starting its provider; the proxy holds a shared
writer fence and uses this adapter after enforcing its existing tool policy.
"""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path

from . import execution_manifest as journal, writer_fence as fences

CAPABILITY = "localMutationOperationsV1"
TOOLS = frozenset({"operation_scope", "operation_apply", "operation_status"})
ERRORS = frozenset({"unsupported", "scope_mismatch", "payload_conflict", "unsupported_target",
                    "invalid_request", "storage_unavailable"})


def _require(ok, reason):
    if not ok:
        raise ValueError("operation_gateway_" + reason)


def envelope(result):
    """Require agreeing versioned structured/text forms, never success prose."""
    _require(type(result) is dict and set(result) == {"isError", "content", "structuredContent"},
             "invalid_response")
    _require(type(result["isError"]) is bool, "invalid_response")
    outer = result["structuredContent"]
    _require(type(outer) is dict and set(outer) == {"engram_operation"}, "invalid_response")
    content = result["content"]
    _require(type(content) is list and len(content) == 1 and type(content[0]) is dict
             and set(content[0]) == {"type", "text"} and content[0]["type"] == "text"
             and type(content[0]["text"]) is str, "invalid_response")
    text = journal._json(content[0]["text"].encode("utf-8"), journal.MAX_INPUT)
    _require(journal.encode(text) == journal.encode(outer), "inconsistent_response")
    value = outer["engram_operation"]
    _require(type(value) is dict and type(value.get("version")) is int and value["version"] == 1,
             "unsupported_response")
    if value.get("kind") == "error":
        _require(result["isError"] is True and set(value) == {"version", "kind", "code"}
                 and value["code"] in ERRORS, "invalid_response")
    else:
        _require(result["isError"] is False, "invalid_response")
    return copy.deepcopy(value)


def mutation(tool, arguments):
    """Translate the existing learner contract without silently dropping fields."""
    _require(type(arguments) is dict, "invalid_arguments")
    args = journal._json(journal.encode(arguments), journal.MAX_INPUT)
    common = {"content", "topic", "source", "importance", "expires_in_days"}
    if tool == "remember":
        allowed = common | {"project", "is_private", "parent_id", "force"}
        _require(set(args) <= allowed and args.get("force", False) is False
                 and args.get("is_private") is True and type(args.get("source")) is str,
                 "invalid_remember_policy")
        args.pop("force", None)
        # Legacy remember documents zero as its default. The typed API uses an
        # omitted importance for that same default and rejects explicit zero.
        if type(args.get("importance")) is int and args["importance"] == 0:
            del args["importance"]
    elif tool == "update":
        _require(set(args) <= common | {"id", "append", "prepend", "find", "replace"},
                 "unsupported_update_fields")
        args["undelete"] = False
    elif tool == "connect":
        _require(set(args) == {"from", "to", "relation"}, "invalid_connection")
    else:
        raise ValueError("operation_gateway_unsupported_tool")
    mapping = {"is_private": "isPrivate", "parent_id": "parentId", "expires_in_days": "expiresInDays",
               "from": "sourceId", "to": "targetId"}
    # Native optional Codable fields are absent, not null. Unknown or invalid
    # required fields are still rejected by the common contract validator.
    request = {mapping.get(key, key): value for key, value in args.items() if value is not None}
    value = {"kind": tool, "request": request}
    journal._mutation(value)
    return value


def call_key(request_id):
    _require(type(request_id) in (str, int), "invalid_call_id")
    return "rpc-" + journal.sha256(journal.encode({"type": type(request_id).__name__, "id": request_id}))


def verify_audit_receipt(run_dir, request_id, tool, entry):
    """Correlate content-free audit fields with the retained native journal."""
    operation = journal.operation_id(run_dir, call_key(request_id))
    fields = {key for key in entry if key.startswith("operation_")}
    _require(fields == {"operation_version", "operation_id", "operation_outcome", "operation_payload_digest"}
             and type(entry["operation_version"]) is int and entry["operation_version"] == 1
             and entry["operation_id"] == operation and entry.get("forwarded") is True
             and entry.get("ok") is True and entry.get("tool") == tool
             and "write_outcome" not in entry and "write_outcome_version" not in entry, "invalid_audit_receipt")
    _, request = journal.read_intent(run_dir, operation)
    _require(request["mutation"]["kind"] == tool, "audit_tool_changed")
    events = journal.read_evidence(run_dir, operation)
    _require(bool(events) and events[0]["evidence"]["kind"] == "dispatch"
             and events[-1]["evidence"]["kind"] == "committed", "audit_receipt_unsettled")
    receipt = events[-1]["evidence"]["receipt"]
    _require(entry["operation_outcome"] == receipt["outcome"]
             and entry["operation_payload_digest"] == receipt["payloadDigest"], "audit_receipt_changed")
    expected = receipt["memoryIDs"] if receipt["outcome"] == "applied" else []
    _require(type(entry.get("memory_ids")) is list
             and [journal._uuid(value) for value in entry["memory_ids"]]
             == [journal._uuid(value) for value in expected], "audit_memory_ids_changed")
    _require(receipt["outcome"] != "applied" or bool(expected), "audit_applied_without_ids")
    return copy.deepcopy(receipt)


def verify_audit_coverage(run_dir, request_ids):
    """Every retained intent must have a correlated, settled audited call."""
    journal.read_manifest(run_dir)
    expected = {"operation-" + journal.operation_id(run_dir, call_key(value)) + ".json"
                for value in request_ids}
    actual = set()
    with os.scandir(run_dir) as entries:
        for count, entry in enumerate(entries):
            _require(count < 4096, "run_directory_limit")
            if entry.name.startswith("operation-"):
                actual.add(entry.name)
    _require(actual == expected, "unaccounted_operation_intents")


class OperationGateway:
    def __init__(self, run_dir, *, manifest_sha256, writer_fence, validate_inputs):
        self.run_dir = Path(run_dir)
        self.manifest, actual = journal.read_manifest(self.run_dir)
        _require(type(manifest_sha256) is str and actual == manifest_sha256, "manifest_changed")
        self.manifest_sha256 = actual
        _require(type(writer_fence) is fences.HeldFence, "invalid_writer_fence")
        _require(callable(validate_inputs), "input_validator_required")
        self.fence = writer_fence
        self.validate_inputs = validate_inputs
        self._verify()

    def _admit_dispatch(self, phase):
        self._verify()
        _require(self.validate_inputs(copy.deepcopy(self.manifest), phase) is True, "input_validation_refused")

    def _verify(self):
        current, digest = journal.read_manifest(self.run_dir)
        _require(digest == self.manifest_sha256, "manifest_changed")
        _require(self.fence.verify(current["fencing"]) is True, "writer_unfenced")
        self.fence.pass_fds()  # An exclusive recovery handle cannot dispatch.
        return True

    def prepare(self, request_id, tool, arguments):
        """Persist intent/dispatch, then return a request built from retained bytes."""
        self._admit_dispatch("before_intent")
        # JSON's ID type is part of identity: integer 7 and string "7" differ.
        call = call_key(request_id)
        operation = journal.operation_id(self.run_dir, call)
        source = self.manifest["source"]
        request = {"version": 1, "operationID": operation, "expectedScope": self.manifest["expected_scope"],
                   "provenance": {"host": self.manifest["host"], "sessionID": self.manifest["session_id"],
                                  "runID": self.manifest["run_id"], "source": {
                                      "startOffset": source["start_offset"], "endOffset": source["end_offset"],
                                      "excerptDigest": source["excerpt_sha256"]}},
                   "mutation": mutation(tool, arguments)}
        journal.publish_intent(self.run_dir, call, journal.encode(request), verify_fence=self.fence.verify)
        self._admit_dispatch("before_dispatch_record")
        raw = journal.record_dispatch(self.run_dir, operation, verify_fence=self.fence.verify)
        retained = journal._json(raw, journal.MAX_INPUT)
        # The relay's compact UTF-8 encoder preserves insertion order. Reading
        # these sorted retained bytes preserves the exact arguments on the wire.
        _require(json.dumps(retained, separators=(",", ":"), ensure_ascii=False,
                            allow_nan=False).encode("utf-8") == raw, "request_encoding_changed")
        self._admit_dispatch("before_forward")
        return operation, {"jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                           "params": {"name": "operation_apply", "arguments": retained}}

    def unavailable(self, operation, reason):
        self._verify()
        journal.record_response(self.run_dir, operation, {"kind": "unavailable", "reason": reason},
                                verify_fence=self.fence.verify)

    def finish(self, operation, message):
        """Retain a validated native receipt before allowing success upstream."""
        self._verify()
        if "error" in message:
            self.unavailable(operation, "transport_error")
            return None
        try:
            value = envelope(message.get("result"))
            if value["kind"] == "error":
                self.unavailable(operation, "backend_error")
                return None
            _require(set(value) == {"version", "kind", "receipt"} and value["kind"] == "committed",
                     "unexpected_apply_response")
            journal.record_response(self.run_dir, operation,
                                    {"kind": "committed", "receipt": value["receipt"]},
                                    verify_fence=self.fence.verify)
        except (ValueError, KeyError, TypeError, UnicodeError):
            self.unavailable(operation, "invalid_response")
            return None
        self._verify()
        return copy.deepcopy(value["receipt"])
