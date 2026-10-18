#!/usr/bin/env python3
"""Exercise the real MCP executable against disposable databases only."""

import argparse
from contextlib import closing, ExitStack
import ctypes
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import uuid


def bounded_text_tail(value, limit=16 * 1024):
    assert 0 < limit <= 16 * 1024
    raw = value if isinstance(value, bytes) else value.encode(errors="replace")
    # Replacement of invalid bytes can expand the decoded UTF-8 representation.
    text = raw[-limit:].decode(errors="replace")
    return text.encode()[-limit:].decode(errors="ignore")


class Client:
    def __init__(self, binary, db, *, environment=None, cwd=None, deadline=None):
        self.started = time.monotonic()
        self.deadline = deadline
        self.output_bytes = 0
        self.stderr = []
        self.buffers = {"stdout": b"", "stderr": b""}
        self.messages = []
        self.next_id = 0
        self.selector = selectors.DefaultSelector()
        env = dict(os.environ if environment is None else environment, CLAUDE_MEMORY_DB=str(db),
                   CLAUDE_SESSION_ID=f"mcp-lock-test-{os.getpid()}-{time.time_ns()}")
        self.process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env=env, cwd=cwd)
        # Inherit the verifier's supervised process group. A detached native
        # would escape the outer runner if Python itself received SIGKILL.
        for name in self.buffers:
            stream = getattr(self.process, name)
            os.set_blocking(stream.fileno(), False)
            self.selector.register(stream, selectors.EVENT_READ, name)

    def send(self, method, params=None, notification=False):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notification:
            self.next_id += 1
            message["id"] = self.next_id
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()
        return message.get("id")

    def pump(self, timeout):
        for key, _ in self.selector.select(timeout):
            data = os.read(key.fileobj.fileno(), 65536)
            if not data:
                self.selector.unregister(key.fileobj)
                continue
            name = key.data
            self.output_bytes += len(data)
            assert self.output_bytes <= 16 * 1024**2, "MCP output exceeded 16 MiB"
            self.buffers[name] += data
            while b"\n" in self.buffers[name]:
                line, self.buffers[name] = self.buffers[name].split(b"\n", 1)
                if name == "stderr":
                    self.stderr.append(line.decode(errors="replace"))
                elif line:
                    self.messages.append(json.loads(line))

    def response_message(self, request_id, timeout=15):
        response_started = time.monotonic()
        deadline = response_started + timeout
        if self.deadline is not None:
            deadline = min(deadline, self.deadline)
        effective_timeout = max(0, deadline - response_started)
        while time.monotonic() < deadline:
            for i, message in enumerate(self.messages):
                if message.get("id") == request_id:
                    self.messages.pop(i)
                    return message
            self.pump(min(0.1, max(0, deadline - time.monotonic())))
            if self.process.poll() is not None:
                raise AssertionError(f"MCP exited {self.process.returncode}: "
                                     + "\n".join(self.stderr[-12:]))
        raise AssertionError(f"MCP response exceeded {effective_timeout:.3f}s effective budget (requested {timeout}s): "
                             + "\n".join(self.stderr[-12:]))

    def response(self, request_id, timeout=15):
        message = self.response_message(request_id, timeout)
        assert "error" not in message, message
        return message["result"]

    def initialize(self, protocol_version="2025-03-26"):
        response = self.response(self.send("initialize", {
            "protocolVersion": protocol_version, "capabilities": {
                "experimental": {"codex": {"structured": True},
                                 "optional": None, "versions": [1, "v1"]}},
            "clientInfo": {"name": "engram-lock-regression", "version": "1"}}))
        assert response["serverInfo"]["name"] == "memory", response
        self.send("notifications/initialized", notification=True)
        return round(time.monotonic() - self.started, 3)

    def call(self, name, arguments, timeout=15):
        result = self.response(self.send("tools/call", {"name": name,
                                  "arguments": arguments}), timeout)
        if result.get("isError"):
            diagnostic_error = None
            try:
                self.pump(0)  # Observe ready diagnostics without extending the deadline.
            except Exception as error:
                diagnostic_error = bounded_text_tail(str(error), 4096)
            raise AssertionError(f"MCP tool {name} failed: {result}\nNative stderr tail:\n{self.stderr_tail()}"
                                 f"\nDiagnostic read error: {diagnostic_error}")
        return result

    def stderr_tail(self):
        raw = ("\n".join(self.stderr[-64:]) + "\n").encode(errors="replace") + self.buffers["stderr"]
        return bounded_text_tail(raw)

    def close(self, require_clean=False):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        forced = False
        try:
            deadline = time.monotonic() + 6
            while self.process.poll() is None and time.monotonic() < deadline:
                self.pump(min(0.1, max(0, deadline - time.monotonic())))
        finally:
            # Signal/join only our direct child. Group cleanup belongs to the
            # outer supervisor, whose group includes this verifier and native.
            for stop in (self.process.terminate, self.process.kill):
                if self.process.poll() is not None:
                    break
                forced = True
                try:
                    stop()
                except ProcessLookupError:
                    break
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
            self.process.wait(timeout=2)
            self.selector.close()
            self.process.stdout.close()
            self.process.stderr.close()
        assert self.process.returncode is not None, "Owned MCP child did not join"
        if require_clean:
            assert not forced, "MCP did not exit cleanly after stdin closed"
            assert self.process.returncode == 0, self.process.returncode


