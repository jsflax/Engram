"""Bounded private fixture reads only; never provider/native/network/store calls."""
import copy
import importlib
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from suite_support import PLUGIN_ROOT

sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
C = importlib.import_module("codex_learner.execution_context")
J, A, H, T, F = (C.journal, C.admission, C.host_admission, C.transcript,
                 importlib.import_module("codex_learner.writer_fence"))
SID = "019b7a00-0000-7123-8000-000000000011"
VOLUME = "11111111-2222-4333-8444-555555555555"
ACTIVATION = "21111111-2222-4333-8444-555555555555"
OWNER = "31111111-2222-4333-8444-555555555555"


def write_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_bytes(J.encode(value) + b"\n")
    path.chmod(0o600)


class ExecutionContextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="execution-context-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.base.chmod(0o700)
        for obj, name in ((subprocess, "Popen"), (subprocess, "run"),
                          (socket, "socket"), (sqlite3, "connect")):
            patch = mock.patch.object(obj, name, side_effect=AssertionError("external effect forbidden"))
            patch.start()
            self.addCleanup(patch.stop)
        identity = mock.patch.object(C.file_identity, "capture_fd", side_effect=lambda fd: {
            "scheme": C.file_identity.SCHEME, "volume_uuid": VOLUME, "inode": os.fstat(fd).st_ino})
        identity.start()
        self.addCleanup(identity.stop)
        self.root, self.project, self.sessions, self.plugin = [self.base / name for name in
                                                             ("learner", "project", "sessions", "plugin")]
        for directory in (self.root, self.project, self.sessions, self.plugin):
            directory.mkdir(mode=0o700)
        self.run_dir = self.root / "runs" / "fixture-run"
        self.run_dir.mkdir(parents=True, mode=0o700)
        (self.run_dir / "workspace").mkdir(mode=0o700)
        self.path = self.sessions / "2026/01/02" / ("rollout-2026-01-02T00-00-00-" + SID + ".jsonl")
        self.path.parent.mkdir(mode=0o700, parents=True)
        write_json(self.path, {"type": "session_meta", "payload": {
            "id": SID, "timestamp": "2026-01-02T00:00:00Z", "cwd": str(self.project),
            "source": "vscode", "cli_version": "fixture", "history_mode": "paginated"}})
        self.append("Older private context before the enrolled frontier.")
        self.policy = {"schema_version": 2, "mode": H.MODE_V2, "enabled": True,
                       "activation_id": ACTIVATION, "cutoff": "2026-01-01T00:00:00Z",
                       "state_dir": str(self.root),
                       "sessions_dir": A._directory_binding(self.sessions, stable_identity=True)}
        write_json(self.root / "admission.json", self.policy)
        payload = {"session_id": SID, "transcript_path": str(self.path), "cwd": str(self.project)}
        origin = H._origin(self.policy, payload)
        entry = {**origin, **A._frontier(origin), "activation_id": ACTIVATION,
                 "captured_at": "2026-01-03T00:00:00Z"}
        self.enrollment = self.root / "enrollments" / (SID + ".json")
        write_json(self.enrollment, entry)
        self.frontier = entry["frontier_offset"]
        self.request = {**payload, "hook_session_id": SID, "hook_cwd": str(self.project),
                        "event": "Stop", "turn_id": "fixture-turn", "request_id": "fixture-request",
                        "identity": entry["identity"]}
        self.request["admission"] = A.check(self.root, self.request)
        self.state = {"session_id": SID, "transcript_path": str(self.path), "identity": entry["identity"],
                      "offset": self.frontier, "recent_messages": [], "current_turn_id": None,
                      "admission": self.request["admission"], "status": "enrolled_frontier"}
        self.state_path = self.root / "sessions" / (SID + ".json")
        self.record_path = self.root / "admissions" / (SID + ".json")
        write_json(self.state_path, self.state)
        self.record = {"binding": self.request["admission"], "state_sha256": C.durable.object_digest(self.state),
                       "last_event": "a" * 64, "processing": None}
        write_json(self.record_path, self.record)
        self.append("PRIVATE newly admitted e\u0301 fact, with exact original bytes.")
        self.excerpt = T.read_excerpt(self.path, self.frontier, max_chars=2000,
                                      max_scan_bytes=4096, stable_identity=True)
        self.next_parser = {"offset": self.excerpt.next_offset,
                            "recent_messages": self.excerpt.recent_messages,
                            "current_turn_id": self.excerpt.current_turn_id}
        self.runtime = self.plugin / "memory"
        # Header-bearing synthetic bytes are never executed. These tests bind
        # whole-file integrity and route rules, not native file format validity.
        self.runtime.write_bytes(b"\xcf\xfa\xed\xfe" + b"native-fixture" * 8)
        self.runtime.chmod(0o700)
        self.config_path = self.base / "config.toml"
        self.config_text = ("[mcp_servers.memory]\ncommand = " + json.dumps(str(self.runtime))
                            + "\ncwd = " + json.dumps(str(self.plugin))
                            + '\nargs = []\ndefault_tools_approval_mode = "approve"\n')
        self.config_path.write_text(self.config_text)
        self.config_path.chmod(0o600)
        write_json(self.root / "settings.json", {"max_chars": 2000, "max_scan_bytes": 4096})
        self.memory = C.memory_config.resolve(self.config_path, self.plugin)[1]
        self.transport = C.memory_config.transport(self.memory)
        self.binding = F.create(self.run_dir, generation_id=ACTIVATION, owner_id=OWNER)
        self.fence = F.acquire_shared(self.run_dir, self.binding)
        self.addCleanup(self.fence.close)
        self.scope = {"version": 1, "storeID": VOLUME,
                      "principal": {"kind": "agent", "groupIds": [], "scopes": []}}
        self.paths = C.ContextPaths(self.root, self.run_dir, self.config_path, self.plugin)

    def append(self, text):
        with self.path.open("ab") as stream:
            stream.write(J.encode({"type": "event_msg", "payload": {
                "type": "user_message", "message": text}}) + b"\n")

    def activate(self, context):
        self.record = {**self.record, "processing": self.request["request_id"],
                       "processing_execution": {"run_id": self.run_dir.name,
                                                "manifest_sha256": context.manifest_sha256}}
        write_json(self.record_path, self.record)

    def seal(self, *, activate=True, **changes):
        arguments = dict(host="fixture-host", request=self.request, state=self.state, excerpt=self.excerpt,
                         expected_next_parser=self.next_parser, memory=self.memory, transport=self.transport,
                         scope=self.scope, writer_fence=self.fence, max_chars=2000, max_scan_bytes=4096)
        context = C.seal_execution(self.paths, **{**arguments, **changes})
        if activate:
            self.activate(context)
        return context

    def manifest(self):
        return J.read_manifest(self.run_dir)[0]

    def validate(self, context, phase="before_forward"):
        return context.validate_inputs(self.manifest(), phase)

    def test_seal_preserves_original_state_frontier_parser_and_private_route(self):
        original = {p: p.read_bytes() for p in (self.state_path, self.record_path, self.enrollment, self.path)}
        context = self.seal(activate=False)
        manifest, digest = J.read_manifest(self.run_dir)
        self.assertEqual(context.manifest_sha256, digest)
        self.assertEqual(manifest["source"]["start_offset"], self.frontier)
        self.assertEqual(manifest["source"]["end_offset"], self.excerpt.next_offset)
        self.assertEqual(J._json(J._unseal(manifest["inputs"]["next_parser_state"])), self.next_parser)
        route = J._json(J._unseal(manifest["inputs"]["backend_route"]))
        self.assertEqual(route["launch"]["env"]["HOME"], os.environ["HOME"])
        self.assertEqual(route["runtime"]["sha256"], J.sha256(self.runtime.read_bytes()))
        self.assertEqual(J._unseal(manifest["inputs"]["cursor"]), original[self.state_path])
        self.assertEqual(J._unseal(manifest["inputs"]["admission"]), original[self.record_path])
        self.assertEqual((self.run_dir / "execution-manifest.json").stat().st_mode & 0o777, 0o600)
        self.assertIs(context.validate_marker(manifest), True)
        for path, raw in original.items():
            self.assertEqual(path.read_bytes(), raw)
        self.activate(context)
        for phase in C.PHASES:
            self.assertIs(self.validate(context, phase), True)
        loaded = C.load_execution(self.paths, manifest_sha256=digest, writer_fence=self.fence)
        self.assertIs(self.validate(loaded), True)

    def test_later_append_pending_and_last_event_are_allowed_and_preserved(self):
        context = self.seal()
        self.append("Later private fact remains pending for the next Stop.")
        newer_record = {**self.record, "last_event": "b" * 64}
        write_json(self.record_path, newer_record)
        pending = self.root / "pending" / (SID + ".json")
        write_json(pending, {**self.request, "request_id": "newer-stop", "turn_id": "newer-turn"})
        newer = {p: p.read_bytes() for p in (pending, self.record_path, self.path)}
        self.assertIs(self.validate(context), True)
        for path, raw in newer.items():
            self.assertEqual(path.read_bytes(), raw)
        self.assertEqual(json.loads(self.state_path.read_bytes())["offset"], self.frontier)

    def test_processing_cursor_binding_activation_and_hold_changes_block(self):
        context = self.seal()
        modifications = [
            (self.record_path, {**self.record, "processing": None}),
            (self.record_path, {**self.record, "processing": "another-request"}),
            (self.record_path, {**self.record, "state_sha256": "0" * 64}),
            (self.record_path, {**self.record, "binding": {**self.request["admission"], "cutoff": "changed"}}),
            (self.state_path, {**self.state, "offset": self.frontier + 1}),
            (self.state_path, {**self.state, "current_turn_id": "changed"}),
            (self.root / "admission.json", {**self.policy, "enabled": False}),
            (self.root / "admission.json", {**self.policy, "activation_id": OWNER}),
        ]
        for path, value in modifications:
            with self.subTest(path=path.name, keys=list(value)):
                old = path.read_bytes()
                write_json(path, value)
                with self.assertRaises(C.ContextError):
                    self.validate(context)
                path.write_bytes(old)
        hold = self.root / "migration-holds" / (SID + ".json")
        write_json(hold, {})
        with self.assertRaises(C.ContextError):
            self.validate(context)

    def test_changed_source_bytes_before_end_truncation_and_replacement_block(self):
        context = self.seal()
        raw = self.path.read_bytes()
        for changed in (raw.replace(b"PRIVATE", b"CHANGED"), raw[:-1]):
            with self.subTest(size=len(changed)):
                self.path.write_bytes(changed)
                with self.assertRaises(C.ContextError):
                    self.validate(context)
                self.path.write_bytes(raw)
        alternate = self.path.with_suffix(".replacement")
        alternate.write_bytes(raw)
        alternate.chmod(0o600)
        os.replace(alternate, self.path)
        with self.assertRaises(C.ContextError):
            self.validate(context)

    def test_runtime_bytes_permissions_config_environment_and_settings_changes_block(self):
        context = self.seal()
        raw = self.runtime.read_bytes()
        self.runtime.write_bytes(raw + b"changed")
        with self.assertRaises(C.ContextError):
            self.validate(context)
        # Restoring content still changes the sealed runtime identity.
        self.runtime.write_bytes(raw)
        with self.assertRaises(C.ContextError):
            self.validate(context)

    def test_effective_config_environment_and_settings_changes_are_rechecked(self):
        context = self.seal()
        config_raw = self.config_path.read_bytes()
        self.config_path.write_text(self.config_text + "disabled_tools = [\"remember\", \"update\", \"connect\"]\n")
        with self.assertRaises(C.ContextError):
            self.validate(context)
        self.config_path.write_bytes(config_raw)
        with mock.patch.dict(os.environ, {"HOME": str(self.base / "changed-private-home")}):
            with self.assertRaises(C.ContextError):
                self.validate(context)
        write_json(self.root / "settings.json", {"max_chars": 4000, "max_scan_bytes": 4096})
        with self.assertRaises(C.ContextError):
            self.validate(context)

    def test_unrelated_user_config_change_does_not_invalidate_effective_memory(self):
        context = self.seal()
        self.config_path.write_text('model = "different-model"\n' + self.config_text)
        self.assertIs(self.validate(context), True)

    def test_wrapper_script_interpreter_arguments_and_symlink_runtime_refused_before_publication(self):
        original = self.runtime.read_bytes()
        self.runtime.write_bytes(b"#!/bin/sh\nexec private-unbound-native\n")
        with self.assertRaisesRegex(C.ContextError, "wrapper_runtime_unsupported"):
            self.seal()
        self.runtime.write_bytes(original)
        self.config_path.write_text(self.config_text.replace("args = []", 'args = ["private-script.py"]'))
        with self.assertRaisesRegex(C.ContextError, "runtime_arguments_unsupported"):
            self.seal()
        self.config_path.write_text(self.config_text)
        alternate = self.runtime.with_name("real-memory")
        self.runtime.rename(alternate)
        self.runtime.symlink_to(alternate)
        with self.assertRaisesRegex(C.ContextError, "unbound_runtime"):
            self.seal()
        self.assertFalse((self.run_dir / "execution-manifest.json").exists())

    def test_wrong_expected_parser_excerpt_and_unresolved_inputs_fail_closed(self):
        for changes in ({"expected_next_parser": {**self.next_parser, "offset": self.excerpt.next_offset + 1}},
                        {"memory": {**self.memory, "env": {"PRIVATE": "different"}}},
                        {"max_scan_bytes": 1}, {"max_chars": True},
                        {"request": {**self.request, "admission": {**self.request["admission"], "mode": H.MODE}}}):
            with self.subTest(keys=list(changes)):
                with self.assertRaises(C.ContextError) as raised:
                    self.seal(**changes)
                self.assertNotIn("PRIVATE", str(raised.exception))
                self.assertFalse((self.run_dir / "execution-manifest.json").exists())

    def test_manifest_tampering_wrong_digest_and_unknown_phase_block(self):
        context = self.seal()
        changed = self.manifest()
        changed["host"] = "different-host"
        with self.assertRaises(C.ContextError):
            context.validate_inputs(changed, "before_intent")
        with self.assertRaises(C.ContextError):
            C.load_execution(self.paths, manifest_sha256="0" * 64, writer_fence=self.fence)
        with self.assertRaises(C.ContextError):
            self.validate(context, "after_provider")
        write_json(self.run_dir / "execution-manifest.json", changed)
        with self.assertRaises(C.ContextError):
            self.validate(context)

    def test_fence_loss_and_unsafe_state_file_block_without_changes(self):
        context = self.seal()
        before = self.state_path.read_bytes()
        self.state_path.chmod(0o644)
        with self.assertRaises(C.ContextError):
            self.validate(context)
        self.state_path.chmod(0o600)
        self.fence.close()
        with self.assertRaises(C.ContextError):
            self.validate(context)
        self.assertEqual(self.state_path.read_bytes(), before)

    def test_existing_processing_marker_is_never_adopted_by_sealing(self):
        write_json(self.record_path, {**self.record, "processing": "other-request"})
        with self.assertRaisesRegex(C.ContextError, "processing_changed"):
            self.seal()
        self.assertFalse((self.run_dir / "execution-manifest.json").exists())

    def test_pre_marker_manifest_never_authorizes_dispatch_and_marker_must_reference_digest(self):
        context = self.seal(activate=False)
        manifest = self.manifest()
        self.assertIs(context.validate_marker(manifest), True)
        loaded = C.load_execution(self.paths, manifest_sha256=context.manifest_sha256,
                                  writer_fence=self.fence, before_marker=True)
        self.assertIs(loaded.validate_marker(manifest), True)
        with self.assertRaises(C.ContextError):
            self.validate(context)
        self.activate(context)
        correct = copy.deepcopy(self.record)
        for execution in (None, {"run_id": "other-run", "manifest_sha256": context.manifest_sha256},
                          {"run_id": self.run_dir.name, "manifest_sha256": "0" * 64}):
            write_json(self.record_path, {**correct, "processing_execution": execution})
            with self.assertRaises(C.ContextError):
                self.validate(context)
        write_json(self.record_path, correct)
        self.assertIs(self.validate(context), True)
        self.assertIs(context.validate_marker(manifest), True)

    def test_source_backend_validation_is_read_only_and_separate_from_cursor_publication_authority(self):
        context = self.seal()
        manifest = self.manifest()
        write_json(self.state_path, {**self.state, "offset": self.excerpt.next_offset})
        with self.assertRaises(C.ContextError):
            self.validate(context)
        self.assertIs(context.validate_source_backend(manifest), True)
        self.fence.close()
        with F.revoke(self.run_dir, self.binding, validate=lambda *_: True) as exclusive:
            recovered = C.load_execution(self.paths, manifest_sha256=context.manifest_sha256,
                                         writer_fence=exclusive, source_backend_only=True)
            self.assertIs(recovered.validate_source_backend(manifest), True)
            with self.assertRaises(C.ContextError):
                recovered.validate_marker(manifest)
            with self.assertRaises(C.ContextError):
                recovered.validate_inputs(manifest, "before_forward")

    def test_bounded_rederivation_uses_original_interval_and_original_parser_state(self):
        context = self.seal()
        self.append("Later message must not enter the original excerpt.")
        with mock.patch.object(T, "read_excerpt", wraps=T.read_excerpt) as read:
            self.assertIs(self.validate(context), True)
            self.assertEqual(read.call_count, 1)
            args, kwargs = read.call_args
            self.assertEqual(args, (str(self.path), self.frontier))
            self.assertEqual(kwargs["max_scan_bytes"], self.excerpt.next_offset - self.frontier)
            self.assertEqual(kwargs["recent_messages"], self.state["recent_messages"])
            self.assertEqual(kwargs["current_turn_id"], self.state["current_turn_id"])
        original = C._parser_runtime()
        with mock.patch.object(C, "_parser_runtime", return_value={**original, "sha256": "0" * 64}):
            with self.assertRaises(C.ContextError):
                self.validate(context)

    def test_malformed_original_parser_state_is_not_silently_filtered(self):
        original = copy.deepcopy(self.state)
        for recent in (["invalid-entry"], [{"content_hash": "bad"}], [None] * 129):
            with self.subTest(count=len(recent)):
                self.state = {**original, "recent_messages": recent}
                write_json(self.state_path, self.state)
                write_json(self.record_path, {**self.record, "state_sha256": C.durable.object_digest(self.state)})
                with self.assertRaises(C.ContextError):
                    self.seal()
                self.assertFalse((self.run_dir / "execution-manifest.json").exists())

    def test_omitted_global_cwd_is_bound_to_run_workspace_across_caller_directories(self):
        self.config_text = self.config_text.replace("cwd = " + json.dumps(str(self.plugin)) + "\n", "")
        self.config_path.write_text(self.config_text)
        self.memory = C.memory_config.resolve(self.config_path, self.plugin)[1]
        self.transport = C.memory_config.transport(self.memory)
        self.assertNotIn("cwd", self.transport)
        resolved = C.effective_transport(self.paths, self.transport)
        self.assertEqual(resolved["cwd"], str(self.run_dir / "workspace"))
        context = self.seal(transport=resolved)
        self.assertEqual(context.transport, resolved)
        original = Path.cwd()
        try:
            os.chdir(self.project)
            loaded = C.load_execution(self.paths, manifest_sha256=context.manifest_sha256, writer_fence=self.fence)
            self.assertIs(self.validate(loaded), True)
            self.assertEqual(loaded.transport["cwd"], str(self.run_dir / "workspace"))
        finally:
            os.chdir(original)
        changed = context.transport
        changed["cwd"] = "not-authority"
        self.assertEqual(context.transport, resolved)

    def test_recovery_input_validation_before_revocation_never_grants_dispatch(self):
        context = self.seal()
        manifest = self.manifest()
        self.fence.close()
        # Pair/processing validation belongs to the caller, including mixed
        # publication images. This helper checks source/backend/activation only.
        write_json(self.state_path, {**self.state, "offset": self.excerpt.next_offset})
        write_json(self.record_path, {**self.record, "processing": None, "state_sha256": "f" * 64})
        before = {p: p.read_bytes() for p in (self.state_path, self.record_path, self.path,
                                            self.run_dir / "execution-manifest.json")}
        self.assertIs(C.validate_recovery_inputs(self.paths, manifest_sha256=context.manifest_sha256), True)
        self.assertFalse((self.run_dir / F.REVOCATION_NAME).exists())
        with self.assertRaises(C.ContextError):
            context.validate_inputs(manifest, "before_forward")
        phases = []
        def validate(binding, phase):
            self.assertEqual(binding, self.binding)
            phases.append(phase)
            return C.validate_recovery_inputs(self.paths, manifest_sha256=context.manifest_sha256)
        with F.revoke(self.run_dir, self.binding, validate=validate) as exclusive:
            self.assertIs(exclusive.verify(self.binding), True)
            recovered = C.load_execution(self.paths, manifest_sha256=context.manifest_sha256,
                                         writer_fence=exclusive, source_backend_only=True)
            with self.assertRaises(C.ContextError):
                recovered.validate_inputs(manifest, "before_forward")
        self.assertEqual(phases, ["before_acquire", "after_acquire", "before_revocation", "after_revocation"])
        for path, raw in before.items():
            self.assertEqual(path.read_bytes(), raw)

    def test_recovery_input_changes_prevent_revocation_before_any_durable_effect(self):
        context = self.seal()
        self.fence.close()
        def validate(*_):
            return C.validate_recovery_inputs(self.paths, manifest_sha256=context.manifest_sha256)
        changes = [
            (self.path, self.path.read_bytes().replace(b"PRIVATE", b"CHANGED")),
            (self.config_path, self.config_path.read_bytes() + b'disabled_tools = ["remember", "update", "connect"]\n'),
            (self.root / "admission.json", J.encode({**self.policy, "enabled": False})),
            (self.root / "settings.json", J.encode({"max_chars": 1, "max_scan_bytes": 4096})),
        ]
        for path, raw in changes:
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.write_bytes(raw)
                with self.assertRaises(C.ContextError):
                    F.revoke(self.run_dir, self.binding, validate=validate)
                self.assertFalse((self.run_dir / F.REVOCATION_NAME).exists())
                path.write_bytes(original)
        original = C._parser_runtime()
        with mock.patch.object(C, "_parser_runtime", return_value={**original, "sha256": "0" * 64}):
            with self.assertRaises(C.ContextError):
                validate()
        self.runtime.write_bytes(self.runtime.read_bytes() + b"changed-runtime")
        with self.assertRaises(C.ContextError):
            validate()
        self.assertFalse((self.run_dir / F.REVOCATION_NAME).exists())

    def test_recovery_requires_pinned_manifest_and_trusted_paths_and_rechecks_manifest(self):
        context = self.seal()
        self.fence.close()
        for digest in ("0" * 64, "invalid", True):
            with self.subTest(digest=digest), self.assertRaises(C.ContextError):
                C.validate_recovery_inputs(self.paths, manifest_sha256=digest)
        alias = self.base / "run-alias"
        alias.symlink_to(self.run_dir, target_is_directory=True)
        wrong = C.ContextPaths(self.root, alias, self.config_path, self.plugin)
        with self.assertRaises(C.ContextError):
            C.validate_recovery_inputs(wrong, manifest_sha256=context.manifest_sha256)
        source = C._source
        def mutate_manifest(*args):
            source(*args)
            altered = self.manifest()
            altered["host"] = "changed-during-validation"
            write_json(self.run_dir / "execution-manifest.json", altered)
        with mock.patch.object(C, "_source", side_effect=mutate_manifest):
            with self.assertRaisesRegex(C.ContextError, "manifest_changed"):
                C.validate_recovery_inputs(self.paths, manifest_sha256=context.manifest_sha256)

    def test_recovery_rechecks_admission_after_source_and_refuses_new_hold(self):
        context = self.seal()
        self.fence.close()
        source = C._source
        def create_hold(*args):
            source(*args)
            write_json(self.root / "migration-holds" / (SID + ".json"), {})
        with mock.patch.object(C, "_source", side_effect=create_hold):
            with self.assertRaises(C.ContextError):
                C.validate_recovery_inputs(self.paths, manifest_sha256=context.manifest_sha256)


if __name__ == "__main__":
    unittest.main()
