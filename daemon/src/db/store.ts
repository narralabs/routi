import type Database from 'better-sqlite3'
import { randomUUID } from 'node:crypto'
import { nextRun, parseSchedule, type Schedule } from '../sessions/schedule.js'
import type { Block, Bot, Conversation, Memory, Message, Profile, Role } from '@routi/protocol'

const now = () => Date.now()

/**
 * Avatar colours, assigned round-robin as bots are created.
 *
 * Chosen so the cream face on top stays legible on every one (no yellows, no pastels),
 * spread around the wheel so neighbours in the sidebar differ in hue, and dark enough
 * that the face rather than the tile is what the eye lands on.
 */
const PALETTE = ['#E8563F', '#F28B2E', '#2FAE7C', '#1FA8B8', '#3B8BEA', '#5A64E0', '#9B5DE5', '#D9508F', '#6E7684']

type BotRow = {
  id: string; name: string; avatar_color: string; system_prompt: string
  provider: string; model: string; effort: string | null; surface_mode: string
  created_at: number; updated_at: number; archived_at: number | null
  profile_id: string | null
}
type ProfileRow = { id: string; name: string; created_at: number }

/** The first profile's id: the one every pre-profile bot and credential belongs to. */
export const DEFAULT_PROFILE = 'default'

const toProfile = (r: ProfileRow): Profile => ({ id: r.id, name: r.name, createdAt: r.created_at })
type RoutineRow = {
  id: string; bot_id: string; conversation_id: string; name: string; prompt: string
  schedule_json: string; enabled: number; created_at: number
  last_run_at: number | null; next_run_at: number | null
}

type MemoryRow = {
  id: string; bot_id: string | null; scope: string; text: string; source: string
  created_at: number; updated_at: number
}

const toMemory = (r: MemoryRow): Memory => ({
  id: r.id,
  botId: r.bot_id,
  scope: r.scope === 'user' ? 'user' : 'bot',
  text: r.text,
  source: r.source === 'user' ? 'user' : 'bot',
  createdAt: r.created_at,
  updatedAt: r.updated_at,
})

const toRoutine = (r: RoutineRow): Routine => ({
  id: r.id,
  botId: r.bot_id,
  conversationId: r.conversation_id,
  name: r.name,
  prompt: r.prompt,
  schedule: parseSchedule(JSON.parse(r.schedule_json)) ?? { kind: 'daily', at: '09:00' },
  enabled: r.enabled === 1,
  createdAt: r.created_at,
  lastRunAt: r.last_run_at,
  nextRunAt: r.next_run_at,
})

export interface Routine {
  id: string
  botId: string
  conversationId: string
  name: string
  prompt: string
  schedule: Schedule
  enabled: boolean
  createdAt: number
  lastRunAt: number | null
  nextRunAt: number | null
}

type ConvRow = {
  kind?: string
  id: string; bot_id: string; title: string
  created_at: number; updated_at: number; last_message_at: number | null
  provider_session_id: string | null
  last_blocks: string | null
}
type MsgRow = {
  bot_id?: string | null
  id: string; conversation_id: string; role: string
  blocks_json: string; provider_meta_json: string | null; created_at: number
}

const toBot = (r: BotRow): Bot => ({
  id: r.id,
  name: r.name,
  avatarColor: r.avatar_color,
  systemPrompt: r.system_prompt,
  provider: r.provider,
  model: r.model,
  effort: (r.effort as Bot['effort']) ?? undefined,
  surfaceMode: r.surface_mode as Bot['surfaceMode'],
  profileId: r.profile_id ?? DEFAULT_PROFILE,
  createdAt: r.created_at,
  updatedAt: r.updated_at,
  archivedAt: r.archived_at,
})

const toConv = (r: ConvRow): Conversation => ({
  kind: (r.kind ?? 'direct') as Conversation['kind'],
  id: r.id,
  botId: r.bot_id,
  title: r.title,
  preview: previewOf(r.last_blocks),
  createdAt: r.created_at,
  updatedAt: r.updated_at,
  lastMessageAt: r.last_message_at,
})

