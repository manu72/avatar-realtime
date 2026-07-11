"""Tests for the avatars' scene tool validation. No live API access required.

Run:  .venv/bin/python -m unittest test_tools -v
"""

import unittest

import server

SAKURA = server.CHARACTERS["sakura"]["outfits"]
NAMU = server.CHARACTERS["namu"]["outfits"]


class SceneToolTests(unittest.TestCase):
    def test_valid_outfit(self):
        update, result = server.scene_tool_call("set_outfit", {"outfit": "Swimsuit"}, SAKURA)
        self.assertEqual(update, {"outfit": "Swimsuit"})
        self.assertEqual(result, {"result": "ok"})

    def test_valid_background(self):
        update, result = server.scene_tool_call("set_background", {"background": "Beach"}, SAKURA)
        self.assertEqual(update, {"background": "Beach"})
        self.assertEqual(result, {"result": "ok"})

    def test_unknown_value_refused(self):
        update, result = server.scene_tool_call("set_outfit", {"outfit": "Battle Armor"}, SAKURA)
        self.assertIsNone(update)
        self.assertIn("error", result)

    def test_unknown_tool_refused(self):
        update, result = server.scene_tool_call("delete_memory", {"outfit": "Swimsuit"}, SAKURA)
        self.assertIsNone(update)
        self.assertIn("error", result)

    def test_missing_args_refused(self):
        for args in (None, {}, {"background": "Beach"}):  # wrong/absent key for set_outfit
            update, result = server.scene_tool_call("set_outfit", args, SAKURA)
            self.assertIsNone(update)
            self.assertIn("error", result)

    def test_other_characters_wardrobe_refused(self):
        # Namu can't wear Sakura's seifuku, and vice versa
        self.assertIsNone(server.scene_tool_call("set_outfit", {"outfit": "Seifuku"}, NAMU)[0])
        self.assertIsNone(server.scene_tool_call("set_outfit", {"outfit": "Pajamas"}, SAKURA)[0])

    def test_every_declared_enum_value_is_accepted(self):
        for char in server.CHARACTERS.values():
            for outfit in char["outfits"]:
                self.assertIsNotNone(server.scene_tool_call("set_outfit", {"outfit": outfit}, char["outfits"])[0])
        for loc in server.LOCATIONS:
            self.assertIsNotNone(server.scene_tool_call("set_background", {"background": loc}, SAKURA)[0])


if __name__ == "__main__":
    unittest.main()
