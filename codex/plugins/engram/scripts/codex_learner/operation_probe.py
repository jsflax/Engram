"""Read-only, bounded pre-dispatch probe of the trusted native MCP route.

Only initialize, notifications/initialized and operation_scope are sent. The
returned scope is an observation to seal in execution_manifest.expected_scope;
it is not replay authority or proof a later process has the same identity. The
actual mutation gateway must still bind each native request to that scope.

Transport resolution, inherited shared-fence environment and process cleanup
are the relay's implementations. The caller owns the HeldFence and must keep it
open throughout this call. No provider, memory mutation or durable publication
occurs here. Diagnostics contain fixed labels, never backend output or paths.
"""
from __future__ import annotations

import copy
from dataclasses import dataclass
import math
import os
import selectors
import signal
import subprocess
import threading
import time

from . import execution_manifest as manifest, stdio_bridge as bridge
from .operation_gateway import envelope
from .writer_fence import HeldFence

PROTOCOL_VERSION = "2025-11-25"
CAPABILITY = "localMutationOperationsV1"


class ProbeError(RuntimeError):
    """A fixed, payload-free failure; never authoritative operation absence."""


def _require(condition, reason):
    if not condition:
        raise ProbeError("operation_probe_" + reason)


@dataclass(frozen=True)
class ProbeLimits:
    deadline_seconds: float = 10.0
    max_frame_bytes: int = 65536
    max_output_bytes: int = 262144
    terminate_timeout_seconds: float = 0.25

    def __post_init__(self):
        for value, maximum in ((self.deadline_seconds, 30),
                               (self.terminate_timeout_seconds, 1)):
            _require(type(value) in (int, float) and math.isfinite(value)
                     and 0 < value <= maximum, "invalid_limits")
        _require(type(self.max_frame_bytes) is int and 128 <= self.max_frame_bytes <= 1048576
                 and type(self.max_output_bytes) is int
                 and self.max_frame_bytes <= self.max_output_bytes <= 2097152,
                 "invalid_limits")


def _initialize(result):
    _require(type(result) is dict
             and {"protocolVersion", "capabilities", "serverInfo"} <= set(result)
             and result["protocolVersion"] == PROTOCOL_VERSION, "invalid_initialize")
    capabilities, server = result["capabilities"], result["serverInfo"]
    _require(type(capabilities) is dict and type(capabilities.get("tools")) is dict
             and type(server) is dict
             and type(server.get("name")) is str and bool(server["name"])
             and type(server.get("version")) is str and bool(server["version"]),
             "invalid_initialize")


def _scope_result(result):
    payload = envelope(result)
    _require(type(payload) is dict and set(payload) == {"version", "kind", "capability", "scope"}
             and type(payload["version"]) is int and payload["version"] == 1
             and payload["kind"] == "scope" and payload["capability"] == CAPABILITY,
             "unsupported_scope")
    manifest._scope(payload["scope"])
    return copy.deepcopy(payload["scope"])