/** First non-empty text block of the last message, flattened to one line. */
function previewOf(blocksJson: string | null): string {
  if (!blocksJson) return ''
  try {
    const blocks = JSON.parse(blocksJson) as Block[]
    for (const b of blocks) {
      if (b.type === 'text' && b.text.trim()) {
        return b.text.trim().replace(/\s+/g, ' ').slice(0, 140)
      }
    }
    // A turn can be all tool cards or images; say something rather than nothing.
    if (blocks.some((b) => b.type === 'tool_use')) return 'Working…'
    if (blocks.some((b) => b.type === 'image')) return 'Sent an image'
  } catch {
    // Corrupt row: fall through to an empty preview rather than failing the list.
  }
  return ''
}

/** Attaches the latest message's blocks so `toConv` can derive a preview. */
const CONV_SELECT = `SELECT c.*, (
    SELECT m.blocks_json FROM messages m
    WHERE m.conversation_id = c.id
    ORDER BY m.created_at DESC LIMIT 1
  ) AS last_blocks
  FROM conversations c`

const toMsg = (r: MsgRow): Message => ({
  id: r.id,
  conversationId: r.conversation_id,
  botId: r.bot_id ?? null,
  role: r.role as Role,
  blocks: JSON.parse(r.blocks_json) as Block[],
  providerMeta: r.provider_meta_json ? (JSON.parse(r.provider_meta_json) as Record<string, unknown>) : null,
  createdAt: r.created_at,
})

export class Store {
  constructor(private readonly db: Database.Database) {}

  // --------------------------------------------------------------- profiles

  listProfiles(): Profile[] {
    return (this.db.prepare('SELECT * FROM profiles ORDER BY created_at').all() as ProfileRow[]).map(toProfile)
  }

  getProfile(id: string): Profile | null {
    const r = this.db.prepare('SELECT * FROM profiles WHERE id = ?').get(id) as ProfileRow | undefined
    return r ? toProfile(r) : null
  }

  createProfile(name: string, id: string = randomUUID()): Profile {
    const profile: Profile = { id, name: name.trim(), createdAt: now() }
    this.db.prepare('INSERT INTO profiles (id, name, created_at) VALUES (@id, @name, @createdAt)').run(profile)
    return profile
  }

  renameProfile(id: string, name: string): Profile | null {
    this.db.prepare('UPDATE profiles SET name = ? WHERE id = ?').run(name.trim(), id)
    return this.getProfile(id)
  }

  /** Only an empty profile goes, and never the last one. */
  deleteProfile(id: string): void {
    if (this.listProfiles().length <= 1) throw new Error('The last profile cannot be deleted.')
    if (this.listBots(true, id).length > 0) throw new Error('Delete or move its bots first.')
    this.db.prepare('DELETE FROM profiles WHERE id = ?').run(id)
  }

  /**
   * The first profile, made once from whatever name was saved before profiles
   * existed, and given every bot that has none. Run at boot before anything reads
   * bots, so the world before profiles is exactly the default profile after them.
   */
  ensureDefaultProfile(): Profile {
    const existing = this.getProfile(DEFAULT_PROFILE)
    if (existing) return existing
    const name = ((this.getSettings()['userName'] as string | undefined)?.trim() || 'Personal')
    const profile = this.createProfile(name, DEFAULT_PROFILE)
    this.db.prepare('UPDATE bots SET profile_id = ? WHERE profile_id IS NULL').run(DEFAULT_PROFILE)
    return profile
  }

  // ------------------------------------------------------------------- bots

  listBots(includeArchived = false, profileId?: string): Bot[] {
    const where = [
      includeArchived ? null : 'archived_at IS NULL',
      profileId ? 'COALESCE(profile_id, @def) = @profileId' : null,
    ].filter(Boolean).join(' AND ')
    const sql = `SELECT * FROM bots${where ? ` WHERE ${where}` : ''} ORDER BY updated_at DESC`
    return (this.db.prepare(sql).all({ def: DEFAULT_PROFILE, profileId }) as BotRow[]).map(toBot)
  }

  getBot(id: string): Bot | null {
    const r = this.db.prepare('SELECT * FROM bots WHERE id = ?').get(id) as BotRow | undefined
    return r ? toBot(r) : null
  }

  // ------------------------------------------------------------------ routines

