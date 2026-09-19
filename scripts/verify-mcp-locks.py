#!/usr/bin/env python3
"""Exercise the real MCP executable against disposable databases only."""

import argparse
from contextlib import closing
import ctypes
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import sqlite3
import subprocess
import tempfile
import time
import uuid


class Client:
    def __init__(self, binary, db, *, environment=None, cwd=None, deadline=None):
        self.started = time.monotonic()
        self.deadline = deadline
        self.output_bytes = 0
        self.stderr = []
        self.buffers = {"stdout": b"", "stderr": b""}
        self.messages = []
        self.next_id = 0
        self.selector = selectors.DefaultSelector()
        env = dict(os.environ if environment is None else environment, CLAUDE_MEMORY_DB=str(db),
                   CLAUDE_SESSION_ID=f"mcp-lock-test-{os.getpid()}-{time.time_ns()}")
        self.process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=env, cwd=cwd)
        # Inherit the verifier's supervised process group. A detached native
        # would escape the outer runner if Python itself received SIGKILL.
        for name in self.buffers:
            stream = getattr(self.process, name)
            os.set_blocking(stream.fileno(), False)
            self.selector.register(stream, selectors.EVENT_READ, name)

    def send(self, method, params=None, notification=False):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notification:
            self.next_id += 1
            message["id"] = self.next_id
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()
        return message.get("id")

    def pump(self, timeout):
        for key, _ in self.selector.select(timeout):
            data = os.read(key.fileobj.fileno(), 65536)
            if not data:
                self.selector.unregister(key.fileobj)
                continue
            name = key.data
            self.output_bytes += len(data)
            assert self.output_bytes <= 16 * 1024**2, "MCP output exceeded 16 MiB"
            self.buffers[name] += data
            while b"\n" in self.buffers[name]:
                line, self.buffers[name] = self.buffers[name].split(b"\n", 1)
                if name == "stderr":
                    self.stderr.append(line.decode(errors="replace"))
                elif line:
                    self.messages.append(json.loads(line))

    def response_message(self, request_id, timeout=15):
        deadline = time.monotonic() + timeout
        if self.deadline is not None:
            deadline = min(deadline, self.deadline)
        while time.monotonic() < deadline:
            for i, message in enumerate(self.messages):
                if message.get("id") == request_id:
                    self.messages.pop(i)
                    return message
            self.pump(min(0.1, max(0, deadline - time.monotonic())))
            if self.process.poll() is not None:
                raise AssertionError(f"MCP exited {self.process.returncode}: "
                                     + "\n".join(self.stderr[-12:]))
        raise AssertionError(f"MCP response exceeded {timeout}s: "
                             + "\n".join(self.stderr[-12:]))

    def response(self, request_id, timeout=15):
        message = self.response_message(request_id, timeout)
        assert "error" not in message, message
        return message["result"]

    def initialize(self):
        response = self.response(self.send("initialize", {
            "protocolVersion": "2025-03-26", "capabilities": {
                "experimental": {"codex": {"structured": True},
                                 "optional": None, "versions": [1, "v1"]}},
            "clientInfo": {"name": "engram-lock-regression", "version": "1"}}))
        assert response["serverInfo"]["name"] == "memory", response
        self.send("notifications/initialized", notification=True)
        return round(time.monotonic() - self.started, 3)

    def call(self, name, arguments, timeout=15):
        result = self.response(self.send("tools/call", {"name": name,
                                  "arguments": arguments}), timeout)
        assert not result.get("isError"), result
        return result

    def close(self, require_clean=False):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        forced = False
        try:
            deadline = time.monotonic() + 6
            while self.process.poll() is None and time.monotonic() < deadline:
                self.pump(min(0.1, max(0, deadline - time.monotonic())))
        finally:
            # Signal/join only our direct child. Group cleanup belongs to the
            # outer supervisor, whose group includes this verifier and native.
            for stop in (self.process.terminate, self.process.kill):
                if self.process.poll() is not None:
                    break
                forced = True
                try:
                    stop()
                except ProcessLookupError:
                    break
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
            self.process.wait(timeout=2)
            self.selector.close()
            self.process.stdout.close()
            self.process.stderr.close()
        assert self.process.returncode is not None, "Owned MCP child did not join"
        if require_clean:
            assert not forced, "MCP did not exit cleanly after stdin closed"
            assert self.process.returncode == 0, self.process.returncode

def tool_text(result):
    assert isinstance(result, dict) and not result.get("isError"), result
    parts = result.get("content", [])
    assert parts and all(part.get("type") == "text" for part in parts), result
    return "\n".join(part["text"] for part in parts)


