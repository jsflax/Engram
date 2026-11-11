"""Finite local publication custody. No authority resolver, transport or installed caller.

Supplied prepared/receipt bodies use the proposed local-custody-v1 integrity
format. Accepting one never proves backend authenticity or current eligibility.
"""
from __future__ import annotations

import base64
import binascii
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import threading
from dataclasses import dataclass
from typing import Callable

MAX_RECORD = 128 * 1024
MAX_BODY = 64 * 1024
MAX_TOTAL = 32 * 1024 * 1024
MAX_OPERATIONS = 256
MAX_ENTRIES = 1282
MAX_INTEGER = 9007199254740991
STAGES = ("candidate", "prepared", "dispatch", "uncertain", "receipt")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
IDENTIFIER = re.compile(r"[A-Za-z0-9._:-]{1,128}\Z")
HASH = re.compile(r"[0-9a-f]{64}\Z")
NAME = re.compile(r"([0-9a-f-]{36})\.(candidate|prepared|dispatch|uncertain|receipt)\.json\Z")


class QueueError(Exception):
    """Only a non-content code may cross the queue boundary."""


def require(value, code="invalid_record"):
    if not value:
        raise QueueError(code)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"), allow_nan=False).encode("utf-8", "strict")


class _Decoder:
    def __init__(self, data: bytes, limit: int):
        require(type(data) is bytes and 0 < len(data) <= limit, "record_bound")
        try:
            self.text = data.decode("utf-8", "strict")
        except UnicodeError:
            raise QueueError("utf8") from None
        self.pos = 0
        self.nodes = 0

    def space(self):
        while self.pos < len(self.text) and self.text[self.pos] in " \t\r\n":
            self.pos += 1

    def string(self):
        require(self.pos < len(self.text) and self.text[self.pos] == '"', "json_string")
        try:
            value, end = json.decoder.scanstring(self.text, self.pos + 1, True)
            value.encode("utf-8", "strict")
        except (ValueError, UnicodeError):
            raise QueueError("json_string") from None
        self.pos = end
        return value

    def value(self, depth=0):
        require(depth <= 16 and self.nodes < 8192, "decode_budget")
        self.nodes += 1
        self.space()
        require(self.pos < len(self.text), "json_truncated")
        token = self.text[self.pos]
        if token == '"':
            return self.string()
        if token == "{":
            self.pos += 1
            self.space()
            result = {}
            if self.pos < len(self.text) and self.text[self.pos] == "}":
                self.pos += 1
                return result
            while True:
                require(len(result) < 128, "object_bound")
                self.space()
                key = self.string()
                require(1 <= len(key) <= 128 and all(0x20 <= ord(ch) <= 0x7e for ch in key), "object_key")
                require(key not in result, "duplicate_key")
                self.space()
                require(self.pos < len(self.text) and self.text[self.pos] == ":", "json_colon")
                self.pos += 1
                result[key] = self.value(depth + 1)
                self.space()
                require(self.pos < len(self.text), "json_truncated")
                end = self.text[self.pos]
                self.pos += 1
                if end == "}":
                    return result
                require(end == ",", "json_object")
        if token == "[":
            self.pos += 1
            self.space()
            result = []
            if self.pos < len(self.text) and self.text[self.pos] == "]":
                self.pos += 1
                return result
            while True:
                require(len(result) < 1024, "array_bound")
                result.append(self.value(depth + 1))
                self.space()
                require(self.pos < len(self.text), "json_truncated")
                end = self.text[self.pos]
                self.pos += 1
                if end == "]":
                    return result
                require(end == ",", "json_array")
        for word, value in (("true", True), ("false", False), ("null", None)):
            if self.text.startswith(word, self.pos):
                self.pos += len(word)
                return value
        require("0" <= token <= "9", "json_number")
        start = self.pos
        while self.pos < len(self.text) and "0" <= self.text[self.pos] <= "9":
            self.pos += 1
        digits = self.text[start:self.pos]
        require(len(digits) <= 16 and (len(digits) == 1 or digits[0] != "0"), "json_integer")
        number = int(digits)
        require(number <= MAX_INTEGER, "json_integer")
        return number


