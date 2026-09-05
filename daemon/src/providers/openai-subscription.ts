import { existsSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { CodexAppServer, type AppServerEvent } from './codex-app-server.js'
import type { AccountInfo, Block, ModelInfo } from '@krog/protocol'
import { sessionKey } from './types.js'
import type { ChatRequest, ProviderAdapter, ProviderEvent } from './types.js'

/**
 * OpenAI through a personal ChatGPT account, via the Codex CLI.
 *
 * The mirror of the Anthropic subscription adapter, and it exists for the same
 * reason: a plan someone already pays for should be spendable without a second,
 * metered bill. Krog never handles the credential — the Codex CLI holds it, and the
 * SDK drives that CLI.
 *
 * Threads are warm and per-conversation, like the Claude sessions: Codex keeps the
 * history itself under a thread id, so `req.history` is deliberately ignored rather
 * than replayed — the model's own context is better than a reconstruction of it.
 */

/**
 * Codex resolves the model itself from the account's plan, so `default` is a real
 * choice here rather than a placeholder: it means "whatever this plan gives you",
 * which keeps working when OpenAI ships something new.
 */
const MODELS: ModelInfo[] = [
  {
    id: 'default',
    // Phrased as an instruction, because in the picker it is one.
    displayName: 'Let Codex decide',
    statusName: 'Model chosen by Codex',
    description:
      'Codex selects the model from your ChatGPT plan at run time and does not report ' +
      'which. Pick a named model below if you want to know exactly what answered.',
    effortLevels: ['low', 'medium', 'high', 'xhigh'],
    // Codex decides, and no event reports it, so claiming a level would be a guess.
    defaultEffort: null,
  },
  {
    id: 'gpt-5.2-codex',
    displayName: 'GPT-5.2 Codex',
    description: 'Tuned for long agentic work. Named explicitly, so the transcript can say so.',
    resolvedModel: 'gpt-5.2-codex',
    effortLevels: ['low', 'medium', 'high', 'xhigh'],
    defaultEffort: null,
  },
]



/**
 * A Codex home belonging to Krog rather than to whoever owns this Mac.
 *
 * Codex reads ~/.codex/config.toml, and a person who uses Codex has a lot in there:
 * bundled plugins for the browser, documents and spreadsheets, their own MCP servers,
 * their own skills. Every Krog bot was inheriting the lot — which is how a bot asked
 * about flight prices ended up invoking a personal browser-control skill and reading
 * app bundles off the disk. A bot's abilities should come from Krog and its
 * description, not from the operator's toolbox.
 *
 * The same failure as on the Anthropic side, where a bot introduced itself as the
 * operator's MCP tooling until `settingSources: []` shut that door. This is that door.
 *
 * The login is the one thing worth keeping, so auth.json is linked rather than copied:
 * signing in or out with the CLI stays in effect, and Krog never holds a copy of the
 * credential.
 */
function isolatedCodexHome(dataDir: string): string {
  const home = join(dataDir, 'codex')
  mkdirSync(home, { recursive: true })

  // Rewritten every start: this file is Krog's statement of what a bot may use, and it
  // should not drift because something once wrote to it.
  writeFileSync(
    join(home, 'config.toml'),
    [
      '# Written by Krog. A bot gets its abilities from Krog and its own description,',
      '# never from the personal Codex setup on this machine.',
      '',
    ].join('\n'),
  )

  const link = join(home, 'auth.json')
  const real = join(homedir(), '.codex', 'auth.json')
  try {
    rmSync(link, { force: true })
    if (existsSync(real)) symlinkSync(real, link)
  } catch {
    // Without the link Codex reports itself signed out, which the auth status already
    // surfaces — better than failing to start the daemon.
  }
  return home
}

export class OpenAiSubscriptionAdapter implements ProviderAdapter {
  readonly id = 'openai'
  readonly supportsSurface = true

  private server: CodexAppServer | null = null
  private readonly env: Record<string, string>
  /** Conversation to Codex thread, so a reply continues where the last one stopped. */
  private readonly threads = new Map<string, string>()
  /** The reverse, for routing an event back to the turn that is waiting on it. */
  private readonly threadOwners = new Map<string, string>()
  private readonly listeners = new Map<string, (event: AppServerEvent) => void>()

  constructor(
    private readonly opts: { cwd: string; dataDir: string; mcpBaseUrl: string; apiKey?: string },
  ) {
    const home = isolatedCodexHome(opts.dataDir)
    // Given in full because supplying env stops the child inheriting process.env —
    // which is the point. CODEX_HOME moves the agent off the operator's personal Codex
    // setup and onto Krog's own.
    this.env = {
      CODEX_HOME: home,
      PATH: process.env['PATH'] ?? '/usr/local/bin:/usr/bin:/bin',
      HOME: process.env['HOME'] ?? homedir(),
      ...(opts.apiKey ? { OPENAI_API_KEY: opts.apiKey } : {}),
      ...(process.env['TMPDIR'] ? { TMPDIR: process.env['TMPDIR'] } : {}),
    }
  }

  async listModels(): Promise<ModelInfo[]> {
    return MODELS
  }

  async accountInfo(): Promise<AccountInfo> {
    return { authMode: this.opts.apiKey ? 'api_key' : 'subscription' }
  }

  async *stream(req: ChatRequest, signal: AbortSignal): AsyncIterable<ProviderEvent> {
    const prompt = req.input
      .filter((block) => block.type === 'text')
      .map((block) => (block.type === 'text' ? block.text : ''))
      .join('\n')
      .trim()
    if (!prompt) {
      yield { type: 'done', stopReason: 'end_turn', meta: {} }
      return
    }

    // The system prompt already carries the standing policy; Codex takes instructions
    // in the turn rather than as a system role, so it leads here.
    const framed = [req.systemPrompt.trim(), '', prompt].filter(Boolean).join('\n')

    // Events arrive on the server's own schedule, so they queue here and the generator
    // drains them. Without this, anything emitted while the consumer is awaiting would
    // be dropped.
    const queue: ProviderEvent[] = []
    let wake: (() => void) | null = null
    const push = (event: ProviderEvent) => {
      queue.push(event)
      wake?.()
      wake = null
    }

    let index = 0
    const open = new Map<string, { at: number; kind: string }>()
    const meta: Record<string, unknown> = {}
    let finished = false

    const server = await this.serverFor(req, (event) => {
      const item = (event.params['item'] ?? {}) as Record<string, any>

      switch (event.method) {
        case 'item/started': {
          const block = startBlock(item)
          if (!block) break
          const at = index++
          open.set(String(item['id']), { at, kind: block.type })
          push({ type: 'block_start', index: at, block })
          break
        }

        case 'item/agentMessage/delta': {
          const entry = open.get(String(event.params['itemId']))
          if (entry?.kind === 'text') {
            push({ type: 'text_delta', index: entry.at, text: String(event.params['delta'] ?? '') })
          }
          break
        }

        case 'item/reasoning/textDelta':
        case 'item/reasoning/summaryTextDelta': {
          const entry = open.get(String(event.params['itemId']))
          if (entry?.kind === 'thinking') {
            push({ type: 'thinking_delta', index: entry.at, text: String(event.params['delta'] ?? '') })
          }
          break
        }

        case 'item/completed': {
          const entry = open.get(String(item['id']))
          if (!entry) break
          const block = completeBlock(item)
          if (block) push({ type: 'block_end', index: entry.at, block })
          break
        }

        case 'turn/completed': {
          const turn = (event.params['turn'] ?? {}) as Record<string, any>
          if (turn['usage']) meta['usage'] = turn['usage']
          finished = true
          push({ type: 'done', stopReason: 'end_turn', meta })
          break
        }

        case 'turn/failed': {
          finished = true
          const error = (event.params['error'] ?? {}) as Record<string, any>
          push({ type: 'error', code: 'turn_failed', message: String(error['message'] ?? 'The turn failed.') })
          break
        }
      }
    })

    const threadId = await this.threadFor(req, server)
    void server
      .request('turn/start', { threadId, input: [{ type: 'text', text: framed }] })
      .catch((err: unknown) => {
        finished = true
        push({
          type: 'error',
          code: 'stream_failed',
          message: err instanceof Error ? err.message : String(err),
        })
      })

    while (!finished || queue.length > 0) {
      if (signal.aborted) {
        void server.request('turn/interrupt', { threadId }).catch(() => {})
        yield { type: 'done', stopReason: 'interrupted', meta }
        return
      }
      if (queue.length === 0) {
        await new Promise<void>((resolve) => {
          wake = resolve
          setTimeout(resolve, 200)
        })
        continue
      }
      yield queue.shift()!
    }
  }

  /** One app-server process for the adapter, shared by every conversation on it. */
  private async serverFor(
    req: ChatRequest,
    onEvent: (event: AppServerEvent) => void,
  ): Promise<CodexAppServer> {
    this.listeners.set(sessionKey(req), onEvent)

    this.server ??= new CodexAppServer({
      binary: codexBinary(),
      env: this.env,
      // Fanned out by thread: one process serves every conversation, and a turn's
      // events must reach only the turn waiting on them.
      onEvent: (event) => {
        const threadId = String(event.params['threadId'] ?? '')
        const conversationId = this.threadOwners.get(threadId)
        const listener = conversationId ? this.listeners.get(conversationId) : undefined
        listener?.(event)
      },
    })
    await this.server.ready()
    return this.server
  }

  private async threadFor(req: ChatRequest, server: CodexAppServer): Promise<string> {
    const existing = this.threads.get(sessionKey(req))
    if (existing) return existing

    const started = await server.request('thread/start', {
      cwd: this.opts.cwd,
      // Codex asks before calling a tool it did not bring itself, and "never" denies
      // rather than allows. The policy has to permit asking; this client answers,
      // approving Krog's own tools and nothing else.
      approvalPolicy: 'on-request',
      sandbox: 'read-only',
      ...(req.model && req.model !== 'default' ? { model: req.model } : {}),
      ...(req.effort ? { effort: normaliseEffort(req.effort) } : {}),
      config: {
        mcp_servers: { krog: { url: `${this.opts.mcpBaseUrl}/mcp/${req.botId}` } },
      },
    })

    const thread = (started['thread'] ?? {}) as Record<string, unknown>
    const threadId = String(thread['id'] ?? '')
    if (!threadId) throw new Error('Codex did not return a thread.')
    this.threads.set(sessionKey(req), threadId)
    this.threadOwners.set(threadId, sessionKey(req))
    return threadId
  }

  release(conversationId: string): void {
    const threadId = this.threads.get(conversationId)
    if (threadId) this.threadOwners.delete(threadId)
    this.threads.delete(conversationId)
    this.listeners.delete(conversationId)
  }

  dispose(): void {
    this.server?.dispose()
    this.server = null
    this.threads.clear()
    this.threadOwners.clear()
    this.listeners.clear()
  }
}

/**
 * The CLI this SDK was written against, rather than whichever one is on PATH.
 *
 * The SDK drives a separate CLI binary, and the two are versioned together — this
 * machine had 0.153 of the SDK spawning 0.133 from Homebrew, twenty versions apart,
 * which is the kind of gap where a config key the SDK sends is simply not understood
 * by the process reading it. Pinning the bundled one also means a user's own Codex can
 * be any version, or absent, without changing how bots behave.
 */
function codexBinary(): string {
  try {
    return createRequire(import.meta.url).resolve('@openai/codex/bin/codex.js')
  } catch {
    // Falls back to whatever `codex` is on PATH, which is how it worked before.
    return 'codex'
  }
}

/** A thread item that has just appeared, as one of Krog's blocks. */
function startBlock(item: Record<string, any>): Block | null {
  switch (item['type']) {
    case 'agentMessage':
      return { type: 'text', text: '' }
    case 'reasoning':
      return { type: 'thinking', text: '' }
    case 'mcpToolCall':
      return {
        type: 'tool_use',
        id: String(item['id'] ?? ''),
        name: String(item['tool'] ?? 'tool'),
        input: item['arguments'],
        status: 'running',
      }
    case 'webSearch':
      return {
        type: 'tool_use',
        id: String(item['id'] ?? ''),
        name: 'WebSearch',
        input: { query: item['query'] },
        status: 'running',
      }
    // Codex's own coding-agent work — commands, plans, file edits — is not chat.
    default:
      return null
  }
}

/** The same item once it has finished. */
function completeBlock(item: Record<string, any>): Block | null {
  const status = String(item['status'] ?? '')
  const done = status === 'failed' ? 'error' : 'done'

  switch (item['type']) {
    case 'agentMessage':
      return { type: 'text', text: String(item['text'] ?? '') }
    case 'reasoning':
      return { type: 'thinking', text: String(item['text'] ?? '') }
    case 'mcpToolCall':
      return {
        type: 'tool_use',
        id: String(item['id'] ?? ''),
        name: String(item['tool'] ?? 'tool'),
        input: item['arguments'],
        status: done,
      }
    case 'webSearch':
      return {
        type: 'tool_use',
        id: String(item['id'] ?? ''),
        name: 'WebSearch',
        input: { query: item['query'] },
        status: done,
        title: String(item['query'] ?? ''),
      }
    default:
      return null
  }
}

function normaliseEffort(effort: string): 'low' | 'medium' | 'high' | 'xhigh' {
  if (effort === 'low') return 'low'
  if (effort === 'medium') return 'medium'
  if (effort === 'max') return 'xhigh'
  return effort === 'xhigh' ? 'xhigh' : 'high'
}
