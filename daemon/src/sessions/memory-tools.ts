import type { Memory } from '@routi/protocol'
import type { Store } from '../db/store.js'
import type { ToolContext } from '../surfaces/tools.js'

/**
 * How many notes a scope may hold, and how long one may be.
 *
 * The notes are read into every turn, so they are bounded — not because a hundred is
 * many, but because a bot that writes one per message will reach a thousand, and at
 * that point the notes are the transcript again, which is the thing they exist to be
 * smaller than. Past the prompt's own cap they are still there, for `recall`.
 */
export const MEMORY_LIMIT = 500
export const NOTE_LIMIT = 600

/** What the person and the app are told about a note being written. Null means shared. */
export type MemoryOwner = string | null

/**
 * The memory verbs, bound to one bot.
 *
 * `onChange` is how the app finds out: a note written mid-turn should appear in the
 * rail while the bot is still talking, not after the person next clicks something. It
 * is told whose notes moved — this bot's, or everyone's.
 */
export function memoryTools(
  store: Store,
  botId: string,
  onChange: (owner: MemoryOwner) => void,
): NonNullable<ToolContext['memory']> {
  return {
    remember(raw, shared = false) {
      const text = raw.trim().replace(/\s+/g, ' ')
      if (!text) return { ok: false, why: 'A note needs some text.' }
      if (text.length > NOTE_LIMIT) {
        return { ok: false, why: `That is too long for one note. Keep it under ${NOTE_LIMIT} characters, or split it.` }
      }

      const existing = shared ? store.listSharedMemories() : store.listMemories(botId)
      // The likeliest mistake is saving what is already there: the notes are shown at
      // the top of every turn, and a model re-reads them and re-saves them.
      const same = existing.find((m) => m.text.toLowerCase() === text.toLowerCase())
      if (same) return { ok: true, already: true }

      if (existing.length >= MEMORY_LIMIT) {
        return {
          ok: false,
          why: `There are already ${MEMORY_LIMIT} notes here. Forget one that no longer matters before adding another.`,
        }
      }

      store.addMemory({ botId, scope: shared ? 'user' : 'bot', text, source: 'bot' })
      onChange(shared ? null : botId)
      return { ok: true, already: false }
    },

    /**
     * Forgiving on the match, as routine removal is.
     *
     * The model quotes a note back imperfectly — trimmed, paraphrased at the edges, or
     * with the date prefix it was shown with. The exact text first; then a note that
     * contains what was given; then a note contained by it. The bot's own notes are
     * searched before the shared ones, so it removes what is nearest to hand.
     */
    forget(raw) {
      const wanted = stripDate(raw).toLowerCase()
      if (!wanted) return false
      const { own, shared } = store.memoriesFor(botId)
      const notes = [...own, ...shared]
      const target =
        notes.find((m) => m.text.toLowerCase() === wanted) ??
        notes.find((m) => m.text.toLowerCase().includes(wanted)) ??
        notes.find((m) => wanted.includes(m.text.toLowerCase()))
      if (!target) return false
      store.deleteMemory(target.id)
      onChange(target.scope === 'user' ? null : botId)
      return true
    },

    /**
     * Every note that mentions the query, however old.
     *
     * The prompt shows the newest notes that fit; this is how the rest stay reachable.
     * Word-wise rather than as one phrase — a model asks for "hotel paris" and the note
     * says "the hotel in Paris" — and every word has to appear.
     */
    recall(query) {
      const words = query.toLowerCase().split(/\s+/).filter((w) => w.length > 1)
      if (words.length === 0) return []
      const { own, shared } = store.memoriesFor(botId)
      return [...own, ...shared]
        .filter((m) => {
          const text = m.text.toLowerCase()
          return words.every((w) => text.includes(w))
        })
        .slice(-20)
        .map((m) => ({ text: m.text, date: dateOf(m), shared: m.scope === 'user' }))
    },
  }
}

const dateOf = (m: Memory): string => new Date(m.createdAt).toISOString().slice(0, 10)
const stripDate = (text: string): string => text.trim().replace(/^\[\d{4}-\d{2}-\d{2}\]\s*/, '')

/**
 * The notes as the bot reads them, dated so a fact has an age.
 *
 * Shared notes first — they are about the person and set the scene — then the bot's
 * own, oldest first, because that is the order they were learned in and the order a
 * later note corrects an earlier one. Bounded in characters as well as count so a bot
 * with long notes does not spend its whole context on them; what falls off the top is
 * still there for `recall`.
 */
export function renderMemory(memory: { own: Memory[]; shared: Memory[] }, maxChars = 8_000): string {
  const shared = memory.shared.map((m) => `- [${dateOf(m)}] ${m.text}`)
  const own = memory.own.map((m) => `- [${dateOf(m)}] ${m.text}`)

  // The shared notes are few and always shown; the cap falls on the bot's own.
  const sharedChars = shared.reduce((n, line) => n + line.length + 1, 0)
  let budget = Math.max(maxChars - sharedChars, 1_000)
  let start = own.length
  while (start > 0 && own[start - 1]!.length + 1 <= budget) {
    budget -= own[start - 1]!.length + 1
    start--
  }
  const hidden = start

  return [
    shared.length > 0 ? 'About the person, shared with every bot:' : 'Nothing is noted about the person yet.',
    ...shared,
    '',
    own.length > 0 ? 'Your own notes, oldest first:' : 'You have no notes of your own yet.',
    ...own.slice(start),
    hidden > 0 ? `(${hidden} older note${hidden === 1 ? '' : 's'} not shown; recall searches them.)` : '',
  ]
    .filter((line, i, all) => line !== '' || all[i - 1] !== '')
    .join('\n')
}
