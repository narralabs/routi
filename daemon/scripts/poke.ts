/**
 * Sends a message to the running daemon so the live app renders the reply.
 *
 * Unlike probe.ts (which spawns its own throwaway daemon), this talks to whatever is
 * already on :7171 — it's how you verify the client's streaming render path without
 * driving the UI.
 *
 * Usage: pnpm --filter routid poke "your message"
 */
import { randomUUID } from 'node:crypto'
import WebSocket from 'ws'
import { PROTOCOL_VERSION, type ServerMessage } from '@routi/protocol'

const text = process.argv.slice(2).join(' ') || 'Say hello in one short sentence.'
const port = Number(process.env['ROUTI_PORT'] ?? 7171)
const ws = new WebSocket(`ws://127.0.0.1:${port}`)

const pending = new Map<string, (v: Record<string, unknown>) => void>()

function rpc(method: string, params: unknown = {}): Promise<Record<string, unknown>> {
  const id = randomUUID()
  return new Promise((resolve) => {
    pending.set(id, resolve)
    ws.send(JSON.stringify({ t: 'rpc', id, method, params }))
  })
}

ws.on('open', () => {
  ws.send(JSON.stringify({ t: 'hello', protocolVersion: PROTOCOL_VERSION, clientName: 'poke', platform: 'probe' }))
})

ws.on('message', async (raw) => {
  const msg = JSON.parse(String(raw)) as ServerMessage

  if (msg.t === 'rpc_ok') {
    pending.get(msg.id)?.(msg.result as Record<string, unknown>)
    pending.delete(msg.id)
    return
  }
  if (msg.t === 'rpc_err') {
    console.error(`  error: ${msg.error.code}: ${msg.error.message}`)
    process.exit(1)
  }
  if (msg.t !== 'hello_ok') return

  // Pick the most recently active conversation — the one the app is showing.
  const { conversations } = (await rpc('conversations.list')) as {
    conversations: { id: string; botId: string; title: string; lastMessageAt: number | null }[]
  }
  if (conversations.length === 0) {
    console.error('  no conversations on this daemon')
    process.exit(1)
  }
  const target = conversations[0]!
  const { bots } = (await rpc('bots.list')) as { bots: { id: string; name: string }[] }
  const bot = bots.find((b) => b.id === target.botId)

  console.log(`  -> ${bot?.name ?? target.botId}: ${JSON.stringify(text)}`)
  ws.send(JSON.stringify({ t: 'subscribe', conversationId: target.id }))
  await rpc('messages.send', { conversationId: target.id, blocks: [{ type: 'text', text }] })
  console.log('  sent; watch the app render it')
  setTimeout(() => process.exit(0), 1500)
})

ws.on('error', (err) => {
  console.error('  could not reach routid:', err.message)
  process.exit(1)
})
