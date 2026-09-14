import { robinhoodFailure } from './robinhood-error.js'
import { createHash, randomBytes, randomUUID } from 'node:crypto'
import { createServer, type Server } from 'node:http'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { auth, UnauthorizedError, type OAuthClientProvider } from '@modelcontextprotocol/sdk/client/auth.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import type { OAuthClientInformationMixed, OAuthTokens } from '@modelcontextprotocol/sdk/shared/auth.js'
import { CallToolResultSchema } from '@modelcontextprotocol/sdk/types.js'
import type { Store } from '../db/store.js'
import type { Credentials } from '../auth/credentials.js'
import type { ToolContext } from '../surfaces/tools.js'

export const ROBINHOOD_URL = 'https://agent.robinhood.com/mcp/trading'
const LOGIN_TIMEOUT = 10 * 60_000
const networkFetch: typeof fetch = (url, init) => fetch(url, {
  ...init, signal: AbortSignal.any([AbortSignal.timeout(30_000), ...(init?.signal ? [init.signal] : [])]),
})

type SavedLogin = { redirectUrl: string; client?: OAuthClientInformationMixed; tokens?: OAuthTokens }
type Secrets = Pick<Credentials, 'getApiKey' | 'setApiKey' | 'clearApiKey'>
type Pending = { provider: OAuthClientProvider; state: string; server: Server; timer: NodeJS.Timeout; redirectUrl: string; accessId?: string }

export interface PluginAccessRequest {
  id: string; botId: string; conversationId: string; profileId: string
  connected: boolean; connecting: boolean; expiresAt: number
}

/** One Robinhood account connection per Routi profile; access is granted per bot. */
export class Robinhood {
  private readonly pending = new Map<string, Pending>()
  private readonly errors = new Map<string, string>()
  private readonly queues = new Map<string, Promise<unknown>>()
  private readonly namespace: string
  private readonly access = new Map<string, PluginAccessRequest>()
  onAccessChanged: (profileId: string) => void = () => {}
  onAccessGranted: (request: PluginAccessRequest) => void = () => {}

  constructor(
    private readonly store: Store,
    private readonly secrets: Secrets,
    dataDir: string,
    private readonly changed: (botId: string) => void,
    // Dependency injection keeps tests offline. Production always uses Robinhood's URL.
    private readonly serverUrl = ROBINHOOD_URL,
  ) {
    this.namespace = createHash('sha256').update(dataDir).digest('hex').slice(0, 16)
  }

  private slot(profileId: string): string { return `${this.namespace}.${profileId}` }
  private checkProfile(profileId: string): void {
    if (!this.store.getProfile(profileId)) throw new Error('This profile no longer exists.')
  }
  private async load(profileId: string): Promise<SavedLogin | undefined> {
    const raw = await this.secrets.getApiKey('robinhood', this.slot(profileId))
    return raw ? JSON.parse(raw) as SavedLogin : undefined
  }
  // Serialize refresh, disconnect, and tool calls so rotated refresh tokens cannot race.
  private async serial<T>(profileId: string, work: () => Promise<T>): Promise<T> {
    const previous = this.queues.get(profileId) ?? Promise.resolve()
    const next = previous.catch(() => {}).then(work)
    this.queues.set(profileId, next)
    try { return await next } finally { if (this.queues.get(profileId) === next) this.queues.delete(profileId) }
  }

  async status(profileId: string) {
    this.checkProfile(profileId)
    return {
      connected: !!(await this.load(profileId))?.tokens,
      connecting: this.pending.has(profileId),
      error: this.errors.get(profileId) ?? null,
      botIds: this.store.listBots(true, profileId).filter(b => this.store.pluginEnabled('robinhood', b.id)).map(b => b.id),
    }
  }

  private provider(profileId: string, saved: SavedLogin, interactive?: { state: string; redirect: (url: URL) => void }): OAuthClientProvider {
    let verifier: string | undefined
    const persist = async () => {
      this.checkProfile(profileId)
      await this.secrets.setApiKey(JSON.stringify(saved), 'robinhood', this.slot(profileId))
    }
    return {
      redirectUrl: saved.redirectUrl,
      clientMetadata: {
        client_name: 'Routi Bot',
        client_uri: 'https://github.com/narralabs/routi',
        redirect_uris: [saved.redirectUrl],
        grant_types: ['authorization_code', 'refresh_token'],
        response_types: ['code'],
        token_endpoint_auth_method: 'none',
      },
      state: () => interactive?.state ?? randomBytes(32).toString('hex'),
      clientInformation: () => saved.client,
      saveClientInformation: info => { saved.client = info },
      tokens: () => saved.tokens,
      saveTokens: async tokens => { saved.tokens = tokens; await persist() },
      saveCodeVerifier: code => { verifier = code },
      codeVerifier: () => { if (!verifier) throw new Error('Login expired. Connect again.'); return verifier },
      redirectToAuthorization: url => {
        if (!interactive) throw new Error('Reconnect Robinhood in Plugins.')
        interactive.redirect(url)
      },
      invalidateCredentials: async scope => {
        if (scope === 'tokens' || scope === 'all') { delete saved.tokens; await persist() }
        if (scope === 'client' || scope === 'all') delete saved.client
        if (scope === 'verifier' || scope === 'all') verifier = undefined
      },
    }
  }

