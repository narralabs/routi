import assert from 'node:assert/strict'
import { test, type TestContext } from 'node:test'
import type { ServerEvent } from '@routi/protocol'
import { openDb } from '../src/db/schema.js'
import { Store } from '../src/db/store.js'
import { providerKey, type ProviderAdapter } from '../src/providers/types.js'
import { SessionManager } from '../src/sessions/manager.js'

function signal() {
  let resolve!: () => void
  const promise = new Promise<void>((done) => { resolve = done })
  return { promise, resolve }
}

function setup(t: TestContext, stream: ProviderAdapter['stream']) {
  const db = openDb(':memory:')
  t.after(() => db.close())
  const store = new Store(db)
  store.ensureDefaultProfile()
  const { bot, conversation } = store.createBot({ name: 'Scout', provider: 'fake', surfaceMode: 'none' })
  const adapter: ProviderAdapter = {
    id: 'fake', supportsSurface: false, stream,
    async listModels() { return [] },
    async accountInfo() { return { authMode: 'api_key' } },
    release() {}, dispose() {},
  }
  const events: ServerEvent[] = []
  const completed = signal()
  const sessions = new SessionManager(
    store, new Map([[providerKey(bot.profileId, bot.provider), adapter]]),
    (event) => {
      events.push(event)
      if (event.e === 'message.completed') completed.resolve()
    },
  )
  return { store, bot, conversation, sessions, events, completed: completed.promise }
}

test('a streamed reply is visible mid-turn, then saved with its provider session', { timeout: 5_000 }, async (t) => {
  const paused = signal()
  const resume = signal()
  // Release a paused stream even if an assertion fails.
  t.after(() => resume.resolve())
  const { store, bot, conversation, sessions, events, completed } = setup(t, async function* (req) {
    assert.equal(req.botId, bot.id)
    assert.deepEqual(req.input, [{ type: 'text', text: 'Find a hotel' }])
    yield { type: 'block_start', index: 0, block: { type: 'text', text: '' } }
    yield { type: 'text_delta', index: 0, text: 'Found ' }
    paused.resolve()
    await resume.promise
    yield { type: 'text_delta', index: 0, text: 'a hotel' }
    yield { type: 'block_end', index: 0, block: { type: 'text', text: 'Found a hotel' } }
    yield { type: 'done', stopReason: 'end_turn', meta: { sessionId: 'fake-session' } }
  })

  await sessions.send(conversation.id, [{ type: 'text', text: 'Find a hotel' }])
  await paused.promise
  assert.equal(sessions.isBusy(conversation.id), true)
  assert.deepEqual(sessions.liveMessage(conversation.id)?.blocks, [{ type: 'text', text: 'Found ' }])
  resume.resolve()
  await completed

  const replies = store.listMessages(conversation.id).filter((m) => m.role === 'assistant')
  assert.equal(replies.length, 1)
  assert.deepEqual(replies[0]?.blocks, [{ type: 'text', text: 'Found a hotel' }])
  assert.deepEqual(store.getProviderSession(conversation.id, bot.id), { provider: 'fake', sessionId: 'fake-session' })
  assert.equal(sessions.isBusy(conversation.id), false)
  assert.equal(sessions.liveMessage(conversation.id), null)
  assert.ok(events.some((e) => e.e === 'message.delta'))
  assert.ok(events.some((e) => e.e === 'conversation.busy' && !e.busy))
})

test('a provider failure preserves the user message and clears the empty reply and busy state', { timeout: 5_000 }, async (t) => {
  const { store, conversation, sessions, events, completed } = setup(t, async function* () {
    throw new Error('Provider unavailable')
  })
  const user = await sessions.send(conversation.id, [{ type: 'text', text: 'Hello' }])
  await completed

  assert.deepEqual(store.listMessages(conversation.id), [user])
  assert.equal(sessions.isBusy(conversation.id), false)
  assert.equal(sessions.liveMessage(conversation.id), null)
  assert.ok(events.some((e) => e.e === 'error' && e.code === 'turn_failed'))
  assert.ok(events.some((e) => e.e === 'message.deleted'))
})
