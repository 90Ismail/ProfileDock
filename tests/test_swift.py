"""Builds and runs the Swift tests (needs Xcode command line tools)."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('xcrun'), 'needs Xcode command line tools')
class SwiftTests(unittest.TestCase):
    def build(self, *sources, flags=()):
        folder = Path(tempfile.mkdtemp())
        binary = folder / 'test'
        result = subprocess.run(['xcrun', 'swiftc', *flags, *map(str, sources), '-o', str(binary)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return binary

    def test_click_choice(self):
        binary = self.build(REPO / 'bridge/WindowChoice.swift', REPO / 'tests/swift/ChoiceTests.swift')
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('all passed', result.stdout)

    def test_launcher_and_agent_build(self):
        self.build(REPO / 'bridge/WindowChoice.swift', REPO / 'bridge/NativeLauncher.swift')
        self.build(REPO / 'bridge/WindowChoice.swift', REPO / 'bridge/Agent.swift')


if __name__ == '__main__':
    unittest.main()
