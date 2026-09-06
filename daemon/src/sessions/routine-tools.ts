import type { Store } from '../db/store.js'
import type { ToolContext } from '../surfaces/tools.js'
import { describeSchedule, parseSchedule } from './schedule.js'

/**
 * The routine verbs, bound to one bot and its conversation.
 *
 * A bot may only schedule work for itself. That is not a permission check so much as
 * the shape of the thing — a routine is a saved prompt plus who will be woken to run
 * it, and there is no sense in which one bot's routine could belong to another.
 */
export function routineTools(
  store: Store,
  botId: string,
  conversationId: string,
): NonNullable<ToolContext['routines']> {
  return {
    create(name, prompt, schedule) {
      if (!name || !prompt) return { ok: false, why: 'A routine needs both a name and a prompt.' }

      const parsed = parseSchedule(schedule)
      if (!parsed) {
        return {
          ok: false,
          why:
            'That schedule is not one I can keep. Use {"kind":"interval","minutes":N} with ' +
            'N at least 5, {"kind":"daily","at":"HH:MM"}, or ' +
            '{"kind":"weekly","weekday":0-6,"at":"HH:MM"}.',
        }
      }

      // Saving the same thing twice is the likeliest mistake: a bot that forgets it
      // already has a routine will make another every time it is asked.
      const existing = store.listRoutines(botId).find((r) => r.name.toLowerCase() === name.toLowerCase())
      if (existing) {
        return { ok: false, why: `You already have a routine called "${existing.name}".` }
      }

      const routine = store.createRoutine({ botId, conversationId, name, prompt, schedule: parsed })
      return { ok: true, described: describeSchedule(routine.schedule) }
    },

    list() {
      return store.listRoutines(botId).map((r) => ({
        name: r.name,
        described: describeSchedule(r.schedule),
        enabled: r.enabled,
      }))
    },

    /**
     * Forgiving on the name, because the model is not careful with it.
     *
     * Asked to remove its scan, a bot passed "US Open Kalshi scan — every 30 minutes":
     * the name and the schedule together, exactly as `list` had shown them. An exact
     * match found nothing, the tool said so, and the bot told the person the routine
     * was gone. So: the exact name first; then a routine whose name the given text
     * starts with; then, when the bot has only one, that one.
     */
    remove(name) {
      const routines = store.listRoutines(botId)
      const wanted = name.trim().toLowerCase()
      const target =
        routines.find((r) => r.name.toLowerCase() === wanted) ??
        routines.find((r) => wanted.startsWith(r.name.toLowerCase())) ??
        (routines.length === 1 ? routines[0] : undefined)
      if (!target) return false
      store.deleteRoutine(target.id)
      return true
    },
  }
}
