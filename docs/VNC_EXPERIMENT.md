# Local VNC viewer experiment

This is an opt-in Mac Debug experiment, not a replacement for the released viewer.
The build uses its own app identifier so it can coexist with the regular app.
The daemon and Docker image are unchanged. Agent screenshot tools are unchanged.

## Run

From this checkout, install dependencies and build the Mac app:

```sh
pnpm install --frozen-lockfile
xcodebuild -project apple/Routi.xcodeproj -scheme Routi -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/Routi-vnc-build \
  PRODUCT_BUNDLE_IDENTIFIER=com.narralabs.routi.vnc-preview build
```

Run the temporary bridge in a terminal:

```sh
cd daemon
node --import tsx scripts/experiments/vnc-preview.ts
```

It prints `VNC_PREVIEW_URL=...`. Pass that URL to the Debug app:

```sh
open -n '/tmp/Routi-vnc-build/Build/Products/Debug/Routi Bot.app' --args \
  -daemonHost 127.0.0.1 -daemonPort 7172 -vncPreviewURL '<printed URL>'
```

An existing dev core must already be listening on 7172. Open a container bot's
running desktop. The expanded viewer has a JPEG/VNC switch. Without the launch
argument, the app uses its ordinary viewer. Close older dev app instances first
so their polling does not distort a comparison.

The bridge defaults to loopback port 7173 and container `routi-desktop`.
`ROUTI_VNC_PORT`, `ROUTI_VNC_CONTAINER`, and `ROUTI_DOCKER_BIN` override those values.
Do not point the app and bridge at different desktop hosts.

## Connection

```text
Mac WKWebView + locally served noVNC
  → binary WebSocket to the temporary localhost bridge
  → docker exec -i → socat → container-loopback TCP → x11vnc
  → the bot's existing X display
```

The image already includes x11vnc and socat. The bridge looks up the bot's display
with `screenctl live`; it never allocates, restarts, or deletes desktops. Each viewed display gets one x11vnc server, reused across viewer connections.
Closing a viewer releases its connection. The last viewer leaving starts a
30-second grace period, after which that display's VNC server stops. Reconnecting
during the grace period reuses the server. Stopping the experiment bridge removes
all VNC servers it started. The X displays and bots survive both operations. VNC ports
15900–15949 are bound only inside the container, never published to the Mac or LAN.
Run only one experiment bridge against a given container. Stop it with Ctrl-C when finished.

The URL contains a random capability. WebSocket upgrades require that capability,
a valid bot UUID, and the local viewer's exact Origin and Host. This is local-only
experiment access, not a remote authentication design. Assets come from a pinned
noVNC development dependency; nothing is loaded from a CDN. Its license files are
included in that dependency.

Node streams apply transport backpressure; RFB updates are not arbitrarily dropped.
A full production implementation would also need connection limits, reconnection,
remote authentication, and deployment packaging.

## Comparison and limits

- JPEG retains its existing 120 ms expanded-view polling interval.
- VNC uses noVNC's scaling and quality level 6, without resizing the X display.
- Mouse and keyboard use VNC. The native Paste button uses Routi's existing paste
  RPC in both modes, so this experiment does not compare clipboard transports.
- Mac clipboard shortcuts, copy-back, keyboard layouts, and iOS touch controls are
  not at feature parity. iOS and Release builds retain their existing viewer.
- The sidebar thumbnail remains JPEG. Normally opening the expanded desktop removes
  the sidebar, so only the selected expanded transport remains active in that window.
- Compare static screens, scrolling, typing, and dragging. Include Docker, the
  bridge, the Mac app, and WebKit helper processes in CPU/memory measurements.
  The Docker exec transport adds overhead, so this is not a final VNC benchmark.
- VNC does not arbitrate simultaneous human and agent input.

## Checks

`pnpm test` includes offline bridge tests using a local echo process: binary data
survives, the bot maps to the expected display, unrelated web origins and missing
screens are rejected, and disconnect ends the child process. These tests do not
start Docker, access credentials, or call models. Real x11vnc lifecycle and Mac
rendering need a local manual check. Nothing automatically starts this experiment
in GitHub Actions.

For a repeatable local check, add `-showScreen -previewBotID <existing bot UUID>`
to open a particular bot’s desktop directly. This only applies to Debug builds.

## Initial local result

The Mac Debug app builds and renders the existing Docker desktop using noVNC.
Switching JPEG → VNC → JPEG works, as does reopening the VNC connection. Stopping
the bridge removes its VNC servers without stopping the X displays. The two
bridge tests and the existing suite pass (31 total); the core builds as well.

Keyboard shortcuts did not produce the expected result during computer-use checks,
including after isolating the app identifier. Treat keyboard input as unresolved
until a physical test confirms it or a follow-up fixes it. This is a viewing
experiment, not input feature parity. Clipboard transport and performance have
not been benchmarked. X RECORD remains disabled for compatibility. XFixes is enabled: x11vnc reads
the desktop cursor image and noVNC renders the received shape, including I-beams,
hands, resize cursors, and custom application cursors.

## Viewer lifecycle and force quits

Viewer accounting belongs to the bridge, not a SwiftUI onDisappear callback.
Each WebSocket holds one idempotent lease on its display. A second device watching
the same desktop adds a lease to the existing server. One device leaving does not
interrupt the other. An app force quit normally closes its socket immediately and
releases the lease without needing a JavaScript page-unload message.

The bridge pings every 15 seconds. A connection missing its response is terminated
at the next check (within roughly 30 seconds), which also releases its lease.
An otherwise idle VNC server then exits after the 30-second grace period. This
covers sleep/network loss as well as orderly close. It does not stop the bot,
browser, X display, or container.

Startup, stop, and reconnect are serialized per display. A viewer that disappears
while Docker is starting VNC still releases its lease once startup completes.
Offline tests cover two devices, separate displays, grace-period reconnect,
startup failure/retry, reconnect during shutdown, socket termination, missing
pongs, and disconnect during startup. No tests require model credentials.

The experiment bridge itself being SIGKILLed is a separate case: it cannot run its
own shutdown hooks. This experiment does not yet provide an external supervisor
or orphan reconciliation for that case; it must be addressed before production
integration into routid.

The lifecycle update passes all 37 offline tests. A real local viewer process was
SIGKILLed while connected through the bridge to Docker display :99: its VNC server
was gone after the 30-second grace period, while the existing Mac viewer's server
on :101 remained running. A read-only RFB check also received a cursor-image update
from the XFixes-enabled server. Visual cursor-shape verification remains a manual
check in the Mac preview.