def decode(data: bytes, limit=MAX_RECORD):
    parser = _Decoder(data, limit)
    value = parser.value()
    parser.space()
    require(parser.pos == len(parser.text), "json_trailing")
    return value


def fields(value, names):
    require(type(value) is dict and set(value) == set(names), "record_fields")


def identifier(value):
    require(type(value) is str and IDENTIFIER.fullmatch(value) is not None, "identifier")


def uuid(value):
    require(type(value) is str and UUID.fullmatch(value) is not None, "uuid")


def digest(value):
    require(type(value) is str and HASH.fullmatch(value) is not None, "digest")


def integer(value, minimum=0):
    require(type(value) is int and minimum <= value <= MAX_INTEGER, "integer")


def unique_ids(value, maximum=32, minimum=0, check=identifier):
    require(type(value) is list and minimum <= len(value) <= maximum, "list_bound")
    for item in value:
        check(item)
    require(len(set(value)) == len(value), "duplicate_id")


def destination(value):
    require(type(value) is dict and type(value.get("kind")) is str, "destination")
    kind = value["kind"]
    if kind == "heldLocal":
        fields(value, ("kind", "storeID", "reason"))
        identifier(value["storeID"])
        require(value["reason"] in ("incomplete", "restricted", "unknownSource", "unsupported"), "hold_reason")
    elif kind == "privateLocal":
        fields(value, ("kind", "storeID", "principalID"))
        identifier(value["storeID"]); identifier(value["principalID"])
    elif kind == "personal":
        fields(value, ("kind", "backend", "resourceID", "graphID", "principalID", "policyID"))
        require(value["backend"] in ("native", "hosted"), "personal_backend")
        for key in ("resourceID", "graphID", "principalID", "policyID"):
            identifier(value[key])
    elif kind in ("company", "team"):
        keys = ("kind", "resourceID", "graphID", "principalID", "policyID", "employeeID", "clientID",
                "qualificationDigest", "membershipGeneration", "grantGeneration", "capabilityGeneration")
        fields(value, keys + (("audienceID",) if kind == "team" else ()))
        for key in ("resourceID", "graphID", "principalID", "policyID", "employeeID", "clientID"):
            identifier(value[key])
        if kind == "team":
            identifier(value["audienceID"])
        digest(value["qualificationDigest"])
        for key in ("membershipGeneration", "grantGeneration", "capabilityGeneration"):
            integer(value[key], 1)
    else:
        raise QueueError("destination")


def candidate(data: bytes):
    value = decode(data)
    fields(value, ("version", "stage", "host", "account", "sessionID", "candidateID", "operationID",
                   "mutation", "content", "payloadSHA256", "coverageDigest", "coverageComplete", "evidence",
                   "privateFloor", "audienceCeiling", "destination"))
    integer(value["version"], 1)
    require(value["version"] == 1 and value["stage"] == "candidate" and value["mutation"] == "remember")
    identifier(value["host"]); identifier(value["account"])
    for key in ("sessionID", "candidateID", "operationID"):
        uuid(value[key])
    require(type(value["content"]) is str, "content")
    content = value["content"].encode("utf-8", "strict")
    require(0 < len(content) <= 32 * 1024, "content_bound")
    digest(value["payloadSHA256"]); digest(value["coverageDigest"])
    require(sha256(content) == value["payloadSHA256"], "payload_hash")
    require(type(value["coverageComplete"]) is bool and type(value["privateFloor"]) is bool, "boolean")
    evidence = value["evidence"]
    require(type(evidence) is list and len(evidence) <= 32, "evidence_bound")
    for row in evidence:
        fields(row, ("id", "revision", "digest"))
        identifier(row["id"]); identifier(row["revision"]); digest(row["digest"])
    require(len({row["id"] for row in evidence}) == len(evidence), "duplicate_evidence")
    unique_ids(value["audienceCeiling"])
    destination(value["destination"])
    kind = value["destination"]["kind"]
    require(not value["privateFloor"] or kind in ("privateLocal", "heldLocal"), "private_floor")
    require(value["coverageComplete"] or kind == "heldLocal", "incomplete_hold")
    shared = kind in ("company", "team") or (kind == "personal" and value["destination"]["backend"] == "hosted")
    require(not shared or len(evidence) > 0, "evidence_hold")
    if kind in ("company", "team"):
        require(value["destination"]["graphID"] in value["audienceCeiling"], "audience_ceiling")
    return value


