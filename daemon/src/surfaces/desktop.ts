import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'

const run = promisify(execFile)

import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const IMAGE = 'routi-desktop:latest'
const CONTAINER = 'routi-desktop'

/**
 * Where Docker's command line is, on a Mac that may never have put it on PATH.
 *
 * Docker Desktop links `docker` into /usr/local/bin only when its first launch is given
 * an administrator password. Declined, the CLI lives inside the app bundle — and, in
 * Docker's "user" install, under ~/.docker/bin — and nothing on a launchd agent's PATH
 * finds it. That surfaced as setup saying Docker was not installed on a Mac where it
 * was visibly running, with "Check again" never changing its mind. PATH is tried first,
 * so an explicit choice still wins; the answer is not cached, so a Docker installed
 * after the core started is found on the next check.
 */
function dockerBinary(): string {
  const onPath = (process.env['PATH'] ?? '')
    .split(':')
    .filter(Boolean)
    .map((dir) => join(dir, 'docker'))
    .find((path) => existsSync(path))
  if (onPath) return onPath
  const known = [
    join(homedir(), '.docker', 'bin', 'docker'),
    '/Applications/Docker.app/Contents/Resources/bin/docker',
    '/usr/local/bin/docker',
    '/opt/homebrew/bin/docker',
  ]
  return known.find((path) => existsSync(path)) ?? 'docker'
}

export type DesktopState = 'stopped' | 'starting' | 'running' | 'unavailable'

export interface DesktopStatus {
  state: DesktopState
  width: number
  height: number
  /** Why the desktop can't run, when it can't. */
  detail?: string
}

export type PointerButton = 1 | 2 | 3

/** The machine every screen lives on, as a whole: for setup and for Settings. */
export interface HostStatus {
  /** Whether a Docker engine can be reached: no CLI at all, a CLI with no engine, or up. */
  docker: 'missing' | 'stopped' | 'running'
  dockerVersion: string | null
  /** The desktop image: not built yet, being built now, or ready. Unknown without Docker. */
  image: 'missing' | 'building' | 'ready' | 'unknown'
  machine: 'stopped' | 'running'
}

export type DesktopInput =
  | { kind: 'click'; x: number; y: number; button?: PointerButton }
  | { kind: 'doubleClick'; x: number; y: number }
  | { kind: 'move'; x: number; y: number }
  | { kind: 'scroll'; x: number; y: number; amount: number }
  | { kind: 'type'; text: string }
  | { kind: 'key'; keys: string[] }
  | { kind: 'open'; url: string }
  /** Puts text on the desktop's clipboard and pastes it. */
  | { kind: 'paste'; text: string }

/**
 * The one machine every screen lives on.
 *
 * A container is not a screen. Bots need separate screens so they never fight over a
 * pointer or read each other's tabs, and that is an X display — one Xvfb, one desktop
 * session, one browser. Running a whole container per bot bought none of that and cost
 * a slow start, a separate filesystem, and tools installed over and over.
 *
 * So there is exactly one container. It starts empty and holds itself open; screens
 * come and go inside it in a couple of seconds each.
 */
class Host {
  private ensuring: Promise<string | null> | null = null
  private building = false

  /**
   * The state of the machine, for a person rather than a bot.
   *
   * A bot's `status()` says whether *its* screen can run; this says why not, in the
   * terms setup and Settings need — is Docker installed, is it running, is the image
   * built. Three separate questions with three separate fixes, and the first screen a
   * new person sees should ask the right one.
   */
  async describe(): Promise<HostStatus> {
    const docker = await this.dockerState()
    if (docker.state !== 'running') {
      return { docker: docker.state, dockerVersion: docker.version, image: 'unknown', machine: 'stopped' }
    }
    const image = this.building ? 'building' : (await this.imageExists()) ? 'ready' : 'missing'
    const machine = (await this.isRunning()) ? 'running' : 'stopped'
    return { docker: 'running', dockerVersion: docker.version, image, machine }
  }

  private async dockerState(): Promise<{ state: HostStatus['docker']; version: string | null }> {
    try {
      const { stdout } = await run(dockerBinary(), ['info', '--format', '{{.ServerVersion}}'], { timeout: 8_000 })
      return { state: 'running', version: stdout.trim() || null }
    } catch (err) {
      // No CLI at all is a different answer from a CLI whose engine is not up: one
      // needs an install, the other a click on Docker Desktop.
      const code = (err as NodeJS.ErrnoException).code
      return { state: code === 'ENOENT' ? 'missing' : 'stopped', version: null }
    }
  }

  /** Brings the machine up if it is not already. Resolves to a reason on failure. */
  async ensure(): Promise<string | null> {
    // Several bots can call this at once on a cold daemon; one start is enough.
    this.ensuring ??= this.ensureOnce().finally(() => {
      this.ensuring = null
    })
    return this.ensuring
  }

