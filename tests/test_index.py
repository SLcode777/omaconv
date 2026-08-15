"""Unit tests for omaconv-index, on fixture transcripts (PRD M1)."""

import importlib.machinery
import importlib.util
import json
import os
import stat as stat_mod
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "omaconv-index")

loader = importlib.machinery.SourceFileLoader("omaconv_index", SCRIPT)
spec = importlib.util.spec_from_loader("omaconv_index", loader)
idx = importlib.util.module_from_spec(spec)
loader.exec_module(idx)


def jsonl(*objs):
    return "".join(json.dumps(o) + "\n" for o in objs)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.projects = os.path.join(self.tmp.name, "projects")
        self.state = os.path.join(self.tmp.name, "state")
        os.makedirs(self.projects)

    def tearDown(self):
        self.tmp.cleanup()

    def write_session(self, project, session_id, content):
        pdir = os.path.join(self.projects, project)
        os.makedirs(pdir, exist_ok=True)
        path = os.path.join(pdir, session_id + ".jsonl")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return path

    def scan(self, previous=None):
        return idx.scan(self.projects, previous)


class TestParsing(Base):
    def test_title_priority_custom_over_ai_over_prompt(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "last-prompt", "lastPrompt": "first prompt"},
            {"type": "ai-title", "aiTitle": "AI title"},
            {"type": "custom-title", "customTitle": "Manual title"},
        ))
        s = self.scan()["sessions"][0]
        self.assertEqual(s["title"], "Manual title")
        self.assertEqual(s["titleSource"], "custom")

    def test_title_falls_back_to_ai_then_prompt(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "last-prompt", "lastPrompt": "first prompt"},
            {"type": "ai-title", "aiTitle": "AI title"},
        ))
        self.write_session("-q", "s2", jsonl(
            {"type": "last-prompt", "lastPrompt": "a prompt serving as a title"},
        ))
        by_id = {s["id"]: s for s in self.scan()["sessions"]}
        self.assertEqual(by_id["s1"]["titleSource"], "ai")
        self.assertEqual(by_id["s2"]["title"], "a prompt serving as a title")
        self.assertEqual(by_id["s2"]["titleSource"], "prompt")

    def test_untitled_promptless_session_uses_id(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "user", "cwd": "/tmp", "isSidechain": False},
        ))
        s = self.scan()["sessions"][0]
        self.assertEqual(s["titleSource"], "id")
        self.assertEqual(s["title"], "s1")

    def test_long_prompt_title_truncated_on_word_boundary(self):
        prompt = "word " * 40
        self.write_session("-p", "s1", jsonl(
            {"type": "last-prompt", "lastPrompt": prompt},
        ))
        title = self.scan()["sessions"][0]["title"]
        self.assertLessEqual(len(title), idx.TITLE_MAX + 1)
        self.assertTrue(title.endswith("…"))

    def test_first_cwd_wins_full_list_kept(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "user", "cwd": "/origin", "isSidechain": False},
            {"type": "user", "cwd": "/detour", "isSidechain": False},
            {"type": "user", "cwd": "/origin", "isSidechain": False},
            {"type": "user", "cwd": "/borrowed", "isSidechain": False},
        ))
        s = self.scan()["sessions"][0]
        self.assertEqual(s["cwd"], "/origin")
        self.assertEqual(s["cwds"], ["/origin", "/detour", "/borrowed"])

    def test_session_without_cwd_kept_greyed(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "last-prompt", "lastPrompt": "hello"},
        ))
        s = self.scan()["sessions"][0]
        self.assertIsNone(s["cwd"])
        self.assertFalse(s["cwdExists"])

    def test_cwd_exists_flag(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "user", "cwd": self.tmp.name, "isSidechain": False},
        ))
        self.write_session("-q", "s2", jsonl(
            {"type": "user", "cwd": "/vanished/folder", "isSidechain": False},
        ))
        by_id = {s["id"]: s for s in self.scan()["sessions"]}
        self.assertTrue(by_id["s1"]["cwdExists"])
        self.assertFalse(by_id["s2"]["cwdExists"])

    def test_prompts_collected_in_order(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "last-prompt", "lastPrompt": "one"},
            {"type": "last-prompt", "lastPrompt": "two"},
            {"type": "last-prompt", "lastPrompt": "three"},
        ))
        self.assertEqual(self.scan()["sessions"][0]["prompts"], ["one", "two", "three"])

    def test_corrupt_line_ignored_session_kept(self):
        self.write_session("-p", "s1",
            '{"type":"last-prompt","lastPrompt":"before"}\n'
            "not json at all\n"
            '{"type":"last-prompt","lastPrompt":42}\n'
            '["a list"]\n'
            '{"type":"last-prompt","lastPrompt":"caf\\u00e9 après"}\n'
        )
        s = self.scan()["sessions"][0]
        # The accented prompt is deliberate: real transcripts are full of French.
        self.assertEqual(s["prompts"], ["before", "café après"])

    def test_git_branch_and_timestamp(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "user", "cwd": "/a", "gitBranch": "main",
             "timestamp": "2026-08-01T10:00:00Z", "isSidechain": False},
            {"type": "user", "cwd": "/a", "gitBranch": "feature",
             "timestamp": "2026-08-02T10:00:00Z", "isSidechain": False},
        ))
        s = self.scan()["sessions"][0]
        self.assertEqual(s["gitBranch"], "feature")
        self.assertEqual(s["lastActivity"], "2026-08-02T10:00:00Z")


