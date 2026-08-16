"""Unit tests for omaconv-index, on fixture transcripts (PRD M1)."""

import importlib.machinery
import importlib.util
import json
import os
import sqlite3
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
        self.codex = os.path.join(self.tmp.name, "codex")
        self.opencode_db = os.path.join(self.tmp.name, "opencode.db")
        self.agy = os.path.join(self.tmp.name, "antigravity-cli")
        self.pi = os.path.join(self.tmp.name, "pi-sessions")
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

    def write_codex_session(self, name, content):
        day = os.path.join(self.codex, "2026", "08", "16")
        os.makedirs(day, exist_ok=True)
        path = os.path.join(day, "rollout-" + name + ".jsonl")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return path

    def write_antigravity_session(self, conv_id, content, workspace=None):
        logs = os.path.join(self.agy, "brain", conv_id, ".system_generated", "logs")
        os.makedirs(logs, exist_ok=True)
        path = os.path.join(logs, "transcript.jsonl")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        if workspace:
            with open(os.path.join(self.agy, "history.jsonl"), "a",
                      encoding="utf-8") as fh:
                fh.write(json.dumps({"display": "x", "timestamp": 0,
                                     "workspace": workspace,
                                     "conversationId": conv_id}) + "\n")
        return path

    def write_pi_session(self, name, content):
        pdir = os.path.join(self.pi, "--home-lucy--")
        os.makedirs(pdir, exist_ok=True)
        path = os.path.join(pdir, name + ".jsonl")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return path

    def scan(self, previous=None):
        # Hermetic: never read the real ~/.claude/sessions, ~/.codex,
        # opencode db, ~/.gemini/antigravity-cli or ~/.pi.
        return idx.scan(self.projects, previous,
                        os.path.join(self.tmp.name, "no-sessions"), self.codex,
                        self.opencode_db, self.agy, self.pi)


class TestParsing(Base):
    def test_title_priority_custom_over_ai_over_prompt(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "last-prompt", "lastPrompt": "first prompt"},
            {"type": "ai-title", "aiTitle": "AI title"},
            {"type": "custom-title", "customTitle": "Manual title"},
        ))
        s = self.scan()["sessions"][0]
        self.assertEqual(s["title"], "Manual title")
        self.assertEqual(s["agent"], "claude")
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


class TestResumeCwd(Base):
    def test_living_first_cwd_wins_no_fallback(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "user", "cwd": self.tmp.name, "isSidechain": False},
            {"type": "user", "cwd": "/somewhere/else", "isSidechain": False},
        ))
        s = self.scan()["sessions"][0]
        self.assertEqual(s["resumeCwd"], self.tmp.name)
        self.assertFalse(s["cwdFallback"])

    def test_dead_first_cwd_falls_back_to_most_recent_living(self):
        living = os.path.join(self.tmp.name, "alive")
        os.makedirs(living)
        self.write_session("-p", "s1", jsonl(
            {"type": "user", "cwd": "/dead/home", "isSidechain": False},
            {"type": "user", "cwd": living, "isSidechain": False},
            {"type": "user", "cwd": "/dead/detour", "isSidechain": False},
        ))
        s = self.scan()["sessions"][0]
        self.assertEqual(s["resumeCwd"], living)
        self.assertTrue(s["cwdFallback"])
        self.assertFalse(s["cwdExists"])

    def test_all_cwds_dead_yields_none(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "user", "cwd": "/dead/one", "isSidechain": False},
            {"type": "user", "cwd": "/dead/two", "isSidechain": False},
        ))
        s = self.scan()["sessions"][0]
        self.assertIsNone(s["resumeCwd"])
        self.assertFalse(s["cwdFallback"])


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


