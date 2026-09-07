import Database from 'better-sqlite3'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

/**
 * Migrations are an append-only list. Each entry runs once, in order, inside a
 * transaction, tracked by PRAGMA user_version. Never edit a shipped migration —
 * add a new one.
 */
const MIGRATIONS: string[] = [
  // 1 — initial schema
  `
  CREATE TABLE bots (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    avatar_color  TEXT NOT NULL,
    system_prompt TEXT NOT NULL DEFAULT '',
    provider      TEXT NOT NULL DEFAULT 'anthropic',
    model         TEXT NOT NULL DEFAULT 'default',
    effort        TEXT,
    surface_mode  TEXT NOT NULL DEFAULT 'none',
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL,
    archived_at   INTEGER
  );

  CREATE TABLE conversations (
    id              TEXT PRIMARY KEY,
    bot_id          TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    title           TEXT NOT NULL DEFAULT '',
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL,
    last_message_at INTEGER
  );
  CREATE INDEX idx_conversations_bot ON conversations(bot_id, last_message_at DESC);

  CREATE TABLE messages (
    id              TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role            TEXT NOT NULL,
    blocks_json     TEXT NOT NULL,
    provider_meta_json TEXT,
    created_at      INTEGER NOT NULL
  );
  CREATE INDEX idx_messages_conversation ON messages(conversation_id, created_at);

  CREATE TABLE settings (
    key        TEXT PRIMARY KEY,
    value_json TEXT NOT NULL
  );

  CREATE TABLE devices (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    token_hash  TEXT NOT NULL,
    paired_at   INTEGER NOT NULL,
    last_seen_at INTEGER
  );

  CREATE TABLE surface_sessions (
    id           TEXT PRIMARY KEY,
    bot_id       TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    kind         TEXT NOT NULL,
    container_id TEXT,
    status       TEXT NOT NULL,
    started_at   INTEGER NOT NULL
  );
  `,

  // 2 — per-conversation provider session ids, so a warm agent session survives a
  //     daemon restart via resume instead of losing the thread.
  `
  ALTER TABLE conversations ADD COLUMN provider_session_id TEXT;
  `,
  /**
   * Rooms: several bots and a person in one transcript.
   *
   * A channel is a conversation with more than one bot in it, so it reuses the
   * conversations table rather than duplicating messages and ordering. `bot_id`
   * becomes nullable — a room belongs to its members, not to one bot — and members
   * live in their own table.
   *
   * Messages gain an author. `role` only ever said user or assistant, which is enough
   * for a 1:1 and useless in a room: four bots all write as "assistant".
   */
  `
  CREATE TABLE channel_members (
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    bot_id          TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    joined_at       INTEGER NOT NULL,
    PRIMARY KEY (conversation_id, bot_id)
  );
  CREATE INDEX idx_channel_members_bot ON channel_members(bot_id);

  ALTER TABLE messages ADD COLUMN bot_id TEXT REFERENCES bots(id) ON DELETE SET NULL;
  ALTER TABLE conversations ADD COLUMN kind TEXT NOT NULL DEFAULT 'direct';

  -- SQLite cannot drop a NOT NULL, so the table is rebuilt to let a room have no
  -- single owner. Everything else is carried across unchanged.
  CREATE TABLE conversations_new (
    id              TEXT PRIMARY KEY,
    bot_id          TEXT REFERENCES bots(id) ON DELETE CASCADE,
    title           TEXT NOT NULL DEFAULT '',
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL,
    last_message_at INTEGER,
    provider_session_id TEXT,
    kind            TEXT NOT NULL DEFAULT 'direct'
  );
  INSERT INTO conversations_new
    SELECT id, bot_id, title, created_at, updated_at, last_message_at, provider_session_id, kind
    FROM conversations;
  DROP TABLE conversations;
  ALTER TABLE conversations_new RENAME TO conversations;
  CREATE INDEX idx_conversations_bot ON conversations(bot_id, last_message_at DESC);
  `,

  /**
   * Routines: a saved prompt and when to run it.
   *
   * The schedule is stored structured rather than as a cron string. A bot writes these
   * itself, and "0 9 * * 1-5" is a format models get subtly wrong — an off-by-one in a
   * weekday field is a routine that fires on the wrong day forever, silently.
   *
   * `next_run_at` is computed on write and after each run, so finding due work is an
   * index scan rather than parsing every row on every tick.
   */
  `
  CREATE TABLE routines (
    id              TEXT PRIMARY KEY,
    bot_id          TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    prompt          TEXT NOT NULL,
    schedule_json   TEXT NOT NULL,
    enabled         INTEGER NOT NULL DEFAULT 1,
    created_at      INTEGER NOT NULL,
    last_run_at     INTEGER,
    next_run_at     INTEGER
  );
  CREATE INDEX idx_routines_due ON routines(enabled, next_run_at);
  CREATE INDEX idx_routines_bot ON routines(bot_id);
  `,

  /**
   * Memory: the notes a bot keeps, and whose warm session belongs to whom.
   *
   * A note is one row rather than a line in one blob, so a bot can add or drop a single
   * fact without rewriting everything it knows — a model asked to retype a whole page
   * to change one line quietly loses lines. Notes belong to a bot, not a conversation:
   * they are the part that is meant to outlive the transcript. `scope` is `bot` for a
   * bot's own notes and `user` for facts about the person that every bot reads — a name,
   * a timezone — which have no bot and so survive any one bot's deletion.
   *
   * `provider_sessions` replaces the single `provider_session_id` on a conversation.
   * That column dated from one bot per conversation; a room has several, each with its
   * own warm session, and one column meant the last bot to finish overwrote the rest and
   * the next restart resumed a teammate's thread. Keyed by conversation and bot, which
   * is what the adapters already key their sessions by. The old column stays, unused.
   */
  `
  CREATE TABLE memories (
    id         TEXT PRIMARY KEY,
    bot_id     TEXT REFERENCES bots(id) ON DELETE CASCADE,
    scope      TEXT NOT NULL DEFAULT 'bot',
    text       TEXT NOT NULL,
    source     TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  );
  CREATE INDEX idx_memories_bot ON memories(bot_id, created_at);
  CREATE INDEX idx_memories_scope ON memories(scope, created_at);

  CREATE TABLE provider_sessions (
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    bot_id          TEXT NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    provider        TEXT NOT NULL,
    session_id      TEXT NOT NULL,
    updated_at      INTEGER NOT NULL,
    PRIMARY KEY (conversation_id, bot_id)
  );
  INSERT INTO provider_sessions (conversation_id, bot_id, provider, session_id, updated_at)
    SELECT c.id, c.bot_id, b.provider, c.provider_session_id, c.updated_at
    FROM conversations c JOIN bots b ON b.id = c.bot_id
    WHERE c.provider_session_id IS NOT NULL AND c.bot_id IS NOT NULL;
  `,

]

export function openDb(path: string): Database.Database {
  mkdirSync(dirname(path), { recursive: true })
  const db = new Database(path)
  db.pragma('journal_mode = WAL')
  db.pragma('foreign_keys = ON')
  db.pragma('busy_timeout = 5000')
  migrate(db)
  return db
}

function migrate(db: Database.Database): void {
  const current = db.pragma('user_version', { simple: true }) as number
  for (let v = current; v < MIGRATIONS.length; v++) {
    const sql = MIGRATIONS[v]!
    db.transaction(() => {
      db.exec(sql)
      // user_version does not accept a bound parameter.
      db.pragma(`user_version = ${v + 1}`)
    })()
  }
}