def remembered_id(result):
    output = tool_text(result)
    match = re.search(r"Stored memory \(id:\s*([0-9A-Fa-f-]{36}),", output)
    assert match, f"Remember returned no successful identity: {output}"
    return str(uuid.UUID(match.group(1))).upper()


def assert_recalled_identity(result, expected_id, expected_content):
    blocks = tool_text(result).split("\n\n")
    marker = f"[id:{expected_id}] "
    matches = [block for block in blocks if block.startswith(marker)]
    assert len(matches) == 1, f"Expected one recalled identity {expected_id}: {blocks}"
    assert matches[0].endswith(") " + expected_content), matches[0]


def assert_failed_write(message):
    assert isinstance(message, dict) and message.get("jsonrpc") == "2.0", message
    assert message.get("id") is not None, message
    # Servers may report a tool execution error or a JSON-RPC error. Neither
    # may be mistaken for a successful remember acknowledgement.
    rpc_error = message.get("error")
    failed = (isinstance(rpc_error, dict) and isinstance(rpc_error.get("message"), str)) or (
        isinstance(message.get("result"), dict) and message["result"].get("isError") is True)
    assert failed, f"Busy remember reported success: {message}"
    assert "Stored memory (id:" not in json.dumps(message), message
    reason = rpc_error["message"] if isinstance(rpc_error, dict) else "\n".join(
        part.get("text", "") for part in message["result"].get("content", []))
    assert re.search(r"\b(?:busy|locked)\b", reason, re.IGNORECASE), f"Write failed for a different reason: {message}"


def persisted_memories(db):
    # Independent read-only connection: verifies committed storage, not the
    # MCP process's cache. db is always created inside this case's temp root.
    with closing(sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=1)) as reader:
        rows = reader.execute("SELECT globalId, content FROM Memory").fetchall()
    return {str(uuid.UUID(row[0])).upper(): row[1] for row in rows}


def run_persistence(binary):
    configured_tmp = os.environ.get("TMPDIR")
    assert configured_tmp and Path(configured_tmp).is_dir(), "persistence requires an existing owned TMPDIR"
    started = time.monotonic()
    deadline = started + 120
    with tempfile.TemporaryDirectory(prefix="engram-mcp-persistence-", dir=configured_tmp) as directory:
        root = Path(directory).resolve()
        db = root / "memory.sqlite"
        for path in (root / "home", root / "home/.codex", root / "tmp"):
            path.mkdir(parents=True, exist_ok=True)
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C",
               "HOME": str(root / "home"), "CFFIXED_USER_HOME": str(root / "home"),
               "CODEX_HOME": str(root / "home/.codex"), "TMPDIR": str(root / "tmp") + "/"}
        token = uuid.uuid4().hex
        original = f"Persistence keeper {token}: retain this exact identity and content across process reopen."
        rejected = f"Persistence rejected {token}: this busy write must never be stored."
        recovered = f"Persistence recovery {token}: writes succeed after the owned lock is released."
        project = "PersistenceRegression"
        client = None
        process_ids = []
        process_group_ids = []
        clean_exits = []

        def open_client():
            assert time.monotonic() < deadline, "Persistence case exceeded 120s"
            result = Client(binary, db, environment=env, cwd=root, deadline=deadline)
            process_ids.append(result.process.pid)
            process_group_ids.append(os.getpgid(result.process.pid))
            return result

        def close_clean():
            nonlocal client
            client.close(require_clean=True)
            clean_exits.append(client.process.returncode)
            client = None

        def recall_content(expected_id, content):
            result = client.call("recall", {"query": content, "project": project,
                                            "limit": 5, "depth": 0})
            assert_recalled_identity(result, expected_id, content)

        try:
            # Writer process must close cleanly before a second process opens.
            client = open_client()
            client.initialize()
            original_id = remembered_id(client.call("remember", {
                "content": original, "project": project, "force": True}))
            close_clean()
            assert persisted_memories(db) == {original_id: original}

            client = open_client()
            client.initialize()
            recall_content(original_id, original)
            with closing(sqlite3.connect(db, timeout=1)) as writer:
                writer.execute("BEGIN IMMEDIATE")
                try:
                    busy_started = time.monotonic()
                    request_id = client.send("tools/call", {"name": "remember", "arguments": {
                        "content": rejected, "project": project, "force": True}})
                    failed = client.response_message(request_id, timeout=9)
                    assert_failed_write(failed)
                    busy_seconds = time.monotonic() - busy_started
                    assert busy_seconds < 6, f"Busy remember took {busy_seconds:.3f}s"
                    assert persisted_memories(db) == {original_id: original}
                finally:
                    writer.rollback()
            recovered_id = remembered_id(client.call("remember", {
                "content": recovered, "project": project, "force": True}))
            assert recovered_id != original_id
            close_clean()

            # A third process proves recovery was committed, not only visible
            # in the process that acknowledged the successful retry.
            client = open_client()
            client.initialize()
            recall_content(original_id, original)
            recall_content(recovered_id, recovered)
            close_clean()
            rows = persisted_memories(db)
            assert rows == {original_id: original, recovered_id: recovered}, rows
            assert len(set(process_ids)) == 3, process_ids
            assert process_group_ids == [os.getpgrp()] * 3, "Native escaped the verifier's supervised process group"
            assert time.monotonic() < deadline, "Persistence case exceeded 120s"
            print(json.dumps({"case": "persistence", "passed": True,
                              "seconds": round(time.monotonic() - started, 3),
                              "process_ids": process_ids, "clean_exits": clean_exits,
                              "process_group_ids": process_group_ids,
                              "original_id": original_id, "recovered_id": recovered_id,
                              "busy_write_seconds": round(busy_seconds, 3),
                              "rejected_write_absent": True, "separate_process_reopens": 2}), flush=True)
        finally:
            if client is not None:
                client.close()


