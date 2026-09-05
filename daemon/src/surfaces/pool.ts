import type { Store } from '../db/store.js'
import { Desktop } from './desktop.js'
import { HostSurface } from './host.js'

/**
 * What every surface can do, whichever machine it is.
 *
 * Container screens and this Mac differ in almost everything — one is disposable and
 * multipliable, the other is the machine you are sitting at — but a bot drives them
 * with the same verbs, which is what lets one set of tools serve both.
 */
export type Surface = Desktop | HostSurface

/**
 * One desktop per bot, created on first mention and kept afterwards.
 *
 * The pool exists so nothing else has to know whether a bot's container has been
 * built yet: callers ask for a bot's desktop and get one, running or not. Entries are
 * never evicted — a `Desktop` with a stopped container costs nothing, and dropping it
 * would lose the name that lets a restart find the same container again.
 */
export class DesktopPool {
  private readonly byBot = new Map<string, Desktop>()
  /**
   * One host surface for everyone who asks for it.
   *
   * There is a single physical screen and a single pointer, so bots set to This Mac
   * cannot each have their own — they share this and take turns. That is the opposite
   * of container screens, and the reason the two are not interchangeable.
   */
  private readonly host: HostSurface

  constructor(dataDir: string, private readonly store?: Store) {
    this.host = new HostSurface(dataDir)
  }

  for(botId: string): Surface {
    if (this.store?.getBot(botId)?.surfaceMode === 'host') return this.host

    let desktop = this.byBot.get(botId)
    if (!desktop) {
      desktop = new Desktop(botId)
      this.byBot.set(botId, desktop)
    }
    return desktop
  }

  all(): Surface[] {
    return [...this.byBot.values(), this.host]
  }

  /**
   * Stops screens whose bot no longer exists.
   *
   * A screen outlives its bot when the bot goes away by some route that never told the
   * pool — a row deleted straight from the database, a restore, a botched migration.
   * Nothing then ever stops it, and it holds a display and a browser for as long as the
   * machine runs. Cheap to check and worth doing at boot.
   */
  async reapOrphans(liveBotIds: Set<string>): Promise<number> {
    // Asks the machine directly rather than through the pool: this is a question about
    // the container, not about any one bot's surface.
    const listed = await new Desktop('__reaper__').listScreens().catch(() => [])
    let reaped = 0
    for (const botId of listed) {
      if (liveBotIds.has(botId)) continue
      await this.for(botId).stop().catch(() => {})
      reaped++
    }
    return reaped
  }

  /**
   * Starts a bot's desktop without making the caller wait.
   *
   * Used where a desktop should simply exist — on bot creation, and when a client
   * opens the screen panel — so the container is warming while the rest of the
   * response goes out. Failures are the desktop's own to report through `status`.
   */
  warm(botId: string): void {
    void this.for(botId).start().catch(() => {})
  }
}