  private async ensureOnce(): Promise<string | null> {
    if (!(await this.dockerAvailable())) {
      return 'Docker is not running on the Mac hosting Routi Core. Start Docker Desktop there; Settings → Screens shows the state.'
    }
    if (!(await this.imageExists())) {
      const built = await this.buildImage()
      if (built !== null) return built
    }
    if (await this.isRunning()) return null

    // Remove any stopped container of the same name; `docker run` refuses otherwise.
    await run(dockerBinary(), ['rm', '-f', CONTAINER], { timeout: 20_000 }).catch(() => {})

    try {
      await run(dockerBinary(), [
        'run', '-d',
        '--name', CONTAINER,
        // Chromium needs more than the default 64MB of /dev/shm or it crashes on any
        // real page — and now several Chromiums share this.
        '--shm-size=2g',
        /**
         * Chromium's own sandbox creates user namespaces, which Docker's default
         * seccomp profile denies — it fails with "Failed to move to new namespace".
         * The alternative is launching with --no-sandbox, which disables Chromium's
         * isolation outright; this keeps it, and leans on the container as the
         * boundary instead.
         */
        '--security-opt', 'seccomp=unconfined',
        // Comes back with Docker. A Docker Desktop restart stops every container; without
        // this the machine stayed down until a bot asked, and with it the machine is up
        // before anyone does. Screens inside it are gone either way and are re-made on
        // demand — `status()` re-confirms a remembered screen against the machine.
        '--restart', 'unless-stopped',
        /**
         * Each screen's Chromium listens for DevTools on 9222 + its display offset, so
         * a bot can read a page's structure rather than read it off a JPEG. Published
         * on loopback only: this is a full remote-control channel into a browser and
         * has no business on the network.
         */
        '-p', '127.0.0.1:9222-9271:9222-9271',
        IMAGE,
      ], { timeout: 60_000 })
      return null
    } catch (err) {
      return err instanceof Error ? err.message : String(err)
    }
  }

  private async dockerAvailable(): Promise<boolean> {
    try {
      await run(dockerBinary(), ['info', '--format', '{{.ServerVersion}}'], { timeout: 8_000 })
      return true
    } catch {
      return false
    }
  }

  /**
   * Builds the desktop image from the Dockerfile that ships with the core.
   *
   * "Install the app; it does the rest" has to include this, or the first bot with a
   * screen ends at a message quoting a docker command. The Dockerfile is found by
   * walking up from this module, which lands on `containers/desktop` from a checkout,
   * a `dist` build, and a Homebrew `libexec` alike. A build is a couple of minutes of
   * apt-get; it runs once, and `ensure` already serialises callers so two bots asking
   * at once wait on the same build.
   */
  private async buildImage(): Promise<string | null> {
    let dir = dirname(fileURLToPath(import.meta.url))
    let dockerfileDir: string | null = null
    for (let up = 0; up < 6; up++) {
      const candidate = join(dir, 'containers', 'desktop')
      if (existsSync(join(candidate, 'Dockerfile'))) { dockerfileDir = candidate; break }
      dir = dirname(dir)
    }
    if (!dockerfileDir) {
      return 'The desktop image is missing and its Dockerfile is not with this core. Build it with: docker build -t routi-desktop containers/desktop'
    }
    console.log(`building the desktop image from ${dockerfileDir} (a few minutes, once)`)
    this.building = true
    try {
      await run(dockerBinary(), ['build', '-t', IMAGE, dockerfileDir], { timeout: 15 * 60_000, maxBuffer: 64 * 1024 * 1024 })
      console.log('desktop image built')
      return null
    } catch (err) {
      const detail = err instanceof Error ? err.message.split('\n').slice(-3).join(' ') : String(err)
      return `Building the desktop image failed: ${detail}`
    } finally {
      this.building = false
    }
  }

  private async imageExists(): Promise<boolean> {
    try {
      const { stdout } = await run(dockerBinary(), ['images', '-q', IMAGE], { timeout: 8_000 })
      return stdout.trim().length > 0
    } catch {
      return false
    }
  }

  async isRunning(): Promise<boolean> {
    try {
      const { stdout } = await run(dockerBinary(), [
        'ps', '--filter', `name=^/${CONTAINER}$`, '--filter', 'status=running', '-q',
      ], { timeout: 8_000 })
      return stdout.trim().length > 0
    } catch {
      return false
    }
  }

  async exec(args: string[], timeout = 20_000): Promise<string> {
    const { stdout } = await run(dockerBinary(), ['exec', CONTAINER, ...args], { timeout })
    return stdout.trim()
  }

