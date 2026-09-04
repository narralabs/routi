import { RpcMethods, type RpcMethod } from '@korg/protocol'
import type { Store } from '../db/store.js'
import type { ProviderAdapter } from '../providers/types.js'
import type { SessionManager } from '../sessions/manager.js'

export interface RpcContext {
  store: Store
  sessions: SessionManager
  providers: Map<string, ProviderAdapter>
}

export class RpcError extends Error {
  constructor(readonly code: string, message: string) {
    super(message)
  }
}

type Handler = (params: unknown, ctx: RpcContext) => Promise<unknown>

/**
 * Handlers receive params already validated against the protocol schema, so each one
 * can trust its input. Anything thrown as RpcError reaches the client as a typed
 * failure; anything else becomes an opaque `internal`.
 */
const handlers: Record<RpcMethod, Handler> = {
  'bots.list': async (p, ctx) => {
    const { includeArchived } = p as { includeArchived: boolean }
    return { bots: ctx.store.listBots(includeArchived) }
  },

  'bots.create': async (p, ctx) => {
    const params = p as { name: string; systemPrompt: string; model: string; avatarColor?: string; surfaceMode: 'none' | 'container' | 'host' }
    return ctx.store.createBot(params)
  },

  'bots.update': async (p, ctx) => {
    const { id, patch } = p as { id: string; patch: Record<string, unknown> }
    const bot = ctx.store.updateBot(id, patch)
    if (!bot) throw new RpcError('not_found', `No such bot: ${id}`)
    // The bot's model or prompt may have changed, so its warm session is now stale.
    ctx.providers.get(bot.provider)?.release(id)
    return { bot }
  },

  'bots.delete': async (p, ctx) => {
    const { id } = p as { id: string }
    if (!ctx.store.deleteBot(id)) throw new RpcError('not_found', `No such bot: ${id}`)
    return { ok: true as const }
  },

  'conversations.list': async (p, ctx) => {
    const { botId } = p as { botId?: string }
    return { conversations: ctx.store.listConversations(botId) }
  },

  'conversations.create': async (p, ctx) => {
    const { botId, title } = p as { botId: string; title?: string }
    if (!ctx.store.getBot(botId)) throw new RpcError('not_found', `No such bot: ${botId}`)
    return { conversation: ctx.store.createConversation(botId, title) }
  },

  'messages.list': async (p, ctx) => {
    const { conversationId, limit, before } = p as { conversationId: string; limit: number; before?: number }
    return { messages: ctx.store.listMessages(conversationId, limit, before) }
  },

  'messages.send': async (p, ctx) => {
    const { conversationId, blocks } = p as { conversationId: string; blocks: never[] }
    try {
      return { message: await ctx.sessions.send(conversationId, blocks) }
    } catch (err) {
      throw new RpcError('send_failed', err instanceof Error ? err.message : String(err))
    }
  },

  'messages.interrupt': async (p, ctx) => {
    const { conversationId } = p as { conversationId: string }
    ctx.sessions.interrupt(conversationId)
    return { ok: true as const }
  },

  'models.list': async (p, ctx) => {
    const { provider } = p as { provider: string }
    const adapter = ctx.providers.get(provider)
    if (!adapter) throw new RpcError('not_found', `No such provider: ${provider}`)
    return { models: await adapter.listModels() }
  },

  'account.info': async (_p, ctx) => {
    const adapter = ctx.providers.get('anthropic')
    if (!adapter) throw new RpcError('not_found', 'No anthropic provider configured')
    return { account: await adapter.accountInfo() }
  },

  'settings.get': async (_p, ctx) => ({ settings: ctx.store.getSettings() }),

  'settings.set': async (p, ctx) => {
    const { patch } = p as { patch: Record<string, unknown> }
    return { settings: ctx.store.setSettings(patch) }
  },
}

export async function dispatch(method: string, rawParams: unknown, ctx: RpcContext): Promise<unknown> {
  const spec = (RpcMethods as Record<string, { params: { safeParse: (v: unknown) => { success: boolean; data?: unknown; error?: unknown } } }>)[method]
  if (!spec) throw new RpcError('unknown_method', `Unknown method: ${method}`)

  const parsed = spec.params.safeParse(rawParams ?? {})
  if (!parsed.success) {
    throw new RpcError('invalid_params', `Invalid params for ${method}: ${JSON.stringify(parsed.error)}`)
  }
  return handlers[method as RpcMethod](parsed.data, ctx)
}