class TestExclusions(Base):
    def test_sidechain_only_session_excluded(self):
        self.write_session("-p", "side", jsonl(
            {"type": "user", "cwd": "/a", "isSidechain": True},
        ))
        self.write_session("-p", "main", jsonl(
            {"type": "user", "cwd": "/a", "isSidechain": False},
            {"type": "user", "cwd": "/a", "isSidechain": True},
        ))
        ids = [s["id"] for s in self.scan()["sessions"]]
        self.assertEqual(ids, ["main"])

    def test_subagents_subdir_ignored(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "last-prompt", "lastPrompt": "main session"},
        ))
        sub = os.path.join(self.projects, "-p", "s1", "subagents")
        os.makedirs(sub)
        with open(os.path.join(sub, "agent-abc.jsonl"), "w") as fh:
            fh.write(jsonl({"type": "last-prompt", "lastPrompt": "subagent"}))
        ids = [s["id"] for s in self.scan()["sessions"]]
        self.assertEqual(ids, ["s1"])

    def test_project_dir_without_jsonl_ignored(self):
        os.makedirs(os.path.join(self.projects, "-stray", "memory"))
        self.assertEqual(self.scan()["sessions"], [])

    def test_empty_jsonl_kept_with_id_title(self):
        self.write_session("-p", "empty", "")
        s = self.scan()["sessions"][0]
        self.assertEqual(s["titleSource"], "id")


class TestOrdering(Base):
    def test_sessions_sorted_anti_chronological(self):
        self.write_session("-p", "old", jsonl(
            {"type": "user", "cwd": "/a", "timestamp": "2026-01-01T00:00:00Z",
             "isSidechain": False},
        ))
        self.write_session("-p", "recent", jsonl(
            {"type": "user", "cwd": "/a", "timestamp": "2026-08-01T00:00:00Z",
             "isSidechain": False},
        ))
        ids = [s["id"] for s in self.scan()["sessions"]]
        self.assertEqual(ids, ["recent", "old"])


class TestIncremental(Base):
    def test_unchanged_file_not_reparsed(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "last-prompt", "lastPrompt": "hello"},
        ))
        first = self.scan()
        with mock.patch.object(idx, "parse_transcript", wraps=idx.parse_transcript) as spy:
            second = self.scan(previous=first)
        spy.assert_not_called()
        self.assertEqual(second["sessions"][0]["prompts"], ["hello"])

    def test_changed_file_reparsed(self):
        path = self.write_session("-p", "s1", jsonl(
            {"type": "last-prompt", "lastPrompt": "v1"},
        ))
        first = self.scan()
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(jsonl({"type": "last-prompt", "lastPrompt": "v2"}))
        second = self.scan(previous=first)
        self.assertEqual(second["sessions"][0]["prompts"], ["v1", "v2"])

    def test_deleted_file_dropped(self):
        path = self.write_session("-p", "s1", jsonl(
            {"type": "last-prompt", "lastPrompt": "hello"},
        ))
        first = self.scan()
        os.unlink(path)
        self.assertEqual(self.scan(previous=first)["sessions"], [])

    def test_corrupt_cache_triggers_full_scan(self):
        os.makedirs(self.state)
        with open(os.path.join(self.state, "index.json"), "w") as fh:
            fh.write("{not json")
        self.assertIsNone(idx.load_cache(self.state))


class TestCacheFile(Base):
    def test_cache_written_0600_and_roundtrips(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "last-prompt", "lastPrompt": "hello"},
        ))
        index = self.scan()
        idx.write_cache(self.state, index)
        target = os.path.join(self.state, "index.json")
        mode = stat_mod.S_IMODE(os.stat(target).st_mode)
        self.assertEqual(mode, 0o600)
        self.assertEqual(idx.load_cache(self.state), index)

    def test_missing_projects_dir_yields_empty_index(self):
        result = idx.scan(os.path.join(self.tmp.name, "inexistant"))
        self.assertEqual(result["sessions"], [])


if __name__ == "__main__":
    unittest.main()
