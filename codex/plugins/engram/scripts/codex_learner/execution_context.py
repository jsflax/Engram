"""Seal and recheck one admitted V2 learner run before durable dispatch.

Callers supply trusted paths and hold worker/provider coordination. This module
does not acquire those locks, run a provider/backend, publish cursor progress or
change pending work. It publishes the immutable execution manifest BEFORE the
coordinator publishes a processing marker referencing that manifest's digest. Newer
Stop events may update pending/last_event while the original processing marker,
admission binding and cursor remain fixed. V1 needs explicit migration first.

Executable hashes bind observed native file bytes, not signatures or behavior.
Only a direct native executable with no arguments is supported initially; shell
wrappers and interpreter-plus-script routes cannot inherit durable authority.
All route/environment snapshots remain in the private manifest. The context is
not a status/recovery/publication validator, and absence never grants replay.
"""
from __future__ import annotations

import copy
from dataclasses import dataclass
import functools
import hashlib
import os
from pathlib import Path
import stat
import time

from . import admission, execution_manifest as journal, file_identity, host_admission
from . import memory_config, migration as durable, stdio_bridge, transcript
from .writer_fence import HeldFence

MAX_SCAN = 32 * 1024 * 1024
MAX_RUNTIME = 512 * 1024 * 1024
READ_TOOLS = {"recall", "graph", "list_topics", "stats", "timeline"}
WRITE_TOOLS = {"remember", "update", "connect"}
PHASES = {"before_intent", "before_dispatch_record", "before_forward",
          "before_plan_seal", "before_plan_publication", "after_plan_publication",
          "before_plan_execution", "before_plan_intent", "before_plan_dispatch",
          "before_plan_forward", "after_plan_response", "after_plan_execution",
          "before_native_launch", "before_native_forward", "before_native_write"}
