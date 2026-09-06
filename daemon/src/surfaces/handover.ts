import type { ServerEvent } from '@routi/protocol'

/**
 * Handing the screen to the person, and waiting.
 *
 * A bot that meets a login has one honest move: stop and ask. It was already told to,
 * but "stop and say so" leaves the user to notice a sentence in a transcript and work
 * out what to do — and leaves the bot to guess when they are finished. So the ask is a
 * tool that blocks: the turn pauses mid-flight, the app shows what is wanted with the
 * screen behind it, and the bot resumes on a button.
 *
 * Requests are per bot, not per conversation: there is one screen, and two turns asking
 * for it at once is the same contention the surface lock already settles.
 */

export interface Handover {
  id: string
  botId: string
  conversationId: string
  /** What the person is being asked to do, in the bot's words. */
  reason: string
  askedAt: number
}

export type HandoverOutcome = 'done' | 'skipped' | 'timeout'

interface Pending extends Handover {
  resolve(outcome: HandoverOutcome): void
  timer: NodeJS.Timeout
}

export class Handovers {
  private readonly pending = new Map<string, Pending>()

  constructor(private readonly emit: (event: ServerEvent) => void) {}

  /** Asks, and waits. Resolves when the person answers, or gives up eventually. */
  request(request: Omit<Handover, 'id' | 'askedAt'>, timeoutMs = 20 * 60_000): Promise<HandoverOutcome> {
    // A second ask from the same bot replaces the first: the newer one is what it
    // actually wants, and two banners for one screen helps nobody.
    this.cancel(request.botId, 'skipped')

    return new Promise<HandoverOutcome>((resolve) => {
      const handover: Handover = {
        ...request,
        id: `${request.botId}:${Date.now()}`,
        askedAt: Date.now(),
      }

      const finish = (outcome: HandoverOutcome) => {
        const entry = this.pending.get(request.botId)
        if (!entry || entry.id !== handover.id) return
        clearTimeout(entry.timer)
        this.pending.delete(request.botId)
        this.emit({ e: 'handover.resolved', botId: handover.botId, id: handover.id, outcome })
        resolve(outcome)
      }

      // Bounded, because a bot waiting forever on someone who has gone to bed is a
      // turn that never ends and a conversation that never unlocks.
      const timer = setTimeout(() => finish('timeout'), timeoutMs)
      timer.unref?.()

      this.pending.set(request.botId, { ...handover, resolve: finish, timer })
      this.emit({ e: 'handover.requested', handover })
    })
  }

  /** Answered from the app. */
  resolve(botId: string, outcome: HandoverOutcome): boolean {
    const entry = this.pending.get(botId)
    if (!entry) return false
    entry.resolve(outcome)
    return true
  }

  private cancel(botId: string, outcome: HandoverOutcome): void {
    this.pending.get(botId)?.resolve(outcome)
  }

  /** What is outstanding, so a client that connects late still sees the ask. */
  all(): Handover[] {
    return [...this.pending.values()].map(({ resolve, timer, ...rest }) => {
      void resolve
      void timer
      return rest
    })
  }
}
