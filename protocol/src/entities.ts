import { z } from 'zod'
import { Block } from './blocks.js'

/** What a bot can see and control. See the surface table in the plan. */
export const SurfaceMode = z.enum(['none', 'container', 'host'])
export type SurfaceMode = z.infer<typeof SurfaceMode>

/** Which credential the daemon uses to reach Anthropic. */
export const AuthMode = z.enum(['subscription', 'api_key'])
export type AuthMode = z.infer<typeof AuthMode>

export const Bot = z.object({
  id: z.string(),
  name: z.string().min(1),
  avatarColor: z.string(),
  systemPrompt: z.string().default(''),
  provider: z.string().default('anthropic'),
  /**
   * Adapter-specific model id — NOT always a raw Anthropic model id. The subscription
   * adapter uses aliases the CLI reports ("default", "opus[1m]", "sonnet"); the API
   * adapter uses real ids ("claude-opus-5"). Resolve through the adapter, never parse.
   */
  model: z.string().default('default'),
  effort: z.enum(['low', 'medium', 'high', 'xhigh', 'max']).optional(),
  surfaceMode: SurfaceMode.default('none'),
  createdAt: z.number().int(),
  updatedAt: z.number().int(),
  archivedAt: z.number().int().nullable().default(null),
})

export const Conversation = z.object({
  id: z.string(),
  botId: z.string().nullable().default(null),
  title: z.string(),
  /** First line of the most recent message — what the sidebar shows under the name. */
  preview: z.string().default(''),
  createdAt: z.number().int(),
  updatedAt: z.number().int(),
  lastMessageAt: z.number().int().nullable().default(null),
  /** 'direct' is one bot; 'channel' is a room with members. */
  kind: z.enum(['direct', 'channel']).default('direct'),
})

export const Role = z.enum(['user', 'assistant', 'system'])
export type Role = z.infer<typeof Role>

export const Message = z.object({
  /** Which bot wrote it, in a room. Null for a person or a one-bot chat. */
  botId: z.string().nullable().default(null),
  id: z.string(),
  conversationId: z.string(),
  role: Role,
  blocks: z.array(Block),
  /** Model, usage, stop reason — opaque to the client, shown in a debug pane. */
  providerMeta: z.record(z.string(), z.unknown()).nullable().default(null),
  createdAt: z.number().int(),
})

/**
 * A recurring task a bot saved for itself, as the app sees it.
 *
 * The schedule travels as a sentence rather than as its shape — "every 30 minutes",
 * "every weekday at 08:00" — because the daemon already knows how to say it and the
 * app has no reason to learn the kinds.
 */
export const Routine = z.object({
  id: z.string(),
  botId: z.string(),
  conversationId: z.string(),
  name: z.string(),
  prompt: z.string(),
  scheduleText: z.string(),
  enabled: z.boolean(),
  lastRunAt: z.number().int().nullable().default(null),
  nextRunAt: z.number().int().nullable().default(null),
})
export type Routine = z.infer<typeof Routine>

/**
 * One note a bot keeps.
 *
 * Notes belong to a bot rather than a conversation and outlive both the transcript and
 * the runtime's own context: they are shown to the bot at the top of every turn, on
 * whatever provider runs it. A bot writes them during ordinary turns; the person can
 * read, rewrite and remove them. `source` says who last touched one.
 *
 * `scope` is `bot` for a bot's own notes and `user` for facts about the person that
 * every bot reads — those have no `botId`, so no bot's deletion takes them along.
 */
export const Memory = z.object({
  id: z.string(),
  botId: z.string().nullable(),
  scope: z.enum(['bot', 'user']),
  text: z.string(),
  source: z.enum(['bot', 'user']),
  createdAt: z.number().int(),
  updatedAt: z.number().int(),
})
export type Memory = z.infer<typeof Memory>

