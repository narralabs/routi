import assert from 'node:assert/strict'
import { test } from 'node:test'
import type Anthropic from '@anthropic-ai/sdk'
import { AnthropicApiAdapter } from '../src/providers/anthropic-api.js'
import type { ProviderEvent } from '../src/providers/types.js'

test('Anthropic API runs external tools without a screen and preserves text across tool rounds', async () => {
  const requests: Record<string, unknown>[] = []
  const client = { messages: { stream: (request: Record<string, unknown>) => {
    requests.push(structuredClone(request))
    const content = requests.length === 1
      ? [{ type: 'text', text: 'Checking your account.' }, { type: 'tool_use', id: 'call1', name: 'robinhood_call_tool', input: { name: 'get_accounts', arguments: {} } }]
      : [{ type: 'text', text: 'Your account is available.' }]
    return {
      async *[Symbol.asyncIterator]() {
        for (const [index, block] of content.entries()) yield { type: 'content_block_start', index, content_block: block }
      },
      finalMessage: async () => ({ content, model: 'fake', stop_reason: requests.length === 1 ? 'tool_use' : 'end_turn', usage: { input_tokens: 10, output_tokens: 5 } }),
    }
  } } } as unknown as Anthropic
  let called = false
  const adapter = new AnthropicApiAdapter('unused', client)
  const events: ProviderEvent[] = []
  for await (const event of adapter.stream({
    botId: 'bot', conversationId: 'chat', model: 'default', systemPrompt: '', history: [], input: [{ type: 'text', text: 'Check my account' }],
    hasSurface: false,
    toolContext: { external: {
      specs: [{ name: 'robinhood_call_tool', description: 'Call Robinhood', parameters: { type: 'object' } }],
      run: async (name, args) => { assert.equal(name, 'robinhood_call_tool'); assert.equal(args['name'], 'get_accounts'); called = true; return { ok: true, output: 'fake account', summary: 'Checked account' } },
    } },
  }, new AbortController().signal)) events.push(event)
  assert.ok(called)
  assert.equal(requests.length, 2)
  assert.match(JSON.stringify(requests[1]?.messages), /tool_result/)
  assert.match(JSON.stringify(requests[1]?.messages), /fake account/)
  const endings = events.filter(e => e.type === 'block_end')
  assert.deepEqual(endings.map(e => e.index), [0, 1, 2])
  assert.equal(endings[0]?.block.type, 'text')
  assert.equal(endings[2]?.block.type, 'text')
  const done = events.find(e => e.type === 'done')
  assert.deepEqual(done?.meta['usage'], { input_tokens: 20, output_tokens: 10 })
})
