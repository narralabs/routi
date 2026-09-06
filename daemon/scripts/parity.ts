/**
 * Does every runtime actually do the same things?
 *
 * Routi's promise is that a bot's abilities come from Routi, not from whoever answers it
 * — but each runtime reaches its tools by a different road: in-process MCP for Claude,
 * function schemas for the OpenAI-compatible providers, an HTTP MCP server for Codex.
 * Roads drift. Codex bots silently had no routine tools for a day because the HTTP
 * server was built without them, and nothing failed loudly enough to notice; a user
 * asked a bot to check something daily and was told it could not.
 *
 * So this asks each configured provider to do the same handful of things and prints
 * what happened. It spends real tokens and takes a few minutes, which is the price of
 * an answer that is true rather than assumed.
 *
 * Run: pnpm --filter routid parity
 */
import WebSocket from 'ws'
import { PROTOCOL_VERSION } from '@routi/protocol'
import { randomUUID } from 'node:crypto'
import { execSync } from 'node:child_process'
import { homedir } from 'node:os'
import { join } from 'node:path'

const URL = process.env['ROUTI_URL'] ?? 'ws://127.0.0.1:7171'
const DB = join(homedir(), '.routi', 'routi.db')

interface Check {
  name: string
  /** What to say to the bot. */
  say: string
  /** Did it work? Given everything the bot did and said. */
  passed(ctx: { text: string; tools: string[]; botId: string }): boolean
  /** Only run where the bot has a screen. */
  needsScreen?: boolean
}

const CHECKS: Check[] = [
  {
    name: 'answers',
    say: 'Reply with exactly the word READY and nothing else.',
    passed: ({ text }) => /ready/i.test(text),
  },
  {
    name: 'browses',
    say: 'Open https://example.com on your screen, read the page, and quote its exact heading.',
    needsScreen: true,
    passed: ({ text, tools }) =>
      /example domain/i.test(text) && tools.some((t) => t.includes('read_page') || t.includes('open_url')),
  },
  {
    name: 'saves a routine',
    say: 'Check the price of the GE Opal ice maker every day at 9am and tell me if it drops.',
    passed: ({ botId }) =>
      query(`select count(*) from routines where bot_id='${botId}'`) !== '0',
  },
  {
    name: 'says its own name',
    say: 'In one short sentence, what are you for?',
    // The identity rule: a bot describes its job, not the tools it happens to hold.
    passed: ({ text }) => !/mcp|tool|connector|anthropic|openai|codex/i.test(text),
  },
]

function query(sql: string): string {
  return execSync(`sqlite3 "${DB}" "${sql}"`, { shell: '/bin/bash' }).toString().trim()
}

class Client {
  private ws!: WebSocket
  private readonly pending = new Map<string, (v: any) => void>()
  events: any[] = []

  async connect(): Promise<void> {
    this.ws = new WebSocket(URL)
    await new Promise<void>((resolve, reject) => {
      this.ws.once('open', () => resolve())
      this.ws.once('error', reject)
    })
    this.ws.on('message', (raw) => {
      const m = JSON.parse(String(raw))
      if (m.t === 'rpc_ok' || m.t === 'rpc_err') this.pending.get(m.id)?.(m)
      if (m.t === 'event') this.events.push(m.event ?? m)
    })
    this.ws.send(JSON.stringify({
      t: 'hello', protocolVersion: PROTOCOL_VERSION, clientName: 'parity', platform: 'parity',
    }))
    await wait(400)
  }

  rpc(method: string, params: unknown = {}): Promise<any> {
    const id = randomUUID()
    return new Promise((resolve) => {
      this.pending.set(id, resolve)
      this.ws.send(JSON.stringify({ t: 'rpc', id, method, params }))
    })
  }

  subscribe(conversationId: string): void {
    this.ws.send(JSON.stringify({ t: 'subscribe', conversationId }))
  }

  close(): void { this.ws.close() }
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms))

async function main(): Promise<void> {
  const client = new Client()
  await client.connect()

  const auth = (await client.rpc('auth.status')).result?.auth
  const providers = [
    ...(auth?.configured ? ['anthropic'] : []),
    ...Object.entries(auth?.providers ?? {})
      .filter(([, p]: [string, any]) => p.configured)
      .map(([id]) => id),
  ]
  if (providers.length === 0) {
    console.log('No providers are connected. Connect at least one in Settings, then run this again.')
    process.exit(1)
  }

  console.log(`Checking ${providers.length} provider(s): ${providers.join(', ')}\n`)
  const results: Record<string, Record<string, string>> = {}

  for (const provider of providers) {
    results[provider] = {}
    const models = (await client.rpc('models.list', { provider })).result
    const model = models?.models?.[0]?.id ?? 'default'
    const canScreen = models?.supportsSurface === true

    const made = await client.rpc('bots.create', {
      name: `Parity ${provider}`,
      systemPrompt: 'You track the price of the GE Opal nugget ice maker for William.',
      provider, model, surfaceMode: canScreen ? 'container' : 'none',
    })
    if (made.t === 'rpc_err') {
      results[provider]['bot'] = `could not create: ${made.error?.message ?? 'unknown'}`
      continue
    }
    const { bot, conversation } = made.result
    client.subscribe(conversation.id)
    await settle(client)

    for (const check of CHECKS) {
      if (check.needsScreen && !canScreen) {
        results[provider][check.name] = 'n/a'
        continue
      }
      client.events = []
      await client.rpc('messages.send', {
        conversationId: conversation.id, blocks: [{ type: 'text', text: check.say }],
      })
      await settle(client)

      const text = client.events
        .filter((e) => e.e === 'message.delta')
        .map((e) => e.delta?.text ?? '')
        .join('')
      const tools = client.events
        .filter((e) => e.e === 'message.block' && e.block?.type === 'tool_use')
        .map((e) => e.block.name)

      let passed = false
      try {
        passed = check.passed({ text, tools, botId: bot.id })
      } catch {
        passed = false
      }
      results[provider][check.name] = passed ? 'pass' : 'FAIL'
      process.stdout.write(`  ${provider} · ${check.name}: ${passed ? 'pass' : 'FAIL'}\n`)
    }

    await client.rpc('bots.delete', { id: bot.id })
  }

  console.log('\n' + table(providers, results))
  client.close()

  const failed = Object.values(results).some((row) => Object.values(row).includes('FAIL'))
  process.exit(failed ? 1 : 0)
}

/** Waits for the turn in flight to finish, or gives up. */
async function settle(client: Client, seconds = 240): Promise<void> {
  for (let i = 0; i < seconds; i++) {
    if (client.events.some((e) => e.e === 'message.completed')) return
    await wait(1000)
  }
}

function table(providers: string[], results: Record<string, Record<string, string>>): string {
  const checks = CHECKS.map((c) => c.name)
  const width = Math.max(...providers.map((p) => p.length), 8)
  const header = ['provider'.padEnd(width), ...checks.map((c) => c.padEnd(16))].join(' ')
  const rows = providers.map((p) =>
    [p.padEnd(width), ...checks.map((c) => (results[p]?.[c] ?? '—').padEnd(16))].join(' '),
  )
  return [header, '-'.repeat(header.length), ...rows].join('\n')
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
