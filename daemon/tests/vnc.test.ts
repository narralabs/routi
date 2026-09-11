import test from 'node:test'
import { runInNewContext } from 'node:vm'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { setTimeout as sleep } from 'node:timers/promises'
import { VncViewers } from '../src/server/vnc-lifecycle.js'
import { WebSocket } from 'ws'
import { createVncService } from '../src/server/vnc.js'

const bot = '00000000-0000-0000-0000-000000000001'

test('VNC service serves local modules, routes one display, and closes its child on disconnect', async () => {
  const displays: string[] = []
  let child: ReturnType<typeof spawn> | undefined
  const server = createVncService({
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
    assert.equal((await fetch(`${origin}/vnc/test-capability/viewer/${bot}`)).status, 200)
    const module = await fetch(`${origin}/vnc/test-capability/assets/core/rfb.js`)
    assert.equal(module.status, 200)
    assert.match(await module.text(), /class RFB/)
    assert.equal((await fetch(`${origin}/vnc/test-capability/assets/package.json`)).status, 404)
    const denied = new WebSocket(`${origin.replace('http', 'ws')}/vnc/test-capability/connect/${bot}`, { origin: 'https://example.com' })
    const [error] = await once(denied, 'error')
    assert.match(String(error), /403/)
    assert.deepEqual(displays, [])
    const ws = new WebSocket(`${origin.replace('http', 'ws')}/vnc/test-capability/connect/${bot}`, { origin })
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

test('VNC service rejects a missing desktop without starting VNC', async () => {
  const server = createVncService({
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
    const ws = new WebSocket(`${origin.replace('http', 'ws')}/vnc/test-capability/connect/${bot}`, { origin })
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
    const server = createVncService({
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
    const ws = new WebSocket(`${origin.replace('http', 'ws')}/vnc/test-capability/connect/${bot}`, {
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


test('viewer forwards cursor shapes and reconnects without retaining stale connections', async () => {
  const server = createVncService({
    token: 'cursor-test',
    displayFor: async () => { throw new Error('must not access Docker') },
    acquireDisplay: async () => { throw new Error('must not start VNC') },
  })
  server.http.listen(0, '127.0.0.1')
  await once(server.http, 'listening')
  try {
    const address = server.http.address()
    assert.ok(address && typeof address === 'object')
    const html = await (await fetch(`http://127.0.0.1:${address.port}/vnc/cursor-test/viewer/${bot}`)).text()
    const script = html.match(/<script type="module">([\s\S]*?)<\/script>/)?.[1]
    assert.ok(script)
    const messages: unknown[] = []
    let originalUpdates = 0
    const timers: Array<() => void> = []
    const documentEvents = new Map<string, () => void>()
    class RFB {
      constructor() { instance = this }
      _updateCursor(..._args: unknown[]) { originalUpdates++ }
      events = new Map<string, () => void>()
      addEventListener(name: string, callback: () => void) { this.events.set(name, callback) }
      disconnect() { this.events.get('disconnect')?.() }
    }
    let instance!: RFB
    const context = {
      RFB, location: { host: 'localhost', protocol: 'http:', search: '' }, Uint8ClampedArray, URLSearchParams,
      clearTimeout() {}, setTimeout(callback: () => void) { timers.push(callback) },
      ImageData: class { constructor(..._args: unknown[]) {} },
      document: {
        hidden: false,
        addEventListener(name: string, callback: () => void) { documentEvents.set(name, callback) },
        querySelector: () => ({}),
        createElement: () => ({ getContext: () => ({ putImageData() {} }), toDataURL: () => 'data:image/png;base64,cursor' }),
      },
      window: { webkit: { messageHandlers: { cursor: { postMessage: (message: unknown) => messages.push(message) } } }, addEventListener() {} },
    }
    runInNewContext(script.replace(/^import .*;$/m, ''), context)
    instance._updateCursor(new Uint8Array([0, 0, 0, 255, 0, 0, 0, 255]), 1, 0, 2, 1)
    assert.equal(JSON.stringify(messages[0]), JSON.stringify({ png: 'cursor', hotx: 1, hoty: 0 }))
    instance._updateCursor(new Uint8Array(4), 0, 0, 1, 1)
    instance._updateCursor(new Uint8Array(), 0, 0, 0, 0)
    instance._updateCursor(new Uint8Array([0, 0, 0, 255]), 0, 0, 257, 1)
    assert.deepEqual(messages.slice(1), [null, null, null])
    assert.equal(originalUpdates, 4, 'preserve noVNC cursor processing')
    const first = instance
    first.disconnect()
    assert.equal(timers.length, 1)
    timers[0]!()
    assert.notEqual(instance, first)
    first.disconnect()
    assert.equal(timers.length, 1, 'late close from old connection must not start another viewer')
    context.document.hidden = true
    documentEvents.get('visibilitychange')!()
    assert.equal(timers.length, 1, 'hidden viewer must not reconnect')
    context.document.hidden = false
    const second = instance
    documentEvents.get('visibilitychange')!()
    assert.notEqual(instance, second)
    runInNewContext(script.replace(/^import .*;$/m, ''), { ...context, window: { addEventListener() {} } })
    assert.equal(instance._updateCursor, RFB.prototype._updateCursor, 'Mac has no native cursor hook')
  } finally { await server.close() }
})


test('the normal core listener resolves and serves VNC without starting Docker', async () => {
  const { RoutiServer } = await import('../src/server/ws.js')
  const { openDb } = await import('../src/db/schema.js')
  const { Store } = await import('../src/db/store.js')
  const db = openDb(':memory:')
  const store = new Store(db)
  store.ensureDefaultProfile()
  const { bot: desktop } = store.createBot({ name: 'Viewer', surfaceMode: 'container' })
  const server = new RoutiServer({ store, desktops: { for: () => ({}) } } as unknown as import('../src/server/rpc.js').RpcContext)
  await server.listen(0, '127.0.0.1')
  const address = server['http'].address()
  assert.ok(address && typeof address === 'object')
  const origin = `http://127.0.0.1:${address.port}`
  const ws = new WebSocket(origin.replace('http:', 'ws:'))
  try {
    await once(ws, 'open')
    const reply = once(ws, 'message')
    ws.send(JSON.stringify({ t: 'rpc', id: 'viewer', method: 'surface.viewer', params: { botId: desktop.id } }))
    const result = JSON.parse(String((await reply)[0]))
    assert.equal(result.t, 'rpc_ok')
    assert.match(result.result.path, /^\/vnc\/[a-f0-9]+\/viewer\//)
    const page = await fetch(origin + result.result.path + '?viewOnly=1')
    assert.equal(page.status, 200)
    assert.match(await page.text(), /Reconnecting/)
    assert.equal((await fetch(origin + '/vnc/invalid/viewer/' + desktop.id)).status, 404)
  } finally { ws.terminate(); await server.close(); db.close() }
})


test('a stopped VNC server is invalidated before a viewer reconnects', async () => {
  let starts = 0
  let stops = 0
  const viewers = new VncViewers({ start: async () => ++starts, stop: async () => { stops++ } })
  try {
    const stale = await viewers.acquire(':101')
    await viewers.invalidate(':101')
    const fresh = await viewers.acquire(':101')
    assert.equal(fresh.server, 2)
    stale.release()
    assert.equal(stops, 1, 'late disconnect from old server cannot stop its replacement')
    fresh.release()
  } finally { await viewers.close() }
  assert.equal(stops, 2)
})
