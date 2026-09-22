import assert from 'node:assert/strict'
import { WebSocket, WebSocketServer } from 'ws'
import { execFileSync, spawn } from 'node:child_process'
import { createVncBridge } from '../src/server/vnc-bridge.js'
import { dispatch } from '../src/server/rpc.js'
import { once } from 'node:events'
import { mkdtempSync, readFileSync, statSync, writeFileSync, rmSync } from 'node:fs'
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

async function setup(t: TestContext, maxDevices = 5) {
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
  const relay = createRelay([{ ...pair.relay, maxDevices }])
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

async function request(url: string, device: Awaited<ReturnType<typeof createPairing>>['viewer'], path = '/health', method = 'GET', authorization = '') {
  const stream = await connectViewer(url, device)
  const chunks: Buffer[] = []
  stream.on('data', chunk => chunks.push(Buffer.from(chunk)))
  const ended = once(stream, 'end')
  stream.write(`${method} ${path} HTTP/1.1\r\nHost: routi-host\r\nConnection: close\r\nAuthorization: Bearer ${authorization}\r\n\r\n`)
  try { await ended; return Buffer.concat(chunks).toString() } finally { stream.destroy() }
}

test('paired relay client reads core health; other routes and methods are unavailable', { timeout: 10_000 }, async t => {
  const { core, pair, url } = await setup(t)
  assert.equal(core.status().enabled, false)
  await core.configure({ url, enabled: true })
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
  await core.configure({ url, enabled: true })
  await waitFor(core, 'connected')
  const stream = await connectViewer(url, pair.viewer)
  const closed = once(stream, 'close')
  core.stop()
  await closed
  const restarted = new RelayConnection(store, hostFile)
  t.after(() => restarted.stop())
  await waitFor(restarted, 'connected')
  await restarted.configure({ url, enabled: false })
  assert.equal(restarted.status().state, 'disconnected')
  const disabled = new RelayConnection(store, hostFile)
  t.after(() => disabled.stop())
  assert.equal(disabled.status().enabled, false)
  assert.equal(disabled.status().state, 'disconnected')
})

test('invalid addresses and missing credentials do not save an enabled connection', async t => {
  const { core, store, hostFile, url } = await setup(t)
  for (const invalid of ['', 'not a URL', 'http://example.com', 'ws://example.com', 'wss://user:secret@example.com', 'wss://example.com/path', 'wss://example.com?token=x']) {
    await assert.rejects(() => core.configure({ url: invalid, enabled: true }), /wss/)
  }
  rmSync(hostFile)
  assert.equal(core.status().configured, false)
  await assert.rejects(() => core.configure({ url, enabled: true }), /set up Routi Connect/)
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
  await core.configure({ url, enabled: false })
  assert.equal(core.status().state, 'disconnected')
})

test('relay rejects invalid credentials and reports failure instead of Connected', { timeout: 5000 }, async t => {
  const { core, hostFile, pair, url } = await setup(t)
  writeFileSync(hostFile, JSON.stringify({ ...pair.host, token: 'x'.repeat(43) }))
  await core.configure({ url, enabled: true })
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

test('devices pair independently, survive restart, and revoke without disconnecting each other', { timeout: 15_000 }, async t => {
  const { core, store, hostFile, pair, url } = await setup(t, 3)
  writeFileSync(hostFile, JSON.stringify({ ...pair.host, viewerToken: pair.viewer.token }))
  store.setSettings({ connectPhonePaired: true })
  const wss = new WebSocketServer({ noServer: true })
  core.setChatHandler((req, socket, head) => wss.handleUpgrade(req, socket, head, () => {}))
  t.after(() => new Promise<void>(resolve => wss.close(() => resolve())))
  async function openChat(device: typeof pair.viewer) {
    const stream = await connectViewer(url, device)
    const ready = once(stream, 'data')
    stream.write('GET /chat HTTP/1.1\r\nHost: routi-host\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n')
    assert.match((await ready)[0].toString(), /HTTP\/1.1 101/)
    return stream
  }
  const unpaired = { ...pair.viewer, key: '', cert: '' }
  const decode = (value: string) => JSON.parse(Buffer.from(new URL(value).searchParams.get('data')!, 'base64url').toString())
  async function pairDevice() {
    const payload = decode((await core.pairPhone()).url)
    assert.equal(payload.pkcs12, undefined)
    assert.equal(payload.key, undefined)
    assert.match(await request(url, unpaired, '/health'), /HTTP\/1.1 403/)
    assert.match(await request(url, unpaired, '/pair', 'POST', 'wrong'), /HTTP\/1.1 403/)
    const response = await request(url, unpaired, '/pair', 'POST', payload.secret)
    assert.match(response.slice(0, 32), /HTTP\/1.1 200/)
    assert.match(await request(url, unpaired, '/pair', 'POST', payload.secret), /HTTP\/1.1 403/)
    const body = JSON.parse(response.slice(response.indexOf('\r\n\r\n') + 4).replace(/^[a-f0-9]+\r\n/, '').replace(/\r\n0\r\n\r\n$/, ''))
    const p12File = join(hostFile, '..', 'phone.p12')
    writeFileSync(p12File, Buffer.from(body.pkcs12, 'base64'), { mode: 0o600 })
    const pem = execFileSync('openssl', ['pkcs12', '-in', p12File, '-passin', 'pass:routi', '-nodes'], { encoding: 'utf8' })
    return { ...pair.viewer, key: pem, cert: pem, token: body.token }
  }
  await core.configure({ url, enabled: true })
  await waitFor(core, 'connected')
  const original = await openChat(pair.viewer)
  const phone = await pairDevice(), phoneStream = await openChat(phone)
  const tablet = await pairDevice(), tabletStream = await openChat(tablet)
  assert.notEqual(phone.token, tablet.token)
  assert.notEqual(phone.cert, tablet.cert)
  assert.equal(core.status().devices.length, 3)
  const alive = [original, phoneStream, tabletStream].map(stream => once(stream, 'data'))
  for (const ws of wss.clients) ws.send('all devices connected')
  for (const [data] of await Promise.all(alive)) assert.ok(data.toString().includes('all devices connected'))
  const overflow = decode((await core.pairPhone()).url)
  assert.match(await request(url, unpaired, '/pair', 'POST', overflow.secret), /Device allowance reached/)
  const closed = once(phoneStream, 'close')
  const phoneId = core.status().devices[1]!.id
  const fetch = globalThis.fetch
  t.mock.method(globalThis, 'fetch', (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) =>
    init?.method === 'DELETE' ? Promise.resolve(new Response('{}', { status: 503 })) : fetch(input, init))
  await assert.rejects(core.revokeDevice(phoneId), /Could not update devices/)
  t.mock.restoreAll()
  await closed
  assert.equal(core.status().devices.length, 2)
  assert.match(await request(url, phone), /HTTP\/1.1 403/)
  // Pairing cleans up the offline revocation's registry entry before adding a device.
  await pairDevice()
  await assert.rejects(connectViewer(url, phone))
  await core.revokeDevice(core.status().devices.at(-1)!.id)
  const remaining = once(tabletStream, 'data')
  for (const ws of wss.clients) ws.send('tablet still connected')
  assert.ok((await remaining)[0].toString().includes('tablet still connected'))
  for (const method of ['connect.pair', 'connect.cancelPairing', 'connect.revokeDevice', 'connect.configure']) {
    const params = method === 'connect.configure' ? { url, enabled: false } : method === 'connect.revokeDevice' ? { id: phoneId } : {}
    await assert.rejects(dispatch(method, params, { relay: core, viaRelay: true } as never), /from your Mac/)
  }
  core.stop()
  const restarted = new RelayConnection(store, hostFile)
  t.after(() => restarted.stop())
  await waitFor(restarted, 'connected')
  assert.equal(restarted.status().devices.length, 2)
  assert.match(await request(url, tablet), /HTTP\/1.1 200/)
})

test('cancelled and expired pairing codes cannot be redeemed', { timeout: 15_000 }, async t => {
  const { core, hostFile, pair, url } = await setup(t)
  writeFileSync(hostFile, JSON.stringify({ ...pair.host, viewerToken: pair.viewer.token }))
  await core.configure({ url, enabled: true })
  await waitFor(core, 'connected')
  const unpaired = { ...pair.viewer, key: '', cert: '' }
  const decode = (value: string) => JSON.parse(Buffer.from(new URL(value).searchParams.get('data')!, 'base64url').toString())
  const cancelled = decode((await core.pairPhone()).url)
  core.cancelPairing()
  assert.match(await request(url, unpaired, '/pair', 'POST', cancelled.secret), /HTTP\/1.1 403/)
  const expired = decode((await core.pairPhone()).url)
  t.mock.method(Date, 'now', () => expired.expiresAt + 1)
  assert.match(await request(url, unpaired, '/pair', 'POST', expired.secret), /HTTP\/1.1 403/)
})


test('paired VNC uses encrypted relay transport; revocation closes the viewer and releases its desktop', { timeout: 15_000 }, async t => {
  const { core, store, pair, url } = await setup(t)
  store.setSettings({ connectPhonePaired: true })
  const bot = '00000000-0000-0000-0000-000000000001'
  let released = 0
  const bridge = createVncBridge({
    token: 'test-capability',
    displayFor: async id => { assert.equal(id, bot); return ':104' },
    acquireDisplay: async () => ({
      open: () => spawn(process.execPath, ['-e', 'process.stdin.pipe(process.stdout)']),
      release: () => { released++ },
    }),
  })
  core.setDesktopHandler(bridge)
  t.after(() => bridge.close())
  await core.configure({ url, enabled: true })
  await waitFor(core, 'connected')
  const prefix = bridge.prefix
  assert.match(await request(url, pair.viewer, `${prefix}/viewer/${bot}`), /HTTP\/1.1 200/)
  assert.match(await request(url, pair.viewer, `${prefix}/assets/core/rfb.js`), /class RFB/)
  for (const path of ['/mcp/bot/conversation', '/vnc/wrong/viewer/' + bot, `${prefix}/assets/../../package.json`]) {
    assert.match(await request(url, pair.viewer, path), /HTTP\/1.1 404/)
  }
  const unpaired = { ...pair.viewer, key: '', cert: '' }
  assert.match(await request(url, unpaired, `${prefix}/viewer/${bot}`), /HTTP\/1.1 403/)
  const connect = async (origin: string) => {
    const stream = await connectViewer(url, pair.viewer)
    return new WebSocket(`wss://routi-host${prefix}/connect/${bot}`, { createConnection: () => stream, origin })
  }
  const denied = await connect('https://untrusted.example')
  assert.match(String((await once(denied, 'error'))[0]), /403/)
  const ws = await connect('https://routi-host')
  t.after(() => ws.terminate())
  await once(ws, 'open')
  // Frame-sized binary traffic crosses multiple TLS/relay chunks without corruption.
  const payload = Buffer.alloc(512 * 1024, 0xa5)
  let received = Buffer.alloc(0)
  const complete = new Promise<void>(resolve => ws.on('message', chunk => {
    received = Buffer.concat([received, chunk as Buffer])
    if (received.length >= payload.length) resolve()
  }))
  ws.send(payload)
  await complete
  assert.deepEqual(received, payload)
  const closed = once(ws, 'close')
  await core.revokeDevice('legacy')
  await closed
  for (let i = 0; i < 100 && !released; i++) await sleep(10)
  assert.equal(released, 1)
  assert.match(await request(url, pair.viewer, `${prefix}/viewer/${bot}`), /HTTP\/1.1 403/)
})

test('a fresh Mac enrolls without CLI setup and pairs a phone for a persistent three-day trial', { timeout: 15_000 }, async t => {
  const directory = mkdtempSync(join(tmpdir(), 'routi-trial-test-'))
  const hostFile = join(directory, 'host.json')
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  let settings: Record<string, unknown> = { connectPhonePaired: true }
  const store = { getSettings: () => settings, setSettings: (patch: Record<string, unknown>) => (settings = { ...settings, ...patch }) }
  let storageAvailable = false
  const relay = createRelay([], { saveTrials: () => { if (!storageAvailable) throw Error('Storage unavailable') }, heartbeatMs: 20 })
  relay.server.listen(0, '127.0.0.1')
  await once(relay.server, 'listening')
  const url = `ws://127.0.0.1:${(relay.server.address() as AddressInfo).port}`
  const core = new RelayConnection(store, hostFile)
  t.after(async () => { core.stop(); await relay.close() })
  await assert.rejects(core.configure({ url, enabled: true }), /set up Routi Connect/)
  const originalToken = JSON.parse(readFileSync(hostFile, 'utf8')).token
  storageAvailable = true
  await core.configure({ url, enabled: true })
  await waitFor(core, 'connected')
  assert.equal(core.status().configured, true)
  assert.equal(core.status().canPair, true)
  assert.deepEqual(core.status().devices, [])
  assert.deepEqual((await core.refreshStatus()).access, { trial: true, expiresAt: null, expired: false })
  const payload = JSON.parse(Buffer.from(new URL((await core.pairPhone()).url).searchParams.get('data')!, 'base64url').toString())
  const host = JSON.parse(readFileSync(hostFile, 'utf8'))
  assert.equal(host.token, originalToken)
  assert.equal(statSync(hostFile).mode & 0o777, 0o600)
  const bootstrap = { token: payload.token, peerCert: host.cert, key: '', cert: '' }
  const response = await request(url, bootstrap, '/pair', 'POST', payload.secret)
  assert.match(response.slice(0, 32), /HTTP\/1.1 200/)
  const body = JSON.parse(response.slice(response.indexOf('\r\n\r\n') + 4).replace(/^[a-f0-9]+\r\n/, '').replace(/\r\n0\r\n\r\n$/, ''))
  const p12 = join(directory, 'phone.p12')
  writeFileSync(p12, Buffer.from(body.pkcs12, 'base64'), { mode: 0o600 })
  const pem = execFileSync('openssl', ['pkcs12', '-in', p12, '-passin', 'pass:routi', '-nodes'], { encoding: 'utf8' })
  const phone = { token: body.token, peerCert: host.cert, key: pem, cert: pem }
  assert.match(await request(url, phone), /HTTP\/1.1 200/)
  const accessURL = url.replace('ws:', 'http:') + '/v1/access'
  const access = await (await fetch(accessURL, { headers: { Authorization: `Bearer ${phone.token}` } })).json() as { expiresAt: number }
  assert.ok(Math.abs(access.expiresAt - Date.now() - 3 * 86400_000) < 2000)
  await core.configure({ url, enabled: false })
  await core.configure({ url, enabled: true })
  await waitFor(core, 'connected')
  assert.equal(JSON.parse(readFileSync(hostFile, 'utf8')).token, host.token)
  const stream = await connectViewer(url, phone)
  const closed = once(stream, 'close')
  t.mock.method(Date, 'now', () => access.expiresAt + 1)
  await closed
  assert.equal((await core.refreshStatus()).access?.expired, true)
  await assert.rejects(connectViewer(url, phone), /402/)
  assert.equal(core.status().devices.length, 1)
})
