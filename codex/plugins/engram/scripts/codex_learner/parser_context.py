"""Private parser-only evidence; never provider, memory, cursor or queue effects.

The caller holds worker -> enqueue coordination and durably embeds the returned
input_evidence in its publication ticket before replacing state/admission. This
module validates frozen source evidence, not the journal's current old/new pair.
It never follows root/session/path selectors supplied by an evidence record.
Empty EOF intervals are supported here only; provider operation manifests still
require nonempty source intervals. Legacy matching-text duplicates remain held.
"""
from __future__ import annotations

import copy
import functools
import os
from pathlib import Path
import re
import stat

from . import execution_context as execution, execution_manifest as journal
from . import admission, file_identity, host_admission, migration as durable, transcript

INPUTS = {"request", "cursor", "admission", "parser_state", "next_parser_state"}
REASONS = {"no_visible_content", "duplicate"}


class ParserContextError(ValueError):
    """Fixed labels only; private excerpt, request and file data stay unprinted."""


def _require(ok, reason):
    if not ok:
        raise ParserContextError("parser_context_" + reason)


def _safe(function):
    @functools.wraps(function)
    def guarded(*args, **kwargs):
        try:
            return function(*args, **kwargs)
        except ParserContextError:
            raise
        except (OSError, ValueError, TypeError, KeyError, AttributeError, OverflowError,
                RecursionError, RuntimeError):
            raise ParserContextError("parser_context_unavailable_or_changed") from None
    return guarded


def _interval(path, identity, start, end):
    if start != end:
        return execution._interval(path, identity, start, end)
    _require(type(start) is int and start >= 0, "invalid_empty_interval")
    path = Path(path)
    _require(path.is_absolute() and path.resolve(strict=True) == path, "unbound_source")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        _require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                 and before.st_size >= start and file_identity.capture_fd(fd) == identity,
                 "source_changed")
        _require(start == 0 or os.pread(fd, 1, start - 1) == b"\n", "incomplete_boundary")
        after, current = os.fstat(fd), path.lstat()
        _require(file_identity.capture_fd(fd) == identity and after.st_size >= start
                 and (before.st_dev, before.st_ino, before.st_uid, before.st_mode)
                 == (after.st_dev, after.st_ino, after.st_uid, after.st_mode)
                 == (current.st_dev, current.st_ino, current.st_uid, current.st_mode), "source_changed")
        return journal.sha256(b"")
    finally:
        os.close(fd)


