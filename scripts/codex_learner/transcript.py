"""Read visible Codex conversation text without ingesting tools or reasoning.

The durable cursor is ``(next_offset, recent_messages, current_turn_id)``. Commit
all three only after the excerpt has been successfully learned. Offsets are
binary JSONL record boundaries, never text-file cookies. A partial final record
or an oversized visible message remains pending; no suffix is silently dropped.

This module intentionally does not follow ``history_base`` into parent files or
read compacted replacement histories. Unknown fork layouts fail closed rather
than learning an inherited conversation a second time.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
from typing import Any, BinaryIO


DEFAULT_MAX_CHARS = 24_000
DEFAULT_MAX_SCAN_BYTES = 8 * 1024 * 1024
MAX_METADATA_BYTES = 1024 * 1024
MAX_RECENT_MESSAGES = 128
VISIBLE_CHANNELS = {None, "final", "final_answer", "commentary"}


class TranscriptError(ValueError):
    """Invalid metadata or a cursor that cannot be safely resumed."""


@dataclass(frozen=True)
class RolloutMetadata:
    path: str
    session_id: str
    cwd: str | None
    source: str | dict[str, Any] | None
    parent_session_id: str | None
    history_mode: str | None
    history_start_ordinal: int | None
    fork_boundary_known: bool
    start_offset: int
    size_bytes: int
    mtime_ns: int
    device: int
    inode: int
    hook_session_id: str | None = None


@dataclass(frozen=True)
class Excerpt:
    metadata: RolloutMetadata
    text: str
    next_offset: int
    has_more: bool
    blocked_reason: str | None
    diagnostics: dict[str, int]
    recent_messages: list[dict[str, Any]]
    current_turn_id: str | None
    message_count: int


def _nonnegative_int(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def _string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def inspect_rollout(path: str | Path) -> RolloutMetadata:
    """Inspect only the first complete metadata record, never its instructions.

    Subagents can put the logical root session's ID in ``session_id`` and their
    own thread ID in ``id``. For nested agents the logical root can differ from
    the immediate parent. Preserve the former as ``hook_session_id`` while the
    latter remains canonical. Later inherited ``session_meta`` records must not
    override either identity.
    """
    rollout = Path(path)
    with rollout.open("rb") as stream:
        return _inspect_stream(rollout, stream)


def _inspect_stream(path: Path, stream: BinaryIO) -> RolloutMetadata:
    import os

    stat = os.fstat(stream.fileno())
    line = stream.readline(MAX_METADATA_BYTES + 1)
    if len(line) > MAX_METADATA_BYTES or not line.endswith(b"\n"):
        raise TranscriptError("missing, incomplete, or oversized initial session metadata")
    try:
        record = json.loads(line)
    except (ValueError, UnicodeError) as error:
        raise TranscriptError("invalid initial session metadata") from error
    if not isinstance(record, dict) or record.get("type") != "session_meta":
        raise TranscriptError("initial record is not session_meta")
    payload = record.get("payload")
    if not isinstance(payload, dict):
        raise TranscriptError("session_meta payload is not an object")
    session_id = _string(payload.get("id")) or _string(payload.get("session_id"))
    if session_id is None:
        raise TranscriptError("session_meta has no session ID")
    source = payload.get("source")
    if not isinstance(source, (str, dict)):
        source = None
    parent = _string(payload.get("forked_from_id")) or _string(payload.get("parent_thread_id"))
    if not parent and isinstance(source, dict):
        subagent = source.get("subagent")
        spawn = subagent.get("thread_spawn") if isinstance(subagent, dict) else None
        if isinstance(spawn, dict):
            parent = _string(spawn.get("parent_thread_id"))
    start_ordinal = _nonnegative_int(payload.get("subagent_history_start_ordinal"))
    boundary_known = parent is None or start_ordinal is not None
    fork_ordinal = _nonnegative_int(payload.get("forked_from_ordinal_exclusive"))
    meta_ordinal = _nonnegative_int(record.get("ordinal"))
    history_base = payload.get("history_base")
    if isinstance(history_base, dict):
        base_ordinal = _nonnegative_int(history_base.get("end_ordinal_exclusive"))
        parent = parent or _string(history_base.get("thread_id"))
        # A history_base pointer means inherited history is stored elsewhere.
        # The ordinal guard additionally excludes any older materialized items.
        if base_ordinal is not None:
            start_ordinal = start_ordinal if start_ordinal is not None else base_ordinal
            boundary_known = True
        elif parent is not None and start_ordinal is None:
            boundary_known = False
    elif start_ordinal is None and fork_ordinal is not None:
        # The parent's ordinal is meaningful locally only when the first local
        # record continues that sequence. Legacy re-numbered forks are ambiguous.
        if meta_ordinal is not None and meta_ordinal >= fork_ordinal:
            start_ordinal = fork_ordinal
            boundary_known = True
    return RolloutMetadata(
        path=str(path.resolve()),
        session_id=session_id,
        cwd=_string(payload.get("cwd")),
        source=source,
        parent_session_id=parent,
        history_mode=_string(payload.get("history_mode")),
        history_start_ordinal=start_ordinal,
        fork_boundary_known=boundary_known,
        start_offset=stream.tell(),
        size_bytes=stat.st_size,
        mtime_ns=stat.st_mtime_ns,
        device=stat.st_dev,
        inode=stat.st_ino,
        hook_session_id=_string(payload.get("session_id")),
    )


_PRIVATE_KEY = re.compile(
    r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----.*?"
    r"-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----",
    re.DOTALL,
)
_BEARER = re.compile(r"\b(Bearer\s+)[A-Za-z0-9._~+/=-]+", re.IGNORECASE)
_CREDENTIAL = re.compile(
    r"(?i)(\b(?:api[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|"
    r"password|passwd|secret|ORBITAL_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY)"
    r"\b[\"']?\s*[:=]\s*)(?:\"[^\"\n]*\"|'[^'\n]*'|[^\s,;]+)"
)
_KNOWN_TOKEN = re.compile(
    r"\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}|"
    r"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|"
    r"xox[baprs]-[A-Za-z0-9-]{12,})\b"
)
_URL_PASSWORD = re.compile(r"(https?://[^\s/@:]+:)[^\s/@]+(@)")
_PEM_START = re.compile(r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----")


def redact_secrets(text: str) -> str:
    """Mask common credentials in visible prose; not a universal secret detector.

    Raw tool records are excluded before this function. Applications should
    still treat the resulting conversation excerpt as private user data.
    """
    text = _PRIVATE_KEY.sub("[REDACTED PRIVATE KEY]", text)
    # A partial pasted key should not leak just because its footer is missing.
    match = _PEM_START.search(text)
    if match:
        text = text[: match.start()] + "[REDACTED INCOMPLETE PRIVATE KEY]"
    text = _BEARER.sub(r"\1[REDACTED]", text)
    text = _CREDENTIAL.sub(r"\1[REDACTED]", text)
    text = _KNOWN_TOKEN.sub("[REDACTED]", text)
    return _URL_PASSWORD.sub(r"\1[REDACTED]\2", text)


def _text_parts(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for part in content:
        if isinstance(part, dict) and part.get("type") in {"input_text", "output_text", "text"}:
            text = part.get("text")
            if isinstance(text, str):
                parts.append(text)
    return "\n".join(parts)


def _visible_message(
    record: dict[str, Any], current_turn_id: str | None
) -> tuple[str, str, str, str | None, str | None] | None:
    payload = record.get("payload")
    if not isinstance(payload, dict):
        return None
    role: str | None = None
    text = ""
    item_id = _string(payload.get("id"))
    turn_id = _string(payload.get("turn_id")) or current_turn_id
    channel = payload.get("channel") or payload.get("phase")
    record_type = record.get("type")
    if record_type == "response_item" and payload.get("type") == "message":
        role = payload.get("role")
        text = _text_parts(payload.get("content"))
        passthrough = payload.get("internal_chat_message_metadata_passthrough")
        if isinstance(passthrough, dict):
            turn_id = _string(passthrough.get("turn_id")) or turn_id
        source = "response"
    elif record_type == "event_msg" and payload.get("type") in {"user_message", "agent_message"}:
        role = "user" if payload["type"] == "user_message" else "assistant"
        text = _text_parts(payload.get("message"))
        source = "event"
    elif record_type == "event_msg" and payload.get("type") == "item_completed":
        item = payload.get("item")
        if not isinstance(item, dict) or item.get("type") not in {"UserMessage", "AgentMessage"}:
            return None
        role = "user" if item["type"] == "UserMessage" else "assistant"
        text = _text_parts(item.get("content"))
        channel = item.get("channel") or item.get("phase")
        item_id = _string(item.get("id"))
        source = "item_completed"
    else:
        return None
    if role not in {"user", "assistant"} or channel not in VISIBLE_CHANNELS:
        return None
    if payload.get("recipient") not in {None, "all"}:
        return None
    text = text.strip()
    if not text:
        return None
    # Codex stores injected environment text as user messages too. These are
    # machine context, not user decisions, and can contain unrelated paths.
    if role == "user" and text.startswith(("<environment_context>", "<permissions instructions>", "<codex_delegation>")):
        return None
    return role, text, source, item_id, turn_id


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _dedup_entry(
    role: str, text: str, source: str, item_id: str | None, turn_id: str | None
) -> dict[str, Any]:
    return {
        "content_hash": _hash(role + "\0" + text),
        "id_hash": _hash(role + "\0" + item_id) if item_id else None,
        "turn_hash": _hash(turn_id) if turn_id else None,
        "sources": [source],
    }


def _duplicate_index(recent: list[dict[str, Any]], entry: dict[str, Any]) -> int | None:
    for index in range(len(recent) - 1, -1, -1):
        previous = recent[index]
        if entry["id_hash"] and previous.get("id_hash") == entry["id_hash"]:
            return index
        if previous.get("content_hash") != entry["content_hash"]:
            continue
        if entry["sources"][0] in previous.get("sources", []):
            # Repeated genuine messages (e.g. a second "yes") remain distinct.
            continue
        if previous.get("turn_hash") == entry["turn_hash"]:
            return index
        # Old event formats omit turn IDs. Match only the adjacent visible
        # message, so an old identical answer is not mistaken for a mirror.
        if index == len(recent) - 1 and (not previous.get("turn_hash") or not entry["turn_hash"]):
            return index
    return None


def _copy_recent(recent: list[dict[str, Any]] | None) -> list[dict[str, Any]]:
    result = []
    for entry in (recent or [])[-MAX_RECENT_MESSAGES:]:
        if not isinstance(entry, dict) or not isinstance(entry.get("content_hash"), str):
            continue
        result.append({
            "content_hash": entry["content_hash"],
            "id_hash": entry.get("id_hash"),
            "turn_hash": entry.get("turn_hash"),
            "sources": [source for source in entry.get("sources", []) if source in {"response", "event", "item_completed"}],
        })
    return result


def read_excerpt(
    path: str | Path,
    start_offset: int = 0,
    *,
    max_chars: int = DEFAULT_MAX_CHARS,
    max_scan_bytes: int = DEFAULT_MAX_SCAN_BYTES,
    recent_messages: list[dict[str, Any]] | None = None,
    current_turn_id: str | None = None,
) -> Excerpt:
    """Return a bounded excerpt and the exact safely consumed byte boundary.

    ``blocked_reason`` is ``partial_final_record``, ``record_exceeds_scan_limit``,
    ``message_exceeds_char_limit``, ``ambiguous_fork_history``, or
    ``missing_fork_ordinal`` when explicit intervention/retry is needed. Ordinary
    full batches have ``has_more=True`` without a blocked reason. Malformed
    newline-terminated records are counted in diagnostics, never included.

    A message larger than ``max_chars`` is not truncated or consumed. The caller
    can raise the limit deliberately, or record an explicit excluded range;
    it must not treat that condition as successful learning.
    """
    if _nonnegative_int(start_offset) is None:
        raise TranscriptError("start_offset must be a nonnegative integer")
    if max_chars < 1 or max_scan_bytes < 1:
        raise TranscriptError("limits must be positive")
    recent = _copy_recent(recent_messages)
    diagnostics = {"malformed_records": 0, "excluded_records": 0, "inherited_records": 0, "duplicate_messages": 0, "redacted_messages": 0}
    chunks: list[str] = []
    chars = 0
    blocked = None
    with Path(path).open("rb") as stream:
        metadata = _inspect_stream(Path(path), stream)
        if start_offset > metadata.size_bytes:
            raise TranscriptError("cursor is beyond file size; rollout was truncated or replaced")
        if start_offset:
            stream.seek(start_offset - 1)
            if stream.read(1) != b"\n":
                raise TranscriptError("cursor is not a complete JSONL record boundary")
        offset = max(start_offset, metadata.start_offset)
        if not metadata.fork_boundary_known:
            return Excerpt(metadata, "", start_offset, True, "ambiguous_fork_history", diagnostics, recent, current_turn_id, 0)
        stream.seek(offset)
        scan_start = offset
        while offset < metadata.size_bytes:
            remaining = max_scan_bytes - (offset - scan_start)
            if remaining <= 0:
                break
            line = stream.readline(min(remaining + 1, metadata.size_bytes - offset))
            if len(line) > remaining:
                if offset == scan_start:
                    blocked = "record_exceeds_scan_limit"
                break
            if not line.endswith(b"\n"):
                blocked = "partial_final_record"
                break
            end_offset = offset + len(line)
            try:
                record = json.loads(line)
                if not isinstance(record, dict):
                    raise ValueError("record must be an object")
            except (ValueError, UnicodeError):
                diagnostics["malformed_records"] += 1
                offset = end_offset
                continue
            if metadata.history_start_ordinal is not None:
                ordinal = _nonnegative_int(record.get("ordinal"))
                if ordinal is None:
                    # Metadata can be nested in a materialized fork, but no
                    # visible text is safe without its boundary discriminator.
                    if _visible_message(record, current_turn_id) is not None:
                        blocked = "missing_fork_ordinal"
                        break
                elif ordinal < metadata.history_start_ordinal:
                    diagnostics["inherited_records"] += 1
                    offset = end_offset
                    continue
            payload = record.get("payload")
            if isinstance(payload, dict) and (
                record.get("type") == "turn_context"
                or (record.get("type") == "event_msg" and payload.get("type") == "task_started")
            ):
                current_turn_id = _string(payload.get("turn_id")) or current_turn_id
            visible = _visible_message(record, current_turn_id)
            if visible is None:
                diagnostics["excluded_records"] += 1
                offset = end_offset
                continue
            role, raw_text, source, item_id, turn_id = visible
            entry = _dedup_entry(role, raw_text, source, item_id, turn_id)
            duplicate = _duplicate_index(recent, entry)
            if duplicate is not None:
                prior = recent[duplicate]
                prior["sources"] = sorted(set(prior["sources"]) | {source})
                prior["id_hash"] = prior.get("id_hash") or entry["id_hash"]
                prior["turn_hash"] = prior.get("turn_hash") or entry["turn_hash"]
                diagnostics["duplicate_messages"] += 1
                offset = end_offset
                continue
            safe_text = redact_secrets(raw_text)
            chunk = ("\n\n" if chunks else "") + "[" + role.upper() + "]\n" + safe_text
            if chars + len(chunk) > max_chars:
                if not chunks:
                    blocked = "message_exceeds_char_limit"
                break
            if safe_text != raw_text:
                diagnostics["redacted_messages"] += 1
            chunks.append(chunk)
            chars += len(chunk)
            recent.append(entry)
            recent = recent[-MAX_RECENT_MESSAGES:]
            offset = end_offset
        return Excerpt(
            metadata=metadata,
            text="".join(chunks),
            next_offset=offset,
            has_more=offset < metadata.size_bytes,
            blocked_reason=blocked,
            diagnostics=diagnostics,
            recent_messages=recent,
            current_turn_id=current_turn_id,
            message_count=len(chunks),
        )
