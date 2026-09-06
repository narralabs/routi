# How Routi is built

The README says what it is and how to install it. This is the rest: the shape, the
decisions that were measured rather than assumed, and how a release is cut. Adding an AI
provider has its own map in `CLAUDE.md`.

## Shape

The Mac that stays on runs the core and owns every login. Everything else is a client of
it — including the phone, which is the same app over a different network path.

```
                 ┌──────────────────────────────────────────┐
                 │               host Mac                   │
   macOS app ────┼──▶  routid  ──▶ Claude / OpenAI / xAI …  │
   iPhone   ─────┼──▶    ├──▶ SQLite                        │
   (Tailscale)   │       └──▶ container / host screen       │
                 └──────────────────────────────────────────┘
```

- **`daemon/`** — `routid`, Node + TypeScript. Owns the credentials, the database, the
  bots, the screens. One WebSocket API on `127.0.0.1:7171`, data in `~/.routi`.
- **`apple/`** — SwiftUI, one target for Mac, iPad and iPhone. Knows no provider beyond
  a display roster; it speaks the protocol and renders blocks.
- **`protocol/`** — zod schemas for the wire format. `apple/Routi/Models/` is the
  hand-written Swift mirror; the two change in the same commit.
- **`containers/desktop/`** — the shared Linux desktop: one machine, an X display per
  bot, Chromium, and a small `act` script that is the only input surface exposed.

Because clients never talk to a vendor, a provider is a daemon-side adapter and nothing
else changes.

## Running from source

Node 22+ and pnpm (the version is pinned in `package.json`; `corepack` honours it).

```bash
pnpm install && pnpm --filter @routi/protocol build
pnpm --filter routid dev              # the core on 7171, data in ~/.routi
pnpm --filter routid dev:isolated     # or: a second core on ~/.routi-dev, port 7172
cd apple && ./bootstrap.sh && open Routi.xcodeproj
```

Use `dev:isolated` when a packaged core is serving your real bots. Every save restarts
the daemon, and a restart ends any turn in flight; the isolated core also never runs the
screen reaper, which would otherwise stop the real core's screens — it has none of those
bots in its database and sees every screen as an orphan.

`bootstrap.sh` regenerates the Xcode project from `project.yml`; the `.xcodeproj` is
disposable. It builds Mac only with ad-hoc signing by default, so a fresh clone runs with
no Apple account. `./bootstrap.sh --ios` adds iOS and switches to automatic signing
against your team; the simulator needs neither:

```bash
xcodebuild -scheme Routi -destination "id=<simulator udid>" CODE_SIGNING_ALLOWED=NO build
```

## Verifying

```bash
pnpm --filter routid typecheck
pnpm --filter routid spike            # subscription auth reaches Claude at all
pnpm --filter routid spike:session    # warm sessions, and which credential is in use
pnpm --filter routid spike:grok       # one real Grok turn, tools and all, on a fake screen
pnpm --filter routid probe            # the full protocol: streaming, persistence, restart
cd apple && xcodebuild -scheme Routi -destination 'platform=macOS' build
```

`probe` drives the real WebSocket exactly as the app does, so protocol work is never
blocked on the UI. With a daemon running, `pnpm --filter routid poke "..."` sends a
message to it so the app's render path can be watched without driving the UI.

## Releasing

Two artifacts, one script. `scripts/package.sh` builds the app universal and Release,
signs it with a Developer ID Application certificate when the keychain has one, and
notarizes and staples when credentials are stored (`xcrun notarytool store-credentials
routi-notary`); without them it signs to run locally and says so. It also packs the core
as a source tarball with its installer.

The core publishes itself: pushing a `v*` tag runs `.github/workflows/release.yml`, which
attaches `routi-core.tar.gz` and its sha256 to a GitHub release. The app does not — the
certificate lives on one Mac — so a release is:

```bash
git tag v0.x.y && git push origin main v0.x.y      # core builds and publishes
scripts/package.sh                                 # app, notarized
gh release upload v0.x.y build/Routi.zip --clobber
```

then the checksum from the release into `packaging/homebrew/routi-core.rb` (url and
sha256 are the two lines that change), copied to `Formula/routi-core.rb` in the
`narralabs/homebrew-tap` repository. `scripts/install.sh` is the curl route and points at
the release's `latest` asset, so it needs nothing per release.

The formula runs the repository's pinned pnpm through `corepack` rather than depending
on Homebrew's, whose major version refused the native build scripts the daemon needs.
`pnpm-workspace.yaml` names those two — `better-sqlite3` and `esbuild` — because pnpm 10
skips dependency build scripts it has not been told to run.

## Authentication

Nobody installs a vendor CLI to use a plan. The Agent SDK pins a Claude Code version in
its manifest and fetches that build, checksummed, the first time a turn needs it; Codex
is a dependency versioned with the SDK that drives it. Sign-in uses those same binaries.
Grok is the exception — xAI ships it only through their own installer — and the app says
where to get it.

