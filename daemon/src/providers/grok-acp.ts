import { spawn, type ChildProcess } from 'node:child_process'

/**
 * A JSON-RPC client for `grok agent stdio`.
 *
 * Grok Build speaks ACP — the Agent Client Protocol that editors use to embed an
 * agent — and that is the richest surface it has: token-level text, a separate
 * thought stream, tool calls with their arguments and results, and MCP servers the
 * client hands it. Headless `grok -p` would have been less code and would have
 * flattened all of that into one blob of stdout.
 *
 * The other half of the reason is the same as on the Codex side: the agent asks
 * before a tool it did not bring itself runs, and the question comes back over this
 * connection as a request. Something has to answer it. A client that cannot say yes
 * leaves a bot standing next to a screen it has been told it may not touch.
 */

type Json = Record<string, unknown>

export interface AcpEvent {
  method: string
  params: Json
}

/** The name Krog's tools are mounted under, and so the prefix on their tool ids. */
export const KROG_MCP_SERVER = 'krog'

export interface GrokAcpOptions {
  binary: string
  env: Record<string, string>
  /** Called for every agent notification; the adapter turns these into blocks. */
  onEvent: (event: AcpEvent) => void
}

export class GrokAcp {
  private child: ChildProcess | null = null
  private seq = 0
  private buffer = ''
  private readonly pending = new Map<number, { resolve: (v: Json) => void; reject: (e: Error) => void }>()
  private starting: Promise<void> | null = null

  constructor(private readonly opts: GrokAcpOptions) {}

  /** Starts the process and completes the handshake. Idempotent. */
  async ready(): Promise<void> {
    this.starting ??= this.start()
    return this.starting
  }

  private async start(): Promise<void> {
    const child = spawn(this.opts.binary, ['agent', 'stdio'], {
      env: this.opts.env,
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    this.child = child

    child.stdout?.setEncoding('utf8')
    child.stdout?.on('data', (chunk: string) => this.consume(chunk))
    child.on('exit', () => {
      for (const waiter of this.pending.values()) waiter.reject(new Error('Grok exited.'))
      this.pending.clear()
      this.child = null
      this.starting = null
    })

    await this.request('initialize', {
      protocolVersion: 1,
      // Stated honestly: Krog gives a bot a screen, not this Mac's filesystem or a
      // terminal on it. Claiming these would invite requests that would be refused.
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
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

    // A method *and* an id means the agent is asking us something.
    if (method && id !== undefined && id !== null) {
      this.answerAgentRequest(method, id, (message['params'] ?? {}) as Json)
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
    if (error) waiter.reject(new Error(error.message ?? 'Grok returned an error.'))
    else waiter.resolve((message['result'] ?? {}) as Json)
  }

  /**
   * Answers the questions Grok would otherwise put to a human.
   *
   * Krog's own tools are approved: the user granted that by giving the bot a screen,
   * and a prompt per click would make any real task unusable. Everything else is
   * refused — a bot here is not meant to be running commands or editing files on the
   * Mac hosting the core, so a request to do so is a mistake rather than something to
   * wave through. `--always-approve` would have been one flag and would have said yes
   * to the shell too.
   *
   * When there is a UI for this, it goes here.
   */
  private answerAgentRequest(method: string, id: unknown, params: Json): void {
    if (method === 'session/request_permission') {
      const options = (params['options'] ?? []) as { optionId?: string; kind?: string }[]
      const wanted = isKrogTool(params['toolCall'] as Json | undefined)
        // Always, not once: the same bot calls the same screen verbs dozens of times
        // in a turn, and each round trip is a stall in front of the user.
        ? ['allow_always', 'allow_once']
        : ['reject_once', 'reject_always']
      const chosen = wanted
        .map((kind) => options.find((option) => option.kind === kind))
        .find((option) => option?.optionId)
      if (chosen?.optionId) {
        this.reply(id, { outcome: { outcome: 'selected', optionId: chosen.optionId } })
      } else {
        // No option we recognise. Cancelling is the one answer that cannot approve
        // something by accident.
        this.reply(id, { outcome: { outcome: 'cancelled' } })
      }
      return
    }

    // Krog declares neither capability, so these should never arrive; if one does,
    // an error is the honest answer and it keeps the turn moving.
    if (method.startsWith('fs/') || method.startsWith('terminal/')) {
      this.fail(id, `Krog does not offer ${method}.`)
      return
    }
    this.reply(id, {})
  }

  private reply(id: unknown, result: unknown): void {
    this.child?.stdin?.write(`${JSON.stringify({ jsonrpc: '2.0', id, result })}\n`)
  }

  private fail(id: unknown, message: string): void {
    const error = { code: -32601, message }
    this.child?.stdin?.write(`${JSON.stringify({ jsonrpc: '2.0', id, error })}\n`)
  }

  /**
   * Sends a request. `timeoutMs` of zero waits as long as it takes.
   *
   * Which `session/prompt` needs, and did not get. A prompt resolves when the whole
   * turn is over, so the timeout was a cap on how long a bot may work — and a bot
   * booking a hotel spent eleven minutes clicking through a travel site before the
   * ten-minute cap called it a failure, on top of work that was going fine. Setup
   * calls keep a bound because a handshake that hangs is broken; a turn that takes
   * an hour is a turn, and the way to end one early is the stop button, which sends
   * `session/cancel`. A crashed agent still fails everything pending on exit.
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
      this.child?.stdin?.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`)
    })
  }

  /** Fire-and-forget, for the notifications ACP defines — cancelling a turn. */
  notify(method: string, params: unknown): void {
    this.child?.stdin?.write(`${JSON.stringify({ jsonrpc: '2.0', method, params })}\n`)
  }

  dispose(): void {
    this.child?.kill()
    this.child = null
    this.starting = null
  }
}

/**
 * The tool a call is really for.
 *
 * Grok does not offer MCP tools to the model directly. It hides them behind two of
 * its own — `search_tool` to find one, `use_tool` to run it — so the call that lands
 * here is `use_tool` and the tool the user would recognise is an argument to it. The
 * title carries the same name once the agent has resolved it, which is what makes
 * both worth reading.
 */
export function toolTargetOf(toolCall: Json | undefined): string {
  if (!toolCall) return ''
  const input = (toolCall['rawInput'] ?? {}) as Json
  const named = input['tool_name']
  if (typeof named === 'string' && named) return named
  const title = toolCall['title']
  return typeof title === 'string' ? title : ''
}

/** Whether a tool call is one Krog served. */
export function isKrogTool(toolCall: Json | undefined): boolean {
  return toolTargetOf(toolCall).startsWith(`${KROG_MCP_SERVER}__`)
}
