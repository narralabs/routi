import assert from 'node:assert/strict'
import { test, type TestContext } from 'node:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { OpenAiSubscriptionAdapter } from '../src/providers/openai-subscription.js'
import type { AppServerEvent } from '../src/providers/codex-app-server.js'
import type { Json } from '../src/providers/json-rpc-stdio.js'
import { providerKey, type ChatRequest } from '../src/providers/types.js'
import { SessionManager } from '../src/sessions/manager.js'
import { Store } from '../src/db/store.js'
import { openDb } from '../src/db/schema.js'
import type { ServerEvent } from '@routi/protocol'

async function collect<T>(stream: AsyncIterable<T>): Promise<T[]> {
  const values: T[] = []
  for await (const value of stream) values.push(value)
  return values
}

// Synthetic app-server responses; no CLI, account, network, or model calls.
const supported = { id: 'picker-id', model: 'available-model', displayName: 'Available', isDefault: true }
const request: ChatRequest = {
  conversationId: 'conversation', botId: 'bot', systemPrompt: '', model: 'default',
  history: [], input: [{ type: 'text', text: 'Hello' }],
}
function setup(t: TestContext, events: AppServerEvent[] = []) {
  const dir = mkdtempSync(join(tmpdir(), 'routi-codex-test-'))
  const calls: { method: string; params: Json }[] = []
  let catalogue = (_params: Json): Json => ({ data: [supported], nextCursor: null })
  const adapter = new OpenAiSubscriptionAdapter({ cwd: dir, dataDir: dir, mcpBaseUrl: 'http://unused', ownLogin: true }, (opts) => ({
    async ready() {}, dispose() {},
    async request(method, raw): Promise<Json> {
      const params = raw as Json
      calls.push({ method, params })
      if (method === 'model/list') return catalogue(params)
      if (method === 'thread/start') return { thread: { id: 'thread' } }
      if (method === 'turn/start') {
        for (const event of events) opts.onEvent({ ...event, params: { threadId: 'thread', ...event.params } })
        return { turn: { id: 'turn' } }
      }
      throw new Error(`Unexpected request ${method}`)
    },
  }))
  t.after(() => { adapter.dispose(); rmSync(dir, { recursive: true, force: true }) })
  return { adapter, calls, setCatalogue(fn: typeof catalogue) { catalogue = fn } }
}
const completion = (status: string, error?: unknown): AppServerEvent => ({ method: 'turn/completed', params: { turn: { status, error } } })
const failure = { message: 'This model is not supported with a ChatGPT account.' }

test('a failed Codex completion surfaces its error and removes the empty chat reply', { timeout: 5000 }, async (t) => {
  const { adapter } = setup(t, [completion('failed', failure)])
  const db = openDb(':memory:')
  t.after(() => db.close())
  const store = new Store(db)
  store.ensureDefaultProfile()
  const { bot, conversation } = store.createBot({ name: 'Probe', provider: 'openai-codex' })
  const events: ServerEvent[] = []
  let complete!: () => void
  const completed = new Promise<void>((r) => { complete = r })
  const sessions = new SessionManager(store, new Map([[providerKey(bot.profileId, bot.provider), adapter]]), (event) => {
    events.push(event)
    if (event.e === 'message.completed') complete()
  })
  await sessions.send(conversation.id, request.input)
  await completed
  assert.equal(sessions.isBusy(conversation.id), false)
  assert.equal(store.listMessages(conversation.id).filter((m) => m.role === 'assistant').length, 0)
  assert.ok(events.some((e) => e.e === 'error' && e.message === failure.message))
  assert.ok(events.some((e) => e.e === 'message.completed' && e.stopReason === 'error'))
})

test('terminal errors are emitted once; transient retry warnings do not fail a successful turn', { timeout: 5000 }, async (t) => {
  const terminal = setup(t, [{ method: 'error', params: { error: failure, willRetry: false } }, completion('failed')])
  assert.deepEqual(await collect(terminal.adapter.stream(request, new AbortController().signal)), [
    { type: 'error', code: 'turn_failed', message: failure.message },
  ])
  const retry = setup(t, [{ method: 'error', params: { error: failure, willRetry: true } }, completion('completed')])
  assert.deepEqual(await collect(retry.adapter.stream(request, new AbortController().signal)), [
    { type: 'done', stopReason: 'end_turn', meta: {} },
  ])
  const interrupted = setup(t, [completion('interrupted')])
  assert.deepEqual(await collect(interrupted.adapter.stream(request, new AbortController().signal)), [
    { type: 'done', stopReason: 'interrupted', meta: {} },
  ])
})

test('model discovery follows pages, filters hidden entries, uses runtime model names, and refreshes', async (t) => {
  const { adapter, calls, setCatalogue } = setup(t)
  setCatalogue((p) => p.cursor ? { data: [supported], nextCursor: null } : {
    data: [{ id: 'hidden', hidden: true }], nextCursor: 'page2',
  })
  assert.deepEqual((await adapter.listModels()).map((m) => m.id), ['default', 'available-model'])
  assert.ok(calls.every((c) => c.params.includeHidden === false))
  setCatalogue(() => ({ data: [{ id: 'replacement', isDefault: true }], nextCursor: null }))
  assert.deepEqual((await adapter.listModels()).map((m) => m.id), ['default', 'replacement'])
})

test('an obsolete saved model fails before starting a thread or consuming tokens', async (t) => {
  const { adapter, calls } = setup(t)
  const events = await collect(adapter.stream({ ...request, model: 'retired-model' }, new AbortController().signal))
  assert.ok(events.some((e) => e.type === 'error' && e.code === 'model_unavailable' && e.message.includes('retired-model')))
  assert.ok(calls.every((c) => c.method === 'model/list'))
})

test('Default explicitly selects the current catalog default, including on a warm thread', async (t) => {
  const { adapter, calls, setCatalogue } = setup(t, [completion('completed')])
  await collect(adapter.stream(request, new AbortController().signal))
  setCatalogue(() => ({ data: [{ id: 'next-default', isDefault: true }], nextCursor: null }))
  await collect(adapter.stream(request, new AbortController().signal))
  assert.deepEqual(calls.filter((c) => c.method === 'turn/start').map((c) => c.params.model), ['available-model', 'next-default'])
  assert.equal(calls.filter((c) => c.method === 'thread/start').length, 1)
})
