import { query, type Query, type SDKMessage, type SDKUserMessage } from '@anthropic-ai/claude-agent-sdk'
import type { MessageParam } from '@anthropic-ai/sdk/resources'
import type { AccountInfo, Block, ModelInfo } from '@routi/protocol'
import { PushQueue } from './push-queue.js'
import { sessionKey } from './types.js'
import type { ChatRequest, ProviderAdapter, ProviderEvent } from './types.js'
import type { DesktopPool } from '../surfaces/pool.js'
import { desktopToolServer, toolNames } from '../surfaces/tools.js'
import { managedClaudeIfPresent } from '../auth/claude-cli.js'

/**
 * Anthropic via the user's personal Claude plan.
 *
 * Uses @anthropic-ai/claude-agent-sdk, which picks up the subscription login already
 * present on this machine (macOS Keychain). routid never sees or stores the credential.
 * Verified in the M0 spike: subscriptionType "Claude Max", apiKeySource none, and it
 * works from a scrubbed launchd-style environment.
 *
 * One warm session is held per conversation. The SDK owns conversation history for
 * that session, so ChatRequest.history is intentionally ignored here — replaying it
 * would double the context. It is used only when rebuilding a session from scratch.
 */

interface WarmSession {
  q: Query
  input: PushQueue<SDKUserMessage>
  /** Events for the turn currently in flight. */
  turn: PushQueue<ProviderEvent> | null
  sessionId: string | null
  pump: Promise<void>
}

export class AnthropicSubscriptionAdapter implements ProviderAdapter {
  readonly id = 'anthropic'
  readonly supportsSurface = true
  private readonly sessions = new Map<string, WarmSession>()
  private modelCache: ModelInfo[] | null = null
  private accountCache: AccountInfo | null = null

  constructor(private readonly opts: { cwd: string; desktops?: DesktopPool }) {}

  // ------------------------------------------------------------ capabilities

  /**
   * A short-lived throwaway session, because model and account info are only
   * reachable through a live Query. Cached — this costs a process spawn.
   */
  private async withProbe<T>(fn: (q: Query) => Promise<T>): Promise<T> {
    const input = new PushQueue<SDKUserMessage>()
    const q = query({
      prompt: input,
      options: {
        cwd: this.opts.cwd,
        ...(managedClaudeIfPresent() ? { pathToClaudeCodeExecutable: managedClaudeIfPresent() } : {}),
        tools: [],
        persistSession: false,
        settingSources: [],
      },
    })
    try {
      return await fn(q)
    } finally {
      input.close()
      q.close()
    }
  }

  async listModels(): Promise<ModelInfo[]> {
    if (this.modelCache) return this.modelCache
    const models = await this.withProbe((q) => q.supportedModels())
    this.modelCache = models.map((m) => ({
      id: m.value,
      displayName: m.displayName,
      description: m.description ?? '',
      resolvedModel: m.resolvedModel,
      effortLevels: m.supportsEffort ? m.supportedEffortLevels : undefined,
    }))
    return this.modelCache
  }

  async accountInfo(): Promise<AccountInfo> {
    if (this.accountCache) return this.accountCache
    const a = await this.withProbe((q) => q.accountInfo())
    this.accountCache = {
      authMode: 'subscription',
      subscriptionType: a.subscriptionType,
      organization: a.organization,
      email: a.email,
    }
    return this.accountCache
  }

  // ---------------------------------------------------------------- sessions