class TestSkills(Base):
    def write_skill(self, name, frontmatter):
        d = os.path.join(self.tmp.name, "skills", name)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "SKILL.md"), "w", encoding="utf-8") as fh:
            fh.write(frontmatter)
        return os.path.join(self.tmp.name, "skills")

    def test_quoted_and_folded_descriptions(self):
        root = self.write_skill("herdr",
            '---\nname: herdr\ndescription: "Control Herdr, a multiplexer."\n---\nbody\n')
        self.write_skill("omarchy",
            "---\nname: omarchy\ndescription: >\n  REQUIRED for desktop config.\n"
            "  Use when editing hypr.\n---\nbody\n")
        skills = {s["name"]: s for s in idx.scan_skills(root)}
        self.assertEqual(skills["herdr"]["description"], "Control Herdr, a multiplexer.")
        self.assertEqual(skills["omarchy"]["description"],
                         "REQUIRED for desktop config. Use when editing hypr.")

    def test_missing_name_falls_back_to_dirname(self):
        root = self.write_skill("mystery", "---\ndescription: x\n---\n")
        self.assertEqual(idx.scan_skills(root)[0]["name"], "mystery")

    def test_no_frontmatter_and_missing_dir_tolerated(self):
        root = self.write_skill("bare", "# just markdown\n")
        skills = idx.scan_skills(root)
        self.assertEqual(skills[0]["name"], "bare")
        self.assertEqual(skills[0]["description"], "")
        self.assertEqual(idx.scan_skills("/nonexistent"), [])


class TestRunning(Base):
    def write_state(self, name, obj):
        d = os.path.join(self.tmp.name, "sessions")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name), "w", encoding="utf-8") as fh:
            json.dump(obj, fh)
        return d

    def test_alive_pid_marks_running_dead_pid_does_not(self):
        d = self.write_state("1.json", {"sessionId": "alive", "pid": os.getpid(), "kind": "bg"})
        self.write_state("2.json", {"sessionId": "dead", "pid": 2 ** 22 + 999983, "kind": "bg"})
        self.write_state("3.json", {"sessionId": "nokind", "pid": os.getpid()})
        running = idx.scan_running(d)
        self.assertEqual(running, {"alive": "bg", "nokind": "interactive"})

    def test_malformed_state_and_missing_dir_tolerated(self):
        d = self.write_state("bad.json", ["not", "a", "dict"])
        with open(os.path.join(d, "junk.json"), "w") as fh:
            fh.write("{nope")
        self.assertEqual(idx.scan_running(d), {})
        self.assertEqual(idx.scan_running("/nonexistent"), {})

    def test_running_field_lands_on_indexed_sessions(self):
        self.write_session("-p", "s1", jsonl(
            {"type": "user", "cwd": "/a", "isSidechain": False},
        ))
        d = self.write_state("1.json", {"sessionId": "s1", "pid": os.getpid(), "kind": "bg"})
        s = idx.scan(self.projects, sessions_dir=d)["sessions"][0]
        self.assertEqual(s["running"], "bg")
        s2 = idx.scan(self.projects, sessions_dir="/nonexistent")["sessions"][0]
        self.assertIsNone(s2["running"])


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
        result = idx.scan(os.path.join(self.tmp.name, "inexistant"),
                          sessions_dir=os.path.join(self.tmp.name, "no-sessions"),
                          codex_dir=os.path.join(self.tmp.name, "no-codex"),
                          opencode_db=os.path.join(self.tmp.name, "no.db"),
                          antigravity_dir=os.path.join(self.tmp.name, "no-agy"),
                          pi_dir=os.path.join(self.tmp.name, "no-pi"))
        self.assertEqual(result["sessions"], [])


def codex_lines(session_id, cwd, prompts, branch=None, ts="2026-08-16T10:00:00.000Z"):
    git = {"branch": branch} if branch else {}
    lines = [{"timestamp": ts, "type": "session_meta",
              "payload": {"session_id": session_id, "cwd": cwd, "git": git}}]
    for i, prompt in enumerate(prompts):
        lines.append({"timestamp": ts[:15] + str(i) + ts[16:], "type": "response_item",
                      "payload": {"type": "message", "role": "user",
                                  "content": [{"type": "input_text", "text": prompt}]}})
    return jsonl(*lines)


