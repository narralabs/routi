"""Offline Linux tests for the production shell script; no Docker or model calls."""
import concurrent.futures
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[3] / 'containers' / 'desktop' / 'screenctl'


class ScreenAllocation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = {**os.environ, 'PATH': f'{self.bin}:{os.environ["PATH"]}',
                    'TEST_ROOT': str(self.root), 'HOME': str(self.root), 'SCREEN_WIDTH': '1280',
                    'SCREEN_HEIGHT': '800', 'SCREEN_DEPTH': '24'}
        self.script = self.bin / 'screenctl'
        self.script.write_text(SOURCE.read_text().replace('STATE=/tmp/routi-screens', f'STATE={self.state}')
                               .replace('/usr/local/bin/start-screen.sh', '/bin/true')
                               .replace('/tmp/.X', f'{self.root}/.X'))
        self.script.chmod(0o755)
        self.stub('xdpyinfo', 'test -f "$TEST_ROOT/live-${2#:}"')
        self.stub('Xvfb', '''echo $$ > "$TEST_ROOT/pid-${1#:}"
sleep 0.15
touch "$TEST_ROOT/live-${1#:}"
exec sleep 60''')
        self.stub('dbus-launch', 'echo "DBUS_SESSION_BUS_PID=999999;"')
        self.stub('pgrep', 'exit 1')
        self.stub('pkill', 'echo called >> "$TEST_ROOT/kills"')

    def stub(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/bash\n' + body + '\n')
        p.chmod(0o755)

    def call(self, verb, bot, check=True):
        return subprocess.run([str(self.script), verb, bot], env=self.env,
                              capture_output=True, text=True, timeout=5, check=check)

    def tearDown(self):
        for p in self.root.glob('pid-*'):
            try:
                os.kill(int(p.read_text()), signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.temp.cleanup()

    def test_concurrent_bots_get_distinct_displays(self):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            displays = list(pool.map(lambda b: self.call('start', b).stdout.strip(), ['a', 'b', 'c']))
        self.assertEqual(len(set(displays)), 3)

    def test_same_bot_concurrent_start_is_idempotent(self):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            displays = list(pool.map(lambda _: self.call('start', 'a').stdout.strip(), range(3)))
        self.assertEqual(displays, ['99'] * 3)
        self.assertEqual(len(list(self.root.glob('pid-*'))), 1)

    def test_dead_display_stays_reserved_for_its_bot(self):
        (self.state / 'old').write_text('99\n')
        self.assertEqual(self.call('start', 'new').stdout.strip(), '100')
        self.assertEqual(self.call('start', 'old').stdout.strip(), '99')

    def test_unassigned_browser_profiles_are_not_inherited(self):
        (self.root / '.chromium-:99').mkdir()
        (self.root / 'chrome-profile-100').mkdir()
        self.assertEqual(self.call('start', 'new').stdout.strip(), '101')

    def test_stop_preserves_the_browser_profile_reservation(self):
        self.call('start', 'a')
        self.call('stop', 'a')
        self.assertEqual((self.state / 'a').read_text().strip(), '99')
        (self.root / 'live-99').unlink()
        self.assertEqual(self.call('start', 'b').stdout.strip(), '100')

    def test_conflicting_mapping_cannot_attach_or_kill_another_bot(self):
        for bot in ['a', 'b']:
            (self.state / bot).write_text('99\n')
        (self.root / 'live-99').touch()
        for verb in ['start', 'live', 'display', 'stop']:
            result = self.call(verb, 'a', check=False)
            self.assertNotEqual(result.returncode, 0, verb)
            self.assertIn('conflicting bot assignments', result.stderr)
        self.assertFalse((self.root / 'kills').exists())


if __name__ == '__main__':
    unittest.main()