NATIVE_MAGIC = {b"\x7fELF", b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
                b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
                b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


class ContextError(ValueError):
    """Fixed payload-free reason; no request, transcript, path or environment."""


def _require(ok, reason):
    if not ok:
        raise ContextError("execution_context_" + reason)


def _safe(function):
    @functools.wraps(function)
    def guarded(*args, **kwargs):
        try:
            return function(*args, **kwargs)
        except ContextError:
            raise
        except (OSError, ValueError, TypeError, KeyError, AttributeError, OverflowError,
                RecursionError, RuntimeError):
            raise ContextError("execution_context_unavailable_or_changed") from None
    return guarded


@dataclass(frozen=True)
class ContextPaths:
    root: Path
    run_dir: Path
    config_path: Path
    plugin_root: Path

    @_safe
    def check(self):
        for path in (self.root, self.run_dir, self.config_path, self.plugin_root):
            _require(isinstance(path, Path) and path.is_absolute()
                     and path.resolve(strict=True) == path, "untrusted_paths")
        for directory in (self.root, self.run_dir, self.plugin_root):
            durable._directory(directory)
        _require(not self.root.stat().st_mode & 0o077
                 and not self.run_dir.stat().st_mode & 0o077
                 and self.run_dir.parent == self.root / "runs", "untrusted_paths")
        return {name: str(getattr(self, name)) for name in self.__dataclass_fields__}


def _same(left, right):
    return journal.encode(left) == journal.encode(right)


def _record(path, *, absent=False, private=True):
    raw, _ = durable._read(path, absent=absent, private=private)
    return (None, None) if raw is None else (raw, journal._json(raw))


def _parser_state(value):
    recent, turn = value.get("recent_messages", []), value.get("current_turn_id")
    _require(type(value.get("offset")) is int and value["offset"] >= 0
             and type(recent) is list and len(recent) <= transcript.MAX_RECENT_MESSAGES,
             "invalid_parser_state")
    if turn is not None:
        journal._string(turn, 4096)
    for entry in recent:
        journal._keys(entry, {"content_hash", "id_hash", "turn_hash", "sources"})
        journal._digest(entry["content_hash"])
        for key in ("id_hash", "turn_hash"):
            if entry[key] is not None:
                journal._digest(entry[key])
        _require(type(entry["sources"]) is list and 1 <= len(entry["sources"]) <= 3
                 and all(source in ("response", "event", "item_completed") for source in entry["sources"]),
                 "invalid_parser_state")
    return {"offset": value["offset"], "recent_messages": recent, "current_turn_id": turn}


def _next_parser(excerpt):
    return _parser_state({"offset": excerpt.next_offset, "recent_messages": excerpt.recent_messages,
                          "current_turn_id": excerpt.current_turn_id})


def _authority(record):
    _require(type(record) is dict and {"binding", "state_sha256", "processing", "last_event"} <= set(record),
             "invalid_admission_record")
    return {**{key: record[key] for key in ("binding", "state_sha256", "processing")},
            "processing_execution": record.get("processing_execution")}


def _admitted(paths, request, state_raw, *, processing, execution):
    binding = admission.check(paths.root, request)
    _require(binding.get("mode") == host_admission.MODE_V2, "v2_required")
    _require(_same(binding, request["admission"]), "binding_changed")
    selected = admission.state_paths(paths.root, request["session_id"])
    admission_raw, record = _record(selected["admissions"])
    current_raw, state = _record(selected["sessions"])
    _require(current_raw == state_raw, "cursor_changed")
    _authority(record)
    _require(_same(record["binding"], binding)
             and record["state_sha256"] == durable.object_digest(state)
             and type(request.get("request_id")) is str and bool(request["request_id"])
             and record["processing"] == processing
             and _same({"value": record.get("processing_execution")}, {"value": execution}),
             "processing_changed")
    _require(_same(state.get("admission"), binding)
             and state.get("session_id") == request["session_id"]
             and state.get("transcript_path") == request["transcript_path"]
             and type(state.get("offset")) is int and state["offset"] >= binding["frontier_offset"]
             and state.get("identity") == binding["identity"] == request["identity"]
             and "device" not in state and "inode" not in state, "cursor_binding_changed")
    _require(state.get("status") != "reconciliation_required"
             and not state.get("reconciliation_required"), "reconciliation_required")
    # A concurrent Stop may replace the admission row's last_event, but cannot
    # alter the authority fields or cursor while this original request runs.
    _, after = _record(selected["admissions"])
    _require(_same(_authority(after), _authority(record)), "admission_changed")
    return admission_raw, record


def _runtime(path):
    path = Path(path)
    _require(path.is_absolute() and path.resolve(strict=True) == path, "unbound_runtime")
    before = path.lstat()
    _require(stat.S_ISREG(before.st_mode) and before.st_uid in (0, os.getuid())
             and not before.st_mode & 0o022 and before.st_mode & 0o111
             and 4 <= before.st_size <= MAX_RUNTIME, "unsafe_runtime")
    identity = durable._identity(before)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        _require(durable._identity(os.fstat(fd)) == identity, "runtime_changed")
        _require(os.pread(fd, 4, 0) in NATIVE_MAGIC, "wrapper_runtime_unsupported")
        digest, count, deadline = hashlib.sha256(), 0, time.monotonic() + 10
        while True:
            _require(time.monotonic() < deadline, "runtime_read_deadline")
            chunk = os.read(fd, min(1048576, MAX_RUNTIME + 1 - count))
            if not chunk:
                break
            count += len(chunk)
            _require(count <= MAX_RUNTIME, "runtime_too_large")
            digest.update(chunk)
        _require(count == before.st_size and durable._identity(os.fstat(fd)) == identity
                 == durable._identity(path.lstat()), "runtime_changed")
        return {"path": str(path), "sha256": digest.hexdigest(), "identity": identity}
    finally:
        os.close(fd)


def _effective_transport(paths, transport):
    _require(type(transport) is dict, "invalid_transport")
    value = copy.deepcopy(transport)
    if value.get("cwd") is None:
        workspace = paths.run_dir / "workspace"
        durable._directory(workspace)
        value["cwd"] = str(workspace)
    return value


@_safe
def effective_transport(paths, transport):
    """Bind omitted cwd before the probe; caller creates the private workspace."""
    _require(type(paths) is ContextPaths, "invalid_context")
    paths.check()
    value = _effective_transport(paths, transport)
    stdio_bridge._transport(value)
    return value


def _backend(paths):
    config_raw, _ = durable._read(paths.config_path, private=False, maximum=memory_config.MAX_CONFIG)
    _require(not paths.config_path.stat().st_mode & 0o022, "unsafe_config")
    _, memory = memory_config.resolve(paths.config_path, paths.plugin_root, config_bytes=config_raw)
    allowed = memory_config.allowed_tools(memory, READ_TOOLS | WRITE_TOOLS)
    _require("recall" in allowed and bool(allowed & WRITE_TOOLS), "memory_policy_disallows_learning")
    transport = _effective_transport(paths, memory_config.transport(memory))
    argv, env, cwd = stdio_bridge._transport(transport)
    _require(len(argv) == 1, "runtime_arguments_unsupported")
    _require(cwd is None or Path(cwd).resolve(strict=True) == Path(cwd), "unbound_cwd")
    runtime = _runtime(argv[0])
    settings_raw, settings = _record(paths.root / "settings.json", absent=True)
    configuration = {"memory": memory, "settings": None if settings_raw is None else {
        "sha256": journal.sha256(settings_raw), "value": settings}}
    route = {"version": 1, "paths": paths.check(), "transport": transport,
             "launch": {"argv": argv, "env": env, "cwd": cwd}, "runtime": runtime}
    return configuration, route


def _parser_runtime():
    path = Path(transcript.__file__)
    raw, _ = durable._read(path, private=False, maximum=1048576)
    _require(not path.stat().st_mode & 0o022, "unsafe_parser")
    return {"path": str(path), "sha256": journal.sha256(raw)}


def _interval(path, identity, start, end):
    _require(type(start) is int and type(end) is int and 0 <= start < end
             and end - start <= MAX_SCAN, "invalid_source_interval")
    path = Path(path)
    _require(path.resolve(strict=True) == path, "unbound_source")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        _require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                 and before.st_size >= end and file_identity.capture_fd(fd) == identity,
                 "source_changed")
        digest, position = hashlib.sha256(), start
        while position < end:
            chunk = os.pread(fd, min(1048576, end - position), position)
            _require(bool(chunk), "source_truncated")
            digest.update(chunk)
            position += len(chunk)
        after, current = os.fstat(fd), path.lstat()
        _require(file_identity.capture_fd(fd) == identity and after.st_size >= end
                 and (before.st_dev, before.st_ino, before.st_uid, before.st_mode)
                 == (after.st_dev, after.st_ino, after.st_uid, after.st_mode)
                 == (current.st_dev, current.st_ino, current.st_uid, current.st_mode), "source_changed")
        return digest.hexdigest()
    finally:
        os.close(fd)


