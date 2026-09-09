import { execFile, spawn } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'

const run = promisify(execFile)

export interface GrokAuthStatus {
  installed: boolean
  loggedIn: boolean
  /** Who is signed in, for display — an email address. */
  account?: string
}

/**
 * Where the Grok CLI actually is on this machine.
 *
 * Its installer drops the binary in `~/.grok/bin`, which is on an interactive shell's
 * PATH and is not on a launchd daemon's. Looking there first is what keeps routid
 * finding the same CLI the user signed in with, whether it started from a terminal or
 * at boot.
 */
export function grokBinary(): string {
  const configured = process.env['ROUTI_GROK_BIN']
  if (configured) return configured
  const installed = join(homedir(), '.grok', 'bin', 'grok')
  return existsSync(installed) ? installed : 'grok'
}

/** The credential store `grok login` writes, which is also the one Routi borrows. */
export function grokAuthFile(): string {
  return join(homedir(), '.grok', 'auth.json')
}

/**
 * The Grok CLI, as the way to reach a personal Grok account.
 *
 * The third of the same shape, after `ClaudeCli` and `CodexCli`, and for the same
 * reason: a plan someone already pays for should be spendable without a second,
 * metered bill, and the only sanctioned way to spend one from a program is through
 * the vendor's own signed-in CLI. Routi never sees or stores the token — it asks the
 * CLI whether one exists and lets the agent use it.
 */
export class GrokCli {
  /** `env` carries GROK_HOME and HOME for a profile with its own login. */
  constructor(private readonly binary = grokBinary(), private readonly env: Record<string, string> = {}) {}
  private get spawnEnv(): NodeJS.ProcessEnv { return { ...process.env, ...this.env } }

  async version(): Promise<string | null> {
    try {
      const { stdout, stderr } = await run(this.binary, ['--version'], { timeout: 10_000 })
      return stdout.trim() || stderr.trim() || null
    } catch {
      return null
    }
  }

  /**
   * Asks the CLI, rather than reading its auth.json.
   *
   * The file keeps its entry long after the token behind it has stopped buying
   * anything — this Mac had a three-week-old one that `grok models` answered with
   * "You are not authenticated" — so the file says only that somebody signed in once.
   * `models` needs a live credential, which is the question actually being asked.
   */
  async status(): Promise<GrokAuthStatus> {
    const version = await this.version()
    if (version === null) return { installed: false, loggedIn: false }

    try {
      const { stdout, stderr } = await run(this.binary, ['models'], { timeout: 20_000, env: this.spawnEnv })
      if (/not authenticated/i.test(`${stdout}\n${stderr}`)) return { installed: true, loggedIn: false }
      return { installed: true, loggedIn: true, account: this.account() }
    } catch {
      return { installed: true, loggedIn: false }
    }
  }

  /**
   * Signs the CLI out, so the next `login` is a real one. Without this, Disconnect
   * only forgot Routi's own setting; the CLI kept its session, and the next Connect
   * found it signed in and kept whichever account that was — measured on a Mac where
   * an Apple-relay account would not give way to the one wanted.
   */
  async logout(): Promise<void> {
    try {
      await run(this.binary, ['logout'], { timeout: 30_000, env: this.spawnEnv })
    } catch {
      // Not signed in, or no CLI: either way there is nothing left to sign out of.
    }
  }

  /** Every model this account can reach, asked of the CLI rather than hardcoded. */
  async models(): Promise<GrokModel[]> {
    try {
      const { stdout } = await run(this.binary, ['models'], { timeout: 20_000, env: this.spawnEnv })
      return parseModelList(stdout)
    } catch {
      return []
    }
  }

  /** The signed-in email, read from the CLI's own store. Display only. */
  private account(): string | undefined {
    try {
      const file = JSON.parse(readFileSync(grokAuthFile(), 'utf8')) as Record<string, unknown>
      for (const entry of Object.values(file)) {
        const email = (entry as Record<string, unknown> | null)?.['email']
        if (typeof email === 'string' && email) return email
      }
    } catch {
      // No file, or a shape this doesn't know. The account line is a nicety.
    }
    return undefined
  }

  /**
   * Signs in, and waits for it to take.
   *
   * Grok uses a device code: it prints a URL and a short code and opens the browser
   * itself. Nothing about completion comes back on stdout, so this polls the status
   * the way the Claude and Codex sides do. The URL is kept as it goes past, because
   * the one case worth handling well is the browser not opening — then the only
   * useful thing to say is where to go and what to type.
   */
  async login(options: { timeoutMs?: number } = {}): Promise<GrokAuthStatus> {
    const timeoutMs = options.timeoutMs ?? 5 * 60_000

    const child = spawn(this.binary, ['login'], { stdio: ['ignore', 'pipe', 'pipe'], env: this.spawnEnv })
    let prompt = ''
    child.stdout?.setEncoding('utf8')
    child.stderr?.setEncoding('utf8')
    const collect = (chunk: string) => { prompt += chunk }
    child.stdout?.on('data', collect)
    child.stderr?.on('data', collect)

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
    if (!final.loggedIn) throw new Error(loginFailure(prompt))
    return final
  }
}

export interface GrokModel {
  id: string
  isDefault: boolean
}

/**
 * `grok models` as a list.
 *
 * It prints a default line and then a bulleted lineup:
 *
 *     Default model: grok-4.6
 *
 *     Available models:
 *       * grok-4.6 (default)
 *       - grok-4.5
 */
export function parseModelList(output: string): GrokModel[] {
  const models: GrokModel[] = []
  for (const line of output.split('\n')) {
    const match = /^\s*[*-]\s+(\S+)/.exec(line)
    if (!match?.[1]) continue
    models.push({ id: match[1], isDefault: line.includes('(default)') })
  }
  return models
}

/** Says what to do next, using the code the CLI printed if it got that far. */
function loginFailure(output: string): string {
  const url = /https:\/\/\S*device\S*/.exec(output)?.[0]
  const code = /user_code=([A-Z0-9-]+)/.exec(output)?.[1]
  if (url && code) {
    return `Sign-in didn't complete. Open ${url} on the Mac running Routi Core and confirm the code ${code}, then try again.`
  }
  return 'Sign-in did not complete. Finish it in the browser, then try again.'
}
