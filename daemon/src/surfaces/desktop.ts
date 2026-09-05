import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'

const run = promisify(execFile)

const IMAGE = 'krog-desktop:latest'
const CONTAINER = 'krog-desktop'

export type DesktopState = 'stopped' | 'starting' | 'running' | 'unavailable'

export interface DesktopStatus {
  state: DesktopState
  width: number
  height: number
  /** Why the desktop can't run, when it can't. */
  detail?: string
}

export type PointerButton = 1 | 2 | 3

export type DesktopInput =
  | { kind: 'click'; x: number; y: number; button?: PointerButton }
  | { kind: 'doubleClick'; x: number; y: number }
  | { kind: 'move'; x: number; y: number }
  | { kind: 'scroll'; x: number; y: number; amount: number }
  | { kind: 'type'; text: string }
  | { kind: 'key'; keys: string[] }
  | { kind: 'open'; url: string }

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
      return 'Docker is not running on this Mac. Start Docker Desktop, then try again.'
    }
    if (!(await this.imageExists())) {
      return 'The desktop image is missing. Build it with: docker build -t krog-desktop containers/desktop'
    }
    if (await this.isRunning()) return null

    // Remove any stopped container of the same name; `docker run` refuses otherwise.
    await run('docker', ['rm', '-f', CONTAINER], { timeout: 20_000 }).catch(() => {})

    try {
      await run('docker', [
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
      await run('docker', ['info', '--format', '{{.ServerVersion}}'], { timeout: 8_000 })
      return true
    } catch {
      return false
    }
  }

  private async imageExists(): Promise<boolean> {
    try {
      const { stdout } = await run('docker', ['images', '-q', IMAGE], { timeout: 8_000 })
      return stdout.trim().length > 0
    } catch {
      return false
    }
  }

  async isRunning(): Promise<boolean> {
    try {
      const { stdout } = await run('docker', [
        'ps', '--filter', `name=^/${CONTAINER}$`, '--filter', 'status=running', '-q',
      ], { timeout: 8_000 })
      return stdout.trim().length > 0
    } catch {
      return false
    }
  }

  async exec(args: string[], timeout = 20_000): Promise<string> {
    const { stdout } = await run('docker', ['exec', CONTAINER, ...args], { timeout })
    return stdout.trim()
  }

  /** As `exec`, with DISPLAY set so the command lands on one bot's screen. */
  async execOn(display: string, args: string[], timeout = 20_000): Promise<string> {
    const { stdout } = await run('docker', ['exec', '-e', `DISPLAY=${display}`, CONTAINER, ...args], {
      timeout,
    })
    return stdout.trim()
  }

  spawnOn(display: string, command: string) {
    return spawn('docker', ['exec', '-e', `DISPLAY=${display}`, CONTAINER, 'bash', '-lc', command])
  }
}

const host = new Host()

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
  private width = 1280
  private height = 800

  /** Conversation currently allowed to send input, if any. */
  private heldBy: string | null = null

  constructor(readonly botId: string) {}

  async status(): Promise<DesktopStatus> {
    // A daemon restart forgets which display belongs to this bot while the screen
    // itself keeps running, so ask the machine before concluding anything.
    if (this.display === null && (await host.isRunning())) {
      const found = await host.exec(['screenctl', 'live', this.botId]).catch(() => '')
      if (found) {
        this.display = `:${found}`
        this.state = 'running'
        await this.readGeometry()
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
      await this.readGeometry()
    } catch (err) {
      this.state = 'unavailable'
      this.detail = err instanceof Error ? err.message : String(err)
    }
    return this.status()
  }

  /** Stops this bot's screen. The machine stays up for everyone else. */
  async stop(): Promise<void> {
    this.heldBy = null
    this.state = 'stopped'
    const display = this.display
    this.display = null
    if (!display) return
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
        if (code !== 0 || chunks.length === 0) return resolve(null)
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
      }
    })()

    await host.execOn(this.display, ['act', ...args])
  }
}
