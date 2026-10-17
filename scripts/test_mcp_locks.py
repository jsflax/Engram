"""Client/fixture checks only; does not execute an Engram native product."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("verify_mcp_locks", ROOT / "verify-mcp-locks.py")
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)
ID = "7603516A-65A2-450B-8A55-86D74EEC7946"


class PersistenceHarnessTests(unittest.TestCase):
    def temporary_directory(self):
        # CI may use its normal temporary root. Agent runs explicitly set
        # TMPDIR (or ENGRAM_MCP_TEST_TMPDIR) beneath their owned localdev run.
        root = os.environ.get("ENGRAM_MCP_TEST_TMPDIR", os.environ.get("TMPDIR"))
        if root is not None:
            Path(root).mkdir(parents=True, exist_ok=True)
        return tempfile.TemporaryDirectory(prefix="engram-client-test-", dir=root)

    def result(self, text, **extra):
        return {"content": [{"type": "text", "text": text}], **extra}

    def test_remember_requires_valid_successful_uuid(self):
        self.assertEqual(HARNESS.remembered_id(self.result(f"Stored memory (id: {ID}, project: Test): exact")), ID)
        for result in [self.result("Stored memory without identity"),
                       self.result(f"Stored memory (id: {ID}, project: Test): exact", isError=True)]:
            with self.subTest(result=result), self.assertRaises(AssertionError):
                HARNESS.remembered_id(result)

    def test_recall_requires_exact_identity_full_content_and_one_block(self):
        block = f"[id:{ID}] [Test/general] (distance: 0.100) exact content"
        HARNESS.assert_recalled_identity(self.result(block), ID, "exact content")
        for text in [block.replace(ID, "00000000-0000-0000-0000-000000000000"),
                     block + " truncated", block + "\n\n" + block]:
            with self.subTest(text=text), self.assertRaises(AssertionError):
                HARNESS.assert_recalled_identity(self.result(text), ID, "exact content")

    def test_failed_write_accepts_error_forms_and_rejects_false_ack(self):
        HARNESS.assert_failed_write({"jsonrpc": "2.0", "id": 1, "error": {"code": -32603, "message": "busy"}})
        HARNESS.assert_failed_write({"jsonrpc": "2.0", "id": 1, "result": self.result("busy", isError=True)})
        for result in [self.result("busy"), self.result("embedding unavailable", isError=True),
                       self.result(f"Stored memory (id: {ID}, project: Test): bad", isError=True)]:
            with self.subTest(result=result), self.assertRaises(AssertionError):
                HARNESS.assert_failed_write({"jsonrpc": "2.0", "id": 1, "result": result})

    def fake_binary(self, directory, dishonest=False, scope=None):
        # A small Python JSON-RPC fixture backed by its disposable SQLite DB.
        # This verifies the harness's process/reopen/lock logic, not Engram.
        program = textwrap.dedent('''\
            import json, os, sqlite3, sys, uuid
            assert "ENGRAM_URL" not in os.environ
            db = sqlite3.connect(os.environ["CLAUDE_MEMORY_DB"], timeout=0.05)
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("CREATE TABLE IF NOT EXISTS Memory(globalId TEXT PRIMARY KEY, content TEXT)")
            db.commit()
            for line in sys.stdin:
                request = json.loads(line)
                if "id" not in request:
                    continue
                method = request["method"]
                if method == "initialize":
                    result = {"serverInfo": {"name": "memory"}}
                else:
                    params = request["params"]
                    args = params["arguments"]
                    if params["name"] == "remember":
                        identity = str(uuid.uuid4()).upper()
                        try:
                            db.execute("INSERT INTO Memory VALUES (?, ?)", (identity, args["content"]))
                            db.commit()
                            result = {"content": [{"type": "text", "text": "Stored memory (id: " + identity + ", project: Test): " + args["content"]}]}
                        except sqlite3.OperationalError as exc:
                            db.rollback()
                            if DISHONEST:
                                result = {"content": [{"type": "text", "text": "Stored memory (id: " + identity + ", project: Test): " + args["content"]}]}
                            else:
                                result = {"isError": True, "content": [{"type": "text", "text": str(exc)}]}
                    elif params["name"] == "operation_scope":
                        payload = {"engram_operation": {"version": 1, "kind": "scope",
                            "capability": "localMutationOperationsV1", "scope": SCOPE}}
                        result = {"content": [{"type": "text", "text": json.dumps(payload)}],
                                  "structuredContent": payload}
                    else:
                        rows = db.execute("SELECT globalId, content FROM Memory").fetchall()
                        result = {"content": [{"type": "text", "text": "\\n\\n".join("[id:" + identity + "] [Test/general] (distance: 0.100) " + content for identity, content in rows)}]}
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
            db.close()
        ''').replace("DISHONEST", repr(dishonest)).replace("SCOPE", repr(scope))
        binary = Path(directory) / "fake-mcp"
        binary.write_text("#!" + sys.executable + "\n" + program)
        binary.chmod(0o700)
        return binary

    def test_unlocked_reopen_preserves_scope_deadline_and_reaps_process(self):
        scope = {"version": 1, "storeID": ID, "principal": {"kind": "anonymous", "groupIds": [], "scopes": []}}
        with self.temporary_directory() as directory:
            binary = self.fake_binary(directory, scope=scope)
            clients, receipts = [], []
            original_client = HARNESS.Client
            deadline = time.monotonic() + 5
            def capture(*args, **kwargs):
                client = original_client(*args, **kwargs)
                clients.append(client)
                return client
            with patch.object(HARNESS, "Client", side_effect=capture):
                pid = HARNESS.reopen_registered_fixture(binary, Path(directory) / "fixture.sqlite", scope,
                    environment={}, cwd=directory, deadline=deadline,
                    require_open_logs=lambda client: receipts.append(client.process.poll()))
            self.assertEqual(clients[0].deadline, deadline)
            self.assertEqual(clients[0].process.returncode, 0)
            self.assertEqual(receipts, [None])
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_unlocked_reopen_rejects_changed_scope_and_still_reaps(self):
        scope = {"version": 1, "storeID": ID, "principal": {"kind": "anonymous", "groupIds": [], "scopes": []}}
        changed = dict(scope, storeID="00000000-0000-0000-0000-000000000001")
        with self.temporary_directory() as directory:
            binary = self.fake_binary(directory, scope=changed)
            clients = []
            original_client = HARNESS.Client
            def capture(*args, **kwargs):
                client = original_client(*args, **kwargs)
                clients.append(client)
                return client
            with patch.object(HARNESS, "Client", side_effect=capture):
                with self.assertRaisesRegex(AssertionError, "changed store/principal scope"):
                    HARNESS.reopen_registered_fixture(binary, Path(directory) / "fixture.sqlite", scope,
                        environment={}, cwd=directory, deadline=time.monotonic() + 5)
            self.assertEqual(clients[0].process.returncode, 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(clients[0].process.pid, 0)

    def test_schema_snapshot_still_refuses_fingerprints_staled_by_post_open_ddl(self):
        with self.temporary_directory() as directory:
            path = (Path(directory) / "fixture.sqlite").resolve()
            with contextlib.closing(sqlite3.connect(path)) as db:
                for name in ("Memory", "Edge", "Checkpoint", "HookState", "SessionState", "SyncConfig", "EngramOperationReceiptV1"):
                    db.execute(f"CREATE TABLE {name}(id INTEGER)")
                db.execute("CREATE TABLE EngramOperationStoreV1(singletonKey TEXT, storeID TEXT, formatVersion INTEGER)")
                db.execute("INSERT INTO EngramOperationStoreV1 VALUES ('local-operation-store', ?, 1)", (ID.lower(),))
                db.execute("CREATE TABLE _lattice_meta(key TEXT, value TEXT)")
                original_cookie = db.execute("PRAGMA schema_version").fetchone()[0]
                db.execute("INSERT INTO _lattice_meta VALUES ('schema_fingerprint:fixture', ?)", (str(original_cookie),))
                db.commit()
                self.assertEqual(HARNESS.initialized_store_snapshot(path)["schema_cookie"], original_cookie)
                db.execute("CREATE TABLE post_open_vector_fixture(id INTEGER)")
                db.commit()
                with self.assertRaisesRegex(AssertionError, "schema_cookie"):
                    HARNESS.initialized_store_snapshot(path)
                self.assertEqual(db.execute("SELECT value FROM _lattice_meta").fetchone()[0], str(original_cookie))

    def guarded_startup_fixture(self, directory):
        path = (Path(directory) / "startup.sqlite").resolve()
        with contextlib.closing(sqlite3.connect(path)) as db:
            db.execute("CREATE TABLE Memory(globalId TEXT, content TEXT)")
            db.execute("INSERT INTO Memory VALUES (?, 'synthetic preserved memory')", (ID,))
            for name in ("Edge", "Checkpoint", "HookState", "SessionState", "SyncConfig", "EngramOperationReceiptV1"):
                db.execute(f"CREATE TABLE {name}(id INTEGER)")
            db.execute("CREATE TABLE EngramOperationStoreV1(id INTEGER PRIMARY KEY, globalId TEXT, singletonKey TEXT, storeID TEXT, formatVersion INTEGER)")
            db.execute("INSERT INTO EngramOperationStoreV1 VALUES (1, ?, 'local-operation-store', ?, 1)", (ID, ID))
            db.execute("CREATE TABLE _SyncControl(id INTEGER PRIMARY KEY, disabled INTEGER)")
            db.execute("INSERT INTO _SyncControl VALUES (1, 0)")
            db.execute("CREATE TABLE _lattice_meta(key TEXT, value TEXT)")
            db.execute("CREATE TABLE AuditLog(id INTEGER PRIMARY KEY AUTOINCREMENT, tableName TEXT, operation TEXT, rowId INTEGER, globalRowId TEXT, changedFields TEXT, changedFieldsNames TEXT, timestamp REAL)")
            db.execute("INSERT INTO AuditLog(tableName, operation, rowId, globalRowId) VALUES ('Memory', 'INSERT', 1, ?)", (ID,))
            # Match Core's generated DELETE guard and audit fields. No UDF is
            # installed until the test explicitly selects its connection state.
            db.execute("""CREATE TRIGGER AuditEngramOperationStoreV1Delete
                AFTER DELETE ON EngramOperationStoreV1 WHEN (sync_disabled() = 0)
                BEGIN INSERT INTO AuditLog(tableName, operation, rowId, globalRowId,
                                          changedFields, changedFieldsNames, timestamp)
                    VALUES ('EngramOperationStoreV1', 'DELETE', OLD.id, OLD.globalId,
                            json_object('singletonKey', OLD.singletonKey, 'storeID', OLD.storeID,
                                        'formatVersion', OLD.formatVersion),
                            json_array('singletonKey', 'storeID', 'formatVersion'), unixepoch('subsec'));
                END""")
            cookie = db.execute("PRAGMA schema_version").fetchone()[0]
            db.execute("INSERT INTO _lattice_meta VALUES ('schema_fingerprint:fixture', ?)", (str(cookie),))
            db.commit()
        return path

    def test_startup_identity_removal_retains_generated_guard_schema_and_audit(self):
        with self.temporary_directory() as directory:
            path = self.guarded_startup_fixture(directory)
            with contextlib.closing(sqlite3.connect(path)) as db:
                before = list(db.iterdump())
                with self.assertRaisesRegex(sqlite3.OperationalError, "no such function: sync_disabled"):
                    db.execute("DELETE FROM EngramOperationStoreV1")
                db.rollback()
                self.assertEqual(list(db.iterdump()), before)
                # The existing trigger still audits ordinary, non-disabled
                # deletes. Roll back this probe before exercising setup.
                db.create_function("sync_disabled", 0, lambda: 0)
                db.execute("DELETE FROM EngramOperationStoreV1")
                self.assertEqual(db.execute("SELECT operation FROM AuditLog ORDER BY id").fetchall(), [("INSERT",), ("DELETE",)])
                db.rollback()
                self.assertEqual(list(db.iterdump()), before)
            HARNESS.remove_fixture_store_identity(path)
            with contextlib.closing(sqlite3.connect(path)) as db:
                after = list(db.iterdump())
                self.assertEqual(after, [line for line in before if not line.startswith('INSERT INTO "EngramOperationStoreV1"')])
                self.assertEqual(db.execute("SELECT COUNT(*) FROM EngramOperationStoreV1").fetchone()[0], 0)
                with self.assertRaisesRegex(sqlite3.OperationalError, "no such function: sync_disabled"):
                    db.execute("SELECT sync_disabled()")

    def test_startup_identity_removal_refuses_unsafe_fixture_preconditions(self):
        for mutation in ("INSERT INTO EngramOperationReceiptV1 VALUES (1)",
                         "UPDATE EngramOperationStoreV1 SET singletonKey='other'",
                         "DROP TRIGGER AuditEngramOperationStoreV1Delete"):
            with self.subTest(mutation=mutation), self.temporary_directory() as directory:
                path = self.guarded_startup_fixture(directory)
                with contextlib.closing(sqlite3.connect(path)) as db:
                    db.execute(mutation)
                    db.commit()
                    before = list(db.iterdump())
                with self.assertRaises(AssertionError):
                    HARNESS.remove_fixture_store_identity(path)
                with contextlib.closing(sqlite3.connect(path)) as db:
                    self.assertEqual(list(db.iterdump()), before)

    def test_response_timeout_reports_effective_clamped_budget(self):
        for absolute, effective in ((102.0, 2.0), (None, 15.0), (99.0, 0.0)):
            with self.subTest(absolute=absolute):
                now = [100.0]
                client = HARNESS.Client.__new__(HARNESS.Client)
                client.deadline, client.messages, client.stderr = absolute, [], []
                client.process = Mock()
                client.process.poll.return_value = None
                def pump(timeout):
                    self.assertGreater(timeout, 0)
                    now[0] += timeout
                client.pump = pump
                with patch.object(HARNESS.time, "monotonic", side_effect=lambda: now[0]):
                    with self.assertRaisesRegex(AssertionError, rf"exceeded {effective:.3f}s effective budget \(requested 15s\)"):
                        client.response_message(1)
                self.assertAlmostEqual(now[0], 100 + effective)

    def fixture_run(self, dishonest=False):
        with self.temporary_directory() as directory:
            binary = self.fake_binary(directory, dishonest)
            with patch.dict(os.environ, {"TMPDIR": directory, "ENGRAM_URL": "must-not-be-inherited"}), contextlib.redirect_stdout(io.StringIO()) as output:
                HARNESS.run(binary, "persistence")
            return json.loads(output.getvalue())

    def test_three_real_client_processes_reopen_sqlite_and_recover(self):
        receipt = self.fixture_run()
        self.assertTrue(receipt["passed"])
        self.assertEqual(receipt["separate_process_reopens"], 2)
        self.assertEqual(len(set(receipt["process_ids"])), 3)
        self.assertEqual(receipt["clean_exits"], [0, 0, 0])
        self.assertEqual(receipt["process_group_ids"], [os.getpgrp()] * 3)
        self.assertTrue(receipt["rejected_write_absent"])
        for pid in receipt["process_ids"]:
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_client_gate_rejects_acknowledged_but_unpersisted_busy_write(self):
        with self.assertRaisesRegex(AssertionError, "Busy remember reported success"):
            self.fixture_run(dishonest=True)

    def hanging_binary(self, directory, receipt):
        binary = Path(directory) / "hanging-fake-mcp"
        binary.write_text("#!" + sys.executable + "\n" + textwrap.dedent(f'''\
            import json, os, signal, time
            from pathlib import Path
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            Path({str(receipt)!r}).write_text(json.dumps({{"pid": os.getpid(), "pgid": os.getpgrp()}}))
            while True:
                time.sleep(0.1)
        '''))
        binary.chmod(0o700)
        return binary

    def wait_receipt(self, path, process):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists():
                try:
                    return json.loads(path.read_text())
                except json.JSONDecodeError:
                    pass
            self.assertIsNone(process.poll(), "Verifier exited before native startup")
            time.sleep(0.02)
        self.fail("Fixture native did not report startup within 5s")

    def test_client_close_signals_only_owned_child_and_joins(self):
        with self.temporary_directory() as directory:
            receipt = Path(directory) / "native.json"
            binary = self.hanging_binary(directory, receipt)
            client = HARNESS.Client(binary, Path(directory) / "unused.sqlite", cwd=directory)
            try:
                state = self.wait_receipt(receipt, client.process)
                self.assertEqual(state["pgid"], os.getpgrp())
                # This must never target the caller's shared supervisor group.
                with patch.object(HARNESS.os, "killpg", side_effect=AssertionError("Client must not signal a group")):
                    client.close()
                self.assertEqual(client.process.returncode, -signal.SIGKILL)
                with self.assertRaises(ProcessLookupError):
                    os.kill(state["pid"], 0)
            finally:
                if client.process.poll() is None:
                    client.process.kill()
                    client.process.wait(timeout=2)

    def test_outer_group_cleans_native_after_verifier_sigkill(self):
        with self.temporary_directory() as directory:
            receipt = Path(directory) / "native.json"
            binary = self.hanging_binary(directory, receipt)
            env = dict(os.environ, TMPDIR=directory)
            # Only this test's outer supervisor establishes a new group.
            verifier = subprocess.Popen([sys.executable, "-B", str(ROOT / "verify-mcp-locks.py"),
                                          "--binary", str(binary), "--case", "persistence"],
                                         cwd=directory, env=env, start_new_session=True,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            group = verifier.pid
            state = None
            native_gone = False
            try:
                state = self.wait_receipt(receipt, verifier)
                self.assertEqual(os.getpgid(verifier.pid), group)
                self.assertEqual(state["pgid"], group)
                # SIGKILL cannot run a Python finally block or signal handler.
                verifier.kill()
                verifier.wait(timeout=2)
                self.assertEqual(verifier.returncode, -signal.SIGKILL)
                os.kill(state["pid"], 0)  # fake native deliberately ignores stdin EOF
                self.assertEqual(os.getpgid(state["pid"]), group)
                os.killpg(group, signal.SIGKILL)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    try:
                        os.killpg(group, 0)
                    except ProcessLookupError:
                        native_gone = True
                        break
                    time.sleep(0.02)
                else:
                    self.fail("Outer group cleanup did not remove the orphaned native")
            finally:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                verifier.wait(timeout=2)
                # Defensive cleanup also makes this regression safe when run
                # against the old escaping implementation: only its known PID.
                if state is not None and not native_gone:
                    try:
                        os.kill(state["pid"], signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main(verbosity=2)
