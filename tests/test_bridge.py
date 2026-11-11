import importlib.util
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HOST = Path(__file__).resolve().parents[1] / 'bridge/native_host.py'
spec = importlib.util.spec_from_file_location('host', HOST)
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class BridgeTests(unittest.TestCase):
    def test_rejects_invalid_windows(self):
        for value in ({}, [{'id': '1'}], [{'id': True}]):
            with self.assertRaises(ValueError):
                host.clean_windows(value, {})

    def test_only_window_metadata_leaves_browser(self):
        result = host.clean_windows([{'id': 3, 'title': 'Example', 'tabCount': 2, 'url': 'private', 'tabs': ['private']}], {})
        self.assertEqual(result, [{'id': 3, 'title': 'Example', 'tabCount': 2, 'focused': False, 'lastFocused': 0}])

    def test_remembers_last_focused_window(self):
        seen = {}
        host.clean_windows([{'id': 1, 'focused': True}, {'id': 2}], seen)
        result = host.clean_windows([{'id': 1}, {'id': 2}], seen)
        self.assertGreater(result[0]['lastFocused'], result[1]['lastFocused'])

    def test_losing_focus_refreshes_last_focused(self):
        # A Dock click blurs Chrome before the launcher reads state; the blur
        # moment must count as "just focused" so the picker still opens.
        seen = {}
        host.clean_windows([{'id': 1, 'focused': True}], seen)
        seen['times'][1] = 5
        result = host.clean_windows([{'id': 1}], seen)
        self.assertGreater(result[0]['lastFocused'], time.time() - 2)
        seen['times'][1] = 5
        result = host.clean_windows([{'id': 1}], seen)
        self.assertEqual(result[0]['lastFocused'], 5)

    def test_keeps_safe_extras_for_dock_list(self):
        icon = 'data:image/png;base64,iVBORw0KGgo='
        result = host.clean_windows([{'id': 1, 'state': 'minimized', 'host': 'github.com', 'icon': icon}], {})
        self.assertEqual((result[0]['state'], result[0]['host'], result[0]['icon']), ('minimized', 'github.com', icon))

    def test_drops_unsafe_extras(self):
        result = host.clean_windows([{'id': 1, 'state': 'weird', 'host': 'https://x.com/private?q=1',
                                      'icon': 'https://tracker.example/icon.png'}], {})
        self.assertEqual(set(result[0]), {'id', 'title', 'tabCount', 'focused', 'lastFocused'})
        big = 'data:image/png;base64,' + 'A' * (host.MAX_ICON + 1)
        self.assertNotIn('icon', host.clean_windows([{'id': 1, 'icon': big}], {})[0])

    def test_reload_only_when_installed_version_differs_and_not_twice(self):
        with tempfile.TemporaryDirectory() as folder:
            original = host.ROOT
            host.ROOT = Path(folder)
            try:
                manifest = host.ROOT / 'extensions/work/manifest.json'
                manifest.parent.mkdir(parents=True)
                manifest.write_text(json.dumps({'version': '0.2.0'}))
                self.assertFalse(host.should_reload('work', '0.2.0'))
                self.assertTrue(host.should_reload('work', '0.1.0'))
                self.assertFalse(host.should_reload('work', '0.1.0'))  # cooldown: no reload loop
                self.assertFalse(host.should_reload('other', '0.1.0'))  # nothing installed
            finally:
                host.ROOT = original

    def test_connection_commands_and_disconnect(self):
        import struct
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'profiles.json').write_text(json.dumps({'work': {'app': '/nonexistent/ProfileDock.app'}}))
            code = 'import runpy; m=runpy.run_path(sys.argv[1]); m["main"].__globals__["ROOT"]=Path(sys.argv[2]); m["main"]()'
            proc = subprocess.Popen([sys.executable, '-c', 'import sys; from pathlib import Path; ' + code, str(HOST), folder], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            def send(value):
                data = json.dumps(value).encode()
                proc.stdin.write(struct.pack('=I', len(data)) + data); proc.stdin.flush()
            try:
                send({'type': 'hello', 'profile': 'work'})
                size = struct.unpack('=I', proc.stdout.read(4))[0]
                self.assertEqual(json.loads(proc.stdout.read(size)), {'type': 'ready'})
                send({'type': 'snapshot', 'profile': 'work', 'windows': [{'id': 123, 'title': 'Test', 'tabCount': 2}]})
                for _ in range(50):
                    p = root / 'state/work.json'
                    if p.exists() and json.loads(p.read_text())['windows']: break
                    time.sleep(.05)
                state = json.loads(p.read_text())
                self.assertEqual(state['windows'][0]['id'], 123)
                command = root / 'commands/work/request.json'
                command.write_text(json.dumps({'session':state['session'],'type':'focus','windowId':123}))
                size = struct.unpack('=I', proc.stdout.read(4))[0]
                focus = json.loads(proc.stdout.read(size))
                self.assertEqual(focus['windowId'], 123)
                send({'type': 'result', 'requestId': focus['requestId'], 'ok': True})
                result = root / 'results' / (focus['requestId'] + '.json')
                for _ in range(50):
                    if result.exists(): break
                    time.sleep(.05)
                self.assertTrue(json.loads(result.read_text())['ok'])
                # Close commands are forwarded like focus ones.
                (root / 'commands/work/closing.json').write_text(json.dumps({'session': state['session'], 'type': 'close', 'windowId': 123}))
                size = struct.unpack('=I', proc.stdout.read(4))[0]
                self.assertEqual(json.loads(proc.stdout.read(size)), {'type': 'close', 'windowId': 123, 'requestId': 'closing'})
                # A command for an old connection is answered at once, so the
                # sender falls back instead of waiting.
                (root / 'commands/work/stale.json').write_text(json.dumps({'session': 'old', 'type': 'focus', 'windowId': 123}))
                stale = root / 'results/stale.json'
                for _ in range(50):
                    if stale.exists(): break
                    time.sleep(.05)
                self.assertFalse(json.loads(stale.read_text())['ok'])
                proc.stdin.close(); proc.wait(timeout=5)
                self.assertFalse(json.loads(p.read_text())['connected'])
                self.assertEqual(json.loads(p.read_text())['windows'], [])
            finally:
                if proc.poll() is None: proc.kill(); proc.wait()
                proc.stdout.close()


    def test_chrome_hanging_up_is_not_a_crash(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'profiles.json').write_text(json.dumps({'work': {'app': '/nonexistent/ProfileDock.app'}}))
            code = ('import sys; from pathlib import Path; import runpy; m=runpy.run_path(sys.argv[1]); '
                    'm["run"].__globals__["ROOT"]=Path(sys.argv[2]); m["run"]()')
            proc = subprocess.Popen([sys.executable, '-c', code, str(HOST), folder],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            proc.stdout.close()  # Chrome is gone before the host's first reply
            import struct
            data = json.dumps({'type': 'hello', 'profile': 'work'}).encode()
            proc.stdin.write(struct.pack('=I', len(data)) + data)
            proc.stdin.flush()
            _, errors = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 0, errors)
            self.assertFalse((root / 'host.log').exists())
            state = root / 'state/work.json'  # never written, or written as disconnected
            self.assertFalse(state.exists() and json.loads(state.read_text())['connected'])


if __name__ == '__main__':
    unittest.main()
