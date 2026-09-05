import type { AuthMode } from '@krog/protocol'
import type { Store } from '../db/store.js'
import { AnthropicApiAdapter } from '../providers/anthropic-api.js'
import { AnthropicSubscriptionAdapter } from '../providers/anthropic-subscription.js'
import type { ProviderAdapter } from '../providers/types.js'
import type { DesktopPool } from '../surfaces/pool.js'
import { OpenAiApiAdapter } from '../providers/openai-api.js'
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
  harness: string | null
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
      providers: { openai: await this.openAiStatus() },
    }
  }

  // ------------------------------------------------------------------ OpenAI

  private async openAiStatus(): Promise<ProviderAuth> {
    const cli = await this.codex.status()
    const key = await this.credentials.getApiKey('openai')
    const mode = (this.store.getSettings()[settingModeFor('openai')] as AuthMode | undefined) ?? null

    return {
      // As with Anthropic, a stored mode only counts while its credential still works.
      configured: (mode === 'subscription' && cli.loggedIn) || (mode === 'api_key' && key !== null),
      mode,
      // Derived rather than merely read back: a ChatGPT plan is only spendable
      // through Codex, and a connection made before this setting existed has nothing
      // stored. Reporting null there would show a configured provider as having no
      // harness at all.
      harness: mode === 'subscription'
        ? 'codex'
        : mode === 'api_key'
          ? ((this.store.getSettings()[settingHarnessFor('openai')] as string | undefined) ?? 'direct')
          : null,
      cli: {
        installed: cli.installed,
        version: cli.installed ? await this.codex.version() : null,
        loggedIn: cli.loggedIn,
        account: cli.method,
      },
      apiKey: { present: key !== null },
    }
  }

  /** Opens the vendor's browser sign-in for a provider configured in Settings. */
  async providerLogin(provider: string): Promise<AuthStatus> {
    if (provider !== 'openai') throw new Error(`No account sign-in for provider: ${provider}`)

    const cli = await this.codex.status()
    if (!cli.installed) {
      throw new Error(
        'Codex is not installed on this Mac. Install it with `npm install -g @openai/codex`, then try again.',
      )
    }
    if (!cli.loggedIn) await this.codex.login()

    this.store.setSettings({
      [settingModeFor(provider)]: 'subscription',
      // A ChatGPT plan has no API of its own; Codex is the only way to spend one.
      [settingHarnessFor(provider)]: 'codex',
    })
    await this.applyProvider(provider)
    return this.status()
  }

  async providerSetApiKey(provider: string, key: string, harness = 'direct'): Promise<AuthStatus> {
    if (provider !== 'openai') throw new Error(`No API key slot for provider: ${provider}`)

    // Proven before it is stored, so a typo fails here rather than on the first
    // message of a bot the user has already built. The key reaches OpenAI the same way
    // whichever harness will later spend it, so one check covers both.
    await new OpenAiApiAdapter(key).validate()

    await this.credentials.setApiKey(key, provider)
    this.store.setSettings({
      [settingModeFor(provider)]: 'api_key',
      [settingHarnessFor(provider)]: harness === 'codex' ? 'codex' : 'direct',
    })
    await this.applyProvider(provider)
    return this.status()
  }

  async providerSignOut(provider: string): Promise<AuthStatus> {
    await this.credentials.clearApiKey(provider)
    this.store.setSettings({ [settingModeFor(provider)]: null, [settingHarnessFor(provider)]: null })
    this.providers.get(provider)?.dispose()
    this.providers.delete(provider)
    return this.status()
  }

  /** Installs the adapter matching a provider's stored mode. */
  private async applyProvider(provider: string): Promise<void> {
    this.providers.get(provider)?.dispose()
    this.providers.delete(provider)

    if (provider !== 'openai') return
    const mode = this.store.getSettings()[settingModeFor(provider)] as AuthMode | undefined

    const harness = this.store.getSettings()[settingHarnessFor(provider)] as string | undefined

    if (mode === 'api_key') {
      const key = await this.credentials.getApiKey('openai')
      if (!key) return
      this.providers.set(
        'openai',
        harness === 'codex'
          ? new OpenAiSubscriptionAdapter({ cwd: this.sessionCwd, dataDir: this.dataDir, apiKey: key })
          : new OpenAiApiAdapter(key, this.desktops),
      )
      return
    }

    if (mode === 'subscription') {
      const cli = await this.codex.status()
      if (cli.installed && cli.loggedIn) {
        this.providers.set(
          'openai',
          new OpenAiSubscriptionAdapter({ cwd: this.sessionCwd, dataDir: this.dataDir }),
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
    await this.applyProvider('openai')

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
