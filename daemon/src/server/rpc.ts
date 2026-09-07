import { RpcMethods, type RpcMethod } from '@routi/protocol'
import type { Store } from '../db/store.js'
import type { ProviderAdapter } from '../providers/types.js'
import { describeSchedule } from '../sessions/schedule.js'
import type { SessionManager } from '../sessions/manager.js'
import type { AuthManager } from '../auth/manager.js'
import { Desktop, desktopHost, type DesktopInput } from '../surfaces/desktop.js'
import type { Handovers } from '../surfaces/handover.js'
import type { DesktopPool } from '../surfaces/pool.js'

export interface RpcContext {
  store: Store
  sessions: SessionManager
  providers: Map<string, ProviderAdapter>
  auth: AuthManager
  desktops: DesktopPool
  handovers: Handovers
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
    const params = p as {
      name: string; systemPrompt: string; model: string
      effort?: 'low' | 'medium' | 'high' | 'xhigh' | 'max'
      avatarColor?: string; surfaceMode: 'none' | 'container' | 'host'
      provider?: string
    }
    const created = ctx.store.createBot(params)
    // A bot with a screen gets it now rather than on first use. Pulling a container up
    // takes tens of seconds, and a bot is expected to start working the moment it is
    // made — waiting until its first tool call would strand it mid-greeting.
    const adapter = ctx.providers.get(created.bot.provider)
    if (params.surfaceMode === 'container' && adapter?.supportsSurface) {
      ctx.desktops.warm(created.bot.id)
    }
    // Fire and forget: the client should get its bot back immediately and watch the
    // greeting stream in, exactly as it would any other reply.
    void ctx.sessions.greet(created.conversation.id)
    return created
  },

  'bots.update': async (p, ctx) => {
    const { id, patch } = p as { id: string; patch: Record<string, unknown> }
    const before = ctx.store.getBot(id)
    const bot = ctx.store.updateBot(id, patch)
    if (!bot || !before) throw new RpcError('not_found', `No such bot: ${id}`)
    // A changed description means a stale system prompt in every warm session, so
    // those are dropped — keyed per conversation and bot, so each is named. Model and
    // effort are applied per turn by every adapter and need no drop; dropping for
    // them would cost a harness bot its thread, which is its memory of the chat.
    if (bot.systemPrompt !== before.systemPrompt) {
      const adapter = ctx.providers.get(bot.provider)
      for (const conversation of ctx.store.listConversations(bot.id)) {
        adapter?.release(`${conversation.id}:${bot.id}`)
      }
    }
    return { bot }
  },

  'bots.delete': async (p, ctx) => {
    const { id } = p as { id: string }
    if (!ctx.store.deleteBot(id)) throw new RpcError('not_found', `No such bot: ${id}`)
    // The bot is gone; its container should not outlive it.
    void ctx.desktops.for(id).stop().catch(() => {})
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
    const messages = ctx.store.listMessages(conversationId, limit, before)
    // A turn in progress has said things the row does not hold yet; show those.
    const live = ctx.sessions.liveMessage(conversationId)
    return {
      messages: live
        ? messages.map((m) => (m.id === live.messageId ? { ...m, blocks: live.blocks } : m))
        : messages,
    }
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

  'auth.status': async (_p, ctx) => ({ auth: await ctx.auth.status() }),

  'auth.loginWithClaude': async (_p, ctx) => {
    try {
      return { auth: await ctx.auth.loginWithClaude() }
    } catch (err) {
      throw new RpcError('login_failed', err instanceof Error ? err.message : String(err))
    }
  },

  'auth.setApiKey': async (p, ctx) => {
    const { key } = p as { key: string }
    try {
      return { auth: await ctx.auth.setApiKey(key) }
    } catch (err) {
      // Most likely a bad key: the manager probes before committing.
      throw new RpcError('invalid_key', err instanceof Error ? err.message : String(err))
    }
  },

  'auth.signOut': async (_p, ctx) => ({ auth: await ctx.auth.signOut() }),

  'auth.providerLogin': async (p, ctx) => {
    const { provider } = p as { provider: string }
    try {
      return { auth: await ctx.auth.providerLogin(provider) }
    } catch (err) {
      throw new RpcError('login_failed', err instanceof Error ? err.message : String(err))
    }
  },

  'auth.providerSetApiKey': async (p, ctx) => {
    const { provider, key } = p as { provider: string; key: string }
    try {
      const { verified, ...auth } = await ctx.auth.providerSetApiKey(provider, key)
      return { auth, verified }
    } catch (err) {
      throw new RpcError('invalid_key', err instanceof Error ? err.message : String(err))
    }
  },

  'auth.providerSignOut': async (p, ctx) => {
    const { provider } = p as { provider: string }
    return { auth: await ctx.auth.providerSignOut(provider) }
  },

  'desktop.status': async (_p, ctx) => ({ desktop: await describeDesktopHost(ctx) }),

  'desktop.prepare': async (_p, ctx) => {
    const failure = await desktopHost.prepare()
    if (failure) throw new RpcError('desktop_failed', failure)
    return { desktop: await describeDesktopHost(ctx) }
  },

  'surface.status': async (p, ctx) => {
    const desktop = ctx.desktops.for((p as { botId: string }).botId)
    return { surface: { ...(await desktop.status()), heldBy: desktop.holder } }
  },

  'surface.start': async (p, ctx) => {
    const desktop = ctx.desktops.for((p as { botId: string }).botId)
    return { surface: { ...(await desktop.start()), heldBy: desktop.holder } }
  },

  'surface.stop': async (p, ctx) => {
    const desktop = ctx.desktops.for((p as { botId: string }).botId)
    await desktop.stop()
    return { surface: { ...(await desktop.status()), heldBy: desktop.holder } }
  },

  'surface.frame': async (p, ctx) => {
    const { botId, quality } = p as { botId: string; quality: number }
    const desktop = ctx.desktops.for(botId)
    const status = await desktop.status()
    const frame = await desktop.captureFrame(quality)
    return {
      jpeg: frame ? frame.jpeg.toString('base64') : null,
      width: status.width,
      height: status.height,
      pointerX: frame?.pointer?.x ?? null,
      pointerY: frame?.pointer?.y ?? null,
    }
  },

  'handover.resolve': async (p, ctx) => {
    const { botId, outcome } = p as { botId: string; outcome: 'done' | 'skipped' }
    return { ok: ctx.handovers.resolve(botId, outcome) }
  },

  'handover.list': async (_p, ctx) => ({ handovers: ctx.handovers.all() }),

  // Routines are made by bots during ordinary turns; these only let a person see and
  // stop what a bot has scheduled. Creating one from the app is not offered, because a
  // routine is a prompt the bot wrote for itself in its own voice.
  'routines.list': async (p, ctx) => {
    const { botId } = p as { botId?: string }
    return {
      routines: ctx.store.listRoutines(botId).map((routine) => ({
        ...routine,
        schedule: undefined,
        scheduleText: describeSchedule(routine.schedule),
      })),
    }
  },

  'routines.setEnabled': async (p, ctx) => {
    const { id, enabled } = p as { id: string; enabled: boolean }
    ctx.store.setRoutineEnabled(id, enabled)
    return {}
  },

  'routines.delete': async (p, ctx) => {
    const { id } = p as { id: string }
    ctx.store.deleteRoutine(id)
    return {}
  },

  // A bot's notes. The bot writes them during turns; a person may add, rewrite and
  // remove them here. Every change is announced so the rail and the bot both learn of
  // it — the bot on its next turn, since a warm session's prompt is already built.
  'memory.list': async (p, ctx) => {
    const { botId } = p as { botId?: string }
    if (!botId) return { memories: ctx.store.listSharedMemories() }
    const { own, shared } = ctx.store.memoriesFor(botId)
    return { memories: [...own, ...shared] }
  },

  'memory.add': async (p, ctx) => {
    const { botId, text, scope } = p as { botId?: string; text: string; scope: 'bot' | 'user' }
    if (scope === 'bot' && !ctx.store.getBot(botId ?? '')) throw new RpcError('not_found', `No such bot: ${botId}`)
    const memory = ctx.store.addMemory({ botId: botId ?? null, scope, text, source: 'user' })
    ctx.sessions.memoryChanged(memory.botId, 'user')
    return { memory }
  },

  'memory.update': async (p, ctx) => {
    const { id, text } = p as { id: string; text: string }
    const memory = ctx.store.updateMemory(id, text, 'user')
    if (!memory) throw new RpcError('not_found', `No such note: ${id}`)
    ctx.sessions.memoryChanged(memory.botId, 'user')
    return { memory }
  },

  'memory.delete': async (p, ctx) => {
    const { id } = p as { id: string }
    const memory = ctx.store.getMemory(id)
    if (memory && ctx.store.deleteMemory(id)) ctx.sessions.memoryChanged(memory.botId, 'user')
    return {}
  },

  'surface.clipboard': async (p, ctx) => {
    const { botId } = p as { botId: string }
    return { text: await ctx.desktops.for(botId).readClipboard() }
  },

  'surface.input': async (p, ctx) => {
    const { botId, input } = p as { botId: string; input: DesktopInput }
    try {
      await ctx.desktops.for(botId).send(input)
      return { ok: true as const }
    } catch (err) {
      throw new RpcError('surface_input_failed', err instanceof Error ? err.message : String(err))
    }
  },

  'channels.create': async (p, ctx) => {
    const { name, botIds } = p as { name: string; botIds: string[] }
    const conversation = ctx.store.createChannel(name, botIds)
    return { conversation, members: ctx.store.channelMembers(conversation.id) }
  },

  'channels.list': async (_p, ctx) => ({ conversations: ctx.store.listChannels() }),

  'channels.members': async (p, ctx) => {
    const { conversationId } = p as { conversationId: string }
    return { members: ctx.store.channelMembers(conversationId) }
  },

  'channels.updateMembers': async (p, ctx) => {
    const { conversationId, add, remove } = p as {
      conversationId: string; add: string[]; remove: string[]
    }
    try {
      return { members: ctx.store.updateChannelMembers(conversationId, add, remove) }
    } catch (err) {
      throw new RpcError('bad_membership', err instanceof Error ? err.message : String(err))
    }
  },

  'models.list': async (p, ctx) => {
    const { provider } = p as { provider: string }
    const adapter = ctx.providers.get(provider)
    // Before onboarding finishes there is no provider yet; an empty list lets the
    // client render without special-casing.
    if (!adapter) return { models: [], supportsSurface: false }
    return { models: await adapter.listModels(), supportsSurface: adapter.supportsSurface }
  },

  'account.info': async (_p, ctx) => {
    const adapter = ctx.providers.get('anthropic-claude') ?? ctx.providers.get('anthropic')
    if (!adapter) throw new RpcError('not_configured', 'No Anthropic credential configured yet.')
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

/** The machine, plus the bots with a screen up on it right now. */
async function describeDesktopHost(ctx: RpcContext) {
  const host = await desktopHost.describe()
  const screens: { botId: string; state: string }[] = []
  if (host.machine === 'running') {
    for (const surface of ctx.desktops.all()) {
      if (!(surface instanceof Desktop)) continue
      const status = await surface.status()
      if (status.state === 'running' || status.state === 'starting') {
        screens.push({ botId: surface.botId, state: status.state })
      }
    }
  }
  return { ...host, screens }
}
