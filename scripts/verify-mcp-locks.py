#!/usr/bin/env python3
"""Exercise the real MCP executable against disposable databases only."""

import argparse
import ctypes
import fcntl
import json
import os
from pathlib import Path
import selectors
import sqlite3
import subprocess
import tempfile
import time


class Client:
    def __init__(self, binary, db):
        self.started = time.monotonic()
        self.stderr = []
        self.buffers = {"stdout": b"", "stderr": b""}
        self.messages = []
        self.next_id = 0
        self.selector = selectors.DefaultSelector()
        env = dict(os.environ, CLAUDE_MEMORY_DB=str(db),
                   CLAUDE_SESSION_ID=f"mcp-lock-test-{os.getpid()}-{time.time_ns()}")
        self.process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=env)
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
            self.buffers[name] += data
            while b"\n" in self.buffers[name]:
                line, self.buffers[name] = self.buffers[name].split(b"\n", 1)
                if name == "stderr":
                    self.stderr.append(line.decode(errors="replace"))
                elif line:
                    self.messages.append(json.loads(line))

    def response(self, request_id, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for i, message in enumerate(self.messages):
                if message.get("id") == request_id:
                    self.messages.pop(i)
                    assert "error" not in message, message
                    return message["result"]
            self.pump(min(0.1, max(0, deadline - time.monotonic())))
            if self.process.poll() is not None:
                raise AssertionError(f"MCP exited {self.process.returncode}: "
                                     + "\n".join(self.stderr[-12:]))
        raise AssertionError(f"MCP response exceeded {timeout}s: "
                             + "\n".join(self.stderr[-12:]))

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
        try:
            self.process.wait(timeout=6)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            if require_clean:
                raise AssertionError("MCP did not exit after stdin closed")
        finally:
            self.selector.close()
            self.process.stdout.close()
            self.process.stderr.close()
        if require_clean:
            assert self.process.returncode == 0, self.process.returncode


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
    parser.add_argument("--case", choices=["smoke", "idle", "recall", "startup"], default="smoke")
    args = parser.parse_args()
    run(args.binary.resolve(), args.case)
