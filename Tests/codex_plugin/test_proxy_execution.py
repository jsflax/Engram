"""The real proxy entry point activates and retains the sealed writer context."""
import importlib
import json
import os
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
        self.assertFalse((self.fixture.run_dir / P.STARTUP_FAILURE_FILE).exists())

    def break_marker(self):
        record = {**self.fixture.record, "processing": None}
        record.pop("processing_execution")
        self.fixture.record_path.write_bytes(J.encode(record))

    def failed_start(self):
        with mock.patch.object(B, "run_relay") as relay:
            with self.assertRaises(ValueError) as failure:
                P.run(self.config)
            relay.assert_not_called()
        return failure.exception

    def test_pre_relay_context_failure_retains_exact_code_without_affecting_settlement(self):
        settlement = importlib.import_module("codex_learner.settlement")
        self.break_marker()
        before = settlement._snapshot(self.fixture.run_dir)
        error = self.failed_start()
        self.assertEqual(str(error), "execution_context_processing_changed")
        path = self.fixture.run_dir / P.STARTUP_FAILURE_FILE
        value = json.loads(path.read_bytes())
        self.assertEqual(value, {"version": 1, "kind": "gateway_startup_failure",
            "run_id": self.fixture.run_dir.name, "session_id": fixtures.SID,
            "manifest_sha256": self.context.manifest_sha256,
            "stage": "execution_context", "reason": "execution_context_processing_changed"})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(settlement._snapshot(self.fixture.run_dir), before)
        self.assertFalse((self.fixture.run_dir / "mcp-audit.jsonl").exists())
        self.assertEqual(P.read_startup_failure(self.fixture.run_dir, self.context.manifest_sha256),
                         {"stage": value["stage"], "reason": value["reason"]})

    def test_actual_backend_drift_is_reported_without_private_value(self):
        self.fixture.config_path.write_text(self.fixture.config_text +
            '\n[mcp_servers.memory.env]\nPRIVATE_SECRET = "must-never-appear"\n')
        self.assertEqual(str(self.failed_start()), "execution_context_backend_changed")
        raw = (self.fixture.run_dir / P.STARTUP_FAILURE_FILE).read_bytes()
        self.assertNotIn(b"must-never-appear", raw)
        self.assertNotIn(b"PRIVATE_SECRET", raw)
        self.assertEqual(json.loads(raw)["reason"], "execution_context_backend_changed")

    def test_unknown_exception_and_diagnostic_io_failure_preserve_original_error(self):
        secret = ValueError("secret argv /private/prompt PATH=private")
        with mock.patch.object(C, "load_execution", side_effect=secret), mock.patch.object(B, "run_relay") as relay:
            with self.assertRaises(ValueError) as failure:
                P.run(self.config)
            self.assertIs(failure.exception, secret)
            relay.assert_not_called()
        receipt = self.fixture.run_dir / P.STARTUP_FAILURE_FILE
        original = receipt.read_bytes()
        self.assertEqual(json.loads(original)["reason"], "validation_failed")
        self.assertNotIn(b"secret", original)
        self.break_marker()
        self.assertEqual(str(self.failed_start()), "execution_context_processing_changed")
        self.assertEqual(receipt.read_bytes(), original)  # Never overwrite even a prior diagnostic.

    def test_diagnostic_destination_never_follows_symlink_or_hardlink(self):
        self.break_marker()
        external = self.fixture.base / "private-unrelated"
        external.write_bytes(b"unchanged"); external.chmod(0o600)
        target = self.fixture.run_dir / P.STARTUP_FAILURE_FILE
        for hardlink in (False, True):
            with self.subTest(hardlink=hardlink):
                if hardlink:
                    os.link(external, target)
                else:
                    target.symlink_to(external)
                self.assertEqual(str(self.failed_start()), "execution_context_processing_changed")
                self.assertEqual(external.read_bytes(), b"unchanged")
                self.assertIsNone(P.read_startup_failure(self.fixture.run_dir, self.context.manifest_sha256))
                target.unlink()

    def test_unsafe_or_mismatched_binding_never_creates_diagnostic(self):
        target = self.fixture.run_dir / P.STARTUP_FAILURE_FILE
        with mock.patch.object(B, "run_relay") as relay:
            self.fixture.run_dir.chmod(0o755)
            with self.assertRaises(ValueError): P.run(self.config)
            self.fixture.run_dir.chmod(0o700)
            manifest_path = self.fixture.run_dir / "execution-manifest.json"
            manifest_path.chmod(0o644)
            with self.assertRaises(ValueError): P.run(self.config)
            manifest_path.chmod(0o600)
            changed = {**self.config, "execution": {**self.config["execution"], "manifest_sha256": "0" * 64}}
            with self.assertRaises(P.ProxyError): P.run(changed)
            alias = self.fixture.base / "run-alias"
            alias.symlink_to(self.fixture.run_dir, target_is_directory=True)
            changed = {**self.config, "execution": {**self.config["execution"], "run_dir": str(alias)}}
            with self.assertRaises(ValueError): P.run(changed)
            relay.assert_not_called()
        self.assertFalse(target.exists())

    def test_manifest_drift_during_failure_does_not_write_stale_diagnostic(self):
        path = self.fixture.run_dir / "execution-manifest.json"
        original = path.read_bytes()
        def changed(*args, **kwargs):
            value = json.loads(original); value["host"] = "changed-host"
            path.write_bytes(J.encode(value))
            raise ValueError("execution_context_backend_changed")
        with mock.patch.object(C, "load_execution", side_effect=changed):
            self.assertEqual(str(self.failed_start()), "execution_context_backend_changed")
        self.assertFalse((self.fixture.run_dir / P.STARTUP_FAILURE_FILE).exists())

    def test_replaced_run_directory_is_not_a_diagnostic_destination(self):
        diagnostic = P._StartupDiagnostic()
        diagnostic.bind(self.fixture.paths, self.fixture.manifest(), self.context.manifest_sha256, J)
        moved = self.fixture.run_dir.with_name("original-run")
        self.fixture.run_dir.rename(moved)
        self.fixture.run_dir.mkdir(mode=0o700)
        path = self.fixture.run_dir / "execution-manifest.json"
        path.write_bytes((moved / path.name).read_bytes()); path.chmod(0o600)
        diagnostic.record(ValueError("execution_context_backend_changed"))
        self.assertFalse((moved / P.STARTUP_FAILURE_FILE).exists())
        self.assertFalse((self.fixture.run_dir / P.STARTUP_FAILURE_FILE).exists())

    def test_audit_open_failure_is_typed_and_never_starts_native(self):
        with mock.patch.object(P, "Audit", side_effect=PermissionError("private-path-secret")), \
             mock.patch.object(B, "run_relay") as relay:
            with self.assertRaises(PermissionError): P.run(self.config)
            relay.assert_not_called()
        self.assertEqual(P.read_startup_failure(self.fixture.run_dir, self.context.manifest_sha256),
                         {"stage": "audit_open", "reason": "io_error"})

    def test_reader_rejects_wrong_binding_extra_fields_and_untrusted_codes(self):
        self.break_marker(); self.failed_start()
        path = self.fixture.run_dir / P.STARTUP_FAILURE_FILE
        value = json.loads(path.read_bytes())
        for change in ({"manifest_sha256": "0" * 64}, {"run_id": "other"}, {"session_id": "other"},
                       {"extra": "private"}, {"reason": "execution_context_private-secret"},
                       {"stage": []}, {"version": True}):
            with self.subTest(fields=list(change)):
                path.write_bytes(J.encode({**value, **change}))
                self.assertIsNone(P.read_startup_failure(self.fixture.run_dir, self.context.manifest_sha256))

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
