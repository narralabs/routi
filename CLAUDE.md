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
- `containers/desktop/` — the shared Linux desktop the bots drive.

Verify with `pnpm --filter routid typecheck`, `pnpm --filter routid probe`, and
`cd apple && xcodebuild -scheme Routi -destination 'platform=macOS' build`.

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
| `apple/Routi/Views/Settings/Providers.swift` | The roster: id, display name, brand mark, tint, whether it is wired up. `ProviderConnectPane` is the shared "account or API key" pane; Anthropic has its own because it is also the onboarding credential. |

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
(`openai` / `openai-codex`, `xai` / `xai-grok`) so both can be connected at once.
`HARNESS_PROVIDERS` in `manager.ts` is the list.

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
