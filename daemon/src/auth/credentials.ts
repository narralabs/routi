import { execFile } from 'node:child_process'
import { chmodSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { promisify } from 'node:util'

const run = promisify(execFile)

const SERVICE = 'Krog'
const ACCOUNT = 'anthropic-api-key'

/**
 * Secret storage for the Anthropic API key.
 *
 * On macOS this is the login Keychain, so the key never sits in plaintext on disk
 * and is protected by the same lock as everything else on the machine. The 0600 file
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

  async getApiKey(): Promise<string | null> {
    if (this.useKeychain) {
      try {
        const { stdout } = await run('security', ['find-generic-password', '-s', SERVICE, '-a', ACCOUNT, '-w'])
        const key = stdout.trim()
        return key.length > 0 ? key : null
      } catch {
        // `security` exits non-zero when the item simply isn't there.
        return null
      }
    }
    try {
      const raw = JSON.parse(readFileSync(this.fallbackPath, 'utf8')) as { anthropicApiKey?: string }
      return raw.anthropicApiKey ?? null
    } catch {
      return null
    }
  }

  async setApiKey(key: string): Promise<void> {
    const trimmed = key.trim()
    if (!trimmed) throw new Error('API key is empty.')

    if (this.useKeychain) {
      // -U updates in place when the item already exists.
      await run('security', [
        'add-generic-password', '-U',
        '-s', SERVICE,
        '-a', ACCOUNT,
        '-w', trimmed,
        '-D', 'application password',
        '-j', 'Anthropic API key for Krog',
      ])
      return
    }

    mkdirSync(dirname(this.fallbackPath), { recursive: true })
    writeFileSync(this.fallbackPath, JSON.stringify({ anthropicApiKey: trimmed }, null, 2), { mode: 0o600 })
    chmodSync(this.fallbackPath, 0o600)
  }

  async clearApiKey(): Promise<void> {
    if (this.useKeychain) {
      try {
        await run('security', ['delete-generic-password', '-s', SERVICE, '-a', ACCOUNT])
      } catch {
        // Already absent.
      }
      return
    }
    rmSync(this.fallbackPath, { force: true })
  }
}
