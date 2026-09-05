import type { Bot } from '@krog/protocol'

/**
 * Who a message wakes.
 *
 * A room's cost is not its words, it is the number of bots scheduled for a turn, and
 * its failure mode is not expense but recursion: two bots acknowledging each other
 * forever. Both are settled by one rule.
 *
 * A message from a **bot** wakes only the bots it names. Nothing else. That is the
 * whole loop break — a bot cannot start a conversation with another bot by accident,
 * only by deliberately addressing it — and it costs nothing to enforce, unlike hop
 * counters and cooldowns which have to be tuned and still leak.
 *
 * A message from a **person** is allowed to wake the room, because a person asking
 * their assistants a question is the thing rooms are for.
 */

/**
 * Names mentioned with @, matched loosely against the bots actually present.
 *
 * `@everyone` is a person's privilege. A bot able to wake the room with one word is
 * the loop rule with a hole in it — one bot writes it, three wake, any of them can
 * write it again — so a bot has to name the teammate it actually needs.
 */
export function mentionedBots(text: string, members: Bot[], allowEveryone = true): Bot[] {
  const lower = text.toLowerCase()
  if (allowEveryone && /@everyone\b/.test(lower)) return members

  return members.filter((bot) => {
    const name = bot.name.toLowerCase()
    // "@Ice Machine Bot 2" and "@Ice" should both reach it: a person writing a mention
    // will not reliably type a four-word name, and a bot addressing a teammate has no
    // autocomplete at all.
    const first = name.split(/\s+/)[0] ?? name
    return lower.includes(`@${name}`) || new RegExp(`@${escape(first)}\\b`).test(lower)
  })
}

function escape(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

export interface Wake {
  bots: Bot[]
  reason: 'mentioned' | 'everyone' | 'addressed-room' | 'none'
}

/**
 * Decides who answers a message just posted to a room.
 *
 * `authorBotId` is null for a person. Silence is a valid outcome and the common one:
 * an empty list means nobody was asked, so nobody speaks.
 */
export function wakeFor(
  text: string,
  members: Bot[],
  authorBotId: string | null,
): Wake {
  const others = members.filter((bot) => bot.id !== authorBotId)

  if (authorBotId !== null) {
    // From a bot: named teammates only. Never the room, and never @everyone.
    const named = mentionedBots(text, others, false)
    return { bots: named, reason: named.length > 0 ? 'mentioned' : 'none' }
  }

  if (/@everyone\b/i.test(text)) return { bots: others, reason: 'everyone' }
  const mentioned = mentionedBots(text, others)
  if (mentioned.length > 0) return { bots: mentioned, reason: 'mentioned' }

  // A person talking to the room with nobody named. Everyone may answer — and is told
  // they need not — because refusing to answer an unaddressed question would make a
  // room feel broken, where an unnecessary reply merely makes it chatty.
  return { bots: others, reason: 'addressed-room' }
}

/**
 * What a bot is told about being in a room.
 *
 * Mostly permission to say nothing. Left to itself a model answers every message it is
 * shown, which in a room of four is four replies to every remark and a conversation
 * that never settles.
 */
export function channelInstructions(self: Bot, members: Bot[]): string {
  const others = members.filter((bot) => bot.id !== self.id).map((bot) => bot.name)

  return [
    `You are ${self.name}, in a group chat with ${others.join(', ') || 'no one else yet'} and the person you work for.`,
    '',
    'Speak only as yourself. Never write a message as though you were another bot or',
    'the person.',
    '',
    'Say nothing unless you have something to add. Ending your turn without a message',
    'is normal and often right: agreement, acknowledgement and "sounds good" are noise',
    'in a room this size. If someone else has already answered well, stay quiet.',
    '',
    'Keep it to a few sentences. Report what you found or where you are stuck, not how',
    'you got there — your tools and working are private, and the room only wants the',
    'result.',
    '',
    'To ask a teammate for something, mention them by name with an @ — they will not',
    'see your message otherwise. Only do that when you actually need them, and name the',
    'one you need rather than the whole room.',
  ].join('\n')
}
