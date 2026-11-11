import importlib.util
import json
import tempfile
import time
import unittest
from pathlib import Path

SETUP = Path(__file__).resolve().parents[1] / 'setup.py'
spec = importlib.util.spec_from_file_location('setup_module', SETUP)
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.original = setup.ROOT
        setup.ROOT = Path(self.folder.name)
        (setup.ROOT / 'state').mkdir()
        (setup.ROOT / 'extensions/pro').mkdir(parents=True)
        (setup.ROOT / 'extensions/pro/manifest.json').write_text(json.dumps({'version': '0.2.0'}))

    def tearDown(self):
        setup.ROOT = self.original
        self.folder.cleanup()

    def state(self, **values):
        (setup.ROOT / 'state/pro.json').write_text(json.dumps(values))

    def line(self, chrome_running=True):
        return setup.describe('pro', {'label': 'Pro'}, chrome_running)

    def test_never_connected_points_to_the_extension_folder(self):
        line, bad = self.line()
        self.assertTrue(bad)
        self.assertIn('extensions/pro', line)

    def test_connected_counts_windows(self):
        self.state(connected=True, updated=time.time(), version='0.2.0', windows=[{}, {}])
        self.assertEqual(self.line(), ('connected, 2 windows', False))

    def test_no_windows_is_not_an_error(self):
        self.state(connected=False, updated=time.time() - 100, version='0.2.0', windows=[])
        self.assertEqual(self.line(), ('no windows open (connects when one opens)', False))
        self.assertEqual(self.line(chrome_running=False), ('Chrome is closed', False))

    def test_stale_connected_state_is_not_connected(self):
        self.state(connected=True, updated=time.time() - 60, version='0.2.0', windows=[{}])
        self.assertFalse(self.line()[0].startswith('connected'))

    def test_outdated_extension_needs_attention(self):
        self.state(connected=True, updated=time.time(), windows=[{}])
        line, bad = self.line()
        self.assertTrue(bad)
        self.assertIn('chrome://extensions', line)


if __name__ == '__main__':
    unittest.main()
