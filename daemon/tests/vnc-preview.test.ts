import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { setTimeout as sleep } from 'node:timers/promises'
import { VncViewers } from '../scripts/experiments/vnc-lifecycle.js'
import { WebSocket } from 'ws'
import { createVncPreview } from '../scripts/experiments/vnc-preview.js'

const bot = '00000000-0000-0000-0000-000000000001'

test('VNC experiment serves local modules, routes one display, and closes its child on disconnect', async () => {
  const displays: string[] = []
  let child: ReturnType<typeof spawn> | undefined
  const server = createVncPreview({
    token: 'test-capability',
    displayFor: async (id) => { assert.equal(id, bot); return ':104' },
    acquireDisplay: async (display) => ({
      release() {},
      open() {
        displays.push(display)
        const process = spawn(globalThis.process.execPath, ['-e', 'process.stdin.pipe(process.stdout)'])
        child = process
        return process
      },
    }),
  })
  server.http.listen(0, '127.0.0.1')
  await once(server.http, 'listening')
  const address = server.http.address()
  assert.ok(address && typeof address === 'object')
  const origin = `http://127.0.0.1:${address.port}`
  try {
    assert.equal((await fetch(`${origin}/wrong/viewer/${bot}`)).status, 404)
    assert.equal((await fetch(`${origin}/test-capability/viewer/${bot}`)).status, 200)
    const module = await fetch(`${origin}/test-capability/assets/core/rfb.js`)
    assert.equal(module.status, 200)
    assert.match(await module.text(), /class RFB/)
    assert.equal((await fetch(`${origin}/test-capability/assets/package.json`)).status, 404)
    const denied = new WebSocket(`${origin.replace('http', 'ws')}/test-capability/connect/${bot}`, { origin: 'https://example.com' })
    const [error] = await once(denied, 'error')
    assert.match(String(error), /403/)
    assert.deepEqual(displays, [])
    const ws = new WebSocket(`${origin.replace('http', 'ws')}/test-capability/connect/${bot}`, { origin })
    await once(ws, 'open')
    const received = once(ws, 'message')
    const bytes = Buffer.from([0, 255, 3, 128, 13, 10])
    ws.send(bytes)
    assert.deepEqual((await received)[0], bytes)
    assert.deepEqual(displays, [':104'])
    assert.ok(child)
    const closed = once(child, 'close')
    ws.close()
    await closed
  } finally { await server.close() }
})

test('VNC experiment rejects a missing desktop without starting VNC', async () => {
  const server = createVncPreview({
    token: 'test-capability',
    displayFor: async () => { throw new Error('not running') },
    acquireDisplay: async () => { throw new Error('must not start') },
  })
  server.http.listen(0, '127.0.0.1')
  await once(server.http, 'listening')
  const address = server.http.address()
  assert.ok(address && typeof address === 'object')
  const origin = `http://127.0.0.1:${address.port}`
  try {
    const ws = new WebSocket(`${origin.replace('http', 'ws')}/test-capability/connect/${bot}`, { origin })
    ws.on('error', () => {})
    await once(ws, 'close')
  } finally { await server.close() }
})


async function until(predicate: () => boolean) {
  const deadline = Date.now() + 2000
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('Timed out waiting for VNC cleanup')
    await sleep(5)
  }
}

test('two devices share a server; only the last disconnect starts the grace period', async () => {
  let starts = 0
  let stops = 0
  const viewers = new VncViewers({
    start: async () => ++starts,
    stop: async () => { stops++ },
  }, 30)
  try {
    const [mac, phone] = await Promise.all([viewers.acquire(':101'), viewers.acquire(':101')])
    assert.equal(starts, 1)
    mac.release()
    mac.release() // error + close events must not count twice
    await sleep(60)
    assert.equal(stops, 0)
    phone.release()
    const reconnect = await viewers.acquire(':101')
    await sleep(60)
    assert.equal(stops, 0)
    assert.equal(starts, 1)
    reconnect.release()
    await until(() => stops === 1)
    const next = await viewers.acquire(':101')
    assert.equal(starts, 2)
    next.release()
  } finally { await viewers.close() }
  assert.equal(stops, 2)
})

test('different displays stop independently, and startup failure can be retried', async () => {
  const stopped: string[] = []
  let fail = true
  const viewers = new VncViewers({
    start: async (display) => {
      if (display === ':103' && fail) { fail = false; throw new Error('startup failed') }
      return display
    },
    stop: async (display) => { stopped.push(display) },
  }, 20)
  try {
    const mac = await viewers.acquire(':101')
    const phone = await viewers.acquire(':102')
    await assert.rejects(viewers.acquire(':103'), /startup failed/)
    const retried = await viewers.acquire(':103')
    mac.release()
    await until(() => stopped.length === 1)
    assert.deepEqual(stopped, [':101'])
    phone.release()
    retried.release()
  } finally { await viewers.close() }
  assert.deepEqual(new Set(stopped), new Set([':101', ':102', ':103']))
})

test('reconnect waits for an in-flight stop before starting another server', async () => {
  let starts = 0
  let finishStop!: () => void
  const viewers = new VncViewers({
    start: async () => ++starts,
    stop: () => new Promise<void>((resolve) => { finishStop = resolve }),
  }, 5)
  const first = await viewers.acquire(':101')
  first.release()
  await until(() => Boolean(finishStop))
  const next = viewers.acquire(':101')
  await sleep(10)
  assert.equal(starts, 1)
  finishStop()
  const second = await next
  assert.equal(starts, 2)
  second.release()
  const close = viewers.close()
  await sleep(0)
  finishStop()
  await close
})

for (const mode of ['force-quit', 'unresponsive', 'disconnect-during-startup'] as const) {
  test(`VNC ${mode} releases its display even without a page unload`, async () => {
    let released = 0
    let acquired = 0
    let finishStart: (() => void) | undefined
    const server = createVncPreview({
      token: 'test-capability', heartbeatMs: 25,
      displayFor: async () => ':101',
      acquireDisplay: async () => {
        acquired++
        if (mode === 'disconnect-during-startup') await new Promise<void>((resolve) => { finishStart = resolve })
        return {
          release() { released++ },
          open: () => spawn(process.execPath, ['-e', 'process.stdin.pipe(process.stdout)']),
        }
      },
    })
    server.http.listen(0, '127.0.0.1')
    await once(server.http, 'listening')
    const address = server.http.address()
    assert.ok(address && typeof address === 'object')
    const origin = `http://127.0.0.1:${address.port}`
    const ws = new WebSocket(`${origin.replace('http', 'ws')}/test-capability/connect/${bot}`, {
      origin, autoPong: mode !== 'unresponsive',
    })
    ws.on('error', () => {})
    try {
      await once(ws, 'open')
      await until(() => acquired === 1)
      if (mode !== 'unresponsive') ws.terminate()
      if (mode === 'disconnect-during-startup') {
        await until(() => Boolean(finishStart))
        await sleep(10)
        finishStart!()
      }
      await until(() => released === 1)
      assert.equal(released, 1)
    } finally { ws.terminate(); finishStart?.(); await server.close() }
  })
}
