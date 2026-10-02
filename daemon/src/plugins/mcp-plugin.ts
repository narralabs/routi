import { hasScope, type PermissionGroup, type PermissionRule } from './google-permissions.js'
import { mcpFailure } from './mcp-error.js'
import { createHash, randomBytes, randomUUID } from 'node:crypto'
import { createServer, type Server } from 'node:http'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { auth, UnauthorizedError, type OAuthClientProvider } from '@modelcontextprotocol/sdk/client/auth.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import type { OAuthClientInformationMixed, OAuthTokens } from '@modelcontextprotocol/sdk/shared/auth.js'
import { CallToolResultSchema, type Tool, type CallToolResult } from '@modelcontextprotocol/sdk/types.js'
import type { Store } from '../db/store.js'
import type { Credentials } from '../auth/credentials.js'
import type { ToolContext } from '../surfaces/tools.js'

interface ActionPreview {
  details: Record<string, unknown>
  beforeRun: (accessToken: string, signal?: AbortSignal) => Promise<void>
}

export interface McpPluginDefinition {
  id: string
  name: string
  url: string
  /** Existing credential slot, when a plugin predates the shared MCP service. */
  credentialProvider?: string
  callInstructions?: string
  localTools?: { preview?: (args: Record<string, unknown>, accessToken: string, signal?: AbortSignal) => Promise<ActionPreview>; spec: Tool; requiredScopes?: string[]; run: (args: Record<string, unknown>, accessToken: string, signal?: AbortSignal) => Promise<CallToolResult> }[]
  accountEmail?: (accessToken: string) => Promise<string | null>
  permissions?: PermissionGroup[]
  failedCallInstructions?: string
  oauth?: {
    client?: OAuthClientInformationMixed
    scope: string
    readOnlyScope?: string
    authorizationParams?: Record<string, string>
    setupMessage: string
  }
}
export const MAX_PLUGIN_OUTPUT_BYTES = 24_000
const LOGIN_TIMEOUT = 10 * 60_000
const networkFetch: typeof fetch = (url, init) => fetch(url, {
  ...init, signal: AbortSignal.any([AbortSignal.timeout(30_000), ...(init?.signal ? [init.signal] : [])]),
})

type SavedLogin = { redirectUrl: string; client?: OAuthClientInformationMixed; tokens?: OAuthTokens; expiresAt?: number; accountEmail?: string | null }
type Secrets = Pick<Credentials, 'getApiKey' | 'setApiKey' | 'clearApiKey'>
type Pending = { provider: OAuthClientProvider; state: string; server: Server; timer: NodeJS.Timeout; redirectUrl: string; accessId?: string }

export interface PluginAccessRequest {
  pluginId: string; id: string; botId: string; conversationId: string; profileId: string
  connected: boolean; connecting: boolean; expiresAt: number
  action?: { tool: string; arguments: string; preview?: string }
}

/** One remote MCP connection per plugin and profile, with explicit per-bot access. */
export class McpPlugin {
  private readonly pending = new Map<string, Pending>()
  private readonly errors = new Map<string, string>()
  private readonly queues = new Map<string, Promise<unknown>>()
  private readonly namespace: string
  private readonly decisions = new Map<string, (allow: boolean) => void>()
  private readonly access = new Map<string, PluginAccessRequest>()
  onAccessChanged: (profileId: string) => void = () => {}
  onAccessGranted: (request: PluginAccessRequest) => void = () => {}
  get name(): string { return this.definition.name }

  constructor(
    private readonly definition: McpPluginDefinition,
    private readonly store: Store,
    private readonly secrets: Secrets,
    dataDir: string,
    private readonly changed: (botId: string) => void,
  ) {
    if (!/^[a-z][a-z0-9_]*$/.test(definition.id)) throw new Error('Invalid MCP plugin ID')
    this.namespace = createHash('sha256').update(dataDir).digest('hex').slice(0, 16)
  }

