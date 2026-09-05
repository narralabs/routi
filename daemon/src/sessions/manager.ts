import { randomUUID } from 'node:crypto'
import type { Block, Message, ServerEvent } from '@krog/protocol'
import type { Store } from '../db/store.js'
import type { ProviderAdapter } from '../providers/types.js'

type Emit = (event: ServerEvent) => void

/**
 * Owns the lifecycle of an assistant turn: assembles streamed provider events into a
 * block array, broadcasts deltas as they arrive, and persists the final message.
 *
 * The in-flight message is written to SQLite twice — once empty when the turn starts,
 * once complete when it ends. That ordering means a client that reconnects mid-turn
 * still finds the message row and can resync, rather than seeing a gap.
 */
export class SessionManager {
  private readonly inFlight = new Map<string, AbortController>()

  constructor(
    private readonly store: Store,
    private readonly providers: Map<string, ProviderAdapter>,
    private readonly emit: Emit,
  ) {}

  isBusy(conversationId: string): boolean {
    return this.inFlight.has(conversationId)
  }

  interrupt(conversationId: string): boolean {
    const ac = this.inFlight.get(conversationId)
    if (!ac) return false
    ac.abort()
    return true
  }

  /**
   * Persists the user's message, then runs the assistant turn in the background.
   * Returns as soon as the user message is durable so the client can echo it.
   */
  async send(conversationId: string, blocks: Block[]): Promise<Message> {
    const conv = this.store.getConversation(conversationId)
    if (!conv) throw new Error(`No such conversation: ${conversationId}`)
    const bot = this.store.getBot(conv.botId)
    if (!bot) throw new Error(`No such bot: ${conv.botId}`)
    if (this.inFlight.has(conversationId)) throw new Error('This conversation is already generating a reply.')

    const userMessage = this.store.insertMessage({ conversationId, role: 'user', blocks })
    this.emit({ e: 'message.created', message: userMessage })

    // First user message names the chat, mirroring the sidebar in the reference app.
    if (conv.title === 'New chat') {
      const firstText = blocks.find((b): b is Extract<Block, { type: 'text' }> => b.type === 'text')?.text
      if (firstText) {
        const title = firstText.trim().slice(0, 60)
        const updated = this.store.setConversationTitle(conversationId, title)
        if (updated) this.emit({ e: 'conversation.updated', conversation: updated })
      }
    }

    void this.runTurn(conversationId, bot, userMessage)
    return userMessage
  }

  private async runTurn(
    conversationId: string,
    bot: NonNullable<ReturnType<Store['getBot']>>,
    userMessage: Message,
  ): Promise<void> {
    const provider = this.providers.get(bot.provider)
    if (!provider) {
      this.emit({ e: 'error', conversationId, code: 'no_provider', message: `Unknown provider: ${bot.provider}` })
      return
    }

    const ac = new AbortController()
    this.inFlight.set(conversationId, ac)
    this.emit({ e: 'conversation.busy', conversationId, busy: true })

    const messageId = randomUUID()
    const blocks: Block[] = []
    let stopReason: string | null = null
    let meta: Record<string, unknown> | null = null

    // Persist empty first, so a mid-turn reconnect finds the row.
    const assistantMessage = this.store.insertMessage({ id: messageId, conversationId, role: 'assistant', blocks: [] })
    this.emit({ e: 'message.created', message: assistantMessage })

    const history = this.store.listMessages(conversationId, 200).filter((m) => m.id !== messageId)

    try {
      const stream = provider.stream(
        {
          conversationId,
          systemPrompt: bot.systemPrompt,
          model: bot.model,
          effort: bot.effort,
          history,
          input: userMessage.blocks,
        },
        ac.signal,
      )

      for await (const ev of stream) {
        switch (ev.type) {
          case 'block_start':
            setBlock(blocks, ev.index, ev.block)
            this.emit({ e: 'message.block', conversationId, messageId, blockIndex: ev.index, block: ev.block })
            break

          case 'text_delta': {
            const b = blocks[ev.index]
            if (b?.type === 'text') b.text += ev.text
            else setBlock(blocks, ev.index, { type: 'text', text: ev.text })
            this.emit({
              e: 'message.delta', conversationId, messageId,
              blockIndex: ev.index, delta: { type: 'text', text: ev.text },
            })
            break
          }

          case 'thinking_delta': {
            const b = blocks[ev.index]
            if (b?.type === 'thinking') b.text += ev.text
            else setBlock(blocks, ev.index, { type: 'thinking', text: ev.text })
            this.emit({
              e: 'message.delta', conversationId, messageId,
              blockIndex: ev.index, delta: { type: 'thinking', text: ev.text },
            })
            break
          }

          case 'block_end':
            setBlock(blocks, ev.index, ev.block)
            this.emit({ e: 'message.block', conversationId, messageId, blockIndex: ev.index, block: ev.block })
            break

          case 'done':
            stopReason = ev.stopReason
            meta = ev.meta
            break

          case 'error':
            this.emit({ e: 'error', conversationId, code: ev.code, message: ev.message })
            stopReason = 'error'
            break
        }
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      this.emit({ e: 'error', conversationId, code: 'turn_failed', message })
      stopReason = 'error'
    } finally {
      const finalBlocks = blocks.filter(Boolean)
      this.store.updateMessageBlocks(messageId, finalBlocks, meta)

      // Remember the provider's session id so a restart can resume this thread.
      const sid = (meta?.['sessionId'] as string | undefined) ?? null
      if (sid) this.store.setProviderSessionId(conversationId, sid)

      this.inFlight.delete(conversationId)
      this.emit({ e: 'message.completed', conversationId, messageId, stopReason, providerMeta: meta })
      this.emit({ e: 'conversation.busy', conversationId, busy: false })

      const conv = this.store.getConversation(conversationId)
      if (conv) this.emit({ e: 'conversation.updated', conversation: conv })
    }
  }
}

/** Providers address blocks by index and may skip ahead; keep the array dense. */
function setBlock(blocks: Block[], index: number, block: Block): void {
  while (blocks.length < index) blocks.push({ type: 'text', text: '' })
  blocks[index] = block
}
