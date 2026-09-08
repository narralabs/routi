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
  bot (minimal xfwm4 + picom + bottom Plank; no XFCE top panel), Chromium, and a small `act` script that is the only input surface exposed.

Because clients never talk to a vendor, a provider is a daemon-side adapter and nothing
else changes.

### What the app does at launch

The app starts connecting the moment it opens, and the first screen depends on whether
this device has been through setup (`hasCompletedSetup` in its defaults):

- **Never set up** — setup opens at once, before any connection; the window stays empty
  for the few hundred milliseconds a local port takes to answer or refuse, so the
  welcome screen is not shown only to be replaced. *Get Started* then reads the socket:
  a core that answered goes to the credential step (or straight to the finish if it
  already holds one); no core on a Mac asks whether to install one here — the
  one-line installer, watching the port until the core appears — or to point at
  another Mac; a phone can only point.
- **Set up before** — connect quietly. A refused port shows "Routi Core isn't running"
  immediately, with the installer, not after a timer; only a wait that is felt gets a
  spinner. Both no-core screens knock on the port every two seconds so the app moves
  on within a beat of the installer finishing.

Finding a core that already has a credential marks the device set up, so an app
reinstalled on a working Mac lands in the chat. The saved host and port are read at
launch — the client is constructed from them, not from the defaults in its signature.

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

## Reaching the core from a phone or iPad

The core listens on loopback, and on this Mac's Tailscale address when it has one —
checked every half minute, since Tailscale usually comes up after the core at login.
That is the whole remote story on purpose: a Tailscale address is the same at home and
away, and only devices signed into the same tailnet can reach it, so the core needs no
login of its own yet. It is not offered on the LAN, where anyone on the Wi-Fi could
drive the bots. The tools endpoint under `/mcp` answers only loopback even on the
tailnet, because the harnesses that use it run on this Mac. Settings › Routi Core shows
the address to type into the phone; the phone's first run asks for it and points at
Tailscale. The app's Info.plist allows cleartext connections, since `ws://` to a 100.x
address is refused by App Transport Security otherwise — the encryption is WireGuard's,
underneath.

## Updating an installed core from the app

Settings › Routi Core shows "Update Routi Core" when a newer release exists, and the
sidebar says so. The core does the work on itself, because the app may be a phone: it
asks GitHub for the latest release (cached six hours), downloads the tarball, checks it
against the release's sha256, unpacks it to `~/.routi/core.next`, and runs that
release's `scripts/update-core.sh` detached — in its own process group, which is what
lets it outlive the core that started it (measured on a launchd install: the child
survives `bootout`). The script builds in the staging folder, swaps `core` and
`core.prev`, reruns the installer in agent-only mode so a changed plist takes effect,
and waits for `/health` to answer with the new version. If it does not within ninety
seconds, the previous core is swapped back and restarted, and the failed one is left as
`~/.routi/core.failed`. The app watches the socket drop and reconnects: the new version
is success, the old version after a restart is a rollback, and nothing in ten minutes
is reported with the installer one-liner as the way out. A core run from a source
checkout reports that it cannot update itself. The app does not update itself; the
same row links the latest DMG.

## Releasing

A core release is one command: `scripts/release-core.sh 0.1.9` sets the version in
`daemon/package.json` and `protocol/package.json`, commits, tags `v0.1.9` and pushes.
The core reads its version from the package (`daemon/src/version.ts`), so `/health`,
the handshake's `serverVersion` and Settings → Routi Core all report the tag's number.
The workflow then publishes the tarball; attach the DMG and bump the tap as below.

Two artifacts, one script. `scripts/package.sh` builds the app universal and Release,
signs it with a Developer ID Application certificate when the keychain has one, and
notarizes and staples when credentials are stored (`xcrun notarytool store-credentials
routi-notary`); without them it signs to run locally and says so. It also packs the core
as a source tarball with its installer.

The core publishes itself: pushing a `v*` tag runs `.github/workflows/release.yml`, which
attaches `routi-core.tar.gz` and its sha256 to a GitHub release. The app does not — the
certificate lives on one Mac — so a release is:

```bash
scripts/release-core.sh 0.x.y                      # versions, tag, push; core publishes
scripts/package.sh                                 # app, notarized, plus its appcast
gh release upload v0.x.y build/RoutiBot.dmg build/appcast.xml --clobber
```

