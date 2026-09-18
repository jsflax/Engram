"""Client/fixture checks only; does not execute an Engram native product."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch

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

    def fake_binary(self, directory, dishonest=False):
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
                    else:
                        rows = db.execute("SELECT globalId, content FROM Memory").fetchall()
                        result = {"content": [{"type": "text", "text": "\\n\\n".join("[id:" + identity + "] [Test/general] (distance: 0.100) " + content for identity, content in rows)}]}
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
            db.close()
        ''').replace("DISHONEST", repr(dishonest))
        binary = Path(directory) / "fake-mcp"
        binary.write_text("#!" + sys.executable + "\n" + program)
        binary.chmod(0o700)
        return binary

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
