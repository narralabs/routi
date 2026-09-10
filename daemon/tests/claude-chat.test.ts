import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { Query, SDKMessage } from '@anthropic-ai/claude-agent-sdk'
import type { Block } from '@routi/protocol'
import { AnthropicSubscriptionAdapter } from '../src/providers/anthropic-subscription.js'
import { providerKey } from '../src/providers/types.js'
import { SessionManager } from '../src/sessions/manager.js'
import { Store } from '../src/db/store.js'
import { openDb } from '../src/db/schema.js'

// Only the SDK fields consumed by the adapter are needed in this recorded-shape
// fixture. The important boundary is message_start resetting the SDK block index.
function event(event: Record<string, unknown>): SDKMessage {
  return { type: 'stream_event', event, parent_tool_use_id: null } as unknown as SDKMessage
}
function text(index: number, value: string): SDKMessage[] {
  return [
    event({ type: 'content_block_start', index, content_block: { type: 'text', text: '' } }),
    event({ type: 'content_block_delta', index, delta: { type: 'text_delta', text: value } }),
    event({ type: 'content_block_stop', index }),
  ]
}
const start = () => event({ type: 'message_start' })
const finish = () => ({ type: 'result', subtype: 'success', duration_ms: 1, usage: {} }) as SDKMessage

const toolTurn: SDKMessage[] = [
  start(),
  ...text(0, "I'll open the browser."),
  event({ type: 'content_block_start', index: 1, content_block: {
    type: 'tool_use', id: 'tool-1', name: 'mcp__desktop__open_url', input: {},
  } }),
  event({ type: 'message_stop' }),
  { type: 'user', message: { role: 'user', content: [{
    type: 'tool_result', tool_use_id: 'tool-1', content: 'Opened',
  }] } } as SDKMessage,
  start(),
  event({ type: 'content_block_start', index: 0, content_block: { type: 'thinking', thinking: '' } }),
  event({ type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: 'Page loaded.' } }),
  ...text(1, 'The page is open.'),
  event({ type: 'message_stop' }),
  // Another model response also restarts at zero.
  start(),
  ...text(0, 'Here is the summary.'),
  // The SDK also emits completed assistant messages; these must not duplicate text.
  { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'Here is the summary.' }] } } as SDKMessage,
  finish(),
]

test('Claude tool round-trips preserve earlier text live and in storage, and reset indexes for the next user turn', { timeout: 5_000 }, async (t) => {
  const db = openDb(':memory:')
  const store = new Store(db)
  store.ensureDefaultProfile()
  const { bot, conversation } = store.createBot({ name: 'Screenshot Bot', provider: 'anthropic-claude' })
  let queryCount = 0
  const adapter = new AnthropicSubscriptionAdapter({ cwd: '/tmp', mcpBaseUrl: 'http://127.0.0.1:7172' }, ({ prompt }) => {
    queryCount++
    assert.notEqual(typeof prompt, 'string')
    const input = prompt as AsyncIterable<unknown>
    const messages = (async function* () {
      let turn = 0
      for await (const _ of input) {
        yield* turn++ === 0 ? toolTurn : [start(), ...text(0, 'Next reply.'), finish()]
      }
    })()
    return Object.assign(messages, { close() {}, async interrupt() {} }) as Query
  })
  t.after(() => { adapter.dispose(); db.close() })

  let complete!: () => void
  let completed = new Promise<void>((resolve) => { complete = resolve })
  const live: Block[][] = []
  const indexes: number[] = []
  const sessions = new SessionManager(store, new Map([[providerKey(bot.profileId, bot.provider), adapter]]), (ev) => {
    if (ev.e === 'message.block') indexes.push(ev.blockIndex)
    if (ev.e === 'message.delta') {
      live.push(structuredClone(sessions.liveMessage(conversation.id)?.blocks ?? []))
    }
    if (ev.e === 'message.completed') complete()
  })
  await sessions.send(conversation.id, [{ type: 'text', text: 'Open the browser' }])
  await completed
  const expected: Block[] = [
    { type: 'text', text: "I'll open the browser." },
    { type: 'tool_use', id: 'tool-1', name: 'mcp__desktop__open_url', input: {}, status: 'running' },
    { type: 'thinking', text: 'Page loaded.' },
    { type: 'text', text: 'The page is open.' },
    { type: 'text', text: 'Here is the summary.' },
  ]
  assert.deepEqual(indexes, [0, 1, 2, 3, 4])
  assert.ok(live.length >= 4)
  for (const blocks of live) assert.deepEqual(blocks[0], expected[0], 'the first sentence must remain visible throughout the turn')
  assert.deepEqual(live.at(-1), expected)
  const first = store.listMessages(conversation.id).find((m) => m.role === 'assistant')!
  assert.deepEqual(first.blocks, expected)

  completed = new Promise<void>((resolve) => { complete = resolve })
  indexes.length = 0
  await sessions.send(conversation.id, [{ type: 'text', text: 'Thanks' }])
  await completed
  assert.equal(queryCount, 1, 'the next turn reuses the warm SDK session')
  assert.deepEqual(indexes, [0])
  const replies = store.listMessages(conversation.id).filter((m) => m.role === 'assistant')
  assert.equal(replies.length, 2)
  assert.deepEqual(replies[0]?.blocks, expected)
  assert.deepEqual(replies[1]?.blocks, [{ type: 'text', text: 'Next reply.' }])
})
