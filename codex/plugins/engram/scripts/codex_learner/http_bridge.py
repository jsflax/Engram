"""Read-only learner HTTP adapter, supervised by the existing bounded stdio relay.

Compatibility transport for initialize-based MCP 2025-03-26 / 2025-06-18.
No redirects, retries, legacy SSE endpoint discovery, or stream resumption.
The process boundary lets the relay enforce absolute deadlines even during DNS,
TLS or trickling reads. Only fixed error codes reach diagnostics.
"""
from __future__ import annotations

import http.client
import json
import math
import os
from pathlib import Path
import re
import ssl
import stat
import sys
import threading
import time
from urllib.parse import urlsplit

if __package__:
    from . import stdio_bridge as bridge
else:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import stdio_bridge as bridge

VERSIONS = frozenset({"2025-03-26", "2025-06-18"})
READ_TOOLS = frozenset({"recall", "graph", "list_topics", "stats", "timeline"})
MAX_BODY = 1024 * 1024
MAX_INFLIGHT = 8


def require(condition, reason):
    if not condition:
        raise bridge.RelayError(reason)


def decode_utf8(raw):
    return bridge._decode(raw.decode("utf-8"))


def validate_transport(value):
    require(type(value) is dict and {"type", "url", "credential_file"} <= value.keys()
            and not value.keys() - {"type", "url", "credential_file", "request_timeout_sec",
                                    "initialize_timeout_sec", "max_response_bytes", "max_inflight"}
            and value["type"] == "http", "http_invalid_transport")
    url = value["url"]
    require(type(url) is str and 1 <= len(url) <= 2048 and url.isascii()
            and not any(ord(c) <= 32 or ord(c) == 127 for c in url), "http_invalid_endpoint")
    try:
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError:
        raise bridge.RelayError("http_invalid_endpoint") from None
    require(parsed.scheme == "https" and parsed.hostname and parsed.username is None
            and parsed.password is None and not parsed.query and not parsed.fragment
            and "?" not in url and "#" not in url and "\\" not in url
            and (port is None or 1 <= port <= 65535), "http_invalid_endpoint")
    credential = value["credential_file"]
    require(type(credential) is str and Path(credential).is_absolute(), "http_invalid_credential_path")
    for field, default, maximum in (("request_timeout_sec", 30, 120), ("initialize_timeout_sec", 10, 30)):
        limit = value.get(field, default)
        require(type(limit) in (int, float) and math.isfinite(limit) and 0.1 <= limit <= maximum,
                "http_invalid_limits")
    for field, default, maximum, minimum in (("max_response_bytes", MAX_BODY, MAX_BODY, 1024),
                                            ("max_inflight", MAX_INFLIGHT, MAX_INFLIGHT, 1)):
        limit = value.get(field, default)
        require(type(limit) is int and minimum <= limit <= maximum, "http_invalid_limits")
    return parsed


def _credential(transport):
    path = Path(transport["credential_file"])
    require(path.resolve(strict=True) == path, "http_unsafe_credential")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and not before.st_mode & 0o077 and before.st_nlink == 1
                and before.st_size <= 128 * 1024, "http_unsafe_credential")
        raw = stream.read(128 * 1024 + 1)
        after = os.fstat(stream.fileno())
        identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                                 info.st_ctime_ns, info.st_mode, info.st_uid, info.st_nlink)
        require(identity(before) == identity(after) == identity(path.lstat())
                and len(raw) == before.st_size, "http_credential_changed")
    value = decode_utf8(raw)
    require(type(value) is dict and set(value) in (
        {"version", "endpoint", "bearer_token"}, {"version", "endpoint", "bearer_token", "tls_ca_pem"})
        and type(value["version"]) is int and value["version"] == 1
        and value["endpoint"] == transport["url"], "http_credential_binding")
    token = value["bearer_token"]
    require(type(token) is str and 1 <= len(token) <= 8192
            and re.fullmatch(r"[A-Za-z0-9._~+/-]+=*", token), "http_invalid_credential")
    ca = value.get("tls_ca_pem")
    require(ca is None or (type(ca) is str and 1 <= len(ca) <= 65536
                          and "-----BEGIN CERTIFICATE-----" in ca), "http_invalid_trust")
    context = ssl.create_default_context(cadata=ca)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.set_alpn_protocols(["http/1.1"])
    return token, context


