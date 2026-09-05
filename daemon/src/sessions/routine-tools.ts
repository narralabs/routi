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

    remove(name) {
      const target = store
        .listRoutines(botId)
        .find((r) => r.name.toLowerCase() === name.trim().toLowerCase())
      if (!target) return false
      store.deleteRoutine(target.id)
      return true
    },
  }
}
