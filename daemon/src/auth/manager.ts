import type { AuthMode } from '@routi/protocol'
import type { Store } from '../db/store.js'
import { AnthropicApiAdapter } from '../providers/anthropic-api.js'
import { AnthropicSubscriptionAdapter } from '../providers/anthropic-subscription.js'
import type { ProviderAdapter } from '../providers/types.js'
import type { DesktopPool } from '../surfaces/pool.js'
import { OpenAiApiAdapter } from '../providers/openai-api.js'
import { COMPATIBLE_PROVIDERS, OpenAiCompatibleAdapter } from '../providers/openai-compatible.js'
import { OpenAiSubscriptionAdapter } from '../providers/openai-subscription.js'
import { XaiSubscriptionAdapter } from '../providers/xai-subscription.js'
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
/** Per-provider mode, for providers configured after onboarding. */
const settingModeFor = (provider: string) => `authMode.${provider}`
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
 * Owns which credential the daemon uses and swaps the live provider when it changes.
 *
 * The daemon must start with no credentials at all — that is the whole point of
 * onboarding — so the provider map starts empty and is populated here.
 */
export class AuthManager {
  private readonly cli = new ClaudeCli()
  private readonly codex = new CodexCli()
  private readonly grok = new GrokCli()
  private readonly credentials: Credentials

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

