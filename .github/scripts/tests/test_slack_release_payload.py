import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from slack_release_payload import HEADER_LIMIT, SECTION_LIMIT, build_payload, format_notes


class SlackReleasePayloadTests(unittest.TestCase):
    url = "https://github.com/jsflax/Engram/releases/tag/v0.15.20"

    def payload(self, body, **kwargs):
        return build_payload("Engram", "v0.15.20", self.url, body, **kwargs)

    def sections(self, payload):
        return [block["text"]["text"] for block in payload["blocks"] if block["type"] == "section"]

    def test_actual_engram_soft_wrapped_bullet(self):
        body = """### Fixed
- Suspend fully transparent near and far nebula emitters so hidden effects do
  not continue particle simulation. Restore opacity before reactivating an
  emitter, including small positive fades, and preserve visible particle density.

### Changed
- Update Lattice Swift SDK to 2.2.5 while retaining LatticeCore 2.2.8.
"""
        expected = "*Fixed*\n• Suspend fully transparent near and far nebula emitters so hidden effects do not continue particle simulation. Restore opacity before reactivating an emitter, including small positive fades, and preserve visible particle density.\n\n*Changed*\n• Update Lattice Swift SDK to 2.2.5 while retaining LatticeCore 2.2.8."
        self.assertEqual(format_notes(body), expected)
        payload = self.payload(body)
        self.assertEqual(self.sections(payload), [expected])
        roundtrip = json.loads(json.dumps(payload))
        self.assertIn("\n\n*Changed*\n", self.sections(roundtrip)[0])
        self.assertNotIn("\\n", self.sections(roundtrip)[0])

    def test_paragraphs_nested_bullets_ordered_items_and_headings(self):
        body = "Intro softly\nwrapped.\n\nAnother paragraph.\n\n### Changes\n- Parent\n  continuation.\n  - Child\n    continuation.\n  - Second child\n- Next parent\n1. Step one\n   continued.\n2. Step two"
        self.assertEqual(format_notes(body), "Intro softly wrapped.\n\nAnother paragraph.\n\n*Changes*\n• Parent continuation.\n  • Child continuation.\n  • Second child\n• Next parent\n1. Step one continued.\n2. Step two")

    def test_code_keeps_whitespace_and_does_not_convert_markdown(self):
        body = "Before.\n\n```python\n  print('**bold** <@U123> &')\n\n  value = 2\n```\n\nAfter."
        rendered = format_notes(body)
        self.assertIn("```\n  print('**bold** &lt;@U123&gt; &amp;')\n\n  value = 2\n```", rendered)
        self.assertTrue(rendered.endswith("\n\nAfter."))
        self.assertIn("`**literal** &lt;@U1&gt;`", format_notes("`**literal** <@U1>`"))

    def test_unclosed_and_longer_fences_are_balanced(self):
        self.assertEqual(format_notes("~~~text\ncode\n  preserved"), "```\ncode\n  preserved\n```")
        rendered = format_notes("````\n```\n````")
        self.assertEqual(rendered.count("```"), 2)
        self.assertIn("``\u200b`", rendered)

    def test_links_bold_ampersands_and_mentions(self):
        body = "**Fixed** & <raw> <!here> <@U123> [**notes**](https://example.com/a?b=1&c=2) [bad](javascript:alert) __also bold__"
        rendered = format_notes(body)
        self.assertIn("*Fixed* &amp; &lt;raw&gt; &lt;!here&gt; &lt;@U123&gt;", rendered)
        self.assertIn("<https://example.com/a?b=1&amp;c=2|*notes*>", rendered)
        self.assertIn("[bad](javascript:alert)", rendered)
        self.assertIn("*also bold*", rendered)
        self.assertTrue(self.payload(body)["blocks"][1]["text"]["verbatim"])

    def test_malformed_markdown_stays_text(self):
        body = "[unfinished\n**unclosed & <@U1>\n[no](data:text/plain,hello)\n[pipe|label](https://example.com/a|b)"
        rendered = format_notes(body)
        self.assertNotIn("<@U1>", rendered)
        self.assertIn("[no](data:text/plain,hello)", rendered)
        self.assertIn("<https://example.com/a%7Cb|pipe¦label>", rendered)

    def test_more_than_twenty_lines_are_not_dropped(self):
        body = "\n".join(f"- Item {index}." for index in range(80))
        rendered = "\n".join(self.sections(self.payload(body)))
        for index in range(80):
            self.assertIn(f"• Item {index}.", rendered)

    def test_sections_respect_limits_and_keep_all_sentences(self):
        sentences = [f"Sentence {index} " + "substantial " * 12 + "." for index in range(160)]
        sections = self.sections(self.payload(" ".join(sentences)))
        self.assertTrue(all(0 < len(section) <= SECTION_LIMIT for section in sections))
        combined = " ".join(sections)
        for sentence in sentences:
            self.assertIn(sentence, combined)

    def test_long_code_sections_remain_balanced(self):
        lines = [f"  line_{index} = {index}" for index in range(500)]
        sections = self.sections(self.payload("```\n" + "\n".join(lines) + "\n```"))
        self.assertTrue(all(len(section) <= SECTION_LIMIT and section.count("```") == 2 for section in sections))
        for line in lines:
            self.assertIn(line, "\n".join(sections))

    def test_extremely_long_token_entities_and_links(self):
        body = "x" * 4000 + " & " + "y" * 4000 + " [link](https://example.com/" + "z" * 5000 + ")"
        sections = self.sections(self.payload(body))
        self.assertTrue(all(len(section) <= SECTION_LIMIT for section in sections))
        self.assertIn("&amp;", " ".join(sections))
        # The oversized link falls back to text instead of an invalid Slack tag.
        self.assertNotIn("<https://", "".join(sections))

    def test_section_boundary_does_not_split_a_generated_link(self):
        label = "word " * 350
        body = f"[{label}](https://example.com/) " + "x" * 4000
        sections = self.sections(self.payload(body))
        self.assertTrue(all(len(section) <= SECTION_LIMIT for section in sections))
        self.assertIn("<https://example.com/|" + label + ">", sections[0])

    def test_fallback_keeps_long_code_fences_balanced(self):
        payload = self.payload("```\n" + "\n".join("some code " * 20 for _ in range(100)) + "\n```")
        self.assertEqual(payload["text"].count("```"), 2)

    def test_huge_notes_have_bounded_blocks_and_explicit_full_notes_link(self):
        body = "\n\n".join("Paragraph " + str(index) + ": " + "word " * 500 for index in range(100))
        payload = self.payload(body, icon_url="https://example.com/icon.png")
        self.assertLessEqual(len(payload["blocks"]), 50)
        self.assertTrue(all(len(section) <= SECTION_LIMIT for section in self.sections(payload)))
        notice = payload["blocks"][-1]["elements"][0]["text"]
        self.assertIn("Notes shortened.", notice)
        self.assertIn(self.url, notice)
        self.assertIn("Notes shortened", payload["text"])

    def test_icon_is_right_of_heading_and_button_stays_with_notes(self):
        payload = build_payload("Lattice" * 100, "v2.0.6", self.url, "- Useful change.", "https://example.com/icon.png")
        heading, notes = payload["blocks"]
        self.assertEqual(heading["type"], "section")
        self.assertEqual(heading["text"]["type"], "mrkdwn")
        self.assertTrue(heading["text"]["verbatim"])
        self.assertTrue(heading["text"]["text"].startswith("*✅ Lattice"))
        self.assertTrue(heading["text"]["text"].endswith("…*"))
        self.assertLessEqual(len(heading["text"]["text"]), HEADER_LIMIT)
        self.assertEqual(heading["accessory"]["type"], "image")
        self.assertEqual(heading["accessory"]["image_url"], "https://example.com/icon.png")
        self.assertIn("Useful change.", payload["text"])
        self.assertEqual(notes["text"]["text"], "• Useful change.")
        self.assertEqual(notes["accessory"]["type"], "button")
        self.assertEqual(notes["accessory"]["text"]["text"], "View Release")
        self.assertEqual(notes["accessory"]["url"], self.url)

    def test_branded_heading_escapes_slack_syntax_within_size_budget(self):
        payload = build_payload("Lattice <!here> &", "v2.0.6", self.url, "Notes", "https://example.com/icon.png")
        heading = payload["blocks"][0]["text"]
        self.assertEqual(heading["text"], "*✅ Lattice &lt;!here&gt; &amp; v2.0.6 released*")
        self.assertTrue(heading["verbatim"])
        oversized = build_payload("&" * 100, "v2.0.6", self.url, "Notes", "https://example.com/icon.png")
        text = oversized["blocks"][0]["text"]["text"]
        self.assertLessEqual(len(text), HEADER_LIMIT)
        self.assertRegex(text, r"^(?:[^&]|&amp;)*$")
        self.assertTrue(text.endswith("…*"))

    def test_unbranded_release_keeps_plain_text_header(self):
        payload = self.payload("- Useful change.")
        self.assertEqual(payload["blocks"][0], {
            "type": "header",
            "text": {"type": "plain_text", "text": "✅ Engram v0.15.20 released"},
        })
        self.assertEqual(payload["blocks"][1]["accessory"]["type"], "button")

    def test_missing_notes_and_invalid_urls(self):
        self.assertEqual(self.sections(self.payload(" \n\r\n")), ["No release notes provided."])
        for url in ("javascript:alert(1)", "https://example.com\n<!here>", "https://user:password@example.com", "not-a-url"):
            with self.assertRaises(ValueError):
                build_payload("Engram", "v1", url, "Notes")


if __name__ == "__main__":
    unittest.main()
