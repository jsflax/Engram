"""Shared disposable legacy evidence fixture; no provider or live-state access."""
from __future__ import annotations

import copy
from contextlib import closing
import datetime as dt
import hashlib
import importlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
import tempfile
import uuid

TEST_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = TEST_ROOT.parents[1]
PLUGIN = REPOSITORY_ROOT / "codex/plugins/engram"
SID = "019b7a00-0000-7123-8000-000000000021"
ACTIVATION = "21111111-2222-4333-8444-555555555555"
SUCCESS_ID = "41111111-2222-4333-8444-555555555555"
DUPLICATE_ID = "71111111-2222-4333-8444-555555555555"
RUN_ID = "20260103T083200Z-b8af2a1f05fd497394bd99ea768a54cb"
PREVIOUS_RUN = "20260103T073200Z-a8af2a1f05fd497394bd99ea768a54cb"
HISTORICAL_REQUEST = "8d4d4a6e4e63447e90f9ee7229373c6e"


def encode(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=False, allow_nan=False) + "\n").encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def write_json(path, value, *, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(encode(value))
    path.chmod(mode)


def load_runtime():
    """Import the assembled repository plugin, never a candidate overlay."""
    sys.dont_write_bytecode = True
    if str(PLUGIN / "scripts") not in sys.path:
        sys.path.insert(0, str(PLUGIN / "scripts"))
    module = importlib.import_module("codex_learner.legacy_reconciliation")
    expected = PLUGIN / "scripts/codex_learner/legacy_reconciliation.py"
    if Path(module.__file__).resolve() != expected.resolve():
        raise RuntimeError("Legacy acceptance must use the repository plugin")
    return module


class LegacyFixture:
    """One V2 origin, a failed legacy run, six messages, and two expired rows."""

    def __init__(self, module=None, *, fixture_parent=None):
        self.L = module or load_runtime()
        L, A, H, C = self.L, self.L.admission, self.L.host_admission, self.L.context
        if fixture_parent is None:
            parent = TEST_ROOT / ".tmp"
            if parent.is_symlink():
                raise RuntimeError("The fixture directory must not be a symlink")
            parent.mkdir(mode=0o700, exist_ok=True)
        else:
            parent = Path(fixture_parent)
            if not parent.is_absolute() or parent.resolve(strict=True) != parent:
                raise ValueError("fixture_parent must be an existing canonical absolute directory")
            info = parent.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError("fixture_parent must be an owned private directory")
        self.temp = tempfile.TemporaryDirectory(prefix="legacy-acceptance-", dir=parent)
        self.base = Path(self.temp.name).resolve()
        self.base.chmod(0o700)
        self.root, self.sessions, self.project, self.evidence = [self.base / name for name in
            ("learner", "sessions", "project", "evidence")]
        for path in (self.root, self.sessions, self.project, self.evidence):
            path.mkdir(mode=0o700)
        for name in ("enrollments", "admissions", "sessions", "pending", "runs", "publications"):
            (self.root / name).mkdir(mode=0o700)
        for path in (self.root / "worker.lock", self.base / "learner-provider.lock", self.root / "enqueue.lock"):
            path.write_bytes(b"")
            path.chmod(0o600)
        self.path = self.sessions / "2026/01/02" / ("rollout-2026-01-02T00-00-00-" + SID + ".jsonl")
        write_json(self.path, {"type": "session_meta", "payload": {
            "id": SID, "timestamp": "2026-01-02T00:00:00Z", "cwd": str(self.project),
            "source": "vscode", "cli_version": "fixture", "history_mode": "paginated"}})
        self.append("Unselected older context.")
        self.policy = {"schema_version": 2, "mode": H.MODE_V2, "enabled": True,
            "activation_id": ACTIVATION, "cutoff": "2026-01-01T00:00:00Z", "state_dir": str(self.root),
            "sessions_dir": A._directory_binding(self.sessions, stable_identity=True)}
        write_json(self.root / "admission.json", self.policy)
        payload = {"session_id": SID, "transcript_path": str(self.path), "cwd": str(self.project)}
        origin = H._origin(self.policy, payload)
        self.enrollment = {**origin, **A._frontier(origin), "activation_id": ACTIVATION,
                           "captured_at": "2026-01-03T00:00:00Z"}
        self.enrollment_path = self.root / "enrollments" / (SID + ".json")
        write_json(self.enrollment_path, self.enrollment)
        self.frontier = self.enrollment["frontier_offset"]
        self.append("Previous successfully processed fixture message.")
        previous_excerpt = L.transcript.read_excerpt(self.path, self.frontier, max_chars=4000,
                                                     max_scan_bytes=20000, stable_identity=True)
        self.start = previous_excerpt.next_offset
        self.messages = [
            "PRIVATE reviewed statement already represented by an expired row.",
            "PRIVATE dated progress report two.",
            "PRIVATE dated progress report three.",
            "PRIVATE dated progress report four.",
            "PRIVATE statement accounted for by the two historical intents.",
            "PRIVATE dated progress report six."]
        for message in self.messages:
            self.append(message)
        self.request = {**payload, "hook_session_id": SID, "hook_cwd": str(self.project),
            "event": "Stop", "turn_id": "selected-turn", "request_id": "current-stop-request",
            "identity": self.enrollment["identity"], "historical_request_id": HISTORICAL_REQUEST,
            "pause_reason": "batch_limit", "paused_request_id": "current-stop-request",
            "queued_at": "2026-01-03T08:40:00Z", "fixture_provenance": "preserve-this-exactly"}
        self.request["admission"] = A.check(self.root, self.request)
        self.state = {"session_id": SID, "transcript_path": str(self.path), "identity": self.enrollment["identity"],
            **C._next_parser(previous_excerpt), "admission": self.request["admission"],
            "status": "reconciliation_required", "last_run": RUN_ID,
            "last_success_at": "2026-01-03T07:33:00Z",
            "last_excerpt_sha256": digest(previous_excerpt.text.encode()),
            "unrelated_field": {"keep": [1, 2]},
            "reconciliation_required": {"run_id": RUN_ID, "reason": "successful_or_unverified_write",
                                        "memory_ids": [SUCCESS_ID]}}
        self.record = {"binding": self.request["admission"], "state_sha256": L.durable.object_digest(self.state),
                       "last_event": "a" * 64, "processing": None}
        self.state_path = self.root / "sessions" / (SID + ".json")
        self.record_path = self.root / "admissions" / (SID + ".json")
        self.pending_path = self.root / "pending" / (SID + ".json")
        for path, value in ((self.state_path, self.state), (self.record_path, self.record),
                            (self.pending_path, self.request)):
            write_json(path, value)
        self.excerpt = L.transcript.read_excerpt(self.path, self.start, max_chars=4000, max_scan_bytes=20000,
            recent_messages=self.state["recent_messages"], current_turn_id=self.state["current_turn_id"],
            stable_identity=True)
        self.end = self.excerpt.next_offset
        self.store = self.base / "memory.sqlite"
        self.row_values = [self.memory(SUCCESS_ID, "PRIVATE original successfully stored fixture content."),
                           self.memory(DUPLICATE_ID, "PRIVATE qualified duplicate for first selected message.")]
        with closing(sqlite3.connect(self.store)) as db:
            db.execute('CREATE TABLE Memory (id INTEGER PRIMARY KEY, globalId TEXT, content TEXT, project TEXT, '
                       'topic TEXT, source TEXT, isPrivate INTEGER, createdAt REAL, modifiedAt REAL, '
                       'expiresAt REAL, deletedAt REAL, accessCount INTEGER, lastAccessedAt REAL)')
            for i, row in enumerate(self.row_values, 1):
                db.execute('INSERT INTO Memory VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
                           (i, *[row[key] for key in L.ROW_FIELDS], 7, 1767429190.0))
            db.commit()
        self.store.chmod(0o600)
        self.paths = L.LegacyPaths(self.root, self.evidence, PLUGIN, self.store)
        self.run_dir, self.previous_dir = self.root / "runs" / RUN_ID, self.root / "runs" / PREVIOUS_RUN
        self.run_dir.mkdir(mode=0o700)
        self.previous_dir.mkdir(mode=0o700)
        self.history = self.historical_files()
        for role, name in L.ROLES.items():
            path = self.run_dir / name
            path.write_bytes(self.history[role])
            path.chmod(0o644 if role == "result" else 0o600)
        (self.previous_dir / "run.json").write_bytes(self.history["previous_run"])
        (self.previous_dir / "run.json").chmod(0o600)
        chunks = ["[ASSISTANT]\n" + message for message in self.messages]
        info = self.store.stat()
        self.review = {"version": 1, "kind": "reviewed_legacy_no_new_mutation", "session_id": SID,
            "legacy_run_id": RUN_ID, "previous_run_id": PREVIOUS_RUN, "historical_request_id": HISTORICAL_REQUEST,
            "source": {"identity": self.enrollment["identity"], "start_offset": self.start, "end_offset": self.end,
                "interval_sha256": digest(self.path.read_bytes()[self.start:self.end]),
                "excerpt_sha256": digest(self.excerpt.text.encode())},
            "parser": {"input": C._parser_state(self.state), "next": C._next_parser(self.excerpt),
                       "runtime_sha256": C._parser_runtime()["sha256"], "max_chars": 4000},
            "messages": [{"index": i, "role": "assistant", "sha256": digest(chunk.encode()),
                "disposition": "already_represented_expired" if i == 1 else
                    "original_intents_accounted" if i == 5 else "dated_progress",
                "memory_ids": [DUPLICATE_ID] if i == 1 else [SUCCESS_ID] if i == 5 else []}
                for i, chunk in enumerate(chunks, 1)],
            "attempts": self.attempts, "rows": [self.row_readback(row) for row in self.row_values],
            "store_identity": {"device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid},
            "preserved_memory_ids": [SUCCESS_ID], "artifacts": {},
            "history": {role: digest(raw) for role, raw in self.history.items()},
            "qualifications": {"historical_run_status": "failed", "historical_execution_sealed": False,
                "source_binding_grade": "current_bounded_reconstruction", "current_cross_provider_capability": "unverified"}}
        self.write_assessments()
        self.write_review()
        self.reconciliation_id = str(uuid.uuid4())

    def close(self):
        self.temp.cleanup()

    def append(self, message):
        with self.path.open("ab") as stream:
            stream.write(encode({"type": "event_msg", "payload": {"type": "agent_message", "message": message}}))

    def memory(self, identifier, content):
        created = dt.datetime(2026, 1, 3, 8, 32, 59, tzinfo=dt.timezone.utc).timestamp()
        return {"globalId": identifier, "content": content, "project": "fixture-project", "topic": "fixture-topic",
                "source": "codex-session:" + SID, "isPrivate": 1, "createdAt": created,
                "modifiedAt": created, "expiresAt": created + 14 * 86400, "deletedAt": None}

    def row_readback(self, row):
        result = copy.deepcopy(row)
        result["content_sha256"] = digest(result.pop("content").encode())
        return result

    def historical_files(self):
        L = self.L
        provider = [{"type": "thread.started", "thread_id": SID}, {"type": "turn.started"}]
        audit, self.attempts = [{"event": "relay_started"}], []
        for index, tool in enumerate(("stats", "remember", "remember"), 1):
            args = {} if tool == "stats" else {"content": self.row_values[0]["content"] if index == 2
                else "PRIVATE failed-BEGIN intent with expired relative validity.", "project": "fixture-project",
                "topic": "fixture-topic", "source": "codex-session:" + SID, "is_private": True, "force": False,
                "expires_in_days": 14}
            item = {"id": "tool-" + str(index), "type": "mcp_tool_call", "server": "memory",
                    "tool": tool, "arguments": args}
            result = {"content": [{"type": "text", "text": "fixture result"}]}
            if index == 3:
                result = {"structured_content": {"engram_write_receipt": {"schema_version": 1,
                    "tool": "remember", "memory_ids": [], "reason": "database_busy",
                    "write_outcome": "not_stored_transaction_not_started"}}}
            provider.extend([{"type": "item.started", "item": item},
                             {"type": "item.completed", "item": {**item, "result": result}}])
            audit.extend([{"event": "tool_call", "id": index, "tool": tool},
                          {"event": "tool_result", "id": index, "tool": tool, "forwarded": True,
                           "ok": index != 3, "memory_ids": [SUCCESS_ID] if index == 2 else [],
                           **({"write_outcome_version": 1, "write_outcome": "not_stored_transaction_not_started"}
                              if index == 3 else {})}])
            if tool == "remember":
                self.attempts.append({"item_id": item["id"], "audit_id": index,
                    "arguments_sha256": digest(L.codec.encode(args)), "native_result_sha256": digest(L.codec.encode(result)),
                    "disposition": "original_success_preserved" if index == 2 else "original_no_write_expired",
                    "memory_ids": [SUCCESS_ID] if index == 2 else []})
        provider.append({"type": "turn.completed"})
        audit.append({"event": "relay_finished", "child_reaped": True, "cleanup_overrun": False, "peak_inflight": 1})
        run = {"session_id": SID, "request_id": HISTORICAL_REQUEST, "status": "failed",
            "reason": "unverified_completion", "returncode": 0, "turn_completed": True,
            "provider_error": False, "unexpected_tool": False, "end_offset": self.end,
            "started_at": "2026-01-03T08:32:00Z", "ended_at": "2026-01-03T08:33:21Z",
            "write_calls": 1, "tool_calls": 3}
        return {"run": encode(run), "result": encode({"outcome": "stored", "summary": "PRIVATE original result",
            "memory_ids": [SUCCESS_ID]}), "provider": b"".join(encode(e) for e in provider),
            "audit": b"".join(encode(e) for e in audit), "transport": encode({"command": "never-execute-this"}),
            "schema": encode({"type": "object"}), "previous_run": encode({"session_id": SID,
            "status": "succeeded", "end_offset": self.start, "excerpt_sha256": self.state["last_excerpt_sha256"]})}

    def write_assessments(self):
        """Construct cross-linked independent report shapes from synthetic facts."""
        common = {"schema_version": 1, "session_id": SID, "run_id": RUN_ID}
        source = self.review["source"]
        interval = [self.start, self.end]
        artifacts = self.review["artifacts"]
        def report(name, value):
            write_json(self.evidence / name, {**common, **value})
            artifacts[name] = digest((self.evidence / name).read_bytes())
        report("legacy-reconciliation-assessment.json", {
            "state": {"pending_request_id": HISTORICAL_REQUEST},
            "source_reconstruction": {"candidate_start_offset": self.start, "recorded_failed_end_offset": self.end,
                "candidate_interval_sha256": source["interval_sha256"],
                "reconstructed_excerpt_sha256": source["excerpt_sha256"]}})
        report("legacy-coverage-capture.json", {"source_interval": interval, "source_identity": source["identity"],
            "interval_sha256": source["interval_sha256"], "excerpt": {"sha256": source["excerpt_sha256"]},
            "parser_input": self.review["parser"]["input"], "parser_next": self.review["parser"]["next"],
            "message_segments": self.review["messages"]})
        success = self.review["rows"][0]
        report("legacy-success-independent-readback.json", {
            "memory_id": SUCCESS_ID, "content_sha256": success["content_sha256"],
            "matches_historical_successful_intent": {key: True for key in ("content", "project", "topic", "source", "is_private")},
            **{public: dt.datetime.fromtimestamp(success[column], dt.timezone.utc).isoformat().replace("+00:00", "Z")
               for public, column in (("created_at", "createdAt"), ("modified_at", "modifiedAt"), ("expires_at", "expiresAt"))},
            "deleted_at": None})
        report("legacy-residual-duplicate-target.private.json", {"row": self.row_values[1]})
        started = [json.loads(line)["item"] for line in self.history["provider"].splitlines()
                   if json.loads(line).get("type") == "item.started" and json.loads(line)["item"]["tool"] == "remember"]
        report("legacy-write-intents.private.json", {"provider_file_sha256": self.review["history"]["provider"],
            "intents": [{"provider_item_id": attempt["item_id"], "audit_rpc_id": attempt["audit_id"],
                "arguments_canonical_json_sha256": attempt["arguments_sha256"],
                "original_outbound_native_arguments": item["arguments"]}
                for attempt, item in zip(self.attempts, started)]})
        report("legacy-coverage-assessment.json", {"input_bindings": {
            "source_interval": interval, "source_interval_sha256": source["interval_sha256"],
            "excerpt": {"sha256": source["excerpt_sha256"]},
            "independent_success_readback_sha256": artifacts["legacy-success-independent-readback.json"],
            "private_original_intents_sha256": artifacts["legacy-write-intents.private.json"]}})
        report("legacy-residual-duplicate-assessment.json", {
            "input_bindings": {"coverage_assessment_sha256": artifacts["legacy-coverage-assessment.json"],
                "original_assessment_sha256": artifacts["legacy-reconciliation-assessment.json"]},
            "conclusions": {"no_justified_new_mutation_from_retained_candidate_interval": True,
                "historical_original_provider_completed_successfully": False,
                "historical_execution_manifest_or_excerpt_seal_recovered": False,
                "current_cross_provider_capability": "unverified", "cursor_advancement_or_gate_release_performed": False},
            "candidate_interval_dispositions": [
                {"message_indexes": [1], "disposition": "already_represented_by_existing_expired_qualified_memory; no_new_mutation"},
                {"message_indexes": [2, 3, 4, 6], "disposition": "dated_assistant_progress; no_new_durable_fact_supported"},
                {"message_indexes": [5], "disposition": "two_original_intents_accounted; original_success_preserved; original_no_write_expired; no_new_mutation"}],
            "coverage_mapping": {"existing_memory_id": DUPLICATE_ID,
                                 "content_sha256": self.review["rows"][1]["content_sha256"]}})

    def write_review(self):
        write_json(self.evidence / "review.json", self.review)
        self.review_sha256 = digest((self.evidence / "review.json").read_bytes())

    def prepare(self):
        return self.L.prepare(self.paths, session_id=SID, legacy_run_id=RUN_ID,
            reviewed_bundle_sha256=self.review_sha256, reconciliation_id=self.reconciliation_id)

    def pin(self, plan):
        return digest(encode(plan))

    def apply(self, plan):
        return self.L.apply(self.paths, plan=plan, plan_sha256=self.pin(plan))

    def recover(self, plan):
        return self.L.recover(self.paths, session_id=SID, reconciliation_id=plan["id"], plan_sha256=self.pin(plan))

    def current(self):
        return tuple(path.read_bytes() for path in (self.state_path, self.record_path, self.pending_path))

    def history_snapshot(self):
        return {str(path.relative_to(self.root)): (path.read_bytes(), path.stat().st_mode & 0o777)
                for directory in (self.run_dir, self.previous_dir) for path in directory.iterdir()}

    def update_row(self, assignment, parameters):
        with closing(sqlite3.connect(self.store)) as db:
            db.execute("UPDATE Memory SET " + assignment + " WHERE globalId=?", (*parameters, SUCCESS_ID))
            db.commit()

    def newer_pending(self):
        current = json.loads(self.pending_path.read_bytes())
        newer = {**current, "request_id": "newer-stop-request", "turn_id": "newer-turn",
                 "paused_request_id": "newer-stop-request", "fixture_provenance": "newer-preserved-exactly"}
        write_json(self.pending_path, newer)
        record = json.loads(self.record_path.read_bytes())
        write_json(self.record_path, {**record, "last_event": "b" * 64})
        return self.pending_path.read_bytes(), self.record_path.read_bytes()