  createRoutine(input: {
    botId: string; conversationId: string; name: string; prompt: string
    schedule: Schedule
  }): Routine {
    const t = now()
    const routine: Routine = {
      id: randomUUID(),
      botId: input.botId,
      conversationId: input.conversationId,
      name: input.name,
      prompt: input.prompt,
      schedule: input.schedule,
      enabled: true,
      createdAt: t,
      lastRunAt: null,
      nextRunAt: nextRun(input.schedule, t),
    }
    this.db
      .prepare(
        `INSERT INTO routines (id,bot_id,conversation_id,name,prompt,schedule_json,enabled,created_at,last_run_at,next_run_at)
         VALUES (@id,@botId,@conversationId,@name,@prompt,@scheduleJson,1,@createdAt,NULL,@nextRunAt)`,
      )
      .run({ ...routine, scheduleJson: JSON.stringify(routine.schedule) })
    return routine
  }

  listRoutines(botId?: string): Routine[] {
    const rows = botId
      ? (this.db.prepare('SELECT * FROM routines WHERE bot_id = ? ORDER BY created_at').all(botId) as RoutineRow[])
      : (this.db.prepare('SELECT * FROM routines ORDER BY created_at').all() as RoutineRow[])
    return rows.map(toRoutine)
  }

  /** Everything enabled and overdue. The scheduler's only query. */
  dueRoutines(at = now()): Routine[] {
    const rows = this.db
      .prepare('SELECT * FROM routines WHERE enabled = 1 AND next_run_at IS NOT NULL AND next_run_at <= ?')
      .all(at) as RoutineRow[]
    return rows.map(toRoutine)
  }

  /** Records a run and books the next one. */
  markRoutineRun(id: string, at = now()): void {
    const routine = this.db.prepare('SELECT * FROM routines WHERE id = ?').get(id) as RoutineRow | undefined
    if (!routine) return
    const schedule = parseSchedule(JSON.parse(routine.schedule_json))
    this.db
      .prepare('UPDATE routines SET last_run_at = ?, next_run_at = ? WHERE id = ?')
      .run(at, schedule ? nextRun(schedule, at) : null, id)
  }

  setRoutineEnabled(id: string, enabled: boolean): void {
    this.db.prepare('UPDATE routines SET enabled = ? WHERE id = ?').run(enabled ? 1 : 0, id)
  }

  deleteRoutine(id: string): void {
    this.db.prepare('DELETE FROM routines WHERE id = ?').run(id)
  }

  // ------------------------------------------------------------------- memory

  /** A bot's own notes, oldest first — the order they read in, and the order they are shown to it. */
  listMemories(botId: string): Memory[] {
    const rows = this.db
      .prepare("SELECT * FROM memories WHERE scope = 'bot' AND bot_id = ? ORDER BY created_at, rowid")
      .all(botId) as MemoryRow[]
    return rows.map(toMemory)
  }

  /** What every bot knows about the person. */
  listSharedMemories(): Memory[] {
    const rows = this.db
      .prepare("SELECT * FROM memories WHERE scope = 'user' ORDER BY created_at, rowid")
      .all() as MemoryRow[]
    return rows.map(toMemory)
  }

  /** Everything one bot reads: its own notes and the shared ones. */
  memoriesFor(botId: string): { own: Memory[]; shared: Memory[] } {
    return { own: this.listMemories(botId), shared: this.listSharedMemories() }
  }

  getMemory(id: string): Memory | null {
    const r = this.db.prepare('SELECT * FROM memories WHERE id = ?').get(id) as MemoryRow | undefined
    return r ? toMemory(r) : null
  }

  /** A shared note has no bot: it must outlive whichever bot happened to write it. */
  addMemory(input: { botId: string | null; scope: Memory['scope']; text: string; source: Memory['source'] }): Memory {
    const t = now()
    const memory: Memory = {
      id: randomUUID(),
      botId: input.scope === 'user' ? null : input.botId,
      scope: input.scope,
      text: input.text,
      source: input.source,
      createdAt: t,
      updatedAt: t,
    }
    this.db
      .prepare(
        `INSERT INTO memories (id,bot_id,scope,text,source,created_at,updated_at)
         VALUES (@id,@botId,@scope,@text,@source,@createdAt,@updatedAt)`,
      )
      .run(memory)
    return memory
  }

