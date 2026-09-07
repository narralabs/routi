<p align="center"><img src="apple/Routi/Resources/Assets.xcassets/AppIcon.appiconset/mac-256x256@1x.png" width="96" alt="Routi"></p>

# Routi Bot

Bots that live on your Mac, each with its own personality, model and screen. Give one a
job — watch a market, find a hotel, check a price every morning — and it opens a browser
and does it, on any AI you already pay for: a Claude plan, a ChatGPT plan, or an API
key. Your phone is a window onto the same bots.

## Install

Download **[Routi Bot](https://github.com/narralabs/routi/releases/latest/download/RoutiBot.dmg)**,
open the disk image, drag the app to Applications, open it.

Setup does the rest, in three screens: one command to paste into Terminal that installs
Routi Core — the part that keeps your bots and does the work, and starts at every login;
a sign-in with Claude or ChatGPT, or an API key; and, if you want bots that browse, the
desktop they browse in. Claude Code and Codex come with the core.

The desktop is a Linux machine in [Docker Desktop](https://www.docker.com/products/docker-desktop/),
one screen per bot, kept apart from your own. Install Docker and set it to start at login;
setup checks for it and builds the desktop right there, and Settings → Screens shows its
state afterwards. Bots without a screen, and bots set to *This Mac*, don't need it.

Do this on the Mac that stays on. Give it automatic login, so the Keychain is unlocked
after a reboot, and set it to never sleep. Needs macOS 14 or newer.

## Update

The core updates with the same command that installed it — it fetches the latest release
and restarts:

```bash
curl -fsSL https://raw.githubusercontent.com/narralabs/routi/main/scripts/install.sh | sh
```

The app updates by downloading the disk image again. Settings → Routi Core shows which
version of each you have.

## From another Mac, or a phone

Install the app anywhere and point it at the host under Settings → Routi Core. A
Tailscale name works. iPhone and iPad are the same app; they're coming.

## Without the app, or with Homebrew

For a mini with no monitor, or if you'd rather manage the core yourself:

```bash
brew tap narralabs/tap && brew install routi-core && brew services start routi-core
```

or the install command above, which needs nothing on the Mac beforehand.

## If something's off

- `curl http://127.0.0.1:7171/health` on the host says whether the core is up, and which version.
- Logs: `~/.routi/logs/routid.log`; with Homebrew, `brew services info routi-core`.
- A bot that says its screen is unavailable: Settings → Screens names which of Docker,
  the desktop image, or the machine is the problem, with the button that fixes it.
- Sign-in trouble: Settings → the provider's pane says what is connected and how.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/narralabs/routi/main/scripts/uninstall.sh | sh
```

Stops and removes the core, its login agent, the desktop machine and image in Docker,
and the API keys Routi stored in the Keychain. Your bots and conversations stay in
`~/.routi`, so reinstalling brings them back. To remove those and the app as well:

```bash
curl -fsSL https://raw.githubusercontent.com/narralabs/routi/main/scripts/uninstall.sh | sh -s -- --purge
```

Add `--dry-run` to either to see what would go without touching anything. Docker Desktop
itself, and the sign-ins that belong to Claude Code, Codex and Grok, are left alone —
they were yours before Routi.

## Roadmap

- **Plugins.** Give bots Gmail, Google Calendar, Slack, GitHub and the rest, through each
  vendor's own MCP server and sign-in — one connection, every bot. The Google ones wait
  on Google's app verification.
- **iPhone and iPad.** The same app, as a window onto the bots on your Mac.
- **Per-bot plugins and screens.** Which connections a bot may use, chosen per bot.

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