  /** As `exec`, with DISPLAY set so the command lands on one bot's screen. */
  async execOn(display: string, args: string[], timeout = 20_000): Promise<string> {
    const { stdout } = await run(dockerBinary(), ['exec', '-e', `DISPLAY=${display}`, CONTAINER, ...args], {
      timeout,
    })
    return stdout.trim()
  }

  spawnOn(display: string, command: string) {
    return spawn(dockerBinary(), ['exec', '-e', `DISPLAY=${display}`, CONTAINER, 'bash', '-lc', command])
  }
}

const host = new Host()

/** The machine as a whole, for setup and Settings: what state it is in, and bring it up. */
export const desktopHost = {
  describe: (): Promise<HostStatus> => host.describe(),
  /** Builds the image if needed and starts the machine. Resolves to a reason on failure. */
  prepare: (): Promise<string | null> => host.ensure(),
}

/**
 * One bot's screen.
 *
 * Holds a display number rather than a container. `claim` remains: within a single
 * screen, turns still take the pointer in order.
 */
export class Desktop {
  private state: DesktopState = 'stopped'
  private detail: string | undefined
  private display: string | null = null
  /** When the display was last confirmed to exist, not merely remembered. */
  private verifiedAt = 0
  private width = 1280
  private height = 800

  /** Conversation currently allowed to send input, if any. */
  private heldBy: string | null = null

  constructor(readonly botId: string) {}

  async status(): Promise<DesktopStatus> {
    /**
     * Remembering a screen is not the same as having one.
     *
     * A display can go without this object hearing: the container is rebuilt, Docker
     * restarts, something inside it dies. Reporting the remembered state meant a bot
     * was told it had a screen, called screenshot, and got "could not capture" —
     * repeatedly, with nothing anywhere saying the screen was gone.
     *
     * So a running screen is re-confirmed against the machine, throttled to once every
     * few seconds because this is asked far more often than a display disappears.
     */
    const stale = Date.now() - this.verifiedAt > 5_000
    const machineUp = (this.display === null || stale) ? await host.isRunning() : true
    if ((this.display === null || stale) && !machineUp && (this.state === 'running' || this.state === 'starting')) {
      // Docker was quit, or the machine with it. A screen remembered as running is
      // not running; say so now rather than after the next screenshot fails.
      this.display = null
      this.state = 'stopped'
      this.verifiedAt = Date.now()
    }
    if ((this.display === null || stale) && machineUp) {
      const found = await host.exec(['screenctl', 'live', this.botId]).catch(() => '')
      this.verifiedAt = Date.now()
      if (found) {
        if (this.display !== `:${found}`) {
          this.display = `:${found}`
          await this.readGeometry()
        }
        this.state = 'running'
      } else if (this.state === 'running') {
        // It was there and now is not. Say so, and let whoever is watching start one.
        this.display = null
        this.state = 'stopped'
      }
    }

    if (this.state === 'running' || this.state === 'starting') {
      return { state: this.state, width: this.width, height: this.height, detail: this.detail }
    }

    const failure = await host.ensure()
    if (failure) {
      return { state: 'unavailable', width: this.width, height: this.height, detail: failure }
    }
    return { state: this.state, width: this.width, height: this.height }
  }

  /** Idempotent: safe to call on every attach. */
  async start(): Promise<DesktopStatus> {
    if (this.state === 'running' && this.display) return this.status()

    this.state = 'starting'
    const failure = await host.ensure()
    if (failure) {
      this.state = 'unavailable'
      this.detail = failure
      return { state: 'unavailable', width: this.width, height: this.height, detail: failure }
    }

    try {
      // screenctl waits for the display itself and prints its number.
      const number = await host.exec(['screenctl', 'start', this.botId], 90_000)
      if (!/^\d+$/.test(number)) throw new Error(number || 'no display number')
      this.display = `:${number}`
      this.state = 'running'
      this.detail = undefined
      this.verifiedAt = Date.now()
      await this.readGeometry()
    } catch (err) {
      this.state = 'unavailable'
      this.detail = err instanceof Error ? err.message : String(err)
    }
    return this.status()
  }

  /** Every bot id with a screen on the machine, whether or not the bot still exists. */
  async listScreens(): Promise<string[]> {
    if (!(await host.isRunning())) return []
    const out = await host.exec(['screenctl', 'list']).catch(() => '')
    return out
      .split('\n')
      .map((line) => line.trim().split(/\s+/)[0] ?? '')
      .filter(Boolean)
  }

  /** Stops this bot's screen. The machine stays up for everyone else. */
  async stop(): Promise<void> {
    this.heldBy = null
    this.state = 'stopped'
    this.display = null
    this.verifiedAt = 0
    // Told unconditionally, not only when a display is remembered. A freshly made
    // object has never seen one, which is exactly the case when stopping a screen whose
    // bot is gone — so the early return meant orphans could never be cleaned up by the
    // one thing written to clean them up.
    await host.exec(['screenctl', 'stop', this.botId], 30_000).catch(() => {})
  }

