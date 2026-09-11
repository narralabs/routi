import { mkdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import type { AuthMode } from '@routi/protocol'
import { DEFAULT_PROFILE, type Store } from '../db/store.js'
import { AnthropicApiAdapter } from '../providers/anthropic-api.js'
import { AnthropicSubscriptionAdapter } from '../providers/anthropic-subscription.js'
import { providerKey, type ProviderAdapter } from '../providers/types.js'
import type { DesktopPool } from '../surfaces/pool.js'
import { OpenAiApiAdapter } from '../providers/openai-api.js'
import { COMPATIBLE_PROVIDERS, OpenAiCompatibleAdapter } from '../providers/openai-compatible.js'
import { OpenAiSubscriptionAdapter } from '../providers/openai-subscription.js'
import { XaiSubscriptionAdapter, isolatedGrokHome } from '../providers/xai-subscription.js'
import { ClaudeCli } from './claude-cli.js'
import { CodexCli } from './codex-cli.js'
import { GrokCli } from './grok-cli.js'
import { Credentials } from './credentials.js'

export interface AuthStatus {
  /** True once any provider has a working credential. Gates onboarding. */
  configured: boolean
  mode: AuthMode | null
  subscription: {
    cliInstalled: boolean
    cliVersion: string | null
    loggedIn: boolean
    email?: string
    organization?: string
    subscriptionType?: string
  }
  apiKey: { present: boolean }
  providers: Record<string, ProviderAuth>
}

export interface ProviderAuth {
  configured: boolean
  mode: AuthMode | null
  cli: { installed: boolean; version: string | null; loggedIn: boolean; account?: string }
  apiKey: { present: boolean }
}

const SETTING_MODE = 'authMode'
/**
 * Per-provider mode. The default profile keeps the keys from before profiles existed,
 * so an upgraded core sees its connections where it left them; every other profile's
 * modes carry the profile id.
 */
const settingModeFor = (provider: string, profileId = DEFAULT_PROFILE) =>
  profileId === DEFAULT_PROFILE ? `authMode.${provider}` : `authMode.${profileId}.${provider}`
/** Which harness runs the turn, where a provider offers a choice. */
const settingHarnessFor = (provider: string) => `authHarness.${provider}`

/**
 * Providers whose turns are run by a vendor's own CLI rather than by Routi.
 *
 * They are the ones that can spend a personal plan, and each is its own provider id
 * beside the vendor's direct API — a bot on the agent and a bot on a named API model
 * are different bots, and a person will want both alive rather than having to choose.
 */
const HARNESS_PROVIDERS = new Set(['anthropic-claude', 'openai-codex', 'xai-grok'])

/** Where a harness provider's API key is proven, since the CLI cannot say. */
const VENDOR_API_OF: Record<string, string> = { 'xai-grok': 'xai', 'anthropic-claude': 'anthropic' }

/** The two Anthropic ids: the key-only direct API, and Claude Code beside it. */
const ANTHROPIC_IDS = new Set(['anthropic', 'anthropic-claude'])

/**
 * A profile's own copies of the vendor CLIs, and the directory its logins live in.
 *
 * The default profile is the Mac's own: Claude Code's `~/.claude`, Codex's `~/.codex`,
 * Grok's `~/.grok`, exactly as before profiles existed. Every other profile gets a
 * home of its own under `~/.routi/profiles/<id>`, and each CLI is pointed there —
 * `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME` plus `HOME` — so signing in from
 * that profile signs in only that profile. Measured: Claude Code with an empty
 * `CLAUDE_CONFIG_DIR` reports `loggedIn: false` while the Mac's own login is live.
 */
interface ProfileTools {
  cli: ClaudeCli
  codex: CodexCli
  grok: GrokCli
  /** Where this profile's harness adapters keep their isolated homes. */
  dataDir: string
  /** Claude Code's config dir, for a profile with its own login; unset for the default. */
  claudeConfigDir?: string
  /** True when the profile holds its own CLI logins rather than borrowing the Mac's. */
  ownLogin: boolean
}

/**
 * Owns which credential the daemon uses and swaps the live provider when it changes.
 *
 * The daemon must start with no credentials at all — that is the whole point of
 * onboarding — so the provider map starts empty and is populated here. Adapters are
 * filed by `providerKey(profileId, providerId)`: a profile is a separate set of
 * connections, so two profiles on Claude Code are two adapters on two logins.
 */
export class AuthManager {
  private readonly credentials: Credentials
  private readonly tools = new Map<string, ProfileTools>()

  constructor(
    private readonly store: Store,
    private readonly providers: Map<string, ProviderAdapter>,
    private readonly sessionCwd: string,
    private readonly dataDir: string,
    /** Where this daemon serves tools over HTTP, for harnesses that need a URL. */
    private readonly mcpBaseUrl: string,
    private readonly desktops?: DesktopPool,
  ) {
    this.credentials = new Credentials(dataDir)
  }

  private toolsFor(profileId: string): ProfileTools {
    const found = this.tools.get(profileId)
    if (found) return found
    let made: ProfileTools
    if (profileId === DEFAULT_PROFILE) {
      made = { cli: new ClaudeCli(), codex: new CodexCli(), grok: new GrokCli(), dataDir: this.dataDir, ownLogin: false }
    } else {
      const dir = this.profileDir(profileId)
      const claudeConfigDir = join(dir, 'claude')
      mkdirSync(claudeConfigDir, { recursive: true })
      const { grokHome, home } = isolatedGrokHome(dir, false)
      const codexHome = join(dir, 'codex')
      mkdirSync(codexHome, { recursive: true })
      made = {
        cli: new ClaudeCli({ CLAUDE_CONFIG_DIR: claudeConfigDir }),
        codex: new CodexCli(undefined, { CODEX_HOME: codexHome }),
        grok: new GrokCli(undefined, { GROK_HOME: grokHome, HOME: home }),
        dataDir: dir,
        claudeConfigDir,
        ownLogin: true,
      }
    }
    this.tools.set(profileId, made)
    return made
  }

  private profileDir(profileId: string): string {
    return join(this.dataDir, 'profiles', profileId)
  }

  async status(profileId = DEFAULT_PROFILE): Promise<AuthStatus> {
    const tools = this.toolsFor(profileId)
    const cliStatus = await tools.cli.status()

    const providers: Record<string, ProviderAuth> = {
      anthropic: await this.keyOnlyStatus('anthropic', profileId),
      'anthropic-claude': await this.claudeStatus(cliStatus, profileId),
      openai: await this.openAiStatus('openai', profileId),
      'openai-codex': await this.openAiStatus('openai-codex', profileId),
      'xai-grok': await this.grokStatus(profileId),
      // Everything that speaks OpenAI's chat API: one shape, key only.
      ...Object.fromEntries(
        await Promise.all(
          Object.keys(COMPATIBLE_PROVIDERS).map(
            async (id) => [id, await this.keyOnlyStatus(id, profileId)] as const,
          ),
        ),
      ),
    }

    // The top-level fields predate per-provider status, when Anthropic was the only
    // provider and had one mode. They now describe the Anthropic pair, so a client
    // that still reads them sees the truth: Claude Code's mode if it is connected,
    // else the direct API's.
    const claude = providers['anthropic-claude']!
    const direct = providers['anthropic']!
    return {
      // Set up means one working connection to anything. It used to mean Anthropic,
      // which made a person with a ChatGPT plan and no Claude account unable to get
      // past the first screen of an app that supports them perfectly well.
      configured: Object.values(providers).some((p) => p.configured),
      mode: claude.configured ? claude.mode : direct.configured ? direct.mode : null,
      subscription: {
        cliInstalled: cliStatus.installed,
        cliVersion: cliStatus.installed ? await tools.cli.version() : null,
        loggedIn: cliStatus.loggedIn,
        email: cliStatus.email,
        organization: cliStatus.organization,
        subscriptionType: cliStatus.subscriptionType,
      },
      apiKey: { present: direct.apiKey.present },
      providers,
    }
  }

  private modeOf(provider: string, profileId: string): AuthMode | null {
    return (this.store.getSettings()[settingModeFor(provider, profileId)] as AuthMode | undefined) ?? null
  }

  // --------------------------------------------------------------- Anthropic

  /** Claude Code, which reaches a Claude plan the way Codex reaches ChatGPT. */
  private async claudeStatus(cli: Awaited<ReturnType<ClaudeCli['status']>>, profileId: string): Promise<ProviderAuth> {
    const key = await this.credentials.getApiKey('anthropic-claude', profileId)
    const mode = this.modeOf('anthropic-claude', profileId)
    return {
      configured: (mode === 'subscription' && cli.installed && cli.loggedIn) || (mode === 'api_key' && key !== null),
      mode,
      cli: {
        installed: cli.installed,
        version: cli.installed ? await this.toolsFor(profileId).cli.version() : null,
        loggedIn: cli.loggedIn,
        account: cli.email,
      },
      apiKey: { present: key !== null },
    }
  }

  // ------------------------------------------------------------------ OpenAI

  private async openAiStatus(provider: string, profileId: string): Promise<ProviderAuth> {
    const usesCodex = provider === 'openai-codex'
    const codex = this.toolsFor(profileId).codex
    const cli = usesCodex ? await codex.status() : { installed: false, loggedIn: false }
    const key = await this.credentials.getApiKey(provider, profileId)
    const mode = this.modeOf(provider, profileId)

    return {
      // As with Anthropic, a stored mode only counts while its credential still works.
      configured:
        (mode === 'subscription' && usesCodex && cli.loggedIn) || (mode === 'api_key' && key !== null),
      mode,
      cli: {
        installed: cli.installed,
        version: usesCodex && cli.installed ? await codex.version() : null,
        loggedIn: cli.loggedIn,
        account: 'method' in cli ? cli.method : undefined,
      },
      apiKey: { present: key !== null },
    }
  }

  // --------------------------------------------------------------------- xAI

  /** Grok Build, which reaches a personal Grok account the way Codex reaches ChatGPT. */
  private async grokStatus(profileId: string): Promise<ProviderAuth> {
    const grok = this.toolsFor(profileId).grok
    const cli = await grok.status()
    const key = await this.credentials.getApiKey('xai-grok', profileId)
    const mode = this.modeOf('xai-grok', profileId)

    return {
      configured: (mode === 'subscription' && cli.loggedIn) || (mode === 'api_key' && key !== null),
      mode,
      cli: {
        installed: cli.installed,
        version: cli.installed ? await grok.version() : null,
        loggedIn: cli.loggedIn,
        account: cli.account,
      },
      apiKey: { present: key !== null },
    }
  }

  /** A provider with no account path: an API key or nothing. */
  private async keyOnlyStatus(provider: string, profileId: string): Promise<ProviderAuth> {
    const key = await this.credentials.getApiKey(provider, profileId)
    const mode = this.modeOf(provider, profileId)
    return {
      configured: mode === 'api_key' && key !== null,
      mode,
      cli: { installed: false, version: null, loggedIn: false },
      apiKey: { present: key !== null },
    }
  }

  /** Opens the vendor's browser sign-in for a provider configured in Settings. */
  async providerLogin(provider: string, profileId = DEFAULT_PROFILE): Promise<AuthStatus> {
    const tools = this.toolsFor(profileId)
    if (provider === 'anthropic-claude') {
      const cli = await tools.cli.status()
      if (!cli.installed) {
        throw new Error(
          'Claude Code could not be started on this Mac. It ships with Routi Core, so this is worth reporting.',
        )
      }
      if (!cli.loggedIn) await tools.cli.login()
    } else if (provider === 'openai-codex') {
      const cli = await tools.codex.status()
      if (!cli.installed) {
        throw new Error(
          'Codex could not be started on this Mac. It ships with Routi Core, so this is worth reporting.',
        )
      }
      if (!cli.loggedIn) await tools.codex.login()
    } else if (provider === 'xai-grok') {
      const cli = await tools.grok.status()
      if (!cli.installed) {
        throw new Error(
          'Grok is not installed on this Mac. Install it from grok.com/cli, then try again.',
        )
      }
      if (!cli.loggedIn) await tools.grok.login()
    } else {
      throw new Error(`No account sign-in for provider: ${provider}`)
    }

    this.store.setSettings({ [settingModeFor(provider, profileId)]: 'subscription' })
    await this.applyProvider(provider, profileId)
    return this.status(profileId)
  }

  async providerSetApiKey(provider: string, key: string, profileId = DEFAULT_PROFILE): Promise<AuthStatus & { verified: string }> {
    const compatible = COMPATIBLE_PROVIDERS[provider]
    if (!compatible && !HARNESS_PROVIDERS.has(provider) && provider !== 'openai' && provider !== 'anthropic') {
      throw new Error(`No API key slot for provider: ${provider}`)
    }

    // Proven before it is stored, so a typo fails here rather than on the first message
    // of a bot the user has already built. A harness provider spends the same key its
    // vendor's API takes, so it is checked against that API — the CLI has no cheaper
    // way to say whether a key is any good.
    const checkAgainst = compatible ?? COMPATIBLE_PROVIDERS[VENDOR_API_OF[provider] ?? '']
    const verified = await (ANTHROPIC_IDS.has(provider)
      ? this.validateAnthropicKey(key)
      : checkAgainst
        ? new OpenAiCompatibleAdapter(checkAgainst, key).validate()
        : new OpenAiApiAdapter(key).validate())

    await this.credentials.setApiKey(key, provider, profileId)
    this.store.setSettings({ [settingModeFor(provider, profileId)]: 'api_key' })
    await this.applyProvider(provider, profileId)
    return { ...(await this.status(profileId)), verified }
  }

  /**
   * Disconnect. For a harness provider this signs the vendor's CLI out as well as
   * forgetting Routi's setting: the CLI's session is the connection, and left in
   * place it came straight back on the next Connect with the same account, which
   * made switching accounts impossible from the app. On the default profile that
   * CLI login is the Mac's own, so this signs the Mac out of that CLI too — which is
   * exactly what someone pressing Disconnect on "Grok CLI" is asking for.
   */
  async providerSignOut(provider: string, profileId = DEFAULT_PROFILE): Promise<AuthStatus> {
    if (HARNESS_PROVIDERS.has(provider)) {
      const tools = this.toolsFor(profileId)
      if (provider === 'anthropic-claude') await tools.cli.logout()
      else if (provider === 'openai-codex') await tools.codex.logout()
      else if (provider === 'xai-grok') await tools.grok.logout()
    }
    await this.credentials.clearApiKey(provider, profileId)
    this.store.setSettings({ [settingModeFor(provider, profileId)]: null })
    const key = providerKey(profileId, provider)
    this.providers.get(key)?.dispose()
    this.providers.delete(key)
    return this.status(profileId)
  }

  /**
   * Drops everything a deleted profile connected: its adapters, its stored modes and
   * keys, and the directory holding its CLI logins. The default profile is the Mac's
   * own and is never forgotten this way.
   */
  async forgetProfile(profileId: string): Promise<void> {
    if (profileId === DEFAULT_PROFILE) return
    for (const id of this.allProviderIds()) {
      await this.credentials.clearApiKey(id, profileId)
      this.store.setSettings({ [settingModeFor(id, profileId)]: null })
      const key = providerKey(profileId, id)
      this.providers.get(key)?.dispose()
      this.providers.delete(key)
    }
    this.tools.delete(profileId)
    rmSync(this.profileDir(profileId), { recursive: true, force: true })
  }

  private allProviderIds(): string[] {
    return ['anthropic', 'openai', ...HARNESS_PROVIDERS, ...Object.keys(COMPATIBLE_PROVIDERS)]
  }

  /**
   * Moves a pre-split Codex connection onto its own provider id.
   *
   * Codex used to be a harness flag on `openai`, so a connection made then is stored
   * under the wrong id and its bots point at an adapter that will now be the direct
   * API. Left alone they would fail on their next message with no explanation.
   */
  private async migrateCodexProvider(): Promise<void> {
    const settings = this.store.getSettings()
    const mode = settings[settingModeFor('openai')] as AuthMode | undefined
    const harness = settings[settingHarnessFor('openai')] as string | undefined
    // A subscription was only ever spendable through Codex, so it moves regardless of
    // whether the harness setting was ever written.
    const wasCodex = mode === 'subscription' || harness === 'codex'

    if (wasCodex) {
      this.store.setSettings({
        [settingModeFor('openai-codex')]: mode ?? null,
        [settingModeFor('openai')]: null,
        [settingHarnessFor('openai')]: null,
      })
      if (mode === 'api_key') {
        const key = await this.credentials.getApiKey('openai')
        if (key) {
          await this.credentials.setApiKey(key, 'openai-codex')
          await this.credentials.clearApiKey('openai')
        }
      }
    }

    // Moving the bots is a separate condition, not an else-branch of the above: the
    // credential can already have moved while the bots did not, and a migration that
    // only runs when it sees the old settings would never come back for them.
    const after = this.store.getSettings()
    const codexConfigured = after[settingModeFor('openai-codex')] != null
    const directConfigured = after[settingModeFor('openai')] != null
    if (codexConfigured && !directConfigured) {
      const moved = this.store.moveBotsToProvider('openai', 'openai-codex')
      if (moved > 0) console.log(`moved ${moved} bot(s) onto the Codex provider`)
    }
  }

  /** Installs the adapter matching a provider's stored mode, for one profile. */
  private async applyProvider(provider: string, profileId: string): Promise<void> {
    const key = providerKey(profileId, provider)
    this.providers.get(key)?.dispose()
    this.providers.delete(key)

    const compatible = COMPATIBLE_PROVIDERS[provider]
    if (provider !== 'openai' && provider !== 'anthropic' && !HARNESS_PROVIDERS.has(provider) && !compatible) return
    const mode = this.modeOf(provider, profileId)
    const apiKey = await this.credentials.getApiKey(provider, profileId)
    const tools = this.toolsFor(profileId)

    if (provider === 'anthropic') {
      if (mode === 'api_key' && apiKey) {
        this.providers.set(key, new AnthropicApiAdapter(apiKey))
      }
      return
    }

    if (compatible) {
      if (mode === 'api_key' && apiKey) {
        this.providers.set(key, new OpenAiCompatibleAdapter(compatible, apiKey, this.desktops))
      }
      return
    }

    if (provider === 'openai') {
      if (mode === 'api_key' && apiKey) {
        this.providers.set(key, new OpenAiApiAdapter(apiKey, this.desktops))
      }
      return
    }

    // A harness spends either credential — the CLI holds the account login itself, and
    // a key is handed to it in the environment — so the two modes differ only in
    // whether a key comes along.
    if (mode !== 'api_key' && mode !== 'subscription') return
    if (mode === 'api_key' && !apiKey) return
    if (mode === 'subscription' && !(await this.harnessSignedIn(provider, profileId))) return

    const opts = {
      cwd: this.sessionCwd,
      dataDir: tools.dataDir,
      mcpBaseUrl: this.mcpBaseUrl,
      ownLogin: tools.ownLogin,
      ...(mode === 'api_key' && apiKey ? { apiKey } : {}),
    }
    this.providers.set(
      key,
      provider === 'anthropic-claude'
        ? new AnthropicSubscriptionAdapter({
            cwd: this.sessionCwd,
            mcpBaseUrl: this.mcpBaseUrl,
            ...(opts.apiKey ? { apiKey: opts.apiKey } : {}),
            ...(tools.claudeConfigDir ? { configDir: tools.claudeConfigDir } : {}),
          })
        : provider === 'xai-grok'
          ? new XaiSubscriptionAdapter(opts)
          : new OpenAiSubscriptionAdapter(opts),
    )
  }

  /** Whether the CLI behind a harness provider still has a live account login. */
  private async harnessSignedIn(provider: string, profileId: string): Promise<boolean> {
    const tools = this.toolsFor(profileId)
    const cli = provider === 'anthropic-claude'
      ? await tools.cli.status()
      : provider === 'xai-grok'
        ? await tools.grok.status()
        : await tools.codex.status()
    return cli.installed && cli.loggedIn
  }

  /** A key is proven against the real API before it is stored, and never stored if it fails. */
  private async validateAnthropicKey(key: string): Promise<string> {
    const probe = new AnthropicApiAdapter(key.trim())
    try {
      return await probe.validate()
    } finally {
      probe.dispose()
    }
  }

  /**
   * Moves a pre-split Anthropic connection onto the pair.
   *
   * Anthropic used to be one provider with a mode — `authMode` in settings — under
   * which a plan meant Claude Code and a key meant the direct API. The plan now lives
   * on `anthropic-claude`, so a person can hold both at once, and every bot that ran on
   * the plan follows it there; a key stays on `anthropic`, where it always was.
   */
  private migrateAnthropicProvider(): void {
    const settings = this.store.getSettings()
    const mode = settings[SETTING_MODE] as AuthMode | undefined
    if (mode !== 'subscription' && mode !== 'api_key') return

    if (mode === 'subscription') {
      this.store.setSettings({ [settingModeFor('anthropic-claude')]: 'subscription', [SETTING_MODE]: null })
      const moved = this.store.moveBotsToProvider('anthropic', 'anthropic-claude')
      if (moved > 0) console.log(`moved ${moved} bot(s) onto Claude Code`)
    } else {
      this.store.setSettings({ [settingModeFor('anthropic')]: 'api_key', [SETTING_MODE]: null })
    }
  }

  /** Installs every configured provider of every profile. Called at boot and on change. */
  async applyMode(): Promise<void> {
    // The migrations predate profiles, so they concern the default one only.
    await this.migrateCodexProvider()
    this.migrateAnthropicProvider()
    const profiles = this.store.listProfiles().map((p) => p.id)
    if (!profiles.includes(DEFAULT_PROFILE)) profiles.unshift(DEFAULT_PROFILE)
    for (const profileId of profiles) {
      for (const id of this.allProviderIds()) await this.applyProvider(id, profileId)
    }
  }
}
