import unittest

from build import validate


class ConfigTests(unittest.TestCase):
    def test_rejects_path_traversal(self):
        with self.assertRaises(ValueError):
            validate([{"label": "../Other", "chrome_name": "Work"}])

    def test_rejects_case_insensitive_filename_collision(self):
        with self.assertRaises(ValueError):
            validate(
                [{"label": "Work", "chrome_name": "One"}, {"label": "work", "chrome_name": "Two"}]
            )

    def test_rejects_ambiguous_profile(self):
        with self.assertRaises(ValueError):
            validate(
                [{"label": "One", "chrome_name": "Same"}, {"label": "Two", "chrome_name": "Same"}]
            )

    def test_accepts_unicode_chrome_name(self):
        self.assertEqual(
            validate([{"label": "Work", "chrome_name": "Büro"}])[0]["chrome_name"], "Büro"
        )

    def test_rejects_multiline_name(self):
        with self.assertRaises(ValueError):
            validate([{"label": "Work", "chrome_name": "Work\nOther"}])


if __name__ == "__main__":
    unittest.main()
