"""Pure Markdown-to-Slack release formatting; no network or environment access."""

from __future__ import annotations

import html
import re
from urllib.parse import quote, urlsplit

SECTION_LIMIT = 3000
HEADER_LIMIT = 150
MAX_NOTE_SECTIONS = 45  # Leave room for the heading and truncation notice.

_FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})(.*)$")
_HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$")
_LIST = re.compile(r"^(\s*)([-+*]|\d+[.)])\s+(.+)$")
_LINK = re.compile(r"\[([^\]\n]+)\]\(([^\s()]+)(?:\s+[\"'][^\n]*?[\"'])?\)")


def _escape(text: str) -> str:
    # Slack's mrkdwn escape set. In particular, this disables <!here> and
    # <@USER> syntax in release notes, without corrupting ordinary Unicode.
    return html.escape(text, quote=False)


def _web_url(url: str) -> bool:
    try:
        parsed = urlsplit(url)
        return (
            parsed.scheme in {"https", "http"}
            and bool(parsed.hostname)
            and not parsed.username
            and not parsed.password
            and not any(character.isspace() or ord(character) < 32 for character in url)
        )
    except ValueError:
        return False


def _slack_url(url: str) -> str:
    return _escape(quote(url, safe=":/?#[]@!$&'()*+,;=%-._~"))


def _inline(text: str, *, allow_links: bool = True) -> str:
    """Convert the supported inline constructs without interpreting Slack tags."""
    result: list[str] = []
    index = 0
    while index < len(text):
        if text[index] == "`":
            end_ticks = index
            while end_ticks < len(text) and text[end_ticks] == "`":
                end_ticks += 1
            ticks = text[index:end_ticks]
            end = text.find(ticks, end_ticks)
            if end != -1:
                content = text[end_ticks:end].replace("`", "`\u200b")
                result.append("`" + _escape(content) + "`")
                index = end + len(ticks)
                continue
        if allow_links and text[index] == "[":
            match = _LINK.match(text, index)
            if match and _web_url(match[2]):
                label = _inline(match[1], allow_links=False).replace("|", "¦")
                link = f"<{_slack_url(match[2])}|{label}>"
                # Exceptionally long links must remain splittable text.
                result.append(link if len(link) <= 2000 else _escape(match[0]))
                index = match.end()
                continue
        if text.startswith(("**", "__"), index):
            marker = text[index : index + 2]
            end = text.find(marker, index + 2)
            if end > index + 2:
                result.append("*" + _inline(text[index + 2 : end], allow_links=allow_links) + "*")
                index = end + 2
                continue
        result.append(_escape(text[index]))
        index += 1
    return "".join(result)


def _blocks(body: str) -> list[tuple[str, str]]:
    """Return rendered prose/code blocks while retaining semantic boundaries."""
    blocks: list[tuple[str, str]] = []
    pending: list[str] = []
    pending_prefix = ""
    fence: str | None = None
    code: list[str] = []
    blank_pending = False

    def flush() -> None:
        nonlocal pending_prefix
        if pending:
            blocks.append(("prose", pending_prefix + _inline(" ".join(pending))))
            pending.clear()
        pending_prefix = ""

    for line in body.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        marker = _FENCE.match(line)
        if fence is not None:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                # Slack supports triple-backtick fences, independent of the
                # Markdown fence's language, delimiter, or delimiter length.
                blocks.append(("code", _escape("\n".join(code)).replace("```", "``\u200b`")))
                code = []
                fence = None
            else:
                code.append(line)
            continue
        if marker:
            flush()
            if blank_pending and blocks and blocks[-1][0] != "blank":
                blocks.append(("blank", ""))
            blank_pending = False
            fence = marker[1]
            continue
        if not line.strip():
            flush()
            blank_pending = True
            continue
        if blank_pending and blocks and blocks[-1][0] != "blank":
            blocks.append(("blank", ""))
        blank_pending = False
        heading = _HEADING.match(line)
        item = _LIST.match(line)
        if heading:
            flush()
            blocks.append(("prose", "*" + _inline(heading[1]) + "*"))
        elif item:
            flush()
            indent, marker_text, content = item.groups()
            bullet = "•" if marker_text in {"-", "+", "*"} else marker_text
            pending_prefix = indent.expandtabs(4) + bullet + " "
            pending = [content.strip()]
        elif re.fullmatch(r"\s*(?:-{3,}|\*{3,}|_{3,})\s*", line):
            flush()
            blocks.append(("prose", "—"))
        else:
            pending.append(line.strip())
    flush()
    if fence is not None:
        # Malformed/unclosed Markdown still gets a balanced Slack code block.
        blocks.append(("code", _escape("\n".join(code)).replace("```", "``\u200b`")))
    while blocks and blocks[-1][0] == "blank":
        blocks.pop()
    return blocks


