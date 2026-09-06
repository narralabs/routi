import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'

const run = promisify(execFile)

export interface CodexAuthStatus {
  installed: boolean
  loggedIn: boolean
  /** How Codex is authenticated, in its own words — "ChatGPT" or "API key". */
  method?: string
}

/**
 * The Codex CLI, as the way to reach a personal ChatGPT account.
 *
 * The same shape as `ClaudeCli` and for the same reason: a subscription is not
 * something an API key can stand in for, and the only sanctioned way to spend one
 * from a program is through the vendor's own signed-in CLI. Routi never sees or stores
 * the credential — it asks the CLI whether one exists and lets the SDK use it.
 *
 * `codex login status` prints a line like "Logged in using ChatGPT" — on stderr, not
 * stdout, and with a zero exit code either way. There is no `--json`, so this reads
 * the sentence from both streams; the parse stays forgiving because whether the
 * wording changes matters less than whether it says logged in.
 */
export class CodexCli {
  constructor(private readonly binary = process.env['ROUTI_CODEX_BIN'] ?? 'codex') {}

  async version(): Promise<string | null> {
    try {
      const { stdout, stderr } = await run(this.binary, ['--version'], { timeout: 10_000 })
      return (stdout.trim() || stderr.trim()) || null
    } catch {
      return null
    }
  }

  async status(): Promise<CodexAuthStatus> {
    const version = await this.version()
    if (version === null) return { installed: false, loggedIn: false }

    try {
      const { stdout, stderr } = await run(this.binary, ['login', 'status'], { timeout: 15_000 })
      const line = `${stdout}\n${stderr}`.trim()
      if (!/logged in/i.test(line)) return { installed: true, loggedIn: false }
      const method = /using\s+(.+?)\.?$/i.exec(line)?.[1]?.trim()
      return { installed: true, loggedIn: true, method: method || undefined }
    } catch {
      // Exits non-zero when signed out.
      return { installed: true, loggedIn: false }
    }
  }

  /**
   * Opens the browser sign-in and waits for it to take.
   *
   * Polls rather than watching the child's output: `codex login` prints a URL and
   * then waits on a local callback, so completion shows up in the status, not on
   * stdout. Same approach as the Claude side.
   */
  async login(options: { timeoutMs?: number } = {}): Promise<CodexAuthStatus> {
    const timeoutMs = options.timeoutMs ?? 5 * 60_000

    const child = spawn(this.binary, ['login'], { stdio: 'ignore', detached: false })
    const deadline = Date.now() + timeoutMs

    try {
      while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 1_500))
        const status = await this.status()
        if (status.loggedIn) return status
        if (child.exitCode !== null && child.exitCode !== 0) break
      }
    } finally {
      if (child.exitCode === null) child.kill()
    }

    const final = await this.status()
    if (!final.loggedIn) {
      throw new Error('Sign-in did not complete. Finish it in the browser, then try again.')
    }
    return final
  }
}
