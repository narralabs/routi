import { existsSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { AccountInfo, Block, ModelInfo } from '@routi/protocol'
import { GrokCli, grokAuthFile, grokBinary } from '../auth/grok-cli.js'
import { GrokAcp, ROUTI_MCP_SERVER, isRoutiTool, toolTargetOf, type AcpEvent } from './grok-acp.js'
import { replayTranscript } from './replay.js'
import { sessionKey } from './types.js'
import type { ChatRequest, ProviderAdapter, ProviderEvent } from './types.js'

/**
 * xAI through a personal Grok account, via the Grok CLI.
 *
 * The third of the same shape, after Claude and Codex: a plan someone already pays
 * for should be spendable without a second, metered bill, and the CLI is the only
 * sanctioned way to spend one from a program. Routi never handles the credential — the
 * Grok CLI holds it and this drives the CLI.
 *
 * Sessions are warm and per bot-in-conversation, like the other two: Grok keeps the
 * history itself under a session id, so `req.history` is deliberately ignored rather
 * than replayed. The model's own context beats a reconstruction of it.
 */

/**
 * Reasoning effort is not offered here, and that is a finding rather than an omission.
 *
 * Grok's models carry four levels and name a default, but nothing over ACP moves them
 * off it: `session/set_mode` with a level id returns success and changes nothing,
 * `_meta` hints on `session/new` and `session/prompt` are ignored, and the CLI's own
 * `--reasoning-effort` does not reach a session created this way. All four were
 * measured against 1.0.13 and the session stayed on the model's default every time.
 * Listing levels Routi cannot actually set would put a control in the bot sheet that
 * quietly did nothing.
 */
const NO_EFFORT_LEVELS: ModelInfo['effortLevels'] = []

/**
 * A Grok home belonging to Routi rather than to whoever owns this Mac.
 *
 * The same door the Codex adapter had to shut, and Grok leaves it open twice as wide:
 * it reads `~/.grok` for config, skills, plugins and MCP servers, *and* `~/.claude.json`
 * and `~/.claude/` for the same things, in Claude Code's format. Left alone, a Routi
 * bot inherits the operator's whole toolbox — the first session opened here came up
 * holding a personal Figma server. A bot's abilities should come from Routi and its own
 * description.
 *
 * Hence both variables: `GROK_HOME` moves the Grok config, and `HOME` moves the
 * Claude-compatible one, which `GROK_HOME` does not cover. Measured: with only
 * `GROK_HOME` set, the personal server was still there; with both, the session lists
 * exactly the tools Routi served it.
 *
 * The login is the one thing worth keeping, so auth.json is linked rather than copied:
 * signing in or out with the CLI stays in effect, and Routi never holds a copy of the
 * credential.
 */
function isolatedGrokHome(dataDir: string): { grokHome: string; home: string } {
  const grokHome = join(dataDir, 'grok')
  const home = join(grokHome, 'home')
  mkdirSync(home, { recursive: true })

  // Rewritten every start: this file is Routi's statement of what a bot may use, and it
  // should not drift because something once wrote to it.
  writeFileSync(
    join(grokHome, 'config.toml'),
    [
      '# Written by Routi. A bot gets its abilities from Routi and its own description,',
      '# never from the personal Grok setup on this machine.',
      '',
    ].join('\n'),
  )

  const link = join(grokHome, 'auth.json')
  try {
    rmSync(link, { force: true })
    if (existsSync(grokAuthFile())) symlinkSync(grokAuthFile(), link)
  } catch {
    // Without the link Grok reports itself signed out, which the auth status already
    // surfaces — better than failing to start the daemon.
  }
  return { grokHome, home }
}

export class XaiSubscriptionAdapter implements ProviderAdapter {
  readonly id = 'xai-grok'
  readonly supportsSurface = true

  private agent: GrokAcp | null = null
  private readonly env: Record<string, string>
  private readonly cli = new GrokCli()
  /** Bot-in-conversation to Grok session, so a reply continues where the last stopped. */
  private readonly sessions = new Map<string, string>()
  /** The reverse, for routing an event back to the turn waiting on it. */
  private readonly sessionOwners = new Map<string, string>()
  private readonly listeners = new Map<string, (event: AcpEvent) => void>()
  /** The lineup the agent last reported, which beats anything written here. */
  private lineup: ModelInfo[] | null = null

  constructor(
    private readonly opts: { cwd: string; dataDir: string; mcpBaseUrl: string; apiKey?: string },
  ) {
    const { grokHome, home } = isolatedGrokHome(opts.dataDir)
    // Given in full because supplying env stops the child inheriting process.env —
    // which is the point.
    this.env = {
      GROK_HOME: grokHome,
      HOME: home,
      PATH: process.env['PATH'] ?? '/usr/local/bin:/usr/bin:/bin',
      ...(opts.apiKey ? { XAI_API_KEY: opts.apiKey } : {}),
      ...(process.env['TMPDIR'] ? { TMPDIR: process.env['TMPDIR'] } : {}),
    }
  }

  /**
   * Asked, not assumed.
   *
   * Every session the agent opens reports the models that account can actually reach,
   * with their names and their default effort, so once a bot has spoken the lineup is
   * first-hand. Before that there is `grok models`, which is the same question put to
   * the CLI.
   */
  async listModels(): Promise<ModelInfo[]> {
    if (this.lineup) return this.lineup
    const models = (await this.cli.models()).map<ModelInfo>((model) => ({
      id: model.id,
      displayName: prettyName(model.id),
      description: model.isDefault ? "Grok's current default." : '',
      resolvedModel: model.id,
      effortLevels: NO_EFFORT_LEVELS,
      defaultEffort: null,
    }))
    return models
  }

  async accountInfo(): Promise<AccountInfo> {
    return { authMode: this.opts.apiKey ? 'api_key' : 'subscription' }
  }

  async *stream(req: ChatRequest, signal: AbortSignal): AsyncIterable<ProviderEvent> {
    const prompt = textOf(req.input)
    if (!prompt) {
      yield { type: 'done', stopReason: 'end_turn', meta: {} }
      return
    }

    // ACP carries no system role, so the standing instruction leads the turn, as it
    // does on the Codex side.
    const framed = [req.systemPrompt.trim(), '', prompt].filter(Boolean).join('\n')

    // Events arrive on the agent's own schedule, so they queue here and the generator
    // drains them. Without this, anything emitted while the consumer is awaiting would
    // be dropped.
    const queue: ProviderEvent[] = []
    let wake: (() => void) | null = null
    const push = (event: ProviderEvent) => {
      queue.push(event)
      wake?.()
      wake = null
    }

    const blocks = new TurnBlocks(push)
    const meta: Record<string, unknown> = { model: req.model }
    let finished = false

    const agent = await this.agentFor(req, (event) => {
      if (event.method !== 'session/update') return
      const update = (event.params['update'] ?? {}) as Record<string, any>

      switch (update['sessionUpdate']) {
        case 'agent_message_chunk':
          blocks.text(String(update['content']?.['text'] ?? ''))
          break

        case 'agent_thought_chunk':
          blocks.thinking(String(update['content']?.['text'] ?? ''))
          break

        case 'tool_call':
          blocks.toolStart(update)
          break

        case 'tool_call_update':
          blocks.toolUpdate(update)
          break

        case 'usage_update':
          meta['usage'] = update['usage'] ?? update
          break
      }
    })

    const { sessionId, created } = await this.sessionFor(req, agent)
    // A session made partway through a conversation — after a restart — knows none of
    // it, so the transcript leads the first turn.
    const replay = created ? replayTranscript(req.history, req.botId) : null
    const text = replay ? [req.systemPrompt.trim(), '', replay, '', prompt].filter(Boolean).join('\n') : framed

    void agent
      // No deadline: a turn is over when the agent says so, or when the user stops it.
      .request('session/prompt', { sessionId, prompt: [{ type: 'text', text }] }, 0)
      .then((result) => {
        const usage = (result['_meta'] as Record<string, unknown> | undefined)?.['usage']
        if (usage) meta['usage'] = usage
        blocks.closeAll()
        finished = true
        push({ type: 'done', stopReason: String(result['stopReason'] ?? 'end_turn'), meta })
      })
      .catch((err: unknown) => {
        blocks.closeAll()
        finished = true
        push({
          type: 'error',
          code: 'stream_failed',
          message: err instanceof Error ? err.message : String(err),
        })
      })

    while (!finished || queue.length > 0) {
      if (signal.aborted) {
        agent.notify('session/cancel', { sessionId })
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

  /** One agent process for the adapter, shared by every conversation on it. */
  private async agentFor(
    req: ChatRequest,
    onEvent: (event: AcpEvent) => void,
  ): Promise<GrokAcp> {
    this.listeners.set(sessionKey(req), onEvent)

    this.agent ??= new GrokAcp({
      binary: grokBinary(),
      env: this.env,
      // Fanned out by session: one process serves every conversation, and a turn's
      // events must reach only the turn waiting on them.
      onEvent: (event) => {
        const sessionId = String(event.params['sessionId'] ?? '')
        const owner = this.sessionOwners.get(sessionId)
        const listener = owner ? this.listeners.get(owner) : undefined
        listener?.(event)
      },
    })
    await this.agent.ready()
    return this.agent
  }

  private async sessionFor(
    req: ChatRequest,
    agent: GrokAcp,
  ): Promise<{ sessionId: string; created: boolean }> {
    const existing = this.sessions.get(sessionKey(req))
    if (existing) return { sessionId: existing, created: false }

    const started = await agent.request('session/new', {
      cwd: this.opts.cwd,
      // Every bot gets the server: notes and routines need no screen, and the server
      // leaves the screen verbs out for a bot that has none.
      mcpServers: [
        {
          type: 'http',
          name: ROUTI_MCP_SERVER,
          url: `${this.opts.mcpBaseUrl}/mcp/${req.botId}/${req.conversationId}`,
          headers: [],
        },
      ],
    })

    const sessionId = String(started['sessionId'] ?? '')
    if (!sessionId) throw new Error('Grok did not return a session.')

    this.rememberLineup(started['models'] as Record<string, unknown> | undefined)

    // The picker's ids are Grok's own, so this is the model the bot was built on. It
    // is set after creation because `session/new` takes no model.
    if (req.model && req.model !== 'default') {
      await agent
        .request('session/set_model', { sessionId, modelId: req.model })
        .catch(() => {
          // An unknown id leaves the session on the account default, which still
          // answers; failing the turn over it would be worse.
        })
    }

    this.sessions.set(sessionKey(req), sessionId)
    this.sessionOwners.set(sessionId, sessionKey(req))
    return { sessionId, created: true }
  }

  /** What a new session says the account can reach, kept for the model picker. */
  private rememberLineup(models: Record<string, unknown> | undefined): void {
    const available = models?.['availableModels']
    if (!Array.isArray(available) || available.length === 0) return

    this.lineup = available.map((entry) => {
      const model = entry as Record<string, any>
      const id = String(model['modelId'] ?? '')
      const meta = (model['_meta'] ?? {}) as Record<string, any>
      const effort = model['supportsReasoningEffort'] ?? meta['supportsReasoningEffort']
      return {
        id,
        displayName: String(model['name'] ?? prettyName(id)),
        description: String(model['description'] ?? ''),
        resolvedModel: id,
        effortLevels: NO_EFFORT_LEVELS,
        // Grok picks a level and says which; Routi cannot change it, so it is reported
        // rather than offered.
        defaultEffort: effort ? normaliseEffort(meta['reasoningEffort']) : null,
      }
    })
  }

  release(conversationId: string): void {
    const sessionId = this.sessions.get(conversationId)
    if (sessionId) this.sessionOwners.delete(sessionId)
    this.sessions.delete(conversationId)
    this.listeners.delete(conversationId)
  }

  dispose(): void {
    this.agent?.dispose()
    this.agent = null
    this.sessions.clear()
    this.sessionOwners.clear()
    this.listeners.clear()
  }
}

/**
 * The running turn's blocks, and the indices the client addresses them by.
 *
 * ACP streams text and thoughts as bare chunks with no ids of their own, so a block is
 * open until something else interrupts it: prose, then a thought, then prose again is
 * three blocks, not one with a hole in it. Tool calls do carry ids, so those are held
 * by id until their result arrives.
 */
class TurnBlocks {
  private index = 0
  private open: { at: number; kind: 'text' | 'thinking'; text: string } | null = null
  private readonly tools = new Map<string, { at: number; name: string; input: unknown }>()

  constructor(private readonly push: (event: ProviderEvent) => void) {}

  // The deltas are what the client draws as they land; the accumulated string travels
  // again at block_end, which is the copy that gets stored.
  text(chunk: string): void {
    if (!chunk) return
    const open = this.streamOpen('text')
    open.text += chunk
    this.push({ type: 'text_delta', index: open.at, text: chunk })
  }

  thinking(chunk: string): void {
    if (!chunk) return
    const open = this.streamOpen('thinking')
    open.text += chunk
    this.push({ type: 'thinking_delta', index: open.at, text: chunk })
  }

  toolStart(update: Record<string, any>): void {
    const target = toolTargetOf(update)
    if (!isRoutiTool(update)) return
    const id = String(update['toolCallId'] ?? '')
    if (!id || this.tools.has(id)) return

    this.closeStream()
    const at = this.index++
    const name = shortToolName(target)
    const input = (update['rawInput']?.['tool_input'] ?? update['rawInput']) as unknown
    this.tools.set(id, { at, name, input })
    this.push({
      type: 'block_start',
      index: at,
      block: { type: 'tool_use', id, name, input, status: 'running' },
    })
  }

  toolUpdate(update: Record<string, any>): void {
    const id = String(update['toolCallId'] ?? '')
    const entry = this.tools.get(id)
    // A tool call gets several updates — the first only names it — so this waits for
    // the one that says how it ended.
    if (!entry) return
    const status = String(update['status'] ?? '')
    if (status !== 'completed' && status !== 'failed') return

    this.tools.delete(id)
    this.push({
      type: 'block_end',
      index: entry.at,
      block: {
        type: 'tool_use',
        id,
        name: entry.name,
        input: entry.input,
        status: status === 'failed' ? 'error' : 'done',
      },
    })
  }

  /** Ends whatever is still open, so a turn never leaves a block unterminated. */
  closeAll(): void {
    this.closeStream()
    for (const [id, entry] of this.tools) {
      this.push({
        type: 'block_end',
        index: entry.at,
        block: { type: 'tool_use', id, name: entry.name, input: entry.input, status: 'error' },
      })
    }
    this.tools.clear()
  }

  private streamOpen(kind: 'text' | 'thinking'): { at: number; text: string } {
    if (this.open?.kind === kind) return this.open
    this.closeStream()
    const at = this.index++
    this.open = { at, kind, text: '' }
    this.push({ type: 'block_start', index: at, block: { type: kind, text: '' } })
    return this.open
  }

  private closeStream(): void {
    const open = this.open
    if (!open) return
    this.open = null
    this.push({ type: 'block_end', index: open.at, block: { type: open.kind, text: open.text } })
  }
}

function textOf(blocks: Block[]): string {
  return blocks
    .filter((block): block is Extract<Block, { type: 'text' }> => block.type === 'text')
    .map((block) => block.text)
    .join('\n')
    .trim()
}

/** `routi__open_url` is Grok's name for it; the transcript wants `open_url`. */
function shortToolName(target: string): string {
  return target.startsWith(`${ROUTI_MCP_SERVER}__`)
    ? target.slice(ROUTI_MCP_SERVER.length + 2)
    : target
}

/** A model id as something a person reads, for the rare one the agent hasn't named. */
function prettyName(id: string): string {
  return id.replace(/[-_]/g, ' ').replace(/\b([a-z])/g, (m) => m.toUpperCase())
}

function normaliseEffort(effort: unknown): ModelInfo['defaultEffort'] {
  const levels = ['low', 'medium', 'high', 'xhigh', 'max'] as const
  return levels.find((level) => level === effort) ?? null
}
