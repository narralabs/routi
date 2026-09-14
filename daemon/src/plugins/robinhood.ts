import { createHash, randomBytes } from 'node:crypto'
import { createServer, type Server } from 'node:http'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { auth, type OAuthClientProvider } from '@modelcontextprotocol/sdk/client/auth.js'
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
type Pending = { provider: OAuthClientProvider; state: string; server: Server; timer: NodeJS.Timeout; redirectUrl: string }

/** One Robinhood account connection per Routi profile; access is granted per bot. */
export class Robinhood {
  private readonly pending = new Map<string, Pending>()
  private readonly errors = new Map<string, string>()
  private readonly queues = new Map<string, Promise<unknown>>()
  private readonly namespace: string

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

  async connect(profileId: string): Promise<{ url: string }> {
    return this.serial(profileId, async () => {
      this.checkProfile(profileId)
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
      this.pending.set(profileId, { provider, state, server, timer, redirectUrl })
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
        await auth(pending.provider, { serverUrl: this.serverUrl, authorizationCode: code, fetchFn: networkFetch })
        this.errors.delete(profileId)
      } catch {
        this.errors.set(profileId, 'Robinhood login failed. Connect again.')
        throw new Error('Robinhood login failed. Connect again.')
      }
    })
  }

  private cancel(profileId: string): void {
    const pending = this.pending.get(profileId)
    if (pending) { clearTimeout(pending.timer); pending.server.close(); this.pending.delete(profileId) }
  }

  private revoke(profileId: string): void {
    for (const bot of this.store.listBots(true, profileId)) {
      if (!this.store.pluginEnabled('robinhood', bot.id)) continue
      this.store.setPluginEnabled('robinhood', bot.id, false)
      this.changed(bot.id)
    }
  }

  async disconnect(profileId: string): Promise<void> {
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

  context(botId: string, signal?: AbortSignal): ToolContext['external'] {
    if (!this.store.getBot(botId) || !this.store.pluginEnabled('robinhood', botId)) return undefined
    return {
      specs: [
        { name: 'robinhood_list_tools', description: 'Discover Robinhood account, market data, and trading tools and their argument schemas. Call before using robinhood_call_tool.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
        { name: 'robinhood_call_tool', description: 'Call a Robinhood tool using the exact name and arguments returned by robinhood_list_tools. Only trade when the user has authorized it. If a call fails or times out, its outcome may be unknown: check order status before attempting another order.', parameters: { type: 'object', properties: { name: { type: 'string' }, arguments: { type: 'object', additionalProperties: true } }, required: ['name', 'arguments'], additionalProperties: false } },
      ],
      run: async (name, args) => {
        const bot = this.store.getBot(botId)
        if (!bot) return { ok: false, output: 'This bot was deleted.', summary: 'Robinhood unavailable' }
        return this.serial(bot.profileId, async () => {
          if (!this.store.getBot(botId) || !this.store.pluginEnabled('robinhood', botId)) return { ok: false, output: 'Robinhood access is disabled for this bot.', summary: 'Robinhood disconnected' }
          if (signal?.aborted) return { ok: false, output: 'Request cancelled before execution.', summary: 'Robinhood cancelled' }
          const client = new Client({ name: 'Routi Bot', version: '1.0.0' })
          try {
            const saved = await this.load(bot.profileId)
            if (!saved?.tokens) throw new Error('Not connected')
            const transport = new StreamableHTTPClientTransport(new URL(this.serverUrl), { authProvider: this.provider(bot.profileId, saved), fetch: (url, init) => networkFetch(url, { ...init,
              signal: AbortSignal.any([...(signal ? [signal] : []), ...(init?.signal ? [init.signal] : [])]),
            }) })
            await client.connect(transport)
            if (name === 'robinhood_list_tools') {
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
              return { ok: true, output: JSON.stringify(tools), summary: `${tools.length} Robinhood tools` }
            }
            if (name !== 'robinhood_call_tool' || typeof args['name'] !== 'string' || !args['arguments'] || typeof args['arguments'] !== 'object' || Array.isArray(args['arguments'])) throw new Error('Invalid tool arguments')
            signal?.throwIfAborted()
            // Recheck after network setup: access may have been revoked meanwhile.
            if (!this.store.pluginEnabled('robinhood', botId)) throw new Error('Access revoked')
            const result = await client.callTool({ name: args['name'], arguments: args['arguments'] as Record<string, unknown> }, CallToolResultSchema, { timeout: 30_000, signal })
            return { ok: !result.isError, output: JSON.stringify(result), summary: `Robinhood: ${args['name']}` }
          } catch {
            return { ok: false, output: 'Robinhood request failed. Check the connection in Plugins. If an order was submitted, its outcome is unknown: check order status before attempting another order. This request was not automatically replayed by Routi.', summary: 'Robinhood request failed' }
          } finally { await client.close().catch(() => {}) }
        })
      },
    }
  }

  close(): void { for (const id of this.pending.keys()) this.cancel(id) }
}