def close_warm_fixture(client, root, case, phase):
    """Retain bounded synthetic diagnostics in the supervisor log before temp cleanup."""
    failure = sys.exc_info()[1]
    cleanup_error = None
    try:
        if client is not None:
            client.close()
    except BaseException as error:
        cleanup_error = error
        if failure is None:
            raise
    finally:
        if failure is not None or cleanup_error is not None:
            # This runs only for the newly created, isolated warm fixtures.
            # Never copy a database, environment, or arbitrary home directory.
            record = {"case": case, "phase": phase, "synthetic_fixture_failure": True,
                      "error": bounded_text_tail(str(failure or cleanup_error), 4096),
                      "cleanup_error": None if cleanup_error is None else bounded_text_tail(str(cleanup_error), 4096),
                      "native_pid": None if client is None else client.process.pid,
                      "native_exit_code": None if client is None else client.process.poll(),
                      "native_stderr_tail": "" if client is None else client.stderr_tail(),
                      "fixture_files": [], "native_log_tails": []}
            try:
                for suffix in ("", "-wal", "-shm"):
                    path = root / ("memory.sqlite" + suffix)
                    if path.exists() and not path.is_symlink():
                        record["fixture_files"].append({"name": path.name, "bytes": path.stat().st_size})
                log_dir = root / "home/.claude/memory-logs"
                # Both sides must use the same path identity (e.g. macOS
                # /var and /private/var temporary-directory aliases).
                if log_dir.resolve().is_relative_to(root.resolve()) and log_dir.is_dir():
                    for index, path in enumerate(log_dir.glob("lattice-mcp-*.log")):
                        if index == 4:
                            break
                        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                        try:
                            metadata = os.fstat(descriptor)
                            if stat.S_ISREG(metadata.st_mode):
                                os.lseek(descriptor, max(0, metadata.st_size - 16 * 1024), os.SEEK_SET)
                                record["native_log_tails"].append({"name": path.name, "bytes": metadata.st_size,
                                    "tail": bounded_text_tail(os.read(descriptor, 16 * 1024))})
                        finally:
                            os.close(descriptor)
            except Exception as error:
                record["diagnostic_error"] = bounded_text_tail(str(error), 4096)
            print(json.dumps(record), file=sys.stderr, flush=True)

def tool_text(result):
    assert isinstance(result, dict) and not result.get("isError"), result
    parts = result.get("content", [])
    assert parts and all(part.get("type") == "text" for part in parts), result
    return "\n".join(part["text"] for part in parts)


def remembered_id(result):
    output = tool_text(result)
    match = re.search(r"Stored memory \(id:\s*([0-9A-Fa-f-]{36}),", output)
    assert match, f"Remember returned no successful identity: {output}"
    return str(uuid.UUID(match.group(1))).upper()


def assert_recalled_identity(result, expected_id, expected_content):
    blocks = tool_text(result).split("\n\n")
    marker = f"[id:{expected_id}] "
    matches = [block for block in blocks if block.startswith(marker)]
    assert len(matches) == 1, f"Expected one recalled identity {expected_id}: {blocks}"
    assert matches[0].endswith(") " + expected_content), matches[0]


def assert_failed_write(message):
    assert isinstance(message, dict) and message.get("jsonrpc") == "2.0", message
    assert message.get("id") is not None, message
    # Servers may report a tool execution error or a JSON-RPC error. Neither
    # may be mistaken for a successful remember acknowledgement.
    rpc_error = message.get("error")
    failed = (isinstance(rpc_error, dict) and isinstance(rpc_error.get("message"), str)) or (
        isinstance(message.get("result"), dict) and message["result"].get("isError") is True)
    assert failed, f"Busy remember reported success: {message}"
    assert "Stored memory (id:" not in json.dumps(message), message
    reason = rpc_error["message"] if isinstance(rpc_error, dict) else "\n".join(
        part.get("text", "") for part in message["result"].get("content", []))
    assert re.search(r"\b(?:busy|locked)\b", reason, re.IGNORECASE), f"Write failed for a different reason: {message}"


def persisted_memories(db):
    # Independent read-only connection: verifies committed storage, not the
    # MCP process's cache. db is always created inside this case's temp root.
    with closing(sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=1)) as reader:
        rows = reader.execute("SELECT globalId, content FROM Memory").fetchall()
    return {str(uuid.UUID(row[0])).upper(): row[1] for row in rows}


