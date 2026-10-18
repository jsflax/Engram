#!/usr/bin/env python3
"""A bounded, audited, memory-only newline JSON-RPC gateway.

Usage: python memory_proxy.py /absolute/private/config.json
No transcript, tool arguments, memory content, or child environment is audited.
The child transport is stdio; HTTP configurations are explicitly unsupported.
"""

from __future__ import annotations

import copy
import contextlib
import json
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import sys
import time
import uuid
from typing import Any

ALLOWED_TOOLS = frozenset({"recall", "graph", "list_topics", "stats", "timeline", "remember", "update", "connect"})
WRITE_TOOLS = frozenset({"remember", "update", "connect"})
READ_TOOLS = ALLOWED_TOOLS - WRITE_TOOLS
PLANNING_MODE = "read_only_plan"
REMEMBER_FIELDS = frozenset({"content", "project", "topic", "source", "expires_in_days", "importance", "is_private", "parent_id", "force"})
UPDATE_FIELDS = frozenset({"id", "content", "append", "prepend", "find", "replace", "topic", "source", "importance", "expires_in_days"})
RELATIONS = frozenset({"relates_to", "contradicts", "supersedes", "derived_from", "part_of", "summarized_by"})
UUID_PATTERN = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
MAX_LINE_BYTES = 8 * 1024 * 1024


class ProxyError(Exception):
    pass


STARTUP_FAILURE_FILE = "gateway-startup-failure.json"
STARTUP_STAGES = frozenset({"provider_policy", "writer_fence", "execution_context",
                            "gateway_policy", "operation_gateway", "audit_open"})
STARTUP_REASONS = frozenset({
    "provider_mode_changed", "planning_budgets_changed", "budgets_changed", "policy_changed",
    "execution_context_backend_changed", "execution_context_binding_changed",
    "execution_context_processing_changed", "execution_context_cursor_changed",
    "execution_context_cursor_binding_changed", "execution_context_reconciliation_required",
    "execution_context_runtime_changed", "execution_context_runtime_read_deadline",
    "execution_context_unsafe_runtime", "execution_context_unbound_runtime",
    "execution_context_source_changed", "execution_context_source_or_parser_changed",
    "execution_context_parser_or_source_changed", "execution_context_unavailable_or_changed",
    "writer_fence_generation_revoked", "writer_fence_lock_changed", "writer_fence_generation_changed",
    "validation_failed", "io_error", "unexpected_error"})
_STARTUP_PROXY_REASONS = {
    "Durable provider mode changed": "provider_mode_changed",
    "Durable planning budgets changed": "planning_budgets_changed",
    "Durable execution budgets changed": "budgets_changed",
    "Durable execution policy changed": "policy_changed"}


def _startup_directory(info):
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o077):
        raise ValueError("unsafe_startup_directory")
    return (info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_mode)


class _StartupDiagnostic:
    """Best-effort metadata only. Never evidence of absence or mutation authority."""
    def __init__(self):
        self.target = None
        self.stage = "provider_policy"

    def bind(self, paths, manifest, digest, journal):
        # Called only after ContextPaths.check and a matching, private manifest.
        try:
            if manifest["run_id"] == paths.run_dir.name:
                self.target = (paths.run_dir, _startup_directory(paths.run_dir.lstat()),
                               manifest["session_id"], digest, journal)
        except Exception:
            self.target = None

    def record(self, error):
        if self.target is None or self.stage not in STARTUP_STAGES:
            return
        try:
            run_dir, identity, session_id, digest, journal = self.target
            if run_dir.resolve(strict=True) != run_dir:
                return
            fd = os.open(run_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            try:
                if _startup_directory(os.fstat(fd)) != identity:
                    return
                manifest, current = journal.read_manifest(run_dir)
                if (current != digest or manifest["run_id"] != run_dir.name
                        or manifest["session_id"] != session_id
                        or _startup_directory(run_dir.lstat()) != identity):
                    return
                # Do not serialize exception text, paths, argv, or environment.
                text = error.args[0] if error.args and type(error.args[0]) is str else None
                reason = _STARTUP_PROXY_REASONS.get(text)
                if reason is None:
                    reason = text if text in STARTUP_REASONS else (
                        "io_error" if isinstance(error, OSError) else
                        "validation_failed" if isinstance(error, (ProxyError, ValueError, TypeError, KeyError))
                        else "unexpected_error")
                value = {"version": 1, "kind": "gateway_startup_failure", "run_id": run_dir.name,
                         "session_id": session_id, "manifest_sha256": digest,
                         "stage": self.stage, "reason": reason}
                raw = journal.encode(value)
                output = os.open(STARTUP_FAILURE_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                 | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=fd)
                try:
                    info = os.fstat(output)
                    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                            or info.st_nlink != 1 or info.st_mode & 0o077):
                        return
                    remaining = memoryview(raw)
                    while remaining:
                        count = os.write(output, remaining)
                        if count <= 0:
                            return
                        remaining = remaining[count:]
                    os.fsync(output)
                finally:
                    os.close(output)
                os.fsync(fd)
            finally:
                os.close(fd)
        except Exception:
            # Preserve the original startup failure even if diagnostics fail.
            pass


