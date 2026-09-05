import { Desktop } from './desktop.js'

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

  for(botId: string): Desktop {
    let desktop = this.byBot.get(botId)
    if (!desktop) {
      desktop = new Desktop(botId)
      this.byBot.set(botId, desktop)
    }
    return desktop
  }

  all(): Desktop[] {
    return [...this.byBot.values()]
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
