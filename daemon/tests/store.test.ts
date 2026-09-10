import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { openDb } from '../src/db/schema.js'
import { Store } from '../src/db/store.js'

test('bot, transcript, and provider session survive reopening the database', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'routi-store-test-'))
  const path = join(dir, 'routi.db')
  let db = openDb(path)
  t.after(() => {
    db.close()
    rmSync(dir, { recursive: true, force: true })
  })
  const store = new Store(db)
  store.ensureDefaultProfile()
  const { bot, conversation } = store.createBot({ name: 'Scout', provider: 'fake' })
  const message = store.insertMessage({
    conversationId: conversation.id, role: 'user', blocks: [{ type: 'text', text: 'Find a hotel' }],
  })
  store.setProviderSession(conversation.id, bot.id, 'fake', 'saved-session')
  db.close()

  db = openDb(path)
  const reopened = new Store(db)
  reopened.ensureDefaultProfile()
  assert.deepEqual(reopened.getBot(bot.id), bot)
  assert.equal(reopened.getConversation(conversation.id)?.botId, bot.id)
  assert.deepEqual(reopened.listMessages(conversation.id), [message])
  assert.deepEqual(reopened.getProviderSession(conversation.id, bot.id), {
    provider: 'fake', sessionId: 'saved-session',
  })
  assert.equal(reopened.listProfiles().length, 1)
})

test('deleting a bot removes its conversation and notes but preserves shared memory', (t) => {
  const db = openDb(':memory:')
  t.after(() => db.close())
  const store = new Store(db)
  store.ensureDefaultProfile()
  const { bot, conversation } = store.createBot({ name: 'Scout' })
  const message = store.insertMessage({ conversationId: conversation.id, role: 'user', blocks: [] })
  const own = store.addMemory({ botId: bot.id, scope: 'bot', text: 'Watch hotel prices', source: 'bot' })
  const shared = store.addMemory({ botId: bot.id, scope: 'user', text: 'Prefers trains', source: 'bot' })

  assert.equal(store.deleteBot(bot.id), true)
  assert.equal(store.getConversation(conversation.id), null)
  assert.equal(store.getMessage(message.id), null)
  assert.equal(store.getMemory(own.id), null)
  assert.deepEqual(store.listSharedMemories(), [shared])
})

test('startup cleanup removes empty assistant replies but keeps saved content and user messages', (t) => {
  const db = openDb(':memory:')
  t.after(() => db.close())
  const store = new Store(db)
  store.ensureDefaultProfile()
  const { conversation } = store.createBot({ name: 'Scout' })
  const user = store.insertMessage({ conversationId: conversation.id, role: 'user', blocks: [] })
  const empty = store.insertMessage({ conversationId: conversation.id, role: 'assistant', blocks: [] })
  const partial = store.insertMessage({
    conversationId: conversation.id, role: 'assistant', blocks: [{ type: 'text', text: 'Found a hotel' }],
  })

  assert.equal(store.deleteEmptyAssistantMessages(), 1)
  assert.equal(store.getMessage(empty.id), null)
  assert.deepEqual(store.getMessage(user.id), user)
  assert.deepEqual(store.getMessage(partial.id), partial)
})
