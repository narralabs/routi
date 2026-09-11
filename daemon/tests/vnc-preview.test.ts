import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { WebSocket } from 'ws'
import { createVncPreview } from '../scripts/experiments/vnc-preview.js'

const bot = '00000000-0000-0000-0000-000000000001'

test('VNC experiment serves local modules, routes one display, and closes its child on disconnect', async () => {
  const displays: string[] = []
  let child: ReturnType<typeof spawn> | undefined
  const server = createVncPreview({
    token: 'test-capability',
    displayFor: async (id) => { assert.equal(id, bot); return ':104' },
    openDisplay: (display) => {
      displays.push(display)
      const process = spawn(globalThis.process.execPath, ['-e', 'process.stdin.pipe(process.stdout)'])
      child = process
      return process
    },
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
    openDisplay: () => { throw new Error('must not start') },
  })
  server.http.listen(0, '127.0.0.1')
  await once(server.http, 'listening')
  const address = server.http.address()
  assert.ok(address && typeof address === 'object')
  const origin = `http://127.0.0.1:${address.port}`
  try {
    const ws = new WebSocket(`${origin.replace('http', 'ws')}/test-capability/connect/${bot}`, { origin })
    const [error] = await once(ws, 'error')
    assert.match(String(error), /404/)
  } finally { await server.close() }
})
