#!/usr/bin/env python3
"""Stop sustained oversized Chromium renderers, without restarting their browser."""
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import threading
from dataclasses import dataclass

LIMIT_BYTES = 2 * 1024**3
INTERVAL_SECONDS = 5
REQUIRED_READINGS = 3
PROC = Path('/proc')
SCREENS = Path('/tmp/routi-screens')


@dataclass(frozen=True)
class Renderer:
    pid: int
    started: int
    rss: int

    @property
    def identity(self):
        return self.pid, self.started


def read_renderer(pid):
    """RSS is cheap to read; it includes resident shared pages, not swapped bytes."""
    try:
        root = PROC / str(pid)
        if (root / 'comm').read_text().strip() not in ('chromium', 'chrome'):
            return None
        args = (root / 'cmdline').read_bytes().replace(b'\0', b' ').split()
        if b'--type=renderer' not in args:
            return None
        # Fields after the final ')' begin at field 3; starttime is field 22.
        started = int((root / 'stat').read_text().rsplit(')', 1)[1].split()[19])
        status = (root / 'status').read_text()
        rss = re.search(r'^VmRSS:\s+(\d+) kB$', status, re.M)
        return Renderer(pid, started, int(rss[1]) * 1024) if rss else None
    except (OSError, ValueError, IndexError):
        return None  # Processes can exit at any point during a scan.


def attribution(pid):
    """Resolve the display through the browser's ancestors; never log command lines."""
    seen = set()
    display = None
    while pid > 1 and pid not in seen:
        seen.add(pid)
        try:
            root = PROC / str(pid)
            args = (root / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
            match = re.search(r'--user-data-dir=\S*/(?:\.chromium-:|chrome-profile-)(\d+)(?:\s|$)', args)
            if match:
                display = match[1]
                break
            pid = int((root / 'stat').read_text().rsplit(')', 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    bots = []
    for path in SCREENS.glob('*'):
        if not re.fullmatch(r'[a-fA-F0-9-]{36}', path.name):
            continue
        try:
            if display and path.read_text().strip() == display:
                bots.append(path.name)
        except OSError:
            pass
    return {'display': ':' + display if display else None, 'bot_ids': sorted(bots)}


def stop_renderer(renderer):
    """A pidfd keeps a recycled PID from redirecting the signal to another process."""
    fd = os.pidfd_open(renderer.pid)
    try:
        current = read_renderer(renderer.pid)
        if not current or current.identity != renderer.identity or current.rss <= LIMIT_BYTES:
            return False
        owner = attribution(renderer.pid)
        signal.pidfd_send_signal(fd, signal.SIGKILL)
        print(json.dumps({'event': 'renderer_memory_limit', 'pid': renderer.pid,
                          'rss_bytes': current.rss, 'limit_bytes': LIMIT_BYTES,
                          'readings': REQUIRED_READINGS, **owner}), flush=True)
        return True
    finally:
        os.close(fd)


class Watchdog:
    def __init__(self):
        self.readings = {}

    def scan(self, renderers):
        readings = {}
        for renderer in renderers:
            if renderer.rss <= LIMIT_BYTES:
                continue
            count = self.readings.get(renderer.identity, 0) + 1
            if count >= REQUIRED_READINGS:
                try:
                    stop_renderer(renderer)
                except ProcessLookupError:
                    pass
                except OSError as error:
                    print(json.dumps({'event': 'renderer_watchdog_error', 'pid': renderer.pid,
                                      'errno': error.errno}), flush=True)
                # Require fresh consecutive readings after an attempted intervention.
            else:
                readings[renderer.identity] = count
        self.readings = readings


def main():
    # Also prevents a manual hot-start from running beside the entrypoint's watcher.
    with open('/tmp/routi-renderer-watchdog.lock', 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        stopped = threading.Event()
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, lambda *_: stopped.set())
        watcher = Watchdog()
        print(json.dumps({'event': 'renderer_watchdog_started', 'limit_bytes': LIMIT_BYTES,
                          'interval_seconds': INTERVAL_SECONDS, 'readings': REQUIRED_READINGS}), flush=True)
        while not stopped.is_set():
            renderers = (read_renderer(int(path.name)) for path in PROC.iterdir() if path.name.isdigit())
            watcher.scan(renderer for renderer in renderers if renderer is not None)
            stopped.wait(INTERVAL_SECONDS)


if __name__ == '__main__':
    main()