  async connect(profileId: string, accessId?: string): Promise<{ url: string }> {
    return this.serial(profileId, async () => {
      this.checkProfile(profileId)
      if (accessId) this.findAccess(accessId, profileId)
      if (accessId && this.pending.has(profileId)) throw new Error('Robinhood sign-in is already in progress. Finish it, then allow this bot.')
      this.cancel(profileId)
      this.errors.delete(profileId)
      const state = randomBytes(32).toString('hex')
      const server = createServer((req, res) => {
        const callback = new URL(req.url ?? '/', 'http://127.0.0.1')
        if (req.method !== 'GET' || callback.pathname !== '/callback') { res.writeHead(404).end(); return }
        const pending = this.pending.get(profileId)
        if (!pending) { res.writeHead(400).end('Login expired. Connect again in Routi.'); return }
        void this.finish(profileId, new URL(req.url!, pending.redirectUrl).href).then(() => {
          res.writeHead(200, { 'content-type': 'text/plain', 'cache-control': 'no-store' }).end('Robinhood connected. Return to Routi Bot.')
        }).catch(() => {
          res.writeHead(400, { 'content-type': 'text/plain', 'cache-control': 'no-store' }).end('Login failed. Return to Routi Bot and connect again.')
        })
      })
      await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve) })
      if (accessId) {
        try { this.findAccess(accessId, profileId) } catch (error) { server.close(); throw error }
      }
      const address = server.address()
      if (!address || typeof address === 'string') { server.close(); throw new Error('Could not start login callback.') }
      const redirectUrl = `http://127.0.0.1:${address.port}/callback`
      let url = ''
      const provider = this.provider(profileId, { redirectUrl }, { state, redirect: value => { url = value.href } })
      const timer = setTimeout(() => {
        this.cancel(profileId)
        this.errors.set(profileId, 'Login expired. Connect again.')
      }, LOGIN_TIMEOUT)
      timer.unref()
      this.pending.set(profileId, { provider, state, server, timer, redirectUrl, accessId })
      try {
        await auth(provider, { serverUrl: this.serverUrl, fetchFn: networkFetch })
        if (!url) throw new Error('Robinhood did not provide a login URL.')
        return { url }
      } catch {
        this.cancel(profileId)
        throw new Error('Could not start Robinhood login. Check the connection and try again.')
      }
    })
  }

  async finish(profileId: string, callbackUrl: string): Promise<void> {
    return this.serial(profileId, async () => {
      this.checkProfile(profileId)
      const pending = this.pending.get(profileId)
      if (!pending) throw new Error('Login expired. Connect again.')
      const url = new URL(callbackUrl)
      const expected = new URL(pending.redirectUrl)
      if (url.origin !== expected.origin || url.pathname !== expected.pathname || url.searchParams.get('state') !== pending.state) {
        throw new Error('This callback does not match the pending login.')
      }
      // Consume the callback once; failed exchanges must start a new login.
      clearTimeout(pending.timer)
      this.pending.delete(profileId)
      pending.server.close()
      try {
        const code = url.searchParams.get('code')
        if (url.searchParams.has('error') || !code) throw new Error('Authorization declined.')
        this.revoke(profileId)
        const outcome = await auth(pending.provider, { serverUrl: this.serverUrl, authorizationCode: code, fetchFn: networkFetch })
        if (outcome !== 'AUTHORIZED') throw new Error('Authorization did not complete.')
        this.errors.delete(profileId)
        if (pending.accessId) {
          const request = this.findAccess(pending.accessId, profileId)
          this.grantAccess(request)
        }
      } catch {
        const request = pending.accessId ? this.access.get(pending.accessId) : undefined
        if (request) { request.connecting = false; this.onAccessChanged(profileId) }
        this.errors.set(profileId, 'Robinhood login failed. Connect again.')
        throw new Error('Robinhood login failed. Connect again.')
      }
    })
  }

  private cancel(profileId: string): void {
    const pending = this.pending.get(profileId)
    if (pending) {
      clearTimeout(pending.timer); pending.server.close(); this.pending.delete(profileId)
      const request = pending.accessId ? this.access.get(pending.accessId) : undefined
      if (request) { request.connecting = false; this.onAccessChanged(profileId) }
    }
  }

  private revoke(profileId: string): void {
    for (const bot of this.store.listBots(true, profileId)) {
      if (!this.store.pluginEnabled('robinhood', bot.id)) continue
      this.store.setPluginEnabled('robinhood', bot.id, false)
      this.changed(bot.id)
    }
  }

  async disconnect(profileId: string): Promise<void> {
    for (const request of this.accessList(profileId)) this.access.delete(request.id)
    this.onAccessChanged(profileId)
    // Revoke immediately, then again under the lock to cover already queued changes.
    this.cancel(profileId)
    this.revoke(profileId)
    await this.serial(profileId, async () => {
      this.cancel(profileId)
      this.revoke(profileId)
      await this.secrets.clearApiKey('robinhood', this.slot(profileId))
      this.errors.delete(profileId)
    })
  }

  async enable(profileId: string, botId: string, enabled: boolean): Promise<void> {
    return this.serial(profileId, async () => {
      this.checkProfile(profileId)
      const bot = this.store.getBot(botId)
      if (!bot || bot.profileId !== profileId) throw new Error('This bot does not belong to this profile.')
      if (enabled && !(await this.load(profileId))?.tokens) throw new Error('Connect Robinhood first.')
      this.store.setPluginEnabled('robinhood', botId, enabled)
      this.changed(botId)
    })
  }

  context(botId: string, signal?: AbortSignal, includeLocked = false): ToolContext['external'] {
    if (!this.store.getBot(botId) || (!includeLocked && !this.store.pluginEnabled('robinhood', botId))) return undefined
    return {
      specs: [
        { name: 'robinhood_list_tools', description: 'Discover Robinhood tools. With no name, returns a compact index of exact tool names. Then pass one exact name to get its argument schema before calling robinhood_call_tool. Do not guess tool names or arguments.', parameters: { type: 'object', properties: { name: { type: 'string', description: 'Exact tool name from the index; omit to list names.' } }, additionalProperties: false } },
        { name: 'robinhood_call_tool', description: 'Call a Robinhood tool using the exact name and arguments returned by robinhood_list_tools. Only trade when the user has authorized it. If a call fails or times out, its outcome may be unknown: check order status before attempting another order.', parameters: { type: 'object', properties: { name: { type: 'string' }, arguments: { type: 'object', additionalProperties: true } }, required: ['name', 'arguments'], additionalProperties: false } },
      ],
      run: async (name, args) => {
        const bot = this.store.getBot(botId)
        if (!bot) return { ok: false, output: 'This bot was deleted.', summary: 'Robinhood unavailable' }
        return this.serial(bot.profileId, async () => {
          if (!this.store.getBot(botId) || !this.store.pluginEnabled('robinhood', botId)) return { ok: false, output: 'Robinhood access is disabled for this bot. Use request_plugin_access with plugin=robinhood to show an approval card.', summary: 'Robinhood disconnected' }
          if (signal?.aborted) return { ok: false, output: 'Request cancelled before execution.', summary: 'Robinhood cancelled' }
          const client = new Client({ name: 'Routi Bot', version: '1.0.0' })
          let stage: 'connect' | 'discover' | 'call' = 'connect'
          try {
            const saved = await this.load(bot.profileId)
            if (!saved?.tokens) throw new UnauthorizedError('Not connected')
            const transport = new StreamableHTTPClientTransport(new URL(this.serverUrl), { authProvider: this.provider(bot.profileId, saved), fetch: (url, init) => networkFetch(url, { ...init,
              signal: AbortSignal.any([...(signal ? [signal] : []), ...(init?.signal ? [init.signal] : [])]),
            }) })
            await client.connect(transport)
            if (name === 'robinhood_list_tools') {
              stage = 'discover'
              const tools = []
              let cursor: string | undefined
              let pages = 0
              do {
                if (++pages > 32) throw new Error('Too many tool pages')
                const page = await client.listTools({ cursor })
                tools.push(...page.tools)
                cursor = page.nextCursor
                if (tools.length > 1000) throw new Error('Too many tools')
              } while (cursor)
              const requested = args['name']
              if (typeof requested === 'string' && requested) {
                const tool = tools.find(tool => tool.name === requested)
                if (!tool) return { ok: false, output: 'No Robinhood tool has that exact name. Call robinhood_list_tools without a name for the index.', summary: 'Unknown Robinhood tool' }
                return { ok: true, output: JSON.stringify(tool), summary: `Robinhood schema: ${tool.name}` }
              }
              return { ok: true, output: JSON.stringify({
                instructions: 'Pass an exact name to robinhood_list_tools to get its argument schema, then use robinhood_call_tool. Do not guess names or arguments.',
                tools: tools.map(tool => ({ name: tool.name, description: (tool.description ?? '').slice(0, 80) })),
              }), summary: `${tools.length} Robinhood tools` }
            }
            if (name !== 'robinhood_call_tool' || typeof args['name'] !== 'string' || !args['arguments'] || typeof args['arguments'] !== 'object' || Array.isArray(args['arguments'])) throw new Error('Invalid tool arguments')
            signal?.throwIfAborted()
            // Recheck after network setup: access may have been revoked meanwhile.
            if (!this.store.pluginEnabled('robinhood', botId)) throw new Error('Access revoked')
            stage = 'call'
            const result = await client.callTool({ name: args['name'], arguments: args['arguments'] as Record<string, unknown> }, CallToolResultSchema, { timeout: 30_000, signal })
            return { ok: !result.isError, output: JSON.stringify(result), summary: `Robinhood: ${args['name']}` }
          } catch (error) {
            const failure = robinhoodFailure(error, signal?.aborted)
            console.warn('Robinhood request failed', { botId, stage, kind: failure.kind })
            const outcome = stage === 'call'
              ? 'If an order was submitted, its outcome is unknown: check order status before attempting another order. Routi did not automatically replay the tool call.'
              : 'No account or trading tool was submitted.'
            return { ok: false, output: `${failure.message} Failure stage: ${stage}. ${outcome}`, summary: `Robinhood: ${failure.kind}` }
          } finally { await client.close().catch(() => {}) }
        })
      },
    }
  }

  async requestAccess(botId: string, conversationId: string) {
    const bot = this.store.getBot(botId)
    const conversation = this.store.getConversation(conversationId)
    if (!bot || !conversation || (conversation.botId !== botId && !this.store.channelMembers(conversationId).some(b => b.id === botId))) {
      return { ok: false, output: 'This bot is not part of this conversation.', summary: 'Access unavailable' }
    }
    if (this.store.pluginEnabled('robinhood', botId) && (await this.load(bot.profileId))?.tokens) {
      return { ok: true, output: 'Robinhood access is already enabled. Use robinhood_list_tools to discover the tools.', summary: 'Robinhood enabled' }
    }
    const existing = this.accessList(bot.profileId).find(r => r.botId === botId && r.conversationId === conversationId)
    if (!existing) {
      const request: PluginAccessRequest = {
        id: randomUUID(), botId, conversationId, profileId: bot.profileId,
        connected: !!(await this.load(bot.profileId))?.tokens, connecting: false, expiresAt: Date.now() + LOGIN_TIMEOUT,
      }
      this.access.set(request.id, request)
      this.onAccessChanged(bot.profileId)
    }
    return { ok: true, output: 'An access card is shown in this conversation. Stop here and wait for the person to allow access or sign in. Routi will send their approval into this chat so you can continue. Do not request passwords or use Robinhood tools before approval.', summary: 'Waiting for Robinhood access' }
  }

  accessList(profileId: string): PluginAccessRequest[] {
    for (const [id, request] of this.access) {
      if (request.expiresAt <= Date.now() || !this.store.getBot(request.botId) || !this.store.getConversation(request.conversationId)) this.access.delete(id)
    }
    return [...this.access.values()].filter(r => r.profileId === profileId).map(r => ({ ...r }))
  }

  private findAccess(id: string, profileId: string): PluginAccessRequest {
    this.accessList(profileId)
    const request = this.access.get(id)
    if (!request || request.profileId !== profileId) throw new Error('This access request expired. Ask the bot to request access again.')
    return request
  }

  private grantAccess(request: PluginAccessRequest): void {
    const current = this.findAccess(request.id, request.profileId)
    const bot = this.store.getBot(current.botId)
    if (!bot || bot.profileId !== current.profileId) throw new Error('The bot is no longer in this profile.')
    this.store.setPluginEnabled('robinhood', current.botId, true)
    this.access.delete(current.id)
    this.onAccessChanged(current.profileId)
    // Chat providers already have the guarded tools, so do not interrupt a warm turn.
    this.onAccessGranted({ ...current })
  }

  async respondAccess(profileId: string, id: string, allow: boolean): Promise<{ url?: string }> {
    this.checkProfile(profileId)
    const request = this.findAccess(id, profileId)
    if (!allow) {
      if (this.pending.get(profileId)?.accessId === id) this.cancel(profileId)
      this.access.delete(id)
      this.onAccessChanged(profileId)
      return {}
    }
    if (request.connecting) throw new Error('Sign-in is already in progress for this request.')
    request.connecting = true
    this.onAccessChanged(profileId)
    try {
      if ((await this.load(profileId))?.tokens) {
        await this.serial(profileId, async () => {
          if (!(await this.load(profileId))?.tokens) throw new Error('Robinhood was disconnected. Try again.')
          this.grantAccess(request)
        })
        return {}
      }
      return await this.connect(profileId, id)
    } catch (error) {
      if (this.access.has(id)) request.connecting = false
      this.onAccessChanged(profileId)
      throw error
    }
  }

  close(): void { for (const id of this.pending.keys()) this.cancel(id) }
}
