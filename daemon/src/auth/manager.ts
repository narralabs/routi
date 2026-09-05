import type { AuthMode } from '@krog/protocol'
import type { Store } from '../db/store.js'
import { AnthropicApiAdapter } from '../providers/anthropic-api.js'
import { AnthropicSubscriptionAdapter } from '../providers/anthropic-subscription.js'
import type { ProviderAdapter } from '../providers/types.js'
import type { DesktopPool } from '../surfaces/pool.js'
import { ClaudeCli } from './claude-cli.js'
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
}

const SETTING_MODE = 'authMode'

/**
 * Owns which credential the daemon uses and swaps the live provider when it changes.
 *
 * The daemon must start with no credentials at all — that is the whole point of
 * onboarding — so the provider map starts empty and is populated here.
 */
export class AuthManager {
  private readonly cli = new ClaudeCli()
  private readonly credentials: Credentials

  constructor(
    private readonly store: Store,
    private readonly providers: Map<string, ProviderAdapter>,
    private readonly sessionCwd: string,
    dataDir: string,
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

  /** Installs the provider matching the stored mode. Called at boot and on change. */
  async applyMode(): Promise<void> {
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