  private slot(profileId: string): string { return `${this.namespace}.${profileId}` }
  private checkProfile(profileId: string): void {
    if (!this.store.getProfile(profileId)) throw new Error('This profile no longer exists.')
  }
  private async load(profileId: string): Promise<SavedLogin | undefined> {
    const raw = await this.secrets.getApiKey(this.definition.credentialProvider ?? `mcp:${this.definition.id}`, this.slot(profileId))
    return raw ? JSON.parse(raw) as SavedLogin : undefined
  }
  private async freshLogin(profileId: string): Promise<SavedLogin> {
    const saved = await this.load(profileId)
    if (!saved?.tokens) throw new UnauthorizedError('Not connected')
    // MCP initialization may accept expired tokens; refresh before REST calls too.
    if (saved.tokens.expires_in !== undefined && (saved.expiresAt ?? 0) <= Date.now() + 60_000) {
      await auth(this.provider(profileId, saved), { serverUrl: this.definition.url, fetchFn: networkFetch })
    }
    return saved
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
    const saved = await this.load(profileId)
    return {
      permissions: this.definition.permissions?.map(group => ({
        id: group.id, label: group.label, rule: this.rule(profileId, group.id),
        available: hasScope(group, saved?.tokens?.scope?.split(/\s+/) ?? []),
      })),
      connected: !!saved?.tokens,
      grantedScopes: saved?.tokens?.scope?.split(/\s+/).filter(Boolean) ?? null,
      supportsReadOnly: !!this.definition.oauth?.readOnlyScope,
      accountEmail: saved?.tokens ? saved.accountEmail ?? null : null,
      connecting: this.pending.has(profileId),
      error: this.errors.get(profileId) ?? null,
      botIds: this.store.listBots(true, profileId).filter(b => this.store.pluginEnabled(this.definition.id, b.id)).map(b => b.id),
    }
  }

  private rule(profileId: string, id: string): PermissionRule {
    return (this.store.getSettings()[`plugin-permission:${profileId}:${this.definition.id}:${id}`] as PermissionRule | undefined) ?? (id === 'read' ? 'allow' : 'ask')
  }

  setPermission(profileId: string, id: string, rule: PermissionRule): void {
    this.checkProfile(profileId)
    if (!this.definition.permissions?.some(group => group.id === id) || !['allow', 'ask', 'deny'].includes(rule)) throw new Error('Unknown plugin permission.')
    this.store.setSettings({ [`plugin-permission:${profileId}:${this.definition.id}:${id}`]: rule })
    this.onAccessChanged(profileId)
    for (const request of this.accessList(profileId)) if (request.action) this.decisions.get(request.id)?.(false)
  }

  private ask(botId: string, conversationId: string | undefined, tool: string, args: Record<string, unknown>, signal?: AbortSignal, preview?: ActionPreview): Promise<boolean> {
    const bot = this.store.getBot(botId)
    const conversation = conversationId ? this.store.getConversation(conversationId) : undefined
    if (!bot || !conversation || (conversation.botId !== botId && !this.store.channelMembers(conversation.id).some(b => b.id === botId)) || signal?.aborted) return Promise.resolve(false)
    return new Promise(resolve => {
      const request: PluginAccessRequest = {
        id: randomUUID(), pluginId: this.definition.id, profileId: bot.profileId, botId, conversationId: conversation.id,
        connected: true, connecting: false, expiresAt: Date.now() + LOGIN_TIMEOUT,
        action: { tool, arguments: JSON.stringify(args, null, 2), ...(preview ? { preview: JSON.stringify(preview.details) } : {}) },
      }
      const finish = (allow: boolean) => {
        clearTimeout(timer)
        signal?.removeEventListener('abort', cancel)
        this.decisions.delete(request.id)
        this.access.delete(request.id)
        this.onAccessChanged(bot.profileId)
        resolve(allow)
      }
      const cancel = () => finish(false)
      const timer = setTimeout(cancel, LOGIN_TIMEOUT)
      signal?.addEventListener('abort', cancel, { once: true })
      this.access.set(request.id, request)
      this.decisions.set(request.id, finish)
      this.onAccessChanged(bot.profileId)
    })
  }

