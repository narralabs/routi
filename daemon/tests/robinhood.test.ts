import { dispatch, type RpcContext } from '../src/server/rpc.js'
import { mcpFailure } from '../src/plugins/mcp-error.js'
import { McpPlugin, MAX_PLUGIN_OUTPUT_BYTES } from '../src/plugins/mcp-plugin.js'
import { googleDefinitions } from '../src/plugins/google.js'
import { Plugins } from '../src/plugins/registry.js'
import type { McpPluginDefinition } from '../src/plugins/mcp-plugin.js'
import { robinhoodDefinition } from '../src/plugins/robinhood.js'
import assert from 'node:assert/strict'
import { test, type TestContext } from 'node:test'
import { createServer } from 'node:http'
import { createHash } from 'node:crypto'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { openDb } from '../src/db/schema.js'
import { Store } from '../src/db/store.js'
import { desktopToolSpecs, runDesktopTool } from '../src/surfaces/tools.js'

async function fixture(t: TestContext, definition: McpPluginDefinition = robinhoodDefinition) {
  const dir = mkdtempSync(join(tmpdir(), 'routi-robinhood-test-'))
  const db = openDb(join(dir, 'test.db'))
  const store = new Store(db)
  store.ensureDefaultProfile()
  const { bot } = store.createBot({ name: 'Trading bot', surfaceMode: 'none' })
  const saved = new Map<string, string>()
  const clients: Record<string, unknown>[] = []
  const calls: string[] = []
  const argumentsSent: Record<string, unknown>[] = []
  const readTool = definition.permissions?.[0]?.tools[0] ?? 'get_accounts'
  let tokenCalls = 0
  let fail = false
  let revoked = false
  let payload = ''
  let challenge = ''
  let accessToken = 'test-access'
  let grantedScope: string | undefined
  let url = ''
  const server = createServer(async (req, res) => {
    const path = new URL(req.url!, url).pathname
    const json = (value: unknown, status = 200) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(value)) }
    let body = ''
    for await (const chunk of req) body += chunk
    if (path.includes('oauth-protected-resource')) return json({ resource: `${url}/mcp`, authorization_servers: [url] })
    if (path.includes('oauth-authorization-server') || path.includes('openid-configuration')) return json({
      issuer: url, authorization_endpoint: `${url}/authorize`, token_endpoint: `${url}/token`, registration_endpoint: `${url}/register`,
      response_types_supported: ['code'], grant_types_supported: ['authorization_code', 'refresh_token'], code_challenge_methods_supported: ['S256'], token_endpoint_auth_methods_supported: definition?.oauth ? ['client_secret_post'] : ['none'],
    })
    if (path === '/register') {
      const registration = JSON.parse(body)
      clients.push(registration)
      return json({ ...registration, client_id: 'routi-test' }, 201)
    }
    if (path === '/token') {
      tokenCalls++
      if (revoked) return json({ error: 'invalid_grant', error_description: 'Token revoked' }, 400)
      const params = new URLSearchParams(body)
      if (definition?.oauth?.client?.client_secret) {
        assert.equal(params.get('client_id'), definition.oauth.client.client_id)
        assert.equal(params.get('client_secret'), definition.oauth.client.client_secret)
      }
      if (params.get('grant_type') === 'authorization_code') {
        assert.equal(params.get('code'), 'test-code')
        assert.equal(createHash('sha256').update(params.get('code_verifier')!).digest('base64url'), challenge)
      }
      if (params.get('grant_type') === 'refresh_token') accessToken = 'refreshed-access'
      return json({ scope: grantedScope, access_token: accessToken, refresh_token: 'test-refresh', token_type: 'Bearer', expires_in: 3600 })
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
        ? { tools: [{ name: 'place_order', description: payload || 'Place an order', inputSchema: { type: 'object', properties: { symbol: { type: 'string' } } } }] }
        : { tools: [{ name: readTool, inputSchema: { type: 'object' } }], nextCursor: 'next' }
      if (message.method === 'tools/call') {
        calls.push(message.params.name)
        argumentsSent.push(message.params.arguments)
        if (fail) return json({ error: 'test failure' }, 500)
        result = { content: [{ type: 'text', text: payload || 'fake account' }], structuredContent: { accounts: ['fake'] } }
      }
      return json({ jsonrpc: '2.0', id: message.id, result })
    }
    res.writeHead(404).end()
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  url = `http://127.0.0.1:${(server.address() as { port: number }).port}`
  const changed: string[] = []
  const secrets = {
    getApiKey: async (_provider?: string, profile?: string) => saved.get(`${_provider}:${profile}`) ?? null,
    setApiKey: async (value: string, _provider?: string, profile?: string) => { saved.set(`${_provider}:${profile}`, value) },
    clearApiKey: async (_provider?: string, profile?: string) => { saved.delete(`${_provider}:${profile}`) },
  }
  const plugin = new McpPlugin({ ...definition, url: `${url}/mcp` }, store, secrets, dir, id => changed.push(id))
  t.after(async () => { plugin.close(); server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); db.close(); rmSync(dir, { recursive: true, force: true }) })
  const callbackFor = (loginUrl: string) => {
    const login = new URL(loginUrl)
    challenge = login.searchParams.get('code_challenge')!
    const callback = new URL(login.searchParams.get('redirect_uri')!)
    callback.searchParams.set('state', login.searchParams.get('state')!)
    callback.searchParams.set('code', 'test-code')
    return callback
  }
  const begin = async () => callbackFor((await plugin.connect('default')).url)
  return { plugin, store, bot, saved, clients, calls, argumentsSent, readTool, changed, begin, callbackFor, secrets, dir, url,
    setScope: (value: string | undefined) => { grantedScope = value },
    setPayload: (value: string) => { payload = value },
    revoke: () => { revoked = true; accessToken = 'revoked-on-server' },
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
  assert.equal(JSON.parse(list.output).tools.length, 2)
  assert.doesNotMatch(list.output, /inputSchema/)
  const schema = await runDesktopTool(null, 'robinhood_list_tools', { name: 'place_order' }, ctx)
  assert.equal(schema.ok, true)
  assert.equal(JSON.parse(schema.output).inputSchema.properties.symbol.type, 'string')
  const unknown = await runDesktopTool(null, 'robinhood_list_tools', { name: 'get_account' }, ctx)
  assert.equal(unknown.ok, false)
  assert.match(unknown.output, /exact name/)
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
  const restarted = new McpPlugin({ ...robinhoodDefinition, url: `${f.url}/mcp` }, f.store, f.secrets, f.dir, () => {})
  assert.equal((await restarted.status('default')).connected, true)
  assert.ok(restarted.context(f.bot.id))
  const otherCore = new McpPlugin({ ...robinhoodDefinition, url: `${f.url}/mcp` }, f.store, f.secrets, '/different/core', () => {})
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


test('chat approval grants only the requesting bot and resumes once', async t => {
  const f = await fixture(t)
  await f.plugin.finish('default', (await f.begin()).href)
  const conversation = f.store.listConversations(f.bot.id)[0]!
  const other = f.store.createBot({ name: 'Other bot', surfaceMode: 'none' }).bot
  const resumed: string[] = []
  f.plugin.onAccessGranted = request => resumed.push(request.botId)
  await f.plugin.requestAccess(f.bot.id, conversation.id)
  await f.plugin.requestAccess(f.bot.id, conversation.id)
  const requests = f.plugin.accessList('default')
  assert.equal(requests.length, 1)
  assert.equal(requests[0]!.connected, true)
  assert.equal(f.store.pluginEnabled('robinhood', f.bot.id), false)
  await f.plugin.respondAccess('default', requests[0]!.id, true)
  assert.equal(f.store.pluginEnabled('robinhood', f.bot.id), true)
  assert.equal(f.store.pluginEnabled('robinhood', other.id), false)
  assert.deepEqual(resumed, [f.bot.id])
  await assert.rejects(f.plugin.respondAccess('default', requests[0]!.id, true), /expired/)
})

test('chat login grants access after OAuth completion, without a separate toggle', async t => {
  const f = await fixture(t)
  const conversation = f.store.listConversations(f.bot.id)[0]!
  let resumed = 0
  f.plugin.onAccessGranted = () => { resumed++ }
  await f.plugin.requestAccess(f.bot.id, conversation.id)
  const request = f.plugin.accessList('default')[0]!
  assert.equal(request.connected, false)
  const response = await f.plugin.respondAccess('default', request.id, true)
  assert.ok(response.url)
  assert.equal(f.store.pluginEnabled('robinhood', f.bot.id), false)
  await f.plugin.finish('default', f.callbackFor(response.url!).href)
  assert.equal(f.store.pluginEnabled('robinhood', f.bot.id), true)
  assert.equal(resumed, 1)
  assert.deepEqual(f.plugin.accessList('default'), [])
})

test('declined, expired, cross-profile, and deleted-bot cards cannot grant access', async t => {
  const f = await fixture(t)
  const conversation = f.store.listConversations(f.bot.id)[0]!
  const other = f.store.createProfile('Work')
  await f.plugin.requestAccess(f.bot.id, conversation.id)
  let request = f.plugin.accessList('default')[0]!
  await assert.rejects(f.plugin.respondAccess(other.id, request.id, true), /expired/)
  await f.plugin.respondAccess('default', request.id, false)
  assert.equal(f.store.pluginEnabled('robinhood', f.bot.id), false)
  await assert.rejects(f.plugin.respondAccess('default', request.id, true), /expired/)
  t.mock.timers.enable({ apis: ['Date'] })
  await f.plugin.requestAccess(f.bot.id, conversation.id)
  request = f.plugin.accessList('default')[0]!
  t.mock.timers.tick(10 * 60_000)
  await assert.rejects(f.plugin.respondAccess('default', request.id, true), /expired/)
  await f.plugin.requestAccess(f.bot.id, conversation.id)
  request = f.plugin.accessList('default')[0]!
  f.store.deleteBot(f.bot.id)
  await assert.rejects(f.plugin.respondAccess('default', request.id, true), /expired/)
})

test('cancelling a chat login prevents its callback from granting access', async t => {
  const f = await fixture(t)
  const conversation = f.store.listConversations(f.bot.id)[0]!
  await f.plugin.requestAccess(f.bot.id, conversation.id)
  const request = f.plugin.accessList('default')[0]!
  const response = await f.plugin.respondAccess('default', request.id, true)
  const callback = f.callbackFor(response.url!)
  await f.plugin.respondAccess('default', request.id, false)
  await assert.rejects(f.plugin.finish('default', callback.href), /expired/)
  assert.equal(f.tokenCalls(), 0)
  assert.equal(f.store.pluginEnabled('robinhood', f.bot.id), false)
})


test('failure messages distinguish authentication from transport errors without exposing error payloads', () => {
  assert.equal(mcpFailure(robinhoodDefinition, { code: 401 }).kind, 'authentication')
  assert.equal(mcpFailure(robinhoodDefinition, { name: 'InvalidGrantError' }).kind, 'authentication')
  assert.equal(mcpFailure(robinhoodDefinition, { code: 503 }).kind, 'http_503')
  assert.equal(mcpFailure(robinhoodDefinition, { name: 'TimeoutError' }).kind, 'timeout')
  assert.equal(mcpFailure(robinhoodDefinition, new Error('secret access token'), true).kind, 'cancelled')
  assert.doesNotMatch(JSON.stringify(mcpFailure(robinhoodDefinition, new Error('secret access token'))), /secret access token/)
})

test('a second MCP plugin reuses login and discovery without sharing credentials or bot grants', async t => {
  const f = await fixture(t)
  await f.plugin.finish('default', (await f.begin()).href)
  await f.plugin.enable('default', f.bot.id, true)
  const other = new McpPlugin({ id: 'notes', name: 'Notes', url: `${f.url}/mcp` }, f.store, f.secrets, f.dir, () => {})
  t.after(() => other.close())
  assert.equal((await other.status('default')).connected, false)
  assert.equal(other.context(f.bot.id), undefined)
  await other.finish('default', f.callbackFor((await other.connect('default')).url).href)
  // Signing in to another plugin does not revoke the existing Robinhood grant.
  assert.equal(f.store.pluginEnabled('robinhood', f.bot.id), true)
  assert.equal(f.store.pluginEnabled('notes', f.bot.id), false)
  const conversation = f.store.listConversations(f.bot.id)[0]!
  await other.requestAccess(f.bot.id, conversation.id)
  const request = other.accessList('default')[0]!
  await assert.rejects(f.plugin.respondAccess('default', request.id, true), /expired/)
  await other.respondAccess('default', request.id, true)
  const ctx = { external: other.context(f.bot.id) }
  const list = await runDesktopTool(null, 'notes_list_tools', {}, ctx)
  assert.equal(list.ok, true)
  assert.doesNotMatch(list.output, /Robinhood|robinhood|inputSchema/)
  const schema = await runDesktopTool(null, 'notes_list_tools', { name: 'get_accounts' }, ctx)
  assert.equal(JSON.parse(schema.output).name, 'get_accounts')
  const call = await runDesktopTool(null, 'notes_call_tool', { name: 'get_accounts', arguments: {} }, ctx)
  assert.equal(call.ok, true)
  const slot = `${createHash('sha256').update(f.dir).digest('hex').slice(0, 16)}.default`
  assert.ok(f.saved.has(`robinhood:${slot}`), 'existing Robinhood credential key is unchanged')
  assert.ok(f.saved.has(`mcp:notes:${slot}`))
  await other.disconnect('default')
  assert.equal(f.store.pluginEnabled('notes', f.bot.id), false)
  assert.equal((await f.plugin.status('default')).connected, true)
  assert.equal(f.store.pluginEnabled('robinhood', f.bot.id), true)
  assert.equal((await runDesktopTool(null, 'notes_call_tool', { name: 'get_accounts', arguments: {} }, ctx)).ok, false)
  assert.equal((await runDesktopTool(null, 'robinhood_call_tool', { name: 'get_accounts', arguments: {} }, { external: f.plugin.context(f.bot.id) })).ok, true)
})


test('oversized schemas and results are withheld without replaying actions', async t => {
  const f = await fixture(t)
  await f.plugin.finish('default', (await f.begin()).href)
  await f.plugin.enable('default', f.bot.id, true)
  const ctx = { external: f.plugin.context(f.bot.id) }
  assert.equal(ctx.external!.specs.length, 2)
  // Multibyte text verifies the byte limit, not just a character count.
  f.setPayload('界'.repeat(MAX_PLUGIN_OUTPUT_BYTES / 2))
  const index = await runDesktopTool(null, 'robinhood_list_tools', {}, ctx)
  assert.equal(index.ok, true)
  assert.ok(Buffer.byteLength(index.output) < MAX_PLUGIN_OUTPUT_BYTES)
  const schema = await runDesktopTool(null, 'robinhood_list_tools', { name: 'place_order' }, ctx)
  assert.equal(schema.ok, false)
  assert.match(schema.output, /withheld/)
  const result = await runDesktopTool(null, 'robinhood_call_tool', { name: 'place_order', arguments: {} }, ctx)
  assert.equal(result.ok, false)
  assert.ok(Buffer.byteLength(result.output) < MAX_PLUGIN_OUTPUT_BYTES)
  assert.doesNotMatch(result.output, /界/)
  assert.match(result.output, /may already have completed/)
  assert.deepEqual(f.calls, ['place_order'])
  f.setPayload('small response')
  const small = await runDesktopTool(null, 'robinhood_call_tool', { name: 'get_accounts', arguments: {} }, ctx)
  assert.equal(small.ok, true)
  assert.equal(JSON.parse(small.output).content[0].text, 'small response')
})


for (const expiresAt of [0, undefined]) test(`local Gmail send refreshes ${expiresAt === 0 ? 'expired' : 'undated'} credentials even when MCP accepts them`, async t => {
  const definition = googleDefinitions()[0]!
  const tokens: string[] = []
  const f = await fixture(t, { ...definition, accountEmail: undefined,
    oauth: { ...definition.oauth!, client: { client_id: 'google-test' } },
    localTools: [{ ...definition.localTools![1]!, run: async (_args, token) => {
      tokens.push(token)
      return { content: [] }
    } }],
  })
  f.setScope(definition.oauth!.scope)
  await f.plugin.finish('default', (await f.begin()).href)
  await f.plugin.enable('default', f.bot.id, true)
  f.plugin.setPermission('default', 'send', 'allow')
  for (const [key, value] of f.saved) f.saved.set(key, JSON.stringify({ ...JSON.parse(value), expiresAt }))
  const context = f.plugin.context(f.bot.id)!
  for (let i = 0; i < 2; i++) assert.equal((await context.run('gmail_send_email', { to: ['test@example.com'], subject: 'Test', body: 'Test' })).ok, true)
  assert.deepEqual(tokens, ['refreshed-access', 'refreshed-access'])
  assert.equal(f.tokenCalls(), 2, 'one initial exchange and one refresh; reuse the fresh token')
  assert.deepEqual(f.calls, [])
})

for (const definition of googleDefinitions()) test(`${definition.name} uses a registered OAuth client, service scopes and offline consent`, async t => {
  const f = await fixture(t, { ...definition, accountEmail: async () => 'test@example.com', oauth: { ...definition.oauth!, client: { client_id: 'google-test', client_secret: 'test-client-secret' } } })
  f.setScope(definition.oauth!.scope)
  const login = new URL((await f.plugin.connect('default')).url)
  assert.equal(login.searchParams.get('client_id'), 'google-test')
  assert.equal(login.searchParams.get('scope'), definition.oauth!.scope)
  assert.equal(login.searchParams.get('access_type'), 'offline')
  assert.equal(login.searchParams.get('prompt'), 'consent')
  assert.equal(login.searchParams.get('code_challenge_method'), 'S256')
  assert.equal(f.clients.length, 0, 'Google must not use dynamic client registration')
  await f.plugin.finish('default', f.callbackFor(login.href).href)
  await f.plugin.enable('default', f.bot.id, true)
  assert.equal(f.store.pluginEnabled(definition.id, f.bot.id), true)
  assert.equal(f.store.pluginEnabled('robinhood', f.bot.id), false)
  assert.equal((await f.plugin.context(f.bot.id)!.run(`${definition.id}_list_tools`, {})).ok, true)
  assert.equal((await f.plugin.context(f.bot.id)!.run(`${definition.id}_call_tool`, { name: f.readTool, arguments: {} })).ok, true)
  for (const other of googleDefinitions().filter(other => other.id !== definition.id)) {
    assert.equal(f.store.pluginEnabled(other.id, f.bot.id), false)
    assert.equal((await new McpPlugin(other, f.store, f.secrets, f.dir, () => {}).status('default')).connected, false)
  }
  f.expire()
  assert.equal((await f.plugin.context(f.bot.id)!.run(`${definition.id}_list_tools`, {})).ok, true)
  assert.equal(f.tokenCalls(), 2, 'saved Google credentials refresh without a new sign-in')
  assert.equal((await f.plugin.status('default')).accountEmail, 'test@example.com')
})

test('missing Google client fails before opening a login session', async t => {
  const definition = googleDefinitions()[0]!
  const f = await fixture(t, { ...definition, oauth: { ...definition.oauth!, client: undefined } })
  await assert.rejects(f.plugin.connect('default'), /Google sign-in is not configured/)
  assert.equal((await f.plugin.status('default')).connecting, false)
})

test('plugin roster routes approvals and keeps service and profile grants separate', async t => {
  const f = await fixture(t)
  const plugins = new Plugins(f.store, f.secrets, f.dir, () => {})
  t.after(() => plugins.close())
  const conversation = f.store.listConversations().find(c => c.botId === f.bot.id)!
  const ctx = plugins.toolContext(f.bot.id, conversation.id)
  assert.equal(ctx.external!.specs.length, 12, 'two entry points per service plus the two local Gmail send tools')
  assert.deepEqual(ctx.pluginIds, ['robinhood', 'gmail', 'google_calendar', 'google_drive', 'google_docs'])
  await ctx.requestPluginAccess!('gmail')
  const request = plugins.accessList('default')[0]!
  assert.equal(request.pluginId, 'gmail')
  const rpc = { plugins } as RpcContext
  assert.deepEqual(await dispatch('robinhood.access.list', { profileId: 'default' }, rpc), { requests: [] })
  assert.deepEqual(await dispatch('plugin.access.list', { profileId: 'default' }, rpc), { requests: [request] })
  assert.deepEqual(await dispatch('robinhood.status', { profileId: 'default' }, rpc),
    await dispatch('plugin.status', { profileId: 'default', pluginId: 'robinhood' }, rpc))
  await assert.rejects(dispatch('plugin.status', { profileId: 'default', pluginId: 'missing' }, rpc), /Unknown plugin/)

  assert.equal(plugins.get('robinhood').accessList('default').length, 0)
  assert.equal(plugins.accessList('other-profile').length, 0)
  await plugins.get('gmail').respondAccess('default', request.id, false)
  assert.equal(plugins.accessList('default').length, 0)
  assert.equal((await ctx.external!.run('gmail_list_tools', {})).ok, false)
  assert.equal((await ctx.external!.run('robinhood_list_tools', {})).ok, false)
})


test('connected account identity follows reconnect and is cleared by disconnect', async t => {
  let email: string | null = 'first@example.com'
  const f = await fixture(t, { ...robinhoodDefinition, accountEmail: async () => email })
  await f.plugin.finish('default', (await f.begin()).href)
  assert.equal((await f.plugin.status('default')).accountEmail, 'first@example.com')
  email = 'second@example.com'
  await f.plugin.finish('default', (await f.begin()).href)
  assert.equal((await f.plugin.status('default')).accountEmail, 'second@example.com')
  email = null
  await f.plugin.finish('default', (await f.begin()).href)
  assert.equal((await f.plugin.status('default')).connected, true)
  assert.equal((await f.plugin.status('default')).accountEmail, null, 'never show the previous account after reconnect')
  await f.plugin.disconnect('default')
  assert.equal((await f.plugin.status('default')).accountEmail, null)
})

test('Gmail local tools share discovery, refreshed credentials, and bot access checks', async t => {
  const tokens: string[] = []
  const definition = googleDefinitions()[0]!
  const f = await fixture(t, { ...definition, accountEmail: undefined,
    oauth: { ...definition.oauth!, client: { client_id: 'google-test', client_secret: 'test-client-secret' } },
    localTools: [{ spec: definition.localTools![0]!.spec, run: async (_args, token) => {
      tokens.push(token)
      return { content: [{ type: 'text', text: 'sent' }] }
    } }],
  })
  f.setScope(definition.oauth!.scope)
  await f.plugin.finish('default', (await f.begin()).href)
  f.plugin.setPermission('default', 'send', 'allow')
  const ctx = f.plugin.context(f.bot.id, undefined, true)!
  assert.match(ctx.specs.find(tool => tool.name === 'gmail_list_tools')!.description, /gmail_send_draft/ )
  const call = () => ctx.run('gmail_call_tool', { name: 'gmail_send_draft', arguments: { draftId: 'draft' } })
  assert.equal((await call()).ok, false)
  assert.deepEqual(tokens, [])
  await f.plugin.enable('default', f.bot.id, true)
  assert.match((await ctx.run('gmail_list_tools', {})).output, /gmail_send_draft/)
  assert.match((await ctx.run('gmail_list_tools', { name: 'gmail_send_draft' })).output, /draftId/)
  f.expire()
  assert.equal((await call()).ok, true)
  assert.deepEqual(tokens, ['refreshed-access'])
  assert.deepEqual(f.calls, [], 'local tool is not submitted to the remote MCP server')
  await f.plugin.enable('default', f.bot.id, false)
  assert.equal((await call()).ok, false)
  assert.equal(tokens.length, 1)
})

for (const definition of googleDefinitions()) test(`${definition.name} reports granted scopes and supports read-only consent`, async t => {
  const f = await fixture(t, { ...definition, accountEmail: undefined, oauth: { ...definition.oauth!, client: { client_id: 'google-test' } } })
  const status = await f.plugin.status('default')
  assert.equal(status.grantedScopes, null)
  assert.equal(status.supportsReadOnly, true)
  const login = new URL((await f.plugin.connect('default', undefined, true)).url)
  assert.equal(login.searchParams.get('scope'), definition.oauth!.readOnlyScope)
  // Google can grant a subset, not necessarily everything requested.
  const granted = definition.oauth!.readOnlyScope!.split(' ').at(-1)!
  f.setScope(granted)
  await f.plugin.finish('default', f.callbackFor(login.href).href)
  assert.deepEqual((await f.plugin.status('default')).grantedScopes, [granted])
  await f.plugin.enable('default', f.bot.id, true)
  if (definition.id === 'gmail') {
    const context = f.plugin.context(f.bot.id)!
    const index = await context.run('gmail_list_tools', {})
    assert.doesNotMatch(index.output, /gmail_send_draft/)
    const send = await context.run('gmail_call_tool', { name: 'gmail_send_draft', arguments: { draftId: 'test' } })
    assert.equal(send.ok, false)
    assert.match(send.output, /does not allow/)
    assert.deepEqual(f.calls, [], 'read-only Gmail must not attempt a send')
  }
  f.setScope(undefined)
  f.expire()
  await f.plugin.context(f.bot.id)!.run(`${definition.id}_list_tools`, {})
  assert.deepEqual((await f.plugin.status('default')).grantedScopes, [granted], 'refresh without scopes keeps the existing grant')
  const reconnect = await f.plugin.connect('default')
  assert.equal(new URL(reconnect.url).searchParams.get('scope'), definition.oauth!.scope)
  await f.plugin.finish('default', f.callbackFor(reconnect.url).href)
  assert.equal((await f.plugin.status('default')).grantedScopes, null, 'new consent without scope must not inherit old permissions')
  await f.plugin.disconnect('default')
  assert.equal((await f.plugin.status('default')).grantedScopes, null)
})

async function connectedGmail(t: TestContext, preview?: NonNullable<McpPluginDefinition['localTools']>[number]['preview']) {
  const definition = googleDefinitions()[0]!
  const localCalls: Record<string, unknown>[] = []
  const f = await fixture(t, { ...definition, accountEmail: undefined,
    oauth: { ...definition.oauth!, client: { client_id: 'google-test' } },
    localTools: definition.localTools!.map(tool => ({ ...tool, preview: tool.spec.name === 'gmail_send_draft' ? preview : undefined, run: async args => {
      localCalls.push(args)
      return { content: [{ type: 'text' as const, text: 'sent' }] }
    } })),
  })
  f.setScope(definition.oauth!.scope)
  await f.plugin.finish('default', (await f.begin()).href)
  await f.plugin.enable('default', f.bot.id, true)
  const conversation = f.store.listConversations().find(c => c.botId === f.bot.id)!
  const controller = new AbortController()
  const context = f.plugin.context(f.bot.id, controller.signal, true, conversation.id)!
  const nextApproval = () => new Promise<ReturnType<typeof f.plugin.accessList>[number]>(resolve => {
    f.plugin.onAccessChanged = () => {
      const request = f.plugin.accessList('default').find(r => r.action)
      if (request) resolve(request)
    }
  })
  return { ...f, localCalls, context, controller, nextApproval }
}

test('Ask approves one exact call; a second call and local draft sending require separate decisions', async t => {
  const f = await connectedGmail(t)
  assert.equal((await f.context.run('gmail_list_tools', { name: 'gmail_send_draft' })).ok, true, 'Ask tools must still expose their schemas before approval')
  let accessGrants = 0
  f.plugin.onAccessGranted = () => { accessGrants++ }
  const approval = f.nextApproval()
  const args = { name: 'send_message', arguments: { to: ['example@example.com'], body: 'Approved text' } }
  const call = f.context.run('gmail_call_tool', args)
  const request = await approval
  args.arguments.body = 'Changed after request'
  assert.deepEqual(f.calls, [])
  assert.equal(JSON.parse(request.action!.arguments).body, 'Approved text')
  await assert.rejects(f.plugin.respondAccess('missing-profile', request.id, true))
  await f.plugin.respondAccess('default', request.id, true)
  assert.equal((await call).ok, true)
  assert.equal(f.argumentsSent[0]!.body, 'Approved text')
  assert.equal(accessGrants, 0, 'action approval must not grant bot access or start another turn')
  await assert.rejects(f.plugin.respondAccess('default', request.id, true), /expired/)

  const next = f.nextApproval()
  const local = f.context.run('gmail_call_tool', { name: 'gmail_send_draft', arguments: { draftId: 'draft' } })
  await f.plugin.respondAccess('default', (await next).id, false)
  assert.equal((await local).ok, false)
  assert.deepEqual(f.localCalls, [])
  assert.deepEqual(f.calls, ['send_message'])
})

test('approval executes the edited details once and reports them to the bot', async t => {
  const f = await connectedGmail(t)
  const approval = f.nextApproval()
  const call = f.context.run('gmail_call_tool', { name: 'send_message', arguments: { to: ['original@example.com'], body: 'Original' } })
  const request = await approval
  const edits = { to: ['edited@example.com'], subject: 'Updated', body: 'Added detail' }
  await assert.rejects(f.plugin.respondAccess('default', request.id, true, [] as unknown as Record<string, unknown>), /must be an object/)
  await f.plugin.respondAccess('default', request.id, true, edits)
  edits.body = 'Changed after approval'
  const result = await call
  assert.equal(result.ok, true)
  assert.deepEqual(f.argumentsSent, [{ to: ['edited@example.com'], subject: 'Updated', body: 'Added detail' }])
  assert.deepEqual(JSON.parse(result.output).approvedArguments, f.argumentsSent[0])
  await assert.rejects(f.plugin.respondAccess('default', request.id, true, edits), /expired/)

  const localApproval = f.nextApproval()
  const local = f.context.run('gmail_call_tool', { name: 'gmail_send_draft', arguments: { draftId: 'old' } })
  await f.plugin.respondAccess('default', (await localApproval).id, true, { draftId: 'edited' })
  assert.equal((await local).ok, true)
  assert.deepEqual(f.localCalls, [{ draftId: 'edited' }])

  const deniedApproval = f.nextApproval()
  const denied = f.context.run('gmail_call_tool', { name: 'send_message', arguments: {} })
  await f.plugin.respondAccess('default', (await deniedApproval).id, false, edits)
  assert.equal((await denied).ok, false)
  assert.deepEqual(f.calls, ['send_message'])
})

for (const changed of [false, true]) test(`saved draft preview is bound to the approved draft (changed=${changed})`, async t => {
  const f = await connectedGmail(t, async args => {
    assert.equal(args.draftId, 'draft')
    return { details: { to: 'reader@example.com', subject: 'Hello', body: 'Review this' }, beforeRun: async () => {
      if (changed) throw new Error('Draft changed')
    } }
  })
  const approval = f.nextApproval()
  const call = f.context.run('gmail_call_tool', { name: 'gmail_send_draft', arguments: { draftId: 'draft' } })
  const request = await approval
  assert.deepEqual(JSON.parse(request.action!.preview!), { to: 'reader@example.com', subject: 'Hello', body: 'Review this' })
  await assert.rejects(f.plugin.respondAccess('default', request.id, true, { draftId: 'other' }), /cannot be changed/)
  await f.plugin.respondAccess('default', request.id, true)
  assert.equal((await call).ok, !changed)
  assert.deepEqual(f.localCalls, changed ? [] : [{ draftId: 'draft' }])
})

test('send edits reach the save step only after approval, without changing the draft ID', async t => {
  const saved: unknown[] = []
  const details = { to: 'reader@example.com', body: 'Original', from: 'sender@example.com' }
  const f = await connectedGmail(t, async () => ({ details, editableFields: ['to', 'body'], beforeRun: async (_token, _signal, edits) => { saved.push(edits) } }))
  const next = f.nextApproval()
  const call = f.context.run('gmail_call_tool', { name: 'gmail_send_draft', arguments: { draftId: 'draft' } })
  const request = await next
  const edits = { ...details, body: 'More detail' }
  await assert.rejects(f.plugin.respondAccess('default', request.id, true, { ...edits, from: 'other@example.com' }), /cannot be changed/)
  await f.plugin.respondAccess('default', request.id, true, edits)
  const result = await call
  assert.equal(result.ok, true)
  assert.deepEqual(saved, [edits])
  assert.deepEqual(f.localCalls, [{ draftId: 'draft' }])
  assert.deepEqual(JSON.parse(result.output).approvedArguments, edits)

  const cancelledApproval = f.nextApproval()
  const cancelled = f.context.run('gmail_call_tool', { name: 'gmail_send_draft', arguments: { draftId: 'draft' } })
  await f.plugin.respondAccess('default', (await cancelledApproval).id, false, { ...details, body: 'Do not save' })
  assert.equal((await cancelled).ok, false)
  assert.equal(saved.length, 1)
  assert.equal(f.localCalls.length, 1)
})

test('email approval refreshes credentials that expired while the user was reviewing', async t => {
  const f = await connectedGmail(t)
  const approval = f.nextApproval()
  const call = f.context.run('gmail_send_email', { to: ['test@example.com'], subject: 'Test', body: 'Test' })
  const request = await approval
  for (const [key, value] of f.saved) f.saved.set(key, JSON.stringify({ ...JSON.parse(value), expiresAt: 0 }))
  assert.equal(f.tokenCalls(), 1)
  await f.plugin.respondAccess('default', request.id, true)
  assert.equal((await call).ok, true)
  assert.equal(f.tokenCalls(), 2)
  assert.equal(f.localCalls.length, 1, 'send executes once after refresh')
})

test('new email needs one editable send approval and cancellation creates no draft', async t => {
  const f = await connectedGmail(t)
  assert.ok(f.context.specs.some(tool => tool.name === 'gmail_send_email'))
  const details = { to: ['reader@example.com'], subject: 'Hello', body: 'Original' }
  const next = f.nextApproval()
  const call = f.context.run('gmail_send_email', details)
  const request = await next
  assert.equal(request.action!.tool, 'gmail_send_email')
  assert.deepEqual(f.localCalls, [])
  await f.plugin.respondAccess('default', request.id, true, { ...details, body: 'Changed' })
  assert.equal((await call).ok, true)
  assert.deepEqual(f.localCalls, [{ ...details, body: 'Changed' }])
  assert.deepEqual(f.calls, [], 'no remote create_draft call')
  assert.deepEqual(f.plugin.accessList('default'), [])
  const deniedApproval = f.nextApproval()
  const denied = f.context.run('gmail_send_email', details)
  await f.plugin.respondAccess('default', (await deniedApproval).id, false)
  assert.equal((await denied).ok, false)
  assert.equal(f.localCalls.length, 1)
  assert.deepEqual(f.calls, [])
})

test('Deny blocks direct and discovered tools, persists across restart, and does not change Google grants', async t => {
  const f = await connectedGmail(t)
  const granted = (await f.plugin.status('default')).grantedScopes
  f.plugin.setPermission('default', 'send', 'deny')
  assert.equal((await f.context.run('gmail_send_email', { to: ['reader@example.com'], subject: 'Hi', body: 'Hi' })).ok, false)
  for (const name of ['send_message', 'gmail_send_draft']) {
    assert.equal((await f.context.run('gmail_call_tool', { name, arguments: { draftId: 'draft' } })).ok, false)
  }
  assert.doesNotMatch((await f.context.run('gmail_list_tools', {})).output, /gmail_send_draft/)
  assert.deepEqual(f.calls, [])
  assert.deepEqual(f.localCalls, [])
  const restarted = new McpPlugin(googleDefinitions()[0]!, f.store, f.secrets, f.dir, () => {})
  const status = await restarted.status('default')
  assert.equal(status.permissions!.find(p => p.id === 'send')!.rule, 'deny')
  assert.deepEqual(status.grantedScopes, granted)
  const other = f.store.createProfile('Other')
  assert.equal((await restarted.status(other.id)).permissions!.find(p => p.id === 'send')!.rule, 'ask')
})

for (const cancel of ['policy', 'disconnect', 'abort', 'bot access'] as const) test(`${cancel} cancels a pending action without executing it or blocking disconnect`, async t => {
  const f = await connectedGmail(t)
  const approval = f.nextApproval()
  const call = f.context.run('gmail_call_tool', { name: 'send_message', arguments: {} })
  const request = await approval
  if (cancel === 'policy') f.plugin.setPermission('default', 'send', 'deny')
  if (cancel === 'disconnect') await f.plugin.disconnect('default')
  if (cancel === 'abort') f.controller.abort()
  if (cancel === 'bot access') await f.plugin.enable('default', f.bot.id, false)
  assert.equal((await call).ok, false)
  assert.deepEqual(f.calls, [])
  assert.equal(f.plugin.accessList('default').length, 0)
  await assert.rejects(f.plugin.respondAccess('default', request.id, true), /expired/)
})

test('Allow cannot grant missing Google access or bypass classification; reads still work', async t => {
  const f = await connectedGmail(t)
  assert.equal((await f.context.run('gmail_call_tool', { name: 'get_message', arguments: {} })).ok, true)
  f.plugin.setPermission('default', 'send', 'allow')
  assert.equal((await f.context.run('gmail_call_tool', { name: 'gmail_send_draft', arguments: { draftId: 'draft' } })).ok, true)
  assert.equal(f.localCalls.length, 1)
  f.setScope('https://www.googleapis.com/auth/gmail.readonly')
  await f.plugin.finish('default', (await f.begin()).href)
  await f.plugin.enable('default', f.bot.id, true)
  assert.equal((await f.context.run('gmail_call_tool', { name: 'send_message', arguments: {} })).ok, false)
  assert.equal((await f.plugin.status('default')).permissions!.find(p => p.id === 'send')!.available, false)
  assert.equal((await f.context.run('gmail_call_tool', { name: 'new_unreviewed_tool', arguments: {} })).ok, false)
  assert.deepEqual(f.calls, ['get_message'])
})


test('revoked Google login stops calls and asks the user to reconnect', async t => {
  const f = await connectedGmail(t)
  f.revoke()
  const result = await f.context.run('gmail_call_tool', { name: 'get_message', arguments: {} })
  assert.equal(result.ok, false)
  assert.deepEqual(f.calls, [])
  const status = await f.plugin.status('default')
  assert.equal(status.connected, false)
  assert.match(status.error!, /Reconnect/)
  assert.deepEqual(status.botIds, [])
})

test('Gmail upgrade uses returned grants; cancelled consent preserves read access and a narrower request cannot erase a broad grant', async t => {
  const definition = googleDefinitions()[0]!
  const f = await fixture(t, { ...definition, accountEmail: undefined, oauth: { ...definition.oauth!, client: { client_id: 'google-test' } } })
  f.setScope(definition.oauth!.readOnlyScope)
  const readOnlyLogin = await f.plugin.connect('default', undefined, true)
  assert.equal(new URL(readOnlyLogin.url).searchParams.get('scope'), definition.oauth!.readOnlyScope)
  await f.plugin.finish('default', f.callbackFor(readOnlyLogin.url).href)
  await f.plugin.enable('default', f.bot.id, true)
  const cancelled = f.callbackFor((await f.plugin.connect('default')).url)
  cancelled.searchParams.delete('code')
  cancelled.searchParams.set('error', 'access_denied')
  await assert.rejects(f.plugin.finish('default', cancelled.href))
  assert.equal((await f.plugin.status('default')).connected, true)
  assert.equal(f.store.pluginEnabled('gmail', f.bot.id), true)
  assert.equal((await f.plugin.status('default')).permissions!.find(p => p.id === 'send')!.available, false)

  const upgrade = await f.plugin.connect('default')
  assert.equal(new URL(upgrade.url).searchParams.get('scope'), definition.oauth!.scope)
  f.setScope(definition.oauth!.scope)
  await f.plugin.finish('default', f.callbackFor(upgrade.url).href)
  assert.equal((await f.plugin.status('default')).permissions!.find(p => p.id === 'send')!.available, true)
  assert.deepEqual((await f.plugin.status('default')).botIds, [], 'new consent requires bot access approval again')

  const narrower = await f.plugin.connect('default', undefined, true)
  await f.plugin.finish('default', f.callbackFor(narrower.url).href)
  assert.equal((await f.plugin.status('default')).permissions!.find(p => p.id === 'send')!.available, true, 'show the broad grant Google actually returned')
  await f.plugin.disconnect('default')
  f.setScope(definition.oauth!.readOnlyScope)
  await f.plugin.finish('default', f.callbackFor((await f.plugin.connect('default', undefined, true)).url).href)
  assert.equal((await f.plugin.status('default')).permissions!.find(p => p.id === 'send')!.available, false, 'fresh read-only grant after Google revocation has no sending')
})


test('temporary Google server errors do not disconnect a valid login', async t => {
  const f = await connectedGmail(t)
  f.fail()
  assert.equal((await f.context.run('gmail_call_tool', { name: 'get_message', arguments: {} })).ok, false)
  const status = await f.plugin.status('default')
  assert.equal(status.connected, true)
  assert.equal(status.error, null)
  assert.deepEqual(status.botIds, [f.bot.id])
})

test('Gmail can request read-only access again after the user declines every service permission', async t => {
  const definition = googleDefinitions()[0]!
  const f = await fixture(t, { ...definition, accountEmail: undefined, oauth: { ...definition.oauth!, client: { client_id: 'google-test' } } })
  f.setScope('openid email')
  const first = await f.plugin.connect('default', undefined, true)
  await f.plugin.finish('default', f.callbackFor(first.url).href)
  const initial = await f.plugin.status('default')
  assert.equal(initial.connected, true)
  assert.ok(initial.permissions!.every(p => !p.available))

  const retry = await f.plugin.connect('default', undefined, true)
  assert.equal(new URL(retry.url).searchParams.get('scope'), definition.oauth!.readOnlyScope)
  f.setScope(definition.oauth!.readOnlyScope)
  await f.plugin.finish('default', f.callbackFor(retry.url).href)
  const permissions = (await f.plugin.status('default')).permissions!
  assert.equal(permissions.find(p => p.id === 'read')!.available, true)
  assert.equal(permissions.find(p => p.id === 'send')!.available, false)
  assert.equal(permissions.find(p => p.id === 'write')!.available, false)
})
