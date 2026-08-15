"""Unit tests for omaconv-render, on fixture transcripts."""

import importlib.machinery
import importlib.util
import io
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader(
    "omaconv_render", os.path.join(HERE, "..", "omaconv-render"))
spec = importlib.util.spec_from_loader("omaconv_render", loader)
rnd = importlib.util.module_from_spec(spec)
loader.exec_module(rnd)


def render_lines(objs, raw_lines=()):
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
        for o in objs:
            fh.write(json.dumps(o) + "\n")
        for line in raw_lines:
            fh.write(line + "\n")
        path = fh.name
    out = io.StringIO()
    try:
        code = rnd.render(path, out)
    finally:
        os.unlink(path)
    return code, out.getvalue()


class TestRender(unittest.TestCase):
    def test_dialogue_keeps_user_and_assistant_text_only(self):
        code, text = render_lines([
            {"type": "user", "timestamp": "2026-08-15T10:00:00Z",
             "message": {"role": "user", "content": "salut, une question"}},
            {"type": "assistant",
             "message": {"content": [
                 {"type": "thinking", "thinking": "hmm secret"},
                 {"type": "text", "text": "voici la réponse"},
                 {"type": "tool_use", "name": "Bash"}]}},
            {"type": "user",
             "message": {"content": [{"type": "tool_result", "content": "big dump"}]}},
        ])
        self.assertEqual(code, 0)
        self.assertIn("YOU 2026-08-15 10:00", text)
        self.assertIn("salut, une question", text)
        self.assertIn("CLAUDE", text)
        self.assertIn("voici la réponse", text)
        self.assertNotIn("hmm secret", text)
        self.assertNotIn("big dump", text)

    def test_noise_and_meta_lines_dropped(self):
        code, text = render_lines([
            {"type": "user", "message": {"content": "<command-name>/model</command-name>"}},
            {"type": "user", "isMeta": True, "message": {"content": "caché"}},
            {"type": "system", "content": "du système"},
        ], raw_lines=["pas du json"])
        self.assertEqual(code, 0)
        self.assertEqual(text, "")

    def test_missing_file_fails_gracefully(self):
        out = io.StringIO()
        self.assertEqual(rnd.render("/nonexistent/x.jsonl", out), 1)


if __name__ == "__main__":
    unittest.main()