  private provider(profileId: string, saved: SavedLogin, interactive?: { state: string; redirect: (url: URL) => void; scope?: string }): OAuthClientProvider {
    let verifier: string | undefined
    const persist = async () => {
      this.checkProfile(profileId)
      await this.secrets.setApiKey(JSON.stringify(saved), this.definition.credentialProvider ?? `mcp:${this.definition.id}`, this.slot(profileId))
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
      clientInformation: () => this.definition.oauth?.client ?? saved.client,
      saveClientInformation: info => { saved.client = info },
      tokens: () => saved.tokens,
      saveTokens: async tokens => {
        saved.expiresAt = tokens.expires_in === undefined ? undefined : Date.now() + tokens.expires_in * 1000
        saved.tokens = { ...tokens, scope: tokens.scope ?? (!interactive ? saved.tokens?.scope : undefined) }
        if (this.definition.accountEmail) {
          saved.accountEmail = await this.definition.accountEmail(tokens.access_token).catch(() => null) ?? saved.accountEmail ?? null
        }
        await persist()
      },
      saveCodeVerifier: code => { verifier = code },
      codeVerifier: () => { if (!verifier) throw new Error('Login expired. Connect again.'); return verifier },
      redirectToAuthorization: url => {
        if (!interactive) throw new UnauthorizedError(`Reconnect ${this.definition.name} in Plugins.`)
        if (this.definition.oauth) url.searchParams.set('scope', interactive.scope ?? this.definition.oauth.scope)
        for (const [key, value] of Object.entries(this.definition.oauth?.authorizationParams ?? {})) url.searchParams.set(key, value)
        interactive.redirect(url)
      },
      invalidateCredentials: async scope => {
        if (scope === 'tokens' || scope === 'all') { delete saved.tokens; delete saved.accountEmail; await persist() }
        if (scope === 'client' || scope === 'all') delete saved.client
        if (scope === 'verifier' || scope === 'all') verifier = undefined
      },
    }
  }

