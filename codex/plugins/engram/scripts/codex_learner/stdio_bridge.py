#!/usr/bin/env python3
"""Bounded POSIX newline JSON-RPC relay for interactive Engram MCP sessions.

`run_relay` owns the child process group and retains its direct child until
joined; joining alone makes no descendant-termination claim. Policy callbacks have the learner
gateway's existing tuple contract: client_message -> (to_child, to_client),
server_message -> (to_client, to_child). They must finish promptly and preserve
the incoming message's ID and request/response kind when forwarding it.

The pump bounds each frame, outgoing queue, and simultaneous request set. IDs
are retained only until their response, in separate namespaces per direction.
There is no session lifetime or total-call cap. Deadlines include queue time;
cancellation is forwarded and retains correlation until a response or deadline.
Timeout, malformed data, unknown response, or duplicate active ID terminates the
connection, so late replies cannot be misattributed after reusing an ID.

CLI: python stdio_bridge.py --config /absolute/private/transport.json
The JSON object contains `transport` (command, args, env, env_vars, cwd), optional
`relay` limits, and optional `bridge_audit_path`. Audit contains fixed event labels
and counts only. Child stderr is discarded. No provider or model is invoked by
the bridge itself; the configured stdio server is the only child it launches.
"""

from __future__ import annotations

import argparse
from collections import deque
import json
import math
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import threading
import time
from typing import Any, Callable


class RelayError(Exception):
    """A fixed, payload-free reason safe to expose in diagnostics."""


class RelayLimits:
    def __init__(self, *, max_line_bytes=8 * 1024 * 1024,
                 max_queue_bytes=16 * 1024 * 1024, max_inflight=128,
                 request_timeout_sec=120.0, initialize_timeout_sec=10.0,
                 io_timeout_sec=10.0, shutdown_timeout_sec=1.0,
                 terminate_timeout_sec=0.25):
        values = locals().copy()
        values.pop("self")
        for name, value in values.items():
            if name.startswith("max_"):
                if type(value) is not int or value < 1:
                    raise RelayError("invalid_limits")
            elif type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
                raise RelayError("invalid_limits")
            setattr(self, name, value)
        if max_queue_bytes < max_line_bytes + 1:
            raise RelayError("invalid_limits")


def _id_key(value: Any) -> tuple[type, Any]:
    if type(value) is int or (type(value) is str and len(value.encode("utf-8")) <= 1024):
        return type(value), value
    raise RelayError("invalid_id")


def _kind(message: Any) -> str:
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        raise RelayError("invalid_message")
    if "method" in message:
        if not isinstance(message["method"], str) or not message["method"] or "result" in message or "error" in message:
            raise RelayError("invalid_message")
        if "params" in message and not isinstance(message["params"], (dict, list)):
            raise RelayError("invalid_message")
        if "id" in message:
            _id_key(message["id"])
            return "request"
        return "notification"
    if "id" not in message or ("result" in message) == ("error" in message):
        raise RelayError("invalid_message")
    _id_key(message["id"])
    if "error" in message:
        error = message["error"]
        if not isinstance(error, dict) or type(error.get("code")) is not int or not isinstance(error.get("message"), str):
            raise RelayError("invalid_message")
    return "response"


