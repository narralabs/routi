import assert from 'node:assert/strict'
import { test, type TestContext } from 'node:test'
import { createServer } from 'node:http'
import { createHash } from 'node:crypto'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { openDb } from '../src/db/schema.js'
import { Store } from '../src/db/store.js'
import { Robinhood } from '../src/plugins/robinhood.js'
import { desktopToolSpecs, runDesktopTool } from '../src/surfaces/tools.js'

async function fixture(t: TestContext) {
  const dir = mkdtempSync(join(tmpdir(), 'routi-robinhood-test-'))
  const db = openDb(join(dir, 'test.db'))
  const store = new Store(db)
  store.ensureDefaultProfile()
  const { bot } = store.createBot({ name: 'Trading bot', surfaceMode: 'none' })
  const saved = new Map<string, string>()
  const clients: Record<string, unknown>[] = []
  const calls: string[] = []
  let tokenCalls = 0
  let fail = false
  let challenge = ''
  let accessToken = 'test-access'
  let url = ''
  const server = createServer(async (req, res) => {
    const path = new URL(req.url!, url).pathname
    const json = (value: unknown, status = 200) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(value)) }
    let body = ''
    for await (const chunk of req) body += chunk
    if (path.includes('oauth-protected-resource')) return json({ resource: `${url}/mcp`, authorization_servers: [url] })
    if (path.includes('oauth-authorization-server') || path.includes('openid-configuration')) return json({
      issuer: url, authorization_endpoint: `${url}/authorize`, token_endpoint: `${url}/token`, registration_endpoint: `${url}/register`,
      response_types_supported: ['code'], grant_types_supported: ['authorization_code', 'refresh_token'], code_challenge_methods_supported: ['S256'], token_endpoint_auth_methods_supported: ['none'],
    })
    if (path === '/register') {
      const registration = JSON.parse(body)
      clients.push(registration)
      return json({ ...registration, client_id: 'routi-test' }, 201)
    }
    if (path === '/token') {
      tokenCalls++
      const params = new URLSearchParams(body)
      if (params.get('grant_type') === 'authorization_code') {
        assert.equal(params.get('code'), 'test-code')
        assert.equal(createHash('sha256').update(params.get('code_verifier')!).digest('base64url'), challenge)
      }
      if (params.get('grant_type') === 'refresh_token') accessToken = 'refreshed-access'
      return json({ access_token: accessToken, refresh_token: 'test-refresh', token_type: 'Bearer', expires_in: 3600 })
    }
    if (path === '/mcp') {
      if (req.headers.authorization !== `Bearer ${accessToken}`) {
        res.setHeader('www-authenticate', `Bearer resource_metadata="${url}/.well-known/oauth-protected-resource"`)
        return json({ error: 'unauthorized' }, 401)
      }
      if (req.method !== 'POST') { res.writeHead(405).end(); return }
      const message = JSON.parse(body)
      if (message.id === undefined) { res.writeHead(202).end(); return }
      let result: unknown
      if (message.method === 'initialize') result = { protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'fake-robinhood', version: '1' } }
      if (message.method === 'tools/list') result = message.params?.cursor
        ? { tools: [{ name: 'place_order', description: 'Place an order', inputSchema: { type: 'object', properties: { symbol: { type: 'string' } } } }] }
        : { tools: [{ name: 'get_accounts', inputSchema: { type: 'object' } }], nextCursor: 'next' }
      if (message.method === 'tools/call') {
        calls.push(message.params.name)
        if (fail) return json({ error: 'test failure' }, 500)
        result = { content: [{ type: 'text', text: 'fake account' }], structuredContent: { accounts: ['fake'] } }
      }
      return json({ jsonrpc: '2.0', id: message.id, result })
    }
    res.writeHead(404).end()
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  url = `http://127.0.0.1:${(server.address() as { port: number }).port}`
  const changed: string[] = []
  const secrets = {
    getApiKey: async (_provider?: string, profile?: string) => saved.get(profile!) ?? null,
    setApiKey: async (value: string, _provider?: string, profile?: string) => { saved.set(profile!, value) },
    clearApiKey: async (_provider?: string, profile?: string) => { saved.delete(profile!) },
  }
  const plugin = new Robinhood(store, secrets, dir, id => changed.push(id), `${url}/mcp`)
  t.after(async () => { plugin.close(); server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); db.close(); rmSync(dir, { recursive: true, force: true }) })
  const begin = async () => {
    const login = new URL((await plugin.connect('default')).url)
    challenge = login.searchParams.get('code_challenge')!
    const callback = new URL(login.searchParams.get('redirect_uri')!)
    callback.searchParams.set('state', login.searchParams.get('state')!)
    callback.searchParams.set('code', 'test-code')
    return callback
  }
  return { plugin, store, bot, saved, clients, calls, changed, begin, secrets, dir, url,
    expire: () => { accessToken = 'expired-on-server' }, tokenCalls: () => tokenCalls, fail: () => { fail = true } }
}

test('OAuth uses Routi identity and PKCE, validates state, and accepts a callback only once', async t => {
  const f = await fixture(t)
  const callback = await f.begin()
  assert.equal(f.clients[0]?.client_name, 'Routi Bot')
  assert.equal(f.clients[0]?.token_endpoint_auth_method, 'none')
  const wrong = new URL(callback); wrong.searchParams.set('state', 'wrong')
  await assert.rejects(f.plugin.finish('default', wrong.href), /does not match/)
  assert.equal(f.tokenCalls(), 0)
  const response = await fetch(callback)
  assert.equal(response.status, 200)
  assert.equal((await f.plugin.status('default')).connected, true)
  await assert.rejects(f.plugin.finish('default', callback.href), /expired/)
  assert.equal(f.tokenCalls(), 1)
  assert.ok(f.saved.size === 1)
})

