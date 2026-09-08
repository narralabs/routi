import { execFile, spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { createRequire } from 'node:module'
import { promisify } from 'node:util'

const run = promisify(execFile)

/**
 * The Claude Code that turns run on — and the only one sign-in runs on.
 *
 * Nobody has to install Claude Code for this daemon: the Agent SDK depends on a
 * platform package (`@anthropic-ai/claude-agent-sdk-darwin-arm64` and its siblings)
 * whose whole content is the native `claude` binary, pinned to the SDK's version and
 * installed with the rest of `node_modules`. That is the binary the SDK spawns, found
 * the way the SDK itself finds it — resolving the package for this platform and
 * architecture — so sign-in and turns cannot disagree about which Claude Code they
 * are on.
 *
 * Two earlier ideas were wrong, measured: the SDK does not fetch a binary into
 * `~/.local/share/claude/versions` (that folder comes from Anthropic's own installer,
 * which a Mac may or may not have), and falling back to the Mac's own `claude` on
 * PATH signed in on one version while turns ran on another. `ROUTI_CLAUDE_BIN`
 * remains for development.
 */
export function managedClaudePath(): string {
  const configured = process.env['ROUTI_CLAUDE_BIN']
  if (configured) return configured
  const require = createRequire(import.meta.url)
  const sdk = require.resolve('@anthropic-ai/claude-agent-sdk')
  const fromSdk = createRequire(sdk)
  const suffix = process.platform === 'win32' ? '.exe' : ''
  const names = process.platform === 'linux'
    ? [`linux-${process.arch}`, `linux-${process.arch}-musl`]
    : [`${process.platform}-${process.arch}`]
  for (const name of names) {
    try {
      return fromSdk.resolve(`@anthropic-ai/claude-agent-sdk-${name}/claude${suffix}`)
    } catch {
      // Not this variant.
    }
  }
  throw new Error(`The Claude Agent SDK on this install has no Claude Code for ${process.platform}-${process.arch}.`)
}

/** The pinned binary, for a turn to name explicitly; undefined if the install lacks it. */
export function managedClaudeIfPresent(): string | undefined {
  try {
    const path = managedClaudePath()
    return existsSync(path) ? path : undefined
  } catch {
    return undefined
  }
}

/**
 * Wraps the Claude Code CLI's own auth.
 *
 * Deliberately a thin wrapper rather than a reimplementation: `claude auth login`
 * opens the browser, performs the real OAuth, and stores the result in the Keychain.
 * Routi never sees or persists a subscription token. Minting one ourselves would mean
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
  private binary = ''
  /** Extra environment — CLAUDE_CONFIG_DIR for a profile with its own login. */
  constructor(private readonly env: Record<string, string> = {}) {}
  private get spawnEnv(): NodeJS.ProcessEnv { return { ...process.env, ...this.env } }

  /** Re-resolved each time: the SDK may have fetched it since. */
  private resolve(): string {
    this.binary = managedClaudePath()
    return this.binary
  }

  async version(): Promise<string | null> {
    try {
      const { stdout } = await run(this.resolve(), ['--version'], { timeout: 10_000 })
      return stdout.trim()
    } catch {
      return null
    }
  }

  async status(): Promise<ClaudeAuthStatus> {
    const version = await this.version()
    if (version === null) return { installed: false, loggedIn: false }

    try {
      const { stdout } = await run(this.binary, ['auth', 'status', '--json'], { timeout: 15_000, env: this.spawnEnv })
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
      env: this.spawnEnv,
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
    throw new Error('Sign-in timed out. Finish the browser step on the Mac running routid, then try again.')
  }

  async logout(): Promise<void> {
    try {
      await run(this.binary, ['auth', 'logout'], { timeout: 30_000, env: this.spawnEnv })
    } catch {
      // Nothing to log out of.
    }
  }
}
