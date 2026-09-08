/**
 * End-to-end protocol probe.
 *
 * Drives routid over the real WebSocket exactly as the Flutter client will, so the
 * protocol and the streaming path can be verified without any UI. Also asserts the
 * durability property that matters most: a conversation survives a daemon restart.
 *
 * Run: pnpm --filter routid probe
 */
import { spawn, type ChildProcess } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import WebSocket from 'ws'
import { PROTOCOL_VERSION, type ServerEvent, type ServerMessage } from '@routi/protocol'

const PORT = 7399
const WS_URL = `ws://127.0.0.1:${PORT}`
const DATA_DIR = mkdtempSync(join(tmpdir(), 'routi-probe-'))

let failures = 0
function check(label: string, ok: boolean, detail = ''): void {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? `  (${detail})` : ''}`)
  if (!ok) failures++
}

// ------------------------------------------------------------------- client

class ProbeClient {
  private ws!: WebSocket
  private readonly pending = new Map<string, { resolve: (v: unknown) => void; reject: (e: Error) => void }>()
  readonly events: ServerEvent[] = []
  private listeners: ((e: ServerEvent) => void)[] = []

  async connect(): Promise<ServerMessage> {
    this.ws = new WebSocket(WS_URL)
    await new Promise<void>((resolve, reject) => {
      this.ws.once('open', resolve)
      this.ws.once('error', reject)
    })
    const helloed = this.nextOfType('hello_ok')
    this.ws.on('message', (raw) => this.onMessage(String(raw)))
    this.ws.send(JSON.stringify({
      t: 'hello', protocolVersion: PROTOCOL_VERSION, clientName: 'probe', platform: 'probe',
    }))
    return helloed
  }

  private helloResolvers: ((m: ServerMessage) => void)[] = []
  private nextOfType(t: string): Promise<ServerMessage> {
    return new Promise((resolve) => {
      this.helloResolvers.push((m) => {
        if (m.t === t) resolve(m)
      })
    })
  }

  private onMessage(raw: string): void {
    const msg = JSON.parse(raw) as ServerMessage
    for (const r of this.helloResolvers) r(msg)
    if (msg.t === 'rpc_ok') {
      this.pending.get(msg.id)?.resolve(msg.result)
      this.pending.delete(msg.id)
    } else if (msg.t === 'rpc_err') {
      this.pending.get(msg.id)?.reject(new Error(`${msg.error.code}: ${msg.error.message}`))
      this.pending.delete(msg.id)
    } else if (msg.t === 'event') {
      this.events.push(msg.event)
      for (const l of this.listeners) l(msg.event)
    }
  }

  rpc<T = unknown>(method: string, params: unknown = {}): Promise<T> {
    const id = randomUUID()
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject })
      this.ws.send(JSON.stringify({ t: 'rpc', id, method, params }))
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`RPC timed out: ${method}`))
      }, 120_000)
    })
  }

  subscribe(conversationId: string): void {
    this.ws.send(JSON.stringify({ t: 'subscribe', conversationId }))
  }

  waitFor(pred: (e: ServerEvent) => boolean, timeoutMs = 120_000): Promise<ServerEvent> {
    const existing = this.events.find(pred)
    if (existing) return Promise.resolve(existing)
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('timed out waiting for event')), timeoutMs)
      const l = (e: ServerEvent) => {
        if (pred(e)) {
          clearTimeout(timer)
          this.listeners = this.listeners.filter((x) => x !== l)
          resolve(e)
        }
      }
      this.listeners.push(l)
    })
  }

  close(): void {
    this.ws.close()
  }
}

// ------------------------------------------------------------------ daemon

const DAEMON_DIR = fileURLToPath(new URL('..', import.meta.url))
const TSX_CLI = createRequire(import.meta.url).resolve('tsx/cli')

function startDaemon(): Promise<ChildProcess> {
  const env: NodeJS.ProcessEnv = { ...process.env, ROUTI_DATA_DIR: DATA_DIR, ROUTI_PORT: String(PORT) }
  // Prove the subscription path, never a stray key in the developer's shell.
  delete env['ANTHROPIC_API_KEY']

  const child = spawn(process.execPath, [TSX_CLI, 'src/index.ts'], {
    cwd: DAEMON_DIR,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('daemon did not start in time')), 30_000)
    child.stdout!.on('data', (b: Buffer) => {
      const s = b.toString()
      if (process.env['PROBE_VERBOSE']) process.stdout.write(`    [routid] ${s}`)
      if (s.includes('listening on')) {
        clearTimeout(timer)
        resolve(child)
      }
    })
    child.stderr!.on('data', (b: Buffer) => process.stderr.write(`    [routid!] ${b}`))
    child.on('exit', (code) => reject(new Error(`daemon exited early with code ${code}`)))
  })
}

async function stopDaemon(child: ChildProcess): Promise<void> {
  child.removeAllListeners('exit')
  child.kill('SIGTERM')
  await new Promise<void>((r) => child.once('exit', () => r()))
}

// -------------------------------------------------------------------- main

async function main(): Promise<void> {
  console.log(`\n  routid protocol probe   (data: ${DATA_DIR})\n`)

  let daemon = await startDaemon()
  let client = new ProbeClient()
  const hello = await client.connect()

  check('handshake completes', hello.t === 'hello_ok')
  if (hello.t === 'hello_ok') {
    check('protocol version matches', hello.protocolVersion === PROTOCOL_VERSION, `v${hello.protocolVersion}`)
    check('daemon reports a credential', !!hello.account.authMode, `${hello.account.authMode} / ${hello.account.subscriptionType ?? '?'}`)
  }

  // --- sign-in --------------------------------------------------------------
  // A fresh data dir has no provider installed: the core starts bare so the app can
  // walk a person through setup. This is that step, against the Claude Code sign-in
  // already on this Mac — nothing interactive happens when one is present.
  const auth = await client.rpc<{ auth: { providers?: Record<string, { configured?: boolean }> } }>(
    'auth.providerLogin', { provider: 'anthropic-claude' },
  )
  check('Claude Code sign-in installs the provider', !!auth.auth)

  // --- bots -----------------------------------------------------------------
  const { bots } = await client.rpc<{ bots: { id: string; name: string }[] }>('bots.list')
  // Nothing is seeded: a fresh install opens onto the empty state, and the first bot is
  // the person's own. A "New Bot" nobody made used to greet them before setup ended.
  check('fresh db has no bots', bots.length === 0, `${bots.length}`)

  const created = await client.rpc<{ bot: { id: string; name: string }; conversation: { id: string } }>('bots.create', {
    name: 'Probe Bot',
    systemPrompt: 'You are terse. Reply in under 12 words.',
    model: 'default',
    provider: 'anthropic-claude',
  })
  check('bots.create returns bot + conversation', !!created.bot.id && !!created.conversation.id)

  const conversationId = created.conversation.id
  client.subscribe(conversationId)

  // The bot greets the moment it is made. Let that finish — busy goes off last, after
  // the completion — so the checks below see exactly one exchange of their own.
  // (Its message.created is missed on purpose: it fires before the subscribe lands,
  // which is why busy is broadcast to everyone.)
  const greeting = await client.waitFor((e) => e.e === 'message.completed')
  await client.waitFor((e) => e.e === 'conversation.busy' && e.conversationId === conversationId && !e.busy)
  check('bot greets on creation', greeting.e === 'message.completed' && greeting.stopReason !== 'error')
  client.events.splice(0)

  // --- streaming ------------------------------------------------------------
  const t0 = Date.now()
  await client.rpc('messages.send', {
    conversationId,
    blocks: [{ type: 'text', text: 'Name one analog synthesizer.' }],
  })

  const completed = await client.waitFor((e) => e.e === 'message.completed')
  const elapsed = Date.now() - t0

  const deltas = client.events.filter((e) => e.e === 'message.delta')
  const busyEvents = client.events.filter((e) => e.e === 'conversation.busy')
  const createdMsgs = client.events.filter((e) => e.e === 'message.created')

  check('user + assistant messages announced', createdMsgs.length === 2, `${createdMsgs.length}`)
  check('text deltas streamed', deltas.length > 0, `${deltas.length} deltas in ${elapsed}ms`)
  check('busy toggled on then off',
    busyEvents.length === 2 && (busyEvents[0] as { busy: boolean }).busy && !(busyEvents[1] as { busy: boolean }).busy,
    busyEvents.map((e) => (e as { busy: boolean }).busy).join(','))
  check('turn completed without error', completed.e === 'message.completed' && completed.stopReason !== 'error',
    completed.e === 'message.completed' ? String(completed.stopReason) : '')

  // Deltas must be addressed by block index, and arrive in order per block.
  const perBlock = new Map<number, string>()
  for (const d of deltas) {
    if (d.e !== 'message.delta') continue
    perBlock.set(d.blockIndex, (perBlock.get(d.blockIndex) ?? '') + d.delta.text)
  }
  const assembled = [...perBlock.entries()].sort((a, b) => a[0] - b[0]).map(([, v]) => v).join('')
  check('deltas assemble into text', assembled.trim().length > 0, JSON.stringify(assembled.slice(0, 60)))

  // --- persistence ----------------------------------------------------------
  const before = await client.rpc<{ messages: { role: string; blocks: unknown[] }[] }>('messages.list', { conversationId })
  check('greeting and both messages persisted', before.messages.length === 3, `${before.messages.length} messages`)
  const storedAssistant = before.messages.find((m) => m.role === 'assistant')
  check('assistant blocks persisted, not empty', (storedAssistant?.blocks.length ?? 0) > 0)

  // --- memory ---------------------------------------------------------------
  const botId = created.bot.id
  const noteEvent = client.waitFor((e) => e.e === 'memory.updated' && e.botId === botId, 10_000)
  const added = await client.rpc<{ memory: { id: string; text: string; source: string } }>('memory.add', {
    botId, text: 'The person collects analog synthesizers.',
  })
  check('memory.add returns the note as the person\'s', added.memory.source === 'user', added.memory.text)
  let announced = true
  try {
    await noteEvent
  } catch {
    announced = false
  }
  check('memory.updated announced to every client', announced)

  const edited = await client.rpc<{ memory: { text: string } }>('memory.update', {
    id: added.memory.id, text: 'The person collects analog synthesizers, mostly Korg.',
  })
  check('memory.update rewrites in place', edited.memory.text.endsWith('Korg.'))

  const shared = await client.rpc<{ memory: { id: string; botId: string | null; scope: string } }>('memory.add', {
    botId, text: 'The person is called Probe.', scope: 'user',
  })
  check('a shared note belongs to no bot', shared.memory.scope === 'user' && shared.memory.botId === null)

  const listed = await client.rpc<{ memories: { id: string; scope: string }[] }>('memory.list', { botId })
  check('memory.list shows own and shared notes',
    listed.memories.length === 2 && listed.memories.some((m) => m.id === added.memory.id),
    listed.memories.map((m) => m.scope).join(','))
  await client.rpc('memory.delete', { id: shared.memory.id })

  // --- restart --------------------------------------------------------------
  client.close()
  await stopDaemon(daemon)
  daemon = await startDaemon()
  client = new ProbeClient()
  await client.connect()
  client.subscribe(conversationId)

  const after = await client.rpc<{ messages: { role: string; blocks: unknown[] }[] }>('messages.list', { conversationId })
  check('conversation survives daemon restart', after.messages.length === before.messages.length,
    `${after.messages.length} messages after restart`)

  const afterBots = await client.rpc<{ bots: unknown[] }>('bots.list')
  check('bots survive daemon restart', afterBots.bots.length === 1, `${afterBots.bots.length} bots`)

  const afterNotes = await client.rpc<{ memories: { id: string }[] }>('memory.list', { botId })
  check('notes survive daemon restart', afterNotes.memories.length === 1)

  // The harness session is resumed by id, so the bot still has the first exchange —
  // without the transcript being replayed from the database.
  const eventsBefore = client.events.length
  await client.rpc('messages.send', {
    conversationId,
    blocks: [{ type: 'text', text: 'Repeat my first question to you, word for word, and nothing else.' }],
  })
  const recalled = await client.waitFor((e, i = client.events.indexOf(e)) => e.e === 'message.completed' && i >= eventsBefore)
  const recalledText = client.events
    .slice(eventsBefore)
    .filter((e): e is Extract<ServerEvent, { e: 'message.delta' }> => e.e === 'message.delta')
    .map((e) => e.delta.text)
    .join('')
  check('bot resumes its thread after restart', recalled.e === 'message.completed' && /analog synthesizer/i.test(recalledText),
    JSON.stringify(recalledText.trim().slice(0, 60)))

  // --- profiles -------------------------------------------------------------
  // A second profile is a second set of connections: it starts signed out of Claude
  // Code even though the Mac's own login is live, sees none of the first profile's
  // bots, and takes bots of its own that the first profile never lists.
  const profiles = await client.rpc<{ profiles: { id: string; name: string }[] }>('profiles.list')
  check('the first profile exists after boot', profiles.profiles.length === 1 && profiles.profiles[0]!.id === 'default',
    profiles.profiles.map((p) => p.name).join(', '))
  const work = await client.rpc<{ profile: { id: string; name: string } }>('profiles.create', { name: 'Probe (Work)' })
  check('profiles.create returns a profile', !!work.profile.id && work.profile.name === 'Probe (Work)')
  const workAuth = await client.rpc<{ auth: { configured: boolean; subscription: { loggedIn: boolean } } }>(
    'auth.status', { profileId: work.profile.id },
  )
  check('a new profile starts signed out of Claude Code', !workAuth.auth.configured && !workAuth.auth.subscription.loggedIn,
    `configured=${workAuth.auth.configured} loggedIn=${workAuth.auth.subscription.loggedIn}`)
  const defaultAuth = await client.rpc<{ auth: { configured: boolean } }>('auth.status', {})
  check('the first profile is still signed in', defaultAuth.auth.configured)
  const workBots = await client.rpc<{ bots: unknown[] }>('bots.list', { profileId: work.profile.id })
  check('a new profile has no bots', workBots.bots.length === 0, `${workBots.bots.length}`)
  const workBot = await client.rpc<{ bot: { id: string; profileId: string } }>('bots.create', {
    name: 'Work Bot', systemPrompt: 'Terse.', model: 'default', provider: 'anthropic-claude', profileId: work.profile.id,
  })
  check('a bot is filed under its profile', workBot.bot.profileId === work.profile.id)
  const defaultBots = await client.rpc<{ bots: unknown[] }>('bots.list', { profileId: 'default' })
  check("the first profile does not list the other's bot", defaultBots.bots.length === 1, `${defaultBots.bots.length}`)
  const renamed = await client.rpc<{ profile: { name: string } }>('profiles.rename', { id: work.profile.id, name: 'Probe (Narra)' })
  check('profiles.rename', renamed.profile.name === 'Probe (Narra)')
  const refused = await client.rpc('profiles.delete', { id: work.profile.id }).then(() => false, () => true)
  check('a profile with bots cannot be deleted', refused)
  await client.rpc('bots.delete', { id: workBot.bot.id })
  await client.rpc('profiles.delete', { id: work.profile.id })
  const left = await client.rpc<{ profiles: unknown[] }>('profiles.list')
  check('an empty profile can be deleted', left.profiles.length === 1)
  const keepFirst = await client.rpc('profiles.delete', { id: 'default' }).then(() => false, () => true)
  check('the first profile cannot be deleted', keepFirst)

  await client.rpc('memory.delete', { id: added.memory.id })
  const gone = await client.rpc<{ memories: unknown[] }>('memory.list', { botId })
  check('memory.delete removes the note', gone.memories.length === 0)

  // --- error handling -------------------------------------------------------
  let rejected = false
  try {
    await client.rpc('messages.send', { conversationId: 'does-not-exist', blocks: [{ type: 'text', text: 'hi' }] })
  } catch {
    rejected = true
  }
  check('unknown conversation is rejected', rejected)

  let badMethod = false
  try {
    await client.rpc('nope.nope')
  } catch (e) {
    badMethod = e instanceof Error && e.message.startsWith('unknown_method')
  }
  check('unknown method returns typed error', badMethod)

  client.close()
  await stopDaemon(daemon)
  rmSync(DATA_DIR, { recursive: true, force: true })

  console.log(`\n  ${failures === 0 ? 'ALL CHECKS PASSED' : `${failures} CHECK(S) FAILED`}\n`)
  process.exit(failures === 0 ? 0 : 1)
}

main().catch((err) => {
  console.error('\n  probe crashed:', err)
  rmSync(DATA_DIR, { recursive: true, force: true })
  process.exit(1)
})
