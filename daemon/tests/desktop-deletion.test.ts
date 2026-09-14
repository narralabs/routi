import assert from 'node:assert/strict'
import test from 'node:test'
import { Desktop, Host } from '../src/surfaces/desktop.js'
import { DesktopPool } from '../src/surfaces/pool.js'
import { openDb } from '../src/db/schema.js'
import { Store } from '../src/db/store.js'

test('deletion waits for an already-started allocation and prevents stale references restarting it', async t => {
  let ready!: () => void
  const gate = new Promise<null>(resolve => { ready = () => resolve(null) })
  const operations: string[] = []
  t.mock.method(Host.prototype, 'ensure', () => gate)
  t.mock.method(Host.prototype, 'exec', async () => { operations.push('start'); return '99' })
  t.mock.method(Host.prototype, 'execOn', async () => 'dimensions: 1280x800')
  t.mock.method(Host.prototype, 'destroyScreen', async () => { operations.push('delete') })
  const desktop = new Desktop('test')
  const start = desktop.start()
  const deletion = desktop.destroy()
  assert.deepEqual(operations, [])
  await assert.rejects(desktop.start(), /being deleted/)
  ready()
  await Promise.all([start, deletion])
  assert.deepEqual(operations, ['start', 'delete'])
  await assert.rejects(desktop.start(), /being deleted/)
})

test('deleting a This Mac bot only removes any old container resources and evicts its entry', async t => {
  const db = openDb(':memory:')
  t.after(() => db.close())
  const store = new Store(db)
  store.ensureDefaultProfile()
  const { bot } = store.createBot({ name: 'Mac bot', surfaceMode: 'host' })
  const pool = new DesktopPool('/tmp/routi-deletion-test', store)
  const host = pool.for(bot.id)
  t.mock.method(host, 'stop', async () => { throw new Error('Do not stop the shared Mac') })
  const deleted: string[] = []
  t.mock.method(Host.prototype, 'destroyScreen', async (id: string) => { deleted.push(id) })
  pool.beginDeletion(bot.id)
  assert.throws(() => pool.for(bot.id), /being deleted/)
  await pool.destroy(bot.id)
  pool.endDeletion(bot.id)
  assert.deepEqual(deleted, [bot.id])
  assert.deepEqual(pool.all(), [host])
})