class TestCodex(Base):
    def test_codex_session_indexed_with_agent_field(self):
        self.write_codex_session("a", codex_lines(
            "uuid-1", self.tmp.name, ["fix the login page", "now the tests"], branch="main"))
        sessions = self.scan()["sessions"]
        self.assertEqual(len(sessions), 1)
        s = sessions[0]
        self.assertEqual(s["agent"], "codex")
        self.assertEqual(s["id"], "uuid-1")
        self.assertEqual(s["title"], "fix the login page")
        self.assertEqual(s["prompts"], ["fix the login page", "now the tests"])
        self.assertEqual(s["cwd"], self.tmp.name)
        self.assertEqual(s["gitBranch"], "main")
        self.assertFalse(s["cwdFallback"])

    def test_codex_noise_prompts_excluded(self):
        self.write_codex_session("b", codex_lines("uuid-2", self.tmp.name, [
            "<environment_context>\n  <cwd>/x</cwd>",
            "# Context from my IDE setup",
            "<turn_aborted>\nThe user aborted",
            "a real question"]))
        s = self.scan()["sessions"][0]
        self.assertEqual(s["prompts"], ["a real question"])
        self.assertEqual(s["title"], "a real question")

    def test_codex_without_meta_uses_filename_id(self):
        self.write_codex_session("2026-08-16T10-00-00-uuid-3", jsonl(
            {"timestamp": "2026-08-16T10:00:00.000Z", "type": "response_item",
             "payload": {"type": "message", "role": "user",
                         "content": [{"type": "input_text", "text": "hello"}]}}))
        s = self.scan()["sessions"][0]
        self.assertEqual(s["id"], "rollout-2026-08-16T10-00-00-uuid-3")
        self.assertIsNone(s["cwd"])
        self.assertIsNone(s["resumeCwd"])

    def test_claude_and_codex_merged_by_recency(self):
        self.write_session("proj", "claude-1", jsonl(
            {"type": "last-prompt", "lastPrompt": "old claude", "timestamp": "2026-08-14T09:00:00Z"}))
        self.write_codex_session("c", codex_lines(
            "uuid-4", self.tmp.name, ["newer codex"], ts="2026-08-16T09:00:00.000Z"))
        sessions = self.scan()["sessions"]
        self.assertEqual([s["agent"] for s in sessions], ["codex", "claude"])

    def test_codex_incremental_reuses_cache(self):
        self.write_codex_session("d", codex_lines("uuid-5", self.tmp.name, ["stable"]))
        first = self.scan()
        marker = dict(first["sessions"][0], title="CACHED")
        again = self.scan(previous={"sessions": [marker]})
        self.assertEqual(again["sessions"][0]["title"], "CACHED")


# Minimal mirror of the real opencode.db (only the columns the indexer reads).
OPENCODE_SCHEMA = """
CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, title TEXT,
  directory TEXT, time_created INTEGER, time_updated INTEGER);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT,
  time_created INTEGER, data TEXT);
CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT,
  time_created INTEGER, data TEXT);
"""


def write_opencode_db(path, sessions):
    """sessions: [{id, title, directory, updated, parent_id,
    turns: [(role, text) or (role, text, synthetic)]}]"""
    db = sqlite3.connect(path)
    db.executescript(OPENCODE_SCHEMA)
    tick = 0
    for s in sessions:
        db.execute("INSERT INTO session VALUES (?,?,?,?,?,?)",
                   (s["id"], s.get("parent_id"),
                    s.get("title", "New session - 2026-08-16T10:00:00.000Z"),
                    s.get("directory", "/tmp"),
                    s.get("updated", 1786875817000), s.get("updated", 1786875817000)))
        for n, turn in enumerate(s.get("turns", [])):
            tick += 1
            mid = "%s-m%d" % (s["id"], n)
            db.execute("INSERT INTO message VALUES (?,?,?,?)",
                       (mid, s["id"], tick, json.dumps({"role": turn[0]})))
            part = {"type": "text", "text": turn[1]}
            if len(turn) > 2 and turn[2]:
                part["synthetic"] = True
            db.execute("INSERT INTO part VALUES (?,?,?,?,?)",
                       (mid + "-p0", mid, s["id"], tick, json.dumps(part)))
    db.commit()
    db.close()


