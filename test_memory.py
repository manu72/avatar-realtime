"""Tests for the persistent memory layer. No live API access required.

Run:  .venv/bin/python -m unittest test_memory -v
"""

import json
import tempfile
import unittest
from pathlib import Path

import memory


def fake_extractor(doc):
    """An extractor that always returns `doc`, counting its calls."""

    async def extract(old, turns):
        extract.calls += 1
        return doc

    extract.calls = 0
    return extract


def failing_extractor():
    async def extract(old, turns):
        extract.calls += 1
        raise RuntimeError("model exploded")

    extract.calls = 0
    return extract


class MemoryTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.db = Path(self._tmp.name) / "test.db"
        memory.init_db(self.db)
        self.addCleanup(self._tmp.cleanup)

    async def seed_turns(self, uid, n=4, session="s1"):
        await memory.start_session(session, uid, db_path=self.db)
        for i in range(n):
            role = "user" if i % 2 == 0 else "sakura"
            await memory.add_turn(session, uid, role, f"turn {i}", db_path=self.db)

    # ---- identity -----------------------------------------------------
    def test_uid_creation_and_validation(self):
        uid = memory.new_uid()
        self.assertTrue(memory.valid_uid(uid))
        self.assertNotEqual(uid, memory.new_uid())  # random per issue
        for bad in (None, "", "short", "Z" * 32, "a" * 31, 12345, "a" * 32 + "b"):
            self.assertFalse(memory.valid_uid(bad), bad)

    async def test_uid_reuse_maps_to_same_user(self):
        uid = memory.new_uid()
        row1 = await memory.touch_user(uid, db_path=self.db)
        row2 = await memory.touch_user(uid, db_path=self.db)
        self.assertEqual(row1["user_id"], row2["user_id"])
        self.assertEqual(row2["interaction_count"], 2)
        self.assertEqual(row1["first_seen_at"], row2["first_seen_at"])

    # ---- empty user ----------------------------------------------------
    async def test_new_user_has_empty_memory(self):
        view = await memory.get_view(memory.new_uid(), db_path=self.db)
        self.assertEqual(view["memory"], memory.EMPTY_MEMORY)
        self.assertEqual(view["interaction_count"], 0)

    # ---- formatting ----------------------------------------------------
    def test_first_meeting_formats_to_nothing(self):
        row = {"memory": json.dumps(memory.EMPTY_MEMORY), "interaction_count": 1,
               "first_seen_at": "2026-07-11", "last_seen_at": "2026-07-11"}
        self.assertEqual(memory.format_memory_section(row), "")

    def test_formatting_includes_content_and_guardrails(self):
        doc = {"profile": {"preferred_name": "Manu", "facts": ["plays guitar"],
                           "preferences": ["likes tea"], "projects": ["avatar app"]},
               "relationship_summary": "We joke about robots."}
        row = {"memory": json.dumps(doc), "interaction_count": 3,
               "first_seen_at": "2026-07-01", "last_seen_at": "2026-07-11"}
        section = memory.format_memory_section(row)
        for needle in ("Manu", "plays guitar", "likes tea", "avatar app",
                       "We joke about robots.", "NEVER invent",
                       "chatted 2 time(s) before"):
            self.assertIn(needle, section)

    def test_memory_section_is_bounded(self):
        doc = {"profile": {"preferred_name": "x" * 999,
                           "facts": ["f" * 999] * 99, "preferences": ["p" * 999] * 99,
                           "projects": ["j" * 999] * 99},
               "relationship_summary": "s" * 99999}
        row = {"memory": json.dumps(doc), "interaction_count": 5,
               "first_seen_at": "2026-07-01", "last_seen_at": "2026-07-11"}
        self.assertLessEqual(len(memory.format_memory_section(row)), memory.MEMORY_SECTION_MAX_CHARS)

    def test_bound_memory_clips_everything(self):
        doc = {"profile": {"preferred_name": 42, "facts": ["a"] * 100,
                           "preferences": ["b"] * 100, "projects": ["c"] * 100,
                           "junk": "x"},
               "relationship_summary": "d" * 10000, "extra": True}
        b = memory.bound_memory(doc)
        self.assertEqual(len(b["profile"]["facts"]), memory.MAX_FACTS)
        self.assertEqual(len(b["profile"]["preferences"]), memory.MAX_PREFERENCES)
        self.assertEqual(len(b["profile"]["projects"]), memory.MAX_PROJECTS)
        self.assertLessEqual(len(b["relationship_summary"]), memory.MAX_SUMMARY_CHARS)
        self.assertEqual(set(b), {"profile", "relationship_summary"})
        self.assertEqual(memory.bound_memory("garbage"), memory.EMPTY_MEMORY)

    # ---- extraction / replacement ---------------------------------------
    async def test_successful_update_replaces_memory(self):
        uid = memory.new_uid()
        await memory.touch_user(uid, db_path=self.db)
        await self.seed_turns(uid)
        new_doc = {"profile": {"preferred_name": "Manu", "facts": ["is testing"],
                               "preferences": [], "projects": []},
                   "relationship_summary": "First proper chat."}
        ok = await memory.update_user_memory(uid, fake_extractor(new_doc), db_path=self.db)
        self.assertTrue(ok)
        view = await memory.get_view(uid, db_path=self.db)
        self.assertEqual(view["memory"]["profile"]["preferred_name"], "Manu")

    async def test_extractor_failure_preserves_memory(self):
        uid = memory.new_uid()
        await memory.touch_user(uid, db_path=self.db)
        old = {"profile": {"preferred_name": "Keep", "facts": [], "preferences": [], "projects": []},
               "relationship_summary": "old"}
        await memory.save_memory(uid, old, db_path=self.db)
        await self.seed_turns(uid)
        ok = await memory.update_user_memory(uid, failing_extractor(), db_path=self.db)
        self.assertFalse(ok)
        view = await memory.get_view(uid, db_path=self.db)
        self.assertEqual(view["memory"]["profile"]["preferred_name"], "Keep")

    async def test_turns_processed_at_most_once(self):
        uid = memory.new_uid()
        await memory.touch_user(uid, db_path=self.db)
        await self.seed_turns(uid)
        extractor = fake_extractor(memory.EMPTY_MEMORY)
        self.assertTrue(await memory.update_user_memory(uid, extractor, db_path=self.db))
        # duplicate disconnect / retry: no unprocessed turns left, extractor not re-run
        self.assertFalse(await memory.update_user_memory(uid, extractor, db_path=self.db))
        self.assertEqual(extractor.calls, 1)

    async def test_too_few_turns_skips_update(self):
        uid = memory.new_uid()
        await memory.touch_user(uid, db_path=self.db)
        await self.seed_turns(uid, n=1)
        extractor = fake_extractor(memory.EMPTY_MEMORY)
        self.assertFalse(await memory.update_user_memory(uid, extractor, db_path=self.db))
        self.assertEqual(extractor.calls, 0)

    async def test_failed_update_leaves_turns_reprocessable(self):
        uid = memory.new_uid()
        await memory.touch_user(uid, db_path=self.db)
        await self.seed_turns(uid)
        await memory.update_user_memory(uid, failing_extractor(), db_path=self.db)
        # a later retry with a working extractor still sees the turns
        ok = await memory.update_user_memory(uid, fake_extractor(memory.EMPTY_MEMORY), db_path=self.db)
        self.assertTrue(ok)

    # ---- clearing --------------------------------------------------------
    async def test_clear_affects_only_one_user(self):
        a, b = memory.new_uid(), memory.new_uid()
        for uid in (a, b):
            await memory.touch_user(uid, db_path=self.db)
            await memory.save_memory(
                uid, {"profile": {"preferred_name": uid[:4], "facts": [], "preferences": [],
                                  "projects": []}, "relationship_summary": ""}, db_path=self.db)
            await self.seed_turns(uid, session="s-" + uid[:4])
        await memory.clear_user(a, db_path=self.db)
        va = await memory.get_view(a, db_path=self.db)
        vb = await memory.get_view(b, db_path=self.db)
        self.assertEqual(va["memory"], memory.EMPTY_MEMORY)
        self.assertEqual(va["interaction_count"], 0)
        self.assertEqual(vb["memory"]["profile"]["preferred_name"], b[:4])
        # b's transcripts survive and are still extractable
        self.assertTrue(await memory.update_user_memory(b, fake_extractor(memory.EMPTY_MEMORY), db_path=self.db))
        # a has no leftover turns
        self.assertFalse(await memory.update_user_memory(a, fake_extractor(memory.EMPTY_MEMORY), db_path=self.db))


if __name__ == "__main__":
    unittest.main()
