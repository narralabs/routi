#!/usr/bin/env python3
"""Permanently delete one bot desktop while holding the screen allocation lock."""
import fcntl
import os
import re
from pathlib import Path
import shutil
import signal
import sys
import time

PROC = Path('/proc')
TMP = Path('/tmp')
STATE = TMP / 'routi-screens'


def processes(display, home):
    """Find this display's processes, including sandboxed browser descendants."""
    found, parents = set(), {}
    profiles = {f'--user-data-dir={home}/.chromium-:{display}', f'--user-data-dir={home}/chrome-profile-{display}'}
    for root in PROC.iterdir():
        if not root.name.isdigit() or int(root.name) == os.getpid():
            continue
        try:
            if root.stat().st_uid != os.getuid():
                continue
            stat = (root / 'stat').read_text().rsplit(')', 1)[1].split()
            if stat[0] == 'Z':
                continue
            pid = int(root.name)
            parents[pid] = int(stat[1])
            args = (root / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace').split()
            try:
                environment = (root / 'environ').read_bytes().split(b'\0')
            except PermissionError:
                environment = []  # Chromium's sandbox can hide environ.
            desktop = f'DISPLAY=:{display}'.encode() in environment
            browser = bool(profiles.intersection(args))
            relay = f'TCP-LISTEN:{9222 + display - 99},fork,reuseaddr,bind=0.0.0.0' in args
            vnc = '-display' in args and f':{display}' in args
            xserver = args[:2] == ['Xvfb', f':{display}']
            if desktop or browser or relay or vnc or xserver:
                found.add(pid)
        except (FileNotFoundError, ProcessLookupError):
            continue
    # Never signal this cleanup command or its callers, even with inherited DISPLAY.
    ancestor = os.getpid()
    protected = {ancestor}
    while ancestor > 1:
        try:
            ancestor = int((PROC / str(ancestor) / 'stat').read_text().rsplit(')', 1)[1].split()[1])
        except FileNotFoundError:
            break
        if ancestor in protected:
            break
        protected.add(ancestor)
    found -= protected
    while True:
        children = {pid for pid, parent in parents.items() if parent in found and pid not in protected}
        if children <= found:
            return found
        found |= children


def destroy(display, home):
    # Pin process identities before signalling. Descendants may have no readable DISPLAY.
    handles = {}
    try:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for pid in processes(display, home):
                if pid not in handles:
                    try:
                        fd = os.pidfd_open(pid)
                        # Recheck after opening the handle, guarding PID reuse.
                        if pid not in processes(display, home):
                            os.close(fd)
                            continue
                        handles[pid] = fd
                    except ProcessLookupError:
                        continue
                try:
                    signal.pidfd_send_signal(handles[pid], sig)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + 2
            while processes(display, home) and time.monotonic() < deadline:
                time.sleep(.05)
            if not processes(display, home):
                break
        else:
            raise RuntimeError('Desktop processes are still running; deletion can be retried.')
    finally:
        for fd in handles.values():
            os.close(fd)

    for name in (f'.chromium-:{display}', f'chrome-profile-{display}'):
        path = home / name
        if path.is_symlink():
            path.unlink()  # Never follow a profile symlink into shared data.
        elif path.exists():
            shutil.rmtree(path)
    # All are display-specific; Downloads and the rest of the home are shared.
    for name in (f'.X{display}-lock', f'.X11-unix/X{display}',
                 f'xfwm4-{display}.log', f'picom-{display}.log', f'plank-{display}.log',
                 f'xvfb-{display}.log', f'start-screen-{display}.log'):
        (TMP / name).unlink(missing_ok=True)


def delete_bot(bot_id, home):
    if not re.fullmatch(r'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}', bot_id):
        raise ValueError('Invalid bot id')
    STATE.mkdir(exist_ok=True)
    with (STATE / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        reservation = STATE / bot_id
        if not reservation.exists():
            return
        display = int(reservation.read_text().strip())
        if not 99 <= display <= 148:
            raise ValueError('Invalid display reservation')
        for other in STATE.iterdir():
            if other == reservation or other.name.startswith('.') or other.name.endswith('.dbus'):
                continue
            if other.read_text().strip() == str(display):
                raise RuntimeError('Display has conflicting bot assignments; deletion refused.')
        destroy(display, home)
        (STATE / (bot_id + '.dbus')).unlink(missing_ok=True)
        reservation.unlink()  # Last: failed cleanup can be retried without losing ownership.


if __name__ == '__main__':
    try:
        delete_bot(sys.argv[1], Path.home())
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
