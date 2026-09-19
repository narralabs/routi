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
import { Robinhood } from '../src/plugins/robinhood.js'
import { desktopToolSpecs, runDesktopTool } from '../src/surfaces/tools.js'

async function fixture(t: TestContext, definition?: McpPluginDefinition) {
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
  let payload = ''
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
      response_types_supported: ['code'], grant_types_supported: ['authorization_code', 'refresh_token'], code_challenge_methods_supported: ['S256'], token_endpoint_auth_methods_supported: definition?.oauth ? ['client_secret_post'] : ['none'],
    })
    if (path === '/register') {
      const registration = JSON.parse(body)
      clients.push(registration)
      return json({ ...registration, client_id: 'routi-test' }, 201)
    }
    if (path === '/token') {
      tokenCalls++
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
        ? { tools: [{ name: 'place_order', description: payload || 'Place an order', inputSchema: { type: 'object', properties: { symbol: { type: 'string' } } } }] }
        : { tools: [{ name: 'get_accounts', inputSchema: { type: 'object' } }], nextCursor: 'next' }
      if (message.method === 'tools/call') {
        calls.push(message.params.name)
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
  const plugin = definition
    ? new McpPlugin({ ...definition, url: `${url}/mcp` }, store, secrets, dir, id => changed.push(id))
    : new Robinhood(store, secrets, dir, id => changed.push(id), `${url}/mcp`)
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
  return { plugin, store, bot, saved, clients, calls, changed, begin, callbackFor, secrets, dir, url,
    setPayload: (value: string) => { payload = value },
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
  const conversation = f.store.listConversations(f.bot.id)[0]!
  const ctx = f.plugin.toolContext(f.bot.id, conversation.id)
  assert.equal((await ctx.requestPluginAccess!('unknown')).ok, false)
  assert.equal((await ctx.requestPluginAccess!('robinhood')).ok, true)
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


test('Google uses a registered OAuth client, narrow scopes and offline consent', async t => {
  const definition = googleDefinitions()[0]!
  const f = await fixture(t, { ...definition, accountEmail: async () => 'test@example.com', oauth: { ...definition.oauth!, client: { client_id: 'google-test', client_secret: 'test-client-secret' } } })
  const login = new URL((await f.plugin.connect('default')).url)
  assert.equal(login.searchParams.get('client_id'), 'google-test')
  assert.equal(login.searchParams.get('scope'), definition.oauth!.scope)
  assert.equal(login.searchParams.get('access_type'), 'offline')
  assert.equal(login.searchParams.get('prompt'), 'consent')
  assert.equal(login.searchParams.get('code_challenge_method'), 'S256')
  assert.equal(f.clients.length, 0, 'Google must not use dynamic client registration')
  await f.plugin.finish('default', f.callbackFor(login.href).href)
  await f.plugin.enable('default', f.bot.id, true)
  assert.equal(f.store.pluginEnabled('gmail', f.bot.id), true)
  assert.equal(f.store.pluginEnabled('robinhood', f.bot.id), false)
  assert.equal((await f.plugin.context(f.bot.id)!.run('gmail_list_tools', {})).ok, true)
  f.expire()
  assert.equal((await f.plugin.context(f.bot.id)!.run('gmail_list_tools', {})).ok, true)
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
  assert.equal(ctx.external!.specs.length, 4, 'two tools per service, not full remote schemas')
  assert.deepEqual(ctx.pluginIds, ['robinhood', 'gmail'])
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
  await f.plugin.finish('default', (await f.begin()).href)
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