def _source(request, parser, source, expected_next, *, verified=None):
    journal._keys(parser, {"version", "input", "limits", "runtime", "interval_sha256"})
    journal._version(parser["version"])
    journal._keys(parser["input"], {"offset", "recent_messages", "current_turn_id"})
    journal._keys(parser["limits"], {"max_chars", "max_scan_bytes"})
    maximum, scan = parser["limits"]["max_chars"], parser["limits"]["max_scan_bytes"]
    _require(type(maximum) is int and 1 <= maximum <= 48000
             and type(scan) is int and 1 <= scan <= MAX_SCAN
             and source["start_offset"] == parser["input"]["offset"]
             and source["end_offset"] - source["start_offset"] <= scan, "invalid_parser_limits")
    _require(source["identity"] == request["identity"]
             and _same(_parser_runtime(), parser["runtime"]), "parser_or_source_changed")
    path, start, end = request["transcript_path"], source["start_offset"], source["end_offset"]
    expected_hash = parser["interval_sha256"]
    _require(_interval(path, source["identity"], start, end) == expected_hash, "source_bytes_changed")
    # Cache semantic reconstruction only. Exact interval bytes, stable file
    # identity and parser source are checked on EVERY call, including appends.
    key = journal.sha256(journal.encode({"inputs": [request, parser, source, expected_next]}))
    if verified is None or verified.get("key") != key:
        excerpt = transcript.read_excerpt(path, start, max_chars=maximum, max_scan_bytes=end - start,
                                          recent_messages=parser["input"]["recent_messages"],
                                          current_turn_id=parser["input"]["current_turn_id"], stable_identity=True)
        _require(excerpt.metadata.session_id == request["session_id"]
                 and excerpt.metadata.identity == source["identity"]
                 and excerpt.next_offset == end and bool(excerpt.text)
                 and journal.sha256(excerpt.text.encode("utf-8")) == source["excerpt_sha256"]
                 and _same(_next_parser(excerpt), expected_next), "excerpt_or_parser_changed")
    _require(_interval(path, source["identity"], start, end) == expected_hash
             and _same(_parser_runtime(), parser["runtime"]), "source_or_parser_changed")
    if verified is not None:
        verified.clear()
        verified["key"] = key


def _decode_inputs(paths, manifest):
    paths.check()
    decoded = {name: journal._json(journal._unseal(value)) for name, value in manifest["inputs"].items()}
    request, state = decoded["request"], decoded["cursor"]
    _require(manifest["session_id"] == request["session_id"] and manifest["run_id"] == paths.run_dir.name,
             "run_changed")
    _require(_same(_parser_state(state), decoded["parser_state"]["input"]), "parser_input_changed")
    return decoded


