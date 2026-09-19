"""Synthetic admission/cursor regressions; no provider, process, DB or network.

This file loads the staged package only after real-effect guards are active.
All rollout, policy, queue and cursor files belong to TemporaryDirectory fixtures.
The worker is real; its process_request uses an explicit fake invoke callback.
"""
import contextlib
import copy
import ctypes
import datetime as dt
import importlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import unittest

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT
from unittest import mock
import uuid


HERE = Path(__file__).resolve().parent
SOURCE = PLUGIN_ROOT / "scripts/codex_learner"
PACKAGE = "_frontier_admission_under_test"
CUTOFF = "2026-01-01T00:00:00Z"
CREATED = "2026-01-02T00:00:01Z"
ORIGIN = "2026-01-02T00:00:00Z"
ACTIVATION = "11111111-2222-4333-8444-555555555555"
TURN1 = "11111111-2222-4333-8444-555555555556"
TURN2 = "11111111-2222-4333-8444-555555555557"
GUARDS = None
RUNNER = None
ADMISSION = None


def forbidden(*args, **kwargs):
    raise AssertionError("Real process/native/database/network operation forbidden")


def setUpModule():
    global GUARDS, RUNNER, ADMISSION
    GUARDS = contextlib.ExitStack()
    for obj, names in (
        (subprocess, ("Popen", "run", "call", "check_call", "check_output")),
        (os, ("system", "fork", "forkpty", "posix_spawn", "posix_spawnp",
              "spawnl", "spawnle", "spawnlp", "spawnlpe", "spawnv", "spawnve",
              "spawnvp", "spawnvpe", "kill", "killpg")),
        (socket, ("socket", "create_connection")),
        (sqlite3, ("connect",)),
        (ctypes, ("CDLL", "PyDLL")),
    ):
        for name in names:
            if hasattr(obj, name):
                GUARDS.enter_context(mock.patch.object(obj, name, side_effect=forbidden))
    GUARDS.enter_context(mock.patch.object(sys, "dont_write_bytecode", True))
    spec = importlib.util.spec_from_file_location(
        PACKAGE, SOURCE / "__init__.py", submodule_search_locations=[str(SOURCE), str(SOURCE)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[PACKAGE] = module
    spec.loader.exec_module(module)
    RUNNER = importlib.import_module(PACKAGE + ".runner")
    ADMISSION = importlib.import_module(PACKAGE + ".admission")


def tearDownModule():
    for name in list(sys.modules):
        if name == PACKAGE or name.startswith(PACKAGE + "."):
            del sys.modules[name]
    if GUARDS is not None:
        GUARDS.close()


def uuid7(timestamp, suffix=17):
    value = dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    milliseconds = int(value.timestamp() * 1000)
    return str(uuid.UUID(int=(milliseconds << 80) | (7 << 76) | (0x123 << 64)
                         | (2 << 62) | suffix))


def private_directory(path):
    if not path.exists():
        private_directory(path.parent)
        path.mkdir(mode=0o700)
    return path


def write_json(path, value):
    private_directory(path.parent)
    path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    path.chmod(0o600)


class Fixture:
    def __init__(self, base, *, origin=ORIGIN, created=CREATED, source="vscode", cli_version="0.154.0-alpha.6.2"):
        self.base = base
        self.root = private_directory(base / "state")
        self.project = private_directory(base / "project")
        self.codex = private_directory(base / "codex")
        self.sessions = private_directory(self.codex / "sessions")
        self.sid = uuid7(origin)
        stamp = dt.datetime.fromisoformat(origin.replace("Z", "+00:00"))
        directory = private_directory(self.sessions / stamp.strftime("%Y/%m/%d"))
        self.path = directory / ("rollout-" + stamp.strftime("%Y-%m-%dT%H-%M-%S")
                                 + "-" + self.sid + ".jsonl")
        self.meta = {
            "type": "session_meta", "timestamp": "2026-06-01T12:00:00Z",
            "payload": {"id": self.sid, "session_id": self.sid,
                        "timestamp": created, "cwd": str(self.project),
                        "source": source, "thread_source": "user",
                        "originator": "Codex Desktop", "cli_version": cli_version,
                        "history_mode": "paginated"},
        }
        self.path.write_text(json.dumps(self.meta) + "\n", encoding="utf-8")
        self.path.chmod(0o600)
        self.append_turn(TURN1, "First synthetic fact: the example marker is amber.")
        self.payload = {
            "hook_event_name": "Stop", "session_id": self.sid,
            "transcript_path": str(self.path), "cwd": str(self.project),
            "turn_id": TURN1, "model": "synthetic-never-invoked",
        }
        self.policy = {
            "schema_version": 1, "mode": "explicit_frontier_v1", "enabled": True,
            "activation_id": ACTIVATION, "cutoff": dt.datetime.now(dt.timezone.utc).isoformat(),
            "state_dir": str(self.root), "project": self.binding(self.project),
            "sessions_dir": self.binding(self.sessions),
            "enrollments": {},
        }
        self.policy["enrollments"][self.sid] = ADMISSION.capture(self.policy["project"], self.policy["sessions_dir"], str(self.path), self.sid)
        self.frontier = self.policy["enrollments"][self.sid]["frontier_offset"]
        self.policy_path = self.root / "admission.json"
        self.save_policy()
        self.config = {"min_chars": 1, "max_chars": 2000, "max_scan_bytes": 1048576,
                       "wall_seconds": 180, "max_tool_calls": 4, "max_writes": 1,
                       "max_runs_per_worker": 1, "retry_seconds": 3600}
        write_json(self.root / "settings.json", self.config)
        self.invocations = []

    @staticmethod
    def binding(path):
        value = path.stat()
        return {"path": str(path), "device": value.st_dev, "inode": value.st_ino}

    @property
    def pending(self):
        return self.root / "pending" / (self.sid + ".json")

    @property
    def state(self):
        return self.root / "sessions" / (self.sid + ".json")

    @property
    def record(self):
        return self.root / "admissions" / (self.sid + ".json")

    def save_policy(self):
        write_json(self.policy_path, self.policy)

    def rewrite_initial(self, raw=None):
        remainder = self.path.read_bytes().split(b"\n", 1)[1]
        first = json.dumps(self.meta).encode() if raw is None else raw
        self.path.write_bytes(first + b"\n" + remainder)

    def append_turn(self, turn, message):
        rows = [
            {"type": "event_msg", "payload": {"type": "task_started", "turn_id": turn}},
            {"type": "response_item", "payload": {
                "type": "message", "role": "user", "turn_id": turn,
                "id": "message-" + turn,
                "content": [{"type": "input_text", "text": message}]}},
            {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": turn}},
        ]
        with self.path.open("a", encoding="utf-8") as out:
            for row in rows:
                out.write(json.dumps(row) + "\n")

    def invoke(self, root, run_dir, request, excerpt, config):
        self.invocations.append({"text": excerpt.text, "next_offset": excerpt.next_offset,
                                 "request_id": request["request_id"]})
        result = {"status": "succeeded", "write_calls": 0, "returncode": 0}
        RUNNER.atomic_json(run_dir / "run.json", result)
        return result

    def request(self):
        return json.loads(self.pending.read_text())

    def worker(self):
        original = RUNNER.process_request

        def process(root, request, config):
            return original(root, request, config, invoke=self.invoke)

        with mock.patch.object(RUNNER, "process_request", side_effect=process), \
                mock.patch.object(RUNNER, "spawn_worker", side_effect=forbidden):
            return RUNNER.worker(self.root)


class FrontierTests(unittest.TestCase):
    @contextlib.contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory(prefix="engram-frontier-") as directory:
            value = Fixture(Path(directory).resolve())
            env = {k: v for k, v in os.environ.items() if k not in ("ENGRAM_CODEX_LEARNER", "CLAUDE_MEMORY_LEARNER")}
            env["CODEX_HOME"] = str(value.codex)
            with mock.patch.dict(os.environ, env, clear=True):
                yield value

    def queued(self, f):
        self.assertTrue(RUNNER.enqueue(f.root, f.payload, spawn=False))
        return f.request()

    def test_existing_history_is_excluded_and_cursor_seeded_at_frontier(self):
        with self.fixture() as f:
            request = self.queued(f)
            self.assertEqual(json.loads(f.state.read_text())["offset"], f.frontier)
            self.assertEqual(RUNNER.process_request(f.root, request, f.config, invoke=f.invoke), "no_change")
            self.assertEqual(f.invocations, [])

    def test_only_bytes_after_frontier_are_learned_then_cursor_resumes(self):
        with self.fixture() as f:
            f.append_turn(TURN2, "NEW ONLY: synthetic color cobalt.")
            f.payload["turn_id"] = TURN2
            self.queued(f)
            f.worker()
            self.assertEqual(len(f.invocations), 1)
            self.assertIn("NEW ONLY", f.invocations[0]["text"])
            self.assertNotIn("amber", f.invocations[0]["text"])
            first_offset = json.loads(f.state.read_text())["offset"]
            f.append_turn("turn-three", "NEXT ONLY: synthetic color jade.")
            f.payload["turn_id"] = "turn-three"
            self.queued(f)
            f.worker()
            self.assertEqual(len(f.invocations), 2)
            self.assertIn("NEXT ONLY", f.invocations[1]["text"])
            self.assertNotIn("NEW ONLY", f.invocations[1]["text"])
            self.assertGreater(json.loads(f.state.read_text())["offset"], first_offset)

    def test_partial_eof_is_rejected_without_rounding_back(self):
        with self.fixture() as f:
            with f.path.open("ab") as stream: stream.write(b'{"unfinished":')
            before = f.policy_path.read_bytes()
            with self.assertRaisesRegex(ValueError, "frontier_not_complete_line"):
                ADMISSION.capture(f.policy["project"], f.policy["sessions_dir"], str(f.path), f.sid)
            self.assertEqual(f.policy_path.read_bytes(), before)

    def test_changed_boundary_or_truncation_rejects(self):
        for change in ("boundary", "truncate"):
            with self.subTest(change=change), self.fixture() as f:
                raw = bytearray(f.path.read_bytes())
                if change == "boundary": raw[-3] = ord('X')
                else: raw = raw[:f.frontier - 1]
                f.path.write_bytes(raw)
                self.assertFalse(RUNNER.enqueue(f.root, f.payload, spawn=False))
                self.assertFalse(f.state.exists())

    def test_missing_cursor_never_resets_to_zero(self):
        with self.fixture() as f:
            request = self.queued(f)
            f.state.unlink()
            with self.assertRaisesRegex(ValueError, "cursor_missing_or_changed"):
                RUNNER.process_request(f.root, request, f.config, invoke=f.invoke)
            self.assertFalse(f.state.exists())
            self.assertEqual(f.invocations, [])

    def test_resealed_cursor_below_frontier_is_rejected(self):
        with self.fixture() as f:
            request = self.queued(f)
            state = json.loads(f.state.read_text());state["offset"] = 0
            record = json.loads(f.record.read_text());record["state_sha256"] = RUNNER.admission_digest(state)
            write_json(f.state, state);write_json(f.record, record)
            with self.assertRaisesRegex(ValueError, "cursor_before_frontier"):
                RUNNER.process_request(f.root, request, f.config, invoke=f.invoke)
            self.assertEqual(f.invocations, [])

    def test_existing_unowned_state_is_not_adopted(self):
        with self.fixture() as f:
            write_json(f.state, {"offset": 0})
            before = f.state.read_bytes()
            self.assertFalse(RUNNER.enqueue(f.root, f.payload, spawn=False))
            self.assertEqual(f.state.read_bytes(), before)
            self.assertFalse(f.record.exists())

    def test_interrupted_initial_pair_fails_closed(self):
        with self.fixture() as f:
            original = RUNNER.atomic_json
            def crash(path, value):
                if path == f.state: raise OSError("synthetic cursor publication crash")
                return original(path, value)
            with mock.patch.object(RUNNER, "atomic_json", side_effect=crash):
                self.assertFalse(RUNNER.enqueue(f.root, f.payload, spawn=False))
            self.assertTrue(f.record.exists());self.assertFalse(f.state.exists())
            self.assertFalse(RUNNER.enqueue(f.root, f.payload, spawn=False))
            self.assertFalse(f.state.exists());self.assertFalse(f.pending.exists())

    def test_foreign_pending_is_not_processed_or_paused(self):
        with self.fixture() as f:
            foreign = f.root / "pending" / "not-enrolled.json"
            write_json(foreign, {"session_id": "not-enrolled", "historic": True})
            before = foreign.read_bytes()
            self.assertEqual(f.worker(), 0)
            self.assertEqual(foreign.read_bytes(), before)
            self.assertEqual(f.invocations, [])

    def test_inactive_policy_rejects_worker_before_locks(self):
        with self.fixture() as f:
            f.policy["enabled"] = False;f.save_policy()
            with mock.patch.object(RUNNER, "lock_file", side_effect=AssertionError("must not lock")):
                with self.assertRaisesRegex(ValueError, "admission_inactive"): f.worker()

    def test_policy_rebinding_invalidates_existing_state(self):
        with self.fixture() as f:
            request = self.queued(f)
            f.append_turn(TURN2, "new bytes")
            f.policy["enrollments"][f.sid] = ADMISSION.capture(f.policy["project"], f.policy["sessions_dir"], str(f.path), f.sid)
            f.save_policy()
            with self.assertRaisesRegex(ValueError, "binding_changed"):
                RUNNER.process_request(f.root, request, f.config, invoke=f.invoke)
            self.assertEqual(f.invocations, [])

    def test_metadata_version_source_fork_changes_reject(self):
        for key, value in (("cli_version", "0.999.0"), ("source", "cli"), ("history_base", {})):
            with self.subTest(key=key), self.fixture() as f:
                f.meta["payload"][key] = value;f.rewrite_initial()
                self.assertFalse(RUNNER.enqueue(f.root, f.payload, spawn=False))

    def test_source_replacement_rejects_same_bytes(self):
        with self.fixture() as f:
            replacement = f.path.with_suffix(".new")
            replacement.write_bytes(f.path.read_bytes());replacement.replace(f.path)
            self.assertFalse(RUNNER.enqueue(f.root, f.payload, spawn=False))

    def test_state_directory_symlink_is_rejected(self):
        with self.fixture() as f:
            other = private_directory(f.base / "other")
            (f.root / "sessions").symlink_to(other, target_is_directory=True)
            self.assertFalse(RUNNER.enqueue(f.root, f.payload, spawn=False))
            self.assertEqual(list(other.iterdir()), [])

    def test_other_session_or_project_is_not_implicitly_enrolled(self):
        with self.fixture() as f:
            bad = {**f.payload, "session_id": uuid7(ORIGIN, suffix=99)}
            self.assertFalse(RUNNER.enqueue(f.root, bad, spawn=False))
            bad = {**f.payload, "cwd": str(f.base)}
            self.assertFalse(RUNNER.enqueue(f.root, bad, spawn=False))
            self.assertEqual(set(f.policy["enrollments"]), {f.sid})

    def test_boolean_boundary_number_is_not_admitted_as_zero(self):
        with self.fixture() as f:
            f.policy["enrollments"][f.sid]["frontier_anchor_start"] = False
            f.save_policy()
            self.assertFalse(RUNNER.enqueue(f.root, f.payload, spawn=False))


if __name__ == "__main__":
    unittest.main(verbosity=2)