def run_relay(transport, client_message, server_message, *, audit):
    """Policy remains in the parent; credentials are read only in the child."""
    validate_transport(transport)
    limits = bridge.RelayLimits(max_line_bytes=MAX_BODY,
        max_queue_bytes=4 * MAX_BODY, max_inflight=transport.get("max_inflight", MAX_INFLIGHT),
        request_timeout_sec=transport.get("request_timeout_sec", 30),
        initialize_timeout_sec=transport.get("initialize_timeout_sec", 10))
    child = {"command": sys.executable, "args": ["-I", str(Path(__file__).resolve()), json.dumps(transport)]}
    return bridge.run_relay(child, client_message, server_message, limits=limits, audit=audit)


class Adapter:
    def __init__(self, transport):
        self.transport = transport
        self.url = validate_transport(transport)
        self.token, self.context = _credential(transport)
        self.maximum = transport.get("max_response_bytes", MAX_BODY)
        self.capacity = transport.get("max_inflight", MAX_INFLIGHT)
        self.lock = threading.RLock()
        self.output_lock = threading.Lock()
        self.active = set()
        self.server_requests = set()
        self.jobs = set()
        self.version = None
        self.session = None
        self.initialized = False

    def output(self, message):
        data = json.dumps(message, separators=(",", ":"), allow_nan=False).encode()
        require(len(data) <= MAX_BODY, "http_frame_limit")
        with self.output_lock:
            sys.stdout.buffer.write(data + b"\n")
            sys.stdout.buffer.flush()

    def deliver(self, message, request, initializing=False):
        kind = bridge._kind(message)
        if kind == "response":
            require(bridge._id_key(message["id"]) == bridge._id_key(request["id"]), "http_response_id")
            if initializing:
                result = message.get("result")
                require(type(result) is dict and result.get("protocolVersion") == request["params"]["protocolVersion"]
                        and type(result.get("capabilities")) is dict and type(result.get("serverInfo")) is dict,
                        "http_initialize_response")
                self.version = result["protocolVersion"]
            with self.lock:
                self.active.discard(bridge._id_key(message["id"]))
            self.output(message)
            return True
        require(not initializing, "http_initialize_message")
        if kind == "request":
            key = bridge._id_key(message["id"])
            with self.lock:
                require(key not in self.server_requests and len(self.server_requests) < self.capacity,
                        "http_server_request_limit")
                self.server_requests.add(key)
        self.output(message)
        return False

    def post(self, message):
        initializing = message.get("method") == "initialize"
        request = bridge._kind(message) == "request"
        duration = self.transport.get("initialize_timeout_sec", 10) if initializing else self.transport.get("request_timeout_sec", 30)
        deadline = time.monotonic() + duration
        raw = json.dumps(message, separators=(",", ":"), allow_nan=False).encode()
        require(len(raw) <= MAX_BODY, "http_frame_limit")
        headers = {"Authorization": "Bearer " + self.token, "Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream", "Accept-Encoding": "identity"}
        if self.version:
            headers["MCP-Protocol-Version"] = self.version
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        connection = http.client.HTTPSConnection(self.url.hostname, self.url.port or 443,
                                                 timeout=duration, context=self.context)
        # Notifications have no JSON-RPC pending ID in the outer relay. Give
        # every POST its own absolute deadline too: socket timeouts alone can
        # be extended indefinitely by a server trickling bytes or a DNS stall.
        watchdog = threading.Timer(duration, lambda: os._exit(1))
        watchdog.daemon = True
        watchdog.start()
        try:
            connection.request("POST", self.url.path or "/", body=raw, headers=headers)
            response = connection.getresponse()
            require(response.status == (200 if request else 202), "http_status")
            header_pairs = response.getheaders()
            for name in ("content-type", "content-length", "mcp-session-id", "transfer-encoding", "mcp-protocol-version"):
                require(sum(k.lower() == name for k, _ in header_pairs) <= 1, "http_duplicate_header")
            require(not (response.getheader("Content-Length") and response.getheader("Transfer-Encoding")),
                    "http_ambiguous_length")
            require(response.getheader("Content-Encoding", "identity").lower() == "identity", "http_encoding")
            length = response.getheader("Content-Length")
            if length is not None:
                require(length.isdecimal() and int(length) <= self.maximum, "http_body_limit")
            session = response.getheader("Mcp-Session-Id")
            if session is not None:
                require(1 <= len(session) <= 256 and all(33 <= ord(c) <= 126 for c in session), "http_session")
                require(initializing or session == self.session, "http_session_changed")
            if initializing:
                self.session = session
            version_header = response.getheader("MCP-Protocol-Version")
            require(version_header is None or version_header == (
                message["params"]["protocolVersion"] if initializing else self.version), "http_protocol_header")
            media = response.getheader("Content-Type", "").split(";", 1)[0].strip().lower()
            if request and media == "text/event-stream":
                size, count, data = 0, 0, []
                while True:
                    require(time.monotonic() < deadline, "http_deadline")
                    line = response.readline(min(65536, self.maximum - size) + 1)
                    size += len(line)
                    require(size <= self.maximum and len(line) <= 65536, "http_body_limit")
                    require(line, "http_incomplete_stream")
                    line = line.rstrip(b"\r\n")
                    if not line and data:
                        count += 1
                        require(count <= 128, "http_event_limit")
                        if self.deliver(decode_utf8(b"\n".join(data)), message, initializing):
                            return
                        data = []
                    elif line.startswith(b"data:"):
                        data.append(line[5:].removeprefix(b" "))
                    elif line.startswith(b"event:"):
                        require(line[6:].strip() in (b"", b"message"), "http_sse_event")
            else:
                body = response.read(self.maximum + 1)
                require(time.monotonic() < deadline and len(body) <= self.maximum, "http_body_limit")
                if request:
                    require(media == "application/json", "http_content_type")
                    decoded = decode_utf8(body)
                    require(bridge._kind(decoded) == "response", "http_expected_response")
                    self.deliver(decoded, message, initializing)
                else:
                    require(not body, "http_notification_body")
        finally:
            watchdog.cancel()
            connection.close()

    def accept(self, message):
        kind = bridge._kind(message)
        method = message.get("method")
        if self.version is None:
            require(method == "initialize" and kind == "request" and type(message.get("params")) is dict
                    and message["params"].get("protocolVersion") in VERSIONS, "http_initialize_required")
            self.post(message)
            return
        require(method != "initialize", "http_reinitialize")
        if not self.initialized:
            require(kind == "notification" and method == "notifications/initialized", "http_initialized_required")
            self.post(message)
            self.initialized = True
            return
        if kind == "request":
            # Defense in depth even if this adapter is invoked without Policy.
            require(method in ("ping", "tools/list", "tools/call"), "http_method_denied")
            if method == "tools/call":
                require(type(message.get("params")) is dict and message["params"].get("name") in READ_TOOLS,
                        "http_write_not_qualified")
        elif kind == "notification":
            require(method == "notifications/cancelled" and type(message.get("params")) is dict,
                    "http_notification_denied")
            with self.lock:
                # A legitimate cancellation can race a completed response.
                if bridge._id_key(message["params"].get("requestId")) not in self.active:
                    return
        else:
            with self.lock:
                key = bridge._id_key(message["id"])
                require(key in self.server_requests, "http_unexpected_response")
                self.server_requests.remove(key)
        key = bridge._id_key(message["id"]) if kind == "request" else None
        with self.lock:
            require(len(self.jobs) < self.capacity + 2, "http_inflight_limit")
            if key is not None:
                require(key not in self.active and len(self.active) < self.capacity, "http_inflight_limit")
                self.active.add(key)
            def work():
                try:
                    self.post(message)
                except BaseException:
                    # The supervising relay records unresolved calls and tears
                    # down the session. Never retry or convert to write success.
                    os._exit(1)
                finally:
                    with self.lock:
                        self.active.discard(key)
                        self.jobs.discard(threading.current_thread())
            thread = threading.Thread(target=work, daemon=True)
            self.jobs.add(thread)
            thread.start()

    def run(self):
        while True:
            raw = sys.stdin.buffer.readline(MAX_BODY + 2)
            if not raw:
                break
            require(len(raw) <= MAX_BODY + 1 and raw.endswith(b"\n"), "http_frame_limit")
            self.accept(bridge._decode(raw))
        deadline = time.monotonic() + 0.75
        while self.jobs and time.monotonic() < deadline:
            time.sleep(0.01)
        return 1 if self.jobs else 0


def main():
    try:
        require(len(sys.argv) == 2, "http_arguments")
        # Header parser bounds apply only to this isolated adapter process.
        http.client._MAXLINE, http.client._MAXHEADERS = 8192, 32
        return Adapter(bridge._decode(sys.argv[1].encode())).run()
    except BaseException:
        print("Engram HTTP adapter: transport or protocol failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
