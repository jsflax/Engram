"""Synthetic newline MCP children only; no installed runtime or memory store."""
import copy
import fcntl
import importlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from suite_support import PLUGIN_ROOT

sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
P = importlib.import_module("codex_learner.operation_probe")
F = importlib.import_module("codex_learner.writer_fence")

SCOPE = {"version": 1, "storeID": "11111111-2222-4333-8444-555555555555", "principal": {
    "id": "21111111-2222-4333-8444-555555555555", "kind": "user", "groupIds": [], "scopes": ["read", "write"]}}

SERVER = r'''
import base64, json, os, signal, sys, time
from pathlib import Path
config = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[1]).parent
mode = config['mode']
binding = json.loads(base64.b64decode(os.environ['ENGRAM_WRITER_FENCE_BINDING_B64']))
fd = int(os.environ['ENGRAM_WRITER_FENCE_FD'])
assert os.fstat(fd).st_ino == binding['lock_identity']['inode']
assert json.loads(os.pread(fd, 65536, 0))['epoch_id'] == binding['epoch_id']
(root / 'child.json').write_text(json.dumps({'pid': os.getpid(), 'binding': binding,
    'cwd': os.getcwd(), 'marker': os.environ.get('PROBE_MARKER')}))
if mode in ('ignore_term', 'delay_scope'):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
def read():
    line = sys.stdin.readline()
    if not line: sys.exit(0)
    message = json.loads(line)
    with (root / 'calls.jsonl').open('a') as out: out.write(json.dumps(message) + '\n')
    assert message.get('method') in ('initialize', 'notifications/initialized', 'tools/call')
    if message.get('method') == 'tools/call':
        assert message['params'] == {'name': 'operation_scope', 'arguments': {}}
    return message
def emit(value):
    print(json.dumps(value, separators=(',', ':')), flush=True)
first = read()
assert first['method'] == 'initialize' and first['id'] == 1
if mode == 'delay_initialize': time.sleep(60)
if mode == 'delay_both': time.sleep(0.16)
if mode == 'stderr': os.write(2, b'PRIVATE BACKEND DETAIL' * 100000)
if mode == 'initialize_error':
    emit({'jsonrpc':'2.0','id':1,'error':{'code':-32000,'message':'PRIVATE BACKEND DETAIL'}})
    time.sleep(60)
initialize = {'protocolVersion': first['params']['protocolVersion'], 'capabilities': {'tools': {}},
              'serverInfo': {'name':'fixture', 'version':'1'}}
initialize.update(config.get('initialize_patch', {}))
if mode == 'output_limit': initialize['instructions'] = 'x' * 600
emit({'jsonrpc':'2.0', 'id':1, 'result':initialize})
assert read()['method'] == 'notifications/initialized'
assert read()['id'] == 2
if mode == 'delay_scope': time.sleep(60)
if mode == 'delay_both': time.sleep(0.16)
if mode == 'malformed':
    print('{broken PRIVATE BACKEND DETAIL', flush=True)
elif mode == 'oversized':
    os.write(1, b'x' * 5000)
elif mode == 'truncated':
    os.write(1, b'{"jsonrpc":"2.0"')
elif mode == 'duplicate_json':
    print('{"jsonrpc":"2.0","id":2,"id":2,"result":{}}', flush=True)
elif mode == 'jsonrpc_error':
    emit({'jsonrpc':'2.0','id':2,'error':{'code':-32000,'message':'PRIVATE BACKEND DETAIL'}})
elif mode == 'server_request':
    emit({'jsonrpc':'2.0','id':77,'method':'sampling/createMessage','params':{}})
else:
    payload = config.get('payload', {'version':1,'kind':'scope','capability':'localMutationOperationsV1',
                                     'scope':config['scope']})
    outer = {'engram_operation':payload}
    text = config.get('text', json.dumps(outer))
    result = {'isError':False,'structuredContent':outer,'content':[{'type':'text','text':text}]}
    result.update(config.get('result_patch', {}))
    response = {'jsonrpc':'2.0','id':config.get('response_id', 2),'result':result}
    if mode == 'duplicate_response':
        raw = json.dumps(response).encode() + b'\n'
        os.write(1, raw + raw)
    else: emit(response)
if mode == 'ignore_term': time.sleep(60)
'''


class OperationProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="operation-probe-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.binding = F.create(self.root, generation_id="31111111-2222-4333-8444-555555555555",
                                owner_id="41111111-2222-4333-8444-555555555555")
        self.held = F.acquire_shared(self.root, self.binding)
        self.addCleanup(self.held.close)
        self.script = self.root / "server.py"
        self.script.write_text(SERVER)
        self.config = self.root / "server.json"
        self.transport = {"command": sys.executable, "args": ["-B", str(self.script), str(self.config)],
                          "cwd": str(self.root), "env": {"PROBE_MARKER": "expected"}}
        self.limits = P.ProbeLimits(deadline_seconds=2, terminate_timeout_seconds=0.05,
                                    max_frame_bytes=4096, max_output_bytes=16384)
        self.children = []
        self.cleanup_results = []
        cleanup = P.bridge._cleanup

        def observed_cleanup(child, timeout):
            self.children.append(child)
            result = cleanup(child, timeout)
            self.cleanup_results.append(result)
            return result

        patch = mock.patch.object(P.bridge, "_cleanup", side_effect=observed_cleanup)
        patch.start()
        self.addCleanup(patch.stop)
        self.addCleanup(self.assert_reaped)

    def assert_reaped(self):
        for child in self.children:
            self.assertIsNotNone(child.poll())
            self.assertTrue(child.stdin.closed and child.stdout.closed)
        for result in self.cleanup_results:
            self.assertEqual(result, {"child_reaped": True, "cleanup_failed": False, "cleanup_overrun": False})

    def probe(self, mode="valid", **configuration):
        self.config.write_text(json.dumps({"mode": mode, "scope": SCOPE, **configuration}))
        return P.probe_scope(self.transport, writer_fence=self.held,
                             expected_binding=self.binding, limits=self.limits)

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def test_valid_scope_and_only_read_only_protocol_calls(self):
        self.assertEqual(self.probe(), SCOPE)
        calls = self.calls()
        self.assertEqual([c["method"] for c in calls], ["initialize", "notifications/initialized", "tools/call"])
        self.assertEqual(calls[-1]["params"], {"name": "operation_scope", "arguments": {}})
        child = json.loads((self.root / "child.json").read_text())
        self.assertEqual(child["binding"], self.binding)
        self.assertEqual(child["cwd"], str(self.root))
        self.assertEqual(child["marker"], "expected")
        self.assertIs(self.held.verify(self.binding), True)

    def test_anonymous_scope_preserves_omitted_id(self):
        scope = copy.deepcopy(SCOPE)
        del scope["principal"]["id"]
        self.assertEqual(self.probe(scope=scope), scope)

    def test_delayed_initialize_and_scope_have_one_deadline_and_reap(self):
        self.limits = P.ProbeLimits(deadline_seconds=0.25, terminate_timeout_seconds=0.05)
        for mode in ("delay_initialize", "delay_scope", "delay_both"):
            with self.subTest(mode=mode):
                start = time.monotonic()
                with self.assertRaisesRegex(P.ProbeError, "deadline"):
                    self.probe(mode)
                self.assertLess(time.monotonic() - start, 2)

    def test_malformed_truncated_oversized_unexpected_and_error_replies(self):
        for mode in ("malformed", "truncated", "oversized", "duplicate_json", "jsonrpc_error",
                     "initialize_error", "server_request", "duplicate_response"):
            with self.subTest(mode=mode):
                with self.assertRaises(P.ProbeError) as raised:
                    self.probe(mode)
                self.assertNotIn("PRIVATE", str(raised.exception))

    def test_cumulative_output_budget(self):
        self.limits = P.ProbeLimits(deadline_seconds=2, max_frame_bytes=1024,
                                    max_output_bytes=1024, terminate_timeout_seconds=0.05)
        with self.assertRaisesRegex(P.ProbeError, "output_limit"):
            self.probe("output_limit")

    def test_stderr_is_discarded_and_ignored_sigterm_is_escalated(self):
        self.assertEqual(self.probe("stderr"), SCOPE)
        self.assertEqual(self.probe("ignore_term"), SCOPE)
        self.assertEqual(self.children[-1].returncode, -signal.SIGKILL)

    def test_initialize_requires_supported_protocol_and_tool_capability(self):
        for patch in ({"protocolVersion": "2099-01-01"}, {"capabilities": {}},
                      {"serverInfo": {"name": "", "version": "1"}}):
            with self.subTest(patch=patch):
                with self.assertRaises(P.ProbeError):
                    self.probe(initialize_patch=patch)

    def test_scope_capability_version_and_all_scope_fields_are_strict(self):
        base = {"version": 1, "kind": "scope", "capability": P.CAPABILITY, "scope": SCOPE}
        payloads = [{**base, "capability": "unknown"}, {**base, "version": 2},
                    {**base, "version": True}, {**base, "kind": "absent"},
                    {**base, "unexpected": True}]
        for change in ({"version": True}, {"version": 2}, {"storeID": "bad"},
                       {"principal": {**SCOPE["principal"], "kind": "anonymous"}},
                       {"principal": {**SCOPE["principal"], "groupIds": ["bad"]}},
                       {"principal": {**SCOPE["principal"], "scopes": [False]}},
                       {"principal": {**SCOPE["principal"], "extra": "bad"}}):
            payloads.append({**base, "scope": {**SCOPE, **change}})
        for payload in payloads:
            with self.subTest(payload=payload):
                with self.assertRaises(P.ProbeError):
                    self.probe(payload=payload)

    def test_text_structured_disagreement_and_error_envelope_are_rejected(self):
        changes = [dict(text='{"engram_operation":{}}'), dict(result_patch={"isError": True}),
                   dict(result_patch={"content": []}), dict(result_patch={"structuredContent": None}),
                   dict(response_id=True), dict(response_id=3), dict(response_id="2"),
                   dict(payload={"version":1,"kind":"error","code":"unsupported"},
                        result_patch={"isError": True})]
        for change in changes:
            with self.subTest(change=change):
                with self.assertRaises(P.ProbeError):
                    self.probe(**change)

    def test_wrong_binding_closed_fence_and_reserved_environment_prevent_launch(self):
        changed = copy.deepcopy(self.binding)
        changed["owner_id"] = changed["epoch_id"]
        with self.assertRaises(P.ProbeError):
            P.probe_scope(self.transport, writer_fence=self.held, expected_binding=changed)
        self.transport["env"]["ENGRAM_WRITER_FENCE_FD"] = "77"
        with self.assertRaises(P.ProbeError):
            self.probe()
        del self.transport["env"]["ENGRAM_WRITER_FENCE_FD"]
        self.held.close()
        with self.assertRaises(P.ProbeError):
            self.probe()
        self.assertEqual(self.children, [])

    def test_child_retains_inherited_shared_lock_until_cleanup_when_parent_copy_closes(self):
        original = subprocess.Popen
        real_cleanup = P.bridge._cleanup
        exclusive = os.open(self.root / F.LOCK_NAME, os.O_RDWR)
        self.addCleanup(os.close, exclusive)

        def launch(*args, **kwargs):
            child = original(*args, **kwargs)
            self.held.close()
            return child

        def verify_retention(child, timeout):
            with self.assertRaises(BlockingIOError):
                fcntl.flock(exclusive, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = real_cleanup(child, timeout)
            fcntl.flock(exclusive, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(exclusive, fcntl.LOCK_UN)
            return result

        with mock.patch.object(P.subprocess, "Popen", side_effect=launch), \
             mock.patch.object(P.bridge, "_cleanup", side_effect=verify_retention):
            with self.assertRaises(P.ProbeError):
                self.probe()

    def test_invalid_limits_and_exclusive_fence_never_launch(self):
        for kwargs in ({"deadline_seconds": 0}, {"deadline_seconds": float("inf")},
                       {"deadline_seconds": 31}, {"max_frame_bytes": True},
                       {"max_output_bytes": 1}, {"terminate_timeout_seconds": 2}):
            with self.assertRaises(P.ProbeError):
                P.ProbeLimits(**kwargs)
        self.held.close()
        with F.revoke(self.root, self.binding, validate=lambda *_: True) as exclusive:
            with self.assertRaisesRegex(P.ProbeError, "writer_unfenced"):
                P.probe_scope(self.transport, writer_fence=exclusive, expected_binding=self.binding)
        self.assertEqual(self.children, [])

    def test_launch_failure_preserves_caller_fence(self):
        self.transport["command"] = str(self.root / "missing-executable")
        with self.assertRaisesRegex(P.ProbeError, "transport_or_protocol_failure"):
            self.probe()
        self.assertIs(self.held.verify(self.binding), True)
        self.assertEqual(self.children, [])

    def test_interrupt_after_launch_reaps_before_restoring_signal_handlers(self):
        original = subprocess.Popen
        prior = signal.getsignal(signal.SIGTERM)

        def interrupted_launch(*args, **kwargs):
            child = original(*args, **kwargs)
            os.kill(os.getpid(), signal.SIGTERM)
            return child

        with mock.patch.object(P.subprocess, "Popen", side_effect=interrupted_launch):
            with self.assertRaisesRegex(P.ProbeError, "interrupted"):
                self.probe()
        self.assertEqual(signal.getsignal(signal.SIGTERM), prior)
        self.assertEqual(len(self.children), 1)
        self.assertIs(self.held.verify(self.binding), True)


if __name__ == "__main__":
    unittest.main()