  /** Rewrites a note. The source becomes whoever last touched it. */
  updateMemory(id: string, text: string, source: Memory['source']): Memory | null {
    this.db
      .prepare('UPDATE memories SET text = ?, source = ?, updated_at = ? WHERE id = ?')
      .run(text, source, now(), id)
    return this.getMemory(id)
  }

  deleteMemory(id: string): boolean {
    return this.db.prepare('DELETE FROM memories WHERE id = ?').run(id).changes > 0
  }

  // ------------------------------------------------------------------ channels

  /**
   * A room: one conversation, several bots.
   *
   * Capped at six members, which is not arbitrary — every member is a model turn
   * waiting to happen, and the cost of a room is the number of bots woken rather than
   * the number of words said.
   */
  createChannel(name: string, botIds: string[]): Conversation {
    const members = [...new Set(botIds)].slice(0, 6)
    if (members.length === 0) throw new Error('A channel needs at least one bot.')

    const t = now()
    const id = randomUUID()
    this.db.transaction(() => {
      this.db
        .prepare(
          `INSERT INTO conversations (id, bot_id, title, created_at, updated_at, last_message_at, kind)
           VALUES (@id, NULL, @title, @t, @t, NULL, 'channel')`,
        )
        .run({ id, title: name, t })
      const insert = this.db.prepare(
        'INSERT INTO channel_members (conversation_id, bot_id, joined_at) VALUES (?, ?, ?)',
      )
      for (const botId of members) insert.run(id, botId, t)
    })()

    return this.getConversation(id)!
  }

  channelMembers(conversationId: string): Bot[] {
    const rows = this.db
      .prepare(
        `SELECT b.* FROM channel_members m
         JOIN bots b ON b.id = m.bot_id
         WHERE m.conversation_id = ? AND b.archived_at IS NULL
         ORDER BY m.joined_at`,
      )
      .all(conversationId) as BotRow[]
    return rows.map(toBot)
  }

  /** Adds and removes in one step. A channel is never left empty. */
  updateChannelMembers(conversationId: string, add: string[] = [], remove: string[] = []): Bot[] {
    this.db.transaction(() => {
      const insert = this.db.prepare(
        'INSERT OR IGNORE INTO channel_members (conversation_id, bot_id, joined_at) VALUES (?, ?, ?)',
      )
      for (const botId of add.slice(0, 6)) insert.run(conversationId, botId, now())

      const drop = this.db.prepare(
        'DELETE FROM channel_members WHERE conversation_id = ? AND bot_id = ?',
      )
      for (const botId of remove) drop.run(conversationId, botId)
    })()

    const left = this.channelMembers(conversationId)
    if (left.length === 0) throw new Error('A channel must keep at least one bot.')
    return left
  }

  listChannels(): Conversation[] {
    const rows = this.db
      .prepare("SELECT * FROM conversations WHERE kind = 'channel' ORDER BY last_message_at DESC, created_at DESC")
      .all() as ConvRow[]
    return rows.map(toConv)
  }

  /** Repoints every bot on one provider at another. Returns how many moved. */
  moveBotsToProvider(from: string, to: string): number {
    const result = this.db
      .prepare('UPDATE bots SET provider=@to, updated_at=@t WHERE provider=@from')
      .run({ from, to, t: now() })
    return result.changes
  }

  createBot(input: {
    name: string; systemPrompt?: string; model?: string; effort?: Bot['effort']
    avatarColor?: string; surfaceMode?: Bot['surfaceMode']; provider?: string; profileId?: string
  }): { bot: Bot; conversation: Conversation } {
    const count = this.db.prepare('SELECT COUNT(*) AS n FROM bots').get() as { n: number }
    const t = now()
    const bot: Bot = {
      id: randomUUID(),
      name: input.name,
      avatarColor: input.avatarColor ?? PALETTE[count.n % PALETTE.length]!,
      systemPrompt: input.systemPrompt ?? '',
      provider: input.provider ?? 'anthropic',
      model: input.model ?? 'default',
      effort: input.effort,
      surfaceMode: input.surfaceMode ?? 'none',
      profileId: input.profileId ?? DEFAULT_PROFILE,
      createdAt: t,
      updatedAt: t,
      archivedAt: null,
    }
    // A bot is useless without somewhere to talk, so create both atomically.
    const conversation = this.db.transaction(() => {
      this.db
        .prepare(
          `INSERT INTO bots (id,name,avatar_color,system_prompt,provider,model,effort,surface_mode,created_at,updated_at,archived_at,profile_id)
           VALUES (@id,@name,@avatarColor,@systemPrompt,@provider,@model,@effort,@surfaceMode,@createdAt,@updatedAt,NULL,@profileId)`,
        )
        .run({ ...bot, effort: bot.effort ?? null })
      return this.createConversation(bot.id, 'New chat')
    })()
    return { bot, conversation }
  }

