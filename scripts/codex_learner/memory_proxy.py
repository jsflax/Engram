#!/usr/bin/env python3
"""A bounded, audited, memory-only newline JSON-RPC gateway.

Usage: python memory_proxy.py /absolute/private/config.json
No transcript, tool arguments, memory content, or child environment is audited.
The child transport is stdio; HTTP configurations are explicitly unsupported.
"""

from __future__ import annotations

import copy
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
REMEMBER_FIELDS = frozenset({"content", "project", "topic", "source", "expires_in_days", "importance", "is_private", "parent_id", "force"})
UPDATE_FIELDS = frozenset({"id", "content", "append", "prepend", "find", "replace", "topic", "source", "importance", "expires_in_days"})
RELATIONS = frozenset({"relates_to", "contradicts", "supersedes", "derived_from", "part_of", "summarized_by"})
UUID_PATTERN = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
MAX_LINE_BYTES = 8 * 1024 * 1024


class ProxyError(Exception):
    pass


def normalized_uuid(value: Any) -> str | None:
    if not isinstance(value, str) or re.fullmatch(UUID_PATTERN, value) is None:
        return None
    return str(uuid.UUID(value))


def valid_id(value: Any) -> bool:
    return (isinstance(value, int) and not isinstance(value, bool)) or (isinstance(value, str) and len(value) <= 128 and re.fullmatch(r"[A-Za-z0-9_.:-]+", value) is not None)


def id_key(value: Any) -> tuple[type, Any]:
    return type(value), value


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


class Policy:
    def __init__(self, audit: Audit, provenance: str, max_tool_calls: int, max_writes: int, allowed_tools: list[str] | None = None):
        self.audit = audit
        self.provenance = provenance
        self.max_tool_calls = max_tool_calls
        self.max_writes = max_writes
        self.allowed_tools = ALLOWED_TOOLS if allowed_tools is None else ALLOWED_TOOLS.intersection(allowed_tools)
        self.total_calls = 0
        self.write_calls = 0
        self.pending: dict[tuple[type, Any], dict[str, Any]] = {}
        self.used_ids: set[tuple[type, Any]] = set()

    def record_result(self, request_id: Any, tool: str, ok: bool, memory_ids: list[str] | None = None, *, write_outcome: str | None = None, write_outcome_version: int | None = None) -> None:
        entry = {"event": "tool_result", "id": request_id, "tool": tool, "ok": ok, "memory_ids": memory_ids or []}
        if write_outcome is not None:
            entry.update(write_outcome=write_outcome, forwarded=True)
        if write_outcome_version is not None:
            entry["write_outcome_version"] = write_outcome_version
        self.audit.write(entry)

    def deny_tool(self, request_id: Any, tool: str, reason: str) -> tuple[None, dict[str, Any]]:
        self.record_result(request_id, tool, False)
        return None, tool_error(request_id, reason)

    def client_message(self, message: Any) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
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
            self.pending[key] = {"id": request_id, "method": method, "tool": tool, "arguments": arguments}
            return forwarded, None
        if not valid_id(request_id) or id_key(request_id) in self.used_ids:
            return None, rpc_error(request_id if valid_id(request_id) else None, "Invalid or repeated request ID")
        self.used_ids.add(id_key(request_id))
        if method not in {"initialize", "ping", "tools/list"}:
            self.audit.write({"event": "tool_call", "id": request_id, "tool": "rpc_denied"})
            self.record_result(request_id, "rpc_denied", False)
            return None, rpc_error(request_id, "Only the memory tool protocol is available")
        self.pending[id_key(request_id)] = {"id": request_id, "method": method}
        return message, None

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
            filtered = [learner_tool_descriptor(tool, self.provenance) for tool in tools
                        if isinstance(tool, dict) and tool.get("name") in self.allowed_tools]
            return dict(message, result=dict(result, tools=filtered)), None
        if pending["method"] == "tools/call":
            tool = pending["tool"]
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
    return config


def send(stream, message: dict[str, Any]) -> None:
    stream.write((json.dumps(message, separators=(",", ":")) + "\n").encode())
    stream.flush()


def run(config: dict[str, Any]) -> int:
    audit = Audit(Path(config["audit_path"]))
    policy = Policy(audit, config["provenance"], config["max_tool_calls"], config["max_writes"], config.get("allowed_tools"))
    transport = config["transport"]
    inherited = {"PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"} | set(transport.get("env_vars", []))
    env = {key: value for key, value in os.environ.items() if key in inherited}
    env.update(transport.get("env", {}))
    child = None
    selector = selectors.DefaultSelector()
    try:
        child = subprocess.Popen([transport["command"], *transport.get("args", [])], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=transport.get("cwd"), env=env)
        selector.register(sys.stdin.buffer, selectors.EVENT_READ, "client")
        selector.register(child.stdout, selectors.EVENT_READ, "child")
        buffers = {"client": b"", "child": b""}
        shutdown_deadline = None
        while selector.get_map():
            if shutdown_deadline is not None and time.monotonic() >= shutdown_deadline:
                break
            for key, _ in selector.select(timeout=0.2):
                origin = key.data
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    if buffers[origin]:
                        raise ProxyError("Incomplete newline JSON-RPC message")
                    if origin == "client":
                        child.stdin.close()
                        shutdown_deadline = time.monotonic() + 3
                    else:
                        policy.fail_pending()
                        return 0 if child.wait(timeout=1) == 0 else 1
                    continue
                buffers[origin] += chunk
                while b"\n" in buffers[origin]:
                    line, buffers[origin] = buffers[origin].split(b"\n", 1)
                    if len(line) > MAX_LINE_BYTES:
                        raise ProxyError("JSON-RPC line exceeded size limit")
                    if not line.strip():
                        continue
                    message = json.loads(line)
                    if origin == "client":
                        forwarded, response = policy.client_message(message)
                        if forwarded is not None:
                            send(child.stdin, forwarded)
                        if response is not None:
                            send(sys.stdout.buffer, response)
                    else:
                        response, forwarded = policy.server_message(message)
                        if response is not None:
                            send(sys.stdout.buffer, response)
                        if forwarded is not None and not child.stdin.closed:
                            send(child.stdin, forwarded)
                if len(buffers[origin]) > MAX_LINE_BYTES:
                    raise ProxyError("JSON-RPC line exceeded size limit")
        return 1 if policy.pending else 0
    finally:
        selector.close()
        try:
            policy.fail_pending()
        finally:
            try:
                if child is not None:
                    try:
                        if not child.stdin.closed:
                            child.stdin.close()
                    except OSError:
                        pass
                    if child.poll() is None:
                        child.terminate()
                        try:
                            child.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait(timeout=2)
                    child.stdout.close()
            finally:
                audit.close()


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
