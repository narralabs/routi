import { execFile, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, openSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { VERSION } from './version.js'

const run = promisify(execFile)
const REPO = 'narralabs/routi'

/**
 * The core updating itself, from a button in the app.
 *
 * The core does the asking and the doing rather than the app, because the app may be a
 * phone and the core is the thing that was installed. What it does itself is the part
 * that must be right before anything changes: fetch the release, check the checksum,
 * unpack beside the running install. Then it hands over to the new release's own
 * `scripts/update-core.sh`, detached, which builds in that folder, swaps it in,
 * restarts the login agent — ending this process — and swaps back if the new core does
 * not answer. The app sees the socket drop and reconnects to whichever core came up.
 */

export interface UpdateCheck {
  current: string
  latest: string | null
  available: boolean
  /** False for a core run from a source checkout, which git updates. */
  canUpdate: boolean
  reason?: string
  checkedAt: number
}

export type UpdateProgress = (stage: string, line: string) => void

/** Dotted versions, numerically: 0.1.10 is newer than 0.1.9. */
export function compareVersions(a: string, b: string): number {
  const pa = a.split('.').map(Number)
  const pb = b.split('.').map(Number)
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0)
    if (d !== 0) return d
  }
  return 0
}

export class Updater {
  private cache: { at: number; latest: string | null } | null = null
  private running = false

  constructor(
    private readonly dataDir: string,
    private readonly progress: UpdateProgress,
  ) {}

  /** The installed core lives in ~/.routi/core; a checkout anywhere else is git's to update. */
  get installed(): boolean {
    return fileURLToPath(import.meta.url).startsWith(join(this.dataDir, 'core') + '/')
  }

  /** Cached for six hours: GitHub allows sixty unauthenticated calls an hour, shared with everything else on the Mac. */
  async check(force = false): Promise<UpdateCheck> {
    const fresh = this.cache !== null && Date.now() - this.cache.at < 6 * 3_600_000
    if (force || !fresh) {
      const latest = await this.latestRelease()
      // A failed lookup keeps the last good answer rather than replacing it with nothing.
      if (latest !== null || this.cache === null) this.cache = { at: Date.now(), latest }
    }
    const latest = this.cache?.latest ?? null
    return {
      current: VERSION,
      latest,
      available: latest !== null && compareVersions(latest, VERSION) > 0,
      canUpdate: this.installed && !this.running,
      ...(this.installed ? {} : { reason: 'This core runs from a source checkout. Pull and restart it instead.' }),
      checkedAt: this.cache?.at ?? Date.now(),
    }
  }

  private async latestRelease(): Promise<string | null> {
    try {
      const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
        headers: { accept: 'application/vnd.github+json', 'user-agent': `routid/${VERSION}` },
        signal: AbortSignal.timeout(8_000),
      })
      if (!res.ok) return null
      const body = (await res.json()) as { tag_name?: string }
      const tag = body.tag_name ?? ''
      return /^v?\d+\.\d+\.\d+$/.test(tag) ? tag.replace(/^v/, '') : null
    } catch {
      return null
    }
  }

  async start(): Promise<{ ok: true } | { ok: false; why: string }> {
    if (!this.installed) return { ok: false, why: 'This core runs from a source checkout. Pull and restart it instead.' }
    if (this.running) return { ok: false, why: 'An update is already running.' }
    const check = await this.check(true)
    if (!check.latest) return { ok: false, why: 'Could not reach GitHub to find the latest release.' }
    if (!check.available) return { ok: false, why: `Already on ${VERSION}.` }

    this.running = true
    void this.run(check.latest).catch((err: unknown) => {
      this.running = false
      this.progress('failed', err instanceof Error ? err.message : String(err))
    })
    return { ok: true }
  }

  private async run(version: string): Promise<void> {
    const base = `https://github.com/${REPO}/releases/download/v${version}`
    this.progress('download', `Downloading Routi Core ${version}`)
    const [archive, sums] = await Promise.all([
      this.fetchBytes(`${base}/routi-core.tar.gz`),
      this.fetchText(`${base}/routi-core.tar.gz.sha256`),
    ])
    const expected = sums.trim().split(/\s+/)[0] ?? ''
    const actual = createHash('sha256').update(archive).digest('hex')
    if (expected.length !== 64 || expected !== actual) {
      throw new Error('The download did not match its checksum, so it was not installed.')
    }

    this.progress('unpack', 'Unpacking')
    const staging = join(this.dataDir, 'core.next')
    rmSync(staging, { recursive: true, force: true })
    mkdirSync(staging, { recursive: true })
    const tarPath = join(this.dataDir, 'routi-core.tar.gz')
    writeFileSync(tarPath, archive)
    try {
      await run('/usr/bin/tar', ['xzf', tarPath, '-C', staging, '--strip-components=1'])
    } finally {
      rmSync(tarPath, { force: true })
    }

    const script = join(staging, 'scripts', 'update-core.sh')
    if (!existsSync(script)) {
      rmSync(staging, { recursive: true, force: true })
      throw new Error(`Routi Core ${version} predates in-app updates. Run the installer instead.`)
    }

    const logs = join(this.dataDir, 'logs')
    mkdirSync(logs, { recursive: true })
    const logPath = join(logs, 'update.log')
    writeFileSync(logPath, `\n--- update to ${version}, ${new Date().toISOString()} ---\n`, { flag: 'a' })
    const fd = openSync(logPath, 'a')

    this.progress('build', 'Building the new core. A few minutes; it restarts by itself when done.')
    /**
     * Detached, in a process group of its own, so it outlives this process. The script
     * ends by restarting the login agent, which ends the core that started it; launchd
     * takes the job's process group with it, and a new group is what survives.
     */
    // Relayed from here on, not from the top: the log keeps every past update, and the
    // first run of this replayed an old rollback's stages as though they were today's.
    const from = statSync(logPath).size
    const child = spawn('/bin/sh', [script, staging], { detached: true, stdio: ['ignore', fd, fd], env: process.env })
    child.unref()
    this.relay(logPath, from)
  }

  /** Passes the script's stage lines on, for as long as this core is alive to read them. */
  private relay(logPath: string, from: number): void {
    let offset = from
    const timer = setInterval(() => {
      try {
        const size = statSync(logPath).size
        if (size <= offset) return
        const text = readFileSync(logPath).subarray(offset).toString('utf8')
        offset = size
        for (const line of text.split('\n')) {
          if (line.startsWith('==> ')) this.progress('build', line.slice(4).trim())
          else if (/\b(error|failed|could not)\b/i.test(line)) this.progress('build', line.trim().slice(0, 200))
        }
      } catch {
        // Not readable this tick; the next one will try again.
      }
    }, 1_000)
    timer.unref()
  }

  private async fetchBytes(url: string): Promise<Buffer> {
    const res = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(5 * 60_000) })
    if (!res.ok) throw new Error(`Could not download the release (${res.status}).`)
    return Buffer.from(await res.arrayBuffer())
  }

  private async fetchText(url: string): Promise<string> {
    const res = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(30_000) })
    if (!res.ok) throw new Error(`Could not download the release checksum (${res.status}).`)
    return res.text()
  }
}
