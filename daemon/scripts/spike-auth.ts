/**
 * M0 auth spike.
 *
 * Proves the single assumption the whole architecture rests on: that routid, running
 * as a background process on the Mac mini, can stream from Claude using the
 * subscription login already on the box — with no ANTHROPIC_API_KEY anywhere.
 *
 * Run: pnpm --filter routid spike
 */
import { query } from '@anthropic-ai/claude-agent-sdk'

// Prove it is genuinely the subscription and not a stray key in the environment.
const strayKey = process.env.ANTHROPIC_API_KEY
if (strayKey) {
  console.log(`  ! ANTHROPIC_API_KEY was set (${strayKey.slice(0, 12)}…) — unsetting so this tests the subscription path`)
  delete process.env.ANTHROPIC_API_KEY
}

const t0 = Date.now()
let ttftMs: number | null = null
let text = ''
let sessionId: string | null = null
let model: string | null = null
let sawStreamEvents = false

const q = query({
  prompt: 'In one short sentence, what is a synthesizer?',
  options: {
    model: 'claude-opus-5',
    // A chat bot, not a coding agent: no tools, no claude_code preset.
    systemPrompt: { type: 'custom', prompt: 'You are a concise assistant.' },
    tools: [],
    maxTurns: 1,
    includePartialMessages: true,
    persistSession: false,
  },
})

try {
  for await (const msg of q) {
    switch (msg.type) {
      case 'system':
        if ('session_id' in msg) sessionId = msg.session_id
        break

      case 'stream_event': {
        sawStreamEvents = true
        const ev = msg.event
        if (ev.type === 'message_start') {
          model = ev.message.model
        } else if (ev.type === 'content_block_delta' && ev.delta.type === 'text_delta') {
          if (ttftMs === null) ttftMs = Date.now() - t0
          text += ev.delta.text
          process.stdout.write(ev.delta.text)
        }
        break
      }

      case 'assistant':
        if (msg.error) {
          console.error(`\n  x assistant error: ${msg.error}`)
          process.exitCode = 1
        }
        break

      case 'result': {
        const totalMs = Date.now() - t0
        console.log('\n')
        console.log('  --- spike result ---')
        console.log(`  subtype:        ${msg.subtype}`)
        console.log(`  model:          ${model ?? '(unknown)'}`)
        console.log(`  session_id:     ${sessionId ?? '(none)'}`)
        console.log(`  stream events:  ${sawStreamEvents ? 'yes' : 'NO — deltas would not work'}`)
        console.log(`  ttft:           ${ttftMs ?? '—'} ms`)
        console.log(`  total:          ${totalMs} ms`)
        console.log(`  chars:          ${text.length}`)
        if ('total_cost_usd' in msg) {
          // Subscription turns report 0 here; API-key turns report a real cost.
          console.log(`  cost_usd:       ${msg.total_cost_usd}`)
        }
        if (msg.subtype !== 'success') process.exitCode = 1
        break
      }
    }
  }
} catch (err) {
  console.error('\n  x spike failed:', err instanceof Error ? err.message : err)
  process.exitCode = 1
}