def operation_scope(client):
    result = client.call("operation_scope", {})
    envelope = json.loads(tool_text(result))
    assert result.get("structuredContent") == envelope, "Operation scope envelopes differ"
    assert set(envelope) == {"engram_operation"}, envelope
    payload = envelope["engram_operation"]
    assert set(payload) == {"version", "kind", "capability", "scope"}, payload
    assert payload["version"] == 1 and payload["kind"] == "scope", payload
    assert payload["capability"] == "localMutationOperationsV1", payload
    scope = payload["scope"]
    assert set(scope) == {"version", "storeID", "principal"} and scope["version"] == 1, scope
    uuid.UUID(scope["storeID"])
    return scope


def initialized_store_snapshot(db):
    # Only the native executable creates/registers this disposable fixture.
    # A smaller registry changes Lattice's schema fingerprint and would test
    # real schema work instead of reopening the existing runtime's store.
    expected_tables = {"Memory", "Edge", "Checkpoint", "HookState", "SessionState",
                       "SyncConfig", "EngramOperationStoreV1", "EngramOperationReceiptV1"}
    with closing(sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=1)) as reader:
        tables = {row[0] for row in reader.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        assert expected_tables <= tables, expected_tables - tables
        cookie = reader.execute("PRAGMA schema_version").fetchone()[0]
        fingerprints = reader.execute(
            "SELECT key, value FROM _lattice_meta WHERE key LIKE 'schema_fingerprint:%' ORDER BY key").fetchall()
        assert fingerprints and all(value == str(cookie) for _, value in fingerprints), {
            "schema_cookie": cookie, "fingerprints": fingerprints}
        stores = reader.execute(
            "SELECT singletonKey, storeID, formatVersion FROM EngramOperationStoreV1").fetchall()
        assert len(stores) == 1 and stores[0][0] == "local-operation-store" and stores[0][2] == 1, stores
        receipts = reader.execute("SELECT COUNT(*) FROM EngramOperationReceiptV1").fetchone()[0]
        assert receipts == 0, "Fixture must contain no operation receipts"
    return {"schema_cookie": cookie, "fingerprints": fingerprints, "stores": stores,
            "operation_receipts": receipts}


def remove_fixture_store_identity(db):
    # Only the disposable, native-created startup fixture calls this helper,
    # after its native child has exited. Keep the generated audit triggers:
    # sync_disabled() is connection state, and 1 disables this setup DELETE's
    # audit insertion without changing the persistent _SyncControl flag.
    expected_tables = {"Memory", "Edge", "Checkpoint", "HookState", "SessionState",
                       "SyncConfig", "EngramOperationStoreV1", "EngramOperationReceiptV1"}
    with closing(sqlite3.connect(db, timeout=2)) as setup:
        setup.execute("BEGIN IMMEDIATE")
        schema = setup.execute("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").fetchall()
        assert expected_tables <= {row[1] for row in schema if row[0] == "table"}, "Incomplete native fixture registry"
        guard = next((row[3] for row in schema if row[0] == "trigger" and
                      row[1] == "AuditEngramOperationStoreV1Delete"), None)
        assert guard and "WHEN (sync_disabled() = 0)" in guard, "Missing native DELETE audit guard"
        stores = setup.execute("SELECT singletonKey, storeID, formatVersion FROM EngramOperationStoreV1").fetchall()
        assert len(stores) == 1 and stores[0][0] == "local-operation-store" and stores[0][2] == 1, stores
        uuid.UUID(stores[0][1])
        assert setup.execute("SELECT COUNT(*) FROM EngramOperationReceiptV1").fetchone()[0] == 0, "Fixture has operation receipts"
        def preserved():
            return (setup.execute("PRAGMA schema_version").fetchone(),
                    setup.execute("SELECT key, value FROM _lattice_meta WHERE key LIKE 'schema_fingerprint:%' ORDER BY key").fetchall(),
                    setup.execute("SELECT id, disabled FROM _SyncControl ORDER BY id").fetchall(),
                    setup.execute("SELECT * FROM AuditLog ORDER BY id").fetchall(),
                    setup.execute("SELECT globalId, content FROM Memory ORDER BY globalId").fetchall(),
                    setup.execute("SELECT name, seq FROM sqlite_sequence ORDER BY name").fetchall())
        before = preserved()
        assert before[1] and before[2] == [(1, 0)] and len(before[4]) == 1, "Unexpected startup fixture state"
        setup.create_function("sync_disabled", 0, lambda: 1)
        deleted = setup.execute("DELETE FROM EngramOperationStoreV1 WHERE singletonKey = 'local-operation-store'")
        assert deleted.rowcount == 1, "Fixture identity removal was not exact"
        assert setup.execute("SELECT COUNT(*) FROM EngramOperationStoreV1").fetchone()[0] == 0
        assert preserved() == before, "Fixture setup changed protected state"
        assert setup.execute("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").fetchall() == schema
        setup.commit()


def assert_retained_writer(writer, db):
    assert writer.in_transaction, "Independent writer transaction was released"
    # A second connection confirms real SQLite writer exclusion, not just the
    # Python connection's transaction flag. Neither connection changes rows.
    with closing(sqlite3.connect(db, timeout=0)) as contender:
        try:
            contender.execute("BEGIN IMMEDIATE")
        except sqlite3.OperationalError as error:
            assert "locked" in str(error).lower(), error
        else:
            contender.rollback()
            raise AssertionError("Independent writer no longer excludes another writer")


def reopen_registered_fixture(binary, db, expected_scope, *, environment, cwd, deadline,
                              require_open_logs=None):
    # The first vector insert can create vec0 tables/triggers AFTER startup
    # stamped its schema fingerprints. One unlocked native reopen lets Core
    # validate/register that real schema before the warm contention baseline.
    # Never stamp markers ourselves or accept stale fingerprints under lock.
    client = Client(binary, db, environment=environment, cwd=cwd, deadline=deadline)
    closed = False
    try:
        client.initialize(protocol_version="2025-11-25")
        assert operation_scope(client) == expected_scope, "Fixture reopen changed store/principal scope"
        if require_open_logs is not None:
            require_open_logs(client)
        client.close(require_clean=True)
        closed = True
        return client.process.pid
    finally:
        if not closed:
            client.close()


def prepare_empty_seed(migration_binary, db, *, environment, cwd, deadline):
    # The MCP's background backstop is optional, not a readiness protocol.
    # Await the existing explicit native command on a new empty fixture first.
    assert migration_binary is not None and migration_binary.is_file(), "Warm fixtures require --migration-binary"
    assert db.parent.resolve() == Path(cwd).resolve(), "Migration database escaped fixture"
    assert time.monotonic() < deadline, "Migration exceeded the original seed deadline before launch"
    descriptor = os.open(db, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.close(descriptor)
    command = [str(migration_binary), "migrate-embeddings", "--db", str(db), "--force"]
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, env=environment, cwd=cwd)
    output = bytearray()
    selector = selectors.DefaultSelector()
    try:
        os.set_blocking(child.stdout.fileno(), False)
        selector.register(child.stdout, selectors.EVENT_READ)
        while selector.get_map() or child.poll() is None:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "Migration exceeded the original seed deadline"
            for key, _ in selector.select(min(0.1, remaining)):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                else:
                    output.extend(chunk)
                    assert len(output) <= 1024**2, "Migration output exceeded 1 MiB"
        child.wait(timeout=max(0.01, deadline - time.monotonic()))
        assert child.returncode == 0, f"Migration exited {child.returncode}"
        lines = output.decode(errors="replace").splitlines()
        assert lines.count("Embedding migration: complete — 0 re-embedded, vec index rebuilt") == 1, \
            "Migration did not report one complete zero-row sweep"
        assert lines.count("Done: 0 re-embedded, 0 failed.") == 1, "Migration reported incomplete/failed work"
        assert time.monotonic() < deadline, "Migration exceeded the original seed deadline"
        with closing(sqlite3.connect(db.as_uri() + "?mode=ro", uri=True,
                                     timeout=min(1, deadline - time.monotonic()))) as reader:
            assert reader.execute("SELECT COUNT(*) FROM Memory").fetchone()[0] == 0, "Migration fixture is not empty"
            marker = reader.execute("SELECT value FROM HookState WHERE key = ?", ("embedding.spaceVersion",)).fetchall()
            assert marker == [("2",)], "Migration did not persist the current embedding marker"
        assert time.monotonic() < deadline, "Migration exceeded the original seed deadline"
        return {"pid": child.pid, "clean_exit": child.returncode, "reembedded": 0, "failed": 0,
                "stored_embedding_version": 2}
    except BaseException:
        print(json.dumps({"fixture_migration_failed": True, "output_tail": bounded_text_tail(bytes(output))}),
              file=sys.stderr, flush=True)
        raise
    finally:
        # Join only this owned child; the outer supervisor owns descendants.
        for stop in (child.terminate, child.kill):
            if child.poll() is not None:
                break
            try:
                stop()
            except ProcessLookupError:
                break
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        child.wait(timeout=2)
        selector.close()
        child.stdout.close()


def run_warm_startup(binary, migration_binary=None):
    configured_tmp = os.environ.get("TMPDIR")
    assert configured_tmp and Path(configured_tmp).is_dir(), "warm-startup requires an existing owned TMPDIR"
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="engram-mcp-warm-startup-", dir=configured_tmp) as directory:
        root = Path(directory).resolve()
        db = root / "memory.sqlite"
        for path in (root / "home", root / "home/.codex", root / "tmp"):
            path.mkdir(parents=True, exist_ok=True)
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C",
               "CFFIXED_USER_HOME": str(root / "home"), "TMPDIR": str(root / "tmp") + "/"}
        # Preserve account environment; Foundation and the explicit database
        # select this disposable fixture's paths.
        for name in ("HOME", "CODEX_HOME"):
            if name in os.environ:
                env[name] = os.environ[name]
        client = None
        cases = []
        token = uuid.uuid4().hex
        content = f"Warm startup keeper {token}: retain this exact identity and content under an independent writer."
        phase = "seed_embedding_migration"
        try:
            migration = prepare_empty_seed(migration_binary, db, environment=env, cwd=root,
                                           deadline=started + 60)
            # A real initial process registers the complete production schema
            # and initializes the store. The remember also exercises normal
            # model readiness before any lock is acquired.
            phase = "seed_initialize"
            client = Client(binary, db, environment=env, cwd=root, deadline=started + 60)
            client.initialize(protocol_version="2025-11-25")
            phase = "seed_remember"
            identity = remembered_id(client.call("remember", {
                "content": content, "project": "WarmStartupRegression", "force": True}, timeout=60))
            phase = "seed_scope_and_reopen"
            expected_scope = operation_scope(client)
            client.close(require_clean=True)
            warm_pid = client.process.pid
            client = None
            assert persisted_memories(db) == {identity: content}
            reopen_pid = reopen_registered_fixture(binary, db, expected_scope,
                environment=env, cwd=root, deadline=started + 60)
            expected_store = initialized_store_snapshot(db)
            assert expected_store["stores"][0][1] == expected_scope["storeID"].lower()
            assert persisted_memories(db) == {identity: content}

            for slot_count in (0, 1):
                phase = f"slot_setup_{slot_count}"
                # The synthetic slot triggers Core's non-fatal sync-state
                # healing admission on reopen. No schema change is made, and
                # no pending sync work or production configuration is used.
                with closing(sqlite3.connect(db, timeout=1)) as setup:
                    assert setup.execute("SELECT COUNT(*) FROM _lattice_replication_slots").fetchone()[0] == 0
                    if slot_count:
                        setup.execute("INSERT INTO _lattice_replication_slots(sync_id) VALUES (?)",
                                      ("warm-startup-regression-" + token,))
                        setup.commit()
                assert initialized_store_snapshot(db) == expected_store

                with closing(sqlite3.connect(db, timeout=1)) as writer:
                    writer.execute("BEGIN IMMEDIATE")
                    try:
                        assert_retained_writer(writer, db)
                        phase = f"held_writer_{slot_count}_slots"
                        attempt_started = time.monotonic()
                        # Match the production operation probe: a single 10s
                        # budget covers launch, initialize and scope. Cleanup
                        # retains the independent lock and has its own bound.
                        client = Client(binary, db, environment=env, cwd=root,
                                        deadline=attempt_started + 10)
                        initialize_seconds = client.initialize(protocol_version="2025-11-25")
                        assert operation_scope(client) == expected_scope, "Store/principal scope changed"
                        protocol_seconds = time.monotonic() - attempt_started
                        assert protocol_seconds < 10, "Warm startup exceeded production probe budget"
                        assert_retained_writer(writer, db)
                        assert initialized_store_snapshot(db) == expected_store
                        assert persisted_memories(db) == {identity: content}
                        client.close(require_clean=True)
                        assert_retained_writer(writer, db)
                        cases.append({"replication_slots": slot_count,
                                      "initialize_seconds": initialize_seconds,
                                      "protocol_seconds": round(protocol_seconds, 3),
                                      "pid": client.process.pid, "clean_exit": client.process.returncode,
                                      "writer_retained_through_scope_and_shutdown": True})
                        client = None
                    finally:
                        # Reap an owned child before releasing the lock even
                        # when an assertion/deadline fails.
                        if client is not None:
                            client.close()
                            client = None
                        writer.rollback()
                assert initialized_store_snapshot(db) == expected_store
                assert persisted_memories(db) == {identity: content}
            assert len({warm_pid, reopen_pid, *(case["pid"] for case in cases)}) == 4
            print(json.dumps({"case": "warm-startup", "passed": True,
                              "seconds": round(time.monotonic() - started, 3),
                              "full_model_registry": True, "scope_unchanged": True,
                              "store_and_fingerprints_unchanged": True,
                              "migration": migration,
                              "warmup_pid": warm_pid, "schema_reopen_pid": reopen_pid,
                              "cases": cases}), flush=True)
        finally:
            close_warm_fixture(client, root, "warm-startup", phase)


