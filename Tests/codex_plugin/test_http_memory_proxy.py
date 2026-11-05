"""Real gateway subprocess and isolated TLS MCP server; synthetic credentials only."""
import json
import os
from pathlib import Path
import select
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from suite_support import PLUGIN_ROOT

GATEWAY = PLUGIN_ROOT / "scripts/codex_learner/memory_proxy.py"
TOKEN = "synthetic-bearer-must-not-appear-in-diagnostics"
VERSION = "2025-06-18"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError, ssl.SSLEOFError):
            pass  # Expected when the gateway aborts malformed/oversize replies.

    def reply(self, status, value=b"", content_type="application/json", **headers):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, val in headers.items():
            self.send_header(key.replace("_", "-"), val)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    def do_POST(self):
        message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.messages.append((message, dict(self.headers)))
        method = message.get("method")
        mode = self.server.mode
        if method == "initialize":
            return self.reply(200, {"jsonrpc": "2.0", "id": message["id"], "result": {
                "protocolVersion": "2099-01-01" if mode == "bad_version" else VERSION, "capabilities": {"tools": {}},
                "serverInfo": {"name": "synthetic", "version": "1"}}}, Mcp_Session_Id="synthetic-session")
        if method is None:
            self.server.answered.set()
            return self.reply(202)
        if method == "notifications/cancelled":
            self.server.cancelled.set()
        if method == "notifications/initialized" and mode == "drip_initialized":
            self.send_response(202)
            self.send_header("Content-Length", "30")
            self.end_headers()
            try:
                for _ in range(30):
                    self.wfile.write(b"x")
                    self.wfile.flush()
                    time.sleep(0.05)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass
            return
        if "id" not in message:
            return self.reply(202)
        if method == "tools/list":
            result = {"tools": [{"name": name, "inputSchema": {"type": "object"}}
                                for name in ("stats", "remember", "update", "connect", "shell")]}
        else:
            result = {"content": [{"type": "text", "text": "synthetic answer"}], "isError": False}
        response = {"jsonrpc": "2.0", "id": message["id"], "result": result}
        if method == "tools/call":
            self.server.started.set()
            if mode == "redirect":
                return self.reply(307, TOKEN.encode(), Location=self.server.redirect)
            if mode == "unauthorized":
                return self.reply(401, TOKEN.encode())
            if mode == "bad_id":
                response["id"] = str(message["id"])
            if mode == "both_results":
                response["error"] = {"code": -1, "message": "contradictory"}
            if mode == "duplicate_json":
                return self.reply(200, b'{"jsonrpc":"2.0","id":3,"id":3,"result":{}}')
            if mode == "utf16":
                return self.reply(200, json.dumps(response).encode("utf-16"))
            if mode == "oversize":
                return self.reply(200, b"x" * 4096)
            if mode == "slow":
                time.sleep(1.5)
            if mode == "cancel":
                self.server.cancelled.wait(3)
                response = {"jsonrpc": "2.0", "id": message["id"],
                            "error": {"code": -32800, "message": "cancelled"}}
            if mode in ("sse", "server_request"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                first = {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progress": 1}}
                if mode == "server_request":
                    first = {"jsonrpc": "2.0", "id": "server-7", "method": "sampling/createMessage", "params": {}}
                self.wfile.write(b"data: " + json.dumps(first).encode() + b"\n\n")
                self.wfile.flush()
                if mode == "server_request":
                    self.server.answered.wait(3)
                try:
                    self.wfile.write(b"event: message\ndata: " + json.dumps(response).encode() + b"\n\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                    pass
                self.close_connection = True
                return
        self.reply(200, response)


class HTTPMemoryProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="http-gateway-tls-")
        cls.root = Path(cls.temp.name)
        cls.cert, cls.key = cls.root / "cert.pem", cls.root / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
                        "-addext", "basicConstraints=critical,CA:TRUE",
                        "-keyout", str(cls.key), "-out", str(cls.cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.key.chmod(0o600)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.temp_run = tempfile.TemporaryDirectory(prefix="http-gateway-run-")
        self.addCleanup(self.temp_run.cleanup)
        self.directory = Path(self.temp_run.name)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.server.messages = []
        self.server.mode = "json"
        self.server.cancelled = threading.Event()
        self.server.started = threading.Event()
        self.server.answered = threading.Event()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.cert, self.key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f"https://localhost:{self.server.server_port}/mcp"
        self.credential = self.directory / "credential.json"
        self.write(self.credential, {"version": 1, "endpoint": self.url, "bearer_token": TOKEN,
                                     "tls_ca_pem": self.cert.read_text()})
        self.config = {"transport": {"type": "http", "url": self.url,
                                     "credential_file": str(self.credential)},
                       "provenance": "codex-session:synthetic", "max_tool_calls": 10,
                       "allowed_tools": ["stats", "remember", "update", "connect", "shell"],
                       "max_writes": 10, "audit_path": str(self.directory / "audit.jsonl")}

    def write(self, path, value):
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def start(self):
        path = self.directory / "gateway.json"
        self.write(path, self.config)
        process = subprocess.Popen([sys.executable, str(GATEWAY), str(path)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        def cleanup():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()
        self.addCleanup(cleanup)
        return process

    def send(self, process, value):
        process.stdin.write(json.dumps(value).encode() + b"\n")
        process.stdin.flush()

    def receive(self, process, timeout=4):
        self.assertTrue(select.select([process.stdout], [], [], timeout)[0], "gateway reply deadline")
        line = process.stdout.readline()
        self.assertTrue(line, "gateway closed without a response")
        return json.loads(line)

    def initialize(self, process):
        self.send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": VERSION, "capabilities": {}, "clientInfo": {"name": "fixture", "version": "1"}}})
        self.assertEqual(self.receive(process)["id"], 1)
        self.send(process, {"jsonrpc": "2.0", "method": "notifications/initialized"})

    def test_real_tls_gateway_filters_tools_and_denies_writes(self):
        process = self.start()
        self.initialize(process)
        self.send(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.assertEqual([t["name"] for t in self.receive(process)["result"]["tools"]], ["stats"])
        self.send(process, {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                            "params": {"name": "remember", "arguments": {"content": "must not be sent"}}})
        self.assertTrue(self.receive(process)["result"]["isError"])
        self.send(process, {"jsonrpc": "2.0", "id": "read-4", "method": "tools/call",
                            "params": {"name": "stats", "arguments": {}}})
        self.assertEqual(self.receive(process)["id"], "read-4")
        self.assertFalse(any(m.get("params", {}).get("name") == "remember" for m, _ in self.server.messages))
        self.assertTrue(all(h["Authorization"] == "Bearer " + TOKEN for _, h in self.server.messages))
        subsequent = [h for m, h in self.server.messages if m.get("method") != "initialize"]
        self.assertTrue(all(h["Mcp-Session-Id"] == "synthetic-session" for h in subsequent))
        self.assertTrue(all(h["MCP-Protocol-Version"] == VERSION for h in subsequent))
        self.assertNotIn(TOKEN, Path(self.config["audit_path"]).read_text())

    def tool(self, process, request_id=3):
        self.send(process, {"jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                            "params": {"name": "stats", "arguments": {}}})

    def assert_transport_fails(self, process):
        output, diagnostic = process.communicate(timeout=4)
        self.assertNotEqual(process.returncode, 0)
        self.assertNotIn(TOKEN.encode(), output + diagnostic)
        audit = Path(self.config["audit_path"])
        if audit.exists():
            self.assertNotIn(TOKEN, audit.read_text())
        return output

    def test_sse_notification_and_matching_response_use_policy(self):
        self.server.mode = "sse"
        process = self.start()
        self.initialize(process)
        self.tool(process)
        self.assertEqual(self.receive(process)["method"], "notifications/progress")
        self.assertEqual(self.receive(process)["id"], 3)

    def test_server_request_is_denied_by_policy_and_returned_over_http(self):
        self.server.mode = "server_request"
        process = self.start()
        self.initialize(process)
        self.tool(process)
        self.assertEqual(self.receive(process)["id"], 3)
        answers = [m for m, _ in self.server.messages if "method" not in m]
        self.assertEqual(len(answers), 1)
        self.assertEqual(answers[0]["id"], "server-7")
        self.assertIn("error", answers[0])

    def test_cancel_is_forwarded_while_read_request_is_waiting(self):
        self.server.mode = "cancel"
        process = self.start()
        self.initialize(process)
        self.tool(process)
        self.assertTrue(self.server.started.wait(2))
        self.send(process, {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 3}})
        self.assertEqual(self.receive(process)["error"]["code"], -32800)
        self.assertTrue(self.server.cancelled.is_set())

    def test_capacity_rejects_extra_request_without_sending_it(self):
        self.config["transport"]["max_inflight"] = 1
        self.server.mode = "cancel"
        process = self.start()
        self.initialize(process)
        self.tool(process)
        self.assertTrue(self.server.started.wait(2))
        self.tool(process, 4)
        rejected = self.receive(process)
        self.assertEqual(rejected["id"], 4)
        self.assertIn("error", rejected)
        self.send(process, {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 3}})
        self.assertEqual(self.receive(process)["id"], 3)
        self.assertEqual(sum(m.get("method") == "tools/call" for m, _ in self.server.messages), 1)

    def test_bad_remote_responses_close_without_replay_or_secret_diagnostics(self):
        for mode in ("bad_id", "both_results", "duplicate_json", "utf16", "unauthorized", "oversize"):
            with self.subTest(mode=mode):
                self.server.mode = mode
                self.server.messages.clear()
                self.config["transport"]["max_response_bytes"] = 1024
                process = self.start()
                self.initialize(process)
                self.tool(process)
                self.assert_transport_fails(process)
                self.assertEqual(sum(m.get("method") == "tools/call" for m, _ in self.server.messages), 1)

    def test_timeout_does_not_replay_post(self):
        self.server.mode = "slow"
        self.config["transport"]["request_timeout_sec"] = 0.2
        process = self.start()
        self.initialize(process)
        started = time.monotonic()
        self.tool(process)
        self.assert_transport_fails(process)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(sum(m.get("method") == "tools/call" for m, _ in self.server.messages), 1)

    def test_notification_has_absolute_deadline_without_pending_request(self):
        self.server.mode = "drip_initialized"
        self.config["transport"]["request_timeout_sec"] = 0.2
        process = self.start()
        started = time.monotonic()
        self.initialize(process)
        # Keep stdin open: client EOF must not be the reason this is bounded.
        self.assertNotEqual(process.wait(timeout=0.8), 0)
        self.assertLess(time.monotonic() - started, 0.8)

    def test_redirect_never_sends_authorization_to_sink(self):
        sink = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        sink.messages = []
        sink.mode = "json"
        sink.daemon_threads = True
        threading.Thread(target=sink.serve_forever, daemon=True).start()
        self.addCleanup(sink.server_close)
        self.addCleanup(sink.shutdown)
        self.server.mode = "redirect"
        self.server.redirect = f"http://127.0.0.1:{sink.server_port}/steal"
        process = self.start()
        self.initialize(process)
        self.tool(process)
        self.assert_transport_fails(process)
        self.assertEqual(sink.messages, [])

    def test_unknown_protocol_negotiation_is_refused(self):
        self.server.mode = "bad_version"
        process = self.start()
        self.send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": VERSION}})
        self.assert_transport_fails(process)
        self.assertEqual(len(self.server.messages), 1)

    def test_endpoint_credential_binding_and_tls_are_checked_before_auth(self):
        variants = [
            {"version": 1, "endpoint": self.url + "/other", "bearer_token": TOKEN, "tls_ca_pem": self.cert.read_text()},
            {"version": 1, "endpoint": self.url, "bearer_token": TOKEN},
            {"version": 1, "endpoint": self.url, "bearer_token": TOKEN + "\r\nInjected: bad", "tls_ca_pem": self.cert.read_text()},
        ]
        for credential in variants:
            with self.subTest(keys=sorted(credential)):
                self.write(self.credential, credential)
                process = self.start()
                self.send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": VERSION}})
                self.assert_transport_fails(process)
                self.assertEqual(self.server.messages, [])

    def test_http_query_credentials_and_native_execution_are_refused_before_network(self):
        original = self.config["transport"]["url"]
        for url in (original.replace("https:", "http:"), original + "?token=" + TOKEN,
                    original.replace("https://", "https://" + TOKEN + "@")):
            with self.subTest(kind=url.split(":")[0]):
                self.config["transport"]["url"] = url
                self.assert_transport_fails(self.start())
                self.assertEqual(self.server.messages, [])
        self.config["transport"]["url"] = original
        self.config["execution"] = {"root": "synthetic-native-context-must-not-load"}
        self.assert_transport_fails(self.start())
        self.assertEqual(self.server.messages, [])

    def test_credential_file_must_be_private_owned_and_unaliased(self):
        self.credential.chmod(0o644)
        self.assert_transport_fails(self.start())
        self.credential.chmod(0o600)
        alias = self.directory / "credential-alias.json"
        alias.symlink_to(self.credential)
        self.config["transport"]["credential_file"] = str(alias)
        self.assert_transport_fails(self.start())
        alias.unlink()
        os.link(self.credential, alias)
        self.config["transport"]["credential_file"] = str(self.credential)
        self.assert_transport_fails(self.start())
        self.assertEqual(self.server.messages, [])

    def test_late_cancellation_does_not_end_a_healthy_session(self):
        process = self.start()
        self.initialize(process)
        self.tool(process)
        self.assertEqual(self.receive(process)["id"], 3)
        self.send(process, {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 3}})
        self.tool(process, 4)
        self.assertEqual(self.receive(process)["id"], 4)
        self.assertFalse(self.server.cancelled.is_set())

    def test_existing_stdio_gateway_path_still_uses_its_declared_child(self):
        child = self.directory / "stdio_server.py"
        child.write_text('''import json, sys
for line in sys.stdin:
    message = json.loads(line)
    if "id" not in message:
        continue
    result = {"content": [{"type": "text", "text": "synthetic stdio"}], "isError": False}
    if message.get("method") == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "stdio", "version": "1"}}
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
''')
        self.config["transport"] = {"command": sys.executable, "args": [str(child)]}
        process = self.start()
        self.initialize(process)
        self.tool(process)
        self.assertEqual(self.receive(process)["result"]["content"][0]["text"], "synthetic stdio")
        self.assertEqual(self.server.messages, [])


if __name__ == "__main__":
    unittest.main()
