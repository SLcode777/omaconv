"""Unit tests for omaconv-render, on fixture transcripts."""

import importlib.machinery
import importlib.util
import io
import json
import os
import sqlite3
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


def preview_json(objs, **kwargs):
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
        for o in objs:
            fh.write(json.dumps(o) + "\n")
        path = fh.name
    out = io.StringIO()
    try:
        code = rnd.preview(path, out, **kwargs)
    finally:
        os.unlink(path)
    return code, json.loads(out.getvalue()) if code == 0 else None


class TestPreview(unittest.TestCase):
    def turns(self, n):
        out = []
        for i in range(n):
            out.append({"type": "user", "timestamp": "2026-08-15T10:%02d:00Z" % i,
                        "message": {"content": "question %d" % i}})
            out.append({"type": "assistant",
                        "message": {"content": [{"type": "text", "text": "answer %d" % i}]}})
        return out

    def test_all_turns_kept_in_order(self):
        code, data = preview_json(self.turns(3))
        self.assertEqual(code, 0)
        texts = [t["text"] for t in data["turns"]]
        self.assertEqual(texts, ["question 0", "answer 0", "question 1",
                                 "answer 1", "question 2", "answer 2"])
        self.assertEqual(data["turns"][0]["who"], "you")
        self.assertEqual(data["turns"][1]["who"], "claude")
        self.assertEqual(data["turns"][0]["time"], "2026-08-15 10:00")

    def test_long_turns_are_clipped(self):
        code, data = preview_json([
            {"type": "user", "message": {"content": "x" * 900}}], clip_chars=100)
        self.assertEqual(code, 0)
        text = data["turns"][0]["text"]
        self.assertEqual(len(text), 100)
        self.assertTrue(text.endswith("…"))

    def test_noise_excluded_and_missing_file_fails(self):
        code, data = preview_json([
            {"type": "user", "message": {"content": "<command-name>/model</command-name>"}}])
        self.assertEqual(code, 0)
        self.assertEqual(data["turns"], [])
        self.assertEqual(rnd.preview("/nonexistent/x.jsonl", io.StringIO()), 1)


