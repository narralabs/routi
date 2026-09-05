import type Database from 'better-sqlite3'
import { randomUUID } from 'node:crypto'
import type { Block, Bot, Conversation, Message, Role } from '@krog/protocol'

const now = () => Date.now()

/** Grok-Bot-ish avatar palette, assigned round-robin as bots are created. */
const PALETTE = ['#8E8E93', '#FF9500', '#FF3B30', '#34C7A4', '#5AC8FA', '#007AFF', '#4CD964', '#FFCC00', '#AF52DE']

type BotRow = {
  id: string; name: string; avatar_color: string; system_prompt: string
  provider: string; model: string; effort: string | null; surface_mode: string
  created_at: number; updated_at: number; archived_at: number | null
}
type ConvRow = {
  id: string; bot_id: string; title: string
  created_at: number; updated_at: number; last_message_at: number | null
  provider_session_id: string | null
  last_blocks: string | null
}
type MsgRow = {
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
  createdAt: r.created_at,
  updatedAt: r.updated_at,
  archivedAt: r.archived_at,
})

const toConv = (r: ConvRow): Conversation => ({
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
  role: r.role as Role,
  blocks: JSON.parse(r.blocks_json) as Block[],
  providerMeta: r.provider_meta_json ? (JSON.parse(r.provider_meta_json) as Record<string, unknown>) : null,
  createdAt: r.created_at,
})

export class Store {
  constructor(private readonly db: Database.Database) {}

  // ------------------------------------------------------------------- bots

  listBots(includeArchived = false): Bot[] {
    const sql = includeArchived
      ? 'SELECT * FROM bots ORDER BY updated_at DESC'
      : 'SELECT * FROM bots WHERE archived_at IS NULL ORDER BY updated_at DESC'
    return (this.db.prepare(sql).all() as BotRow[]).map(toBot)
  }

  getBot(id: string): Bot | null {
    const r = this.db.prepare('SELECT * FROM bots WHERE id = ?').get(id) as BotRow | undefined
    return r ? toBot(r) : null
  }

  createBot(input: {
    name: string; systemPrompt?: string; model?: string; effort?: Bot['effort']
    avatarColor?: string; surfaceMode?: Bot['surfaceMode']; provider?: string
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
      createdAt: t,
      updatedAt: t,
      archivedAt: null,
    }
    // A bot is useless without somewhere to talk, so create both atomically.
    const conversation = this.db.transaction(() => {
      this.db
        .prepare(
          `INSERT INTO bots (id,name,avatar_color,system_prompt,provider,model,effort,surface_mode,created_at,updated_at,archived_at)
           VALUES (@id,@name,@avatarColor,@systemPrompt,@provider,@model,@effort,@surfaceMode,@createdAt,@updatedAt,NULL)`,
        )
        .run({ ...bot, effort: bot.effort ?? null })
      return this.createConversation(bot.id, 'New chat')
    })()
    return { bot, conversation }
  }

  updateBot(id: string, patch: Partial<Bot>): Bot | null {
    const existing = this.getBot(id)
    if (!existing) return null
    // Provider and model are immutable after creation; pin them regardless of what
    // the caller sent, so the schema and the storage layer agree.
    const next: Bot = {
      ...existing,
      ...patch,
      id: existing.id,
      provider: existing.provider,
      model: existing.model,
      effort: existing.effort,
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
      id: randomUUID(), botId, title, preview: '', createdAt: t, updatedAt: t, lastMessageAt: null,
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

  /** Lets a warm agent session be resumed after a daemon restart. */
  getProviderSessionId(conversationId: string): string | null {
    const r = this.db.prepare('SELECT provider_session_id AS s FROM conversations WHERE id = ?').get(conversationId) as
      | { s: string | null }
      | undefined
    return r?.s ?? null
  }

  setProviderSessionId(conversationId: string, sessionId: string | null): void {
    this.db.prepare('UPDATE conversations SET provider_session_id = ? WHERE id = ?').run(sessionId, conversationId)
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

  insertMessage(input: {
    id?: string; conversationId: string; role: Role; blocks: Block[]; providerMeta?: Record<string, unknown> | null
  }): Message {
    const msg: Message = {
      id: input.id ?? randomUUID(),
      conversationId: input.conversationId,
      role: input.role,
      blocks: input.blocks,
      providerMeta: input.providerMeta ?? null,
      createdAt: now(),
    }
    this.db.transaction(() => {
      this.db
        .prepare(
          `INSERT INTO messages (id,conversation_id,role,blocks_json,provider_meta_json,created_at)
           VALUES (?,?,?,?,?,?)`,
        )
        .run(
          msg.id,
          msg.conversationId,
          msg.role,
          JSON.stringify(msg.blocks),
          msg.providerMeta ? JSON.stringify(msg.providerMeta) : null,
          msg.createdAt,
        )
      this.db
        .prepare('UPDATE conversations SET last_message_at = ?, updated_at = ? WHERE id = ?')
        .run(msg.createdAt, msg.createdAt, msg.conversationId)
    })()
    return msg
  }

  /** Called once a streamed assistant turn finishes, to persist its final form. */
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
