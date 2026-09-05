import { spawn, type ChildProcess } from 'node:child_process'

/**
 * A JSON-RPC client for `codex app-server`.
 *
 * The SDK's thread API only lets a caller *set* an approval policy, never answer one —
 * its event union has no approval event at all. That is fatal here, because Codex asks
 * before every call to a tool it did not bring itself, and a policy of "never" denies
 * rather than allows. Bots ended up telling users they had no browser while their
 * screen sat running.
 *
 * The app-server speaks the same protocol in both directions: it sends requests back,
 * and this answers them. That is the whole reason for dropping down a level. Two things
 * come free with it — token-level streaming, where the SDK only reported whole
 * messages, and a place to put an approval UI later, since every request Codex would
 * have shown a human now arrives here first.
 */

type Json = Record<string, unknown>

export interface AppServerEvent {
  method: string
  params: Json
}

export interface CodexAppServerOptions {
  binary: string
  env: Record<string, string>
  /** Called for every server notification; the adapter turns these into blocks. */
  onEvent: (event: AppServerEvent) => void
}

export class CodexAppServer {
  private child: ChildProcess | null = null
  private seq = 0
  private buffer = ''
  private readonly pending = new Map<number, { resolve: (v: Json) => void; reject: (e: Error) => void }>()
  private starting: Promise<void> | null = null

  constructor(private readonly opts: CodexAppServerOptions) {}

  /** Starts the process and completes the handshake. Idempotent. */
  async ready(): Promise<void> {
    this.starting ??= this.start()
    return this.starting
  }

  private async start(): Promise<void> {
    const child = spawn(this.opts.binary, ['app-server'], {
      env: this.opts.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    this.child = child

    child.stdout?.setEncoding('utf8')
    child.stdout?.on('data', (chunk: string) => this.consume(chunk))
    child.on('exit', () => {
      // Anything still waiting will never be answered; fail it rather than hang.
      for (const waiter of this.pending.values()) waiter.reject(new Error('Codex exited.'))
      this.pending.clear()
      this.child = null
      this.starting = null
    })

    await this.request('initialize', {
      clientInfo: { name: 'krog', title: 'Krog', version: '0.0.1' },
    })
  }

  private consume(chunk: string): void {
    this.buffer += chunk
    let index = this.buffer.indexOf('\n')
    while (index >= 0) {
      const line = this.buffer.slice(0, index).trim()
      this.buffer = this.buffer.slice(index + 1)
      if (line) {
        try {
          this.route(JSON.parse(line) as Json)
        } catch {
          // Not JSON, not ours.
        }
      }
      index = this.buffer.indexOf('\n')
    }
  }

  private route(message: Json): void {
    const method = message['method'] as string | undefined
    const id = message['id']

    // A method *and* an id means the server is asking us something.
    if (method && id !== undefined && id !== null) {
      this.answerServerRequest(method, id, (message['params'] ?? {}) as Json)
      return
    }
    if (method) {
      this.opts.onEvent({ method, params: (message['params'] ?? {}) as Json })
      return
    }

    const waiter = typeof id === 'number' ? this.pending.get(id) : undefined
    if (!waiter) return
    this.pending.delete(id as number)
    const error = message['error'] as { message?: string } | undefined
    if (error) waiter.reject(new Error(error.message ?? 'Codex returned an error.'))
    else waiter.resolve((message['result'] ?? {}) as Json)
  }

  /**
   * Answers the questions Codex would otherwise put to a human.
   *
   * Krog's own tools are approved: the user granted that by giving the bot a screen,
   * and a prompt per click would make any real task unusable. Everything else is
   * declined — a bot here is not meant to be running commands or editing files on this
   * machine, so a request to do so is a mistake rather than something to wave through.
   * When there is a UI for this, it goes here.
   */
  private answerServerRequest(method: string, id: unknown, params: Json): void {
    if (method === 'mcpServer/elicitation/request') {
      const ours = params['serverName'] === 'krog'
      this.reply(id, { action: ours ? 'accept' : 'decline', content: ours ? {} : null, _meta: null })
      return
    }
    if (method.endsWith('/requestApproval') || method.endsWith('Approval')) {
      this.reply(id, { decision: 'denied' })
      return
    }
    // Anything unrecognised gets a shape-agnostic refusal rather than silence, which
    // would stall the turn.
    this.reply(id, {})
  }

  private reply(id: unknown, result: unknown): void {
    this.child?.stdin?.write(`${JSON.stringify({ jsonrpc: '2.0', id, result })}\n`)
  }

  request(method: string, params: unknown, timeoutMs = 600_000): Promise<Json> {
    const id = ++this.seq
    return new Promise<Json>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`${method} timed out`))
      }, timeoutMs)
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v) },
        reject: (e) => { clearTimeout(timer); reject(e) },
      })
      this.child?.stdin?.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`)
    })
  }

  dispose(): void {
    this.child?.kill()
    this.child = null
    this.starting = null
  }
}