Signing in with a Claude account runs `claude auth login --claudeai`: the browser opens,
the real OAuth happens, and the token stays owned by the CLI in the Keychain. Routi does
not implement its own OAuth client against a vendor's consumer auth — that would mean
impersonating the vendor's client to reach someone's subscription, which is not a
supported integration. An API key is validated against the live API before it is stored,
so a typo fails in onboarding rather than on a bot's first message.

Two consequences of the Keychain holding the login: the core must run as the user who
signed in, and the login keychain must be unlocked — which an auto-login Mac's is after
boot. A locked keychain is the likeliest cause of a core that starts but cannot reach
Claude.

## The desktop

One container, shared by every bot, with a display per bot. The value of a desktop is
its accumulated state — a signed-in site, a browser profile, downloaded files — and a
container per bot would discard that on every bot you create. The daemon starts it on
demand and leaves it running across its own restarts, since losing browser sessions to a
restart would defeat the point.

**Bots drive it themselves.** A bot with a screen gets the desktop as tools — `read_page`
and `click_ref` for the page's accessibility tree, `screenshot` and `click` for pixels,
`type_text`, `press_key`, `scroll`, and `ask_to_take_over` for the moments only a person
can do. The structured path is Chrome DevTools Protocol over the container's debugging
port; the pixel path is the X framebuffer. Krog's instruction to the bot is to prefer the
tree and fall back to pixels, which is what a bot is seen doing on a site whose date
picker the tree does not describe. The tools are pre-approved: a permission prompt per
click would make any real task unusable, and the person granted this by giving the bot a
screen.

Frames are **pulled**, not pushed: the client asks for a JPEG at whatever rate it can
draw — slower for the rail thumbnail, faster for the full-size view — so an idle window
costs nothing and a slow link degrades to a lower frame rate instead of queueing frames it
will never show.

Two container flags are load-bearing, both found by watching it fail: `--shm-size=1g`,
because Chromium crashes on any real page with Docker's default 64MB; and
`--security-opt seccomp=unconfined`, because Chromium's sandbox creates user namespaces,
which Docker's default seccomp denies. The alternative, `--no-sandbox`, switches
Chromium's isolation off entirely; this keeps it and leans on the container as the
boundary.

## Turns, routines, and what waits for what

Turns are serialised per conversation and the screen is held for the whole turn: a turn
is many actions, and two bots interleaving clicks on one browser would corrupt both.
Different bots run in parallel, each on its own display.

A message sent while a reply is streaming is saved, shown, and answered next — two sent
while waiting are answered together, because "actually, make it two nights" means both
things at once. The reply is not interrupted; the Stop button is for that.

A routine is the same bot, scheduled: it wakes in the bot's own conversation with its
saved prompt and sees the same history a reply to a person would. It waits behind a
conversation mid-turn rather than being skipped, and runs on the first tick after. Bots
make routines themselves, in conversation; a person can switch one off or delete it in
the rail.

A turn's row is inserted empty and written as each block completes, so a daemon that
restarts mid-turn keeps what the bot had said; what a running turn has said so far is
overlaid on `messages.list`, so a load mid-turn shows it; and rows still empty at boot
are swept, since nothing can finish those turns.

## Design notes

**A new bot speaks first.** Creating a bot runs a turn whose prompt is never persisted,
so the transcript opens with the bot introducing itself in its own voice. A bot with a
screen and a description begins the work; a bot with no description says so and asks —
told to begin work it was never given, one invented some.

**Account connectors leak into the subscription path.** Integrations enabled on the
Anthropic account attach server-side to every subscription session, and `settingSources:
[]`, `mcpServers: {}` and `tools: []` were each measured and none of them remove them.
The system prompt therefore states that the bot's description is the source of its
identity and incidental tools are not.

**Provider and model are fixed at creation.** Changing a model mid-thread would
reinterpret an existing conversation under different capabilities, and on a harness
adapter it would strand the warm session that owns that history.

**Messages are block arrays, never strings.** One assistant turn interleaves prose,
screenshots and tool cards, and deltas are addressed by block index, which is what lets a
tool card appear between two paragraphs mid-stream. Tool cards are off by default in the
transcript — a bot that says what it is doing has told a person enough — and every
harness's tool names are normalised to one label and icon, so the same click looks the
same under every provider.

**Sessions stay warm.** A cold turn measured ~2.3s to first token against ~1.3s warm;
the difference is process spawn. The daemon holds one session open per bot per
conversation.

**The transcript is a plain stack, not a lazy one.** A conversation is capped at a
hundred messages, so there is nothing to be lazy about, and laziness was the source of
every scrolling bug this view had: estimated heights, rows never laid out, a re-layout
loop that took a core. With real heights, one rule holds — the reader decides whether the
view rides the end, by scrolling; while it does, arriving content keeps the end in view.

**The client is native SwiftUI, and adapts rather than branches.** `NavigationSplitView`
gives three columns on the Mac, sidebar-over-content on iPad and a push stack on iPhone
from the same views. The first client was Flutter, and its chrome had to be rebuilt by
hand to approximate what the native frameworks give away; the daemon split is what made
the swap cheap, since nothing important lived in the client.
