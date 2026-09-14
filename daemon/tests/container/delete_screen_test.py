"""Deletion is destructive only inside temporary fixtures; no real browser accounts."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().parents[3] / 'containers/desktop'
spec = importlib.util.spec_from_file_location('delete_screen', SOURCE / 'delete-screen.py')
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


class DeleteScreen(unittest.TestCase):
    def test_profiles_removed_but_shared_and_other_bot_files_survive(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in ('.chromium-:99', 'chrome-profile-99', '.chromium-:100', 'Downloads'):
                (root / name).mkdir()
                (root / name / 'keep').write_text('data')
            with patch.object(d, 'processes', return_value=set()), patch.object(d, 'TMP', root):
                d.destroy(99, root)
                d.destroy(99, root)
            self.assertFalse((root / '.chromium-:99').exists())
            self.assertFalse((root / 'chrome-profile-99').exists())
            self.assertEqual((root / '.chromium-:100/keep').read_text(), 'data')
            self.assertEqual((root / 'Downloads/keep').read_text(), 'data')

    def test_profile_symlink_does_not_delete_target(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            shared = root / 'shared'
            shared.mkdir()
            (shared / 'file').touch()
            (root / '.chromium-:99').symlink_to(shared)
            with patch.object(d, 'processes', return_value=set()), patch.object(d, 'TMP', root):
                d.destroy(99, root)
            self.assertTrue((shared / 'file').exists())
            self.assertFalse((root / '.chromium-:99').is_symlink())

    def test_sandboxed_children_and_relay_belong_only_to_their_display(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for pid, parent, args in [(10, 1, '--user-data-dir=/home/routi/.chromium-:99'),
                                      (11, 10, '--type=zygote'), (12, 11, '--type=renderer'),
                                      (20, 1, '--user-data-dir=/home/routi/.chromium-:100'),
                                      (30, 1, 'TCP-LISTEN:9222,fork,reuseaddr,bind=0.0.0.0')]:
                proc = root / str(pid)
                proc.mkdir()
                (proc / 'stat').write_text(f'{pid} (chromium) S {parent}')
                (proc / 'cmdline').write_text(args)
                (proc / 'environ').write_bytes(b'')
            with patch.object(d, 'PROC', root):
                self.assertEqual(d.processes(99, Path('/home/routi')), {10, 11, 12, 30})

    def test_failure_keeps_reservation_and_success_releases_it(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state = root / 'state'
            state.mkdir()
            bot = '11111111-1111-1111-1111-111111111111'
            other = '22222222-2222-2222-2222-222222222222'
            (state / bot).write_text('99')
            with patch.object(d, 'STATE', state), patch.object(d, 'destroy', side_effect=RuntimeError('cleanup failed')):
                with self.assertRaisesRegex(RuntimeError, 'cleanup failed'):
                    d.delete_bot(bot, root)
            self.assertTrue((state / bot).exists())
            (state / other).write_text('99')
            with patch.object(d, 'STATE', state), patch.object(d, 'destroy') as destroy:
                with self.assertRaisesRegex(RuntimeError, 'conflicting bot assignments'):
                    d.delete_bot(bot, root)
                destroy.assert_not_called()
                (state / other).write_text('100')
                d.delete_bot(bot, root)
                destroy.assert_called_once_with(99, root)
                self.assertFalse((state / bot).exists())
                self.assertEqual((state / other).read_text(), '100')
                d.delete_bot(bot, root)
                with self.assertRaisesRegex(ValueError, 'Invalid bot id'):
                    d.delete_bot('../other', root)