class TestOpencode(Base):
    def test_opencode_session_indexed_with_agent_field(self):
        write_opencode_db(self.opencode_db, [{
            "id": "ses_1", "directory": self.tmp.name,
            "updated": 1786875817749,
            "turns": [("user", "test session minimax"), ("assistant", "ok")]}])
        sessions = self.scan()["sessions"]
        self.assertEqual(len(sessions), 1)
        s = sessions[0]
        self.assertEqual(s["agent"], "opencode")
        self.assertEqual(s["id"], "ses_1")
        self.assertEqual(s["title"], "test session minimax")
        self.assertEqual(s["titleSource"], "prompt")
        self.assertEqual(s["prompts"], ["test session minimax"])
        self.assertEqual(s["cwd"], self.tmp.name)
        self.assertEqual(s["transcriptPath"], self.opencode_db)
        self.assertTrue(s["lastActivity"].startswith("2026-08-16T"))

    def test_opencode_real_title_wins_over_prompt(self):
        write_opencode_db(self.opencode_db, [{
            "id": "ses_2", "title": "Fixing the login flow",
            "turns": [("user", "please fix login")]}])
        s = self.scan()["sessions"][0]
        self.assertEqual(s["title"], "Fixing the login flow")
        self.assertEqual(s["titleSource"], "ai")

    def test_opencode_synthetic_and_noise_parts_excluded(self):
        write_opencode_db(self.opencode_db, [{
            "id": "ses_3",
            "turns": [("user", "<system-reminder>opened file</system-reminder>", True),
                      ("user", "<system-reminder>plain noise too"),
                      ("user", "the real prompt")]}])
        s = self.scan()["sessions"][0]
        self.assertEqual(s["prompts"], ["the real prompt"])

    def test_opencode_child_sessions_excluded(self):
        write_opencode_db(self.opencode_db, [
            {"id": "ses_top", "turns": [("user", "parent work")]},
            {"id": "ses_sub", "parent_id": "ses_top",
             "turns": [("user", "subagent work")]}])
        sessions = self.scan()["sessions"]
        self.assertEqual([s["id"] for s in sessions], ["ses_top"])

    def test_opencode_placeholder_title_without_prompts_uses_id(self):
        write_opencode_db(self.opencode_db, [{"id": "ses_4"}])
        s = self.scan()["sessions"][0]
        self.assertEqual(s["title"], "ses_4")
        self.assertEqual(s["titleSource"], "id")

    def test_opencode_sessions_never_cached_by_db_path(self):
        write_opencode_db(self.opencode_db, [{
            "id": "ses_5", "turns": [("user", "fresh every scan")]}])
        first = self.scan()
        marker = dict(first["sessions"][0], title="STALE")
        again = self.scan(previous={"sessions": [marker]})
        self.assertEqual(again["sessions"][0]["title"], "fresh every scan")

    def test_corrupt_db_yields_no_opencode_sessions(self):
        with open(self.opencode_db, "w", encoding="utf-8") as fh:
            fh.write("not a sqlite file")
        self.assertEqual(self.scan()["sessions"], [])


def agy_lines(prompts, ts="2026-08-16T11:45:08Z", extra=()):
    lines = []
    for i, prompt in enumerate(prompts):
        lines.append({
            "step_index": i, "source": "USER_EXPLICIT", "type": "USER_INPUT",
            "status": "DONE", "created_at": ts,
            "content": "<USER_REQUEST>\n%s\n</USER_REQUEST>\n"
                       "<ADDITIONAL_METADATA>\nlocal time\n</ADDITIONAL_METADATA>" % prompt})
    lines.extend(extra)
    return jsonl(*lines)


