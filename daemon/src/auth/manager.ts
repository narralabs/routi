import type { AuthMode } from '@krog/protocol'
import type { Store } from '../db/store.js'
import { AnthropicApiAdapter } from '../providers/anthropic-api.js'
import { AnthropicSubscriptionAdapter } from '../providers/anthropic-subscription.js'
import type { ProviderAdapter } from '../providers/types.js'
import type { DesktopPool } from '../surfaces/pool.js'
import { OpenAiApiAdapter } from '../providers/openai-api.js'
import { COMPATIBLE_PROVIDERS, OpenAiCompatibleAdapter } from '../providers/openai-compatible.js'
import { OpenAiSubscriptionAdapter } from '../providers/openai-subscription.js'
import { ClaudeCli } from './claude-cli.js'
import { CodexCli } from './codex-cli.js'
import { Credentials } from './credentials.js'

export interface AuthStatus {
  /** True once a provider can actually reach Anthropic. Gates onboarding. */
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
 * Owns which credential the daemon uses and swaps the live provider when it changes.
 *
 * The daemon must start with no credentials at all — that is the whole point of
 * onboarding — so the provider map starts empty and is populated here.
 */
export class AuthManager {
  private readonly cli = new ClaudeCli()
  private readonly codex = new CodexCli()
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
    const apiKey = await this.credentials.getApiKey()
    const mode = (this.store.getSettings()[SETTING_MODE] as AuthMode | undefined) ?? null

    const subscriptionUsable = cliStatus.installed && cliStatus.loggedIn
    const apiUsable = apiKey !== null

    // A stored mode only counts if its credential still works — a signed-out CLI or
    // a deleted keychain item should send the user back through onboarding.
    const configured =
      (mode === 'subscription' && subscriptionUsable) || (mode === 'api_key' && apiUsable)

    return {
      configured,
      mode,
      subscription: {
        cliInstalled: cliStatus.installed,
        cliVersion: cliStatus.installed ? await this.cli.version() : null,
        loggedIn: cliStatus.loggedIn,
        email: cliStatus.email,
        organization: cliStatus.organization,
        subscriptionType: cliStatus.subscriptionType,
      },
      apiKey: { present: apiUsable },
      providers: {
        openai: await this.openAiStatus('openai'),
        'openai-codex': await this.openAiStatus('openai-codex'),
        // Everything that speaks OpenAI's chat API: one shape, key only.
        ...Object.fromEntries(
          await Promise.all(
            Object.keys(COMPATIBLE_PROVIDERS).map(
              async (id) => [id, await this.keyOnlyStatus(id)] as const,
            ),
          ),
        ),
      },
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
    if (provider !== 'openai-codex') throw new Error(`No account sign-in for provider: ${provider}`)

    const cli = await this.codex.status()
    if (!cli.installed) {
      throw new Error(
        'Codex is not installed on this Mac. Install it with `npm install -g @openai/codex`, then try again.',
      )
    }
    if (!cli.loggedIn) await this.codex.login()

    this.store.setSettings({ [settingModeFor(provider)]: 'subscription' })
    await this.applyProvider(provider)
    return this.status()
  }

  async providerSetApiKey(provider: string, key: string): Promise<AuthStatus & { verified: string }> {
    const compatible = COMPATIBLE_PROVIDERS[provider]
    if (provider !== 'openai' && provider !== 'openai-codex' && !compatible) {
      throw new Error(`No API key slot for provider: ${provider}`)
    }

    // Proven before it is stored, so a typo fails here rather than on the first message
    // of a bot the user has already built.
    const verified = await (compatible
      ? new OpenAiCompatibleAdapter(compatible, key).validate()
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
    if (provider !== 'openai' && provider !== 'openai-codex' && !compatible) return
    const mode = this.store.getSettings()[settingModeFor(provider)] as AuthMode | undefined
    const key = await this.credentials.getApiKey(provider)

    if (compatible) {
      if (mode === 'api_key' && key) {
        this.providers.set(provider, new OpenAiCompatibleAdapter(compatible, key, this.desktops))
      }
      return
    }

    // Two providers rather than one with a switch, so both can be connected at once:
    // a bot on the Codex agent and a bot on a named API model are different bots, and
    // a person will want both alive rather than having to choose.
    if (provider === 'openai') {
      if (mode === 'api_key' && key) {
        this.providers.set('openai', new OpenAiApiAdapter(key, this.desktops))
      }
      return
    }

    if (mode === 'api_key' && key) {
      this.providers.set(
        'openai-codex',
        new OpenAiSubscriptionAdapter({
          cwd: this.sessionCwd,
          dataDir: this.dataDir,
          mcpBaseUrl: this.mcpBaseUrl,
          apiKey: key,
        }),
      )
      return
    }
    if (mode === 'subscription') {
      const cli = await this.codex.status()
      if (cli.installed && cli.loggedIn) {
        this.providers.set(
          'openai-codex',
          new OpenAiSubscriptionAdapter({
            cwd: this.sessionCwd,
            dataDir: this.dataDir,
            mcpBaseUrl: this.mcpBaseUrl,
          }),
        )
      }
    }
  }

  /** Opens the browser sign-in on this machine and selects subscription mode. */
  async loginWithClaude(): Promise<AuthStatus> {
    const cliStatus = await this.cli.status()
    if (!cliStatus.installed) {
      throw new Error(
        'Claude Code is not installed on this Mac. Install it with `npm install -g @anthropic-ai/claude-code`, then try again.',
      )
    }
    if (!cliStatus.loggedIn) await this.cli.login()

    this.store.setSettings({ [SETTING_MODE]: 'subscription' })
    await this.applyMode()
    return this.status()
  }

  async setApiKey(key: string): Promise<AuthStatus> {
    // Validate against the real API *before* storing, so a rejected key never lands
    // in the Keychain and never becomes the selected mode.
    const probe = new AnthropicApiAdapter(key.trim())
    try {
      await probe.validate()
    } finally {
      probe.dispose()
    }

    await this.credentials.setApiKey(key)
    this.store.setSettings({ [SETTING_MODE]: 'api_key' })
    await this.applyMode()
    return this.status()
  }

  async signOut(): Promise<AuthStatus> {
    const mode = this.store.getSettings()[SETTING_MODE] as AuthMode | undefined
    if (mode === 'api_key') await this.credentials.clearApiKey()
    this.store.setSettings({ [SETTING_MODE]: null })

    const existing = this.providers.get('anthropic')
    existing?.dispose()
    this.providers.delete('anthropic')
    return this.status()
  }

  /** Installs every configured provider. Called at boot and on change. */
  async applyMode(): Promise<void> {
    await this.migrateCodexProvider()
    await this.applyProvider('openai')
    await this.applyProvider('openai-codex')
    for (const id of Object.keys(COMPATIBLE_PROVIDERS)) await this.applyProvider(id)

    const mode = this.store.getSettings()[SETTING_MODE] as AuthMode | undefined

    const existing = this.providers.get('anthropic')
    existing?.dispose()
    this.providers.delete('anthropic')

    if (mode === 'api_key') {
      const key = await this.credentials.getApiKey()
      if (key) this.providers.set('anthropic', new AnthropicApiAdapter(key))
      return
    }

    if (mode === 'subscription') {
      const cliStatus = await this.cli.status()
      if (cliStatus.installed && cliStatus.loggedIn) {
        this.providers.set(
          'anthropic',
          new AnthropicSubscriptionAdapter({ cwd: this.sessionCwd, desktops: this.desktops }),
        )
      }
    }
  }
}
