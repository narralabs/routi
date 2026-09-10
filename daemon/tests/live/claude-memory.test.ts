/**
 * LIVE INTEGRATION TEST — uses your signed-in Claude account and consumes usage.
 * Not included in pnpm test or CI. Uses a temporary Routi database and HTTP server;
 * Claude may retain test sessions in its own local session history.
 *
 * Memory and resume, driven through the real Claude Code adapter.
 *
 * Three turns, three claims:
 *
 *   1. A bot with no screen can still save a note — the tool server is mounted for
 *      every bot, not only the ones with a desktop.
 *   2. A new adapter handed the last turn's session id resumes the thread: it answers
 *      from context with no history replayed.
 *   3. A new adapter handed a dead session id falls back rather than failing: the
 *      resume error is caught before the bot has spoken, the session is rebuilt blank,
 *      and the transcript from the database leads the turn.
 *
 * Run: pnpm --filter routid test:live:claude-memory
 */
import { createServer } from 'node:http'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { Message } from '@routi/protocol'
import { AnthropicSubscriptionAdapter } from '../../src/providers/anthropic-subscription.js'
import type { ChatRequest, ProviderEvent } from '../../src/providers/types.js'
import { openDb } from '../../src/db/schema.js'
import { Store } from '../../src/db/store.js'
import { McpHttp } from '../../src/server/mcp-http.js'
import { DesktopPool } from '../../src/surfaces/pool.js'
import { Handovers } from '../../src/surfaces/handover.js'
import { memoryTools } from '../../src/sessions/memory-tools.js'

if (process.env.ROUTI_LIVE_TESTS !== '1') {
  throw new Error('Live account usage requires the explicit test:live:claude-memory command.')
}

delete process.env.ANTHROPIC_API_KEY

const cwd = mkdtempSync(join(tmpdir(), 'routi-live-memory-test-'))
const db = openDb(':memory:')
const store = new Store(db)
store.ensureDefaultProfile()
const { bot, conversation } = store.createBot({ name: 'Spike', surfaceMode: 'none' })
const memory = memoryTools(store, bot.id, () => {})
const mcp = new McpHttp(new DesktopPool(cwd, store), store, new Handovers(() => {}), () => {}, () => {})
const server = createServer((req, res) => { void mcp.handle(req, res) })
let mcpBaseUrl: string

const systemPrompt = [
  'Your name is Spike. You are a terse assistant in a chat app.',
  'You keep notes with the remember tool. When asked to remember something, call it, then answer in one short line.',
].join('\n')

async function turn(
  adapter: AnthropicSubscriptionAdapter,
  text: string,
  extra: Partial<ChatRequest> = {},
): Promise<{ text: string; tools: string[]; errors: string[]; sessionId: string | null }> {
  const out = { text: '', tools: [] as string[], errors: [] as string[], sessionId: null as string | null }
  const req: ChatRequest = {
    conversationId: conversation.id,
    botId: bot.id,
    systemPrompt,
    model: 'haiku',
    history: [],
    input: [{ type: 'text', text }],
    hasSurface: false,
    toolContext: { memory },
    ...extra,
  }
  for await (const ev of adapter.stream(req, new AbortController().signal)) {
    const e = ev as ProviderEvent
    if (e.type === 'text_delta') out.text += e.text
    if (e.type === 'block_start' && e.block.type === 'tool_use') out.tools.push(e.block.name)
    if (e.type === 'error') out.errors.push(`${e.code}: ${e.message}`)
    if (e.type === 'done') out.sessionId = (e.meta['sessionId'] as string | undefined) ?? null
  }
  return out
}

function check(label: string, ok: boolean, detail: string): void {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? `  — ${detail}` : ''}`)
  if (!ok) process.exitCode = 1
}

async function main(): Promise<void> {
  // 1. Screenless bot saves a note.
  const a = new AnthropicSubscriptionAdapter({ cwd, mcpBaseUrl })
  const first = await turn(a, 'Remember that my favourite bird is the pelican. Then say "noted".')
  check('screenless bot called remember', first.tools.some((t) => t.endsWith('remember')), first.tools.join(', ') || 'no tool calls')
  const notes = [...store.listMemories(bot.id), ...store.listSharedMemories()]
  check('the note landed', notes.some((n) => /pelican/i.test(n.text)), JSON.stringify(notes))
  check('a session id was reported', first.sessionId !== null, first.sessionId ?? 'none')
  a.dispose()
  const sessionId = first.sessionId
  if (!sessionId) return

  // 2. Resume by id, no history.
  const b = new AnthropicSubscriptionAdapter({ cwd, mcpBaseUrl })
  const second = await turn(b, 'What is my favourite bird? Answer with the one word.', { resumeSessionId: sessionId })
  check('resumed session remembers the thread', /pelican/i.test(second.text), `${second.text.trim()} ${second.errors.join('; ')}`)
  b.dispose()

  // 3. Dead id, transcript in history.
  const history: Message[] = [
    { id: 'm1', conversationId: conversation.id, botId: null, role: 'user', providerMeta: null, createdAt: 1,
      blocks: [{ type: 'text', text: 'My favourite bird is the pelican.' }] },
    { id: 'm2', conversationId: conversation.id, botId: bot.id, role: 'assistant', providerMeta: null, createdAt: 2,
      blocks: [{ type: 'text', text: 'Noted.' }] },
  ]
  const c = new AnthropicSubscriptionAdapter({ cwd, mcpBaseUrl })
  const third = await turn(c, 'What is my favourite bird? Answer with the one word.', {
    resumeSessionId: '11111111-2222-3333-4444-555555555555',
    history,
  })
  check('dead resume id surfaced no error to the turn', third.errors.length === 0, third.errors.join('; '))
  check('fallback replayed the transcript', /pelican/i.test(third.text), third.text.trim())
  c.dispose()
}

await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
const address = server.address()
if (!address || typeof address === 'string') throw new Error('No HTTP address')
mcpBaseUrl = `http://127.0.0.1:${address.port}`
main().catch((err) => {
  console.error(err)
  process.exitCode = 1
}).finally(() => {
  server.close()
  server.closeAllConnections()
  db.close()
  rmSync(cwd, { recursive: true, force: true })
})
