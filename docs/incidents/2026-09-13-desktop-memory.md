# Mac mini desktop incident — September 13, 2026

The expanded viewer stalled and screen tools reported Docker was stopped. The
container had actually been running for four days. Docker had about 8 GiB of RAM;
its 1 GiB swap was full, and Linux reported memory stalls.

Process measurements apportioned shared RAM using `/proc/*/smaps_rollup` PSS.
One Chromium renderer in the browser showing Robinhood used about 5.1 GiB.
Terminating that renderer, without deleting its profile or restarting Docker,
reduced container memory from roughly 7 GiB to 1.9 GiB. The page needs reloading.
We did not establish why the renderer grew, or capture the original failed
health-check exception. Memory pressure is the likely trigger, not a proven
explanation of every viewer failure.

## Confirmed code defects and fixes

- `screenctl` could allocate the same X display to concurrent starts. A Linux
  `flock` now serializes start/stop. Children do not inherit the lock.
- A stale assignment could adopt another bot's live screen. Conflicting assignments
  now fail closed for lookup, start, and stop. Existing conflicts require repair;
  the script does not guess which bot owns the browser credentials.
- Stopping a display removed its assignment but retained its browser profile.
  Reservations now survive stop, and new allocations skip unassigned profile
  directories. Reservations last for the container's lifetime, including deleted
  bots; the existing 50-display limit therefore also bounds retained reservations.
- The dock and `act open` launched different browser profiles. Both now use
  `chrome-wrapper.sh`, the agent's existing `.chromium-:<display>` profile, and
  its CDP endpoint. Old dock profiles are not deleted or merged automatically.
- Docker health-check errors were collapsed into “Docker is not running.” Tool
  errors now distinguish a timeout, a missing CLI, and an unreachable daemon.
- The VNC viewer had no handshake deadline. It now disconnects and retries a
  connection that has not completed within 15 seconds.

## Repair on the Mini

Six configured bots had only four unique assignments. Robinhood retained `:100`
and Stock Price Analyzer retained `:99`. Paris Travel received a fresh `:104`;
@narralabs X received a fresh `:105`. Kalshi remained on `:101`, Camera Finder on
`:102`. Existing profiles and conversations were retained; credentials from the
formerly shared profiles were not copied into the new desktops.

Original scripts and assignments were backed up under
`~/.routi/backups/desktop-fix-20260913/`. The container scripts were patched in place
without rebuilding the container. The installed core remains release 0.1.35 until
an update; the improved core error and viewer timeout are in this change.

A container rebuild currently replaces its writable filesystem. Back up browser
profiles before deploying an image change if they must be retained. Persistent,
bot-owned profile storage and resource limits need a separate design; neither is
provided by this patch.

## Validation

The released allocator fails the new concurrency, stale-reservation, conflict,
and stop-reservation regressions. Linux tests run without real browsers or model
calls in the `desktop-scripts` CI job:

```sh
python3 -m unittest discover -s daemon/tests/container -p '*_test.py'
```

A separate disposable-container smoke check started three real X displays
concurrently and launched the dock and agent against one Chrome profile. Core
unit tests cover Docker errors and the VNC handshake deadline.
