import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo } from 'node:net'
import { test, type TestContext } from 'node:test'
import { setTimeout as sleep } from 'node:timers/promises'
import { createPairing } from 'routi-relay/pairing'
import { createRelay } from 'routi-relay/relay'
import { connectViewer } from 'routi-relay/connection'
import { PROTOCOL_VERSION } from '@routi/protocol'
import { VERSION } from '../src/version.js'
import { RelayConnection } from '../src/server/relay.js'

async function setup(t: TestContext) {
  const pair = await createPairing()
  const directory = mkdtempSync(join(tmpdir(), 'routi-connect-test-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const hostFile = join(directory, 'host.json')
  writeFileSync(hostFile, JSON.stringify(pair.host), { mode: 0o600 })
  let settings: Record<string, unknown> = {}
  const store = {
    getSettings: () => settings,
    setSettings: (patch: Record<string, unknown>) => (settings = { ...settings, ...patch }),
  }
  const relay = createRelay([pair.relay])
  relay.server.listen(0, '127.0.0.1')
  await once(relay.server, 'listening')
  const url = `ws://127.0.0.1:${(relay.server.address() as AddressInfo).port}`
  const core = new RelayConnection(store, hostFile)
  t.after(async () => { core.stop(); await relay.close() })
  return { core, store, hostFile, pair, relay, url }
}

async function waitFor(core: RelayConnection, state: string) {
  for (let i = 0; i < 100; i++) {
    if (core.status().state === state) return
    await sleep(20)
  }
  assert.fail(`Expected ${state}, got ${core.status().state}`)
}

async function request(url: string, device: Awaited<ReturnType<typeof createPairing>>['viewer'], path = '/health', method = 'GET') {
  const stream = await connectViewer(url, device)
  const chunks: Buffer[] = []
  stream.on('data', chunk => chunks.push(Buffer.from(chunk)))
  const ended = once(stream, 'end')
  stream.write(`${method} ${path} HTTP/1.1\r\nHost: routi-host\r\nConnection: close\r\n\r\n`)
  try { await ended; return Buffer.concat(chunks).toString() } finally { stream.destroy() }
}

test('paired relay client reads core health; other routes and methods are unavailable', { timeout: 10_000 }, async t => {
  const { core, pair, url } = await setup(t)
  assert.equal(core.status().enabled, false)
  core.configure({ url, enabled: true })
  await waitFor(core, 'connected')
  const result = await request(url, pair.viewer)
  assert.match(result, /HTTP\/1.1 200/)
  assert.ok(result.includes(JSON.stringify({ ok: true, version: VERSION, protocolVersion: PROTOCOL_VERSION })))
  for (const path of ['/mcp/bot/conversation', '/vnc/viewer/bot', '/']) {
    assert.match(await request(url, pair.viewer, path), /HTTP\/1.1 404/)
  }
  assert.match(await request(url, pair.viewer, '/health', 'POST'), /HTTP\/1.1 404/)
})

test('disconnect closes active sessions; preference survives core restart', { timeout: 10_000 }, async t => {
  const { core, store, hostFile, pair, url } = await setup(t)
  core.configure({ url, enabled: true })
  await waitFor(core, 'connected')
  const stream = await connectViewer(url, pair.viewer)
  const closed = once(stream, 'close')
  core.stop()
  await closed
  const restarted = new RelayConnection(store, hostFile)
  t.after(() => restarted.stop())
  await waitFor(restarted, 'connected')
  restarted.configure({ url, enabled: false })
  assert.equal(restarted.status().state, 'disconnected')
  const disabled = new RelayConnection(store, hostFile)
  t.after(() => disabled.stop())
  assert.equal(disabled.status().enabled, false)
  assert.equal(disabled.status().state, 'disconnected')
})

test('invalid addresses and missing credentials do not save an enabled connection', async t => {
  const { core, store, hostFile, url } = await setup(t)
  for (const invalid of ['', 'not a URL', 'http://example.com', 'ws://example.com', 'wss://user:secret@example.com', 'wss://example.com/path', 'wss://example.com?token=x']) {
    assert.throws(() => core.configure({ url: invalid, enabled: true }), /wss/)
  }
  rmSync(hostFile)
  assert.equal(core.status().configured, false)
  assert.throws(() => core.configure({ url, enabled: true }), /credentials/)
  assert.deepEqual(store.getSettings(), {})
})

test('bad persisted credentials do not prevent core startup or leak secrets in status', async t => {
  const { store, hostFile, url } = await setup(t)
  store.setSettings({ connect: { url, enabled: true } })
  writeFileSync(hostFile, '{"token":"private-sentinel"}')
  const core = new RelayConnection(store, hostFile)
  t.after(() => core.stop())
  assert.equal(core.status().state, 'error')
  assert.ok(!JSON.stringify(core.status()).includes('private-sentinel'))
  core.configure({ url, enabled: false })
  assert.equal(core.status().state, 'disconnected')
})

test('relay rejects invalid credentials and reports failure instead of Connected', { timeout: 5000 }, async t => {
  const { core, hostFile, pair, url } = await setup(t)
  writeFileSync(hostFile, JSON.stringify({ ...pair.host, token: 'x'.repeat(43) }))
  core.configure({ url, enabled: true })
  await waitFor(core, 'rejected')
  assert.match(core.status().error!, /rejected/)
})

test('malformed saved relay address falls back to disabled without crashing startup', async t => {
  const { store, hostFile } = await setup(t)
  store.setSettings({ connect: { url: 'not a URL', enabled: true } })
  const core = new RelayConnection(store, hostFile)
  t.after(() => core.stop())
  assert.equal(core.status().enabled, false)
  assert.equal(core.status().state, 'disconnected')
})
