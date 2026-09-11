import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { test, type TestContext } from 'node:test'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { openDb } from '../src/db/schema.js'
import { Store } from '../src/db/store.js'
import { SessionManager } from '../src/sessions/manager.js'
import type { ServerEvent } from '@routi/protocol'
import { McpHttp } from '../src/server/mcp-http.js'
import { Handovers } from '../src/surfaces/handover.js'
import type { DesktopPool, Surface } from '../src/surfaces/pool.js'

async function setup(t: TestContext) {
  const db = openDb(':memory:')
  const store = new Store(db)
  store.ensureDefaultProfile()
  const first = store.createBot({ name: 'First', surfaceMode: 'none' })
  const second = store.createBot({ name: 'Second', surfaceMode: 'none' })
  const screen = store.createBot({ name: 'Screen', surfaceMode: 'host' })
  const memoryChanges: Array<string | null> = []
  const routineChanges: string[] = []
  const surface = {
    status: async () => ({ state: 'running', width: 800, height: 600 }),
    captureFrame: async () => ({ jpeg: Buffer.from('test-image') }),
  } as unknown as Surface
  const desktops = { for: (botId: string) => {
    assert.equal(botId, screen.bot.id, 'screenless tools must not resolve a desktop')
    return surface
  } } as DesktopPool
  const events: ServerEvent[] = []
  const sessions = new SessionManager(store, new Map(), (event) => events.push(event))
  const mcp = new McpHttp(desktops, store, new Handovers(() => {}),
    (owner) => memoryChanges.push(owner), (botId) => routineChanges.push(botId),
    (botId, conversationId, image) => sessions.attachImage(botId, conversationId, image))
  const server = createServer((req, res) => { void mcp.handle(req, res) })
  const clients: Client[] = []
  t.after(async () => {
    await Promise.all(clients.map((client) => client.close()))
    server.closeAllConnections()
    await new Promise<void>((resolve, reject) => server.close((err) => err ? reject(err) : resolve()))
    db.close()
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  assert.ok(address && typeof address !== 'string')
  const baseUrl = `http://127.0.0.1:${address.port}`
  const urlFor = (target: typeof first) => `${baseUrl}/mcp/${target.bot.id}/${target.conversation.id}`
  async function connect(target = first) {
    const client = new Client({ name: 'routi-test', version: '1.0.0' })
    clients.push(client)
    await client.connect(new StreamableHTTPClientTransport(new URL(urlFor(target))))
    return client
  }
  return { store, first, second, screen, surface, connect, urlFor, memoryChanges, routineChanges, events }
}

test('standard MCP client discovers tools and saves notes and structured routines in the URL context', async (t) => {
  const f = await setup(t)
  const client = await f.connect()
  assert.equal(client.getServerVersion()?.name, 'routi-desktop')
  await client.ping()
  const names = (await client.listTools()).tools.map((tool) => tool.name)
  assert.deepEqual(names.sort(), ['create_routine', 'delete_routine', 'forget', 'list_routines', 'recall', 'remember'])
  const note = await client.callTool({ name: 'remember', arguments: { text: 'Favourite bird is pelican' } })
  assert.equal(note.isError, false)
  assert.equal(f.store.listMemories(f.first.bot.id)[0]?.text, 'Favourite bird is pelican')
  assert.deepEqual(f.memoryChanges, [f.first.bot.id])
  const routine = await client.callTool({ name: 'create_routine', arguments: {
    name: 'Bird watch', prompt: 'Check the birds', schedule: { kind: 'interval', minutes: 15 },
  } })
  assert.equal(routine.isError, false)
  assert.equal(f.store.listRoutines(f.first.bot.id)[0]?.conversationId, f.first.conversation.id)
  assert.deepEqual(f.routineChanges, [f.first.bot.id])
  const other = await f.connect(f.second)
  const recall = await other.callTool({ name: 'recall', arguments: { query: 'pelican' } })
  assert.doesNotMatch(JSON.stringify(recall.content), /Favourite bird/)
  assert.deepEqual(f.store.listRoutines(f.second.bot.id), [])
})

test('HTTP MCP preserves images, screen gating, and execution errors', async (t) => {
  const f = await setup(t)
  const screen = await f.connect(f.screen)
  const names = (await screen.listTools()).tools.map((tool) => tool.name)
  assert.ok(names.includes('desktop_screenshot'))
  assert.ok(names.includes('browser_screenshot'))
  assert.ok(!names.includes('screenshot'))
  assert.ok(names.includes('ask_to_take_over'))
  const image = await screen.callTool({ name: 'desktop_screenshot', arguments: {} })
  assert.equal(image.isError, false)
  assert.deepEqual(image.content, [
    { type: 'image', data: Buffer.from('test-image').toString('base64'), mimeType: 'image/jpeg' },
    { type: 'text', text: 'Screen is 800x600 pixels.' },
  ])
  f.surface.captureFrame = async () => { throw new Error('Capture failed') }
  const failure = await screen.callTool({ name: 'desktop_screenshot', arguments: {} })
  assert.equal(failure.isError, true)
  assert.match(JSON.stringify(failure.content), /Capture failed/)
  const plain = await f.connect()
  assert.equal((await plain.callTool({ name: 'desktop_screenshot', arguments: {} })).isError, true)
  assert.equal((await plain.callTool({ name: 'create_routine', arguments: {
    name: 'Bad', prompt: 'Bad schedule', schedule: { kind: 'interval', minutes: 1 },
  } })).isError, true)
})

test('HTTP MCP acknowledges notifications and declines unsupported event streams', async (t) => {
  const f = await setup(t)
  const url = f.urlFor(f.first)
  assert.equal((await fetch(url)).status, 405)
  const initialized = await fetch(url, { method: 'POST', body: JSON.stringify({
    jsonrpc: '2.0', method: 'notifications/initialized',
  }) })
  assert.equal(initialized.status, 202)
  assert.equal(await initialized.text(), '')
  for (const body of ['{broken', 'null', '[]']) {
    assert.equal((await fetch(url, { method: 'POST', body })).status, 400)
  }
  const unknown = await fetch(url, { method: 'POST', body: JSON.stringify({
    jsonrpc: '2.0', id: 9, method: 'missing',
  }) })
  assert.deepEqual(await unknown.json(), {
    jsonrpc: '2.0', id: 9, error: { code: -32601, message: 'Unknown method: missing' },
  })
})

test('requested screenshots are saved and broadcast inline, while navigation captures remain private', async (t) => {
  const f = await setup(t)
  const client = await f.connect(f.screen)
  await client.callTool({ name: 'desktop_screenshot', arguments: {} })
  assert.equal(f.store.listMessages(f.screen.conversation.id).length, 0)
  const result = await client.callTool({ name: 'desktop_screenshot', arguments: { attach: true } })
  assert.equal(result.isError, false)
  assert.match(JSON.stringify(result.content), /attached to the conversation/)
  const messages = f.store.listMessages(f.screen.conversation.id)
  assert.equal(messages.length, 1)
  assert.equal(messages[0]?.botId, f.screen.bot.id)
  assert.deepEqual(messages[0]?.blocks, [{
    type: 'image', mediaType: 'image/jpeg', dataUrl: `data:image/jpeg;base64,${Buffer.from('test-image').toString('base64')}`,
  }])
  const created = f.events.find((event) => event.e === 'message.created')
  assert.ok(created?.e === 'message.created')
  assert.deepEqual(created.message, messages[0])
  assert.deepEqual(f.store.listMessages(f.first.conversation.id), [])

  // A URL cannot use one bot's screen to post into another bot's conversation.
  const wrong = await f.connect({ ...f.screen, conversation: f.first.conversation })
  assert.equal((await wrong.callTool({ name: 'desktop_screenshot', arguments: { attach: true } })).isError, true)
  assert.deepEqual(f.store.listMessages(f.first.conversation.id), [])
  f.surface.captureFrame = async () => { throw new Error('Capture unavailable') }
  assert.equal((await client.callTool({ name: 'desktop_screenshot', arguments: { attach: true } })).isError, true)
  assert.equal(f.store.listMessages(f.screen.conversation.id).length, 1)
})