  private async readGeometry(): Promise<void> {
    if (!this.display) return
    try {
      const out = await host.execOn(this.display, ['xdpyinfo'], 8_000)
      const match = /dimensions:\s+(\d+)x(\d+)/.exec(out)
      if (match) {
        this.width = Number(match[1])
        this.height = Number(match[2])
      }
    } catch {
      // Keep the defaults; geometry is a nicety, not a blocker.
    }
  }

  // --------------------------------------------------------------- capture

  /**
   * A single frame as a JPEG, with the pointer's position.
   *
   * Deliberately a pull, not a push: the panel is a small preview, and the client asks
   * for frames at whatever rate it can actually draw. That keeps an idle window from
   * costing anything and avoids a stream nobody is watching.
   *
   * The pointer comes along because an X screenshot does not contain it — `import`
   * captures the root window's pixels and the cursor is drawn by the server on top, so
   * a frame alone can never show where the pointer is. Both come from one exec: the
   * location is printed as a line first, and the JPEG's own SOI marker says where the
   * text ends and the image begins.
   */
  async captureFrame(quality = 6): Promise<{ jpeg: Buffer; pointer: { x: number; y: number } | null } | null> {
    if (this.state !== 'running' || !this.display) return null
    const display = this.display

    return new Promise((resolve) => {
      const child = host.spawnOn(
        display,
        'eval $(xdotool getmouselocation --shell); echo "$X $Y"; ' +
          `import -window root -quality ${quality * 10} jpeg:-`,
      )
      const chunks: Buffer[] = []
      child.stdout.on('data', (c: Buffer) => chunks.push(c))
      child.on('error', () => resolve(null))
      child.on('close', (code) => {
        // A capture that fails is the first sign a screen has gone; make the next
        // status check confirm rather than trust what is remembered.
        if (code !== 0 || chunks.length === 0) {
          this.verifiedAt = 0
          return resolve(null)
        }
        const all = Buffer.concat(chunks)
        const start = all.indexOf(Buffer.from([0xff, 0xd8]))
        if (start < 0) return resolve(null)

        const header = all.subarray(0, start).toString('ascii').trim().split(/\s+/)
        const x = Number(header[0])
        const y = Number(header[1])
        resolve({
          jpeg: all.subarray(start),
          pointer: Number.isFinite(x) && Number.isFinite(y) ? { x, y } : null,
        })
      })
    })
  }

  // ----------------------------------------------------------------- input

  /**
   * Claims the pointer for one conversation.
   *
   * Two turns on the same screen would interleave clicks and both fail confusingly.
   * The holder is released when its turn ends.
   */
  claim(conversationId: string): boolean {
    if (this.heldBy && this.heldBy !== conversationId) return false
    this.heldBy = conversationId
    return true
  }

  release(conversationId: string): void {
    if (this.heldBy === conversationId) this.heldBy = null
  }

  get holder(): string | null {
    return this.heldBy
  }

  /**
   * Where this screen's browser answers DevTools, or null when no screen is up.
   *
   * Derived from the display number rather than discovered, so it is knowable before
   * the browser has started and stays the same across restarts of it.
   */
  get cdpPort(): number | null {
    if (!this.display) return null
    const n = Number(this.display.slice(1))
    return Number.isFinite(n) ? 9222 + (n - 99) : null
  }

  /** What is on the desktop's clipboard, for copying out of it. */
  async readClipboard(): Promise<string> {
    if (this.state !== 'running' || !this.display) return ''
    return host.execOn(this.display, ['act', 'clipget'], 10_000).catch(() => '')
  }

  async send(input: DesktopInput): Promise<void> {
    if (this.state !== 'running' || !this.display) throw new Error('This bot has no screen running.')

    const args = ((): string[] => {
      switch (input.kind) {
        case 'click': return ['click', String(input.x), String(input.y), String(input.button ?? 1)]
        case 'doubleClick': return ['dblclick', String(input.x), String(input.y)]
        case 'move': return ['move', String(input.x), String(input.y)]
        case 'scroll': return ['scroll', String(input.x), String(input.y), String(input.amount), '3']
        case 'type': return ['type', input.text]
        case 'key': return ['key', ...input.keys]
        case 'open': return ['open', input.url]
        case 'paste': return ['clipset', input.text]
      }
    })()

    await host.execOn(this.display, ['act', ...args])

    // Pasting is two steps: the text has to be on the clipboard before the keystroke
    // that reads it. Typing it out instead loses newlines and tabs, and takes a
    // visible age on anything longer than a sentence.
    if (input.kind === 'paste') {
      await host.execOn(this.display, ['act', 'key', 'ctrl+v'])
    }
  }
}
