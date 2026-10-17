"""The real proxy entry point activates and retains the sealed writer context."""
import importlib
import unittest
from unittest import mock

import test_execution_context as fixtures

C, J, F = fixtures.C, fixtures.J, fixtures.F

P = importlib.import_module("codex_learner.memory_proxy")
B = importlib.import_module("codex_learner.stdio_bridge")


class ProxyExecutionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.ExecutionContextTests(methodName="runTest")
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.setUp()
        f = self.fixture
        self.context = f.seal()
        self.config = {
            "transport": self.context.transport,
            "audit_path": str(f.run_dir / "mcp-audit.jsonl"),
            "provenance": "codex-session:" + f.request["session_id"],
            "allowed_tools": sorted(C.memory_config.allowed_tools(f.memory, P.ALLOWED_TOOLS)),
            "max_tool_calls": 12, "max_writes": 5,
            "execution": {**{name: str(getattr(f.paths, name)) for name in f.paths.__dataclass_fields__},
                          "manifest_sha256": self.context.manifest_sha256}}

    def test_run_activates_durable_policy_and_retains_shared_fence_through_cleanup(self):
        fences = []
        def relay(transport, client, server, **kwargs):
            fence = kwargs["writer_fence"]
            fences.append(fence)
            self.assertEqual(fence.mode, "shared")
            self.assertTrue(fence.verify(self.fixture.manifest()["fencing"]))
            self.assertIsNotNone(client.__self__.operations)
            self.assertEqual(transport, self.context.transport)
            return 0
        def failed(policy):
            self.assertTrue(fences[0].verify(self.fixture.manifest()["fencing"]))
        with mock.patch.object(B, "run_relay", side_effect=relay), \
             mock.patch.object(P.Policy, "fail_pending", autospec=True, side_effect=failed) as finish:
            self.assertEqual(P.run(self.config), 0)
        finish.assert_called_once()
        with self.assertRaisesRegex(ValueError, "closed"):
            fences[0].verify(self.fixture.manifest()["fencing"])
        # Closing the proxy's own copy must not release the runner's copy.
        self.assertTrue(self.fixture.fence.verify(self.fixture.manifest()["fencing"]))

    def test_policy_route_audit_and_provenance_mismatch_never_launch(self):
        alternatives = [
            {"transport": {**self.config["transport"], "env": {"UNEXPECTED": "value"}}},
            {"audit_path": str(self.fixture.run_dir / "other.jsonl")},
            {"provenance": "codex-session:other"},
            {"allowed_tools": ["operation_apply"]},
            {"max_tool_calls": 13},
            {"max_writes": 6},
            {"execution": {**self.config["execution"], "manifest_sha256": "0" * 64}},
            {"execution": {**self.config["execution"], "fd": 1}},
        ]
        with mock.patch.object(B, "run_relay") as relay:
            for change in alternatives:
                with self.subTest(change=list(change)):
                    with self.assertRaises((P.ProxyError, ValueError)):
                        P.run({**self.config, **change})
            relay.assert_not_called()

    def test_missing_marker_never_falls_back_to_legacy_writes(self):
        f = self.fixture
        record = {**f.record, "processing": None}
        record.pop("processing_execution")
        f.record_path.write_bytes(J.encode(record))
        with mock.patch.object(B, "run_relay") as relay:
            with self.assertRaises(ValueError):
                P.run(self.config)
            relay.assert_not_called()

    def test_revoked_generation_cannot_launch_a_late_proxy(self):
        f = self.fixture
        binding = f.fence.binding()
        f.fence.close()
        with F.revoke(f.run_dir, binding, validate=lambda *args: True):
            pass
        with mock.patch.object(B, "run_relay") as relay:
            with self.assertRaisesRegex(ValueError, "revoked"):
                P.run(self.config)
            relay.assert_not_called()

    def test_relay_failure_closes_proxy_fence_after_pending_failure(self):
        fences = []
        def relay(*args, **kwargs):
            fences.append(kwargs["writer_fence"])
            raise RuntimeError("fixture failure")
        with mock.patch.object(B, "run_relay", side_effect=relay), \
             mock.patch.object(P.Policy, "fail_pending", autospec=True) as finish:
            with self.assertRaises(RuntimeError):
                P.run(self.config)
        finish.assert_called_once()
        with self.assertRaisesRegex(ValueError, "closed"):
            fences[0].verify(self.fixture.manifest()["fencing"])


if __name__ == "__main__":
    unittest.main()
