<p align="center"><img src="apple/Routi/Resources/Assets.xcassets/AppIcon.appiconset/mac-256x256@1x.png" width="96" alt="Routi"></p>

# Routi Bot

Bots that live on your Mac, each with its own personality, model and screen. Give one a
job — watch a market, find a hotel, check a price every morning — and it opens a
browser and does it, on any AI you already pay for: a Claude plan, a ChatGPT plan, or an
API key. Your phone is a window onto the same bots.

## Install

Routi is two parts: **Routi Core**, which keeps your bots and does the work, and the
**app**, which is the window onto it. Both go on the Mac that stays on.

**1. The core**

```bash
brew tap narralabs/tap && brew install routi-core
brew services start routi-core        # runs now, and at every login
```

No Homebrew? `curl -fsSL https://raw.githubusercontent.com/narralabs/routi/main/scripts/install.sh | sh`
does the same, including Node.

**2. The app**

Download [Routi.zip](https://github.com/narralabs/routi/releases/latest/download/Routi.zip),
unzip, drag to Applications, open. It's notarized — it just opens. It finds the core on
this Mac and walks you through signing in with Claude or ChatGPT, or pasting an API key.
Claude Code and Codex come with the core; nothing else to install.

**3. Screens (optional)**

Bots that browse for you need a desktop. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/),
set it to start at login, then build the shared desktop once:

```bash
docker build -t routi-desktop https://github.com/narralabs/routi.git#main:containers/desktop
```

Bots without a screen, and bots set to *This Mac*, need no Docker.

**On the Mac that hosts:** turn on automatic login, so the Keychain is unlocked for the
core after a reboot, and set it to never sleep. Logs: `brew services info routi-core`
or `~/.routi/logs/routid.log`.

## Using it from elsewhere

Install the app on any other Mac and point it at the host under Settings → Routi Core.
A Tailscale name works. iPhone and iPad are the same app; they're coming.

Needs macOS 14 or newer. The app is universal.

## Developing

```bash
pnpm install && pnpm --filter @routi/protocol build
pnpm --filter routid dev:isolated     # a second core on ~/.routi-dev, port 7172
cd apple && ./bootstrap.sh && open Routi.xcodeproj
```

Point the Debug app at port 7172 under Settings → Routi Core, and the core serving your
real bots is never touched. How it's built, why it's shaped this way, and how a release
is cut: [`docs/ENGINEERING.md`](docs/ENGINEERING.md). Adding an AI provider: [`CLAUDE.md`](CLAUDE.md).

## License

Apache-2.0, © 2026 Narra Labs, LLC. Provider marks are [LobeHub's](https://github.com/lobehub/lobe-icons), MIT — see `NOTICE`.
