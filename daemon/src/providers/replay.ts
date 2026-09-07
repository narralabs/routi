import type { Message } from '@routi/protocol'

/**
 * The transcript so far, as one block of text, for a harness session that has lost it.
 *
 * A harness adapter keeps a warm session and ignores `history` because the model's own
 * context beats a reconstruction of it. That holds only while the session exists. After
 * a restart the session is resumed by id where the runtime allows it; when it cannot
 * be — the id was never kept, the runtime has forgotten it, its files were cleared —
 * the bot would otherwise start blank in the middle of a conversation the person can
 * still scroll. This is the second-best thing: what was said, oldest first, ahead of
 * the new turn.
 *
 * Text only. Tool calls and images are named rather than carried, since the point is
 * what was decided, not what was clicked.
 */
export function replayTranscript(history: Message[], botId: string, maxChars = 12_000): string | null {
  const lines: string[] = []
  for (const message of history) {
    const text = message.blocks
      .map((block) => {
        if (block.type === 'text') return block.text.trim()
        if (block.type === 'image') return '[an image]'
        if (block.type === 'tool_use') return `[used ${block.name}]`
        return ''
      })
      .filter(Boolean)
      .join('\n')
    if (!text) continue
    const who = message.role === 'user' ? 'Person' : message.botId && message.botId !== botId ? 'Another bot' : 'You'
    lines.push(`${who}: ${text}`)
  }
  if (lines.length === 0) return null

  // Newest kept; the oldest is what falls off when it is too long.
  let body = lines.join('\n\n')
  let dropped = 0
  while (body.length > maxChars && lines.length > 1) {
    lines.shift()
    dropped++
    body = lines.join('\n\n')
  }

  return [
    'You were restarted and have lost your working memory of this conversation. Here is',
    'the transcript so far, oldest first. Carry on as though you remembered it, and do',
    'not mention the restart unless asked.',
    dropped > 0 ? `(${dropped} earlier message${dropped === 1 ? '' : 's'} omitted.)` : '',
    '',
    body,
    '',
    '--- end of transcript; the new message follows ---',
  ]
    .filter((line, i, all) => line !== '' || (i > 0 && all[i - 1] !== ''))
    .join('\n')
}
