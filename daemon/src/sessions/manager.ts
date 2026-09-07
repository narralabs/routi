import { randomUUID } from 'node:crypto'
import type { Block, Bot, Message, ServerEvent } from '@routi/protocol'
import type { Routine, Store } from '../db/store.js'
import type { ProviderAdapter } from '../providers/types.js'
import { wakeFor } from './channel.js'
import type { Handovers } from '../surfaces/handover.js'
import { memoryTools, type MemoryOwner } from './memory-tools.js'
import { standingInstructions } from './policy.js'
import { routineTools } from './routine-tools.js'
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
  /**
   * The message each running turn is writing, as it stands right now.
   *
   * The row on disk is empty until the turn ends, so a client that loads the
   * conversation mid-turn — switching away and back during a handover, say — found
   * the bot's "I need your login" gone and an empty bubble in its place. This is the
   * same array the turn mutates, so what it shows is what has actually been said.
   */
  private readonly live = new Map<string, { messageId: string; blocks: Block[] }>()
  /** Messages sent while a reply was in flight, waiting for it to finish. */
  private readonly queued = new Map<string, Message[]>()
  /**
   * Bots whose notes a person edited since the bot last spoke.
   *
   * A harness session takes its system prompt once, when it is built, so an edit made
   * in the app would not reach a warm bot until something rebuilt it. Rather than tear
   * the session down — which costs the bot its thread — the next turn carries the
   * edited notes in with it.
   */
  private readonly memoryEdited = new Set<string>()
  /** When a person last edited the shared notes, and when each bot was last shown them. */
  private sharedEditedAt = 0
  private readonly sharedShownAt = new Map<string, number>()

  constructor(
    private readonly store: Store,
    private readonly providers: Map<string, ProviderAdapter>,
    private readonly emit: Emit,
    private readonly desktops?: DesktopPool,
    private readonly handovers?: Handovers,
  ) {}

  isBusy(conversationId: string): boolean {
    return this.inFlight.has(conversationId)
  }

  /** What the running turn has written so far, if one is running. */
  liveMessage(conversationId: string): { messageId: string; blocks: Block[] } | null {
    return this.live.get(conversationId) ?? null
  }

  /**
   * A bot's notes changed. The app is told either way; an edit by a person is also
   * carried into the bot's next turn, since its warm session will not have seen it.
   */
  memoryChanged(owner: MemoryOwner, by: 'bot' | 'user'): void {
    if (by === 'user') {
      if (owner === null) this.sharedEditedAt = Date.now()
      else this.memoryEdited.add(owner)
    }
    this.emit({ e: 'memory.updated', botId: owner })
  }

  /** A bot's routines changed; every client's rail is told. */
  routinesChanged(botId: string): void {
    this.emit({ e: 'routines.updated', botId })
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

    const isChannel = conv.kind === 'channel'
    const bot = isChannel ? null : this.store.getBot(conv.botId ?? '')
    if (!isChannel && !bot) throw new Error(`No such bot: ${conv.botId}`)

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

    /**
     * A second message while the first is still being answered waits its turn.
     *
     * It used to be refused outright, which surfaced as an alert saying the conversation
     * was already generating a reply — a true statement and a useless one, since the
     * person had simply thought of something else and there was nothing for them to do
     * about it but wait and retype. The message is written to the transcript either way;
     * only the answering waits.
     */
    if (this.inFlight.has(conversationId)) {
      const waiting = this.queued.get(conversationId) ?? []
      waiting.push(userMessage)
      this.queued.set(conversationId, waiting)
      return userMessage
    }

    if (isChannel) {
      void this.runChannelTurn(conversationId, userMessage, null)
    } else {
      void this.runTurn(conversationId, bot!, userMessage.blocks)
    }
    return userMessage
  }

  /**
   * Answers whatever arrived while the last turn was running.
   *
   * Everything queued goes into one turn rather than one turn each: a person adding
   * "actually, make it two nights" to a request they just sent means both things
   * together, and answering them separately would be answering the first as though the
   * second had not been said.
   */
  private drainQueue(conversationId: string): void {
    const waiting = this.queued.get(conversationId)
    if (!waiting || waiting.length === 0) return
    this.queued.delete(conversationId)

    const conv = this.store.getConversation(conversationId)
    if (!conv) return

    const blocks = waiting.flatMap((message) => message.blocks)
    if (conv.kind === 'channel') {
      void this.runChannelTurn(conversationId, { ...waiting[0]!, blocks }, null)
      return
    }
    const bot = this.store.getBot(conv.botId ?? '')
    if (bot) void this.runTurn(conversationId, bot, blocks)
  }

  /**
   * Runs a routine's saved prompt as a turn in the bot's own conversation.
   *
   * The prompt itself is not persisted, the same way a greeting's is not: the user
   * wrote the instruction once when the routine was made, and replaying it into the
   * transcript every morning would bury the answers under the question. The reply
   * carries the routine's name in its metadata so the transcript can say why the bot
   * spoke unprompted.
   */
  async runRoutine(routine: Routine, bot: Bot): Promise<void> {
    if (this.inFlight.has(routine.conversationId)) return

    await this.runTurn(
      routine.conversationId,
      bot,
      [{ type: 'text', text: routine.prompt }],
      undefined,
      { routineId: routine.id, routineName: routine.name },
    )
  }

  /**
   * Fans a room message out to whoever it woke.
   *
   * The wake rules are the whole design: a person can address the room, a bot can only
   * address someone by name. Everything expensive about a room — and everything
   * recursive — follows from who gets scheduled, not from what gets said.
   *
   * Woken bots run in parallel against the transcript as it stood, rather than queuing
   * to read each other's replies. Serialising them would make a room of four take four
   * turns to answer one question, and the next message shows everyone what was said
   * anyway.
   */
  private async runChannelTurn(
    conversationId: string,
    message: Message,
    authorBotId: string | null,
  ): Promise<void> {
    const members = this.store.channelMembers(conversationId)
    const text = message.blocks
      .filter((b): b is Extract<Block, { type: 'text' }> => b.type === 'text')
      .map((b) => b.text)
      .join('\n')

    const wake = wakeFor(text, members, authorBotId)
    if (wake.bots.length === 0) return

    await Promise.all(
      wake.bots.map((member: Bot) =>
        this.runTurn(conversationId, member, message.blocks, { members }).catch(() => {}),
      ),
    )
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
    // Rooms are not greeted: a bot introducing itself to four others the moment a
    // channel exists is four introductions nobody asked for.
    if (conv.kind === 'channel' || !conv.botId) return
    const bot = this.store.getBot(conv.botId)
    if (!bot) return
    if (this.inFlight.has(conversationId)) return

    const userName = (this.store.getSettings()['userName'] as string | undefined)?.trim()
    const hasSurface = bot.surfaceMode !== 'none'
    const greeting = userName ? `Greet them by name — they are called ${userName}.` : 'Greet them.'

    /**
     * Three openings, because the bots are genuinely different.
     *
     * A bot with a screen was created to do something, and asking "shall I start?"
     * about the exact task it was built for is the wrong first move — it should be
     * working by the time the user reads the message. A bot without a screen can only
     * talk, so promising action would be a lie; it introduces itself and asks.
     *
     * And a bot with an empty description has no task to begin, which the first of
     * those openings assumed it had. Told to start the work its description names, a
     * bot whose description names nothing invents one: the case that found this was a
     * bot called "My Bot" that greeted its owner and opened the browser to check the
     * news, which nobody had asked for. With nothing to go on, the only honest first
     * message says so and asks.
     */
    const hasBrief = bot.systemPrompt.trim().length > 0

    const prompt = !hasBrief
      ? [
          'You have just been created, and the person who made you left your description',
          'empty, so you have not been told what you are for.',
          greeting,
          'Say who you are by name in one short clause, say plainly that you have no brief',
          'yet, and ask what they want you to take on — mentioning that they can also fill',
          'in your description to make it stick.',
          'Do not invent a purpose, do not start any work, and do not use any tools or',
          'screen you may have.',
          'Hard limit: 35 words, one short paragraph, no line breaks.',
        ].join(' ')
      : hasSurface
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
    channel?: { members: Bot[] },
    /** Present when a routine woke this turn rather than a person. */
    routine?: { routineId: string; routineName: string },
  ): Promise<void> {
    const provider = this.providers.get(bot.provider)
    if (!provider) {
      this.emit({ e: 'error', conversationId, code: 'no_provider', message: `Unknown provider: ${bot.provider}` })
      return
    }

    const ac = new AbortController()
    this.inFlight.set(conversationId, ac)
    this.emit({ e: 'conversation.busy', conversationId, busy: true, routineName: routine?.routineName })

    // Held for the whole turn, because a turn is many actions and interleaving two
    // bots' clicks would corrupt both. On a container screen this never waits — each
    // bot has its own display. On This Mac it does: there is one pointer, and every
    // bot set to it shares the surface. Whoever is second waits rather than fighting.
    const surface = bot.surfaceMode !== 'none' ? this.desktops?.for(bot.id) : undefined
    if (surface) await waitForSurface(surface, conversationId, ac.signal)

    const messageId = randomUUID()
    const blocks: Block[] = []
    this.live.set(conversationId, { messageId, blocks })
    let stopReason: string | null = null
    let meta: Record<string, unknown> | null = null

    // Persist empty first, so a mid-turn reconnect finds the row. In a room the author
    // matters: four bots all write as "assistant" and the transcript needs to say which.
    const assistantMessage = this.store.insertMessage({
      id: messageId, conversationId, role: 'assistant', blocks: [], botId: bot.id,
    })
    this.emit({ e: 'message.created', message: assistantMessage })

    const history = this.store.listMessages(conversationId, 200).filter((m) => m.id !== messageId)

    const memory = this.store.memoriesFor(bot.id)
    // Only the harness knows whether it still holds this thread; what is offered is
    // the last id it reported, and only if the same runtime reported it.
    const saved = this.store.getProviderSession(conversationId, bot.id)
    const resumeSessionId = saved && saved.provider === bot.provider ? saved.sessionId : undefined

    // A person edited the notes since this bot last spoke; a warm session's prompt
    // still shows the old ones, so the new ones ride in with the message.
    const sharedStale = this.sharedEditedAt > (this.sharedShownAt.get(bot.id) ?? 0)
    this.sharedShownAt.set(bot.id, Date.now())
    if (this.memoryEdited.delete(bot.id) || sharedStale) {
      const list = (notes: typeof memory.own) => (notes.length === 0 ? ['- nothing'] : notes.map((m) => `- ${m.text}`))
      input = [
        {
          type: 'text',
          text: [
            '(The person edited the notes since your last turn. Shared, about them:',
            ...list(memory.shared),
            'Your own:',
            ...list(memory.own),
            'Carry on; no need to mention this unless it changes your answer.)',
          ].join('\n'),
        },
        ...input,
      ]
    }

    try {
      const stream = provider.stream(
        {
          conversationId,
          // The bot's name belongs in its prompt: without it a bot introduces itself
          // as "Claude" rather than as the thing the user just named and created.
          systemPrompt: standingInstructions({
            bot,
            hasSurface: bot.surfaceMode !== 'none' && provider.supportsSurface,
            channel,
            memory,
          }),
          // A bot schedules work for itself, in the conversation it is speaking in.
          toolContext: {
            routines: routineTools(this.store, bot.id, conversationId, () => this.routinesChanged(bot.id)),
            memory: memoryTools(this.store, bot.id, (owner) => this.memoryChanged(owner, 'bot')),
            // Only offered where there is a screen to hand over.
            ...(bot.surfaceMode !== 'none' && provider.supportsSurface && this.handovers
              ? {
                  handover: (reason: string) =>
                    this.handovers!.request({ botId: bot.id, conversationId, reason }),
                }
              : {}),
          },
          model: bot.model,
          effort: bot.effort,
          history,
          input,
          botId: bot.id,
          hasSurface: bot.surfaceMode !== 'none' && provider.supportsSurface,
          resumeSessionId,
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
            // To disk as each block completes, not only at the end of the turn: a daemon
            // that restarts mid-turn then keeps what the bot had said, rather than an
            // empty row that reads as a bot which never answered. A few writes per
            // turn; the streaming text within a block still lives only in memory.
            this.store.updateMessageBlocks(messageId, blocks)
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
      // Runs whatever the turn did, including throwing: a failed turn that kept the
      // lock or the queue would leave the conversation permanently stuck.
      this.inFlight.delete(conversationId)
      this.live.delete(conversationId)
      surface?.release(conversationId)

      const finalBlocks = blocks.filter(Boolean)
      /**
       * Silence is an outcome, not a failure.
       *
       * A bot in a room is told it may say nothing, and a room where every member
       * answers every remark never settles. An empty turn leaves no message rather
       * than an empty bubble — but only in a room, because a 1:1 that answers nothing
       * looks broken.
       */
      if (routine) meta = { ...(meta ?? {}), ...routine }

      const saidNothing = finalBlocks.every(
        (block) => block.type !== 'text' || block.text.trim().length === 0,
      )
      /**
       * A turn that failed before saying anything leaves nothing behind.
       *
       * It used to leave the row it had reserved — often holding a single empty
       * thinking block — so a failed turn showed as a blank bubble sitting under an
       * error, which reads as a bot still working rather than one that stopped.
       */
      if (saidNothing && stopReason === 'error') {
        this.store.deleteMessage(messageId)
        this.emit({ e: 'message.deleted', conversationId, messageId })
      } else if (channel && saidNothing) {
        this.store.deleteMessage(messageId)
        this.emit({ e: 'message.deleted', conversationId, messageId })
      } else {
        this.store.updateMessageBlocks(messageId, finalBlocks, meta)
      }

      // Remember the provider's session id so a restart can resume this thread.
      const sid = (meta?.['sessionId'] as string | undefined) ?? null
      if (sid) this.store.setProviderSession(conversationId, bot.id, bot.provider, sid)

      this.inFlight.delete(conversationId)
      this.live.delete(conversationId)
      surface?.release(conversationId)
      const preview = finalBlocks
        .find((block): block is Extract<Block, { type: 'text' }> => block.type === 'text' && block.text.trim().length > 0)
        ?.text.trim().replace(/\s+/g, ' ').slice(0, 200)
      this.emit({
        e: 'message.completed', conversationId, messageId, stopReason, providerMeta: meta,
        ...(preview ? { preview } : {}),
      })

      // Deleted from inFlight first, so anything sent mid-turn starts now rather than
      // queueing again behind a turn that has already finished.
      this.drainQueue(conversationId)

      // What a bot said can wake a teammate — but only one it named. This is the loop
      // rule doing its work: a statement reaches nobody, an @mention reaches one bot.
      if (channel && !saidNothing) {
        const posted = this.store.getMessage(messageId)
        if (posted) void this.runChannelTurn(conversationId, posted, bot.id)
      }
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