def optional_store_snapshot(db, expected_tables):
    # Schema was established by the actual CLI's optional-store branch. Never
    # open an optional store through a local-ledger model registration fixture.
    with closing(sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=1)) as reader:
        tables = {row[0] for row in reader.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        assert expected_tables <= tables, expected_tables - tables
        assert not {"EngramOperationStoreV1", "EngramOperationReceiptV1"} & tables, tables
        cookie = reader.execute("PRAGMA schema_version").fetchone()[0]
        fingerprints = reader.execute(
            "SELECT key, value FROM _lattice_meta WHERE key LIKE 'schema_fingerprint:%' ORDER BY key").fetchall()
        assert fingerprints and all(value == str(cookie) for _, value in fingerprints), {
            "schema_cookie": cookie, "fingerprints": fingerprints}
    return {"tables": sorted(tables), "schema_cookie": cookie, "fingerprints": fingerprints}


def require_optional_open_logs(client, synced, groups):
    # Startup logs prove that the CLI entered each optional store successfully;
    # local operation_scope cannot prove optional-store read visibility.
    messages = [f"Synced database at {synced}"]
    messages += [f"Group spoke {identity} at {path}" for identity, path in groups]
    client.pump(0)
    for message in messages:
        assert any(line.endswith(message) for line in client.stderr), f"Missing optional-open receipt: {message}"


def run_warm_multistore_startup(binary, migration_binary=None):
    configured_tmp = os.environ.get("TMPDIR")
    assert configured_tmp and Path(configured_tmp).is_dir(), "warm-multistore-startup requires an existing owned TMPDIR"
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="engram-mcp-warm-multistore-", dir=configured_tmp) as directory:
        root = Path(directory).resolve()
        db = root / "memory.sqlite"
        for path in (root / "home", root / "home/.codex", root / "tmp", root / "sync"):
            path.mkdir(mode=0o700, parents=True, exist_ok=True)
        synced = root / "sync/memory-synced.sqlite"
        groups = [(str(uuid.uuid4()).upper(), None) for _ in range(2)]
        groups = [(identity, root / "sync" / f"group-{identity}.sqlite") for identity, _ in groups]
        optional = [(synced, {"Memory", "Edge", "SyncConfig"})]
        optional += [(path, {"Memory", "Edge", "GroupProjectMap"}) for _, path in groups]
        for path, _ in optional:
            # Existence activates CLI discovery. Only the real executable may
            # establish schema; these new exclusive regular files are empty.
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            os.close(descriptor)
            assert path.stat().st_size == 0
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C",
               "CFFIXED_USER_HOME": str(root / "home"), "TMPDIR": str(root / "tmp") + "/"}
        for name in ("HOME", "CODEX_HOME"):
            if name in os.environ:
                env[name] = os.environ[name]
        token = uuid.uuid4().hex
        content = f"Multi-store startup keeper {token}: retain this local identity under independent writers on every store."
        stores = [db, synced, *(path for _, path in groups)]
        client = None
        phase = "seed_embedding_migration"
        try:
            migration = prepare_empty_seed(migration_binary, db, environment=env, cwd=root,
                                           deadline=started + 60)
            phase = "seed_initialize"
            client = Client(binary, db, environment=env, cwd=root, deadline=started + 60)
            client.initialize(protocol_version="2025-11-25")
            phase = "seed_remember"
            identity = remembered_id(client.call("remember", {
                "content": content, "project": "WarmMultistoreStartupRegression", "force": True}, timeout=60))
            phase = "seed_scope_and_reopen"
            expected_scope = operation_scope(client)
            require_optional_open_logs(client, synced, groups)
            client.close(require_clean=True)
            warm_pid = client.process.pid
            client = None
            assert persisted_memories(db) == {identity: content}
            reopen_pid = reopen_registered_fixture(binary, db, expected_scope,
                environment=env, cwd=root, deadline=started + 60,
                require_open_logs=lambda opened: require_optional_open_logs(opened, synced, groups))
            expected_local = initialized_store_snapshot(db)
            assert expected_local["stores"][0][1] == expected_scope["storeID"].lower()
            expected_optional = {path: optional_store_snapshot(path, tables) for path, tables in optional}
            expected_memories = {path: persisted_memories(path) for path in stores}
            assert expected_memories[db] == {identity: content}
            assert all(expected_memories[path] == {} for path, _ in optional)

            expected_slots = {}
            phase = "slot_setup"
            for index, path in enumerate(stores):
                with closing(sqlite3.connect(path, timeout=1)) as setup:
                    assert setup.execute("SELECT COUNT(*) FROM _lattice_replication_slots").fetchone()[0] == 0
                    slot = f"warm-multistore-regression-{token}-{index}"
                    setup.execute("INSERT INTO _lattice_replication_slots(sync_id) VALUES (?)", (slot,))
                    setup.commit()
                    expected_slots[path] = setup.execute(
                        "SELECT sync_id, confirmed_audit_id, last_active_at, upload_floor FROM _lattice_replication_slots").fetchall()

            def assert_stores_unchanged():
                assert initialized_store_snapshot(db) == expected_local
                for path, tables in optional:
                    assert optional_store_snapshot(path, tables) == expected_optional[path]
                for path in stores:
                    assert persisted_memories(path) == expected_memories[path]
                    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=1)) as reader:
                        assert reader.execute(
                            "SELECT sync_id, confirmed_audit_id, last_active_at, upload_floor FROM _lattice_replication_slots").fetchall() == expected_slots[path]

            assert_stores_unchanged()
            # The stack owns all four writer connections. Cleanup/child join
            # finishes before stack callbacks roll back any independent lock.
            with ExitStack() as stack:
                writers = []
                for path in stores:
                    writer = stack.enter_context(closing(sqlite3.connect(path, timeout=1)))
                    writer.execute("BEGIN IMMEDIATE")
                    stack.callback(writer.rollback)
                    writers.append((writer, path))
                    assert_retained_writer(writer, path)
                try:
                    phase = "held_writers_four_stores"
                    attempt_started = time.monotonic()
                    client = Client(binary, db, environment=env, cwd=root,
                                    deadline=attempt_started + 10)
                    initialize_seconds = client.initialize(protocol_version="2025-11-25")
                    assert operation_scope(client) == expected_scope, "Local store/principal scope changed"
                    protocol_seconds = time.monotonic() - attempt_started
                    assert protocol_seconds < 10, "Multi-store startup exceeded production probe budget"
                    require_optional_open_logs(client, synced, groups)
                    for writer, path in writers:
                        assert_retained_writer(writer, path)
                    assert_stores_unchanged()
                    client.close(require_clean=True)
                    locked_pid = client.process.pid
                    clean_exit = client.process.returncode
                    client = None
                    for writer, path in writers:
                        assert_retained_writer(writer, path)
                finally:
                    if client is not None:
                        client.close()
                        client = None
            assert_stores_unchanged()
            assert len({warm_pid, reopen_pid, locked_pid}) == 3
            print(json.dumps({"case": "warm-multistore-startup", "passed": True,
                              "seconds": round(time.monotonic() - started, 3),
                              "stores": 4, "group_stores": 2, "synthetic_replication_slots_per_store": 1,
                              "initial_and_locked_optional_open_receipts": True,
                              "optional_schema_fingerprints_unchanged": True,
                              "optional_ledger_tables_absent": True,
                              "local_scope_unchanged": True, "optional_read_visibility_verified": False,
                              "writers_retained_through_scope_and_shutdown": True,
                              "initialize_seconds": initialize_seconds,
                              "protocol_seconds": round(protocol_seconds, 3),
                              "warmup_pid": warm_pid, "schema_reopen_pid": reopen_pid,
                              "locked_pid": locked_pid,
                              "migration": migration,
                              "clean_exit": clean_exit}), flush=True)
        finally:
            close_warm_fixture(client, root, "warm-multistore-startup", phase)