class TestCodexTurns(unittest.TestCase):
    def lines(self):
        return [
            {"timestamp": "2026-08-16T09:00:00.000Z", "type": "session_meta",
             "payload": {"session_id": "u1", "cwd": "/tmp"}},
            {"timestamp": "2026-08-16T09:00:01.000Z", "type": "response_item",
             "payload": {"type": "message", "role": "user",
                         "content": [{"type": "input_text", "text": "<environment_context>noise"}]}},
            {"timestamp": "2026-08-16T09:00:02.000Z", "type": "response_item",
             "payload": {"type": "message", "role": "developer",
                         "content": [{"type": "input_text", "text": "dev instructions"}]}},
            {"timestamp": "2026-08-16T09:00:03.000Z", "type": "response_item",
             "payload": {"type": "message", "role": "user",
                         "content": [{"type": "input_text", "text": "real question"}]}},
            {"timestamp": "2026-08-16T09:00:04.000Z", "type": "response_item",
             "payload": {"type": "message", "role": "assistant",
                         "content": [{"type": "output_text", "text": "the answer"}]}},
        ]

    def test_codex_dialogue_and_labels(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
            for o in self.lines():
                fh.write(json.dumps(o) + "\n")
            path = fh.name
        out = io.StringIO()
        try:
            code = rnd.preview(path, out, turns_for=rnd.iter_codex_turns)
            rendered = io.StringIO()
            rnd.render(path, rendered, turns_for=rnd.iter_codex_turns)
        finally:
            os.unlink(path)
        self.assertEqual(code, 0)
        turns = json.loads(out.getvalue())["turns"]
        self.assertEqual([(t["who"], t["text"]) for t in turns],
                         [("you", "real question"), ("codex", "the answer")])
        self.assertEqual(turns[0]["time"], "2026-08-16 09:00")
        self.assertIn("───── CODEX", rendered.getvalue())
        self.assertNotIn("dev instructions", rendered.getvalue())


class TestPiTurns(unittest.TestCase):
    def lines(self):
        return [
            {"type": "session", "version": 3, "id": "uuid-1",
             "timestamp": "2026-08-16T12:03:57.409Z", "cwd": "/home/lucy"},
            {"type": "message", "timestamp": "2026-08-16T12:04:00.000Z",
             "message": {"role": "user",
                         "content": [{"type": "text", "text": "testing pi session"}]}},
            {"type": "message", "timestamp": "2026-08-16T12:04:05.000Z",
             "message": {"role": "assistant",
                         "content": [{"type": "thinking", "thinking": "hmm"},
                                     {"type": "text", "text": "Pi session is active."}]}},
            {"type": "message", "timestamp": "2026-08-16T12:04:10.000Z",
             "message": {"role": "toolResult",
                         "content": [{"type": "text", "text": "PI_MODEL=gpt-5.5"}]}},
            {"type": "message", "timestamp": "2026-08-16T12:04:20.000Z",
             "message": {"role": "user",
                         "content": [{"type": "text", "text": "/exit"}]}},
        ]

    def test_pi_dialogue_and_labels(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
            for o in self.lines():
                fh.write(json.dumps(o) + "\n")
            path = fh.name
        out = io.StringIO()
        rendered = io.StringIO()
        try:
            code = rnd.preview(path, out, turns_for=rnd.iter_pi_turns)
            rnd.render(path, rendered, turns_for=rnd.iter_pi_turns)
        finally:
            os.unlink(path)
        self.assertEqual(code, 0)
        turns = json.loads(out.getvalue())["turns"]
        self.assertEqual([(t["who"], t["text"]) for t in turns],
                         [("you", "testing pi session"),
                          ("pi", "Pi session is active.")])
        self.assertEqual(turns[0]["time"], "2026-08-16 12:04")
        self.assertIn("───── PI", rendered.getvalue())
        self.assertNotIn("hmm", rendered.getvalue())
        self.assertNotIn("PI_MODEL", rendered.getvalue())
        self.assertNotIn("/exit", rendered.getvalue())


class TestAntigravityTurns(unittest.TestCase):
    def lines(self):
        return [
            {"step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT",
             "status": "DONE", "created_at": "2026-08-16T11:45:08Z",
             "content": "<USER_REQUEST>\ngemini testing session\n</USER_REQUEST>\n"
                        "<ADDITIONAL_METADATA>\nlocal time\n</ADDITIONAL_METADATA>"},
            {"step_index": 1, "source": "SYSTEM", "type": "CONVERSATION_HISTORY",
             "status": "DONE", "created_at": "2026-08-16T11:45:08Z"},
            {"step_index": 2, "source": "MODEL", "type": "PLANNER_RESPONSE",
             "status": "DONE", "created_at": "2026-08-16T11:45:09Z",
             "content": "Ready! How can I help?"},
            {"step_index": 3, "source": "SYSTEM", "type": "CHECKPOINT",
             "status": "DONE", "created_at": "2026-08-16T11:45:09Z",
             "content": "{{ CHECKPOINT 0 }} summary of truncated context"},
        ]

    def test_antigravity_dialogue_and_labels(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
            for o in self.lines():
                fh.write(json.dumps(o) + "\n")
            path = fh.name
        out = io.StringIO()
        rendered = io.StringIO()
        try:
            code = rnd.preview(path, out, turns_for=rnd.iter_antigravity_turns)
            rnd.render(path, rendered, turns_for=rnd.iter_antigravity_turns)
        finally:
            os.unlink(path)
        self.assertEqual(code, 0)
        turns = json.loads(out.getvalue())["turns"]
        self.assertEqual([(t["who"], t["text"]) for t in turns],
                         [("you", "gemini testing session"),
                          ("antigravity", "Ready! How can I help?")])
        self.assertEqual(turns[0]["time"], "2026-08-16 11:45")
        self.assertIn("───── ANTIGRAVITY", rendered.getvalue())
        self.assertNotIn("CHECKPOINT", rendered.getvalue())
        self.assertNotIn("ADDITIONAL_METADATA", rendered.getvalue())


class TestOpencodeTurns(unittest.TestCase):
    def make_db(self, path):
        db = sqlite3.connect(path)
        db.executescript(
            "CREATE TABLE message (id TEXT, session_id TEXT,"
            " time_created INTEGER, data TEXT);"
            "CREATE TABLE part (id TEXT, message_id TEXT, session_id TEXT,"
            " time_created INTEGER, data TEXT);")
        rows = [
            ("m1", "ses_1", 1786875810000, {"role": "user"},
             [{"type": "text", "text": "<system-reminder>ctx", "synthetic": True},
              {"type": "text", "text": "real question"}]),
            ("m2", "ses_1", 1786875820000, {"role": "assistant"},
             [{"type": "step-start"}, {"type": "reasoning", "text": "hmm"},
              {"type": "text", "text": "the answer"}]),
            ("m3", "ses_other", 1786875830000, {"role": "user"},
             [{"type": "text", "text": "another session"}]),
        ]
        for mid, sid, ts, meta, parts in rows:
            db.execute("INSERT INTO message VALUES (?,?,?,?)",
                       (mid, sid, ts, json.dumps(meta)))
            for n, part in enumerate(parts):
                db.execute("INSERT INTO part VALUES (?,?,?,?,?)",
                           ("%s-p%d" % (mid, n), mid, sid, ts + n, json.dumps(part)))
        db.commit()
        db.close()

    def test_opencode_dialogue_labels_and_session_filter(self):
        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as fh:
            path = fh.name
        os.unlink(path)
        self.make_db(path)
        out = io.StringIO()
        rendered = io.StringIO()
        reader = lambda p: rnd.iter_opencode_turns(p, "ses_1")
        try:
            code = rnd.preview(path, out, turns_for=reader)
            rnd.render(path, rendered, turns_for=reader)
        finally:
            os.unlink(path)
        self.assertEqual(code, 0)
        turns = json.loads(out.getvalue())["turns"]
        self.assertEqual([(t["who"], t["text"]) for t in turns],
                         [("you", "real question"), ("opencode", "the answer")])
        self.assertEqual(turns[0]["time"], "2026-08-16 10:23")
        self.assertIn("───── OPENCODE", rendered.getvalue())
        self.assertNotIn("another session", rendered.getvalue())
        self.assertNotIn("<system-reminder>", rendered.getvalue())

    def test_missing_db_fails_gracefully(self):
        reader = lambda p: rnd.iter_opencode_turns(p, "ses_1")
        self.assertEqual(
            rnd.preview("/nonexistent/opencode.db", io.StringIO(), turns_for=reader), 1)

    def test_bad_time_created_yields_turn_without_time(self):
        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as fh:
            path = fh.name
        os.unlink(path)
        db = sqlite3.connect(path)
        db.executescript(
            "CREATE TABLE message (id TEXT, session_id TEXT,"
            " time_created INTEGER, data TEXT);"
            "CREATE TABLE part (id TEXT, message_id TEXT, session_id TEXT,"
            " time_created INTEGER, data TEXT);")
        db.execute("INSERT INTO message VALUES ('m1', 's', 'garbage', ?)",
                   (json.dumps({"role": "user"}),))
        db.execute("INSERT INTO part VALUES ('p1', 'm1', 's', 1, ?)",
                   (json.dumps({"type": "text", "text": "hi"}),))
        db.commit()
        db.close()
        out = io.StringIO()
        try:
            code = rnd.preview(path, out,
                               turns_for=lambda p: rnd.iter_opencode_turns(p, "s"))
        finally:
            os.unlink(path)
        self.assertEqual(code, 0)
        turns = json.loads(out.getvalue())["turns"]
        self.assertEqual([(t["who"], t["text"], t["time"]) for t in turns],
                         [("you", "hi", "")])


def skill_json(text):
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
        fh.write(text)
        path = fh.name
    out = io.StringIO()
    try:
        code = rnd.skill_preview(path, out)
    finally:
        os.unlink(path)
    return code, json.loads(out.getvalue()) if code == 0 else None


class TestSkillPreview(unittest.TestCase):
    def test_frontmatter_and_body_split(self):
        code, data = skill_json("---\nname: demo\ndescription: a demo\n---\n\n# Title\n\nBody text.\n")
        self.assertEqual(code, 0)
        self.assertEqual(data["skill"]["frontmatter"], "name: demo\ndescription: a demo")
        self.assertEqual(data["skill"]["body"], "# Title\n\nBody text.")

    def test_no_frontmatter_is_all_body(self):
        code, data = skill_json("# Just a doc\n\nNo frontmatter here.\n")
        self.assertEqual(code, 0)
        self.assertEqual(data["skill"]["frontmatter"], "")
        self.assertEqual(data["skill"]["body"], "# Just a doc\n\nNo frontmatter here.")

    def test_unclosed_frontmatter_is_body(self):
        code, data = skill_json("---\nname: broken\nno closing fence\n")
        self.assertEqual(code, 0)
        self.assertEqual(data["skill"]["frontmatter"], "")
        self.assertIn("name: broken", data["skill"]["body"])

    def test_missing_file_fails_gracefully(self):
        self.assertEqual(rnd.skill_preview("/nonexistent/SKILL.md", io.StringIO()), 1)


if __name__ == "__main__":
    unittest.main()
