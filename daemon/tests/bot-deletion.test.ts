import assert from 'node:assert/strict'
import { test } from 'node:test'
import { openDb } from '../src/db/schema.js'
import { Store } from '../src/db/store.js'
import { SessionManager } from '../src/sessions/manager.js'
import { providerKey, type ProviderAdapter } from '../src/providers/types.js'
import { dispatch, type RpcContext } from '../src/server/rpc.js'
import type { DesktopPool } from '../src/surfaces/pool.js'

function setup(destroy: (id: string) => Promise<void>) {
  const db = openDb(':memory:')
  const store = new Store(db)
  store.ensureDefaultProfile()
  const a = store.createBot({ name: 'Delete me', provider: 'fake', surfaceMode: 'none' })
  const b = store.createBot({ name: 'Keep me', provider: 'fake', surfaceMode: 'none' })
  const released: string[] = []
  const calls: string[] = []
  const adapter: ProviderAdapter = {
    id: 'fake', supportsSurface: false,
    async listModels() { return [] }, async accountInfo() { return { authMode: 'api_key' } },
    async *stream(req, signal) {
      calls.push(req.botId)
      await new Promise<void>(resolve => signal.addEventListener('abort', () => resolve(), { once: true }))
      yield { type: 'done', stopReason: 'interrupted', meta: {} }
    },
    release(key) { released.push(key) }, dispose() { throw new Error('Shared adapter must survive') },
  }
  const sessions = new SessionManager(store, new Map([[providerKey('default', 'fake'), adapter]]), () => {},
    { destroy, beginDeletion() {}, endDeletion() {} } as unknown as DesktopPool)
  return { db, store, a, b, sessions, released, calls, adapter }
}

test('deletion cancels only its bot, drops queued work and removes records after desktop cleanup', async () => {
  const f = setup(async id => {
    if (id !== f.a.bot.id) return
    assert.ok(f.store.getBot(id), 'database row survives until cleanup succeeds')
    assert.equal(f.sessions.isBusy(f.a.conversation.id), false)
  })
  try {
    await f.sessions.send(f.a.conversation.id, [{ type: 'text', text: 'run' }])
    await f.sessions.send(f.a.conversation.id, [{ type: 'text', text: 'queued' }])
    await f.sessions.send(f.b.conversation.id, [{ type: 'text', text: 'keep running' }])
    await f.sessions.deleteBot(f.a.bot.id)
    assert.equal(f.store.getBot(f.a.bot.id), null)
    assert.equal(f.store.getConversation(f.a.conversation.id), null)
    assert.ok(f.store.getBot(f.b.bot.id))
    assert.equal(f.sessions.isBusy(f.b.conversation.id), true)
    assert.deepEqual(f.calls, [f.a.bot.id, f.b.bot.id])
    assert.ok(f.released.includes(`${f.a.conversation.id}:${f.a.bot.id}`))
    assert.ok(f.released.every(key => key.endsWith(':' + f.a.bot.id)))
  } finally {
    await f.sessions.deleteBot(f.b.bot.id).catch(() => {})
    f.db.close()
  }
})

test('failed cleanup retains the bot and can be retried; concurrent deletion runs once', async () => {
  let fail = true
  let calls = 0
  const f = setup(async () => { calls++; if (fail) throw new Error('Docker is unavailable') })
  try {
    await assert.rejects(f.sessions.deleteBot(f.a.bot.id), /Docker is unavailable/)
    assert.ok(f.store.getBot(f.a.bot.id))
    fail = false
    await Promise.all([f.sessions.deleteBot(f.a.bot.id), f.sessions.deleteBot(f.a.bot.id)])
    assert.equal(calls, 2)
    assert.equal(f.store.getBot(f.a.bot.id), null)
  } finally { f.db.close() }
})

test('deleting a channel member preserves the channel, other member and shared notes', async () => {
  const f = setup(async () => {})
  try {
    const channel = f.store.createChannel('Shared room', [f.a.bot.id, f.b.bot.id])
    const own = f.store.addMemory({ botId: f.a.bot.id, scope: 'bot', text: 'private', source: 'user' })
    const routine = f.store.createRoutine({ botId: f.a.bot.id, conversationId: f.a.conversation.id, name: 'Private task', prompt: 'test', schedule: { kind: 'interval', minutes: 60 } })
    const shared = f.store.addMemory({ botId: null, scope: 'user', text: 'shared', source: 'user' })
    await f.sessions.send(channel.id, [{ type: 'text', text: 'hello everyone' }])
    await f.sessions.deleteBot(f.a.bot.id)
    assert.ok(f.store.getConversation(channel.id))
    assert.deepEqual(f.store.channelMembers(channel.id).map(bot => bot.id), [f.b.bot.id])
    assert.equal(f.store.getMemory(own.id), null)
    assert.ok(!f.store.listRoutines().some(item => item.id === routine.id))
    assert.ok(f.store.getMemory(shared.id))
    assert.equal(f.sessions.isBusy(channel.id), true)
  } finally { await f.sessions.deleteBot(f.b.bot.id); f.db.close() }
})

test('the delete RPC reports cleanup failure and blocks new messages while cleanup is pending', async () => {
  let finish!: () => void
  const gate = new Promise<void>(resolve => { finish = resolve })
  const f = setup(async () => { await gate; throw new Error('Could not remove the private profile') })
  try {
    const ctx = { store: f.store, sessions: f.sessions } as RpcContext
    const deletion = dispatch('bots.delete', { id: f.a.bot.id }, ctx)
    const failure = assert.rejects(deletion, { code: 'cleanup_failed', message: 'Could not remove the private profile' })
    await assert.rejects(f.sessions.send(f.a.conversation.id, [{ type: 'text', text: 'new work' }]), /being deleted/)
    assert.ok(f.store.getBot(f.a.bot.id))
    finish()
    await failure
    assert.ok(f.store.getBot(f.a.bot.id))
  } finally { finish(); f.db.close() }
})

test('deleting a bot configured to use This Mac cancels its waiting turn before the AI starts', async () => {
  const f = setup(async () => {})
  let releases = 0
  const bot = f.store.updateBot(f.a.bot.id, { surfaceMode: 'host' })!
  const sessions = new SessionManager(f.store,
    new Map([[providerKey('default', 'fake'), f.adapter]]), () => {}, {
      for: () => ({ claim: () => false, release() { releases++ } }),
      beginDeletion() {}, endDeletion() {}, async destroy() {},
    } as unknown as DesktopPool)
  try {
    await sessions.send(f.a.conversation.id, [{ type: 'text', text: 'waiting' }])
    await sessions.deleteBot(bot.id)
    assert.deepEqual(f.calls, [])
    assert.equal(releases, 1)
    assert.equal(sessions.isBusy(f.a.conversation.id), false)
  } finally { f.db.close() }
})

test('simultaneously finishing channel turns do not leave a stale busy controller', async () => {
  const f = setup(async () => {})
  let finish!: () => void
  const gate = new Promise<void>(resolve => { finish = resolve })
  f.adapter.stream = async function* () { await gate; yield { type: 'done', stopReason: 'end_turn', meta: {} } }
  try {
    const room = f.store.createChannel('Room', [f.a.bot.id, f.b.bot.id])
    await f.sessions.send(room.id, [{ type: 'text', text: 'hello everyone' }])
    finish()
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(f.sessions.isBusy(room.id), false)
  } finally { finish(); f.db.close() }
})
