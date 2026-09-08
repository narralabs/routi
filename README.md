<p align="center"><img src="apple/Routi/Resources/Assets.xcassets/AppIcon.appiconset/mac-256x256@1x.png" width="96" alt="Routi"></p>

# Routi Bot

Bots that live on your Mac, each with its own personality, model and screen. Give one a
job, like watching a market, finding a hotel, or checking a price every morning, and it
opens a browser and does it, on any AI you already pay for: a Claude plan, a ChatGPT
plan, or an API key. Your phone is a window onto the same bots.

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

- **Connectors.** Sign in to Gmail once and every bot you allow can search, read, draft
  and send, as tools rather than through the browser; Google Calendar, Drive, Slack and
  GitHub follow the same way. The sign-in happens on the Mac running the core and the
  token stays in its Keychain, per profile. Gmail first, after launch. Public use of
  the Google ones waits on Google's app verification; until then, a bring-your-own
  OAuth client.
- **Per-bot connectors and screens.** Which connections a bot may use, chosen per bot,
  the way a screen is today.

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