def _source_backend_inputs(paths, manifest, decoded, *, source_cache=None):
    """Read-only input checks; no held-fence or current target-pair authority."""
    request = decoded["request"]
    _require(_same(admission.check(paths.root, request), request["admission"]), "binding_changed")
    configuration, route = _backend(paths)
    _require(_same(configuration, decoded["backend_config"])
             and _same(route, decoded["backend_route"])
             and route["runtime"]["sha256"] == manifest["backend"]["runtime_sha256"], "backend_changed")
    arguments = (request, decoded["parser_state"], manifest["source"], decoded["next_parser_state"])
    if source_cache is None:
        _source(*arguments)
    else:
        _source(*arguments, verified=source_cache)
    _require(_same(admission.check(paths.root, request), request["admission"]), "binding_changed")
    return True


@_safe
def validate_recovery_inputs(paths, *, manifest_sha256):
    """Check pinned inputs before/during exclusive fence acquisition/revocation.

    This deliberately needs no HeldFence: revocation's validation callback runs
    before it can produce a verified revoked exclusive handle. It NEVER grants
    dispatch or publication authority. The caller separately verifies the exact
    processing marker or active publication pair and must obtain and retain the
    exclusive revoked fence before reconciliation/publication. Current cursor
    and processing fields are not checked here because publication can leave an
    admitted old/new pair between its two durable target replacements.
    """
    _require(type(paths) is ContextPaths, "invalid_context")
    paths.check()
    journal._digest(manifest_sha256)
    manifest, digest = journal.read_manifest(paths.run_dir)
    _require(digest == manifest_sha256, "manifest_changed")
    _source_backend_inputs(paths, manifest, _decode_inputs(paths, manifest))
    retained, after_digest = journal.read_manifest(paths.run_dir)
    _require(after_digest == manifest_sha256 and _same(retained, manifest), "manifest_changed")
    return True


class ExecutionContext:
    """Private manifest plus mandatory current-input callback for the gateway."""
    def __init__(self, paths, manifest, digest, writer_fence):
        self.paths = paths
        self.manifest_sha256 = digest
        self._manifest = copy.deepcopy(manifest)
        self._fence = writer_fence
        self._source_cache = {}

    @property
    @_safe
    def transport(self):
        """Exact sealed effective native route for the probe/proxy, copied out."""
        route = journal._json(journal._unseal(self._manifest["inputs"]["backend_route"]))
        return copy.deepcopy(route["transport"])

    def _decoded(self, manifest):
        _require(_same(manifest, self._manifest), "manifest_changed")
        _require(type(self._fence) is HeldFence
                 and self._fence.verify(manifest["fencing"]) is True, "writer_unfenced")
        return _decode_inputs(self.paths, manifest)

    def _source_backend(self, manifest, decoded):
        _source_backend_inputs(self.paths, manifest, decoded, source_cache=self._source_cache)
        _require(self._fence.verify(manifest["fencing"]) is True, "writer_unfenced")
        return True

    def _validate(self, manifest, *, before_marker=False):
        _require(type(self._fence) is HeldFence and self._fence.mode == "shared", "writer_unfenced")
        decoded = self._decoded(manifest)
        request, paths = decoded["request"], self.paths
        original = _authority(decoded["admission"])
        _require(original["processing"] is None and original["processing_execution"] is None,
                 "invalid_pre_marker_admission")
        processing = None if before_marker else request["request_id"]
        execution = None if before_marker else {"run_id": paths.run_dir.name,
                                                "manifest_sha256": self.manifest_sha256}
        expected = {**original, "processing": processing, "processing_execution": execution}
        _, current = _admitted(paths, request, journal._unseal(manifest["inputs"]["cursor"]),
                               processing=processing, execution=execution)
        _require(_same(_authority(current), expected), "admission_changed")
        self._source_backend(manifest, decoded)
        _admitted(paths, request, journal._unseal(manifest["inputs"]["cursor"]),
                  processing=processing, execution=execution)
        _require(self._fence.verify(manifest["fencing"]) is True, "writer_unfenced")
        return True

    @_safe
    def validate_inputs(self, manifest, phase):
        _require(phase in PHASES, "unsupported_validation_phase")
        retained, digest = journal.read_manifest(self.paths.run_dir)
        _require(digest == self.manifest_sha256 and _same(retained, manifest), "manifest_changed")
        return self._validate(manifest)

    @_safe
    def validate_marker(self, manifest):
        """Allow pre/exact-post marker; journal owns exact replacement preimages."""
        retained, digest = journal.read_manifest(self.paths.run_dir)
        _require(digest == self.manifest_sha256 and _same(retained, manifest), "manifest_changed")
        selected = admission.state_paths(self.paths.root, manifest["session_id"])
        _, current = _record(selected["admissions"])
        return self._validate(manifest, before_marker=current.get("processing") is None)

    @_safe
    def validate_source_backend(self, manifest):
        """Check frozen input, not cursor/processing or publication authority.

        A verified revoked exclusive fence is accepted for read-only recovery.
        The journal/coordinator must independently validate every old/new target
        pair and current queue coordination; this method never authorizes replay.
        """
        retained, digest = journal.read_manifest(self.paths.run_dir)
        _require(digest == self.manifest_sha256 and _same(retained, manifest), "manifest_changed")
        return self._source_backend(manifest, self._decoded(manifest))