  updateBot(id: string, patch: Partial<Bot> & { effort?: Bot['effort'] | null }): Bot | null {
    const existing = this.getBot(id)
    if (!existing) return null
    // The provider is immutable after creation; pin it regardless of what the caller
    // sent, so the schema and the storage layer agree. Model and effort may move —
    // a null effort means "back to the provider's default", stored as none.
    const { effort: patchedEffort, ...rest } = patch
    const next: Bot = {
      ...existing,
      ...rest,
      id: existing.id,
      provider: existing.provider,
      profileId: existing.profileId,
      effort: 'effort' in patch ? (patchedEffort ?? undefined) : existing.effort,
      updatedAt: now(),
    }
    this.db
      .prepare(
        `UPDATE bots SET name=@name, avatar_color=@avatarColor, system_prompt=@systemPrompt,
         provider=@provider, model=@model, effort=@effort, surface_mode=@surfaceMode,
         updated_at=@updatedAt, archived_at=@archivedAt WHERE id=@id`,
      )
      .run({ ...next, effort: next.effort ?? null })
    return next
  }

  deleteBot(id: string): boolean {
    return this.db.prepare('DELETE FROM bots WHERE id = ?').run(id).changes > 0
  }

  // ---------------------------------------------------------- conversations

  listConversations(botId?: string): Conversation[] {
    const order = ' ORDER BY COALESCE(c.last_message_at, c.created_at) DESC'
    const sql = botId ? `${CONV_SELECT} WHERE c.bot_id = ?${order}` : `${CONV_SELECT}${order}`
    const rows = (botId ? this.db.prepare(sql).all(botId) : this.db.prepare(sql).all()) as ConvRow[]
    return rows.map(toConv)
  }

  getConversation(id: string): Conversation | null {
    const r = this.db.prepare(`${CONV_SELECT} WHERE c.id = ?`).get(id) as ConvRow | undefined
    return r ? toConv(r) : null
  }

  createConversation(botId: string, title = 'New chat'): Conversation {
    const t = now()
    const conv: Conversation = {
      id: randomUUID(), botId, title, preview: '', createdAt: t, updatedAt: t,
      lastMessageAt: null, kind: 'direct',
    }
    this.db
      .prepare(
        `INSERT INTO conversations (id,bot_id,title,created_at,updated_at,last_message_at,provider_session_id)
         VALUES (@id,@botId,@title,@createdAt,@updatedAt,NULL,NULL)`,
      )
      .run(conv)
    return conv
  }

  setConversationTitle(id: string, title: string): Conversation | null {
    this.db.prepare('UPDATE conversations SET title = ?, updated_at = ? WHERE id = ?').run(title, now(), id)
    return this.getConversation(id)
  }

  /**
   * The warm session a bot holds in a conversation, so a restart can resume it.
   *
   * Keyed the way the adapters key theirs — by conversation and bot — because a room
   * has one session per member. The provider travels with it so a bot's id is never
   * offered to a different runtime.
   */
  getProviderSession(conversationId: string, botId: string): { provider: string; sessionId: string } | null {
    const r = this.db
      .prepare('SELECT provider, session_id FROM provider_sessions WHERE conversation_id = ? AND bot_id = ?')
      .get(conversationId, botId) as { provider: string; session_id: string } | undefined
    return r ? { provider: r.provider, sessionId: r.session_id } : null
  }

  clearProviderSession(conversationId: string, botId: string): void {
    this.db.prepare('DELETE FROM provider_sessions WHERE conversation_id = ? AND bot_id = ?').run(conversationId, botId)
  }

