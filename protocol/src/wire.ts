import { z } from 'zod'
import { Block } from './blocks.js'
import { AccountInfo, Bot, Conversation, Message, ModelInfo, SurfaceMode } from './entities.js'

/**
 * The korgd wire protocol: one WebSocket carrying request/response RPCs and
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
      avatarColor: z.string().optional(),
      surfaceMode: SurfaceMode.default('none'),
    }),
    result: z.object({ bot: Bot, conversation: Conversation }),
  },
  'bots.update': {
    params: z.object({
      id: z.string(),
      patch: z.object({
        name: z.string().min(1).optional(),
        systemPrompt: z.string().optional(),
        model: z.string().optional(),
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

  'models.list': { params: z.object({ provider: z.string().default('anthropic') }), result: z.object({ models: z.array(ModelInfo) }) },
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
