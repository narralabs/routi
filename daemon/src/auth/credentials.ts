import { execFile } from 'node:child_process'
import { chmodSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { promisify } from 'node:util'

const run = promisify(execFile)

const SERVICE = 'Krog'

/** Keychain account name per provider, so two keys can coexist. */
const ACCOUNTS: Record<string, string> = {
  anthropic: 'anthropic-api-key',
  openai: 'openai-api-key',
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

  private account(provider: string): string {
    const account = ACCOUNTS[provider]
    if (!account) throw new Error(`No credential slot for provider: ${provider}`)
    return account
  }

  private readFallback(): Record<string, string> {
    try {
      return JSON.parse(readFileSync(this.fallbackPath, 'utf8')) as Record<string, string>
    } catch {
      return {}
    }
  }

  async getApiKey(provider = 'anthropic'): Promise<string | null> {
    if (this.useKeychain) {
      try {
        const { stdout } = await run('security', [
          'find-generic-password', '-s', SERVICE, '-a', this.account(provider), '-w',
        ])
        const key = stdout.trim()
        return key.length > 0 ? key : null
      } catch {
        // `security` exits non-zero when the item simply isn't there.
        return null
      }
    }
    return this.readFallback()[this.account(provider)] ?? null
  }

  async setApiKey(key: string, provider = 'anthropic'): Promise<void> {
    const trimmed = key.trim()
    if (!trimmed) throw new Error('API key is empty.')

    if (this.useKeychain) {
      // -U updates in place when the item already exists.
      await run('security', [
        'add-generic-password', '-U',
        '-s', SERVICE,
        '-a', this.account(provider),
        '-w', trimmed,
        '-D', 'application password',
        '-j', `${provider} API key for Krog`,
      ])
      return
    }

    const all = { ...this.readFallback(), [this.account(provider)]: trimmed }
    mkdirSync(dirname(this.fallbackPath), { recursive: true })
    writeFileSync(this.fallbackPath, JSON.stringify(all, null, 2), { mode: 0o600 })
    chmodSync(this.fallbackPath, 0o600)
  }

  async clearApiKey(provider = 'anthropic'): Promise<void> {
    if (this.useKeychain) {
      try {
        await run('security', ['delete-generic-password', '-s', SERVICE, '-a', this.account(provider)])
      } catch {
        // Already absent.
      }
      return
    }
    const all = this.readFallback()
    delete all[this.account(provider)]
    if (Object.keys(all).length === 0) {
      rmSync(this.fallbackPath, { force: true })
      return
    }
    writeFileSync(this.fallbackPath, JSON.stringify(all, null, 2), { mode: 0o600 })
  }
}
