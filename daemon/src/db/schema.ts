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