def read_startup_failure(run_dir, manifest_sha256):
    """Return only fixed diagnostic codes; callers must not use them to settle."""
    try:
        from . import execution_manifest as journal
        run_dir = Path(run_dir)
        if run_dir.resolve(strict=True) != run_dir:
            return None
        _startup_directory(run_dir.lstat())
        manifest, digest = journal.read_manifest(run_dir)
        if digest != manifest_sha256 or manifest["run_id"] != run_dir.name:
            return None
        raw, _ = journal.durable._read(run_dir / STARTUP_FAILURE_FILE, maximum=2048)
        value = journal._json(raw)
        if (set(value) != {"version", "kind", "run_id", "session_id", "manifest_sha256", "stage", "reason"}
                or type(value["version"]) is not int or value["version"] != 1
                or value["kind"] != "gateway_startup_failure" or value["run_id"] != run_dir.name
                or value["session_id"] != manifest["session_id"] or value["manifest_sha256"] != digest
                or value["stage"] not in STARTUP_STAGES or value["reason"] not in STARTUP_REASONS):
            return None
        return {key: value[key] for key in ("stage", "reason")}
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError):
        return None


def normalized_uuid(value: Any) -> str | None:
    if not isinstance(value, str) or re.fullmatch(UUID_PATTERN, value) is None:
        return None
    return str(uuid.UUID(value))


def valid_id(value: Any) -> bool:
    return (isinstance(value, int) and not isinstance(value, bool)) or (isinstance(value, str) and len(value) <= 128 and re.fullmatch(r"[A-Za-z0-9_.:-]+", value) is not None)


def id_key(value: Any) -> tuple[type, Any]:
    return type(value), value


def audit_planning_tools(path: Path | None = None, *, allow_clean_interrupt: bool = False,
                         raw: bytes | None = None) -> dict:
    """Read the bounded independent relay evidence for a write-free provider.

    This does not authorize a plan. The plan sealer must separately join the
    provider's terminal observation, proposal, manifest and current inputs.
    """
    calls, results = {}, {}
    errors = 0
    started = finished = interrupted = False
    recalls = 0

    def pairs(items):
        value = {}
        for key, item in items:
            if key in value:
                raise ValueError("duplicate audit field")
            value[key] = item
        return value

    try:
        if raw is None:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as stream:
                before = os.fstat(stream.fileno())
                if (not stat.S_ISREG(before.st_mode) or before.st_mode & 0o077
                        or before.st_size > 1024 * 1024):
                    raise ValueError("invalid planning audit")
                raw = stream.read(1024 * 1024 + 1)
                after = os.fstat(stream.fileno())
            if (len(raw) != before.st_size or before.st_size != after.st_size
                    or before.st_mtime_ns != after.st_mtime_ns):
                raise ValueError("planning audit changed")
        elif path is not None:
            raise ValueError("supply exactly one planning audit input")
        if type(raw) is not bytes or len(raw) > 1024 * 1024 or not raw.endswith(b"\n"):
            raise ValueError("planning audit invalid or truncated")
        lines = raw.splitlines()
        if len(lines) > 256:
            raise ValueError("planning audit limit")
        for line in lines:
            entry = json.loads(line, object_pairs_hook=pairs)
            if type(entry) is not dict or finished:
                raise ValueError("invalid planning audit sequence")
            event = entry.get("event")
            if not started:
                if entry != {"event": "relay_started"}:
                    raise ValueError("planning relay did not start")
                started = True
                continue
            if interrupted and event != "relay_finished":
                raise ValueError("event after planning relay interruption")
            if event == "relay_finished":
                peaks = {"peak_inflight", "peak_client_queue_bytes", "peak_server_queue_bytes"}
                if (set(entry) - ({"event", "child_reaped", "cleanup_overrun"} | peaks)
                        or any(type(entry[name]) is not int or entry[name] < 0 for name in peaks & set(entry))
                        or entry.get("child_reaped") is not True
                        or entry.get("cleanup_overrun") is not False
                        or set(calls) != set(results)):
                    raise ValueError("planning relay did not cleanly finish")
                finished = True
            elif event == "relay_interrupted":
                if (entry != {"event": "relay_interrupted"}
                        or allow_clean_interrupt is not True or interrupted or not calls
                        or set(calls) != set(results)):
                    raise ValueError("planning relay interrupted before completion")
                interrupted = True
            elif event == "initialize_compat":
                if entry != {"event": "initialize_compat", "omitted_capability": "codex/auth-change"}:
                    raise ValueError("unknown planning compatibility event")
            elif event == "tool_call":
                if (set(entry) != {"event", "id", "tool"} or not valid_id(entry["id"])
                        or entry["tool"] not in READ_TOOLS or id_key(entry["id"]) in calls):
                    raise ValueError("planning call is not an allowed unique read")
                calls[id_key(entry["id"])] = entry["tool"]
            elif event == "tool_result":
                if (set(entry) != {"event", "id", "tool", "ok", "memory_ids", "forwarded"}
                        or not valid_id(entry["id"]) or entry["ok"] is not True
                        or entry["forwarded"] is not True or entry["memory_ids"] != []):
                    raise ValueError("planning read failed or claimed a mutation")
                key = id_key(entry["id"])
                if key not in calls or key in results or calls[key] != entry["tool"]:
                    raise ValueError("planning result is unpaired")
                results[key] = entry
                recalls += entry["tool"] == "recall"
            else:
                raise ValueError("unexpected planning relay event")
        if not (started and finished and recalls and set(calls) == set(results)):
            raise ValueError("planning read coverage incomplete")
    except (OSError, ValueError, TypeError, KeyError, UnicodeError, RecursionError):
        errors = 1
    return {"tool_calls": len(calls), "read_calls": len(calls), "successful_recalls": recalls,
            "write_calls": 0, "writes": [], "tool_errors": errors}


