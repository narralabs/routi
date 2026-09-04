import { homedir } from 'node:os'
import { join } from 'node:path'
import { mkdirSync } from 'node:fs'
import { openDb } from './db/schema.js'
import { Store } from './db/store.js'
import { AnthropicSubscriptionAdapter } from './providers/anthropic-subscription.js'
import type { ProviderAdapter } from './providers/types.js'
import { SessionManager } from './sessions/manager.js'
import { KorgServer } from './server/ws.js'

const DATA_DIR = process.env['KORG_DATA_DIR'] ?? join(homedir(), '.korg')
const PORT = Number(process.env['KORG_PORT'] ?? 7171)
// Default to loopback. M2 moves this to the Tailscale interface rather than 0.0.0.0 —
// binding to every interface would expose the daemon on whatever café Wi-Fi is around.
const HOST = process.env['KORG_HOST'] ?? '127.0.0.1'

async function main(): Promise<void> {
  mkdirSync(DATA_DIR, { recursive: true })
  // Agent sessions are stored per working directory; give korgd its own so it never
  // mixes with the user's project histories.
  const sessionCwd = join(DATA_DIR, 'sessions')
  mkdirSync(sessionCwd, { recursive: true })

  const db = openDb(join(DATA_DIR, 'korg.db'))
  const store = new Store(db)

  const providers = new Map<string, ProviderAdapter>()
  providers.set('anthropic', new AnthropicSubscriptionAdapter({ cwd: sessionCwd }))

  let server: KorgServer
  const sessions = new SessionManager(store, providers, (event) => server.broadcast(event))
  server = new KorgServer({ store, sessions, providers })

  await server.listen(PORT, HOST)
  console.log(`korgd listening on ws://${HOST}:${PORT}  (data: ${DATA_DIR})`)

  // Seed one bot on an empty database so a fresh install opens onto something usable.
  if (store.listBots(true).length === 0) {
    const { bot } = store.createBot({
      name: 'New Bot',
      systemPrompt: 'You are a helpful, concise assistant.',
      model: 'default',
    })
    console.log(`seeded first bot: ${bot.name}`)
  }

  const shutdown = async (signal: string) => {
    console.log(`\n${signal} — shutting down`)
    for (const p of providers.values()) p.dispose()
    await server.close()
    db.close()
    process.exit(0)
  }
  process.on('SIGINT', () => void shutdown('SIGINT'))
  process.on('SIGTERM', () => void shutdown('SIGTERM'))
}

main().catch((err) => {
  console.error('korgd failed to start:', err)
  process.exit(1)
})