  private ensureSession(req: ChatRequest, resumeId: string | null): WarmSession {
    const existing = this.sessions.get(sessionKey(req))
    if (existing) return existing

    const input = new PushQueue<SDKUserMessage>()
    // A bot with a screen gets hands; one without stays a pure chat bot.
    // Resolved per request rather than held on the adapter: one adapter serves every
    // bot, and each bot drives its own desktop.
    const desktop = this.opts.desktops?.for(req.botId)
    const withDesktop = req.hasSurface === true && desktop !== undefined
    const q = query({
      prompt: input,
      options: {
        cwd: this.opts.cwd,
        // The same binary sign-in ran on, named rather than left to the SDK's own search.
        ...(managedClaudeIfPresent() ? { pathToClaudeCodeExecutable: managedClaudeIfPresent() } : {}),
        model: req.model,
        effort: req.effort,
        // A chat bot, not a coding agent: no built-in tools, no claude_code preset.
        // Composed once by the session manager, so every runtime says the same things.
        systemPrompt: { type: 'custom', prompt: req.systemPrompt },
        ...(withDesktop
          ? {
              mcpServers: { desktop: desktopToolServer(desktop!, req.toolContext) },
              // Pre-approved: the user granted this by giving the bot a screen, and
              // a permission prompt per click would make any real task unusable.
              allowedTools: toolNames(req.toolContext),
            }
          : { tools: [] }),
        /**
         * Isolation mode. Without this the SDK loads the host's own Claude Code
         * configuration — ~/.claude/settings.json, its MCP servers, and any CLAUDE.md
         * on the path — and the bot inherits an identity that has nothing to do with
         * its personality. It showed up as a bot introducing itself as the operator's
         * MCP tooling rather than as itself. A Routi bot is defined by its system
         * prompt and nothing else.
         */
        settingSources: [],
        /**
         * Keeps the operator's claude.ai connectors out of their bots.
         *
         * `settingSources: []` stops local configuration being read but not this: cloud
         * connectors are attached to the account and fetched by the CLI regardless, so a
         * bot created to compare ice machines could see — and offer — whatever the person
         * happens to have connected to their own Claude. It is the same failure as the
         * one that made bots introduce themselves as the operator's tooling, and no
         * amount of prompting fixes a tool actually being there.
         */
        settings: { disableClaudeAiConnectors: true },
        includePartialMessages: true,
        ...(resumeId ? { resume: resumeId } : {}),
      },
    })

    const session: WarmSession = { q, input, turn: null, sessionId: resumeId, pump: Promise.resolve() }
    // One consumer drains the query for the life of the session and routes each event
    // to whichever turn is in flight.
    session.pump = this.pump(session)
    this.sessions.set(sessionKey(req), session)
    return session
  }

