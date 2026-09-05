# Krog Bot

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
   macOS app ────┼──▶  krogd  ──▶ Claude (subscription) │
                 │       │                             │
   iPhone   ─────┼──▶    ├──▶ SQLite                   │
   (Tailscale)   │       └──▶ container / host surface │
                 └─────────────────────────────────────┘
```

- **`daemon/`** — `krogd`, Node + TypeScript. Owns the Claude session, the database,
  the bots, and (from M3) the container and media pipeline. One WebSocket API.
- **`apple/`** — native SwiftUI, one target for Mac, iPad, and iPhone. Knows nothing
  about model providers; it only speaks krogd's protocol.
- **`protocol/`** — zod schemas defining the wire format. `apple/Krog/Models/` holds
  the hand-written Swift mirror; the two change in the same commit.
- **`containers/`** — the Xvfb + Chromium sandbox a bot drives (M3).

Because clients never talk to Anthropic, adding OpenAI / Grok / Kimi later is a
daemon-side adapter and nothing else changes.

## Running it

Prerequisites: Node 22+, pnpm, Flutter 3.41+, and `claude` logged in on this machine.

```bash
pnpm install
pnpm --filter @krog/protocol build

# terminal 1 — the daemon
pnpm --filter krogd dev            # ws://127.0.0.1:7171, data in ~/.krog

# terminal 2 — the app
cd apple && ./bootstrap.sh && open Krog.xcodeproj
```

`bootstrap.sh` regenerates the Xcode project from `project.yml` (the `.xcodeproj` is
disposable). By default it builds Mac only with ad-hoc signing, so a fresh clone runs
with no Apple account at all.

**For iPhone and iPad:** `./bootstrap.sh --ios` adds iOS to the target's destinations
and switches to automatic signing against your team. Device builds also need an Apple
ID signed in under Xcode > Settings > Accounts. The simulator needs neither:

```bash
./bootstrap.sh --ios
xcodebuild -scheme Krog -destination "id=<simulator udid>" \
  CODE_SIGNING_ALLOWED=NO build