then the checksum from the release into `packaging/homebrew/routi-core.rb` (url and
sha256 are the two lines that change), copied to `Formula/routi-core.rb` in the
`narralabs/homebrew-tap` repository.

### How each side updates

The core updates itself from the button in Settings › Routi Core (above). The Mac app
updates itself with Sparkle, the way Cursor does: a check on launch and daily, a
download and signature check in the background, then a "Restart to Update" button in
the same pane; ignored, it installs on the next quit. `AppUpdater` in
`apple/Routi/State/` is Sparkle's user driver, so the state shows in our pane rather
than Sparkle's windows. What it reads is `appcast.xml`, uploaded beside the DMG on
every release and reached through the newest release's `latest/download` URL; what it
trusts is the EdDSA signature in that file, made by `generate_appcast` inside
`package.sh` with the private key in the release Mac's login keychain (Sparkle's
`generate_keys` made the pair; `generate_keys -x <file>` exports a backup, which
belongs somewhere safe and not in the repository). Losing that key means every
installed app stops trusting new releases and has to be replaced by hand once. The app
is sandboxed, so Sparkle's installer runs from its XPC service, allowed by the
mach-lookup entitlements. Sparkle orders releases by `CFBundleVersion`, which
`release-core.sh` packs from the version (0.1.30 → 130) so it climbs across minor bumps.
Debug builds never check; `-checkAppUpdate -appcastURL <url>` turns one on against a
feed of your own, which is how the flow is tested. The phone updates through TestFlight.

The iPhone and iPad app goes to TestFlight with `scripts/testflight.sh`, after the
release: it archives for iOS under the Narra Labs team and uploads through the Apple ID
saved in Xcode. Two things it needs and cannot make: that account signed in under Xcode
› Settings › Accounts with no expired account beside it (the export walks every saved
account and stops at the first that is rejected), and an app in App Store Connect with
bundle id `com.narralabs.routi`. The first build of a version needs the export-compliance
answer in App Store Connect before testers see it. `scripts/install.sh` is the curl route and points at
the release's `latest` asset, so it needs nothing per release.

The formula runs the repository's pinned pnpm through `corepack` rather than depending
on Homebrew's, whose major version refused the native build scripts the daemon needs.
`pnpm-workspace.yaml` names those two — `better-sqlite3` and `esbuild` — because pnpm 10
skips dependency build scripts it has not been told to run.

## Authentication

Every vendor is two providers: its agent, which is the only thing that can spend a
personal plan (and takes a key too), and its direct API, which Routi drives. The app
names them by what runs the bot — Claude Code / Anthropic API, Codex / OpenAI API, Grok
CLI / xAI API — and both can be connected at once, so the bot picker offers each.

