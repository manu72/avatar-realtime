"""Tests for Sakura's scene tool validation. No live API access required.

Run:  .venv/bin/python -m unittest test_tools -v
"""

import unittest

import server


class SceneToolTests(unittest.TestCase):
    def test_valid_outfit(self):
        update, result = server.scene_tool_call("set_outfit", {"outfit": "Swimsuit"})
        self.assertEqual(update, {"outfit": "Swimsuit"})
        self.assertEqual(result, {"result": "ok"})

    def test_valid_background(self):
        update, result = server.scene_tool_call("set_background", {"background": "Beach"})
        self.assertEqual(update, {"background": "Beach"})
        self.assertEqual(result, {"result": "ok"})

    def test_unknown_value_refused(self):
        update, result = server.scene_tool_call("set_outfit", {"outfit": "Battle Armor"})
        self.assertIsNone(update)
        self.assertIn("error", result)

    def test_unknown_tool_refused(self):
        update, result = server.scene_tool_call("delete_memory", {"outfit": "Swimsuit"})
        self.assertIsNone(update)
        self.assertIn("error", result)

    def test_missing_args_refused(self):
        for args in (None, {}, {"background": "Beach"}):  # wrong/absent key for set_outfit
            update, result = server.scene_tool_call("set_outfit", args)
            self.assertIsNone(update)
            self.assertIn("error", result)

    def test_every_declared_enum_value_is_accepted(self):
        for outfit in server.OUTFITS:
            self.assertIsNotNone(server.scene_tool_call("set_outfit", {"outfit": outfit})[0])
        for loc in server.LOCATIONS:
            self.assertIsNotNone(server.scene_tool_call("set_background", {"background": loc})[0])


if __name__ == "__main__":
    unittest.main()