def run_persistence(binary):
    configured_tmp = os.environ.get("TMPDIR")
    assert configured_tmp and Path(configured_tmp).is_dir(), "persistence requires an existing owned TMPDIR"
    started = time.monotonic()
    deadline = started + 120
    with tempfile.TemporaryDirectory(prefix="engram-mcp-persistence-", dir=configured_tmp) as directory:
        root = Path(directory).resolve()
        db = root / "memory.sqlite"
        for path in (root / "home", root / "home/.codex", root / "tmp"):
            path.mkdir(parents=True, exist_ok=True)
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C",
               "HOME": str(root / "home"), "CFFIXED_USER_HOME": str(root / "home"),
               "CODEX_HOME": str(root / "home/.codex"), "TMPDIR": str(root / "tmp") + "/"}
        token = uuid.uuid4().hex
        original = f"Persistence keeper {token}: retain this exact identity and content across process reopen."
        rejected = f"Persistence rejected {token}: this busy write must never be stored."
        recovered = f"Persistence recovery {token}: writes succeed after the owned lock is released."
        project = "PersistenceRegression"
        client = None
        process_ids = []
        process_group_ids = []
        clean_exits = []

        def open_client():
            assert time.monotonic() < deadline, "Persistence case exceeded 120s"
            result = Client(binary, db, environment=env, cwd=root, deadline=deadline)
            process_ids.append(result.process.pid)
            process_group_ids.append(os.getpgid(result.process.pid))
            return result

        def close_clean():
            nonlocal client
            client.close(require_clean=True)
            clean_exits.append(client.process.returncode)
            client = None

        def recall_content(expected_id, content):
            result = client.call("recall", {"query": content, "project": project,
                                            "limit": 5, "depth": 0})
            assert_recalled_identity(result, expected_id, content)

        try:
            # Writer process must close cleanly before a second process opens.
            client = open_client()
            client.initialize()
            original_id = remembered_id(client.call("remember", {
                "content": original, "project": project, "force": True}))
            close_clean()
            assert persisted_memories(db) == {original_id: original}

            client = open_client()
            client.initialize()
            recall_content(original_id, original)
            with closing(sqlite3.connect(db, timeout=1)) as writer:
                writer.execute("BEGIN IMMEDIATE")
                try:
                    busy_started = time.monotonic()
                    request_id = client.send("tools/call", {"name": "remember", "arguments": {
                        "content": rejected, "project": project, "force": True}})
                    failed = client.response_message(request_id, timeout=9)
                    assert_failed_write(failed)
                    busy_seconds = time.monotonic() - busy_started
                    assert busy_seconds < 6, f"Busy remember took {busy_seconds:.3f}s"
                    assert persisted_memories(db) == {original_id: original}
                finally:
                    writer.rollback()
            recovered_id = remembered_id(client.call("remember", {
                "content": recovered, "project": project, "force": True}))
            assert recovered_id != original_id
            close_clean()

            # A third process proves recovery was committed, not only visible
            # in the process that acknowledged the successful retry.
            client = open_client()
            client.initialize()
            recall_content(original_id, original)
            recall_content(recovered_id, recovered)
            close_clean()
            rows = persisted_memories(db)
            assert rows == {original_id: original, recovered_id: recovered}, rows
            assert len(set(process_ids)) == 3, process_ids
            assert process_group_ids == [os.getpgrp()] * 3, "Native escaped the verifier's supervised process group"
            assert time.monotonic() < deadline, "Persistence case exceeded 120s"
            print(json.dumps({"case": "persistence", "passed": True,
                              "seconds": round(time.monotonic() - started, 3),
                              "process_ids": process_ids, "clean_exits": clean_exits,
                              "process_group_ids": process_group_ids,
                              "original_id": original_id, "recovered_id": recovered_id,
                              "busy_write_seconds": round(busy_seconds, 3),
                              "rejected_write_absent": True, "separate_process_reopens": 2}), flush=True)
        finally:
            if client is not None:
                client.close()


