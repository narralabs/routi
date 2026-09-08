import { execFile, spawn } from 'node:child_process'
import { createRequire } from 'node:module'
import { promisify } from 'node:util'

const run = promisify(execFile)

/**
 * The Codex this daemon ships, rather than whichever one is on PATH.
 *
 * `@openai/codex` is a dependency, versioned with the SDK that drives it — this machine
 * once had the SDK spawning a Homebrew Codex twenty versions apart, which is the kind
 * of gap where a config key one side sends is simply not understood by the other. It
 * also means nobody installs Codex to use a ChatGPT plan here: the binary is present,
 * and `login` on it stores the credential where any Codex would find it.
 */
export function codexBinary(): string {
  const configured = process.env['ROUTI_CODEX_BIN']
  if (configured) return configured
  try {
    return createRequire(import.meta.url).resolve('@openai/codex/bin/codex.js')
  } catch {
    return 'codex'
  }
}

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
  /** `env` carries CODEX_HOME for a profile with its own login. */
  constructor(private readonly binary = codexBinary(), private readonly env: Record<string, string> = {}) {}
  private get spawnEnv(): NodeJS.ProcessEnv { return { ...process.env, ...this.env } }

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
      const { stdout, stderr } = await run(this.binary, ['login', 'status'], { timeout: 15_000, env: this.spawnEnv })
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

    const child = spawn(this.binary, ['login'], { stdio: 'ignore', detached: false, env: this.spawnEnv })
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