@_safe
def seal_execution(paths, *, host, request, state, excerpt, expected_next_parser,
                   memory, transport, scope, writer_fence, max_chars, max_scan_bytes,
                   provider_mode=None, plan_policy=None):
    """Before processing marker/provider: admit, freeze and fsync manifest."""
    _require(type(paths) is ContextPaths and type(writer_fence) is HeldFence
             and writer_fence.mode == "shared", "invalid_context")
    paths.check()
    request, state = copy.deepcopy(request), copy.deepcopy(state)
    _require(request["admission"].get("mode") == host_admission.MODE_V2, "v2_required")
    selected = admission.state_paths(paths.root, request["session_id"])
    state_raw, current = _record(selected["sessions"])
    _require(_same(current, state), "cursor_changed")
    admission_raw, _ = _admitted(paths, request, state_raw, processing=None, execution=None)
    _require(_same(expected_next_parser, _next_parser(excerpt)), "expected_parser_changed")
    source = {"identity": request["identity"], "start_offset": state["offset"],
              "end_offset": excerpt.next_offset, "excerpt_sha256": journal.sha256(excerpt.text.encode("utf-8"))}
    parser = {"version": 1, "input": _parser_state(state),
              "limits": {"max_chars": max_chars, "max_scan_bytes": max_scan_bytes}, "runtime": _parser_runtime(),
              "interval_sha256": _interval(request["transcript_path"], source["identity"],
                                          source["start_offset"], source["end_offset"])}
    configuration, route = _backend(paths)
    _require(_same(configuration["memory"], memory)
             and _same(route["transport"], _effective_transport(paths, transport)), "backend_changed")
    inputs = {"request": journal.encode(request), "admission": admission_raw, "cursor": state_raw,
              "parser_state": journal.encode(parser), "next_parser_state": journal.encode(expected_next_parser),
              "backend_route": journal.encode(route), "backend_config": journal.encode(configuration)}
    inputs = {key: journal.seal_json(raw) for key, raw in inputs.items()}
    value = {"version": 1, "host": host, "session_id": request["session_id"], "run_id": paths.run_dir.name,
             "inputs": inputs, "source": source, "expected_scope": copy.deepcopy(scope),
             "backend": {"route_id": "stdio-" + journal.sha256(journal.encode(route["launch"])),
                         "runtime_sha256": route["runtime"]["sha256"],
                         "route_sha256": inputs["backend_route"]["sha256"],
                         "config_sha256": inputs["backend_config"]["sha256"]}, "fencing": writer_fence.binding()}
    if provider_mode is not None:
        value["provider_mode"] = provider_mode
        value["plan_policy"] = copy.deepcopy(plan_policy)
    else:
        _require(plan_policy is None, "orphan_plan_policy")
    journal._manifest(value)
    context = ExecutionContext(paths, value, journal.sha256(journal.encode(value)), writer_fence)

    def verified(binding):
        _require(writer_fence.verify(binding) is True, "writer_unfenced")
        return context._validate(value, before_marker=True)

    digest = journal.publish_manifest(paths.run_dir, value, verify_fence=verified)
    _require(digest == context.manifest_sha256, "manifest_changed")
    return context


@_safe
def load_execution(paths, *, manifest_sha256, writer_fence, before_marker=False, source_backend_only=False):
    """Reopen only the exact already-sealed run using trusted caller paths."""
    _require(type(paths) is ContextPaths and type(before_marker) is bool
             and type(source_backend_only) is bool and not (before_marker and source_backend_only), "invalid_context")
    paths.check()
    manifest, digest = journal.read_manifest(paths.run_dir)
    _require(digest == manifest_sha256, "manifest_changed")
    context = ExecutionContext(paths, manifest, digest, writer_fence)
    if source_backend_only:
        context.validate_source_backend(manifest)
    elif before_marker:
        context.validate_marker(manifest)
    else:
        context._validate(manifest)
    return context
