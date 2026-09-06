/**
 * Does a custom systemPrompt actually define the bot, or is something else leaking in?
 */
import { query } from '@anthropic-ai/claude-agent-sdk'

delete process.env.ANTHROPIC_API_KEY

async function ask(label: string, options: Record<string, unknown>): Promise<void> {
  let text = ''
  const q = query({
    prompt: 'In one sentence: who are you and what do you do?',
    options: { maxTurns: 1, includePartialMessages: true, persistSession: false, ...options } as never,
  })
  for await (const m of q) {
    if (m.type === 'stream_event') {
      const ev = m.event
      if (ev.type === 'content_block_delta' && ev.delta.type === 'text_delta') text += ev.delta.text
    }
    if (m.type === 'result') break
  }
  console.log(`\n  [${label}]\n  ${text.trim().slice(0, 260)}`)
}

const persona = { type: 'custom' as const, prompt: 'You are a dry, deadpan assistant named Mortimer.' }

await ask('systemPrompt only', { systemPrompt: persona, tools: [] })
await ask('+ settingSources: []', { systemPrompt: persona, tools: [], settingSources: [] })
await ask('+ mcpServers: {}', { systemPrompt: persona, tools: [], settingSources: [], mcpServers: {} })
process.exit(0)
