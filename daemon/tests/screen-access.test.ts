import assert from 'node:assert/strict'
import { test } from 'node:test'
import { openDb } from '../src/db/schema.js'
import { Store } from '../src/db/store.js'
import { dispatch, type RpcContext } from '../src/server/rpc.js'
import { providerKey } from '../src/providers/types.js'

test('a viewer cannot allocate or drive a desktop for a bot with no screen access', async (t) => {
  const db = openDb(':memory:')
  t.after(() => db.close())
  const store = new Store(db)
  store.ensureDefaultProfile()
  const { bot } = store.createBot({ name: 'Chat only', surfaceMode: 'none' })
  let allocations = 0
  const ctx = { store, desktops: { for() { allocations++; throw new Error('Should not allocate') } } } as unknown as RpcContext
  for (const method of ['surface.status', 'surface.start', 'surface.stop', 'surface.frame', 'surface.clipboard', 'surface.input']) {
    await assert.rejects(dispatch(method, { botId: bot.id, input: { kind: 'key', keys: ['a'] } }, ctx), /no screen access/)
  }
  assert.equal(allocations, 0)
})

test('enabling screen access persists the setting, warms the desktop, and drops stale direct and channel sessions', async (t) => {
  const db = openDb(':memory:')
  t.after(() => db.close())
  const store = new Store(db)
  store.ensureDefaultProfile()
  const { bot, conversation } = store.createBot({ name: 'Probe', surfaceMode: 'none' })
  const channel = store.createChannel('Room', [bot.id])
  const released: string[] = []
  const warmed: string[] = []
  for (const c of [conversation, channel]) store.setProviderSession(c.id, bot.id, bot.provider, 'old-session')
  let busy = true
  const ctx = {
    store, sessions: { isBusy: () => busy },
    providers: new Map([[providerKey(bot.profileId, bot.provider), { release(key: string) { released.push(key) } }]]),
    desktops: { warm(id: string) { warmed.push(id) }, for() { return { async status() { return { state: 'running' } } } } },
  } as unknown as RpcContext
  const params = { id: bot.id, patch: { surfaceMode: 'container' } }
  await assert.rejects(dispatch('bots.update', params, ctx), /Wait for the bot/)
  assert.equal(store.getBot(bot.id)?.surfaceMode, 'none')
  busy = false
  await dispatch('bots.update', params, ctx)
  assert.equal(store.getBot(bot.id)?.surfaceMode, 'container')
  assert.deepEqual(new Set(released), new Set([`${conversation.id}:${bot.id}`, `${channel.id}:${bot.id}`]))
  assert.deepEqual(warmed, [bot.id])
  for (const c of [conversation, channel]) assert.equal(store.getProviderSession(c.id, bot.id), null)
  await assert.doesNotReject(dispatch('surface.status', { botId: bot.id }, ctx))
})
