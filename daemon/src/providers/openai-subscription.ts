import { existsSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { codexBinary } from '../auth/codex-cli.js'
import { CodexAppServer, type AppServerEvent, type CodexAppServerOptions } from './codex-app-server.js'
import type { AccountInfo, Block, ModelInfo } from '@routi/protocol'
import { replayTranscript } from './replay.js'
import { sessionKey } from './types.js'
import type { ChatRequest, ProviderAdapter, ProviderEvent } from './types.js'

/**
 * OpenAI through a personal ChatGPT account, via the Codex CLI.
 *
 * The mirror of the Anthropic subscription adapter, and it exists for the same
 * reason: a plan someone already pays for should be spendable without a second,
 * metered bill. Routi never handles the credential — the Codex CLI holds it, and the
 * SDK drives that CLI.
 *
 * Threads are warm and per-conversation, like the Claude sessions: Codex keeps the
 * history itself under a thread id, so `req.history` is deliberately ignored rather
 * than replayed — the model's own context is better than a reconstruction of it.
 */

/** What `model/list` returns, as much of it as this reads. */
interface CodexModel {
  id: string
  model?: string
  displayName?: string
  description?: string
  hidden?: boolean
  isDefault?: boolean
  supportedReasoningEfforts?: { reasoningEffort: string }[]
  defaultReasoningEffort?: string
}

/** The effort levels Routi's protocol names; Codex also has "ultra", which it does not. */
type EffortLevel = NonNullable<ModelInfo['effortLevels']>[number]
const EFFORT_LEVELS: ReadonlySet<string> = new Set<EffortLevel>(['low', 'medium', 'high', 'xhigh', 'max'])
const isEffortLevel = (e: string): e is EffortLevel => EFFORT_LEVELS.has(e)

/**
 * The account's models, asked of Codex rather than hardcoded.
 *
 * A fixed list of two — "let Codex decide" and one named model — was what shipped,
 * and it was months stale the day it was written: the app server answers
 * `model/list` with the plan's real lineup, each with its reasoning levels and its
 * default, and that is what the picker should show. `default` stays as the first
 * entry, meaning the plan's current default, and names which model that is today so
 * the transcript can say what answered rather than "model chosen by Codex".
 */
function toModelInfo(models: CodexModel[]): ModelInfo[] {
  const visible = models.filter((m) => !m.hidden)
  const preferred = visible.find((m) => m.isDefault) ?? visible[0]
  const efforts = (m: CodexModel | undefined): EffortLevel[] =>
    (m?.supportedReasoningEfforts ?? []).map((e) => e.reasoningEffort).filter(isEffortLevel)
  const defaultEffort = (m: CodexModel | undefined): EffortLevel | null => {
    const e = m?.defaultReasoningEffort
    return e && isEffortLevel(e) ? e : null
  }

  const list: ModelInfo[] = [
    {
      id: 'default',
      displayName: preferred ? `Default (${preferred.displayName ?? preferred.id})` : 'Default',
      description: "Whatever your ChatGPT plan's default is, which keeps working when OpenAI ships something new.",
      ...(preferred ? { resolvedModel: preferred.model ?? preferred.id } : {}),
      effortLevels: efforts(preferred),
      defaultEffort: defaultEffort(preferred),
    },
  ]
  for (const m of visible) {
    list.push({
      id: m.model ?? m.id,
      displayName: m.displayName ?? m.id,
      description: m.description ?? '',
      resolvedModel: m.model ?? m.id,
      effortLevels: efforts(m),
      defaultEffort: defaultEffort(m),
    })
  }
  return list
}

/**
 * A Codex home belonging to Routi rather than to whoever owns this Mac.
 *
 * Codex reads ~/.codex/config.toml, and a person who uses Codex has a lot in there:
 * bundled plugins for the browser, documents and spreadsheets, their own MCP servers,
 * their own skills. Every Routi bot was inheriting the lot — which is how a bot asked
 * about flight prices ended up invoking a personal browser-control skill and reading
 * app bundles off the disk. A bot's abilities should come from Routi and its
 * description, not from the operator's toolbox.
 *
 * The same failure as on the Anthropic side, where a bot introduced itself as the
 * operator's MCP tooling until `settingSources: []` shut that door. This is that door.
 *
 * The login is the one thing worth keeping, so auth.json is linked rather than copied:
 * signing in or out with the CLI stays in effect, and Routi never holds a copy of the
 * credential.
 */
function isolatedCodexHome(dataDir: string, linkLogin = true): string {
  const home = join(dataDir, 'codex')
  mkdirSync(home, { recursive: true })

  // Rewritten every start: this file is Routi's statement of what a bot may use, and it
  // should not drift because something once wrote to it.
  writeFileSync(
    join(home, 'config.toml'),
    [
      '# Written by Routi. A bot gets its abilities from Routi and its own description,',
      '# never from the personal Codex setup on this machine.',
      '',
    ].join('\n'),
  )

  // The default profile borrows the Mac's own Codex login; another profile signs in
  // with CODEX_HOME pointed here, so its auth.json is its own and is left alone.
  if (!linkLogin) return home
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

type AppServer = Pick<CodexAppServer, 'ready' | 'request' | 'dispose'>

export class OpenAiSubscriptionAdapter implements ProviderAdapter {
  readonly id = 'openai'
  readonly supportsSurface = true

  private server: AppServer | null = null
  private readonly env: Record<string, string>
  /** Conversation to Codex thread, so a reply continues where the last one stopped. */
  private readonly threads = new Map<string, string>()
  /** The reverse, for routing an event back to the turn that is waiting on it. */
  private readonly threadOwners = new Map<string, string>()
  private readonly listeners = new Map<string, (event: AppServerEvent) => void>()

  constructor(
    private readonly opts: { cwd: string; dataDir: string; mcpBaseUrl: string; apiKey?: string; ownLogin?: boolean },
    private readonly createServer: (opts: CodexAppServerOptions) => AppServer = (opts) => new CodexAppServer(opts),
  ) {
    const home = isolatedCodexHome(opts.dataDir, !opts.ownLogin)
    // Given in full because supplying env stops the child inheriting process.env —
    // which is the point. CODEX_HOME moves the agent off the operator's personal Codex
    // setup and onto Routi's own.
    this.env = {
      CODEX_HOME: home,
      PATH: process.env['PATH'] ?? '/usr/local/bin:/usr/bin:/bin',
      HOME: process.env['HOME'] ?? homedir(),
      ...(opts.apiKey ? { OPENAI_API_KEY: opts.apiKey } : {}),
      ...(process.env['TMPDIR'] ? { TMPDIR: process.env['TMPDIR'] } : {}),
    }
  }

  async listModels(): Promise<ModelInfo[]> {
    // Ask the authenticated runtime each time; a daemon can outlive model availability.
    const server = await this.serverFor({ conversationId: 'models', botId: 'models' } as ChatRequest, () => {})
    const models: CodexModel[] = []
    let cursor: string | null = null
    const seen = new Set<string>()
    do {
      const answer = await server.request('model/list', { includeHidden: false, cursor }, 30_000) as {
        data: CodexModel[]; nextCursor?: string | null
      }
      models.push(...answer.data)
      cursor = answer.nextCursor ?? null
      if (cursor && seen.has(cursor)) throw new Error('Codex returned a repeated model-list cursor.')
      if (cursor) seen.add(cursor)
    } while (cursor)
    return toModelInfo(models)
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

    const models = await this.listModels()
    const selected = models.find((model) => model.id === (req.model || 'default'))
    if (!selected?.resolvedModel) {
      yield {
        type: 'error', code: 'model_unavailable',
        message: `The model "${req.model || 'default'}" is no longer available for this Codex connection. Choose a supported model from the model menu, then send your message again.`,
      }
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
    let terminalError: string | null = null

    const server = await this.serverFor(req, (event) => {
      if (finished) return
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
          if (turn['status'] === 'failed' || turn['error'] || terminalError) {
            push({ type: 'error', code: 'turn_failed', message: turn['error']?.message ?? terminalError ?? 'The Codex turn failed.' })
          } else {
            push({ type: 'done', stopReason: turn['status'] === 'interrupted' ? 'interrupted' : 'end_turn', meta })
          }
          break
        }

        case 'error':
          // Completion follows even a terminal error. Keep this turn active until
          // then so its completion cannot accidentally finish the next queued turn.
          if (event.params['willRetry'] !== true) {
            const error = (event.params['error'] ?? {}) as Record<string, unknown>
            terminalError = String(error['message'] ?? 'The Codex turn failed.')
          }
          break

        case 'turn/failed': {
          finished = true
          const error = (event.params['error'] ?? {}) as Record<string, any>
          push({ type: 'error', code: 'turn_failed', message: String(error['message'] ?? 'The turn failed.') })
          break
        }
      }
    })

    const { threadId, created } = await this.threadFor(req, server)
    // A thread made partway through a conversation — after a restart — knows none of
    // it, so the transcript leads the first turn. Codex's own thread/resume is not yet
    // driven here; this is the fallback that would follow it.
    const replay = created ? replayTranscript(req.history, req.botId) : null
    const text = replay ? [req.systemPrompt.trim(), '', replay, '', prompt].filter(Boolean).join('\n') : framed
    void server
      .request('turn/start', {
        threadId,
        input: [{ type: 'text', text }],
        // Per turn rather than per thread: the schema puts them here, and a bot
        // switched mid-conversation keeps its thread and answers on the new model.
        model: selected.resolvedModel,
        ...(req.effort ? { effort: normaliseEffort(req.effort) } : {}),
      })
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
  ): Promise<AppServer> {
    this.listeners.set(sessionKey(req), onEvent)

    this.server ??= this.createServer({
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

  private async threadFor(
    req: ChatRequest,
    server: AppServer,
  ): Promise<{ threadId: string; created: boolean }> {
    const existing = this.threads.get(sessionKey(req))
    if (existing) return { threadId: existing, created: false }

    const started = await server.request('thread/start', {
      cwd: this.opts.cwd,
      // Codex asks before calling a tool it did not bring itself, and "never" denies
      // rather than allows. The policy has to permit asking; this client answers,
      // approving Routi's own tools and nothing else.
      approvalPolicy: 'on-request',
      sandbox: 'read-only',
      config: {
        // Bot and conversation both: a routine or a note saved over this URL is filed
        // under the conversation it was made in.
        mcp_servers: { routi: { url: `${this.opts.mcpBaseUrl}/mcp/${req.botId}/${req.conversationId}` } },
      },
    })

    const thread = (started['thread'] ?? {}) as Record<string, unknown>
    const threadId = String(thread['id'] ?? '')
    if (!threadId) throw new Error('Codex did not return a thread.')
    this.threads.set(sessionKey(req), threadId)
    this.threadOwners.set(threadId, sessionKey(req))
    return { threadId, created: true }
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

/** A thread item that has just appeared, as one of Routi's blocks. */
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

function normaliseEffort(effort: string): 'low' | 'medium' | 'high' | 'xhigh' | 'max' {
  // Codex now takes every level Routi names; a model that lacks one is not offered it
  // by the picker, which reads the levels `model/list` reports per model.
  if (effort === 'low' || effort === 'medium' || effort === 'xhigh' || effort === 'max') return effort
  return 'high'
}
