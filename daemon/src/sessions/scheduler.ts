import type { Store } from '../db/store.js'
import type { SessionManager } from './manager.js'
import { describeSchedule } from './schedule.js'

/**
 * Runs routines when they come due.
 *
 * Deliberately not a watcher over the conversation. Nothing here reads messages or
 * decides what deserves scheduling — bots create routines themselves during an ordinary
 * turn, and this only fires the ones already saved. Proactivity belongs in the policy a
 * bot runs under; timing belongs in a table.
 *
 * A tick is a database query against an index, so polling every half minute costs
 * nothing and avoids a timer per routine that would have to be rebuilt on every edit
 * and lost on every restart.
 */
export class Scheduler {
  private timer: NodeJS.Timeout | null = null
  /** Routines mid-run, so a slow one is not started again on the next tick. */
  private readonly running = new Set<string>()

  constructor(
    private readonly store: Store,
    private readonly sessions: SessionManager,
    private readonly intervalMs = 30_000,
  ) {}

  start(): void {
    if (this.timer) return
    this.timer = setInterval(() => void this.tick(), this.intervalMs)
    // Unref so a daemon with nothing else to do can still exit.
    this.timer.unref?.()
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  }

  async tick(): Promise<void> {
    for (const routine of this.store.dueRoutines()) {
      if (this.running.has(routine.id)) continue

      // A conversation mid-turn keeps its routine waiting, not skipped. Turns are
      // serialised per conversation, so the run could not start anyway — but it used
      // to be booked forward regardless, which meant a person chatting at eight lost
      // the eight o'clock check until tomorrow. Left due, it runs on the first tick
      // after the reply finishes, which is the "fold it in afterwards" a person expects.
      if (this.sessions.isBusy(routine.conversationId)) continue
      this.running.add(routine.id)

      // Booked forward before the run, not after: a routine that fails or hangs should
      // come round again at its next scheduled time rather than immediately, and a
      // crash mid-run must not leave it due forever.
      this.store.markRoutineRun(routine.id)

      const bot = this.store.getBot(routine.botId)
      if (!bot) {
        this.store.deleteRoutine(routine.id)
        this.running.delete(routine.id)
        continue
      }

      try {
        await this.sessions.runRoutine(routine, bot)
      } catch {
        // A failed run is a failed turn; the next one is already booked.
      } finally {
        this.running.delete(routine.id)
      }
    }
  }

  /** What the daemon prints at boot, so a schedule is visible without opening the app. */
  summary(): string {
    const routines = this.store.listRoutines().filter((r) => r.enabled)
    if (routines.length === 0) return 'routines: none'
    return `routines: ${routines
      .map((r) => `${r.name} (${describeSchedule(r.schedule)})`)
      .join(', ')}`
  }
}
