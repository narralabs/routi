import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'

const run = promisify(execFile)

/**
 * Wraps the Claude Code CLI's own auth.
 *
 * Deliberately a thin wrapper rather than a reimplementation: `claude auth login`
 * opens the browser, performs the real OAuth, and stores the result in the Keychain.
 * Krog never sees or persists a subscription token. Minting one ourselves would mean
 * impersonating Claude Code's OAuth client, which is not a supported integration —
 * so we drive the official flow and read its status.
 */

export interface ClaudeAuthStatus {
  installed: boolean
  loggedIn: boolean
  authMethod?: string
  email?: string
  organization?: string
  subscriptionType?: string
}

/** Shape of `claude auth status --json`. */
interface RawStatus {
  loggedIn?: boolean
  authMethod?: string
  email?: string
  orgName?: string
  subscriptionType?: string
}

export class ClaudeCli {
  constructor(private readonly binary = process.env['KROG_CLAUDE_BIN'] ?? 'claude') {}

  async version(): Promise<string | null> {
    try {
      const { stdout } = await run(this.binary, ['--version'], { timeout: 10_000 })
      return stdout.trim()
    } catch {
      return null
    }
  }

  async status(): Promise<ClaudeAuthStatus> {
    const version = await this.version()
    if (version === null) return { installed: false, loggedIn: false }

    try {
      const { stdout } = await run(this.binary, ['auth', 'status', '--json'], { timeout: 15_000 })
      const raw = JSON.parse(stdout) as RawStatus
      return {
        installed: true,
        loggedIn: raw.loggedIn === true,
        authMethod: raw.authMethod,
        email: raw.email,
        organization: raw.orgName,
        subscriptionType: raw.subscriptionType,
      }
    } catch {
      return { installed: true, loggedIn: false }
    }
  }

  /**
   * Starts the browser sign-in and resolves once it finishes.
   *
   * The CLI is interactive, so it is spawned detached from our stdio and we poll
   * `auth status` until it flips. The browser opens on whichever machine the daemon
   * runs on — the Mac mini — which the client tells the user when they trigger this
   * from a phone.
   */
  async login(options: { timeoutMs?: number } = {}): Promise<ClaudeAuthStatus> {
    const timeoutMs = options.timeoutMs ?? 5 * 60_000

    const child = spawn(this.binary, ['auth', 'login', '--claudeai'], {
      detached: true,
      stdio: 'ignore',
    })
    child.unref()

    const deadline = Date.now() + timeoutMs
    // Poll rather than wait on exit: the CLI may keep running after the browser
    // handshake completes, and status is the fact we actually care about.
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 1500))
      const status = await this.status()
      if (status.loggedIn) return status
    }

    try {
      process.kill(-child.pid!, 'SIGTERM')
    } catch {
      // Already gone.
    }
    throw new Error('Sign-in timed out. Finish the browser step on the Mac running krogd, then try again.')
  }

  async logout(): Promise<void> {
    try {
      await run(this.binary, ['auth', 'logout'], { timeout: 30_000 })
    } catch {
      // Nothing to log out of.
    }
  }
}