def probe_scope(transport, *, writer_fence: HeldFence, expected_binding, limits=None):
    """Return exact validated scope from one separate native process.

    One wall-clock deadline covers the entire protocol exchange, with additional
    relay TERM/KILL cleanup. On an exceptional unreapable OS process the relay
    deliberately retains ownership beyond that cleanup budget; this function
    cannot return success or release its fence reference while that child lives.
    No installed runtime is selected implicitly: transport must be pre-resolved
    and trusted by the caller. The native child inherits the same shared lock.
    """
    limits = ProbeLimits() if limits is None else limits
    _require(type(limits) is ProbeLimits, "invalid_limits")
    binding = copy.deepcopy(expected_binding)
    _require(isinstance(writer_fence, HeldFence) and writer_fence.mode == "shared", "writer_unfenced")
    child = None
    selector = selectors.DefaultSelector()
    old_signals = {}
    interrupted = False
    deadline = time.monotonic() + limits.deadline_seconds
    buffer = bytearray()
    output_bytes = 0
    scope = None

    def interrupt(_signal, _frame):
        nonlocal interrupted
        # Do not throw between Popen creation and retaining its cleanup handle.
        interrupted = True

    def check():
        _require(not interrupted, "interrupted")
        _require(time.monotonic() < deadline, "deadline")

    def ready(fd, event):
        check()
        selector.register(fd, event)
        try:
            while True:
                check()
                if selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                    return
        finally:
            selector.unregister(fd)

    def send(message):
        check()
        _require(writer_fence.verify(binding) is True, "writer_unfenced")
        raw = manifest.encode(message)
        _require(len(raw) <= limits.max_frame_bytes, "frame_limit")
        pending = memoryview(raw + b"\n")
        while pending:
            ready(child.stdin.fileno(), selectors.EVENT_WRITE)
            try:
                written = os.write(child.stdin.fileno(), pending)
            except BlockingIOError:
                continue
            _require(written > 0, "peer_closed")
            pending = pending[written:]

    def receive(request_id):
        nonlocal output_bytes
        while True:
            check()
            newline = buffer.find(b"\n")
            if newline >= 0:
                _require(newline <= limits.max_frame_bytes, "frame_limit")
                raw = bytes(buffer[:newline])
                del buffer[:newline + 1]
                # This fixed conversation has no concurrent requests, server
                # notifications or requests. Coalesced extra frames fail closed.
                _require(not buffer, "unsolicited_output")
                message = manifest._json(raw, maximum=limits.max_frame_bytes)
                _require(bridge._kind(message) == "response"
                         and set(message) == {"jsonrpc", "id", "result"}
                         and type(message["id"]) is int and message["id"] == request_id,
                         "invalid_response")
                return message["result"]
            _require(len(buffer) <= limits.max_frame_bytes, "frame_limit")
            ready(child.stdout.fileno(), selectors.EVENT_READ)
            try:
                chunk = os.read(child.stdout.fileno(), min(65536, limits.max_frame_bytes + 1 - len(buffer)))
            except BlockingIOError:
                continue
            _require(bool(chunk), "incomplete_response")
            output_bytes += len(chunk)
            _require(output_bytes <= limits.max_output_bytes, "output_limit")
            buffer.extend(chunk)

    try:
        _require(writer_fence.verify(binding) is True, "writer_unfenced")
        argv, env, cwd, pass_fds = bridge._fenced_transport(transport, writer_fence)
        if threading.current_thread() is threading.main_thread():
            for sig in (signal.SIGTERM, signal.SIGINT):
                old_signals[sig] = signal.signal(sig, interrupt)
        check()
        child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, env=env, cwd=cwd, pass_fds=pass_fds,
                                 bufsize=0, start_new_session=True)
        os.set_blocking(child.stdin.fileno(), False)
        os.set_blocking(child.stdout.fileno(), False)
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": PROTOCOL_VERSION, "capabilities": {},
            "clientInfo": {"name": "engram-operation-probe", "version": "1"}}})
        _initialize(receive(1))
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
              "params": {"name": "operation_scope", "arguments": {}}})
        scope = _scope_result(receive(2))
        check()
        _require(writer_fence.verify(binding) is True, "writer_unfenced")
    except ProbeError:
        raise
    except KeyboardInterrupt:
        raise ProbeError("operation_probe_interrupted") from None
    except (OSError, ValueError, TypeError, RecursionError, bridge.RelayError, subprocess.SubprocessError):
        raise ProbeError("operation_probe_transport_or_protocol_failure") from None
    finally:
        cleanup_failed = False
        try:
            try:
                selector.close()
            except BaseException:
                cleanup_failed = True
            if child is not None:
                cleanup = bridge._cleanup(child, limits.terminate_timeout_seconds)
                cleanup_failed |= (not cleanup["child_reaped"] or cleanup["cleanup_failed"]
                                   or cleanup["cleanup_overrun"])
        finally:
            for sig, handler in old_signals.items():
                try:
                    signal.signal(sig, handler)
                except BaseException:
                    cleanup_failed = True
        _require(not cleanup_failed, "cleanup_failed")
        _require(not interrupted, "interrupted")
    return scope