def _decode(line: bytes) -> dict[str, Any]:
    def unique_pairs(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise RelayError("duplicate_json_key")
            value[key] = item
        return value

    def no_constant(_):
        raise RelayError("invalid_json")

    try:
        return json.loads(line, object_pairs_hook=unique_pairs, parse_constant=no_constant)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise RelayError("invalid_json") from exc


class _Queue:
    def __init__(self, limit: int):
        self.limit = limit
        self.parts: deque[bytes] = deque()
        self.offset = 0
        self.size = 0
        self.progress_at = time.monotonic()

    def append(self, message: dict[str, Any], max_line: int):
        try:
            data = json.dumps(message, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")
        except (ValueError, TypeError, UnicodeError, RecursionError) as exc:
            raise RelayError("invalid_output") from exc
        if len(data) > max_line:
            raise RelayError("frame_limit")
        data += b"\n"
        if self.size + len(data) > self.limit:
            raise RelayError("queue_limit")
        if not self.size:
            self.progress_at = time.monotonic()
        self.parts.append(data)
        self.size += len(data)

    def write(self, fd: int):
        try:
            written = os.write(fd, memoryview(self.parts[0])[self.offset:self.offset + 65536])
        except BlockingIOError:
            return
        if written <= 0:
            raise RelayError("peer_closed")
        self.offset += written
        self.size -= written
        self.progress_at = time.monotonic()
        if self.offset == len(self.parts[0]):
            self.parts.popleft()
            self.offset = 0


def _transport(transport: dict[str, Any]) -> tuple[list[str], dict[str, str], str | None]:
    if not isinstance(transport, dict) or transport.get("type", "stdio") != "stdio" or "url" in transport:
        raise RelayError("invalid_transport")
    command, args = transport.get("command"), transport.get("args", [])
    if not isinstance(command, str) or not command or not isinstance(args, list) or any(not isinstance(arg, str) for arg in args):
        raise RelayError("invalid_transport")
    supplied, names = transport.get("env", {}), transport.get("env_vars", [])
    if not isinstance(supplied, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in supplied.items()):
        raise RelayError("invalid_transport")
    if not isinstance(names, list) or any(not isinstance(k, str) for k in names):
        raise RelayError("invalid_transport")
    cwd = transport.get("cwd")
    if cwd is not None and (not isinstance(cwd, str) or not Path(cwd).is_absolute()):
        raise RelayError("invalid_transport")
    inherited = {"PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"} | set(names)
    env = {key: value for key, value in os.environ.items() if key in inherited}
    env.update(supplied)
    return [command, *args], env, cwd


def _cleanup(child: subprocess.Popen, timeout: float):
    failed = False
    joined = False
    overrun = False
    for stream in (child.stdin, child.stdout):
        try:
            stream.close()
        except BaseException:
            failed = True

    def owned_signal(sig):
        nonlocal failed, joined
        try:
            if child.poll() is not None:
                joined = True
                return
            # Preserve the owned group's bounded escalation only while its
            # direct leader is unreaped. Never signal a reaped numeric group.
            try:
                os.killpg(child.pid, sig)
            except (ProcessLookupError, PermissionError):
                if child.poll() is None:
                    child.send_signal(sig)
                else:
                    joined = True
        except BaseException:
            failed = True

    def wait_owned(seconds):
        nonlocal failed, joined
        try:
            child.wait(timeout=seconds)
            joined = True
        except subprocess.TimeoutExpired:
            pass
        except BaseException:
            failed = True
        return joined

    owned_signal(signal.SIGTERM)
    if not wait_owned(timeout):
        owned_signal(signal.SIGKILL)
        if not joined and not wait_owned(max(0.5, timeout)):
            overrun = failed = True
            # Keep this exact Popen/session beyond the ordinary cleanup bound.
            # No more signals, retries, descendant claims or successful result.
            while not wait_owned(0.1):
                try:
                    time.sleep(0.1)
                except BaseException:
                    failed = True
    return {"child_reaped": joined, "cleanup_failed": failed, "cleanup_overrun": overrun}


def run_relay(transport: dict[str, Any], client_message: Callable, server_message: Callable,
              *, limits: RelayLimits | None = None, audit: Callable | None = None,
              client_input=None, client_output=None) -> int:
    """Run a policy-controlled relay; return 0 on clean EOF, 1 on failure.

    Callers own policy cleanup (e.g. fail_pending) in their own finally block.
    Audit is best effort and cannot affect transport execution. It never receives
    IDs, method/tool names, arguments, results, paths, environment, or stderr.
    """
    limits = limits or RelayLimits()
    argv, env, cwd = _transport(transport)
    client_input = sys.stdin.buffer if client_input is None else client_input
    client_output = sys.stdout.buffer if client_output is None else client_output
    child = None
    selector = selectors.DefaultSelector()
    restore = {}
    previous_signals = {}
    peak_pending = 0
    peaks = {"client": 0, "server": 0}
    cancelled = False

    def emit(event, **counts):
        if audit is not None:
            try:
                audit({"event": event, **counts})
            except Exception:
                pass

    def interrupted(_signum, _frame):
        nonlocal cancelled
        # Never raise while constructing Popen or retaining its cleanup handle.
        cancelled = True

    try:
        if threading.current_thread() is threading.main_thread():
            for sig in (signal.SIGTERM, signal.SIGINT):
                previous_signals[sig] = signal.signal(sig, interrupted)
        if cancelled:
            raise KeyboardInterrupt
        child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, env=env, cwd=cwd,
                                 bufsize=0, start_new_session=True)
        inputs = {"client": client_input.fileno(), "server": child.stdout.fileno()}
        outputs = {"client": client_output.fileno(), "server": child.stdin.fileno()}
        for fd in (*inputs.values(), *outputs.values()):
            restore[fd] = os.get_blocking(fd)
            os.set_blocking(fd, False)
        buffers = {side: bytearray() for side in inputs}
        next_line = {side: -1 for side in inputs}
        partial_at = {side: time.monotonic() for side in inputs}
        reading = {side: True for side in inputs}
        queues = {side: _Queue(limits.max_queue_bytes) for side in outputs}
        pending = {side: {} for side in inputs}
        shutdown_deadline = None
        child_input_closed = False
        emit("relay_started")

        def enqueue(side, message):
            queues[side].append(message, limits.max_line_bytes)
            peaks[side] = max(peaks[side], queues[side].size)

        def process(side, message):
            nonlocal peak_pending
            other = "server" if side == "client" else "client"
            kind = _kind(message)
            key = _id_key(message["id"]) if kind != "notification" else None
            if kind == "request":
                if key in pending[side]:
                    raise RelayError("duplicate_active_id")
                if len(pending["client"]) + len(pending["server"]) >= limits.max_inflight:
                    enqueue(side, {"jsonrpc": "2.0", "id": message["id"], "error": {
                        "code": -32000, "message": "MCP relay is at its simultaneous request limit"}})
                    emit("request_rejected_capacity")
                    return
            elif kind == "response" and key not in pending[other]:
                raise RelayError("unexpected_response")
            callback = client_message if side == "client" else server_message
            forwarded, response = callback(message)
            if forwarded is not None:
                if _kind(forwarded) != kind or (kind != "notification" and _id_key(forwarded["id"]) != key):
                    raise RelayError("policy_correlation")
                enqueue(other, forwarded)
            if response is not None:
                if kind != "request" or _kind(response) != "response" or _id_key(response["id"]) != key:
                    raise RelayError("policy_correlation")
                enqueue(side, response)
            if kind == "request" and forwarded is not None:
                if response is not None:
                    raise RelayError("policy_correlation")
                duration = limits.initialize_timeout_sec if message["method"] == "initialize" else limits.request_timeout_sec
                pending[side][key] = (message["id"], time.monotonic() + duration)
                peak_pending = max(peak_pending, sum(map(len, pending.values())))
            elif kind == "request" and response is None:
                raise RelayError("policy_dropped_request")
            elif kind == "response":
                if forwarded is None:
                    raise RelayError("policy_dropped_response")
                del pending[other][key]

        while True:
            if cancelled:
                raise KeyboardInterrupt
            now = time.monotonic()
            # A deadline error is correlated but carries no request contents.
            for side, requests in pending.items():
                for request_id, deadline in requests.values():
                    if now >= deadline:
                        emit("request_timeout")
                        error = {"jsonrpc": "2.0", "id": request_id, "error": {
                            "code": -32001, "message": "MCP relay request deadline exceeded"}}
                        # Never block error reporting to a non-reading client.
                        queue = queues[side]
                        if queue.size == 0:
                            queue.append(error, limits.max_line_bytes)
                            try:
                                queue.write(outputs[side])
                            except OSError:
                                pass
                        return 1
            for side, queue in queues.items():
                if queue.size and now - queue.progress_at >= limits.io_timeout_sec:
                    raise RelayError("write_stall")
                if buffers[side] and next_line[side] < 0 and now - partial_at[side] >= limits.io_timeout_sec:
                    raise RelayError("partial_frame_timeout")

            if shutdown_deadline is not None and now >= shutdown_deadline:
                clean = not any(pending.values()) and not any(q.size for q in queues.values()) and not any(buffers.values())
                return 0 if clean and child.poll() == 0 else 1
            if not reading["client"] and not queues["server"].size and not child_input_closed:
                child.stdin.close()
                child_input_closed = True
            if not reading["server"] and not queues["client"].size:
                if child.poll() is not None:
                    return 0 if not any(pending.values()) and not any(buffers.values()) and child.returncode == 0 else 1

            # Keep processing buffered frames even if the fd has no new bytes.
            for side in inputs:
                for _ in range(32):
                    if max(q.size for q in queues.values()) > limits.max_queue_bytes - limits.max_line_bytes - 1:
                        break
                    split = next_line[side]
                    if split < 0:
                        break
                    if split > limits.max_line_bytes:
                        raise RelayError("frame_limit")
                    line = bytes(buffers[side][:split])
                    del buffers[side][:split + 1]
                    next_line[side] = buffers[side].find(b"\n")
                    partial_at[side] = time.monotonic()
                    if line.strip():
                        process(side, _decode(line))

            for key in list(selector.get_map().values()):
                selector.unregister(key.fd)
            ready_buffer = False
            # Pausing readers is backpressure; writes stay independently ready.
            room = max(q.size for q in queues.values()) <= limits.max_queue_bytes - limits.max_line_bytes - 1
            for side, fd in inputs.items():
                if reading[side] and room and next_line[side] < 0:
                    selector.register(fd, selectors.EVENT_READ, ("read", side))
                ready_buffer |= room and next_line[side] >= 0
            for side, fd in outputs.items():
                if queues[side].size and not (side == "server" and child_input_closed):
                    selector.register(fd, selectors.EVENT_WRITE, ("write", side))
            deadlines = [t for requests in pending.values() for _, t in requests.values()]
            if shutdown_deadline is not None:
                deadlines.append(shutdown_deadline)
            for side, queue in queues.items():
                if queue.size:
                    deadlines.append(queue.progress_at + limits.io_timeout_sec)
                if buffers[side] and next_line[side] < 0:
                    deadlines.append(partial_at[side] + limits.io_timeout_sec)
            delay = max(0, min([0.1, *(deadline - time.monotonic() for deadline in deadlines)]))
            for key, _ in selector.select(0 if ready_buffer else delay):
                action, side = key.data
                if action == "write":
                    queues[side].write(key.fd)
                    continue
                try:
                    chunk = os.read(key.fd, min(65536, limits.max_line_bytes + 1 - len(buffers[side])))
                except BlockingIOError:
                    continue
                if not chunk:
                    reading[side] = False
                    if buffers[side]:
                        emit("incomplete_frame", origin=side, buffered_bytes=len(buffers[side]),
                             complete_line_present=next_line[side] >= 0,
                             whitespace_only=not buffers[side].strip())
                        raise RelayError("incomplete_frame")
                    if shutdown_deadline is None:
                        shutdown_deadline = time.monotonic() + limits.shutdown_timeout_sec
                    if side == "server":
                        reading["client"] = False
                        if queues["server"].size:
                            raise RelayError("server_eof_pending_output")
                        queues["server"] = _Queue(limits.max_queue_bytes)
                    continue
                if not buffers[side]:
                    partial_at[side] = time.monotonic()
                # Reads only happen after previously buffered lines are consumed.
                # Scan the new bytes once, not the growing multi-MiB prefix.
                split = chunk.find(b"\n")
                if split >= 0:
                    next_line[side] = len(buffers[side]) + split
                buffers[side].extend(chunk)
                if len(buffers[side]) > limits.max_line_bytes and next_line[side] < 0:
                    raise RelayError("frame_limit")
    except RelayError as exc:
        emit("relay_failed", reason=str(exc))
        return 1
    except (OSError, ValueError, TypeError, RecursionError, subprocess.SubprocessError):
        emit("relay_failed", reason="transport_or_policy_failure")
        return 1
    except KeyboardInterrupt:
        emit("relay_interrupted")
        return 1
    finally:
        cleanup_failed = False
        cleanup = {"child_reaped": False, "cleanup_failed": False, "cleanup_overrun": False}
        try:
            selector.close()
        except BaseException:
            cleanup_failed = True
        # Restore only the caller-owned descriptors; child streams are closed.
        for stream in (client_input, client_output):
            try:
                fd = stream.fileno()
                if fd in restore:
                    os.set_blocking(fd, restore[fd])
            except BaseException:
                cleanup_failed = True
        if child is not None:
            cleanup = _cleanup(child, limits.terminate_timeout_sec)
            cleanup_failed |= cleanup["cleanup_failed"]
        for sig, handler in previous_signals.items():
            try:
                signal.signal(sig, handler)
            except BaseException:
                cleanup_failed = True
        if cleanup_failed:
            emit("relay_cleanup_failed", cleanup_overrun=cleanup["cleanup_overrun"])
        emit("relay_finished", peak_inflight=peak_pending,
             peak_client_queue_bytes=peaks["client"], peak_server_queue_bytes=peaks["server"],
             child_reaped=cleanup["child_reaped"], cleanup_overrun=cleanup["cleanup_overrun"])
        if cleanup_failed or cancelled:
            return 1


def _read_config(path: Path) -> dict[str, Any]:
    if not path.is_absolute():
        raise RelayError("invalid_config")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 65536:
            raise RelayError("invalid_config")
        raw = stream.read(65537)
        if len(raw) > 65536:
            raise RelayError("invalid_config")
        config = json.loads(raw)
    if not isinstance(config, dict):
        raise RelayError("invalid_config")
    return config


class _AuditLog:
    def __init__(self, path: str):
        if not isinstance(path, str) or not Path(path).is_absolute():
            raise RelayError("invalid_audit")
        self.fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        if not stat.S_ISREG(os.fstat(self.fd).st_mode):
            os.close(self.fd)
            raise RelayError("invalid_audit")
        os.fchmod(self.fd, 0o600)

    def write(self, event):
        data = (json.dumps(event, separators=(",", ":")) + "\n").encode()
        try:
            if os.fstat(self.fd).st_size + len(data) <= 1024 * 1024:
                os.write(self.fd, data)
        except OSError:
            pass

    def close(self):
        os.close(self.fd)


def run(config: dict[str, Any]) -> int:
    # Lazy import permits memory_proxy to reuse run_relay without a cycle.
    if __package__:
        from .memory_proxy import compatible_initialize
    else:
        from memory_proxy import compatible_initialize

    log = _AuditLog(config["bridge_audit_path"]) if "bridge_audit_path" in config else None

    def client_message(message):
        forwarded = compatible_initialize(message)
        if forwarded is not message and log is not None:
            log.write({"event": "initialize_compat"})
        return forwarded, None

    try:
        return run_relay(config["transport"], client_message, lambda message: (message, None),
                         limits=RelayLimits(**config.get("relay", {})),
                         audit=log.write if log else None)
    finally:
        if log is not None:
            log.close()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args(argv)

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, interrupted)
    try:
        return run(_read_config(args.config))
    except (Exception, KeyboardInterrupt):
        # Never echo exception details: they can contain config or payload data.
        print("Engram MCP bridge: transport or protocol failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