  setProviderSession(conversationId: string, botId: string, provider: string, sessionId: string): void {
    this.db
      .prepare(
        `INSERT INTO provider_sessions (conversation_id, bot_id, provider, session_id, updated_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(conversation_id, bot_id) DO UPDATE SET
           provider = excluded.provider, session_id = excluded.session_id, updated_at = excluded.updated_at`,
      )
      .run(conversationId, botId, provider, sessionId, now())
  }

  // --------------------------------------------------------------- messages

  listMessages(conversationId: string, limit = 100, before?: number): Message[] {
    const rows = before
      ? (this.db
          .prepare('SELECT * FROM messages WHERE conversation_id = ? AND created_at < ? ORDER BY created_at DESC LIMIT ?')
          .all(conversationId, before, limit) as MsgRow[])
      : (this.db
          .prepare('SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at DESC LIMIT ?')
          .all(conversationId, limit) as MsgRow[])
    return rows.map(toMsg).reverse() // query is newest-first; the UI wants oldest-first
  }

  getMessage(id: string): Message | null {
    const r = this.db.prepare('SELECT * FROM messages WHERE id = ?').get(id) as MsgRow | undefined
    return r ? toMsg(r) : null
  }

  /** Used when a bot in a room chooses to say nothing. */
  deleteMessage(id: string): void {
    this.db.prepare('DELETE FROM messages WHERE id = ?').run(id)
  }

  insertMessage(input: {
    id?: string; conversationId: string; role: Role; blocks: Block[]
    providerMeta?: Record<string, unknown> | null
    /** Which bot wrote it. Null for a person, and for a one-bot chat. */
    botId?: string | null
  }): Message {
    const msg: Message = {
      id: input.id ?? randomUUID(),
      conversationId: input.conversationId,
      role: input.role,
      blocks: input.blocks,
      providerMeta: input.providerMeta ?? null,
      botId: input.botId ?? null,
      createdAt: now(),
    }
    this.db.transaction(() => {
      this.db
        .prepare(
          `INSERT INTO messages (id,conversation_id,role,blocks_json,provider_meta_json,created_at,bot_id)
           VALUES (?,?,?,?,?,?,?)`,
        )
        .run(
          msg.id,
          msg.conversationId,
          msg.role,
          JSON.stringify(msg.blocks),
          msg.providerMeta ? JSON.stringify(msg.providerMeta) : null,
          msg.createdAt,
          msg.botId,
        )
      this.db
        .prepare('UPDATE conversations SET last_message_at = ?, updated_at = ? WHERE id = ?')
        .run(msg.createdAt, msg.createdAt, msg.conversationId)
    })()
    return msg
  }

  /** Called once a streamed assistant turn finishes, to persist its final form. */
  /**
   * Removes assistant rows a dead turn left empty.
   *
   * A turn inserts its row empty and fills it as it ends, so a daemon that restarts
   * mid-turn — a crash, an upgrade, a developer saving a file — leaves a bubble with
   * nothing in it, forever, in someone's transcript. Nothing can finish that turn now;
   * the row is debris. Run at boot, before any client loads.
   */
  deleteEmptyAssistantMessages(): number {
    const result = this.db
      .prepare("DELETE FROM messages WHERE role = 'assistant' AND blocks_json = '[]'")
      .run()
    return result.changes
  }

  updateMessageBlocks(id: string, blocks: Block[], providerMeta?: Record<string, unknown> | null): void {
    this.db
      .prepare('UPDATE messages SET blocks_json = ?, provider_meta_json = ? WHERE id = ?')
      .run(JSON.stringify(blocks), providerMeta ? JSON.stringify(providerMeta) : null, id)
  }

  // --------------------------------------------------------------- settings

  getSettings(): Record<string, unknown> {
    const rows = this.db.prepare('SELECT key, value_json FROM settings').all() as { key: string; value_json: string }[]
    return Object.fromEntries(rows.map((r) => [r.key, JSON.parse(r.value_json)]))
  }

  setSettings(patch: Record<string, unknown>): Record<string, unknown> {
    const stmt = this.db.prepare('INSERT INTO settings (key,value_json) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json')
    this.db.transaction(() => {
      for (const [k, v] of Object.entries(patch)) stmt.run(k, JSON.stringify(v))
    })()
    return this.getSettings()
  }
}