def format_notes(body: str) -> str:
    """Format complete release notes, with soft wraps joined and no truncation."""
    return "\n".join("```\n" + value + "\n```" if kind == "code" else value for kind, value in _blocks(body))


def _pieces(text: str, limit: int) -> list[str]:
    """Split only when required, preferring lines/sentences/word boundaries."""
    pieces: list[str] = []
    while len(text) > limit:
        cut = text.rfind("\n", 0, limit + 1)
        if cut < limit // 2:
            sentences = list(re.finditer(r"(?<=[.!?])\s+", text[: limit + 1]))
            cut = sentences[-1].start() if sentences else -1
        if cut < limit // 2:
            cut = text.rfind(" ", 0, limit + 1)
        if cut <= 0:
            cut = limit
        # Keep generated Slack links and HTML entities intact at hard splits.
        opening = text.rfind("<", 0, cut)
        closing = text.rfind(">", 0, cut)
        if opening > closing:
            end = text.find(">", cut)
            if opening > 0:
                cut = opening
            elif end != -1 and end + 1 <= limit:
                cut = end + 1
        amp = text.rfind("&", 0, cut)
        if amp >= 0 and re.match(r"&(?:amp|lt|gt);", text[amp:]) and ";" not in text[amp:cut]:
            cut = amp
        if cut <= 0:
            cut = limit
        pieces.append(text[:cut])
        text = text[cut:]
        # A separating whitespace character has become the section boundary.
        if text.startswith((" ", "\n")):
            text = text[1:]
    if text:
        pieces.append(text)
    return pieces


def _sections(body: str) -> list[str]:
    sections: list[str] = []
    current = ""
    for kind, value in _blocks(body):
        if kind == "code":
            chunks = ["```\n" + chunk + "\n```" for chunk in (_pieces(value, SECTION_LIMIT - 8) or [""])]
        else:
            chunks = _pieces(value, SECTION_LIMIT) or [""]
        for chunk in chunks:
            combined = current + "\n" + chunk if current else chunk
            if len(combined) <= SECTION_LIMIT:
                current = combined
            else:
                sections.append(current.rstrip("\n"))
                current = chunk
    if current.strip():
        sections.append(current.rstrip("\n"))
    return sections or ["No release notes provided."]


def build_payload(product: str, tag: str, release_url: str, body: str, icon_url: str | None = None) -> dict:
    """Build an incoming-webhook payload; the caller owns delivery and credentials."""
    if not _web_url(release_url):
        raise ValueError("release_url must be an absolute HTTP(S) URL without credentials")
    if icon_url is not None and not _web_url(icon_url):
        raise ValueError("icon_url must be an absolute HTTP(S) URL without credentials")
    product = " ".join(product.split())
    tag = " ".join(tag.split())
    title = f"✅ {product} {tag} released"
    header = title if len(title) <= HEADER_LIMIT else title[: HEADER_LIMIT - 1] + "…"
    if icon_url is not None:
        # Section accessories sit to the right of their text. Header blocks
        # cannot have accessories, so use a bold section for branded releases.
        # Count escaping and the bold delimiters in the heading's size budget.
        if len(_escape(header)) + 2 > HEADER_LIMIT:
            header = header.removesuffix("…")
            while len(_escape(header)) + 3 > HEADER_LIMIT:
                header = header[:-1]
            header += "…"
        blocks: list[dict] = [{
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*{_escape(header)}*", "verbatim": True},
            "accessory": {"type": "image", "image_url": icon_url, "alt_text": f"{product[:100]} icon"},
        }]
    else:
        blocks = [{"type": "header", "text": {"type": "plain_text", "text": header}}]
    sections = _sections(body)
    shortened = len(sections) > MAX_NOTE_SECTIONS
    for index, section in enumerate(sections[:MAX_NOTE_SECTIONS]):
        block = {"type": "section", "text": {"type": "mrkdwn", "text": section, "verbatim": True}}
        if index == 0:
            block["accessory"] = {"type": "button", "text": {"type": "plain_text", "text": "View Release"}, "url": release_url}
        blocks.append(block)
    if shortened:
        blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": f"Notes shortened. <{_slack_url(release_url)}|Read the complete release notes>.", "verbatim": True}]})
    notes = format_notes(body) or "No release notes provided."
    # Reuse a complete rendered section so a long code sample does not leave
    # an unclosed fence in the accessible fallback.
    summary = sections[0] if len(notes) > SECTION_LIMIT else notes
    if len(summary) < len(notes):
        summary += "\nNotes shortened; complete notes are linked below."
    # Include the actual content, not merely a heading: screen readers and
    # notifications may use this field instead of reading the blocks.
    fallback = f"{_escape(header)}\n{summary}\n<{_slack_url(release_url)}|View Release>"
    return {"text": fallback, "blocks": blocks, "unfurl_links": False, "unfurl_media": False}
