"""Every QML Text element that renders transcript- or user-derived text
must declare an explicit textFormat: the AutoText default renders such
strings as rich text, and Qt then fetches any embedded <img> URL —
network egress from untrusted content (verified empirically offscreen).
"""

import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Bindings that carry untrusted content (transcript, skill or user input).
UNTRUSTED = (
    "session.title", "session.id", "selectedSession", "renameSession",
    "modelData.text", "modelData.who", "previewFirst", "previewLast",
    "selectedSkill", "previewSkillDoc", "filterText", "renameText",
    "root.message",
)


def text_blocks(source):
    """Yield (line, block) for each `Text {` element, by brace matching."""
    for match in re.finditer(r"\bText \{", source):
        depth, i = 0, match.start()
        while i < len(source):
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        yield source[: match.start()].count("\n") + 1, source[match.start():i]


class TestPlainTextOnUntrustedSinks(unittest.TestCase):
    def test_untrusted_text_elements_declare_a_textformat(self):
        for name in ("Menu.qml", "ConfirmBox.qml"):
            with open(os.path.join(ROOT, name), encoding="utf-8") as fh:
                source = fh.read()
            for line, block in text_blocks(source):
                # The binding runs from `text:` to the next property line,
                # so markers in `visible:` etc. don't count.
                binding = re.search(
                    r"^\s*text:(?:.+\n)+?(?=\s*[\w.]+:|\s*\})",
                    block + "\n", re.MULTILINE)
                if not binding:
                    continue
                if any(marker in binding.group(0) for marker in UNTRUSTED):
                    self.assertIn(
                        "textFormat", block,
                        "%s:%d renders untrusted content without an "
                        "explicit textFormat" % (name, line))


if __name__ == "__main__":
    unittest.main()
