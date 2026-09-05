/**
 * M0 spike #2: warm sessions.
 *
 * The first spike showed ~3.5-4.2s TTFT, nearly all of it CLI process spawn. If krogd
 * spawned a process per message, every message in the app would carry that penalty.
 *
 * This proves the alternative: hold ONE query() open per conversation, feed it user
 * messages over time via a push queue, and pay the spawn cost once. It also asks
 * accountInfo() which credential is actually in use, and lists the models available
 * to it for the per-bot model picker.
 *
 * Run: pnpm --filter krogd spike:session
 */
import { query, type SDKUserMessage } from '@anthropic-ai/claude-agent-sdk'

delete process.env.ANTHROPIC_API_KEY

/** An async iterable you can push into — this is what keeps the session warm. */
function pushQueue<T>() {
  const buf: T[] = []
  let wake: (() => void) | null = null
  let done = false
  return {
    push(v: T) {
      buf.push(v)
      wake?.()
      wake = null
    },
    end() {
      done = true
      wake?.()
      wake = null
    },
    async *[Symbol.asyncIterator]() {
      for (;;) {
        while (buf.length) yield buf.shift() as T
        if (done) return
        await new Promise<void>((r) => (wake = r))
      }
    },
  }
}

const userMsg = (text: string): SDKUserMessage => ({
  type: 'user',
  message: { role: 'user', content: text },
  parent_tool_use_id: null,
  session_id: '',
})

const input = pushQueue<SDKUserMessage>()

const q = query({
  prompt: input,
  options: {
    model: 'claude-opus-5',
    systemPrompt: { type: 'custom', prompt: 'You are a concise assistant. Answer in one short sentence.' },
    tools: [],
    includePartialMessages: true,
    persistSession: false,
  },
})

// --- who are we authenticated as? -------------------------------------------
const acct = await q.accountInfo()
console.log('  --- credential in use ---')
console.log(`  subscriptionType: ${acct.subscriptionType ?? '(none)'}`)
console.log(`  tokenSource:      ${acct.tokenSource ?? '(none)'}`)
console.log(`  apiKeySource:     ${acct.apiKeySource ?? '(none)'}`)
console.log(`  apiProvider:      ${acct.apiProvider ?? '(none)'}`)
console.log(`  organization:     ${acct.organization ?? '(none)'}`)

const models = await q.supportedModels()
console.log(`\n  --- ${models.length} models available to the picker ---`)
for (const m of models) {
  const effort = m.supportsEffort ? ` effort=[${m.supportedEffortLevels?.join(',')}]` : ''
  console.log(`  ${m.value.padEnd(28)} ${m.displayName.padEnd(20)} -> ${m.resolvedModel ?? '(alias)'}${effort}`)
}

// --- two turns on one warm process ------------------------------------------
const turns = ['Name one analog synthesizer.', 'Now name a different one.']
let turnIdx = 0
let t0 = Date.now()
let ttft: number | null = null
const timings: { turn: number; ttft: number; total: number }[] = []

console.log('\n  --- turns ---')
input.push(userMsg(turns[0]!))
process.stdout.write(`  [1] `)

for await (const msg of q) {
  if (msg.type === 'stream_event') {
    const ev = msg.event
    if (ev.type === 'content_block_delta' && ev.delta.type === 'text_delta') {
      if (ttft === null) ttft = Date.now() - t0
      process.stdout.write(ev.delta.text)
    }
  } else if (msg.type === 'result') {
    timings.push({ turn: turnIdx + 1, ttft: ttft ?? -1, total: Date.now() - t0 })
    turnIdx++
    if (turnIdx < turns.length) {
      ttft = null
      t0 = Date.now()
      process.stdout.write(`\n  [${turnIdx + 1}] `)
      input.push(userMsg(turns[turnIdx]!))
    } else {
      input.end()
      break
    }
  }
}
q.close()

console.log('\n\n  --- timings ---')
for (const t of timings) {
  console.log(`  turn ${t.turn}:  ttft ${t.ttft}ms   total ${t.total}ms`)
}
const [first, second] = timings
if (first && second) {
  console.log(`\n  warm-session saving on turn 2: ${first.ttft - second.ttft}ms of TTFT`)
}
