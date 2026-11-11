"""Runs the Chrome extension tests (tests/extension.test.mjs) when Node is installed."""
import shutil
import subprocess
import unittest
from pathlib import Path

TEST = Path(__file__).resolve().parent / 'extension.test.mjs'


@unittest.skipUnless(shutil.which('node'), 'needs Node.js')
class ExtensionTests(unittest.TestCase):
    def test_background_script(self):
        result = subprocess.run(['node', '--test', str(TEST)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