def read_lock_holders(db):
    if os.uname().sysname != "Darwin":
        return None

    class Flock(ctypes.Structure):
        _fields_ = [("start", ctypes.c_longlong), ("length", ctypes.c_longlong),
                    ("pid", ctypes.c_int), ("type", ctypes.c_short),
                    ("whence", ctypes.c_short)]

    with open(str(db) + "-shm", "rb") as file:
        holders = {}
        for byte in range(123, 128):
            probe = Flock(byte, 1, 0, fcntl.F_WRLCK, os.SEEK_SET)
            result = Flock.from_buffer_copy(fcntl.fcntl(file.fileno(), fcntl.F_GETLK,
                                                       bytes(probe)))
            if result.type != fcntl.F_UNLCK:
                holders[byte] = result.pid
        return holders


def run(binary, case, migration_binary=None):
    if case == "persistence":
        return run_persistence(binary)
    if case == "warm-startup":
        return run_warm_startup(binary, migration_binary)
    if case == "warm-multistore-startup":
        return run_warm_multistore_startup(binary, migration_binary)
    with tempfile.TemporaryDirectory(prefix="engram-mcp-locks-") as directory:
        db = Path(directory) / "memory.sqlite"
        client = Client(binary, db)
        try:
            elapsed = client.initialize()
            tools = client.response(client.send("tools/list"))["tools"]
            assert any(tool["name"] == "recall" for tool in tools)
            print(json.dumps({"initialize_seconds": elapsed, "tools": len(tools)}), flush=True)
            arguments = {"query": "isolated database contention regression",
                         "project": "LockRegression", "limit": 1, "depth": 0}
            client.call("remember", {"content": "Isolated database contention regression fixture.",
                                      "project": "LockRegression", "force": True})
            client.call("recall", arguments)
            time.sleep(0.25)
            holders = read_lock_holders(db)
            print(json.dumps({"idle_read_lock_holders": holders}), flush=True)
            if case == "idle":
                assert not holders, f"Idle MCP retains WAL read locks: {holders}"
            if case == "recall":
                with sqlite3.connect(db, timeout=2) as writer:
                    writer.execute("BEGIN IMMEDIATE")
                    started = time.monotonic()
                    result = client.call("recall", arguments, timeout=9)
                    assert "Isolated database contention" in json.dumps(result), result
                    elapsed = time.monotonic() - started
                    assert elapsed < 6, elapsed
                    print(json.dumps({"locked_recall_seconds": round(elapsed, 3)}), flush=True)
                    writer.rollback()
                client.call("recall", arguments)
            client.close(require_clean=True)
            client = None
            if case == "startup":
                # Preserve the write-required startup refusal case. A fully
                # bootstrapped store now correctly reopens without writer
                # admission (covered separately by warm-startup). Only this
                # disposable zero-receipt fixture loses its initial identity;
                # all eight registered models/fingerprints remain intact.
                remove_fixture_store_identity(db)
                with sqlite3.connect(db, timeout=2) as writer:
                    writer.execute("BEGIN IMMEDIATE")
                    client = Client(binary, db)
                    deadline = time.monotonic() + 8
                    while client.process.poll() is None and time.monotonic() < deadline:
                        client.pump(0.1)
                    assert client.process.poll() is not None, "Locked startup exceeded 8s"
                    assert client.process.returncode != 0, "Locked database unexpectedly opened"
                    assert any("Failed to initialize database" in line for line in client.stderr), client.stderr
                    print(json.dumps({"locked_startup_exit": client.process.returncode,
                                      "seconds": round(time.monotonic() - client.started, 3)}), flush=True)
                    writer.rollback()
                client.close()
                client = Client(binary, db)
                client.initialize()
                client.close(require_clean=True)
                client = None
            print(json.dumps({"case": case, "passed": True}), flush=True)
        finally:
            if client:
                client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--migration-binary", type=Path,
                        help="Explicit memory-sync/EngramDaemon executable; required by the two warm fixtures")
    parser.add_argument("--case", choices=["smoke", "idle", "recall", "startup", "warm-startup", "warm-multistore-startup", "persistence"], default="smoke")
    args = parser.parse_args()
    run(args.binary.resolve(), args.case,
        args.migration_binary.resolve() if args.migration_binary is not None else None)
