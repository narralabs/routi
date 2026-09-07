import { execFile, spawn } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { promisify } from 'node:util'

const run = promisify(execFile)

/**
 * The Claude Code that turns run on — and the only one sign-in runs on.
 *
 * Nobody has to install Claude Code for this daemon. The Agent SDK pins a version in
 * its manifest and fetches that build, checksummed, into the native installer's own
 * layout the first time a session initialises. This is that path, and it is the whole
 * list: the Mac's own `claude` used to be a fallback for sign-in, which meant a Mac
 * that already had one signed in on that binary while turns ran on ours — two
 * versions, and two ideas of where the credential lives. One pinned binary for both,
 * the way the core runs on its own Node. `ROUTI_CLAUDE_BIN` remains for development.
 */
export function managedClaudePath(): string {
  const configured = process.env['ROUTI_CLAUDE_BIN']
  if (configured) return configured
  const root = dirname(createRequire(import.meta.url).resolve('@anthropic-ai/claude-agent-sdk'))
  const manifest = JSON.parse(readFileSync(join(root, 'manifest.json'), 'utf8')) as { version?: string }
  if (!manifest.version) throw new Error('The Claude Agent SDK on this install has no manifest; cannot tell which Claude Code it runs.')
  return join(homedir(), '.local', 'share', 'claude', 'versions', manifest.version)
}

/** The pinned binary if it has been fetched, for a turn to name explicitly. */
export function managedClaudeIfPresent(): string | undefined {
  try {
    const path = managedClaudePath()
    return existsSync(path) ? path : undefined
  } catch {
    return undefined
  }
}

/**
 * Has the SDK fetch its Claude Code, on a machine that has none.
 *
 * The download happens as a session initialises, before any credential is looked at,
 * so a throwaway query that stops at the init message is enough — and it is the SDK's
 * own code path doing the fetching and the checksum, not ours.
 */
async function fetchClaudeCodeViaSdk(): Promise<void> {
  const { query } = await import('@anthropic-ai/claude-agent-sdk')
  const abort = new AbortController()
  try {
    for await (const message of query({ prompt: 'ok', options: { maxTurns: 1, abortController: abort } })) {
      if (message.type === 'system') break
    }
  } catch {
    // Not signed in, or offline: the binary is either there now or it is not, and
    // status() will say which.
  } finally {
    abort.abort()
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
    let version = await this.version()
    if (version === null) {
      await fetchClaudeCodeViaSdk()
      version = await this.version()
    }
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
    throw new Error('Sign-in timed out. Finish the browser step on the Mac running routid, then try again.')
  }

  async logout(): Promise<void> {
    try {
      await run(this.binary, ['auth', 'logout'], { timeout: 30_000 })
    } catch {
      // Nothing to log out of.
    }
  }
}
