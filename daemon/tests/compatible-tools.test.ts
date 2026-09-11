import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { test } from 'node:test'
import { OpenAiCompatibleAdapter } from '../src/providers/openai-compatible.js'
import type { DesktopPool, Surface } from '../src/surfaces/pool.js'
import type { ProviderEvent } from '../src/providers/types.js'

// A local Chat Completions fixture exercises the actual SDK/adapter tool loop.
// No vendor requests, credentials, containers, or model tokens are involved.
for (const hasSurface of [false, true]) {
  test(`compatible API selects and executes tools with screen access ${hasSurface}`, { timeout: 5000 }, async (t) => {
    const requests: { tools: { function: { name: string } }[]; messages: { role: string; content: unknown }[] }[] = []
    const calls = [
      { name: 'remember', arguments: JSON.stringify({ text: 'Synthetic note' }) },
      { name: 'list_routines', arguments: '{}' },
      // Deliberately request a screen tool even when it was not advertised: execution
      // must reject it without allocating a desktop, while general tools still work.
      { name: 'desktop_screenshot', arguments: '{}' },
    ]
    const server = createServer(async (req, res) => {
      let body = ''
      for await (const chunk of req) body += chunk
      requests.push(JSON.parse(body))
      const delta = requests.length === 1 ? {
        tool_calls: calls.map((fn, index) => ({ index, id: `call-${index}`, type: 'function', function: fn })),
      } : { content: 'Finished.' }
      res.writeHead(200, { 'content-type': 'text/event-stream' })
      res.end(`data: ${JSON.stringify({ choices: [{ index: 0, delta, finish_reason: null }] })}\n\ndata: [DONE]\n\n`)
    })
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', r))
    t.after(async () => {
      server.closeAllConnections()
      await new Promise<void>((r) => server.close(() => r()))
    })
    const address = server.address()
    assert.ok(address && typeof address !== 'string')
    let resolutions = 0
    let captures = 0
    let reads = 0
    const remembered: string[] = []
    const surface = {
      async status() { return { state: 'running', width: 800, height: 600 } },
      async captureFrame() { captures++; return { jpeg: Buffer.from('synthetic-image') } },
    } as unknown as Surface
    const pool = { for() { resolutions++; return surface } } as unknown as DesktopPool
    const adapter = new OpenAiCompatibleAdapter({
      id: 'fixture', baseURL: `http://127.0.0.1:${address.port}/v1`, keySource: 'fixture',
    }, 'fake-test-key', pool)
    t.after(() => adapter.dispose())
    const events: ProviderEvent[] = []
    for await (const event of adapter.stream({
      botId: 'bot', conversationId: 'chat', model: 'fixture', systemPrompt: '',
      input: [{ type: 'text', text: 'Use your tools' }], history: [], hasSurface,
      toolContext: {
        memory: {
          remember(text) { remembered.push(text); return { ok: true, already: false } },
          forget() { return false }, recall() { return [] },
        },
        routines: {
          create() { throw new Error('Not called') }, remove() { return false },
          list() { reads++; return [{ name: 'Fixture routine', described: 'daily', enabled: true }] },
        },
      },
    }, new AbortController().signal)) events.push(event)

    assert.equal(requests.length, 2)
    const offered = requests[0]!.tools.map((tool) => tool.function.name)
    for (const name of ['remember', 'recall', 'forget', 'create_routine', 'list_routines', 'delete_routine']) assert.ok(offered.includes(name))
    for (const name of ['desktop_screenshot', 'browser_screenshot', 'open_url', 'click']) assert.equal(offered.includes(name), hasSurface, name)
    assert.deepEqual(remembered, ['Synthetic note'])
    assert.equal(reads, 1)
    assert.equal(resolutions, hasSurface ? 1 : 0)
    assert.equal(captures, hasSurface ? 1 : 0)
    const completed = events.filter((e) => e.type === 'block_end' && e.block.type === 'tool_use')
    assert.deepEqual(completed.map((e) => e.type === 'block_end' && e.block.type === 'tool_use' ? e.block.status : null), ['done', 'done', hasSurface ? 'done' : 'error'])
    const results = requests[1]!.messages.filter((m) => m.role === 'tool')
    assert.equal(results.length, 3)
    assert.match(String(results[1]!.content), /Fixture routine/)
    if (!hasSurface) assert.match(String(results[2]!.content), /no screen/)
  })
}
