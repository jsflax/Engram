"""Trusted relay descriptor handoff, synthetic RPC, and optional native fixture."""
import base64
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
B = importlib.import_module("codex_learner.stdio_bridge")
F = importlib.import_module("codex_learner.writer_fence")
NATIVE = os.environ.get("ENGRAM_NATIVE_FENCE_FIXTURE")


class FencedRelayTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fenced-relay-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.binding = F.create(self.root, generation_id="11111111-2222-4333-8444-555555555555",
                                owner_id="21111111-2222-4333-8444-555555555555")
        self.transport = {"command": sys.executable, "args": ["-B", "-c", "pass"]}

    def test_launch_context_uses_only_verified_shared_handle_and_copies_binding(self):
        with F.acquire_shared(self.root, self.binding) as held:
            argv, env, cwd, fds = B._fenced_transport(self.transport, held)
            self.assertEqual(argv[0], sys.executable)
            self.assertIsNone(cwd)
            self.assertEqual(fds, held.pass_fds())
            self.assertEqual(env[B.FENCE_DESCRIPTOR_ENV], str(fds[0]))
            self.assertEqual(base64.b64decode(env[B.FENCE_BINDING_ENV]), F.durable.encode(self.binding))
            changed = held.binding()
            changed["lock_identity"]["inode"] += 1
            self.assertIs(held.verify(self.binding), True)

    def test_transport_and_inherited_environment_cannot_forge_native_fence(self):
        forged = {B.FENCE_DESCRIPTOR_ENV: "42", B.FENCE_BINDING_ENV: "forged"}
        with mock.patch.dict(os.environ, forged):
            _, env, _, fds = B._fenced_transport({**self.transport, "pass_fds": [42], "writer_fence": forged})
            self.assertEqual(fds, ())
            self.assertFalse(set(forged) & set(env))
        with F.acquire_shared(self.root, self.binding) as held:
            for key in forged:
                for config in ({"env": {key: forged[key]}}, {"env_vars": [key]}):
                    for fence in (None, held):
                        with self.subTest(key=key, config=config, fenced=fence is not None):
                            with self.assertRaisesRegex(B.RelayError, "reserved_fence_environment"):
                                B._fenced_transport({**self.transport, **config}, fence)

    def test_nonshared_closed_and_changed_handles_never_launch(self):
        for fake in (4, {"fd": 4}, object()):
            with self.assertRaisesRegex(B.RelayError, "invalid_writer_fence"):
                B._fenced_transport(self.transport, fake)
        held = F.acquire_shared(self.root, self.binding)
        held.close()
        with mock.patch.object(B.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(ValueError, "closed"):
                B.run_relay(self.transport, lambda value: (value, None), lambda value: (value, None), writer_fence=held)
        launch.assert_not_called()
        with F.revoke(self.root, self.binding, validate=lambda _binding, _phase: True) as recovery:
            with self.assertRaisesRegex(B.RelayError, "invalid_writer_fence"):
                B._fenced_transport(self.transport, recovery)

    def relay(self, transport, fence=None):
        in_read, in_write = os.pipe()
        out_read, out_write = os.pipe()
        request = {"jsonrpc": "2.0", "id": 1, "method": "fixture"}
        os.write(in_write, (json.dumps(request) + "\n").encode())
        os.close(in_write)
        events = []
        try:
            with os.fdopen(in_read, "rb") as source, os.fdopen(out_write, "wb", buffering=0) as target:
                code = B.run_relay(transport, lambda value: (value, None), lambda value: (value, None),
                                   client_input=source, client_output=target, writer_fence=fence,
                                   audit=events.append, limits=B.RelayLimits(shutdown_timeout_sec=2))
            with os.fdopen(out_read, "rb") as stream:
                output = stream.read()
        except BaseException:
            for fd in (in_read, out_read, out_write):
                try: os.close(fd)
                except OSError: pass
            raise
        return code, json.loads(output), events

    def test_actual_child_receives_shared_descriptor_and_relay_leaves_caller_copy_open(self):
        code = r'''
import base64,json,os,sys
binding=json.loads(base64.b64decode(os.environ['ENGRAM_WRITER_FENCE_BINDING_B64']))
fd=int(os.environ['ENGRAM_WRITER_FENCE_FD']);assert os.fstat(fd).st_ino==binding['lock_identity']['inode']
for line in sys.stdin:
 request=json.loads(line);print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':{'fenced':True}}),flush=True)
'''
        with F.acquire_shared(self.root, self.binding) as held:
            result, output, events = self.relay({"command": sys.executable, "args": ["-B", "-c", code]}, held)
            self.assertEqual(result, 0)
            self.assertTrue(output["result"]["fenced"])
            self.assertIs(held.verify(self.binding), True)
            self.assertTrue(events[-1]["child_reaped"])
        with F.revoke(self.root, self.binding, validate=lambda _binding, _phase: True):
            pass

    def test_unfenced_generic_relay_still_handles_rpc_without_fence_environment(self):
        code = r'''
import json,os,sys
assert 'ENGRAM_WRITER_FENCE_FD' not in os.environ and 'ENGRAM_WRITER_FENCE_BINDING_B64' not in os.environ
for line in sys.stdin:
 request=json.loads(line);print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':{'ordinary':True}}),flush=True)
'''
        result, output, events = self.relay({"command": sys.executable, "args": ["-B", "-c", code]})
        self.assertEqual(result, 0)
        self.assertTrue(output["result"]["ordinary"])
        self.assertTrue(events[-1]["child_reaped"])

    @unittest.skipUnless(NATIVE, "Set ENGRAM_NATIVE_FENCE_FIXTURE to the compiled external Swift candidate")
    def test_real_relay_proxy_sigkill_preserves_native_child_shared_fence(self):
        # The Swift fixture intentionally retains its fence briefly after stdin
        # closes, representing an in-flight native write after relay death.
        code = r'''
import json,pathlib,sys
sys.path.insert(0,sys.argv[1]);from codex_learner import writer_fence as F,stdio_bridge as B
root=pathlib.Path(sys.argv[2]);binding=json.loads(sys.argv[3])
with F.acquire_shared(root,binding) as held:
 B.run_relay({'command':sys.argv[4],'args':['--relay-fixture']},lambda value:(value,None),lambda value:(value,None),writer_fence=held)
'''
        proxy = subprocess.Popen([sys.executable, "-B", "-c", code, str(PLUGIN_ROOT / "scripts"),
                                  str(self.root), json.dumps(self.binding), NATIVE],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 start_new_session=True)
        try:
            ready = json.loads(proxy.stdout.readline())
            self.assertEqual(ready["method"], "fixture/ready")
            proxy.kill()
            self.assertEqual(proxy.wait(timeout=5), -signal.SIGKILL)
            with self.assertRaisesRegex(ValueError, "busy"):
                F.revoke(self.root, self.binding, timeout_seconds=.05, validate=lambda _binding, _phase: True)
            with F.revoke(self.root, self.binding, timeout_seconds=3, validate=lambda _binding, _phase: True):
                pass
        finally:
            if proxy.poll() is None:
                proxy.kill()
            proxy.wait(timeout=5)
            for stream in (proxy.stdin, proxy.stdout, proxy.stderr):
                stream.close()


if __name__ == "__main__":
    unittest.main()