  private async pump(session: WarmSession): Promise<void> {
    try {
      for await (const msg of session.q) {
        const ev = this.translate(msg, session)
        if (!ev) continue
        session.turn?.push(ev)
        if (ev.type === 'done' || ev.type === 'error') {
          session.turn?.close()
          session.turn = null
        }
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      session.turn?.push({ type: 'error', code: 'session_failed', message })
      session.turn?.close()
      session.turn = null
    }
  }

  /** SDK message -> our provider event. Returns null for frames the UI ignores. */
  private translate(msg: SDKMessage, session: WarmSession): ProviderEvent | null {
    switch (msg.type) {
      case 'system':
        if ('session_id' in msg && msg.session_id) session.sessionId = msg.session_id
        return null

      case 'stream_event': {
        const ev = msg.event
        switch (ev.type) {
          case 'content_block_start': {
            const block = anthropicBlockToRouti(ev.content_block)
            return block ? { type: 'block_start', index: ev.index, block } : null
          }
          case 'content_block_delta':
            if (ev.delta.type === 'text_delta') return { type: 'text_delta', index: ev.index, text: ev.delta.text }
            if (ev.delta.type === 'thinking_delta') return { type: 'thinking_delta', index: ev.index, text: ev.delta.thinking }
            return null
          default:
            return null
        }
      }

      case 'assistant':
        if (msg.error) return { type: 'error', code: msg.error, message: `Provider error: ${msg.error}` }
        return null

      case 'result': {
        if (msg.subtype !== 'success') {
          /**
           * Said in words rather than in the SDK's vocabulary.
           *
           * "Turn ended: error_during_execution" tells a user nothing they can act on,
           * and it is the phrasing that made a failed turn look like a state rather
           * than a failure. Whatever detail the SDK offers is carried through, since
           * that is the part with any chance of being specific.
           */
          const detail =
            'result' in msg && typeof msg.result === 'string' && msg.result.trim()
              ? msg.result.trim()
              : null
          const message =
            msg.subtype === 'error_max_turns'
              ? 'That took more steps than allowed, so it stopped partway.'
              : `Something went wrong partway through${detail ? `: ${detail}` : '.'}`
          return { type: 'error', code: msg.subtype, message }
        }
        const meta: Record<string, unknown> = {
          sessionId: session.sessionId,
          durationMs: 'duration_ms' in msg ? msg.duration_ms : undefined,
          usage: 'usage' in msg ? msg.usage : undefined,
        }
        return { type: 'done', stopReason: 'end_turn', meta }
      }

      default:
        return null
    }
  }

  // ------------------------------------------------------------------ stream

  async *stream(req: ChatRequest, signal: AbortSignal): AsyncIterable<ProviderEvent> {
    const session = this.ensureSession(req, null)

    if (session.turn) {
      yield { type: 'error', code: 'busy', message: 'This conversation is already generating a reply.' }
      return
    }

    const turn = new PushQueue<ProviderEvent>()
    session.turn = turn

    const onAbort = () => {
      void session.q.interrupt().catch(() => {})
    }
    signal.addEventListener('abort', onAbort, { once: true })

    session.input.push({
      type: 'user',
      message: { role: 'user', content: blocksToAnthropicContent(req.input) },
      parent_tool_use_id: null,
      session_id: session.sessionId ?? '',
    })

    try {
      for await (const ev of turn) yield ev
    } finally {
      signal.removeEventListener('abort', onAbort)
      if (session.turn === turn) session.turn = null
    }
  }

  /** The session id, once known, so it can be persisted and resumed after a restart. */
  sessionIdFor(conversationId: string): string | null {
    return this.sessions.get(conversationId)?.sessionId ?? null
  }

  release(conversationId: string): void {
    const s = this.sessions.get(conversationId)
    if (!s) return
    s.input.close()
    s.q.close()
    this.sessions.delete(conversationId)
  }

  dispose(): void {
    for (const id of [...this.sessions.keys()]) this.release(id)
  }
}


// ------------------------------------------------------------------ mapping

function anthropicBlockToRouti(raw: { type: string }): Block | null {
  // The SDK's content-block union is far wider than the handful the UI renders, so
  // narrow through an indexable view and match on the discriminant.
  const cb = raw as { type: string } & Record<string, unknown>
  switch (cb.type) {
    case 'text':
      return { type: 'text', text: typeof cb.text === 'string' ? cb.text : '' }
    case 'thinking':
      return { type: 'thinking', text: typeof cb.thinking === 'string' ? cb.thinking : '' }
    case 'tool_use':
      return {
        type: 'tool_use',
        id: String(cb.id ?? ''),
        name: String(cb.name ?? ''),
        input: cb.input,
        status: 'running',
      }
    default:
      // redacted_thinking, server_tool_use, and friends have no UI yet.
      return null
  }
}

type MessageContent = MessageParam['content']

function blocksToAnthropicContent(blocks: Block[]): MessageContent {
  // The overwhelmingly common case is a single text block; send it as a plain string.
  if (blocks.length === 1 && blocks[0]!.type === 'text') return (blocks[0] as { text: string }).text

  const out: Exclude<MessageContent, string> = []
  for (const b of blocks) {
    if (b.type === 'text') out.push({ type: 'text', text: b.text })
    else if (b.type === 'image' && b.dataUrl) {
      const m = /^data:([^;]+);base64,(.*)$/.exec(b.dataUrl)
      if (m) {
        out.push({
          type: 'image',
          source: { type: 'base64', media_type: m[1] as 'image/png', data: m[2]! },
        })
      }
    }
  }
  return out.length > 0 ? out : ''
}
