"""Both entry points must reach one profile and one debugging endpoint."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[3] / 'containers' / 'desktop'


class BrowserLauncher(unittest.TestCase):
    def test_dock_and_agent_share_browser_profile_and_cdp_port(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            wrapper = root / 'chrome-wrapper.sh'
            wrapper.write_text((SOURCE / wrapper.name).read_text())
            wrapper.chmod(0o755)
            act = root / 'act'
            act.write_text((SOURCE / 'act').read_text().replace('/usr/local/bin/chrome-wrapper.sh', str(wrapper)))
            act.chmod(0o755)
            chromium = root / 'chromium'
            chromium.write_text('#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ["CALLS"],"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n')
            chromium.chmod(0o755)
            for name, code in [('pgrep', 1), ('socat', 0)]:
                (root / name).write_text(f'#!/bin/sh\nexit {code}\n')
                (root / name).chmod(0o755)
            calls = root / 'calls'
            env = {**os.environ, 'PATH': f'{root}:{os.environ["PATH"]}', 'HOME': tmp,
                   'DISPLAY': ':102', 'CALLS': str(calls)}
            subprocess.run([str(wrapper), 'https://example.test/dock'], env=env, check=True)
            subprocess.run([str(act), 'open', 'https://example.test/agent'], env=env, check=True)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                lines = calls.read_text().splitlines()
                if len(lines) == 2:
                    break
                time.sleep(0.02)
            self.assertEqual(len(lines), 2)
            for args in map(json.loads, lines):
                self.assertIn(f'--user-data-dir={tmp}/.chromium-:102', args)
                self.assertIn('--remote-debugging-port=19225', args)
                self.assertNotIn('--no-sandbox', args)


if __name__ == '__main__':
    unittest.main()