test('screenless bot gets live paginated tools only after explicit enable; disconnect revokes stale contexts', async t => {
  const f = await fixture(t)
  assert.equal(f.plugin.context(f.bot.id), undefined)
  await assert.rejects(f.plugin.enable('default', f.bot.id, true), /Connect Robinhood first/)
  await f.plugin.finish('default', (await f.begin()).href)
  assert.equal(f.plugin.context(f.bot.id), undefined)
  await f.plugin.enable('default', f.bot.id, true)
  const ctx = { external: f.plugin.context(f.bot.id) }
  assert.equal(desktopToolSpecs(ctx, { screen: false }).length, 2)
  const list = await runDesktopTool(null, 'robinhood_list_tools', {}, ctx)
  assert.equal(list.ok, true)
  assert.equal(JSON.parse(list.output).length, 2)
  const result = await runDesktopTool(null, 'robinhood_call_tool', { name: 'get_accounts', arguments: {} }, ctx)
  assert.equal(result.ok, true)
  assert.deepEqual(JSON.parse(result.output).structuredContent, { accounts: ['fake'] })
  await f.plugin.disconnect('default')
  const refused = await runDesktopTool(null, 'robinhood_call_tool', { name: 'place_order', arguments: {} }, ctx)
  assert.equal(refused.ok, false)
  assert.deepEqual(f.calls, ['get_accounts'])
  assert.equal(f.saved.size, 0)
})

test('failed order is reported with uncertain outcome and is not replayed', async t => {
  const f = await fixture(t)
  await f.plugin.finish('default', (await f.begin()).href)
  await f.plugin.enable('default', f.bot.id, true)
  f.fail()
  const result = await runDesktopTool(null, 'robinhood_call_tool', { name: 'place_order', arguments: { symbol: 'TEST' } }, { external: f.plugin.context(f.bot.id) })
  assert.equal(result.ok, false)
  assert.match(result.output, /outcome is unknown/)
  assert.deepEqual(f.calls, ['place_order'])
})

test('profile isolation, restart persistence, and permanent bot deletion', async t => {
  const f = await fixture(t)
  await f.plugin.finish('default', (await f.begin()).href)
  await f.plugin.enable('default', f.bot.id, true)
  const other = f.store.createProfile('Other')
  await assert.rejects(f.plugin.enable(other.id, f.bot.id, true), /does not belong/)
  assert.equal((await f.plugin.status(other.id)).connected, false)
  const restarted = new Robinhood(f.store, f.secrets, f.dir, () => {}, `${f.url}/mcp`)
  assert.equal((await restarted.status('default')).connected, true)
  assert.ok(restarted.context(f.bot.id))
  const otherCore = new Robinhood(f.store, f.secrets, '/different/core', () => {}, `${f.url}/mcp`)
  assert.equal((await otherCore.status('default')).connected, false)
  f.store.deleteBot(f.bot.id)
  assert.equal(f.store.pluginEnabled('robinhood', f.bot.id), false)
  assert.equal(restarted.context(f.bot.id), undefined)
})

test('cancel and replacement logins reject callbacks from older attempts', async t => {
  const f = await fixture(t)
  const old = await f.begin()
  const current = await f.begin()
  await assert.rejects(f.plugin.finish('default', old.href), /does not match/)
  await f.plugin.disconnect('default')
  await assert.rejects(f.plugin.finish('default', current.href), /expired/)
  assert.equal(f.tokenCalls(), 0)
})


test('concurrent calls serialize token refresh and retain the refreshed login', async t => {
  const f = await fixture(t)
  await f.plugin.finish('default', (await f.begin()).href)
  await f.plugin.enable('default', f.bot.id, true)
  f.expire()
  const ctx = { external: f.plugin.context(f.bot.id) }
  const results = await Promise.all([1, 2].map(() => runDesktopTool(null, 'robinhood_call_tool', { name: 'get_accounts', arguments: {} }, ctx)))
  assert.ok(results.every(result => result.ok))
  assert.equal(f.tokenCalls(), 2)
  assert.deepEqual(f.calls, ['get_accounts', 'get_accounts'])
  assert.match([...f.saved.values()][0]!, /refreshed-access/)
})


test('reconnecting an account requires new bot grants', async t => {
  const f = await fixture(t)
  await f.plugin.finish('default', (await f.begin()).href)
  await f.plugin.enable('default', f.bot.id, true)
  await f.plugin.finish('default', (await f.begin()).href)
  assert.equal((await f.plugin.status('default')).connected, true)
  assert.equal(f.plugin.context(f.bot.id), undefined)
})


test('cancelled requests do not submit an order', async t => {
  const f = await fixture(t)
  await f.plugin.finish('default', (await f.begin()).href)
  await f.plugin.enable('default', f.bot.id, true)
  const abort = new AbortController()
  const ctx = { external: f.plugin.context(f.bot.id, abort.signal) }
  abort.abort()
  const result = await runDesktopTool(null, 'robinhood_call_tool', { name: 'place_order', arguments: {} }, ctx)
  assert.equal(result.ok, false)
  assert.deepEqual(f.calls, [])
})

test('login expires and cannot exchange its callback afterward', async t => {
  const f = await fixture(t)
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const callback = await f.begin()
  t.mock.timers.tick(10 * 60_000)
  assert.equal((await f.plugin.status('default')).connecting, false)
  await assert.rejects(f.plugin.finish('default', callback.href), /expired/)
  assert.equal(f.tokenCalls(), 0)
})
