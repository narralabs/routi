# Routi Bot — working notes

Read `README.md` for what the product is and `docs/ENGINEERING.md` for how it is built
and released. This file is the map of the parts that are expensive to rediscover.

## Layout

- `daemon/` — `routid`, Node + TypeScript. Owns credentials, the database, the bots, the
  containers. One WebSocket API on `127.0.0.1:7171`, data in `~/.routi`.
- `protocol/` — zod schemas for the wire format. `apple/Routi/Models/` is the
  hand-written Swift mirror; the two change in the same commit.
- `apple/` — SwiftUI, one target for Mac/iPad/iPhone. Knows no provider names beyond a
  display roster.
- `containers/desktop/` — the shared Linux desktop the bots drive: one machine, an X
  display per bot, each a bare xfwm4 + Plank dock (no XFCE panel since PR #1). The core
  builds the image and labels it with a hash of these files (`sourceStamp` in
  `surfaces/desktop.ts`); change anything here and every core rebuilds on its next
  screen request, losing the running screens once.

Verify with `pnpm --filter routid typecheck`, `pnpm --filter routid probe`, and
`cd apple && xcodebuild -scheme Routi -destination 'platform=macOS' build`. Anything
that touches the phone's desktop is proven by its UI tests, with a core running on
7171 and an iPhone simulator: `cd apple && ./bootstrap.sh --ios && xcodebuild test
-scheme Routi -destination 'id=<simulator>' -only-testing:RoutiUITests
CODE_SIGNING_ALLOWED=NO`. A screenshot shows a view exists; only the tests show it
works. Run them with nothing else building: under load XCUITest's own timing goes,
and a test that passes alone in ten seconds can hang for a thousand.

## How providers work

**A provider is a daemon-side adapter and nothing else.** Clients never talk to a
vendor; they name a provider id in a bot and render whatever blocks come back. Adding
one needs no protocol change and no app release — `bot.provider` is a plain string.

### The pieces

| File | What it owns |
| --- | --- |
| `daemon/src/providers/types.ts` | `ProviderAdapter` — the whole contract: `listModels`, `accountInfo`, `stream`, `release`, `dispose`, plus `supportsSurface`. `sessionKey(req)` is `conversationId:botId`, because a room has several bots and they must not share one warm session. |
| `daemon/src/auth/manager.ts` | Which credential each provider uses, and swapping the live adapter when that changes. `applyMode()` runs at boot and after every change; `applyProvider(id)` installs one. Modes are stored per provider as the setting `authMode.<id>`. |
| `daemon/src/auth/credentials.ts` | API keys in the login Keychain, one account name per provider id. A provider with no entry in `ACCOUNTS` cannot store a key. |
| `daemon/src/server/mcp-http.ts` | The desktop verbs as an MCP server over HTTP, at `/mcp/:botId/:conversationId`. This is how a harness we do not control gets Routi's tools. |
| `apple/Routi/Views/Settings/Providers.swift` | The roster: id, display name, one-line summary (who runs the bot, what pays), brand mark, tint, whether it is wired up. `ProviderConnectPane` is the one "account or API key" pane, for every provider. |

### The three shapes an adapter comes in

1. **Vendor SDK, Routi runs the loop** — `anthropic-api.ts`, `openai-api.ts`.
   Routi owns the tool loop, so bots get the desktop directly.
2. **OpenAI-compatible chat completions** — `openai-compatible.ts`. One class,
   providers as configuration in `COMPATIBLE_PROVIDERS`: a base URL, where to get a
   key, optional known-model names. DeepSeek and xAI live here. **Adding one of these
   is three lines plus a Keychain slot.**
3. **A vendor CLI runs the turn** — `anthropic-subscription.ts` (Claude Code SDK),
   `openai-subscription.ts` + `codex-app-server.ts` (Codex JSON-RPC),
   `xai-subscription.ts` + `grok-acp.ts` (Grok over ACP). This is the only way to spend
   a *personal plan* rather than metered API credit, and the reason each of these
   exists. Routi never sees the token: the CLI holds it, and `daemon/src/auth/*-cli.ts`
   only asks whether one is live and shells out to the vendor's own sign-in.

A harness provider is its own provider id beside the vendor's direct API
(`anthropic` / `anthropic-claude`, `openai` / `openai-codex`, `xai` / `xai-grok`) so both
can be connected at once — a plan for the everyday bots, a key for one that needs a named
model. `HARNESS_PROVIDERS` in `manager.ts` is the list. The app names entries by what runs
the bot ("Claude Code", "Anthropic API"), never by vendor alone. Anthropic was one id
with a mode until 0.1.11; `migrateAnthropicProvider()` moves a plan and its bots onto
`anthropic-claude` at boot, and the old `auth.loginWithClaude` / `auth.setApiKey` /
`auth.signOut` RPCs remain as aliases onto the pair.

### Profiles

A profile is an organisational context — "William (Personal)", "William (Narra Labs)"
— with its own bots and its own provider connections on one core. There are no Routi
accounts; a profile is not a login, it is a partition. `profiles` table, `bots.profile_id`,
`profiles.*` RPCs; `bots.list` / `bots.create` / `auth.*` / `models.list` / `account.info`
take a `profileId` that defaults to `default`, so an older client keeps working on the
first profile. The app remembers which profile it shows in defaults (`currentProfile`),
per device, and asks for everything with it; the core has no notion of "current".

The first profile has the fixed id `default` and is what the world before profiles
became: `Store.ensureDefaultProfile()` runs at boot before `applyMode()`, names it from
the old `userName` setting (else "Personal") and takes every bot with no profile.
Onboarding names it ("Name your profile"); the sidebar name, the initials and the
greeting are its name, the greeting minus any label in brackets.

Connections are per profile because that is the point — a work Claude account beside a
personal one. Adapters are filed under `providerKey(profileId, providerId)`; settings
keys are `authMode.<provider>` for the default profile (unchanged) and
`authMode.<profileId>.<provider>` for the rest; Keychain accounts get `.<profileId>`
appended the same way. A harness CLI is pointed at the profile's own home under
`~/.routi/profiles/<id>/` — `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME` + `HOME` —
so signing in there signs in only there (measured: an empty `CLAUDE_CONFIG_DIR` reports
`loggedIn: false` while the Mac's own login is live). The default profile keeps
borrowing the Mac's own CLI logins, as before. Deleting a profile refuses while it has
bots, refuses `default` always, and otherwise drops its adapters, settings, keys and
home directory. Memory's `user` scope is deliberately not per profile: it is about the
person, and the person is the same in both.

### What a bot remembers, and where

Three layers, and the distinction matters when something "forgets":

- **The transcript** is SQLite (`messages`). The API-shaped adapters replay the last 200
  rows every turn and nothing compacts them. The harness adapters ignore it while a warm
  session exists — the runtime holds the thread and compacts it as it likes.
- **The warm session** is per `conversationId:botId`, and its id is kept in
  `provider_sessions` after every turn. After a restart the adapter resumes it
  (`ChatRequest.resumeSessionId`); a resume of a dead id fails before the bot has spoken
  (measured: result subtype `error_during_execution`, "No conversation found"), so the
  adapter rebuilds blank and leads the turn with `replayTranscript()` from
  `providers/replay.ts`. Codex and Grok get the replay only; their own resume verbs are
  not driven yet.
- **Memory** is Routi's, not the runtime's: `memories` rows, written by the bot with
  `remember` / `forget` / `recall` (`sessions/memory-tools.ts`), rendered into the
  standing prompt by `policy.ts`, over `memory.*` RPCs. Two scopes: `bot` (its own,
  listed in the rail, cascade-deleted with it) and `user` (about the person, no
  `bot_id`, read by every bot, shown under Settings › General › About you; a bot's own
  note wins a conflict). Notes are the bot's to write: the app only lists them and
  opens one in `NoteEditor` on click; the single place a person adds one is About you.
  The prompt shows the newest that fit; `recall` searches the rest. It is deliberately not
  Claude Code's or Grok's own memory feature: those are per home directory, so every bot
  would share one file, and they are the operator's config that `settingSources: []` /
  `GROK_HOME` exist to keep out. A person's edit reaches a warm session as a prefix on
  the bot's next turn (`SessionManager.memoryEdited`), since its prompt is already built.

Routi's tool server is mounted for every bot; `ToolOptions.screen` decides whether the
nine desktop verbs are in it. Notes and routines are answered in `runDesktopTool`
before the desktop is touched, so saving one never starts a container.
`pnpm --filter routid spike:memory` proves all three layers against the real CLI.

### The desktop on a phone

`apple/Routi/Views/MobileScreen.swift` is the whole thing: a UIKit gesture layer over
the fitted frame, a trackpad mode that moves the desktop's pointer relatively, a
keyboard bar with the keys a phone lacks, and the clipboard both ways. The touch model,
arrived at by testing on a hand rather than a spec, and matched to Grok Bot's app:
relative pointing by default. The pointer starts in the middle; one finger anywhere on
the pane, black margins included, moves it by its travel; a tap clicks where the
pointer is. "Tap where you touch" is the other mode, in the ··· menu. Press-and-hold
is decided on release (still = right-click, moved = drag); two fingers scroll, a
two-finger tap right-clicks, pinch zooms. No double-tap recognizer: it delayed every
tap. Frames are decoded once on arrival, never in the body. `RoutiUITests` is the
proof; run it for any change here. A drag is the `drag` input kind, run as one xdotool chain in
`desktop.ts` so the container image did not change. The Mac keeps `ScreenWindow`.
Debug builds open straight onto it with `-showScreen`.

### Where the core listens

Loopback, plus the Tailscale address when present (`daemon/src/server/tailscale.ts`,
bound by `RoutiServer.listenAlso` from `index.ts` on a 30s check). Never the LAN: there
is no client auth yet. `/mcp` is loopback-only on every listener. `core.addresses` is
what Settings shows a phone's owner.

### Updating the core from the app

`daemon/src/update.ts` + `scripts/update-core.sh`. The core fetches, verifies and unpacks
the release, then hands over to the *new* release's script, detached; the script
builds in `~/.routi/core.next`, swaps, restarts the agent, and rolls back on a failed
health check. `Updater.installed` is false for a checkout, so the dev core never tries.
The installer's `ROUTI_INSTALL_NO_AGENT` / `ROUTI_INSTALL_AGENT_ONLY` are the updater's
two halves. See ENGINEERING.md for the full sequence and what was measured.

### Two things every harness adapter has had to solve

**Isolation.** These CLIs read the operator's personal config — MCP servers, skills,
plugins — and hand it to every bot. A bot then introduces itself as the operator's
toolbox. Fixes, measured rather than assumed: `CODEX_HOME` for Codex; `GROK_HOME`
**and** `HOME` for Grok, because Grok also reads `~/.claude.json` and `~/.claude/` in
Claude Code's format and `GROK_HOME` does not cover those. The vendor's `auth.json` is
symlinked into the isolated home so the login still counts and Routi never copies a
credential.

**Approvals.** Every one of these agents asks before running a tool it did not bring
itself, and the answer comes back over the same connection. A client that cannot answer
leaves a bot standing next to a screen it has been told not to touch. Both transports
answer in the same place: approve Routi's own tools (the user granted that by giving the
bot a screen), refuse everything else — a bot here is not meant to run commands on the
Mac hosting the core. Never `--always-approve` / `--dangerously-*`: that says yes to the
shell too.

### Grok specifics (verified against grok 1.0.13)

- Transport is `grok agent stdio`, speaking ACP: `initialize` → `session/new` →
  `session/set_model` → `session/prompt`, with `session/update` notifications carrying
  `agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`.
  `session/prompt` itself resolves with the stop reason and usage.
- MCP over HTTP is accepted in `session/new` (`mcpCapabilities.http`), which is how the
  desktop reaches it. Grok hides MCP tools behind its own `search_tool` / `use_tool`, so
  the call that arrives is `use_tool` with `rawInput.tool_name = "routi__screenshot"`.
- Reasoning effort cannot be set. `session/set_mode`, `_meta` hints on `session/new`
  and `session/prompt`, and the CLI's own `--reasoning-effort` were each measured and
  each left the session on the model's default.
- The binary installs to `~/.grok/bin/grok`, which is not on a launchd daemon's PATH —
  `grokBinary()` looks there before falling back to PATH.
- `grok models` is the auth check: `auth.json` keeps stale entries, so file presence
  proves only that somebody once signed in.

### Checklist for the next provider

1. Adapter in `daemon/src/providers/`, plus a `*-cli.ts` in `daemon/src/auth/` if it
   has an account login.
2. Keychain slot in `credentials.ts`.
3. `manager.ts`: status, `providerLogin` if it has an account path, `applyProvider`.
4. `Providers.swift`: roster entry, brand mark asset, and any copy the shared pane
   needs to switch on.
5. A spike script (`daemon/scripts/spike-*.ts`, wired into `daemon/package.json`) that
   drives one real turn with a fake screen. `pnpm --filter routid spike:grok` is the
   model for this.
