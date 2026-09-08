import { execFile } from 'node:child_process'
import { chmodSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { promisify } from 'node:util'

const run = promisify(execFile)

const SERVICE = 'Routi'
/** The Keychain service name from before the rename; read from, never written to. */
const OLD_SERVICE = 'Krog'

/** Keychain account name per provider, so two keys can coexist. */
const ACCOUNTS: Record<string, string> = {
  anthropic: 'anthropic-api-key',
  'anthropic-claude': 'anthropic-claude-api-key',
  openai: 'openai-api-key',
  'openai-codex': 'openai-codex-api-key',
  deepseek: 'deepseek-api-key',
  xai: 'xai-api-key',
  'xai-grok': 'xai-grok-api-key',
}

/**
 * Secret storage for provider API keys.
 *
 * On macOS this is the login Keychain, so a key never sits in plaintext on disk and
 * is protected by the same lock as everything else on the machine. The 0600 file
 * fallback exists only for non-macOS hosts; it is deliberately noisy about being
 * second-best.
 */
export class Credentials {
  private readonly fallbackPath: string

  constructor(dataDir: string) {
    this.fallbackPath = join(dataDir, 'credentials.json')
  }

  private get useKeychain(): boolean {
    return process.platform === 'darwin'
  }

  /**
   * The Keychain account name. The default profile keeps the names from before
   * profiles existed, so nothing already stored moves; another profile's key sits
   * beside it under the same name with the profile's id appended.
   */
  private account(provider: string, profileId = 'default'): string {
    const account = ACCOUNTS[provider]
    if (!account) throw new Error(`No credential slot for provider: ${provider}`)
    return profileId === 'default' ? account : `${account}.${profileId}`
  }

  private readFallback(): Record<string, string> {
    try {
      return JSON.parse(readFileSync(this.fallbackPath, 'utf8')) as Record<string, string>
    } catch {
      return {}
    }
  }

  async getApiKey(provider = 'anthropic', profileId = 'default'): Promise<string | null> {
    if (this.useKeychain) {
      const found = await this.readKeychain(SERVICE, provider, profileId)
      if (found !== null) return found
      // A key stored under the old name is adopted: written under the new one, so the
      // next read finds it there, and left in place under the old.
      if (profileId !== 'default') return null
      const old = await this.readKeychain(OLD_SERVICE, provider, profileId)
      if (old !== null) await this.setApiKey(old, provider, profileId)
      return old
    }
    return this.readFallback()[this.account(provider, profileId)] ?? null
  }

  private async readKeychain(service: string, provider: string, profileId: string): Promise<string | null> {
    try {
      const { stdout } = await run('security', [
        'find-generic-password', '-s', service, '-a', this.account(provider, profileId), '-w',
      ])
      const key = stdout.trim()
      return key.length > 0 ? key : null
    } catch {
      // `security` exits non-zero when the item simply isn't there.
      return null
    }
  }

  async setApiKey(key: string, provider = 'anthropic', profileId = 'default'): Promise<void> {
    const trimmed = key.trim()
    if (!trimmed) throw new Error('API key is empty.')

    if (this.useKeychain) {
      // -U updates in place when the item already exists.
      await run('security', [
        'add-generic-password', '-U',
        '-s', SERVICE,
        '-a', this.account(provider, profileId),
        '-w', trimmed,
        '-D', 'application password',
        '-j', `${provider} API key for Routi`,
      ])
      return
    }

    const all = { ...this.readFallback(), [this.account(provider, profileId)]: trimmed }
    mkdirSync(dirname(this.fallbackPath), { recursive: true })
    writeFileSync(this.fallbackPath, JSON.stringify(all, null, 2), { mode: 0o600 })
    chmodSync(this.fallbackPath, 0o600)
  }

  async clearApiKey(provider = 'anthropic', profileId = 'default'): Promise<void> {
    if (this.useKeychain) {
      try {
        await run('security', ['delete-generic-password', '-s', SERVICE, '-a', this.account(provider, profileId)])
      } catch {
        // Already absent.
      }
      return
    }
    const all = this.readFallback()
    delete all[this.account(provider, profileId)]
    if (Object.keys(all).length === 0) {
      rmSync(this.fallbackPath, { force: true })
      return
    }
    writeFileSync(this.fallbackPath, JSON.stringify(all, null, 2), { mode: 0o600 })
  }
}