def audit_planning_bytes(raw: bytes, *, allow_clean_interrupt: bool = False) -> dict:
    """Validate exactly the bytes already descriptor-bound by the plan sealer."""
    return audit_planning_tools(raw=raw, allow_clean_interrupt=allow_clean_interrupt)


def learner_tool_descriptor(tool: dict[str, Any], provenance: str) -> dict[str, Any]:
    """Advertise the learner contract, without changing the native descriptor.

    Build closed write schemas instead of retaining native schema fragments that
    could require or recommend fields the learner gateway rejects.
    """
    name = tool.get("name")
    if name not in WRITE_TOOLS:
        return tool
    exact_uuid = {"type": "string", "pattern": f"^{UUID_PATTERN}$",
                  "minLength": 36, "maxLength": 36,
                  "description": "Exact memory UUID returned by recall; not a query or shortened ID."}
    shared = {
        "content": {"type": "string", "description": "The atomic memory text to store or replace."},
        "topic": {"type": "string", "description": "The memory's topic or category."},
        "source": {"type": "string", "description": "The supplied source provenance for this memory."},
        "importance": {"type": "integer", "description": "Importance rating, 1–5; 0 uses the default."},
        "expires_in_days": {"type": "integer", "description": "Expire in this many days; 0 makes the memory permanent."},
    }
    if name == "remember":
        properties = dict(shared, **{
            "project": {"type": "string", "description": "Project for the new memory; use global for cross-project knowledge."},
            "parent_id": {"type": "string", "description": "UUID of an existing parent memory, linked by part_of."},
            "source": {"type": "string", "const": provenance,
                       "description": "Optional: the gateway always supplies this learner's source provenance."},
            "is_private": {"type": "boolean", "const": True, "default": True,
                           "description": "New memories are always private; the gateway enforces true."},
            "force": {"type": "boolean", "const": False, "default": False,
                      "description": "Conflict detection stays enabled; omit this field or use false."},
        })
        required = ["content"]
        description = ("Store one new private memory after checking for an existing equivalent. "
                       "The gateway enforces private storage, session source provenance and conflict detection. "
                       "A near-duplicate warning is a no-write outcome; never force a duplicate.")
    elif name == "update":
        properties = dict(shared, **{
            "id": exact_uuid,
            "append": {"type": "string", "description": "Text to append to the existing content."},
            "prepend": {"type": "string", "description": "Text to prepend to the existing content."},
            "find": {"type": "string", "description": "Text to find; supply replace together with this field."},
            "replace": {"type": "string", "description": "Replacement for find; may be empty to remove matched text."},
        })
        required = ["id"]
        description = ("Update an existing memory by its exact UUID from recall. Choose one content edit: "
                       "replacement, append, prepend, or paired find/replace. Topic, source, importance and "
                       "expiration may be updated alongside it. Existing privacy and project are preserved; "
                       "restoration and semantic targeting are unavailable. Do not send privacy fields.")
    else:
        properties = {"from": dict(exact_uuid), "to": dict(exact_uuid),
                      "relation": {"type": "string", "enum": sorted(RELATIONS),
                                   "description": "The directed relationship between these two memories."}}
        required = ["from", "to", "relation"]
        description = ("Connect two existing memories using their exact UUIDs and one listed relation. "
                       "Duplicate edges with the same endpoints and relation are idempotent.")
    descriptor = copy.deepcopy(tool)
    descriptor["description"] = description
    descriptor["inputSchema"] = {"type": "object", "properties": properties,
                                 "required": required, "additionalProperties": False}
    return descriptor


