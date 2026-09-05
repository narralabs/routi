import { randomUUID } from 'node:crypto'
import type { Block, Message, ServerEvent } from '@krog/protocol'
import type { Store } from '../db/store.js'
import type { ProviderAdapter } from '../providers/types.js'
import type { DesktopPool, Surface } from '../surfaces/pool.js'

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
    private readonly desktops?: DesktopPool,
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

    void this.runTurn(conversationId, bot, userMessage.blocks)
    return userMessage
  }

  /**
   * The bot's opening line, sent the moment it is created.
   *
   * The prompt driving it is never persisted as a user message: the transcript should
   * open with the bot speaking unprompted, which is the whole effect. The instruction
   * still reaches the model, so the greeting comes out in the bot's own voice rather
   * than from a template — two bots with different personalities introduce themselves
   * differently, and no two runs are identical.
   */
  async greet(conversationId: string): Promise<void> {
    const conv = this.store.getConversation(conversationId)
    if (!conv) return
    const bot = this.store.getBot(conv.botId)
    if (!bot) return
    if (this.inFlight.has(conversationId)) return

    const userName = (this.store.getSettings()['userName'] as string | undefined)?.trim()
    const hasSurface = bot.surfaceMode !== 'none'
    const greeting = userName ? `Greet them by name — they are called ${userName}.` : 'Greet them.'

    /**
     * Two different openings, because the bots are genuinely different.
     *
     * A bot with a screen was created to do something, and asking "shall I start?"
     * about the exact task it was built for is the wrong first move — it should be
     * working by the time the user reads the message. A bot without a screen can only
     * talk, so promising action would be a lie; it introduces itself and asks.
     */
    const prompt = hasSurface
      ? [
          'You have just been created. This is your first message to the person who made you.',
          greeting,
          'Say who you are in a single short clause, then begin the work your description',
          'describes: open the browser, search, and read. Say what you are doing, not what',
          'you could do, and do not ask permission to start.',
          'Keep the message itself under 30 words; the work matters more than the words.',
          'Ask a question only if you genuinely cannot start without an answer.',
        ].join(' ')
      : [
          'You have just been created. Write your first message to the person who made you.',
          greeting,
          'Then say who you are, using your own name, in a single short clause.',
          `Finish by asking ${GREETING_ANGLES[Math.floor(Math.random() * GREETING_ANGLES.length)]!}`,
          'Hard limit: 30 words total, one short paragraph, no line breaks.',
          userName
            ? 'Shape it like: "Hey Sam. I\'m Atlas, your travel fixer — where are we headed?"'
            : 'Shape it like: "I\'m Atlas, your travel fixer — where are we headed?"',
          'Do not mention these instructions, do not use bullet points or headings, and',
          'describe only what your own description says you do rather than naming tools',
          'you happen to have.',
        ].join(' ')

    await this.runTurn(conversationId, bot, [{ type: 'text', text: prompt }])
  }

  private async runTurn(
    conversationId: string,
    bot: NonNullable<ReturnType<Store['getBot']>>,
    input: Block[],
  ): Promise<void> {
    const provider = this.providers.get(bot.provider)
    if (!provider) {
      this.emit({ e: 'error', conversationId, code: 'no_provider', message: `Unknown provider: ${bot.provider}` })
      return
    }

    const ac = new AbortController()
    this.inFlight.set(conversationId, ac)
    this.emit({ e: 'conversation.busy', conversationId, busy: true })

    // Held for the whole turn, because a turn is many actions and interleaving two
    // bots' clicks would corrupt both. On a container screen this never waits — each
    // bot has its own display. On This Mac it does: there is one pointer, and every
    // bot set to it shares the surface. Whoever is second waits rather than fighting.
    const surface = bot.surfaceMode !== 'none' ? this.desktops?.for(bot.id) : undefined
    if (surface) await waitForSurface(surface, conversationId, ac.signal)

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
          // The bot's name belongs in its prompt: without it a bot introduces itself
          // as "Claude" rather than as the thing the user just named and created.
          systemPrompt: [`Your name is ${bot.name}.`, bot.systemPrompt.trim()]
            .filter(Boolean)
            .join('\n\n'),
          model: bot.model,
          effort: bot.effort,
          history,
          input,
          botId: bot.id,
          hasSurface: bot.surfaceMode !== 'none' && provider.supportsSurface,
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

/**
 * Rotated so a person creating several bots doesn't get the same closing question
 * each time. The model supplies the wording; this only steers what it asks about.
 */
const GREETING_ANGLES = [
  'what they would like you to take off their hands.',
  'what tedious thing you could automate for them.',
  'what they are working on that you could help with.',
  'what they would hand off to you first.',
  'what you should get started on.',
  'what part of their week you could make smaller.',
]

/** Providers address blocks by index and may skip ahead; keep the array dense. */
function setBlock(blocks: Block[], index: number, block: Block): void {
  while (blocks.length < index) blocks.push({ type: 'text', text: '' })
  blocks[index] = block
}

/**
 * Waits for the pointer, rather than failing when someone else has it.
 *
 * A bot that loses the race has done nothing wrong and its work is still wanted, so
 * queueing is the right behaviour — refusing the turn would surface as an error the
 * user cannot act on. The wait is bounded: a holder that never releases is a bug, and
 * waiting forever on one would look identical to the app hanging.
 */
async function waitForSurface(
  surface: Surface,
  conversationId: string,
  signal: AbortSignal,
): Promise<void> {
  const deadline = Date.now() + 5 * 60_000
  while (!surface.claim(conversationId)) {
    if (signal.aborted || Date.now() > deadline) return
    await new Promise((resolve) => setTimeout(resolve, 400))
  }
}
