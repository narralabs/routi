<p align="center"><img src="apple/Routi/Resources/Assets.xcassets/AppIcon.appiconset/mac-256x256@1x.png" width="96" alt="Routi"></p>

# Routi Bot

Bots that live on your Mac, each with its own personality, model and screen. Give one a
job — watch a market, find a hotel, check a price every morning — and it opens a browser
and does it, on any AI you already pay for: a Claude plan, a ChatGPT plan, or an API
key. Your phone is a window onto the same bots.

## Install

Download **[Routi Bot](https://github.com/narralabs/routi/releases/latest/download/RoutiBot.dmg)**,
open the disk image, drag the app to Applications, open it.

That's it. The app walks you through the rest: it gives you one command to paste into
Terminal that installs Routi Core — the part that keeps your bots and does the work, and
starts at every login — then signs you in with Claude or ChatGPT, or takes an API key.
Claude Code and Codex come with the core; nothing else to install.

Bots that browse for you need a screen: install
[Docker Desktop](https://www.docker.com/products/docker-desktop/) and set it to start at
login. Setup checks for it and offers to build the desktop right there; Settings → Screens
shows its state afterwards. Bots without a screen, and bots set to *This Mac*, don't need
it.

Do this on the Mac that stays on. Give it automatic login, so the Keychain is unlocked
after a reboot, and set it to never sleep. Needs macOS 14 or newer.

## From another Mac, or a phone

Install the app anywhere and point it at the host under Settings → Routi Core. A
Tailscale name works. iPhone and iPad are the same app; they're coming.

## Without the app, or with Homebrew

For a mini with no monitor, or if you'd rather manage the core yourself:

```bash
brew tap narralabs/tap && brew install routi-core && brew services start routi-core
```

or the same command the app shows, which needs nothing on the Mac beforehand:

```bash
curl -fsSL https://raw.githubusercontent.com/narralabs/routi/main/scripts/install.sh | sh
```

Logs are in `~/.routi/logs/routid.log`; with Homebrew, `brew services info routi-core`.

## Developing

```bash
pnpm install && pnpm --filter @routi/protocol build
pnpm --filter routid dev:isolated     # a second core on ~/.routi-dev, port 7172
scripts/dev-app.sh                    # builds the app and opens it on that core
```

`dev:isolated` reloads on every daemon change; run `dev-app.sh` again after an app
change. Or `cd apple && ./bootstrap.sh && open Routi.xcodeproj` and ⌘R in Xcode, with
`-daemonPort 7172` under the scheme's arguments. Either way the core serving your real
bots is never touched. How it's built and released: [`docs/ENGINEERING.md`](docs/ENGINEERING.md).
Adding an AI provider: [`CLAUDE.md`](CLAUDE.md).

## License

Apache-2.0, © 2026 Narra Labs, LLC. Provider marks are [LobeHub's](https://github.com/lobehub/lobe-icons), MIT — see `NOTICE`.