class TestAntigravity(Base):
    def test_antigravity_session_indexed_with_agent_field(self):
        self.write_antigravity_session("conv-1", agy_lines(
            ["gemini testing session", "do you believe in agi ?"]),
            workspace=self.tmp.name)
        sessions = self.scan()["sessions"]
        self.assertEqual(len(sessions), 1)
        s = sessions[0]
        self.assertEqual(s["agent"], "antigravity")
        self.assertEqual(s["id"], "conv-1")
        self.assertEqual(s["title"], "gemini testing session")
        self.assertEqual(s["prompts"],
                         ["gemini testing session", "do you believe in agi ?"])
        self.assertEqual(s["cwd"], self.tmp.name)
        self.assertEqual(s["lastActivity"], "2026-08-16T11:45:08Z")
        self.assertFalse(s["cwdFallback"])

    def test_antigravity_without_history_entry_has_no_cwd(self):
        self.write_antigravity_session("conv-2", agy_lines(["orphan prompt"]))
        s = self.scan()["sessions"][0]
        self.assertIsNone(s["cwd"])
        self.assertIsNone(s["resumeCwd"])

    def test_antigravity_machinery_steps_are_not_prompts(self):
        self.write_antigravity_session("conv-3", agy_lines(["only real one"], extra=[
            {"source": "SYSTEM", "type": "CHECKPOINT", "status": "DONE",
             "created_at": "2026-08-16T11:46:00Z", "content": "{{ CHECKPOINT 0 }}"},
            {"source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
             "created_at": "2026-08-16T11:46:01Z", "content": "an answer"},
        ]), workspace="/tmp")
        s = self.scan()["sessions"][0]
        self.assertEqual(s["prompts"], ["only real one"])
        # lastActivity still tracks every step's timestamp.
        self.assertEqual(s["lastActivity"], "2026-08-16T11:46:01Z")


def pi_lines(session_id, cwd, prompts, ts="2026-08-16T12:04:00.000Z"):
    lines = [{"type": "session", "version": 3, "id": session_id,
              "timestamp": ts, "cwd": cwd}]
    for prompt in prompts:
        lines.append({"type": "message", "id": "m", "timestamp": ts,
                      "message": {"role": "user",
                                  "content": [{"type": "text", "text": prompt}]}})
    return jsonl(*lines)


class TestPi(Base):
    def test_pi_session_indexed_with_agent_field(self):
        self.write_pi_session("2026-08-16T12-03-57-409Z_uuid-1", pi_lines(
            "uuid-1", self.tmp.name, ["testing pi session", "what model are you?"]))
        sessions = self.scan()["sessions"]
        self.assertEqual(len(sessions), 1)
        s = sessions[0]
        self.assertEqual(s["agent"], "pi")
        self.assertEqual(s["id"], "uuid-1")
        self.assertEqual(s["title"], "testing pi session")
        self.assertEqual(s["prompts"], ["testing pi session", "what model are you?"])
        self.assertEqual(s["cwd"], self.tmp.name)
        self.assertFalse(s["cwdFallback"])

    def test_pi_slash_commands_are_not_prompts(self):
        self.write_pi_session("s", pi_lines(
            "uuid-2", "/tmp", ["/model", "a real question", "/exit"]))
        s = self.scan()["sessions"][0]
        self.assertEqual(s["prompts"], ["a real question"])
        self.assertEqual(s["title"], "a real question")

    def test_pi_without_header_uses_filename_id(self):
        self.write_pi_session("2026-08-16T12-00-00-000Z_uuid-3", jsonl(
            {"type": "message", "timestamp": "2026-08-16T12:00:00.000Z",
             "message": {"role": "user",
                         "content": [{"type": "text", "text": "hello"}]}}))
        s = self.scan()["sessions"][0]
        self.assertEqual(s["id"], "2026-08-16T12-00-00-000Z_uuid-3")
        self.assertIsNone(s["cwd"])


if __name__ == "__main__":
    unittest.main()
