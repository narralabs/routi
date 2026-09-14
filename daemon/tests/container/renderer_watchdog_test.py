import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

# The desktop source directory is hashed by the core; keep imports from adding files.
sys.dont_write_bytecode = True

SOURCE = Path(__file__).resolve().parents[3] / 'containers/desktop/renderer-watchdog.py'
spec = importlib.util.spec_from_file_location('watchdog', SOURCE)
w = importlib.util.module_from_spec(spec)
sys.modules['watchdog'] = w
spec.loader.exec_module(w)


class WatchdogTests(unittest.TestCase):
    def test_only_sustained_oversized_renderer_is_stopped(self):
        watcher = w.Watchdog()
        large = w.Renderer(12, 100, w.LIMIT_BYTES + 1)
        small = w.Renderer(13, 100, 100 * 1024**2)
        with patch.object(w, 'stop_renderer') as stop:
            watcher.scan([large, small])
            watcher.scan([large, small])
            stop.assert_not_called()
            watcher.scan([large, small])
            stop.assert_called_once_with(large)

    def test_recovery_missing_process_and_reused_pid_reset_the_grace_period(self):
        for middle in [[], [w.Renderer(12, 100, w.LIMIT_BYTES)], [w.Renderer(12, 101, w.LIMIT_BYTES + 1)]]:
            watcher = w.Watchdog()
            large = w.Renderer(12, 100, w.LIMIT_BYTES + 1)
            with patch.object(w, 'stop_renderer') as stop:
                watcher.scan([large])
                watcher.scan(middle)
                watcher.scan([large])
                stop.assert_not_called()

    def test_scan_continues_when_a_process_exits_or_cannot_be_signalled(self):
        for error in [ProcessLookupError(), PermissionError(1, 'denied')]:
            watcher = w.Watchdog()
            items = [w.Renderer(p, 100, w.LIMIT_BYTES + 1) for p in [12, 13]]
            with patch.object(w, 'stop_renderer', side_effect=[error, True]) as stop, patch('sys.stdout', new=io.StringIO()):
                for _ in range(3):
                    watcher.scan(items)
                self.assertEqual(stop.call_count, 2)

    def test_process_reader_excludes_browser_gpu_and_non_chrome_processes(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(w, 'PROC', Path(tmp)):
            root = Path(tmp) / '12'
            root.mkdir()
            (root / 'stat').write_text('12 (chromium) ' + ' '.join(['S', '1'] + ['0'] * 17 + ['12345']))
            (root / 'status').write_text('VmRSS:\t3145728 kB\n')
            for name, args, expected in [('chromium', b'chromium\0--type=renderer\0', True),
                                         ('chrome', b'chrome\0--type=renderer\0', True),
                                         ('chromium', b'chromium\0--type=gpu-process\0', False),
                                         ('chromium', b'chromium\0', False),
                                         ('python3', b'python3\0--type=renderer\0', False)]:
                (root / 'comm').write_text(name)
                (root / 'cmdline').write_bytes(args)
                result = w.read_renderer(12)
                self.assertEqual(result is not None, expected)
                if result:
                    self.assertEqual(result.started, 12345)
                    self.assertEqual(result.rss, 3 * 1024**3)
            self.assertIsNone(w.read_renderer(999))

    def test_attribution_follows_ancestors_and_ignores_other_screen_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp) / 'proc'
            screens = Path(tmp) / 'screens'
            screens.mkdir()
            bot = '450f1c0d-e471-47a5-a68f-a22b8a023ad5'
            (screens / bot).write_text('100\n')
            (screens / (bot + '.dbus')).write_text('100')
            for pid, parent, args in [(12, 10, b'chromium\0--type=renderer\0'),
                                      (10, 1, b'chromium\0--user-data-dir=/home/routi/.chromium-:100\0')]:
                root = proc / str(pid)
                root.mkdir(parents=True)
                (root / 'cmdline').write_bytes(args)
                (root / 'stat').write_text(f'{pid} (chromium) S {parent}')
            with patch.object(w, 'PROC', proc), patch.object(w, 'SCREENS', screens):
                self.assertEqual(w.attribution(12), {'display': ':100', 'bot_ids': [bot]})
                (proc / '10/cmdline').write_bytes(b'chromium\0--user-data-dir=/home/routi/chrome-profile-100\0')
                self.assertEqual(w.attribution(12)['bot_ids'], [bot])
                self.assertEqual(w.attribution(999), {'display': None, 'bot_ids': []})

    def test_kill_rechecks_identity_and_memory_after_opening_pidfd(self):
        old = w.Renderer(12, 100, w.LIMIT_BYTES + 1)
        for current in [None, w.Renderer(12, 101, old.rss), w.Renderer(12, 100, w.LIMIT_BYTES)]:
            with patch.object(w.os, 'pidfd_open', return_value=99, create=True), \
                 patch.object(w.os, 'close') as close, \
                 patch.object(w, 'read_renderer', return_value=current), \
                 patch.object(w.signal, 'pidfd_send_signal', create=True) as kill:
                self.assertFalse(w.stop_renderer(old))
                kill.assert_not_called()
                close.assert_called_once_with(99)

    def test_signal_targets_pidfd_and_logs_only_process_and_bot_metadata(self):
        large = w.Renderer(12, 100, w.LIMIT_BYTES + 1)
        with patch.object(w.os, 'pidfd_open', return_value=99, create=True), \
             patch.object(w.os, 'close'), patch.object(w, 'read_renderer', return_value=large), \
             patch.object(w, 'attribution', return_value={'display': ':102', 'bot_ids': ['test-bot']}), \
             patch.object(w.signal, 'pidfd_send_signal', create=True) as kill, \
             patch('sys.stdout', new=io.StringIO()) as log:
            self.assertTrue(w.stop_renderer(large))
            kill.assert_called_once_with(99, w.signal.SIGKILL)
            self.assertIn('test-bot', log.getvalue())
            self.assertIn('renderer_memory_limit', log.getvalue())


if __name__ == '__main__':
    unittest.main()