Nobody installs a vendor CLI to use a plan. Claude Code arrives as a platform package the
Agent SDK depends on (`@anthropic-ai/claude-agent-sdk-darwin-arm64` — the whole package
is the native `claude` binary, pinned to the SDK's version), so it is in `node_modules`
after `pnpm install`; Codex is a dependency versioned with the SDK that drives it.
Sign-in runs on exactly those binaries — `managedClaudePath()` resolves the platform
package the way the SDK does — never on a `claude` the Mac happens to have, which
signed in on one version while turns ran on another. Nothing is fetched at run time;
`~/.local/share/claude/versions` is Anthropic's own installer's folder and plays no
part. Grok is the exception — xAI ships it only through their own installer — and the
app says where to get it.

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

### Profiles

Routi has no accounts of its own, and the General pane used to look as if it did
("Account William, Sign Out") when all it had was a name and a Claude login. What it has
instead is profiles: organisational contexts on one core, each with its own bots and its
own provider connections, so a personal Claude account and a company one can both be
signed in and never share a bot. Onboarding makes exactly one, named after the person;
the menu behind that name (sidebar foot on the Mac, top left on the phone) is where the
rest are — Switch Profile lists them with a New Profile… entry, and Settings sits under
it. A new profile starts with nothing connected and says so in its empty list; its
accounts are connected under Settings › Providers like the first one's were.

The core keeps every profile and no notion of a current one; the app sends `profileId`
with every request that depends on it and remembers its choice per device. Isolation of
a vendor CLI's login is by environment — `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`
plus `HOME` — under `~/.routi/profiles/<id>/`; the first profile keeps the Mac's own
logins so an upgraded core changes nothing. `pnpm --filter routid probe` proves the
split: the second profile it makes starts signed out of Claude Code while the first is
signed in, sees none of the first's bots, and cannot be deleted until its own bot is.

## The desktop

One container, shared by every bot, with a display per bot. The value of a desktop is
its accumulated state — a signed-in site, a browser profile, downloaded files — and a
container per bot would discard that on every bot you create. The daemon starts it on
demand and leaves it running across its own restarts, since losing browser sessions to a
restart would defeat the point.

A screen is Xvfb, xfwm4, picom and a bottom Plank dock with Chrome, the file manager
and a terminal on it — no panel, no session, a dark canvas. It was a full XFCE session
until PR #1, whose author was Grok Bot's own agent; the bar and its clock were noise in
every screenshot a bot read. The bot's browser starts maximised with the window class
the dock launcher is matched on, so it fills the screen above the dock and sits on the
Chrome icon. The image is built by the core from `containers/desktop` the first time
a screen is needed, and labelled with a hash of those files; a core update that
changes them finds the label wrong and rebuilds before recreating the machine, so an
installed core follows the desktop it ships with rather than keeping the first one it
ever built. Screens on the old machine are lost in that swap and remade on demand.

**Bots drive it themselves.** A bot with a screen gets the desktop as tools — `read_page`
and `click_ref` for the page's accessibility tree, `screenshot` and `click` for pixels,
`type_text`, `press_key`, `scroll`, and `ask_to_take_over` for the moments only a person
can do. The structured path is Chrome DevTools Protocol over the container's debugging
port; the pixel path is the X framebuffer. The bot's standing instruction is to prefer the
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

### When Docker is not there

Three states, told apart because each has a different fix: no `docker` CLI (install
Docker Desktop), a CLI with no engine (start it), an engine with no image (build it —
`desktop.prepare`, minutes once). Setup asks the question after the credential and
offers the fix; Settings → Screens shows the same three rows afterwards and which bots
have a screen up.

If Docker is quit while bots run: a bot's next screen tool gets "your screen is
unavailable: Docker is not running…, tell the person and stop using screen tools", the
bot's screen reports `unavailable` with that reason, and the panel shows it with a
button to the Screens pane. `Desktop.status()` re-confirms a remembered screen against
the machine, so one that vanished reads as stopped rather than running until the next
screenshot fails. The container runs with `--restart unless-stopped`, so a Docker
restart brings the machine back on its own; screens inside it are re-made on demand.

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

## Memory, and what survives a restart

A bot on a harness keeps its thread in the harness: Claude Code, Codex and Grok each
hold a session per bot-in-conversation and compact it themselves. The core keeps each
session's id and resumes it after a restart; when the runtime no longer has it, the
transcript from SQLite leads the next turn instead, so the bot never starts blank in a
conversation the person can still scroll. A bot on a plain API has no session and is
sent the transcript every turn.

Memory is the layer above both: short notes the bot writes for itself during ordinary
turns — a decision, a preference, a deadline, where something was found — read back to
it at the top of every turn on whatever runs it. They belong to the bot, not the
conversation, so they are what carries into a routine's run, across a restart, and
across a change of provider. Facts about the person — a name, a timezone — are a second,
shared scope that every bot reads, kept in Settings rather than in any bot's rail. The
rail lists a bot's notes and opens one on click to correct or remove; an edit reaches a
warm bot with its next message. The runtimes' own memory features are not used: they
are per home directory, which would make every bot share one, and they are exactly the
operator configuration the isolation work keeps out.

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

**The provider is fixed at creation; model and effort are not.** Model ids do not cross
providers and a bot's history lives in one harness, so the provider stays. The model and
effort switch mid-conversation the way Claude Code's own /model does: every adapter
applies them per turn (Codex takes them on `turn/start`, not `thread/start`), so a bot
keeps its session — a harness bot's session is its memory of the chat — and answers the
next message on the new model. Only a changed description drops the warm sessions,
since that is a stale system prompt. Codex's models come from `model/list` at run time,
not a hardcoded pair; `default` names the plan's current default.

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