```

Enabling iOS is why this is a switch rather than the default: a multiplatform target
makes the *Mac* build demand a team too, so the Mac-only default is what lets a fresh
clone build with no Apple account at all. Run plain `./bootstrap.sh` to go back.

Point the app at a different daemon under Krog > Settings. Remote access over
Tailscale lands in M2.

## Verifying

```bash
pnpm --filter krogd spike          # subscription auth reaches Claude at all
pnpm --filter krogd spike:session  # warm sessions + which credential is in use
pnpm --filter krogd probe          # full protocol: streaming, persistence, restart
cd apple && xcodebuild -scheme Krog -destination 'platform=macOS' build
```

With the daemon already running, `pnpm --filter krogd poke "..."` sends a message to
the live instance so you can watch the app render the stream — useful for checking the
client's render path without driving the UI.

`probe` is the important one — it drives the real WebSocket exactly as the Flutter
client does, so protocol work is never blocked on the UI.

## Onboarding

First run walks the user through setup before any chat UI appears. One flow, branching
on whether the device can host: a Mac offers to run the core itself, an iPhone can only
connect to one, so that choice is hidden there rather than offered and then refused.

Welcome -> where should the core run -> connect Claude -> done.

Connecting Claude offers the two credentials the daemon supports. Signing in with a
Claude account shells out to `claude auth login --claudeai`, which opens the browser
and performs the real OAuth; the token stays owned by the CLI and Krog never sees it.
Krog does **not** implement its own OAuth client against Anthropic's consumer auth —
that would mean impersonating Claude Code's client to reach someone's subscription,
which is not a supported integration.

An API key is validated against the live API (`models.list`, which spends no tokens)
*before* being stored, so a typo fails in onboarding rather than on the first message,
and a rejected key never lands in the Keychain.

## Authentication

`krogd` reaches Claude through `@anthropic-ai/claude-agent-sdk`, which picks up the
subscription login already on the machine (stored in the macOS Keychain). krogd never
sees or stores the credential.

Verified in the M0 spike: `subscriptionType: Claude Max`, `apiKeySource: none`, working
from a scrubbed launchd-style environment. Two consequences worth remembering:

- The daemon must run as the same user that ran `claude /login`.
- The login keychain must be unlocked, which on an auto-login Mac mini it is after
  boot. A locked keychain is the most likely cause of a daemon that starts but cannot
  reach Claude.

An API-key adapter is planned alongside, selectable in settings.

## Settings

Settings is a sheet over the app — a fixed-size panel with a nav list on the left and
an X to close — reached from the account row in the sidebar footer or ⌘,. On iPhone it
becomes a navigation stack that pushes into each pane.

Panes are General (theme, send key, reasoning visibility), one per **Provider**,
Krog Core (daemon endpoint and connection state), and About.

Each provider is its own entry with a tinted monogram tile — Anthropic, OpenAI, xAI,
Moonshot. Only Anthropic is wired up; the others are listed and marked "Soon" because
that is the roadmap, and each is a daemon-side adapter that will appear without an app
update. Krog Core sits in its own section: it is the daemon this app talks to, not a
model provider, and lumping the two under one "Connections" heading blurred that.

The monograms are deliberately not reproductions of anyone's logo. A consistent set of
tinted tiles reads as intentional design; hand-drawn approximations of real brand marks
would look wrong next to the genuine article.

The rows are hand-built rather than a SwiftUI `Form`: `Form`'s grouped style puts a
control and its description on separate lines and can't produce the two-line-label-
plus-trailing-control shape this layout needs.

## Design notes

**A new bot speaks first.** Creating a bot immediately runs a turn whose prompt is
never persisted, so the transcript opens with the bot introducing itself unprompted
and asking what it can take on. The wording comes from the model in the bot's own
voice rather than a template, so two personalities introduce themselves differently
and no two runs match; a rotating set of closing questions keeps repeat creations from
feeling canned.

**Account connectors leak into the subscription path.** Integrations enabled on the
Anthropic account attach server-side to every subscription session. `settingSources:
[]`, `mcpServers: {}` and `tools: []` were each measured and none of them remove the
connectors, because they are not local configuration — a fresh bot would introduce
itself as whatever tooling the account exposes instead of as itself. The system prompt
therefore states that the bot's description is the source of its identity and that
incidental tools are not. To remove them entirely, turn the connectors off in the
Anthropic account, or use the API-key credential, which carries none.

**Provider and model are fixed at creation.** Both are chosen in the New Bot sheet and
immutable afterwards, enforced in the protocol schema *and* pinned again in
`Store.updateBot`. Changing a model mid-thread would reinterpret an existing
conversation under different capabilities, and on the subscription adapter it would
strand the warm agent session that owns that history.

**Messages are block arrays, never strings.** A single assistant turn interleaves
prose, inline screenshots, and tool cards, so `messages.blocks_json` holds
`text | thinking | image | tool_use | tool_result | surface_event`. Getting this right
before tools land avoids a migration later.

**Deltas are addressed by block index.** The daemon emits
`message.delta{blockIndex, delta}` rather than appending to a running string, which is
what lets a tool card appear between two paragraphs mid-stream.

**Sessions stay warm.** The M0 spike measured ~2.3s TTFT on a cold turn versus ~1.3s
on a warm one — the difference is CLI process spawn. `krogd` holds one `query()` open
per conversation and feeds it through a push queue, so only the first message in a
conversation pays that cost.

**The transcript reads as a document, not a chat log.** Only the user's turn gets a
bubble; assistant replies run as plain text on the page. That single choice is most of
what separates a clean AI client from a wall of tinted rectangles — and the composer
floats as a rounded pill over the scroll view rather than sitting in a bar behind a
divider, so the window reads as one surface.

**The window chrome has no sidebar toggle, on purpose.** The system toggle anchors to
the detail pane's leading edge, so it slides across the window whenever the sidebar
collapses. Attempts to pin it — `.navigation` placement, a hidden title bar with
per-column headers — each traded that jump for a different misalignment. The reference
design simply has no toggle and an always-visible sidebar, which removes the problem
rather than compensating for it.

**The client is native SwiftUI, and adapts rather than branches.**
`NavigationSplitView` gives three columns on the Mac, sidebar-over-content on iPad, and
a push stack on iPhone from the same view code; `.listStyle(.sidebar)` supplies real
vibrancy and selection styling. The first client was Flutter, and the chrome had to be
rebuilt by hand — vibrancy, scroll physics, fonts, spacing — to approximate what the
native frameworks give away. Since every target here is an Apple platform, that work
was pure overhead. The daemon split is what made the swap cheap: nothing important
lived in the client.

**Streams, not VNC, for the surface.** From M3 the container is captured with ffmpeg,
encoded to H.264, and sent over WebRTC with input returning on a data channel. An
RFB-in-canvas client would be visibly worse on a phone and would have forced the whole
app onto web tech.

## Status

- [x] **M0** — skeleton, auth spike, warm-session spike
- [x] **M1** — chat: bots, conversations, streaming, persistence, model picker
- [x] **UI** — native SwiftUI client replacing the Flutter one
- [x] **Onboarding** — first-run setup, both Anthropic credential paths
- [ ] **M2** — Tailscale, device pairing, reconnect
- [ ] **M3** — container surface, WebRTC video, input injection, host surface
- [ ] **M4** — bots that drive the surface; tool cards wired up
- [ ] **M5** — OpenAI, Grok, Kimi adapters

Full plan: `~/.claude/plans/giggly-growing-parasol.md`.