export const ModelInfo = z.object({
  id: z.string(),
  displayName: z.string(),
  description: z.string().default(''),
  resolvedModel: z.string().optional(),
  effortLevels: z.array(z.enum(['low', 'medium', 'high', 'xhigh', 'max'])).optional(),
  /**
   * What the provider does when a bot names no effort.
   *
   * Stated by the provider rather than assumed by the client, which used to print a
   * flat "High" for every bot — true of Anthropic, invented for the others. Null
   * means the provider decides and will not say, so nothing should be claimed.
   */
  defaultEffort: z.enum(['low', 'medium', 'high', 'xhigh', 'max']).nullish(),
  /**
   * What to call this model when reporting what a bot runs, if that differs from its
   * name in the picker.
   *
   * A menu item and a status line want different grammar. "Let Codex decide" is an
   * instruction and belongs in a list of choices; "Model chosen by Codex" is a
   * statement and belongs under a bot. One string doing both made a menu look like it
   * was answering a question.
   */
  statusName: z.string().nullish(),
})

export const AccountInfo = z.object({
  authMode: AuthMode,
  subscriptionType: z.string().optional(),
  organization: z.string().optional(),
  email: z.string().optional(),
})

/** Everything onboarding needs to decide what to show next. */
/** How one provider is authenticated. */
export const ProviderAuth = z.object({
  configured: z.boolean(),
  mode: AuthMode.nullable(),
  cli: z.object({
    installed: z.boolean(),
    version: z.string().nullable(),
    loggedIn: z.boolean(),
    /** How the CLI is signed in, in its own words — "ChatGPT", a plan name. */
    account: z.string().optional(),
  }),
  apiKey: z.object({ present: z.boolean() }),
})
export type ProviderAuth = z.infer<typeof ProviderAuth>

export const AuthStatus = z.object({
  /** True once a provider can actually reach Anthropic. Gates the main UI. */
  configured: z.boolean(),
  mode: AuthMode.nullable(),
  subscription: z.object({
    cliInstalled: z.boolean(),
    cliVersion: z.string().nullable(),
    loggedIn: z.boolean(),
    email: z.string().optional(),
    organization: z.string().optional(),
    subscriptionType: z.string().optional(),
  }),
  apiKey: z.object({ present: z.boolean() }),
  /**
   * Every provider beyond the first, keyed by id.
   *
   * Anthropic keeps the flat fields above because onboarding is built on them and a
   * bot needs one working provider before anything else can happen. Providers added
   * later are configured in Settings instead, so they arrive as a map rather than as
   * more top-level fields — adding the next one costs a row in the UI and nothing in
   * the wire format.
   */
  providers: z.record(z.string(), ProviderAuth).default({}),
})
export type AuthStatus = z.infer<typeof AuthStatus>

/** The shared Linux desktop every bot drives. */
export const SurfaceStatus = z.object({
  state: z.enum(['stopped', 'starting', 'running', 'unavailable']),
  width: z.number().int().positive(),
  height: z.number().int().positive(),
  /** Why it cannot run, when it cannot. */
  detail: z.string().optional(),
  /** Conversation currently holding the pointer, if any. */
  heldBy: z.string().nullable().default(null),
})
export type SurfaceStatus = z.infer<typeof SurfaceStatus>

export type Bot = z.infer<typeof Bot>
export type Conversation = z.infer<typeof Conversation>
export type Message = z.infer<typeof Message>
export type ModelInfo = z.infer<typeof ModelInfo>
export type AccountInfo = z.infer<typeof AccountInfo>

/**
 * The machine every container screen lives on, for setup and Settings.
 *
 * Three questions with three different fixes — is Docker installed, is it running, is
 * the desktop image built — plus which bots have a screen up right now.
 */
export const DesktopHostStatus = z.object({
  docker: z.enum(['missing', 'stopped', 'running']),
  dockerVersion: z.string().nullable(),
  image: z.enum(['missing', 'building', 'ready', 'unknown']),
  machine: z.enum(['stopped', 'running']),
  screens: z.array(z.object({ botId: z.string(), state: z.string() })),
  /** Where the image build is, while one runs: which Dockerfile step, and its newest line. */
  build: z
    .object({
      step: z.number().int().nullable(),
      of: z.number().int().nullable(),
      detail: z.string(),
      line: z.string(),
      elapsedMs: z.number().int(),
    })
    .optional(),
})
export type DesktopHostStatus = z.infer<typeof DesktopHostStatus>

/** A bot waiting for the person to do something on its screen. */
export const Handover = z.object({
  id: z.string(),
  botId: z.string(),
  conversationId: z.string(),
  reason: z.string(),
  askedAt: z.number(),
})
export type Handover = z.infer<typeof Handover>