  async status(): Promise<AuthStatus> {
    const cliStatus = await this.cli.status()

    const providers: Record<string, ProviderAuth> = {
      anthropic: await this.keyOnlyStatus('anthropic'),
      'anthropic-claude': await this.claudeStatus(cliStatus),
      openai: await this.openAiStatus('openai'),
      'openai-codex': await this.openAiStatus('openai-codex'),
      'xai-grok': await this.grokStatus(),
      // Everything that speaks OpenAI's chat API: one shape, key only.
      ...Object.fromEntries(
        await Promise.all(
          Object.keys(COMPATIBLE_PROVIDERS).map(
            async (id) => [id, await this.keyOnlyStatus(id)] as const,
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
        cliVersion: cliStatus.installed ? await this.cli.version() : null,
        loggedIn: cliStatus.loggedIn,
        email: cliStatus.email,
        organization: cliStatus.organization,
        subscriptionType: cliStatus.subscriptionType,
      },
      apiKey: { present: direct.apiKey.present },
      providers,
    }
  }

  // --------------------------------------------------------------- Anthropic

  /** Claude Code, which reaches a Claude plan the way Codex reaches ChatGPT. */
  private async claudeStatus(cli: Awaited<ReturnType<ClaudeCli['status']>>): Promise<ProviderAuth> {
    const key = await this.credentials.getApiKey('anthropic-claude')
    const mode = (this.store.getSettings()[settingModeFor('anthropic-claude')] as AuthMode | undefined) ?? null
    return {
      configured: (mode === 'subscription' && cli.installed && cli.loggedIn) || (mode === 'api_key' && key !== null),
      mode,
      cli: {
        installed: cli.installed,
        version: cli.installed ? await this.cli.version() : null,
        loggedIn: cli.loggedIn,
        account: cli.email,
      },
      apiKey: { present: key !== null },
    }
  }

  // ------------------------------------------------------------------ OpenAI

  private async openAiStatus(provider: string): Promise<ProviderAuth> {
    const usesCodex = provider === 'openai-codex'
    const cli = usesCodex ? await this.codex.status() : { installed: false, loggedIn: false }
    const key = await this.credentials.getApiKey(provider)
    const mode = (this.store.getSettings()[settingModeFor(provider)] as AuthMode | undefined) ?? null

    return {
      // As with Anthropic, a stored mode only counts while its credential still works.
      configured:
        (mode === 'subscription' && usesCodex && cli.loggedIn) || (mode === 'api_key' && key !== null),
      mode,
      cli: {
        installed: cli.installed,
        version: usesCodex && cli.installed ? await this.codex.version() : null,
        loggedIn: cli.loggedIn,
        account: 'method' in cli ? cli.method : undefined,
      },
      apiKey: { present: key !== null },
    }
  }

  // --------------------------------------------------------------------- xAI

  /** Grok Build, which reaches a personal Grok account the way Codex reaches ChatGPT. */
  private async grokStatus(): Promise<ProviderAuth> {
    const cli = await this.grok.status()
    const key = await this.credentials.getApiKey('xai-grok')
    const mode = (this.store.getSettings()[settingModeFor('xai-grok')] as AuthMode | undefined) ?? null

    return {
      configured: (mode === 'subscription' && cli.loggedIn) || (mode === 'api_key' && key !== null),
      mode,
      cli: {
        installed: cli.installed,
        version: cli.installed ? await this.grok.version() : null,
        loggedIn: cli.loggedIn,
        account: cli.account,
      },
      apiKey: { present: key !== null },
    }
  }

  /** A provider with no account path: an API key or nothing. */
  private async keyOnlyStatus(provider: string): Promise<ProviderAuth> {
    const key = await this.credentials.getApiKey(provider)
    const mode = (this.store.getSettings()[settingModeFor(provider)] as AuthMode | undefined) ?? null
    return {
      configured: mode === 'api_key' && key !== null,
      mode,
      cli: { installed: false, version: null, loggedIn: false },
      apiKey: { present: key !== null },
    }
  }

  /** Opens the vendor's browser sign-in for a provider configured in Settings. */
  async providerLogin(provider: string): Promise<AuthStatus> {
    if (provider === 'anthropic-claude') {
      const cli = await this.cli.status()
      if (!cli.installed) {
        throw new Error(
          'Claude Code could not be started on this Mac. It ships with Routi Core, so this is worth reporting.',
        )
      }
      if (!cli.loggedIn) await this.cli.login()
    } else if (provider === 'openai-codex') {
      const cli = await this.codex.status()
      if (!cli.installed) {
        throw new Error(
          'Codex could not be started on this Mac. It ships with Routi Core, so this is worth reporting.',
        )
      }
      if (!cli.loggedIn) await this.codex.login()
    } else if (provider === 'xai-grok') {
      const cli = await this.grok.status()
      if (!cli.installed) {
        throw new Error(
          'Grok is not installed on this Mac. Install it from grok.com/cli, then try again.',
        )
      }
      if (!cli.loggedIn) await this.grok.login()
    } else {
      throw new Error(`No account sign-in for provider: ${provider}`)
    }

    this.store.setSettings({ [settingModeFor(provider)]: 'subscription' })
    await this.applyProvider(provider)
    return this.status()
  }

  async providerSetApiKey(provider: string, key: string): Promise<AuthStatus & { verified: string }> {
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

    await this.credentials.setApiKey(key, provider)
    this.store.setSettings({ [settingModeFor(provider)]: 'api_key' })
    await this.applyProvider(provider)
    return { ...(await this.status()), verified }
  }

  async providerSignOut(provider: string): Promise<AuthStatus> {
    await this.credentials.clearApiKey(provider)
    this.store.setSettings({ [settingModeFor(provider)]: null })
    this.providers.get(provider)?.dispose()
    this.providers.delete(provider)
    return this.status()
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

  /** Installs the adapter matching a provider's stored mode. */
  private async applyProvider(provider: string): Promise<void> {
    this.providers.get(provider)?.dispose()
    this.providers.delete(provider)

    const compatible = COMPATIBLE_PROVIDERS[provider]
    if (provider !== 'openai' && provider !== 'anthropic' && !HARNESS_PROVIDERS.has(provider) && !compatible) return
    const mode = this.store.getSettings()[settingModeFor(provider)] as AuthMode | undefined
    const key = await this.credentials.getApiKey(provider)

    if (provider === 'anthropic') {
      if (mode === 'api_key' && key) {
        this.providers.set('anthropic', new AnthropicApiAdapter(key))
      }
      return
    }

    if (compatible) {
      if (mode === 'api_key' && key) {
        this.providers.set(provider, new OpenAiCompatibleAdapter(compatible, key, this.desktops))
      }
      return
    }

    if (provider === 'openai') {
      if (mode === 'api_key' && key) {
        this.providers.set('openai', new OpenAiApiAdapter(key, this.desktops))
      }
      return
    }

    // A harness spends either credential — the CLI holds the account login itself, and
    // a key is handed to it in the environment — so the two modes differ only in
    // whether a key comes along.
    if (mode !== 'api_key' && mode !== 'subscription') return
    if (mode === 'api_key' && !key) return
    if (mode === 'subscription' && !(await this.harnessSignedIn(provider))) return

    const opts = {
      cwd: this.sessionCwd,
      dataDir: this.dataDir,
      mcpBaseUrl: this.mcpBaseUrl,
      ...(mode === 'api_key' && key ? { apiKey: key } : {}),
    }
    this.providers.set(
      provider,
      provider === 'anthropic-claude'
        ? new AnthropicSubscriptionAdapter({ cwd: this.sessionCwd, desktops: this.desktops, ...(opts.apiKey ? { apiKey: opts.apiKey } : {}) })
        : provider === 'xai-grok'
          ? new XaiSubscriptionAdapter(opts)
          : new OpenAiSubscriptionAdapter(opts),
    )
  }

  /** Whether the CLI behind a harness provider still has a live account login. */
  private async harnessSignedIn(provider: string): Promise<boolean> {
    const cli = provider === 'anthropic-claude'
      ? await this.cli.status()
      : provider === 'xai-grok'
        ? await this.grok.status()
        : await this.codex.status()
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

  /** The onboarding sign-in: Claude Code, by its provider id. Kept for older clients. */
  async loginWithClaude(): Promise<AuthStatus> {
    return this.providerLogin('anthropic-claude')
  }

  /** The onboarding key: the direct API, by its provider id. Kept for older clients. */
  async setApiKey(key: string): Promise<AuthStatus> {
    const { verified: _verified, ...status } = await this.providerSetApiKey('anthropic', key)
    return status
  }

  /** Disconnects both Anthropic ids — what "sign out of Claude" meant when it was one. */
  async signOut(): Promise<AuthStatus> {
    for (const id of ANTHROPIC_IDS) await this.providerSignOut(id)
    return this.status()
  }

  /** Installs every configured provider. Called at boot and on change. */
  async applyMode(): Promise<void> {
    await this.migrateCodexProvider()
    this.migrateAnthropicProvider()
    await this.applyProvider('anthropic')
    await this.applyProvider('openai')
    for (const id of HARNESS_PROVIDERS) await this.applyProvider(id)
    for (const id of Object.keys(COMPATIBLE_PROVIDERS)) await this.applyProvider(id)
  }
}
