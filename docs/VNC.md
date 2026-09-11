# Desktop viewing

Container desktops use VNC in the Mac, iPhone and iPad app, including sidebar
previews. There is no container JPEG viewer, polling loop or JPEG/VNC switch.
The mobile TouchLayer still handles the whole pane, including black margins,
trackpad mode, zoom and the larger cursor. Keyboard and clipboard input retain
the existing surface RPCs. Agent screenshot tools and inline chat images remain.

“This Mac” uses a different capture backend and retains its native JPEG viewer.
`surface.frame` and the explicitly named host-frame polling methods are only for
that surface. Removing them would remove existing host-screen functionality.

## Connection and packaging

The app calls `surface.viewer` on its existing core connection to get a capability
path. It resolves that path against the same core host and port, then loads the
viewer in WKWebView. The core serves the HTML, pinned noVNC JavaScript modules and
binary WebSocket stream on its normal listeners. noVNC is a production dependency.
No separate preview process, Docker port publishing or Debug launch flags are needed.

The stream passes through `docker exec -i` / socat to x11vnc on container loopback.
The Docker image already includes both programs. The core looks up the bot's
existing display using screenctl; opening a viewer never creates a new display.

Core listeners retain their existing loopback/Tailscale trust boundary. Viewer
paths contain a random per-core capability, bot IDs are validated, and WebSocket
upgrades require a matching Origin/Host. The HTTP handler serves only viewer HTML
and noVNC modules. Responses are not cached and suppress Referer disclosure.
Do not expose the core directly to the public internet. Physical phones use the
same existing private-network core connection as chat.

## Ownership and reconnect

Each watched display has one VNC server with a lease for each connection. Three
devices watching one bot share a server; three different watched bots use three.
An idle server exits 30 seconds after its final viewer disconnects. Unwatched bots
do not start VNC servers. This does not stop their browsers or X displays.

Every VNC server has a supervising Docker exec process that holds stdin open.
When the owning core exits, including SIGKILL, EOF causes the supervisor to stop
its VNC process. Graceful shutdown also closes all viewer connections and leases.
The backend bounds shutdown waiting so an unresponsive Docker CLI cannot block it
indefinitely. A stopped server is invalidated before retrying.

The stream preserves RFB update order with backpressure. Heartbeats detect silent
clients within roughly 30 seconds. The page reconnects with a fresh RFB instance
after disconnect; it does not reuse an incomplete framebuffer. Hidden viewers
release their connections. The Apple view resolves a new capability when the core
reconnects or the app becomes active. Manual Retry covers capability lookup errors.

## Cursors and input

XFixes provides desktop cursor images. Mobile forwards shape updates and hotspots
through WKScriptMessageHandler and draws them at 26 points; absent, transparent
or invalid images fall back to the existing arrow. Pointer movement stays in the
native TouchLayer and does not transfer cursor images.

noVNC 1.7.0 has no public cursor-change event, so the small mobile hook wraps
`_updateCursor`. Review it when upgrading noVNC. The hook is guarded; the Mac viewer
does not use it. Mobile web-view touch input is disabled to avoid double input.

## Validation and remaining limitations

Offline tests cover routing through the normal core listener, capabilities, Origin,
shared leases, disconnect/startup races, dead sockets, heartbeat expiry and cursor
forwarding/fallback. They use fakes and make no model calls. Mac and iOS release
builds exercise the production path.

A real Docker ownership check killed the VNC-owning Node process with SIGKILL:
the VNC port closed while its X display stayed running. Prior physical testing
confirmed mobile full-pane gestures and contextual cursors. Total CPU/memory and
three-device throughput have not been benchmarked. Paste latency is deferred.
The phone may take 1–2 seconds to recenter the desktop after keyboard dismissal;
the user accepted deferring that visual issue. An unsuccessful inset workaround
was removed rather than retained as an unverified fix.
