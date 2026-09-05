import { z } from 'zod'
import { Block } from './blocks.js'
import {
  AccountInfo, AuthStatus, Bot, Conversation, Message, ModelInfo, SurfaceMode, SurfaceStatus,
} from './entities.js'

/**
 * The krogd wire protocol: one WebSocket carrying request/response RPCs and
 * server-pushed events.
 *
 * Streaming rule: deltas are addressed by `blockIndex`, never appended to a running
 * string. That is what lets text and tool cards interleave correctly as they arrive,
 * and it lets a reconnecting client resync a single block instead of the whole turn.
 */

export const PROTOCOL_VERSION = 1

// ---------------------------------------------------------------- RPC methods

export const RpcMethods = {
  'bots.list': { params: z.object({ includeArchived: z.boolean().default(false) }), result: z.object({ bots: z.array(Bot) }) },
  'bots.create': {
    params: z.object({
      name: z.string().min(1),
      systemPrompt: z.string().default(''),
      model: z.string().default('default'),
      /** Fixed at creation like provider and model; omitted means Anthropic's default. */
      effort: z.enum(['low', 'medium', 'high', 'xhigh', 'max']).optional(),
      avatarColor: z.string().optional(),
      surfaceMode: SurfaceMode.default('none'),
      /** Fixed at creation, like the model. Defaults to the provider onboarding set up. */
      provider: z.string().default('anthropic'),
    }),
    result: z.object({ bot: Bot, conversation: Conversation }),
  },
  'bots.update': {
    params: z.object({
      id: z.string(),
      /**
       * `provider` and `model` are deliberately absent: they are chosen once, at
       * creation, and fixed for the bot's lifetime. Changing the model mid-thread
       * would silently reinterpret an existing conversation under different
       * capabilities — and on the subscription adapter it would strand the warm
       * agent session that owns that history.
       */
      patch: z.object({
        name: z.string().min(1).optional(),
        systemPrompt: z.string().optional(),
        avatarColor: z.string().optional(),
        surfaceMode: SurfaceMode.optional(),
        archivedAt: z.number().int().nullable().optional(),
      }),
    }),
    result: z.object({ bot: Bot }),
  },
  'bots.delete': { params: z.object({ id: z.string() }), result: z.object({ ok: z.literal(true) }) },

  'conversations.list': { params: z.object({ botId: z.string().optional() }), result: z.object({ conversations: z.array(Conversation) }) },
  'conversations.create': { params: z.object({ botId: z.string(), title: z.string().optional() }), result: z.object({ conversation: Conversation }) },

  'messages.list': {
    params: z.object({ conversationId: z.string(), limit: z.number().int().positive().max(500).default(100), before: z.number().int().optional() }),
    result: z.object({ messages: z.array(Message) }),
  },
  'messages.send': {
    params: z.object({ conversationId: z.string(), blocks: z.array(Block) }),
    result: z.object({ message: Message }),
  },
  'messages.interrupt': { params: z.object({ conversationId: z.string() }), result: z.object({ ok: z.literal(true) }) },

  'auth.status': { params: z.object({}), result: z.object({ auth: AuthStatus }) },
  /** Opens the browser sign-in on the machine running krogd. Long-running. */
  'auth.loginWithClaude': { params: z.object({}), result: z.object({ auth: AuthStatus }) },
  'auth.setApiKey': { params: z.object({ key: z.string().min(1) }), result: z.object({ auth: AuthStatus }) },
  'auth.signOut': { params: z.object({}), result: z.object({ auth: AuthStatus }) },

  // Providers configured after onboarding. `provider` names which one, so a third
  // vendor needs no new methods.
  'auth.providerLogin': {
    params: z.object({ provider: z.string() }),
    result: z.object({ auth: AuthStatus }),
  },
  'auth.providerSetApiKey': {
    params: z.object({
      provider: z.string(),
      key: z.string().min(1),
      /** 'direct' or 'codex' for OpenAI; ignored by providers with one harness. */
      harness: z.string().optional(),
    }),
    result: z.object({
      auth: AuthStatus,
      /** What the check actually proved, e.g. "deepseek-chat answered". */
      verified: z.string().optional(),
    }),
  },
  'auth.providerSignOut': {
    params: z.object({ provider: z.string() }),
    result: z.object({ auth: AuthStatus }),
  },

  // Every surface call names a bot: desktops are per-bot, so there is no such thing
  // as "the" desktop to address.
  'surface.status': { params: z.object({ botId: z.string() }), result: z.object({ surface: SurfaceStatus }) },
  'surface.start': { params: z.object({ botId: z.string() }), result: z.object({ surface: SurfaceStatus }) },
  'surface.stop': { params: z.object({ botId: z.string() }), result: z.object({ surface: SurfaceStatus }) },
  /**
   * One frame, pulled. The client asks at whatever rate it can draw, so an idle
   * window costs nothing and no stream runs with nobody watching.
   */
  'surface.frame': {
    params: z.object({ botId: z.string(), quality: z.number().int().min(1).max(10).default(6) }),
    result: z.object({
      jpeg: z.string().nullable(),
      width: z.number().int(),
      height: z.number().int(),
      // An X screenshot has no cursor in it, so the pointer travels beside the frame.
      pointerX: z.number().int().nullable().default(null),
      pointerY: z.number().int().nullable().default(null),
    }),
  },
  /** Reads the desktop's clipboard, for copying out of a container screen. */
  'surface.clipboard': {
    params: z.object({ botId: z.string() }),
    result: z.object({ text: z.string() }),
  },
  'surface.input': {
    params: z.object({
      botId: z.string(),
      input: z.discriminatedUnion('kind', [
        z.object({ kind: z.literal('click'), x: z.number(), y: z.number(), button: z.number().int().min(1).max(3).optional() }),
        z.object({ kind: z.literal('doubleClick'), x: z.number(), y: z.number() }),
        z.object({ kind: z.literal('move'), x: z.number(), y: z.number() }),
        z.object({ kind: z.literal('scroll'), x: z.number(), y: z.number(), amount: z.number() }),
        z.object({ kind: z.literal('type'), text: z.string() }),
        z.object({ kind: z.literal('key'), keys: z.array(z.string()).min(1) }),
        z.object({ kind: z.literal('open'), url: z.string() }),
        z.object({ kind: z.literal('paste'), text: z.string() }),
      ]),
    }),
    result: z.object({ ok: z.literal(true) }),
  },

  'channels.create': {
    params: z.object({ name: z.string().min(1), botIds: z.array(z.string()).min(1).max(6) }),
    result: z.object({ conversation: Conversation, members: z.array(Bot) }),
  },
  'channels.list': { params: z.object({}), result: z.object({ conversations: z.array(Conversation) }) },
  'channels.members': {
    params: z.object({ conversationId: z.string() }),
    result: z.object({ members: z.array(Bot) }),
  },
  'channels.updateMembers': {
    params: z.object({
      conversationId: z.string(),
      add: z.array(z.string()).default([]),
      remove: z.array(z.string()).default([]),
    }),
    result: z.object({ members: z.array(Bot) }),
  },

  'models.list': {
    params: z.object({ provider: z.string().default('anthropic') }),
    result: z.object({
      models: z.array(ModelInfo),
      /** Whether a bot on this provider can be given a screen. */
      supportsSurface: z.boolean().default(true),
    }),
  },
  'account.info': { params: z.object({}), result: z.object({ account: AccountInfo }) },

  'settings.get': { params: z.object({}), result: z.object({ settings: z.record(z.string(), z.unknown()) }) },
  'settings.set': { params: z.object({ patch: z.record(z.string(), z.unknown()) }), result: z.object({ settings: z.record(z.string(), z.unknown()) }) },
} as const

