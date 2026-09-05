import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'

const run = promisify(execFile)

const IMAGE = 'krog-desktop:latest'
const DISPLAY = ':99'

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
 * One bot's Linux desktop.
 *
 * A container each, not one shared between them. Bots are given separate jobs and
 * separate errands — one pricing an ice machine, another booking a hotel — and a
 * shared screen would mean they queued for the pointer and read each other's tabs.
 * Isolation also means a bot's logins and cookies are its own, which is the state
 * worth keeping.
 *
 * `claim` remains: within a single desktop, turns still take it in order.
 */
export class Desktop {
  /** Container name, derived from the bot so restarts find the same desktop. */
  private readonly container: string

  constructor(readonly botId: string) {
    this.container = `krog-desktop-${botId}`
  }

  private state: DesktopState = 'stopped'
  private detail: string | undefined
  private width = 1280
  private height = 800

  /** Conversation currently allowed to send input, if any. */
  private heldBy: string | null = null

  async status(): Promise<DesktopStatus> {
    if (this.state === 'running' || this.state === 'starting') {
      return { state: this.state, width: this.width, height: this.height, detail: this.detail }
    }

    if (!(await this.dockerAvailable())) {
      return {
        state: 'unavailable',
        width: this.width,
        height: this.height,
        detail: 'Docker is not running on this Mac. Start Docker Desktop, then try again.',
      }
    }
    if (!(await this.imageExists())) {
      return {
        state: 'unavailable',
        width: this.width,
        height: this.height,
        detail: 'The desktop image is missing. Build it with: docker build -t krog-desktop containers/desktop',
      }
    }
    return { state: this.state, width: this.width, height: this.height }
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

  private async isRunning(): Promise<boolean> {
    try {
      const { stdout } = await run('docker', [
        'ps', '--filter', `name=^/${this.container}$`, '--filter', 'status=running', '-q',
      ], { timeout: 8_000 })
      return stdout.trim().length > 0
    } catch {
      return false
    }
  }

  /** Idempotent: safe to call on every attach. */
  async start(): Promise<DesktopStatus> {
    if (await this.isRunning()) {
      this.state = 'running'
      return this.status()
    }

    const available = await this.dockerAvailable()
    if (!available) return this.status()
    if (!(await this.imageExists())) return this.status()

    this.state = 'starting'
    // Remove any stopped container of the same name; `docker run` refuses otherwise.
    await run('docker', ['rm', '-f', this.container], { timeout: 20_000 }).catch(() => {})

    try {
      await run('docker', [
        'run', '-d',
        '--name', this.container,
        // Chromium needs more than the default 64MB of /dev/shm or it crashes on
        // any real page.
        '--shm-size=1g',
        /**
         * Chromium's own sandbox creates user namespaces, which Docker's default
         * seccomp profile denies — it fails with "Failed to move to new namespace".
         * The alternative is launching with --no-sandbox, which disables Chromium's
         * isolation outright; this keeps it, and leans on the container as the
         * boundary instead. The container is disposable and holds nothing but the
         * desktop, which is what makes that trade acceptable here.
         */
        '--security-opt', 'seccomp=unconfined',
        IMAGE,
      ], { timeout: 60_000 })
    } catch (err) {
      this.state = 'unavailable'
      this.detail = err instanceof Error ? err.message : String(err)
      return this.status()
    }

    // Wait for X rather than sleeping a guess; the desktop is useless before then.
    const deadline = Date.now() + 45_000
    while (Date.now() < deadline) {
      try {
        await run('docker', ['exec', this.container, 'xdpyinfo', '-display', DISPLAY], { timeout: 5_000 })
        this.state = 'running'
        await this.readGeometry()
        return this.status()
      } catch {
        await new Promise((r) => setTimeout(r, 500))
      }
    }

    this.state = 'unavailable'
    this.detail = 'The desktop container started but its display never came up.'
    return this.status()
  }

  async stop(): Promise<void> {
    this.heldBy = null
    this.state = 'stopped'
    await run('docker', ['rm', '-f', this.container], { timeout: 30_000 }).catch(() => {})
  }

  private async readGeometry(): Promise<void> {
    try {
      const { stdout } = await run('docker', ['exec', this.container, 'xdpyinfo', '-display', DISPLAY], {
        timeout: 8_000,
      })
      const match = /dimensions:\s+(\d+)x(\d+)/.exec(stdout)
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
   * A single frame as a JPEG.
   *
   * Deliberately a pull, not a push: the panel is a small preview, and the client
   * asks for frames at whatever rate it can actually draw. That keeps an idle window
   * from costing anything and avoids a stream nobody is watching. A WebRTC transport
   * belongs here later, when the surface becomes interactive at full size.
   */
  async captureFrame(quality = 6): Promise<Buffer | null> {
    if (this.state !== 'running') return null
    return new Promise((resolve) => {
      const child = spawn('docker', [
        'exec', this.container, 'bash', '-lc',
        `DISPLAY=${DISPLAY} import -window root -quality ${quality * 10} jpeg:-`,
      ])
      const chunks: Buffer[] = []
      child.stdout.on('data', (c: Buffer) => chunks.push(c))
      child.on('error', () => resolve(null))
      child.on('close', (code) => {
        resolve(code === 0 && chunks.length > 0 ? Buffer.concat(chunks) : null)
      })
    })
  }

  // ----------------------------------------------------------------- input

  /**
   * Claims the pointer for one conversation.
   *
   * Without this two bots working at once would interleave clicks on a shared screen
   * and both fail confusingly. The holder is released when its turn ends.
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

  async send(input: DesktopInput): Promise<void> {
    if (this.state !== 'running') throw new Error('The desktop is not running.')

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

    await run('docker', ['exec', this.container, 'act', ...args], { timeout: 20_000 })
  }
}
