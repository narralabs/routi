# Korg Bot

A self-hosted, provider-agnostic take on Grok Bot: persistent chat bots, each with its
own personality and model, that will eventually be able to see and drive a live
desktop.

## Shape of the thing

The Mac mini is always on and owns the Anthropic login. Everything else is a client of
it — including the phone, which is not a lesser app but the same app over a different
network path.

```
                 ┌─────────────────────────────────────┐
                 │            Mac mini                 │
                 │                                     │
   macOS app ────┼──▶  korgd  ──▶ Claude (subscription) │
                 │       │                             │
   iPhone   ─────┼──▶    ├──▶ SQLite                   │
   (Tailscale)   │       └──▶ container / host surface │
                 └─────────────────────────────────────┘
```

- **`daemon/`** — `korgd`, Node + TypeScript. Owns the Claude session, the database,
  the bots, and (from M3) the container and media pipeline. One WebSocket API.
- **`app/`** — Flutter, builds macOS and iOS from one codebase. Knows nothing about
  model providers; it only speaks korgd's protocol.
- **`protocol/`** — zod schemas defining the wire format. `app/lib/api/models.dart` is
  the hand-written Dart mirror; the two change in the same commit.
- **`containers/`** — the Xvfb + Chromium sandbox a bot drives (M3).

Because clients never talk to Anthropic, adding OpenAI / Grok / Kimi later is a
daemon-side adapter and nothing else changes.

## Running it

Prerequisites: Node 22+, pnpm, Flutter 3.41+, and `claude` logged in on this machine.

```bash
pnpm install
pnpm --filter @korg/protocol build

# terminal 1 — the daemon
pnpm --filter korgd dev            # ws://127.0.0.1:7171, data in ~/.korg

# terminal 2 — the app
cd app && flutter run -d macos --no-tree-shake-icons
```

The `--no-tree-shake-icons` flag works around a broken font-subset tool in Flutter
3.41.6 — without it the macOS release build fails in `ReleaseMacOSBundleFlutterAssets`
with a bare `dart help` dump. It costs about 1 MB of bundle and nothing else.

For the phone, run `flutter run -d <device>` and point `KorgClient` at the mini's
address. Remote access over Tailscale lands in M2.

## Verifying

```bash
pnpm --filter korgd spike          # subscription auth reaches Claude at all
pnpm --filter korgd spike:session  # warm sessions + which credential is in use
pnpm --filter korgd probe          # full protocol: streaming, persistence, restart
cd app && flutter analyze
```

With the daemon already running, `pnpm --filter korgd poke "..."` sends a message to
the live instance so you can watch the app render the stream — useful for checking the
client's render path without driving the UI.

`probe` is the important one — it drives the real WebSocket exactly as the Flutter
client does, so protocol work is never blocked on the UI.

## Authentication

`korgd` reaches Claude through `@anthropic-ai/claude-agent-sdk`, which picks up the
subscription login already on the machine (stored in the macOS Keychain). korgd never
sees or stores the credential.

Verified in the M0 spike: `subscriptionType: Claude Max`, `apiKeySource: none`, working
from a scrubbed launchd-style environment. Two consequences worth remembering:

- The daemon must run as the same user that ran `claude /login`.
- The login keychain must be unlocked, which on an auto-login Mac mini it is after
  boot. A locked keychain is the most likely cause of a daemon that starts but cannot
  reach Claude.

An API-key adapter is planned alongside, selectable in settings.

## Design notes

**Messages are block arrays, never strings.** A single assistant turn interleaves
prose, inline screenshots, and tool cards, so `messages.blocks_json` holds
`text | thinking | image | tool_use | tool_result | surface_event`. Getting this right
before tools land avoids a migration later.

**Deltas are addressed by block index.** The daemon emits
`message.delta{blockIndex, delta}` rather than appending to a running string, which is
what lets a tool card appear between two paragraphs mid-stream.

**Sessions stay warm.** The M0 spike measured ~2.3s TTFT on a cold turn versus ~1.3s
on a warm one — the difference is CLI process spawn. `korgd` holds one `query()` open
per conversation and feeds it through a push queue, so only the first message in a
conversation pays that cost.

**The macOS chrome is native, not simulated.** `macos_window_utils` gives the window a
real `NSVisualEffectView` sidebar material, so the side panes are genuinely translucent
rather than painted grey. The title bar is hidden with the traffic lights kept and
inset into the sidebar's top padding; drag-to-move is restored by handing that strip's
mouse events back to the native titlebar via `MacosToolbarPassthrough`, since the
plugin has no Dart-side drag call.

**No `fontFamily` anywhere.** On Apple platforms Flutter already resolves to the system
UI font, correctly optical-sized. Naming a family string opts out of that and is the
single most common reason a Flutter app reads as not-quite-native on macOS.

**Streams, not VNC, for the surface.** From M3 the container is captured with ffmpeg,
encoded to H.264, and sent over WebRTC with input returning on a data channel. An
RFB-in-canvas client would be visibly worse on a phone and would have forced the whole
app onto web tech.

## Status

- [x] **M0** — skeleton, auth spike, warm-session spike
- [x] **M1** — chat: bots, conversations, streaming, persistence, model picker
- [ ] **M2** — Tailscale, device pairing, reconnect
- [ ] **M3** — container surface, WebRTC video, input injection, host surface
- [ ] **M4** — bots that drive the surface; tool cards wired up
- [ ] **M5** — OpenAI, Grok, Kimi adapters

Full plan: `~/.claude/plans/giggly-growing-parasol.md`.