export type RpcMethod = keyof typeof RpcMethods
export type RpcParams<M extends RpcMethod> = z.infer<(typeof RpcMethods)[M]['params']>
export type RpcResult<M extends RpcMethod> = z.infer<(typeof RpcMethods)[M]['result']>

// ------------------------------------------------------------ client -> server

export const ClientHello = z.object({
  t: z.literal('hello'),
  protocolVersion: z.number().int(),
  clientName: z.string(),
  platform: z.enum(['macos', 'ios', 'android', 'probe']),
  token: z.string().optional(),
})

export const ClientRpc = z.object({
  t: z.literal('rpc'),
  id: z.string(),
  method: z.string(),
  params: z.unknown(),
})

export const ClientSubscribe = z.object({ t: z.literal('subscribe'), conversationId: z.string() })
export const ClientUnsubscribe = z.object({ t: z.literal('unsubscribe'), conversationId: z.string() })

export const ClientMessage = z.discriminatedUnion('t', [ClientHello, ClientRpc, ClientSubscribe, ClientUnsubscribe])
export type ClientMessage = z.infer<typeof ClientMessage>

// ------------------------------------------------------------ server -> client

export const ServerEvent = z.discriminatedUnion('e', [
  z.object({ e: z.literal('message.created'), message: Message }),
  z.object({
    e: z.literal('message.delta'),
    conversationId: z.string(),
    messageId: z.string(),
    blockIndex: z.number().int().nonnegative(),
    /** Appended to the block at `blockIndex`; the block is created if absent. */
    delta: z.discriminatedUnion('type', [
      z.object({ type: z.literal('text'), text: z.string() }),
      z.object({ type: z.literal('thinking'), text: z.string() }),
    ]),
  }),
  /** A whole block arrived at once (tool_use, image, tool_result). */
  z.object({
    e: z.literal('message.block'),
    conversationId: z.string(),
    messageId: z.string(),
    blockIndex: z.number().int().nonnegative(),
    block: Block,
  }),
  z.object({
    e: z.literal('message.completed'),
    conversationId: z.string(),
    messageId: z.string(),
    stopReason: z.string().nullable().default(null),
    providerMeta: z.record(z.string(), z.unknown()).nullable().default(null),
  }),
  z.object({ e: z.literal('conversation.updated'), conversation: Conversation }),
  z.object({ e: z.literal('bot.updated'), bot: Bot }),
  z.object({ e: z.literal('bot.deleted'), botId: z.string() }),
  z.object({ e: z.literal('surface.state'), botId: z.string(), surface: SurfaceStatus }),
  // A room message that was never written: a bot chose silence.
  z.object({ e: z.literal('message.deleted'), conversationId: z.string(), messageId: z.string() }),
  /** Drives the typing indicator and the interrupt button. */
  z.object({ e: z.literal('conversation.busy'), conversationId: z.string(), busy: z.boolean() }),
  z.object({ e: z.literal('error'), conversationId: z.string().nullable().default(null), code: z.string(), message: z.string() }),
])
export type ServerEvent = z.infer<typeof ServerEvent>

export const ServerHelloOk = z.object({
  t: z.literal('hello_ok'),
  protocolVersion: z.number().int(),
  serverVersion: z.string(),
  account: AccountInfo,
  /** Lets the client decide to show onboarding without a second round trip. */
  auth: AuthStatus,
})

export const ServerRpcOk = z.object({ t: z.literal('rpc_ok'), id: z.string(), result: z.unknown() })
export const ServerRpcErr = z.object({
  t: z.literal('rpc_err'),
  id: z.string(),
  error: z.object({ code: z.string(), message: z.string() }),
})
export const ServerEventEnvelope = z.object({ t: z.literal('event'), event: ServerEvent })

export const ServerMessage = z.discriminatedUnion('t', [ServerHelloOk, ServerRpcOk, ServerRpcErr, ServerEventEnvelope])
export type ServerMessage = z.infer<typeof ServerMessage>