def read_lock_holders(db):
    if os.uname().sysname != "Darwin":
        return None

    class Flock(ctypes.Structure):
        _fields_ = [("start", ctypes.c_longlong), ("length", ctypes.c_longlong),
                    ("pid", ctypes.c_int), ("type", ctypes.c_short),
                    ("whence", ctypes.c_short)]

    with open(str(db) + "-shm", "rb") as file:
        holders = {}
        for byte in range(123, 128):
            probe = Flock(byte, 1, 0, fcntl.F_WRLCK, os.SEEK_SET)
            result = Flock.from_buffer_copy(fcntl.fcntl(file.fileno(), fcntl.F_GETLK,
                                                       bytes(probe)))
            if result.type != fcntl.F_UNLCK:
                holders[byte] = result.pid
        return holders


def run(binary, case):
    if case == "persistence":
        return run_persistence(binary)
    with tempfile.TemporaryDirectory(prefix="engram-mcp-locks-") as directory:
        db = Path(directory) / "memory.sqlite"
        client = Client(binary, db)
        try:
            elapsed = client.initialize()
            tools = client.response(client.send("tools/list"))["tools"]
            assert any(tool["name"] == "recall" for tool in tools)
            print(json.dumps({"initialize_seconds": elapsed, "tools": len(tools)}), flush=True)
            arguments = {"query": "isolated database contention regression",
                         "project": "LockRegression", "limit": 1, "depth": 0}
            client.call("remember", {"content": "Isolated database contention regression fixture.",
                                      "project": "LockRegression", "force": True})
            client.call("recall", arguments)
            time.sleep(0.25)
            holders = read_lock_holders(db)
            print(json.dumps({"idle_read_lock_holders": holders}), flush=True)
            if case == "idle":
                assert not holders, f"Idle MCP retains WAL read locks: {holders}"
            if case == "recall":
                with sqlite3.connect(db, timeout=2) as writer:
                    writer.execute("BEGIN IMMEDIATE")
                    started = time.monotonic()
                    result = client.call("recall", arguments, timeout=9)
                    assert "Isolated database contention" in json.dumps(result), result
                    elapsed = time.monotonic() - started
                    assert elapsed < 6, elapsed
                    print(json.dumps({"locked_recall_seconds": round(elapsed, 3)}), flush=True)
                    writer.rollback()
                client.call("recall", arguments)
            client.close(require_clean=True)
            client = None
            if case == "startup":
                with sqlite3.connect(db, timeout=2) as writer:
                    writer.execute("BEGIN IMMEDIATE")
                    client = Client(binary, db)
                    deadline = time.monotonic() + 8
                    while client.process.poll() is None and time.monotonic() < deadline:
                        client.pump(0.1)
                    assert client.process.poll() is not None, "Locked startup exceeded 8s"
                    assert client.process.returncode != 0, "Locked database unexpectedly opened"
                    assert any("Failed to initialize database" in line for line in client.stderr), client.stderr
                    print(json.dumps({"locked_startup_exit": client.process.returncode,
                                      "seconds": round(time.monotonic() - client.started, 3)}), flush=True)
                    writer.rollback()
                client.close()
                client = Client(binary, db)
                client.initialize()
                client.close(require_clean=True)
                client = None
            print(json.dumps({"case": case, "passed": True}), flush=True)
        finally:
            if client:
                client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case", choices=["smoke", "idle", "recall", "startup", "persistence"], default="smoke")
    args = parser.parse_args()
    run(args.binary.resolve(), args.case)