class ParserContext:
    @_safe
    def __init__(self, root, session_id, *, verify_coverage=None):
        _require(isinstance(root, Path) and root.is_absolute() and root.resolve(strict=True) == root,
                 "untrusted_root")
        _require(not durable._directory(root).st_mode & 0o077, "untrusted_root")
        admission._uuid(session_id, 7)
        self.root, self.session_id = root, session_id
        _require(verify_coverage is None or callable(verify_coverage), "invalid_coverage_validator")
        self._verify_coverage = verify_coverage

    def _coverage(self, evidence, values):
        """Reference selects one fixed filename; callback establishes success.

        Receipt schema V1 binds the exact source and parser descriptor below plus
        execution_manifest_sha256 and settlement_sha256. Those two digests are
        references, not success by themselves: the mandatory trusted callback
        verifies their retained native journals and completion evidence. This
        module cannot manufacture coverage from prose or a matching text hash.
        """
        reference = evidence["coverage"]
        _require(callable(self._verify_coverage) and type(reference) is dict, "duplicate_coverage_required")
        journal._keys(reference, {"version", "run_id", "receipt_sha256"})
        journal._version(reference["version"])
        _require(type(reference["run_id"]) is str
                 and re.fullmatch(r"[A-Za-z0-9_-]{1,100}", reference["run_id"]), "invalid_coverage_reference")
        journal._digest(reference["receipt_sha256"])
        path = self.root / "runs" / reference["run_id"] / "successful-coverage.json"
        raw, identity = durable._read(path)
        _require(journal.sha256(raw) == reference["receipt_sha256"], "coverage_changed")
        receipt = journal._json(raw)
        journal._keys(receipt, {"version", "kind", "status", "session_id", "run_id", "source", "parser",
                               "execution_manifest_sha256", "settlement_sha256"})
        journal._version(receipt["version"])
        _require(receipt["kind"] == "successful_interval_coverage" and receipt["status"] == "succeeded"
                 and receipt["session_id"] == self.session_id and receipt["run_id"] == reference["run_id"],
                 "invalid_coverage_receipt")
        for key in ("execution_manifest_sha256", "settlement_sha256"):
            journal._digest(receipt[key])
        parser = values["parser_state"]
        parser_binding = {"runtime": parser["runtime"], "limits": parser["limits"],
                          "input_sha256": journal.sha256(journal.encode(parser["input"])),
                          "next_sha256": evidence["inputs"]["next_parser_state"]["sha256"]}
        _require(execution._same(receipt["source"], evidence["source"])
                 and execution._same(receipt["parser"], parser_binding), "coverage_interval_mismatch")
        binding = {"session_id": self.session_id, "run_id": reference["run_id"],
                   "source": copy.deepcopy(evidence["source"]), "parser": copy.deepcopy(parser_binding),
                   "admission": copy.deepcopy(values["request"]["admission"])}
        _require(self._verify_coverage(copy.deepcopy(receipt), binding) is True, "coverage_unverified")
        after, after_identity = durable._read(path)
        _require(after == raw and after_identity == identity, "coverage_changed")

    def _decode(self, evidence):
        journal._keys(evidence, {"version", "kind", "session_id", "request_id", "reason", "inputs", "source", "coverage"})
        journal._version(evidence["version"])
        _require(evidence["kind"] == "parser_only_context" and evidence["session_id"] == self.session_id
                 and evidence["reason"] in REASONS, "invalid_evidence")
        journal._identifier(evidence["request_id"])
        journal._keys(evidence["inputs"], INPUTS)
        values = {key: journal._json(journal._unseal(value)) for key, value in evidence["inputs"].items()}
        request, state, record = values["request"], values["cursor"], values["admission"]
        _require(request["session_id"] == state["session_id"] == self.session_id
                 and request["request_id"] == evidence["request_id"], "selected_task_changed")
        _require(request["admission"].get("mode") == host_admission.MODE_V2, "v2_required")
        binding = admission.check(self.root, request)
        _require(execution._same(binding, request["admission"])
                 and execution._same(binding, state["admission"])
                 and execution._same(binding, record["binding"]), "binding_changed")
        execution._authority(record)
        _require(record["state_sha256"] == durable.object_digest(state)
                 and record["processing"] is None and record.get("processing_execution") is None,
                 "invalid_original_pair")
        _require(type(state.get("offset")) is int and state["offset"] >= binding["frontier_offset"]
                 and state.get("identity") == request["identity"] == binding["identity"]
                 and state.get("transcript_path") == request["transcript_path"]
                 and "device" not in state and "inode" not in state
                 and state.get("status") != "reconciliation_required" and not state.get("reconciliation_required"),
                 "invalid_original_cursor")
        journal._keys(values["parser_state"], {"version", "input", "runtime", "limits"})
        parser = values["parser_state"]
        journal._version(parser["version"])
        _require(execution._same(execution._parser_state(state), parser["input"]), "parser_input_changed")
        journal._keys(values["next_parser_state"], {"offset", "recent_messages", "current_turn_id"})
        execution._parser_state(values["next_parser_state"])
        journal._keys(parser["limits"], {"max_chars", "max_scan_bytes"})
        maximum, scan = parser["limits"]["max_chars"], parser["limits"]["max_scan_bytes"]
        _require(type(maximum) is int and 1 <= maximum <= 48000 and type(scan) is int
                 and 1 <= scan <= execution.MAX_SCAN, "invalid_parser_limits")
        journal._keys(evidence["source"], {"identity", "start_offset", "end_offset", "interval_sha256", "excerpt_sha256"})
        source = evidence["source"]
        file_identity.validate(source["identity"])
        journal._integer(source["start_offset"])
        journal._integer(source["end_offset"], source["start_offset"])
        for name in ("interval_sha256", "excerpt_sha256"):
            journal._digest(source[name])
        _require(source["identity"] == request["identity"] and source["start_offset"] == state["offset"]
                 and source["end_offset"] - source["start_offset"] <= scan
                 and values["next_parser_state"]["offset"] == source["end_offset"], "source_binding_changed")
        return values

    def _source(self, evidence, values):
        source, parser, request = evidence["source"], values["parser_state"], values["request"]
        _require(execution._same(execution._parser_runtime(), parser["runtime"]), "parser_changed")
        path, identity = request["transcript_path"], source["identity"]
        start, end = source["start_offset"], source["end_offset"]
        _require(_interval(path, identity, start, end) == source["interval_sha256"], "source_bytes_changed")
        if start == end:
            metadata = transcript.inspect_rollout(path, stable_identity=True)
            _require(metadata.session_id == self.session_id and metadata.identity == identity
                     and metadata.start_offset <= start, "source_changed")
            text, next_parser = "", parser["input"]
        else:
            excerpt = transcript.read_excerpt(path, start, max_chars=parser["limits"]["max_chars"],
                                              max_scan_bytes=end - start,
                                              recent_messages=parser["input"]["recent_messages"],
                                              current_turn_id=parser["input"]["current_turn_id"], stable_identity=True)
            _require(excerpt.metadata.session_id == self.session_id and excerpt.metadata.identity == identity
                     and excerpt.next_offset == end and excerpt.blocked_reason is None, "parser_boundary_changed")
            text, next_parser = excerpt.text, execution._next_parser(excerpt)
        _require(journal.sha256(text.encode("utf-8")) == source["excerpt_sha256"]
                 and execution._same(next_parser, values["next_parser_state"]), "excerpt_or_parser_changed")
        if evidence["reason"] == "no_visible_content":
            _require(not text and evidence["coverage"] is None, "visible_content_not_covered")
        else:
            _require(bool(text) and start < end, "duplicate_requires_visible_interval")
            self._coverage(evidence, values)
        _require(_interval(path, identity, start, end) == source["interval_sha256"]
                 and execution._same(execution._parser_runtime(), parser["runtime"]), "source_or_parser_changed")
        _require(execution._same(admission.check(self.root, request), request["admission"]), "binding_changed")
        return True

    @_safe
    def capture(self, request, state, excerpt, expected_next_parser, *, reason,
                max_chars, max_scan_bytes, coverage=None):
        """Return evidence for a private durable ticket before any target write."""
        request, state = copy.deepcopy(request), copy.deepcopy(state)
        _require(request.get("session_id") == self.session_id and reason in REASONS, "selected_task_changed")
        selected = admission.state_paths(self.root, self.session_id)
        raw_state, current = execution._record(selected["sessions"])
        _require(execution._same(current, state), "cursor_changed")
        raw_admission, _ = execution._admitted(self, request, raw_state, processing=None, execution=None)
        _require(excerpt.blocked_reason is None and execution._same(expected_next_parser, execution._next_parser(excerpt)),
                 "expected_parser_changed")
        _require(excerpt.metadata.session_id == self.session_id
                 and excerpt.metadata.identity == request["identity"]
                 and (excerpt.next_offset != state["offset"]
                      or (excerpt.metadata.size_bytes == state["offset"] and not excerpt.has_more)),
                 "original_excerpt_changed")
        parser = {"version": 1, "input": execution._parser_state(state), "runtime": execution._parser_runtime(),
                  "limits": {"max_chars": max_chars, "max_scan_bytes": max_scan_bytes}}
        source = {"identity": request["identity"], "start_offset": state["offset"], "end_offset": excerpt.next_offset,
                  "interval_sha256": _interval(request["transcript_path"], request["identity"], state["offset"], excerpt.next_offset),
                  "excerpt_sha256": journal.sha256(excerpt.text.encode("utf-8"))}
        inputs = {"request": journal.encode(request), "cursor": raw_state, "admission": raw_admission,
                  "parser_state": journal.encode(parser), "next_parser_state": journal.encode(expected_next_parser)}
        evidence = {"version": 1, "kind": "parser_only_context", "session_id": self.session_id,
                    "request_id": request["request_id"], "reason": reason,
                    "inputs": {key: journal.seal_json(raw) for key, raw in inputs.items()},
                    "source": source, "coverage": copy.deepcopy(coverage)}
        self._source(evidence, self._decode(evidence))
        execution._admitted(self, request, raw_state, processing=None, execution=None)
        return evidence

    @_safe
    def validate_source(self, input_evidence, phase):
        """Read-only check; coordinator separately qualifies mixed target pairs."""
        _require(type(phase) is str and re.fullmatch(r"[a-z_]{1,128}", phase), "invalid_phase")
        # Copy through the bounded strict encoder before inspecting caller data.
        evidence = journal._json(journal.encode(input_evidence))
        return self._source(evidence, self._decode(evidence))