  async connect(profileId: string, accessId?: string, readOnly = false): Promise<{ url: string }> {
    return this.serial(profileId, async () => {
      this.checkProfile(profileId)
      if (this.definition.oauth && !this.definition.oauth.client) throw new Error(this.definition.oauth.setupMessage)
      if (accessId) this.findAccess(accessId, profileId)
      if (accessId && this.pending.has(profileId)) throw new Error(`${this.definition.name} sign-in is already in progress. Finish it, then allow this bot.`)
      if (readOnly && !this.definition.oauth?.readOnlyScope) throw new Error('Read-only access is not supported by this plugin.')
      const scope = readOnly ? this.definition.oauth!.readOnlyScope : this.definition.oauth?.scope
      this.cancel(profileId)
      this.errors.delete(profileId)
      const state = randomBytes(32).toString('hex')
      const server = createServer((req, res) => {
        const callback = new URL(req.url ?? '/', 'http://127.0.0.1')
        if (req.method !== 'GET' || callback.pathname !== '/callback') { res.writeHead(404).end(); return }
        const pending = this.pending.get(profileId)
        if (!pending) { res.writeHead(400).end('Login expired. Connect again in Routi.'); return }
        void this.finish(profileId, new URL(req.url!, pending.redirectUrl).href).then(() => {
          res.writeHead(200, { 'content-type': 'text/plain', 'cache-control': 'no-store' }).end(`${this.definition.name} connected. Return to Routi Bot.`)
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
      const provider = this.provider(profileId, { redirectUrl }, { state, scope, redirect: value => { url = value.href } })
      const timer = setTimeout(() => {
        this.errors.set(profileId, 'Login expired. Connect again.')
        this.cancel(profileId)
      }, LOGIN_TIMEOUT)
      timer.unref()
      this.pending.set(profileId, { provider, state, server, timer, redirectUrl, accessId })
      try {
        await auth(provider, { serverUrl: this.definition.url, scope, fetchFn: networkFetch })
        if (!url) throw new Error(`${this.definition.name} did not provide a login URL.`)
        this.onAccessChanged(profileId)
        return { url }
      } catch {
        this.cancel(profileId)
        throw new Error(`Could not start ${this.definition.name} login. Check the connection and try again.`)
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
        const outcome = await auth(pending.provider, { serverUrl: this.definition.url, authorizationCode: code, fetchFn: networkFetch })
        if (outcome !== 'AUTHORIZED') throw new Error('Authorization did not complete.')
        this.errors.delete(profileId)
        if (pending.accessId) {
          const request = this.findAccess(pending.accessId, profileId)
          this.grantAccess(request)
        }
      } catch {
        const request = pending.accessId ? this.access.get(pending.accessId) : undefined
        if (request) request.connecting = false
        this.errors.set(profileId, `${this.definition.name} login failed. Connect again.`)
        throw new Error(`${this.definition.name} login failed. Connect again.`)
      } finally { this.onAccessChanged(profileId) }
    })
  }

  private cancel(profileId: string): void {
    const pending = this.pending.get(profileId)
    if (pending) {
      clearTimeout(pending.timer); pending.server.close(); this.pending.delete(profileId)
      const request = pending.accessId ? this.access.get(pending.accessId) : undefined
      if (request) request.connecting = false
      this.onAccessChanged(profileId)
    }
  }

  private revoke(profileId: string): void {
    for (const request of this.accessList(profileId)) if (request.action) this.decisions.get(request.id)?.(false)
    for (const bot of this.store.listBots(true, profileId)) {
      if (!this.store.pluginEnabled(this.definition.id, bot.id)) continue
      this.store.setPluginEnabled(this.definition.id, bot.id, false)
      this.changed(bot.id)
    }
  }

  async disconnect(profileId: string): Promise<void> {
    for (const request of this.accessList(profileId)) { this.decisions.get(request.id)?.(false); this.access.delete(request.id) }
    this.onAccessChanged(profileId)
    // Revoke immediately, then again under the lock to cover already queued changes.
    this.cancel(profileId)
    this.revoke(profileId)
    await this.serial(profileId, async () => {
      this.cancel(profileId)
      this.revoke(profileId)
      await this.secrets.clearApiKey(this.definition.credentialProvider ?? `mcp:${this.definition.id}`, this.slot(profileId))
      this.errors.delete(profileId)
      this.onAccessChanged(profileId)
    })
  }

  async enable(profileId: string, botId: string, enabled: boolean): Promise<void> {
    return this.serial(profileId, async () => {
      this.checkProfile(profileId)
      const bot = this.store.getBot(botId)
      if (!bot || bot.profileId !== profileId) throw new Error('This bot does not belong to this profile.')
      if (enabled && !(await this.load(profileId))?.tokens) throw new Error(`Connect ${this.definition.name} first.`)
      this.store.setPluginEnabled(this.definition.id, botId, enabled)
      if (!enabled) for (const request of this.accessList(profileId)) if (request.botId === botId && request.action) this.decisions.get(request.id)?.(false)
      this.changed(botId)
      this.onAccessChanged(profileId)
    })
  }

  context(botId: string, signal?: AbortSignal, includeLocked = false, conversationId?: string): ToolContext['external'] {
    if (!this.store.getBot(botId) || (!includeLocked && !this.store.pluginEnabled(this.definition.id, botId))) return undefined
    return {
      specs: [
        ...(this.definition.localTools ?? []).map(({ spec }) => ({ name: spec.name, description: spec.description ?? '', parameters: spec.inputSchema })),
        { name: `${this.definition.id}_list_tools`, description: `Discover ${this.definition.name} tools.${this.definition.localTools?.length ? ` Routi also provides: ${this.definition.localTools.map(tool => tool.spec.name).join(', ')}.` : ''} Refresh this list before claiming an action is unavailable; tools can change. With no name, returns a compact index of exact tool names. Then pass one exact name to get its argument schema before calling ${this.definition.id}_call_tool. Do not guess tool names or arguments.`, parameters: { type: 'object', properties: { name: { type: 'string', description: 'Exact tool name from the index; omit to list names.' } }, additionalProperties: false } },
        { name: `${this.definition.id}_call_tool`, description: `Call a ${this.definition.name} tool using the exact name and arguments returned by ${this.definition.id}_list_tools. ${this.definition.callInstructions ?? "Only perform actions the user has authorized. If a call fails, check its outcome before repeating it."}`, parameters: { type: 'object', properties: { name: { type: 'string' }, arguments: { type: 'object', additionalProperties: true } }, required: ['name', 'arguments'], additionalProperties: false } },
      ],
      run: async (name, args) => {
        if (this.definition.localTools?.some(tool => tool.spec.name === name)) {
          args = { name, arguments: args }
          name = `${this.definition.id}_call_tool`
        }
        const bot = this.store.getBot(botId)
        if (!bot) return { ok: false, output: 'This bot was deleted.', summary: `${this.definition.name} unavailable` }
        // Freeze exactly what is approved; never hold the credential lock while waiting for a person.
        args = structuredClone(args)
        const group = name === `${this.definition.id}_call_tool` ? this.definition.permissions?.find(group => group.tools.includes(String(args['name']))) : undefined
        let approved = false
        let preview: ActionPreview | undefined
        if (name === `${this.definition.id}_call_tool` && (!args['arguments'] || typeof args['arguments'] !== 'object' || Array.isArray(args['arguments']) || typeof args['name'] !== 'string')) return { ok: false, output: 'Provide a tool name and arguments object.', summary: 'Invalid arguments' }
        if (name === `${this.definition.id}_call_tool` && this.definition.permissions) {
          if (!this.store.pluginEnabled(this.definition.id, botId)) return { ok: false, output: 'Plugin access is disabled for this bot.', summary: 'Access disabled' }
          if (!group) return { ok: false, output: 'This tool has not been classified for Routi permissions and cannot run.', summary: 'Unsupported tool' }
          const saved = await this.load(bot.profileId)
          if (!hasScope(group, saved?.tokens?.scope?.split(/\s+/) ?? [])) return { ok: false, output: 'This Google connection does not allow this action. Grant additional access in Plugins first.', summary: 'Google access required' }
          const rule = this.rule(bot.profileId, group.id)
          if (rule === 'deny') return { ok: false, output: 'This action is denied by Bot permissions in Plugins.', summary: 'Action denied' }
          if (rule === 'ask') {
            const prepare = this.definition.localTools?.find(tool => tool.spec.name === args['name'])?.preview
            if (prepare) {
              try {
                preview = await this.serial(bot.profileId, async () => {
                  const login = await this.freshLogin(bot.profileId)
                  const client = new Client({ name: 'Routi Bot', version: '1.0.0' })
                  try {
                    await client.connect(new StreamableHTTPClientTransport(new URL(this.definition.url), { authProvider: this.provider(bot.profileId, login), fetch: networkFetch }))
                    return await prepare(args['arguments'] as Record<string, unknown>, login.tokens!.access_token, signal)
                  } finally { await client.close().catch(() => {}) }
                })
              } catch {
                return { ok: false, output: 'Could not load the email for review. No email was sent. Check the connection and request approval again.', summary: 'Email preview unavailable' }
              }
            }
            const decision = await this.ask(botId, conversationId, String(args['name']), args['arguments'] as Record<string, unknown>, signal, preview)
            if (!decision) return { ok: false, output: 'This action was not approved. No tool was executed. Stop and wait for the user; do not retry, substitute another action, or clean up drafts.', summary: 'Not approved' }
            approved = true
          }
        }
        const result = await this.serial(bot.profileId, async () => {
          if (this.store.getBot(botId)?.profileId !== bot.profileId || !this.store.pluginEnabled(this.definition.id, botId)) return { ok: false, output: `${this.definition.name} access is disabled for this bot. Use request_plugin_access with plugin=${this.definition.id} to show an approval card.`, summary: `${this.definition.name} disconnected` }
          if (signal?.aborted) return { ok: false, output: 'Request cancelled before execution.', summary: `${this.definition.name} cancelled` }
          const client = new Client({ name: 'Routi Bot', version: '1.0.0' })
          let stage: 'connect' | 'discover' | 'call' = 'connect'
          try {
            const saved = await this.freshLogin(bot.profileId)
            const transport = new StreamableHTTPClientTransport(new URL(this.definition.url), { authProvider: this.provider(bot.profileId, saved), fetch: (url, init) => networkFetch(url, { ...init,
              signal: AbortSignal.any([...(signal ? [signal] : []), ...(init?.signal ? [init.signal] : [])]),
            }) })
            await client.connect(transport)
            const granted = saved.tokens?.scope?.split(/\s+/)
            if (group && (!hasScope(group, granted ?? []) || this.rule(bot.profileId, group.id) === 'deny' || (this.rule(bot.profileId, group.id) === 'ask' && !approved))) {
              return { ok: false, output: 'Access changed before execution. No tool was executed.', summary: 'Permission changed' }
            }
            const localTools = (this.definition.localTools ?? []).filter(tool => !granted || !tool.requiredScopes || tool.requiredScopes.some(scope => granted.includes(scope)))
            if (name === `${this.definition.id}_list_tools`) {
              stage = 'discover'
              let tools: Tool[] = localTools.map(tool => tool.spec)
              let cursor: string | undefined
              let pages = 0
              do {
                if (++pages > 32) throw new Error('Too many tool pages')
                const page = await client.listTools({ cursor })
                tools.push(...page.tools)
                cursor = page.nextCursor
                if (tools.length > 1000) throw new Error('Too many tools')
              } while (cursor)
              tools = tools.filter(tool => !this.definition.permissions || this.definition.permissions.some(group =>
                group.tools.includes(tool.name) && hasScope(group, granted ?? []) && this.rule(bot.profileId, group.id) !== 'deny'))
              const requested = args['name']
              if (typeof requested === 'string' && requested) {
                const tool = tools.find(tool => tool.name === requested)
                if (!tool) return { ok: false, output: `No ${this.definition.name} tool has that exact name. Call ${this.definition.id}_list_tools without a name for the index.`, summary: `Unknown ${this.definition.name} tool` }
                return { ok: true, output: JSON.stringify(tool), summary: `${this.definition.name} schema: ${tool.name}` }
              }
              return { ok: true, output: JSON.stringify({
                instructions: `Pass an exact name to ${this.definition.id}_list_tools to get its argument schema, then use ${this.definition.id}_call_tool. Do not guess names or arguments.`,
                tools: tools.map(tool => ({ name: tool.name, description: (tool.description ?? '').slice(0, 80) })),
              }), summary: `${tools.length} ${this.definition.name} tools` }
            }
            if (name !== `${this.definition.id}_call_tool` || typeof args['name'] !== 'string' || !args['arguments'] || typeof args['arguments'] !== 'object' || Array.isArray(args['arguments'])) throw new Error('Invalid tool arguments')
            signal?.throwIfAborted()
            // Recheck after network setup: access may have been revoked meanwhile.
            if (!this.store.pluginEnabled(this.definition.id, botId)) throw new Error('Access revoked')
            try { await preview?.beforeRun(saved.tokens!.access_token, signal) }
            catch { return { ok: false, output: 'The draft changed or could not be checked. No email was sent. Request a fresh preview and approval.', summary: 'Review the draft again' } }
            stage = 'call'
            const local = this.definition.localTools?.find(tool => tool.spec.name === args['name'])
            if (local && !localTools.includes(local)) return { ok: false, output: 'This connection does not allow this action. Change permissions in Plugins to enable it.', summary: 'Permission required' }
            const result = local
              ? await local.run(args['arguments'] as Record<string, unknown>, saved.tokens!.access_token, signal)
              : await client.callTool({ name: args['name'], arguments: args['arguments'] as Record<string, unknown> }, CallToolResultSchema, { timeout: 30_000, signal })
            return { ok: !result.isError, output: JSON.stringify(result), summary: `${this.definition.name}: ${args['name']}` }
          } catch (error) {
            const failure = mcpFailure(this.definition, error, signal?.aborted)
            if (failure.kind === 'authentication') {
              await this.secrets.clearApiKey(this.definition.credentialProvider ?? `mcp:${this.definition.id}`, this.slot(bot.profileId))
              this.revoke(bot.profileId)
              this.errors.set(bot.profileId, failure.message)
              this.onAccessChanged(bot.profileId)
            }
            console.warn(`${this.definition.name} request failed`, { botId, stage, kind: failure.kind })
            const outcome = stage === 'call'
              ? (this.definition.failedCallInstructions ?? 'The action outcome may be unknown. Check its status before repeating it. Routi did not automatically replay the tool call.')
              : 'No remote tool was submitted.'
            return { ok: false, output: `${failure.message} Failure stage: ${stage}. ${outcome}`, summary: `${this.definition.name}: ${failure.kind}` }
          } finally { await client.close().catch(() => {}) }
        })
        // Bound model context, including schema and error responses. Never truncate JSON.
        if (Buffer.byteLength(result.output, 'utf8') > MAX_PLUGIN_OUTPUT_BYTES) return {
          ok: false, summary: `${this.definition.name}: response too large`,
          output: `The plugin response exceeded ${MAX_PLUGIN_OUTPUT_BYTES} bytes and was withheld. Request a specific tool schema or a smaller, paginated read. If this was an action, it may already have completed: check its status rather than repeating it to recover the response. Routi did not automatically replay the call.`,
        }
        return result
      },
    }
  }

  async requestAccess(botId: string, conversationId: string) {
    const bot = this.store.getBot(botId)
    const conversation = this.store.getConversation(conversationId)
    if (!bot || !conversation || (conversation.botId !== botId && !this.store.channelMembers(conversationId).some(b => b.id === botId))) {
      return { ok: false, output: 'This bot is not part of this conversation.', summary: 'Access unavailable' }
    }
    if (this.store.pluginEnabled(this.definition.id, botId) && (await this.load(bot.profileId))?.tokens) {
      return { ok: true, output: `${this.definition.name} access is already enabled. Use ${this.definition.id}_list_tools to discover the tools.`, summary: `${this.definition.name} enabled` }
    }
    const existing = this.accessList(bot.profileId).find(r => !r.action && r.botId === botId && r.conversationId === conversationId)
    if (!existing) {
      const request: PluginAccessRequest = {
        pluginId: this.definition.id, id: randomUUID(), botId, conversationId, profileId: bot.profileId,
        connected: !!(await this.load(bot.profileId))?.tokens, connecting: false, expiresAt: Date.now() + LOGIN_TIMEOUT,
      }
      this.access.set(request.id, request)
      this.onAccessChanged(bot.profileId)
    }
    return { ok: true, output: `An access card is shown in this conversation. Stop here and wait for the person to allow access or sign in. Routi will send their approval into this chat so you can continue. Do not request passwords or use ${this.definition.name} tools before approval.`, summary: `Waiting for ${this.definition.name} access` }
  }

  accessList(profileId: string): PluginAccessRequest[] {
    for (const [id, request] of this.access) {
      if (request.expiresAt <= Date.now() || !this.store.getBot(request.botId) || !this.store.getConversation(request.conversationId)) { this.decisions.get(id)?.(false); this.access.delete(id) }
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
    this.store.setPluginEnabled(this.definition.id, current.botId, true)
    this.access.delete(current.id)
    this.onAccessChanged(current.profileId)
    // Chat providers already have the guarded tools, so do not interrupt a warm turn.
    this.onAccessGranted({ ...current })
  }

  async respondAccess(profileId: string, id: string, allow: boolean, editedArguments?: Record<string, unknown>): Promise<{ url?: string }> {
    this.checkProfile(profileId)
    const request = this.findAccess(id, profileId)
    if (request.action) {
      if (editedArguments !== undefined) throw new Error('Approval details cannot be changed. Request a new review.')
      this.decisions.get(id)?.(allow)
      return {}
    }
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
          if (!(await this.load(profileId))?.tokens) throw new Error(`${this.definition.name} was disconnected. Try again.`)
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

  close(): void { for (const decide of [...this.decisions.values()]) decide(false); for (const id of this.pending.keys()) this.cancel(id) }
}