def _binding(raw_candidate: bytes, value):
    target = value["destination"]
    return {"version": 1, "protocol": "local-custody-v1", "operationID": value["operationID"],
            "candidateSHA256": sha256(raw_candidate), "destination": target,
            "payloadSHA256": value["payloadSHA256"], "coverageDigest": value["coverageDigest"],
            "derivationSHA256": sha256(canonical({"privateFloor": value["privateFloor"],
                                                   "audienceCeiling": value["audienceCeiling"]})),
            "qualificationDigest": target.get("qualificationDigest")}


def prepared_body(data: bytes, raw_candidate: bytes, value):
    body = decode(data, MAX_BODY)
    binding = _binding(raw_candidate, value)
    fields(body, (*binding, "backendDigest"))
    require(type(body["version"]) is int, "integer")
    # Canonical comparison retains bool/int and nested field distinctions.
    require(canonical({key: body[key] for key in binding}) == canonical(binding), "prepared_binding")
    digest(body["backendDigest"])
    return body


def receipt_body(data: bytes, prepared_data: bytes, body):
    value = decode(data, MAX_BODY)
    fields(value, (*body, "preparedBodySHA256", "outcome", "committedIDs"))
    require(canonical({key: value[key] for key in body}) == canonical(body), "receipt_binding")
    require(value["preparedBodySHA256"] == sha256(prepared_data) and value["outcome"] == "committed", "receipt_prepared")
    unique_ids(value["committedIDs"], minimum=1, check=uuid)
    return value


def _envelope(stage, op, prior, body):
    return canonical({"version": 1, "stage": stage, "operationID": op, "priorSHA256": sha256(prior),
                      "bodyBase64": base64.b64encode(body).decode("ascii"), "bodySHA256": sha256(body)})


def _unwrap(data, stage, op, prior):
    row = decode(data)
    fields(row, ("version", "stage", "operationID", "priorSHA256", "bodyBase64", "bodySHA256"))
    require(type(row["version"]) is int and row["version"] == 1 and row["stage"] == stage
            and row["operationID"] == op and row["priorSHA256"] == sha256(prior), "stage_chain")
    require(type(row["bodyBase64"]) is str and len(row["bodyBase64"]) <= 87384, "body_bound")
    try:
        body = base64.b64decode(row["bodyBase64"], validate=True)
    except (ValueError, binascii.Error):
        raise QueueError("base64") from None
    require(0 < len(body) <= MAX_BODY and base64.b64encode(body).decode("ascii") == row["bodyBase64"], "base64")
    require(row["bodySHA256"] == sha256(body), "body_hash")
    return body


@dataclass(frozen=True)
class RecoveryRecord:
    operation_id: str
    state: str
    candidate_bytes: bytes
    prepared_bytes: bytes | None
    receipt_bytes: bytes | None
    candidate_sha256: str
    prepared_sha256: str | None
    receipt_sha256: str | None
    backend_digest: str | None
    destination: dict


@dataclass(frozen=True)
class Recovery:
    records: tuple[RecoveryRecord, ...]
    accounting: dict[str, int]
    session_complete: bool = False  # Never a completion certificate.


