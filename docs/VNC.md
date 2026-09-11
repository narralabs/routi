# Desktop viewing

Container desktops use VNC in the Mac, iPhone and iPad app, including sidebar previews.

## Connection

```text
App (WKWebView + noVNC)
  → core's VNC bridge (WebSocket)
  → Docker's x11vnc (TCP)
  → bot's X display
```

The app requests a token-protected viewer path through `surface.viewer`. The
viewer, MCP and chat API share the core's host and port. Phones connect through
the same private network as chat; Docker's VNC ports stay on container loopback.
The bridge validates the viewer token, bot ID and WebSocket Origin/Host.

## Lifecycle

One VNC server serves each watched desktop, shared across devices. It stops
30 seconds after the last viewer disconnects. A supervisor also stops it if the
core exits or is killed. The bot's desktop and browser keep running.

Heartbeats detect silent connections within roughly 30 seconds. Viewers reconnect
automatically and release their connections in the background. The app obtains
a fresh viewer path after reconnecting to the core.

## Input and maintenance

Mobile uses native full-pane touch controls, including the black margins, and
renders VNC cursor shapes at 26 points. Its keyboard and clipboard use surface
RPCs. The mobile cursor hook uses noVNC 1.7.0's private `_updateCursor` method;
check it when upgrading noVNC.

“This Mac” uses host-screen capture through `surface.frame`. Agent screenshots
and chat images are separate from desktop viewing.

Tests: `daemon/tests/vnc.test.ts`. Known follow-ups: paste latency and the brief
mobile recentering delay after keyboard dismissal.
