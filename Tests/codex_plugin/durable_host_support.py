"""Synthetic process owner over the real migration/context/receipt machinery.

This fixture never runs the native header bytes or a provider. The caller's
process/network/store guards remain installed. Only the stable-volume oracle
and read-only scope reply are substituted.
"""
import copy
import importlib
import json
import os
from unittest import mock


class DurableHost:
    def __init__(self, test, modules):
        self.test, self.modules = test, modules
        self.runner = modules.RUNNER
        prefix = modules.PACKAGE
        self.migration = importlib.import_module(prefix + ".migration")
        self.publications = importlib.import_module(prefix + ".runner_publication")
        self.journal = importlib.import_module(prefix + ".execution_manifest")
        self.gateway = importlib.import_module(prefix + ".operation_gateway")
        self.settlement = importlib.import_module(prefix + ".settlement")
        self.scope = {"version": 1, "storeID": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                      "principal": {"kind": "agent", "groupIds": [], "scopes": []}}
        patch = mock.patch.object(self.migration.file_identity, "capture_fd", side_effect=lambda fd: {
            "scheme": self.migration.file_identity.SCHEME,
            "volume_uuid": "11111111-2222-4333-8444-555555555555", "inode": os.fstat(fd).st_ino})
        patch.start()
        test.addCleanup(patch.stop)
        patch = mock.patch.object(self.publications.operation_probe, "probe_scope", side_effect=self.probe)
        patch.start()
        test.addCleanup(patch.stop)
        self.runtime = test.base / "fixture-native-memory"
        self.runtime.write_bytes(b"\xcf\xfa\xed\xfe" + b"not-executed-native-fixture" * 3)
        self.runtime.chmod(0o700)
        config = test.home / "config.toml"
        config.write_text('[mcp_servers.memory]\ncommand = ' + json.dumps(str(self.runtime))
                          + '\nargs = []\ndefault_tools_approval_mode = "approve"\n')
        config.chmod(0o600)

    def probe(self, transport, *, writer_fence, expected_binding):
        self.test.assertIs(writer_fence.verify(expected_binding), True)
        self.test.assertEqual(transport["command"], str(self.runtime))
        return copy.deepcopy(self.scope)

    def migrate(self):
        test, migration = self.test, self.migration
        if test.policy["mode"] == migration.MODE_V2:
            return
        for name in ("enrollments", "sessions", "admissions", "pending"):
            self.modules.private_directory(test.root / name)
        for path in (test.root / "worker.lock", test.root / "enqueue.lock", test.root.parent / "learner-provider.lock"):
            if not path.exists():
                path.touch(mode=0o600)
        ids = sorted(path.stem for path in (test.root / "enrollments").glob("*.json"))
        before = {}
        for sid in ids:
            before[sid] = {name: json.loads(path.read_bytes()) if path.exists() else None
                           for name, path in migration._paths(test.root, sid).items()}
        plan = migration.prepare(test.root, test.routes, ids, authorize_current_volume_adoption=True)
        digest = migration.digest(migration.encode(plan))
        test.assertEqual(migration.apply(test.root, plan, digest)["status"], "migration_complete_held")
        release = migration.prepare_release(test.root, plan, digest, ids)
        test.assertFalse(migration.release(test.root, plan, digest, release,
                                          migration.digest(migration.encode(release)))["learner_started"])
        for sid, original in before.items():
            for name, path in migration._paths(test.root, sid).items():
                previous = original[name]
                current = json.loads(path.read_bytes()) if path.exists() else None
                if previous is None:
                    test.assertIsNone(current)
                    continue
                if name == "enrollments":
                    test.assertEqual(current["frontier_offset"], previous["frontier_offset"])
                elif name in {"sessions", "pending"}:
                    omit = {"device", "inode", "identity", "admission"}
                    test.assertEqual({k: v for k, v in current.items() if k not in omit},
                                     {k: v for k, v in previous.items() if k not in omit})
                else:
                    for key in ("last_event", "processing"):
                        test.assertEqual(current[key], previous[key])
        test.policy = json.loads((test.root / "admission.json").read_bytes())

    def provider(self, *, rows=None, success=True, started=True, typed_success=False, missing_audit=False):
        execution = self.runner._EXECUTION.get()
        test, journal, settlement = self.test, self.journal, self.settlement
        test.assertIsNotNone(execution)
        run = execution.paths.run_dir
        manifest, digest = journal.read_manifest(run)
        settlement.record_provider_dispatch(run, digest,
            lambda value, phase: execution.context.validate_inputs(value, "before_forward"))
        if not started:
            settlement.persist_observation(run, {"started": False, "terminated": True, "returncode": None,
                "turn_completed": False, "provider_error": False, "unexpected_tool": False,
                "tool_errors": 0, "reason": "popen_failed"})
            return
        if rows is None and not missing_audit:
            rows = [{"event": "relay_started"}, {"event": "tool_call", "id": 1, "tool": "recall"},
                    {"event": "tool_result", "id": 1, "tool": "recall", "ok": True,
                     "forwarded": True, "memory_ids": []}]
        rows = copy.deepcopy(rows)
        if rows is not None:
            gateway = self.gateway.OperationGateway(run, manifest_sha256=digest, writer_fence=execution.fence,
                                                    validate_inputs=execution.context.validate_inputs)
            calls = {row["id"]: row["tool"] for row in rows if row["event"] == "tool_call"}
            for row in rows:
                if (typed_success and row["event"] == "tool_result" and row.get("ok") is True
                        and row.get("memory_ids") and calls.get(row["id"]) in {"remember", "update", "connect"}):
                    test.assertEqual(row["tool"], "remember")
                    operation, _ = gateway.prepare(row["id"], "remember", {
                        "content": "Private typed fixture intent", "source": "codex-session:" + manifest["session_id"],
                        "is_private": True})
                    receipt = {"version": 1, "operationID": operation, "scope": self.scope,
                               "payloadDigest": "d" * 64, "mutation": "remember", "outcome": "applied",
                               "memoryIDs": row["memory_ids"], "edgeIDs": [], "committedAt": 800000000.25}
                    journal.record_response(run, operation, {"kind": "committed", "receipt": receipt},
                                            verify_fence=execution.fence.verify)
                    row.update(operation_version=1, operation_id=operation, operation_outcome="applied",
                               operation_payload_digest="d" * 64)
            if not rows or rows[-1].get("event") != "relay_finished":
                rows.append({"event": "relay_finished", "child_reaped": True, "cleanup_overrun": False})
            settlement.durable._new(run / "mcp-audit.jsonl", b"".join(journal.encode(row) + b"\n" for row in rows))
        settlement.durable._new(run / "result.json", journal.encode({
            "outcome": "no_new_memories", "summary": "Private synthetic provider result", "memory_ids": []}))
        settlement.persist_observation(run, {"started": True, "terminated": True, "returncode": 0 if success else 1,
            "turn_completed": success, "provider_error": not success, "unexpected_tool": False,
            "tool_errors": sum(row.get("event") == "tool_result" and row.get("ok") is False for row in (rows or [])),
            "reason": None if success else "synthetic_failure"})