class Audit:
    def __init__(self, path: Path):
        if not path.is_absolute() or path.is_symlink():
            raise ProxyError("audit_path must be an absolute regular file path")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            raise ProxyError("audit_path must name a regular file")
        os.fchmod(fd, 0o600)
        self.stream = os.fdopen(fd, "a", encoding="utf-8")

    def write(self, value: dict[str, Any]) -> None:
        self.stream.write(json.dumps(value, separators=(",", ":")) + "\n")
        self.stream.flush()
        os.fsync(self.stream.fileno())

    def close(self) -> None:
        self.stream.close()


def tool_error(request_id: Any, reason: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": {"isError": True, "content": [{"type": "text", "text": "Engram learner gateway denied this call: " + reason}]}}


def rpc_error(request_id: Any, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": message}}


# This warning and suffix are emitted only by remember's pre-storage conflict
# branch in MemoryTools+Core.swift. Match the outer native receipt, never a
# phrase or UUID quoted inside remembered content.
NO_WRITE_OUTCOME = "not_stored_near_duplicate"
BEGIN_BUSY_OUTCOME = "not_stored_transaction_not_started"
BEGIN_BUSY_VERSION = 1
BEGIN_BUSY_TEXT = "Memory was not stored: the database was busy before the write transaction started. Retry on a later turn."
BEGIN_BUSY_UPDATE_TEXT = "Memory was not updated: the database was busy before the write transaction started. Retry on a later turn."
NEAR_DUPLICATE_PREFIX = "⚠️ Near-duplicate memory detected. The new memory was NOT stored.\n\nExisting similar memories:"
NEAR_DUPLICATE_SUFFIX = ('\n\nTo resolve:'
                         '\n  - Use `update(id: "UUID", ...)` to modify the existing memory'
                         '\n  - Use `remember(..., force: true)` to keep both'
                         '\n  - Use `forget(id: "UUID")` to remove the old one, then `remember` the new one')


def verified_no_write_response(tool: str, result: Any) -> bool:
    """Recognize one vetted native no-write contract; unknown results stay unsafe."""
    if (tool != "remember" or not isinstance(result, dict)
            or result.get("isError") is not False or "structuredContent" in result):
        return False
    content = result.get("content")
    if not isinstance(content, list) or len(content) != 1:
        return False
    item = content[0]
    if not isinstance(item, dict) or set(item) != {"type", "text"} or item.get("type") != "text":
        return False
    text = item.get("text")
    return (isinstance(text, str) and text.startswith(NEAR_DUPLICATE_PREFIX)
            and text.endswith(NEAR_DUPLICATE_SUFFIX))


def verified_begin_busy_response(tool: str, result: Any) -> bool:
    """Accept only native remember/update versioned pre-BEGIN no-write contracts.

    Text alone, nested quoted content, and any unknown or contradictory field
    cannot establish no-write. The native producer checks body entry, not just
    an error string; post-entry/commit failures never produce this receipt.
    """
    expected_text = BEGIN_BUSY_UPDATE_TEXT if tool == "update" else BEGIN_BUSY_TEXT
    if (tool not in ("remember", "update") or not isinstance(result, dict)
            or set(result) != {"isError", "content", "structuredContent"}
            or result["isError"] is not True
            or result["content"] != [{"type": "text", "text": expected_text}]):
        return False
    structured = result["structuredContent"]
    if not isinstance(structured, dict) or set(structured) != {"engram_write_receipt"}:
        return False
    receipt = structured["engram_write_receipt"]
    return (isinstance(receipt, dict)
            and set(receipt) == {"schema_version", "tool", "write_outcome", "reason", "memory_ids"}
            and type(receipt["schema_version"]) is int and receipt["schema_version"] == BEGIN_BUSY_VERSION
            and receipt["tool"] == tool and receipt["write_outcome"] == BEGIN_BUSY_OUTCOME
            and receipt["reason"] == "database_busy"
            and isinstance(receipt["memory_ids"], list) and receipt["memory_ids"] == [])


def verified_no_write_receipt(entry: Any) -> bool:
    """Exact gateway metadata shared by completion and failed-run reconciliation."""
    fields = {"event", "id", "tool", "ok", "memory_ids", "forwarded", "write_outcome"}
    if (not isinstance(entry, dict) or entry.get("event") != "tool_result"
            or not valid_id(entry.get("id"))
            or entry.get("forwarded") is not True
            or not isinstance(entry.get("memory_ids"), list) or entry["memory_ids"] != []):
        return False
    if entry.get("write_outcome") == NO_WRITE_OUTCOME:
        return set(entry) == fields and entry.get("tool") == "remember" and entry.get("ok") is True
    return (entry.get("tool") in ("remember", "update")
            and set(entry) == fields | {"write_outcome_version"}
            and entry.get("ok") is False and entry.get("write_outcome") == BEGIN_BUSY_OUTCOME
            and type(entry.get("write_outcome_version")) is int
            and entry["write_outcome_version"] == BEGIN_BUSY_VERSION)


def verified_write_ids(tool: str, arguments: dict[str, Any], result: dict[str, Any]) -> list[str]:
    content = result.get("content")
    if (not isinstance(content, list) or len(content) != 1
            or not isinstance(content[0], dict) or content[0].get("type") != "text"
            or not isinstance(content[0].get("text"), str) or "structuredContent" in result):
        return []
    texts = [content[0]["text"]]
    for text in texts:
        if tool in {"remember", "update"}:
            prefix = "Stored" if tool == "remember" else "Updated"
            match = re.match(rf"^{prefix} memory \(id: ({UUID_PATTERN})(?:,|\))", text)
            if match:
                memory_id = normalized_uuid(match[1])
                if tool == "remember" or memory_id == normalized_uuid(arguments.get("id")):
                    return [memory_id]
        elif tool == "connect":
            match = re.match(rf"^Connected \(edge id: {UUID_PATTERN}\) \[id:({UUID_PATTERN})\] --\[([a-z_]+)\]--> \[id:({UUID_PATTERN})\]", text)
            if match and normalized_uuid(match[1]) == normalized_uuid(arguments.get("from")) and normalized_uuid(match[3]) == normalized_uuid(arguments.get("to")) and match[2] == arguments.get("relation"):
                return [normalized_uuid(match[1]), normalized_uuid(match[3])]
    return []


def compatible_initialize(message: dict[str, Any]) -> dict[str, Any]:
    """Omit the one unsupported optional Codex auth-change advertisement.

    Codex 0.154 sends an empty object for this experimental capability. The
    Engram 0.14.7 Swift MCP decoder accepts only String values in this map.
    Engram does not implement Codex auth-change notifications, so omitting
    this advertisement loses no supported behavior. Preserve all standard
    capabilities and all other extension data; do not flatten arbitrary JSON.
    """
    if message.get("method") != "initialize":
        return message
    params = message.get("params")
    capabilities = params.get("capabilities") if isinstance(params, dict) else None
    experimental = capabilities.get("experimental") if isinstance(capabilities, dict) else None
    if not isinstance(experimental, dict) or experimental.get("codex/auth-change") != {}:
        return message
    experimental = dict(experimental)
    del experimental["codex/auth-change"]
    capabilities = dict(capabilities)
    if experimental:
        capabilities["experimental"] = experimental
    else:
        capabilities.pop("experimental")
    return dict(message, params=dict(params, capabilities=capabilities))


class Policy:
    def __init__(self, audit: Audit, provenance: str, max_tool_calls: int, max_writes: int, allowed_tools: list[str] | None = None,
                 *, operations=None, provider_mode=None):
        if provider_mode not in (None, PLANNING_MODE):
            raise ProxyError("Unsupported provider mode")
        if provider_mode == PLANNING_MODE and operations is not None:
            raise ProxyError("A planning provider cannot receive mutation authority")
        self.audit = audit
        self.provenance = provenance
        self.max_tool_calls = max_tool_calls
        self.max_writes = max_writes
        self.allowed_tools = ALLOWED_TOOLS if allowed_tools is None else ALLOWED_TOOLS.intersection(allowed_tools)
        if provider_mode == PLANNING_MODE:
            # Enforce this at dispatch as well as discovery. A provider cannot
            # bypass the plan by naming a hidden mutation or native operation.
            self.allowed_tools = self.allowed_tools.intersection(READ_TOOLS)
        self.total_calls = 0
        self.write_calls = 0
        self.pending: dict[tuple[type, Any], dict[str, Any]] = {}
        self.used_ids: set[tuple[type, Any]] = set()
        # The learner has a short, finite tool budget. Bound control traffic and
        # denied calls too, so pings or denied retries cannot grow audit/ID state.
        self.message_count = 0
        self.max_messages = max(64, max_tool_calls * 4 + 8)
        self.operations = operations
        self.operation_tools_available = False

    def record_result(self, request_id: Any, tool: str, ok: bool, memory_ids: list[str] | None = None, *, forwarded: bool = True, write_outcome: str | None = None, write_outcome_version: int | None = None, operation_receipt=None) -> None:
        entry = {"event": "tool_result", "id": request_id, "tool": tool, "ok": ok, "memory_ids": memory_ids or [], "forwarded": forwarded}
        if write_outcome is not None:
            entry["write_outcome"] = write_outcome
        if write_outcome_version is not None:
            entry["write_outcome_version"] = write_outcome_version
        if operation_receipt is not None:
            # Content-free correlation; the private durable journal retains the
            # authoritative receipt and its complete scope/identity binding.
            entry.update(operation_version=1, operation_id=operation_receipt["operationID"],
                         operation_outcome=operation_receipt["outcome"],
                         operation_payload_digest=operation_receipt["payloadDigest"])
        self.audit.write(entry)

    def deny_tool(self, request_id: Any, tool: str, reason: str) -> tuple[None, dict[str, Any]]:
        self.record_result(request_id, tool, False, forwarded=False)
        return None, tool_error(request_id, reason)

    def client_message(self, message: Any) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
        self.message_count += 1
        if self.message_count > self.max_messages:
            raise ProxyError("Learner protocol message limit reached")
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            raise ProxyError("Invalid client JSON-RPC message")
        method = message.get("method")
        request_id = message.get("id")
        if method in {"notifications/initialized", "notifications/cancelled"} and "id" not in message:
            return message, None
        if method == "tools/call":
            params = message.get("params")
            name = params.get("name") if isinstance(params, dict) else None
            # Audit a fixed label for malformed/unbounded names, never arbitrary text.
            tool = name if isinstance(name, str) and re.fullmatch(r"[a-z_]{1,64}", name) else "invalid_tool"
            audit_id = request_id if valid_id(request_id) else None
            self.audit.write({"event": "tool_call", "id": audit_id, "tool": tool})
            self.total_calls += 1
            if not valid_id(request_id):
                return self.deny_tool(audit_id, tool, "invalid request ID")
            key = id_key(request_id)
            if key in self.used_ids:
                return self.deny_tool(request_id, tool, "request ID was already used")
            self.used_ids.add(key)
            if self.total_calls > self.max_tool_calls:
                return self.deny_tool(request_id, tool, "tool-call limit reached")
            if name not in self.allowed_tools:
                return self.deny_tool(request_id, tool, "tool is not allowed")
            arguments = params.get("arguments", {})
            if not isinstance(arguments, dict):
                return self.deny_tool(request_id, tool, "arguments must be an object")
            arguments = dict(arguments)
            if tool in WRITE_TOOLS:
                self.write_calls += 1
                if self.write_calls > self.max_writes:
                    return self.deny_tool(request_id, tool, "write limit reached")
            if tool == "remember":
                if set(arguments) - REMEMBER_FIELDS:
                    return self.deny_tool(request_id, tool, "unsupported remember fields")
                if arguments.get("force", False) is not False:
                    return self.deny_tool(request_id, tool, "conflict overrides are not allowed")
                arguments["is_private"] = True
                arguments["source"] = self.provenance
                arguments["force"] = False
            elif tool == "update":
                if set(arguments) - UPDATE_FIELDS or normalized_uuid(arguments.get("id")) is None:
                    return self.deny_tool(request_id, tool, "updates require an exact UUID and cannot change privacy, restore, or move memories")
            elif tool == "connect":
                if set(arguments) != {"from", "to", "relation"} or normalized_uuid(arguments.get("from")) is None or normalized_uuid(arguments.get("to")) is None or arguments.get("relation") not in RELATIONS:
                    return self.deny_tool(request_id, tool, "invalid connection endpoints or relation")
            forwarded = dict(message, params=dict(params, arguments=arguments))
            operation = None
            if self.operations is not None and tool in WRITE_TOOLS:
                if not self.operation_tools_available:
                    return self.deny_tool(request_id, tool, "durable native operation capability is unavailable")
                # Errors after intent/dispatch publication stop the relay. They
                # cannot be disguised as a denied/no-write call or fall back to
                # a legacy mutation, because forwarding may be ambiguous.
                operation, forwarded = self.operations.prepare(request_id, tool, arguments)
            verification_fields = {"update": ("id",), "connect": ("from", "to", "relation")}.get(tool, ())
            verification = {field: arguments[field] for field in verification_fields}
            self.pending[key] = {"id": request_id, "method": method, "tool": tool, "arguments": verification}
            if operation is not None:
                self.pending[key]["operation"] = operation
            return forwarded, None
        if not valid_id(request_id) or id_key(request_id) in self.used_ids:
            return None, rpc_error(request_id if valid_id(request_id) else None, "Invalid or repeated request ID")
        self.used_ids.add(id_key(request_id))
        if method not in {"initialize", "ping", "tools/list"}:
            self.audit.write({"event": "tool_call", "id": request_id, "tool": "rpc_denied"})
            self.record_result(request_id, "rpc_denied", False)
            return None, rpc_error(request_id, "Only the memory tool protocol is available")
        self.pending[id_key(request_id)] = {"id": request_id, "method": method}
        forwarded = compatible_initialize(message)
        if forwarded is not message:
            self.audit.write({"event": "initialize_compat", "omitted_capability": "codex/auth-change"})
        return forwarded, None

    def server_message(self, message: Any) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
        """Return (client output, child output); child requests cannot escape."""
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            raise ProxyError("Invalid child JSON-RPC message")
        if "method" in message:
            if "id" in message:
                return None, rpc_error(message.get("id"), "Server-initiated requests are not available in the learner")
            if message.get("method") in {"notifications/progress", "notifications/tools/list_changed"}:
                return message, None
            return None, None
        request_id = message.get("id")
        if not valid_id(request_id):
            raise ProxyError("Invalid child response ID")
        pending = self.pending.pop(id_key(request_id), None)
        if pending is None:
            raise ProxyError("Unexpected child response ID")
        result = message.get("result")
        if pending["method"] == "tools/list" and isinstance(result, dict):
            tools = result.get("tools")
            if not isinstance(tools, list):
                raise ProxyError("Invalid child tool list")
            if self.operations is not None:
                names = {tool.get("name") for tool in tools if isinstance(tool, dict)
                         and isinstance(tool.get("name"), str)}
                self.operation_tools_available = {"operation_scope", "operation_apply", "operation_status"} <= names
            filtered = [learner_tool_descriptor(tool, self.provenance) for tool in tools
                        if isinstance(tool, dict) and tool.get("name") in self.allowed_tools]
            return dict(message, result=dict(result, tools=filtered)), None
        if pending["method"] == "tools/call":
            tool = pending["tool"]
            if "operation" in pending:
                receipt = self.operations.finish(pending["operation"], message)
                if receipt is None:
                    self.record_result(request_id, tool, False)
                    return tool_error(request_id, "durable write outcome is unavailable; do not retry blindly"), None
                ids = receipt["memoryIDs"] if receipt["outcome"] == "applied" else []
                self.record_result(request_id, tool, True, ids, operation_receipt=receipt)
                return message, None
            ok = "error" not in message and isinstance(result, dict) and result.get("isError", False) is False
            no_write = ok and verified_no_write_response(tool, result)
            begin_busy = "error" not in message and verified_begin_busy_response(tool, result)
            memory_ids = verified_write_ids(tool, pending["arguments"], result) if ok and tool in WRITE_TOOLS and not no_write else []
            if tool in WRITE_TOOLS and not memory_ids and not no_write:
                ok = False
            self.record_result(request_id, tool, ok, memory_ids if ok else [],
                               write_outcome=NO_WRITE_OUTCOME if no_write else (BEGIN_BUSY_OUTCOME if begin_busy else None),
                               write_outcome_version=BEGIN_BUSY_VERSION if begin_busy else None)
            if not ok and "error" not in message and isinstance(result, dict) and result.get("isError", False) is False:
                return tool_error(request_id, "write was not verified by an Engram receipt; do not retry blindly"), None
        return message, None

    def fail_pending(self) -> None:
        for pending in self.pending.values():
            if pending["method"] == "tools/call":
                if "operation" in pending:
                    self.operations.unavailable(pending["operation"], "transport_error")
                self.record_result(pending["id"], pending["tool"], False)
        self.pending.clear()


def load_config(path: Path) -> dict[str, Any]:
    if not path.is_absolute() or path.is_symlink():
        raise ProxyError("Proxy configuration must be an absolute regular file path")
    if not stat.S_ISREG(path.stat().st_mode) or path.stat().st_mode & 0o077:
        raise ProxyError("Proxy configuration must be a private regular file (mode 0600)")
    config = json.loads(path.read_text())
    if not isinstance(config, dict):
        raise ProxyError("Proxy configuration must be an object")
    transport = config.get("transport")
    if not isinstance(transport, dict) or "url" in transport or transport.get("type", "stdio") != "stdio":
        raise ProxyError("Only stdio memory MCP transports are supported; HTTP is unsupported")
    if not isinstance(transport.get("command"), str) or not transport["command"]:
        raise ProxyError("A stdio memory command is required")
    if not isinstance(transport.get("args", []), list) or any(not isinstance(arg, str) for arg in transport.get("args", [])):
        raise ProxyError("Memory args must be an array of strings")
    if not isinstance(transport.get("env", {}), dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in transport.get("env", {}).items()):
        raise ProxyError("Memory env must contain string pairs")
    if not isinstance(transport.get("env_vars", []), list) or any(not isinstance(k, str) for k in transport.get("env_vars", [])):
        raise ProxyError("Memory env_vars must be an array of names")
    cwd = transport.get("cwd")
    if cwd is not None and (not isinstance(cwd, str) or not Path(cwd).is_absolute()):
        raise ProxyError("Memory cwd must be absolute")
    if not isinstance(config.get("provenance"), str) or not config["provenance"]:
        raise ProxyError("A provenance label is required")
    for field in ("max_tool_calls", "max_writes"):
        if not isinstance(config.get(field), int) or isinstance(config[field], bool) or not 0 <= config[field] <= 1000:
            raise ProxyError("Tool and write limits must be integers between 0 and 1000")
    if not isinstance(config.get("audit_path"), str) or not Path(config["audit_path"]).is_absolute():
        raise ProxyError("audit_path must be absolute")
    if "allowed_tools" in config and (not isinstance(config["allowed_tools"], list) or any(not isinstance(name, str) for name in config["allowed_tools"])):
        raise ProxyError("allowed_tools must be an array of tool names")
    if config.get("provider_mode") not in (None, PLANNING_MODE):
        raise ProxyError("Unsupported provider mode")
    if config.get("provider_mode") == PLANNING_MODE and "execution" not in config:
        raise ProxyError("Planning requires a sealed execution")
    return config


def run(config: dict[str, Any]) -> int:
    try:
        from .stdio_bridge import RelayLimits, run_relay
    except ImportError:  # Direct execution from a packaged runtime.
        from stdio_bridge import RelayLimits, run_relay
    with contextlib.ExitStack() as cleanup:
        operations, fence, transport = None, None, config["transport"]
        diagnostic = _StartupDiagnostic()
        try:
            if "execution" in config:
                operations, fence, transport = durable_execution(config, cleanup, diagnostic=diagnostic)
            diagnostic.stage = "audit_open"
            audit = Audit(Path(config["audit_path"]))
        except Exception as error:
            diagnostic.record(error)
            raise
        cleanup.callback(audit.close)
        policy = Policy(audit, config["provenance"], config["max_tool_calls"],
                        config["max_writes"], config.get("allowed_tools"), operations=operations,
                        provider_mode=config.get("provider_mode"))
        try:
            return run_relay(transport, policy.client_message,
                             policy.server_message, limits=RelayLimits(max_inflight=64),
                             audit=audit.write, writer_fence=fence)
        finally:
            # Record transport uncertainty while the shared fence is still held.
            policy.fail_pending()


def durable_execution(config, cleanup, *, diagnostic=None):
    """Load a runner-issued manifest; JSON never supplies a lock descriptor.

    The gateway reacquires the sealed generation and validates the live marker
    before starting native Engram. A revoked/interrupted generation cannot fall
    back to ordinary unjournaled writes.
    """
    if __package__:
        from . import execution_context as contexts, execution_manifest as journal
        from . import learner_settings, memory_config, operation_gateway, writer_fence
    else:
        scripts = str(Path(__file__).resolve().parent.parent)
        if scripts not in sys.path:
            sys.path.insert(0, scripts)
        from codex_learner import execution_context as contexts, execution_manifest as journal
        from codex_learner import learner_settings, memory_config, operation_gateway, writer_fence
    specification = config["execution"]
    if type(specification) is not dict or set(specification) != {
            "root", "run_dir", "config_path", "plugin_root", "manifest_sha256"}:
        raise ProxyError("Invalid durable execution configuration")
    if any(type(value) is not str for value in specification.values()):
        raise ProxyError("Invalid durable execution configuration")
    paths = contexts.ContextPaths(**{name: Path(specification[name]) for name in
                                    ("root", "run_dir", "config_path", "plugin_root")})
    paths.check()
    manifest, digest = journal.read_manifest(paths.run_dir)
    if digest != specification["manifest_sha256"]:
        raise ProxyError("Durable execution manifest changed")
    if diagnostic is not None:
        diagnostic.bind(paths, manifest, digest, journal)
    mode = manifest.get("provider_mode")
    if mode != config.get("provider_mode") or mode not in (None, PLANNING_MODE):
        raise ProxyError("Durable provider mode changed")
    if mode == PLANNING_MODE and manifest["plan_policy"] != {
            name: config[name] for name in ("max_tool_calls", "max_writes")}:
        raise ProxyError("Durable planning budgets changed")
    if diagnostic is not None:
        diagnostic.stage = "writer_fence"
    fence = cleanup.enter_context(writer_fence.acquire_shared(paths.run_dir, manifest["fencing"]))
    if diagnostic is not None:
        diagnostic.stage = "execution_context"
    context = contexts.load_execution(paths, manifest_sha256=digest, writer_fence=fence)
    if diagnostic is not None:
        diagnostic.stage = "gateway_policy"
    backend = journal._json(journal._unseal(manifest["inputs"]["backend_config"]))
    allowed = sorted(memory_config.allowed_tools(backend["memory"], ALLOWED_TOOLS))
    if mode == PLANNING_MODE:
        allowed = sorted(set(allowed).intersection(READ_TOOLS))
    settings = learner_settings.bounded({} if backend["settings"] is None else backend["settings"]["value"])
    if any(type(config[name]) is not int or not 0 <= config[name] <= settings[name]
           for name in ("max_tool_calls", "max_writes")):
        raise ProxyError("Durable execution budgets changed")
    if (journal.encode(config["transport"]) != journal.encode(context.transport)
            or config["audit_path"] != str(paths.run_dir / "mcp-audit.jsonl")
            or config["provenance"] != "codex-session:" + manifest["session_id"]
            or config.get("allowed_tools") != allowed):
        raise ProxyError("Durable execution policy changed")
    operations = None
    if mode is None:
        if diagnostic is not None:
            diagnostic.stage = "operation_gateway"
        operations = operation_gateway.OperationGateway(paths.run_dir, manifest_sha256=digest,
            writer_fence=fence, validate_inputs=context.validate_inputs)
    return operations, fence, context.transport


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("Usage: memory_proxy.py /absolute/private/config.json", file=sys.stderr)
        return 2
    try:
        return run(load_config(Path(argv[0])))
    except ProxyError as exc:
        print(f"Engram memory gateway: {exc}", file=sys.stderr)
        return 1
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        # Exception text can contain child argv, environment values, or payload.
        print("Engram memory gateway: transport or protocol failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
