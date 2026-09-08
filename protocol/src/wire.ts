import { z } from 'zod'
import { Block } from './blocks.js'
import {
  AccountInfo, AuthStatus, Bot, Conversation, DesktopHostStatus, Handover, Memory, Message, ModelInfo, Routine, SurfaceMode, SurfaceStatus,
} from './entities.js'

/**
 * The routid wire protocol: one WebSocket carrying request/response RPCs and
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
       * `provider` is absent: it is chosen once, at creation, because model ids do
       * not cross providers and a bot's history lives in one harness. `model` and
       * `effort` can change — the same switch Claude Code's own /model makes
       * mid-conversation. The daemon releases the bot's warm session on update, and
       * the next turn resumes the same history under the new model. A null effort
       * hands the choice back to the provider's default.
       */
      patch: z.object({
        name: z.string().min(1).optional(),
        systemPrompt: z.string().optional(),
        model: z.string().min(1).optional(),
        effort: z.enum(['low', 'medium', 'high', 'xhigh', 'max']).nullable().optional(),
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
  /** Opens the browser sign-in on the machine running routid. Long-running. */
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
  /** The machine as a whole: Docker, the image, and which bots have a screen up. */
  'desktop.status': { params: z.object({}), result: z.object({ desktop: DesktopHostStatus }) },
  /** Builds the image if needed and starts the machine. Minutes, the first time. */
  'desktop.prepare': { params: z.object({}), result: z.object({ desktop: DesktopHostStatus }) },
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
  /** Answers a bot that is waiting for you to sign in or finish something. */
  'handover.resolve': {
    params: z.object({ botId: z.string(), outcome: z.enum(['done', 'skipped']) }),
    result: z.object({ ok: z.boolean() }),
  },
  'handover.list': { params: z.object({}), result: z.object({ handovers: z.array(Handover) }) },
  // What a bot has scheduled for itself. Seen and stopped here; made in conversation.
  'routines.list': {
    params: z.object({ botId: z.string().optional() }),
    result: z.object({ routines: z.array(Routine) }),
  },
  'routines.setEnabled': { params: z.object({ id: z.string(), enabled: z.boolean() }), result: z.object({}) },
  'routines.delete': { params: z.object({ id: z.string() }), result: z.object({}) },

  // What a bot has written down for itself. Unlike routines the person may add here
  // too: a note is a fact, and a fact is as true from them as from the bot.
  /**
   * A bot's own notes and the shared ones, together; `scope` tells them apart. With no
   * bot named, only the shared ones — Settings reads them without a bot selected.
   */
  'memory.list': {
    params: z.object({ botId: z.string().optional() }),
    result: z.object({ memories: z.array(Memory) }),
  },
  'memory.add': {
    params: z
      .object({
        botId: z.string().optional(),
        text: z.string().trim().min(1).max(2000),
        scope: z.enum(['bot', 'user']).default('bot'),
      })
      .refine((p) => p.scope === 'user' || !!p.botId, { message: 'A bot\'s own note needs a botId.' }),
    result: z.object({ memory: Memory }),
  },
  'memory.update': {
    params: z.object({ id: z.string(), text: z.string().trim().min(1).max(2000) }),
    result: z.object({ memory: Memory }),
  },
  'memory.delete': { params: z.object({ id: z.string() }), result: z.object({}) },

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

  /**
   * Whether a newer core exists, and the update itself.
   *
   * The core asks GitHub for the latest release — the core, not the app, because the
   * app may be a phone and the core is the thing with the install. `start` downloads,
   * verifies and unpacks the release, then hands over to the release's own update
   * script, which builds it beside the running core, swaps them and restarts the
   * agent; the socket drops when that happens and the app reconnects to the new one.
   */
  'core.update.check': {
    params: z.object({ force: z.boolean().default(false) }),
    result: z.object({
      update: z.object({
        current: z.string(),
        latest: z.string().nullable(),
        available: z.boolean(),
        /** False for a core run from a source checkout, which git updates. */
        canUpdate: z.boolean(),
        reason: z.string().optional(),
        checkedAt: z.number().int(),
      }),
    }),
  },
  'core.update.start': {
    params: z.object({}),
    result: z.object({ ok: z.boolean(), why: z.string().optional() }),
  },
  /** Where this core can be reached from another device: the Mac's name, and its Tailscale address when it has one. */
  'core.addresses': {
    params: z.object({}),
    result: z.object({
      addresses: z.object({
        hostname: z.string(),
        tailscale: z.string().nullable(),
        /** Whether the core is answering on that Tailscale address right now. */
        listening: z.boolean(),
      }),
    }),
  },

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
    /**
     * The reply's first line of text, for a notification. A client only holds the
     * messages of the conversation it is looking at, and a finished turn elsewhere is
     * exactly the one worth telling the person about.
     */
    preview: z.string().optional(),
  }),
  z.object({ e: z.literal('conversation.updated'), conversation: Conversation }),
  z.object({ e: z.literal('bot.updated'), bot: Bot }),
  z.object({ e: z.literal('bot.deleted'), botId: z.string() }),
  // A bot's notes changed — written by the bot mid-turn or edited by a person on
  // another device. Carries only the owner, null for a shared note: the list is small
  // and fetched whole.
  z.object({ e: z.literal('memory.updated'), botId: z.string().nullable() }),
  // A bot's routines changed — one saved or removed mid-turn, or toggled on another
  // device. The rail used to learn of a new routine only when the bot was reselected.
  z.object({ e: z.literal('routines.updated'), botId: z.string() }),
  // What the update is doing, while the old core is still alive to say.
  z.object({ e: z.literal('core.update.progress'), stage: z.string(), line: z.string() }),
  z.object({ e: z.literal('surface.state'), botId: z.string(), surface: SurfaceStatus }),
  // A room message that was never written: a bot chose silence.
  z.object({ e: z.literal('message.deleted'), conversationId: z.string(), messageId: z.string() }),
  z.object({ e: z.literal('handover.requested'), handover: Handover }),
  z.object({
    e: z.literal('handover.resolved'),
    botId: z.string(),
    id: z.string(),
    outcome: z.enum(['done', 'skipped', 'timeout']),
  }),
  /**
   * Drives the typing indicator and the interrupt button.
   *
   * Names the routine when one woke the turn, so the app can say so: a bot that went
   * "Thinking…" the moment its conversation was opened, with nothing sent, looked
   * broken — it was running its half-hourly scan.
   */
  z.object({
    e: z.literal('conversation.busy'),
    conversationId: z.string(),
    busy: z.boolean(),
    routineName: z.string().nullish(),
  }),
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
