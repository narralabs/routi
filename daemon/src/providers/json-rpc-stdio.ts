import { spawn, type ChildProcess } from 'node:child_process'

/**
 * Line-delimited JSON-RPC over a child process's stdin and stdout.
 *
 * Both agent CLIs Routi drives speak this — Codex through its app-server, Grok through
 * ACP — and both send requests *back*: an approval to grant, a file to read, a
 * permission to decide. That is the whole reason to hold the connection rather than
 * use a vendor SDK, and it is the same reason on both sides, so it is one class. What
 * differs is only what each vendor asks and what the answer should be, and that is
 * the one method a subclass supplies.
 */

export type Json = Record<string, unknown>

export interface RpcEvent {
  method: string
  params: Json
}

export interface JsonRpcStdioOptions {
  binary: string
  args: string[]
  env: Record<string, string>
  /** What to call the other side in errors: "Codex", "Grok". */
  name: string
  /** Called for every notification; the adapter turns these into blocks. */
  onEvent: (event: RpcEvent) => void
}

export abstract class JsonRpcStdio {
  private child: ChildProcess | null = null
  private seq = 0
  private buffer = ''
  private readonly pending = new Map<number, { resolve: (v: Json) => void; reject: (e: Error) => void }>()
  private starting: Promise<void> | null = null

  constructor(protected readonly opts: JsonRpcStdioOptions) {}

  /** The handshake this protocol opens with. Runs once, after the process is up. */
  protected abstract handshake(): Promise<void>

  /**
   * Answers a request the agent sent us. The vendor-specific half: which tools to
   * approve, which capabilities to refuse, in the shape each protocol expects.
   */
  protected abstract answer(method: string, params: Json): { result: unknown } | { error: string }

  /** Starts the process and completes the handshake. Idempotent. */
  async ready(): Promise<void> {
    this.starting ??= this.start()
    return this.starting
  }

  private async start(): Promise<void> {
    const child = spawn(this.opts.binary, this.opts.args, {
      env: this.opts.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    this.child = child

    child.stdout?.setEncoding('utf8')
    child.stdout?.on('data', (chunk: string) => this.consume(chunk))
    child.on('exit', () => {
      // Anything still waiting will never be answered; fail it rather than hang.
      for (const waiter of this.pending.values()) waiter.reject(new Error(`${this.opts.name} exited.`))
      this.pending.clear()
      this.child = null
      this.starting = null
    })

    await this.handshake()
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

    // A method *and* an id means the other side is asking us something.
    if (method && id !== undefined && id !== null) {
      const reply = this.answer(method, (message['params'] ?? {}) as Json)
      if ('error' in reply) this.write({ jsonrpc: '2.0', id, error: { code: -32601, message: reply.error } })
      else this.write({ jsonrpc: '2.0', id, result: reply.result })
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
    if (error) waiter.reject(new Error(error.message ?? `${this.opts.name} returned an error.`))
    else waiter.resolve((message['result'] ?? {}) as Json)
  }

  /**
   * Sends a request. `timeoutMs` of zero waits as long as it takes.
   *
   * Setup calls keep a bound, because a handshake that hangs is broken. A turn does
   * not: it resolves when the agent says it is over, a bot booking a hotel can take
   * eleven minutes doing it, and the way to end one early is the stop button. A
   * crashed agent still fails everything pending on exit.
   */
  request(method: string, params: unknown, timeoutMs = 600_000): Promise<Json> {
    const id = ++this.seq
    return new Promise<Json>((resolve, reject) => {
      const timer = timeoutMs > 0
        ? setTimeout(() => {
            this.pending.delete(id)
            reject(new Error(`${method} timed out`))
          }, timeoutMs)
        : undefined
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v) },
        reject: (e) => { clearTimeout(timer); reject(e) },
      })
      this.write({ jsonrpc: '2.0', id, method, params })
    })
  }

  /** Fire-and-forget, for the notifications a protocol defines — cancelling a turn. */
  notify(method: string, params: unknown): void {
    this.write({ jsonrpc: '2.0', method, params })
  }

  private write(message: unknown): void {
    this.child?.stdin?.write(`${JSON.stringify(message)}\n`)
  }

  dispose(): void {
    this.child?.kill()
    this.child = null
    this.starting = null
  }
}
