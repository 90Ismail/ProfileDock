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
                host.clean_windows(value)

    def test_only_window_metadata_leaves_browser(self):
        result = host.clean_windows([{'id': 3, 'title': 'Example', 'tabCount': 2, 'url': 'private', 'tabs': ['private']}])
        self.assertEqual(result, [{'id': 3, 'title': 'Example', 'tabCount': 2, 'focused': False}])

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
                self.assertEqual(json.loads(proc.stdout.read(size))['windowId'], 123)
                proc.stdin.close(); proc.wait(timeout=5)
                self.assertFalse(json.loads(p.read_text())['connected'])
                self.assertEqual(json.loads(p.read_text())['windows'], [])
            finally:
                if proc.poll() is None: proc.kill(); proc.wait()
                proc.stdout.close()


if __name__ == '__main__':
    unittest.main()