def _mode(st, directory=False):
    check = stat.S_ISDIR if directory else stat.S_ISREG
    require(check(st.st_mode) and st.st_uid == os.getuid()
            and stat.S_IMODE(st.st_mode) == (0o700 if directory else 0o600)
            and (directory or st.st_nlink == 1), "unsafe_file")


def _identity(st):
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)


def _open_root(root: str):
    require(type(root) is str and root.startswith("/") and str(Path(root)) == root
            and root != "/" and all(x not in ("", ".", "..") for x in root.split("/")[1:]), "root_path")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open("/", flags)
    try:
        for part in root.split("/")[1:]:
            next_fd = os.open(part, flags, dir_fd=descriptor)
            old = descriptor
            descriptor = next_fd
            try:
                os.close(old)
            except OSError:
                raise QueueError("descriptor_close_failed") from None
            st = os.fstat(descriptor)
            require(stat.S_ISDIR(st.st_mode) and st.st_uid in (0, os.getuid())
                    and stat.S_IMODE(st.st_mode) & 0o022 == 0, "unsafe_ancestor")
        _mode(os.fstat(descriptor), directory=True)
        return descriptor
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            raise QueueError("descriptor_close_failed") from None
        raise


class LearnerPublicationQueue:
    """One retained local writer. No method certifies publication permission."""

    def __init__(self, root: str, host: str, account: str, *, _fault: Callable[[str, str], None] | None = None):
        identifier(host); identifier(account)
        self.root, self.host, self.account = root, host, account
        self._fault_hook = _fault
        self._mutex = threading.RLock()
        self._root_fd = self._lock_fd = -1
        self._closed = False
        self._poisoned = False
        self._close_uncertain = False
        self._total = 0
        self._known = {}
        self._observed = {}
        try:
            self._root_fd = _open_root(root)
            st = os.fstat(self._root_fd)
            self._root_identity = (st.st_dev, st.st_ino)
            self._lock_fd = os.open(".owner.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                                    0o600, dir_fd=self._root_fd)
            lock = os.fstat(self._lock_fd)
            _mode(lock); require(lock.st_size == 0, "lock_content")
            fcntl.flock(self._lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self._lock_identity = (lock.st_dev, lock.st_ino)
            names = self._names()
            if "namespace.json" not in names:
                require(names == [".owner.lock"], "namespace_missing")
                self._append("namespace.json", canonical({"version": 1, "host": host, "account": account}))
            self._load()
            # A complete stage surviving an interrupted write is conservatively
            # recovered only after real file+directory durability is re-established.
            for name in self._names():
                descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=self._root_fd)
                try:
                    _mode(os.fstat(descriptor))
                    self._fault("reopen_file_fsync", name)
                    os.fsync(descriptor)
                finally:
                    try:
                        os.close(descriptor)
                    except OSError:
                        self._poisoned = self._close_uncertain = True
                        raise QueueError("descriptor_close_failed") from None
            self._fault("reopen_directory_fsync", "")
            os.fsync(self._root_fd)
            self._load()
        except BaseException as error:
            self.close()
            if isinstance(error, QueueError):
                raise
            raise QueueError("namespace_open") from None

    def _fault(self, point, name):
        if self._fault_hook is not None:
            self._fault_hook(point, name)

    def _check(self):
        require(not self._closed and not self._poisoned, "queue_unavailable")
        try:
            descriptor = _open_root(self.root)
        except QueueError as error:
            if str(error) == "descriptor_close_failed":
                self._poisoned = self._close_uncertain = True
            raise
        try:
            st = os.fstat(descriptor)
            require((st.st_dev, st.st_ino) == self._root_identity, "root_changed")
        finally:
            try:
                os.close(descriptor)
            except OSError:
                self._poisoned = self._close_uncertain = True
                raise QueueError("descriptor_close_failed") from None
        held = os.fstat(self._lock_fd)
        path = os.stat(".owner.lock", dir_fd=self._root_fd, follow_symlinks=False)
        _mode(held); _mode(path)
        require((held.st_dev, held.st_ino) == (path.st_dev, path.st_ino) == self._lock_identity
                and held.st_size == path.st_size == 0, "lock_changed")

    def _names(self):
        names = []
        with os.scandir(self._root_fd) as iterator:
            for entry in iterator:
                require(len(names) < MAX_ENTRIES, "entry_bound")
                name = entry.name
                try:
                    valid_name = type(name) is str and len(name.encode("utf-8", "strict")) <= 96
                except UnicodeError:
                    valid_name = False
                require(valid_name, "filename")
                require(name in (".owner.lock", "namespace.json") or NAME.fullmatch(name) is not None, "filename")
                names.append(name)
        require(len(names) == len(set(names)), "duplicate_file")
        return names

    def _read(self, name, limit):
        preliminary = os.stat(name, dir_fd=self._root_fd, follow_symlinks=False)
        _mode(preliminary)
        require(0 <= preliminary.st_size <= limit, "file_bound")
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=self._root_fd)
        try:
            before = os.fstat(descriptor)
            _mode(before)
            require(_identity(before) == _identity(preliminary), "file_changed")
            require(0 <= before.st_size <= limit, "file_bound")
            self._total += before.st_size
            require(self._total <= MAX_TOTAL, "aggregate_bound")
            chunks = []
            remaining = before.st_size
            while remaining:
                chunk = os.read(descriptor, min(remaining, 65536))
                require(chunk, "file_truncated")
                chunks.append(chunk)
                remaining -= len(chunk)
            require(os.read(descriptor, 1) == b"", "file_grew")
            after = os.fstat(descriptor)
            current = os.stat(name, dir_fd=self._root_fd, follow_symlinks=False)
            _mode(current)
            require(_identity(before) == _identity(after) == _identity(current), "file_changed")
            data = b"".join(chunks)
            self._observed[name] = sha256(data)
            return data
        finally:
            try:
                os.close(descriptor)
            except OSError:
                self._poisoned = self._close_uncertain = True
                raise QueueError("descriptor_close_failed") from None

    def _load(self):
        self._check()
        self._total = 0
        self._observed = {}
        names = self._names()
        require("namespace.json" in names and ".owner.lock" in names, "namespace_missing")
        self._read(".owner.lock", 0)
        metadata = decode(self._read("namespace.json", 1024), 1024)
        fields(metadata, ("version", "host", "account"))
        require(canonical(metadata) == canonical({"version": 1, "host": self.host, "account": self.account}), "namespace_binding")
        rows = {}
        for name in sorted(names):
            if name in ("namespace.json", ".owner.lock"):
                continue
            match = NAME.fullmatch(name)
            require(match is not None, "filename")
            op, stage = match.groups()
            uuid(op)
            if op not in rows:
                require(len(rows) < MAX_OPERATIONS, "operation_bound")
                rows[op] = {}
            rows[op][stage] = self._read(name, MAX_RECORD)
        ids = set()
        for op, stages in rows.items():
            require("candidate" in stages, "stage_missing")
            c = candidate(stages["candidate"])
            require(c["operationID"] == op and c["host"] == self.host and c["account"] == self.account, "candidate_namespace")
            require(c["candidateID"] not in ids, "candidate_rebound")
            ids.add(c["candidateID"])
            if c["destination"]["kind"] == "heldLocal":
                require(set(stages) == {"candidate"}, "held_local")
            prepared = body = None
            if "prepared" in stages:
                prepared = _unwrap(stages["prepared"], "prepared", op, stages["candidate"])
                body = prepared_body(prepared, stages["candidate"], c)
            if any(stage in stages for stage in ("dispatch", "uncertain", "receipt")):
                require(prepared is not None, "stage_missing")
                require("dispatch" in stages, "stage_missing")
                expected = {"version": 1, "stage": "dispatch", "operationID": op,
                            "priorSHA256": sha256(stages["prepared"]), "preparedBodySHA256": sha256(prepared),
                            "backendDigest": body["backendDigest"]}
                require(canonical(decode(stages["dispatch"])) == canonical(expected), "dispatch_binding")
            if "uncertain" in stages:
                row = decode(stages["uncertain"])
                fields(row, ("version", "stage", "operationID", "priorSHA256", "reason"))
                require(type(row["version"]) is int and row["version"] == 1 and row["stage"] == "uncertain"
                        and row["operationID"] == op and row["priorSHA256"] == sha256(stages["dispatch"])
                        and row["reason"] in ("cancelled", "lostResponse", "interrupted", "unknown"), "uncertain_binding")
            if "receipt" in stages:
                received = _unwrap(stages["receipt"], "receipt", op, stages.get("uncertain", stages["dispatch"]))
                receipt_body(received, prepared, body)
        require(sum("dispatch" in stages and "receipt" not in stages for stages in rows.values()) <= 1, "unresolved_dispatch_capacity")
        require(all(self._observed.get(name) == digest for name, digest in self._known.items()), "observed_history_changed")
        self._known = dict(self._observed)
        return rows

    def _append(self, name, data):
        require(type(data) is bytes and 0 < len(data) <= MAX_RECORD and self._total + len(data) <= MAX_TOTAL, "capacity")
        descriptor = -1
        try:
            self._check()
            descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                                 0o600, dir_fd=self._root_fd)
            _mode(os.fstat(descriptor))
            self._fault("before_write", name)
            offset = 0
            while offset < len(data):
                count = os.write(descriptor, data[offset:offset + 65536])
                require(count > 0, "write_zero")
                offset += count
            self._fault("after_write", name)
            self._fault("file_fsync", name)
            os.fsync(descriptor)
            self._fault("directory_fsync", name)
            os.fsync(self._root_fd)
            self._total += len(data)
            self._known[name] = sha256(data)
        except BaseException as error:
            self._poisoned = True
            if isinstance(error, QueueError):
                raise
            raise QueueError("persistence_failed") from None
        finally:
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    self._poisoned = self._close_uncertain = True
                    raise QueueError("descriptor_close_failed") from None

    def retain_candidate(self, data: bytes):
        with self._mutex:
            rows = self._load()
            value = candidate(data)
            require(value["host"] == self.host and value["account"] == self.account, "candidate_namespace")
            op = value["operationID"]
            if op in rows:
                require(rows[op]["candidate"] == data, "candidate_conflict")
                return self._record(op, rows[op])
            require(len(rows) < MAX_OPERATIONS, "operation_bound")
            require(all(candidate(s["candidate"])["candidateID"] != value["candidateID"] for s in rows.values()), "candidate_rebound")
            self._append(op + ".candidate.json", data)
            return self._record(op, {"candidate": data})

    def retain_prepared(self, op: str, data: bytes):
        with self._mutex:
            rows = self._load(); uuid(op)
            require(op in rows, "operation_missing")
            stages = rows[op]; c = candidate(stages["candidate"])
            require(c["destination"]["kind"] != "heldLocal", "held_local")
            prepared_body(data, stages["candidate"], c)
            if "prepared" in stages:
                require(_unwrap(stages["prepared"], "prepared", op, stages["candidate"]) == data, "prepared_conflict")
            else:
                wrapped = _envelope("prepared", op, stages["candidate"], data)
                self._append(op + ".prepared.json", wrapped)
                stages["prepared"] = wrapped
            return self._record(op, stages)

    def record_dispatch_started(self, op: str):
        with self._mutex:
            rows = self._load(); uuid(op)
            require(op in rows and "prepared" in rows[op], "stage_missing")
            stages = rows[op]
            if "dispatch" not in stages:
                require(all(other == op or "dispatch" not in prior or "receipt" in prior for other, prior in rows.items()), "unresolved_dispatch_capacity")
                body = _unwrap(stages["prepared"], "prepared", op, stages["candidate"])
                decoded = prepared_body(body, stages["candidate"], candidate(stages["candidate"]))
                data = canonical({"version": 1, "stage": "dispatch", "operationID": op,
                                  "priorSHA256": sha256(stages["prepared"]), "preparedBodySHA256": sha256(body),
                                  "backendDigest": decoded["backendDigest"]})
                self._append(op + ".dispatch.json", data); stages["dispatch"] = data
            return self._record(op, stages)

    def record_uncertain(self, op: str, reason: str):
        with self._mutex:
            rows = self._load(); uuid(op)
            require(op in rows and "dispatch" in rows[op] and "receipt" not in rows[op], "stage_missing")
            require(reason in ("cancelled", "lostResponse", "interrupted", "unknown"), "uncertain_reason")
            stages = rows[op]
            data = canonical({"version": 1, "stage": "uncertain", "operationID": op,
                              "priorSHA256": sha256(stages["dispatch"]), "reason": reason})
            if "uncertain" in stages:
                require(stages["uncertain"] == data, "uncertain_conflict")
            else:
                self._append(op + ".uncertain.json", data); stages["uncertain"] = data
            return self._record(op, stages)

    def retain_receipt(self, op: str, data: bytes):
        with self._mutex:
            rows = self._load(); uuid(op)
            require(op in rows and "dispatch" in rows[op], "stage_missing")
            stages = rows[op]
            prepared = _unwrap(stages["prepared"], "prepared", op, stages["candidate"])
            body = prepared_body(prepared, stages["candidate"], candidate(stages["candidate"]))
            receipt_body(data, prepared, body)
            prior = stages.get("uncertain", stages["dispatch"])
            if "receipt" in stages:
                require(_unwrap(stages["receipt"], "receipt", op, prior) == data, "receipt_conflict")
            else:
                wrapped = _envelope("receipt", op, prior, data)
                self._append(op + ".receipt.json", wrapped); stages["receipt"] = wrapped
            return self._record(op, stages)

    def _record(self, op, stages):
        c = candidate(stages["candidate"])
        state = "heldLocal" if c["destination"]["kind"] == "heldLocal" else "pending"
        prepared = receipt = backend = None
        if "prepared" in stages:
            prepared = _unwrap(stages["prepared"], "prepared", op, stages["candidate"])
            backend = prepared_body(prepared, stages["candidate"], c)["backendDigest"]
            state = "prepared"
        if "dispatch" in stages:
            state = "dispatchedUnknown"
        if "receipt" in stages:
            receipt = _unwrap(stages["receipt"], "receipt", op, stages.get("uncertain", stages["dispatch"]))
            state = "acknowledged"
        return RecoveryRecord(op, state, stages["candidate"], prepared, receipt, sha256(stages["candidate"]),
                              sha256(prepared) if prepared else None, sha256(receipt) if receipt else None, backend, c["destination"])

    def recover(self):
        with self._mutex:
            rows = self._load()
            records = tuple(self._record(op, rows[op]) for op in sorted(rows))
            counts = {state: 0 for state in ("heldLocal", "pending", "prepared", "dispatchedUnknown", "acknowledged")}
            for row in records:
                counts[row.state] += 1
            counts["retained"] = len(records)
            return Recovery(records, counts)

    def close(self):
        with self._mutex:
            self._closed = True
            # Closing the original descriptors releases only this local owner.
            # It says nothing about any transport operation.
            failed = False
            for name in ("_lock_fd", "_root_fd"):
                descriptor = getattr(self, name, -1)
                setattr(self, name, -1)
                if descriptor >= 0:
                    try:
                        os.close(descriptor)
                    except OSError:
                        failed = True
            if failed:
                self._poisoned = self._close_uncertain = True
            require(not self._close_uncertain, "descriptor_close_failed")

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class UnavailableHostedAdapter:
    """No callback, credential, network operation or fallback target exists."""
    def prepare(self, *_):
        raise QueueError("hosted_adapter_unavailable")

    def apply(self, *_):
        raise QueueError("hosted_adapter_unavailable")

    def lookup(self, *_):
        raise QueueError("hosted_adapter_unavailable")
