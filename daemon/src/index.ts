import { homedir } from 'node:os'
import { join } from 'node:path'
import { mkdirSync } from 'node:fs'
import { openDb } from './db/schema.js'
import { Store } from './db/store.js'
import { AuthManager } from './auth/manager.js'
import type { ProviderAdapter } from './providers/types.js'
import { SessionManager } from './sessions/manager.js'
import { KrogServer } from './server/ws.js'
import { DesktopPool } from './surfaces/pool.js'

const DATA_DIR = process.env['KROG_DATA_DIR'] ?? join(homedir(), '.krog')
const PORT = Number(process.env['KROG_PORT'] ?? 7171)
// Default to loopback. M2 moves this to the Tailscale interface rather than 0.0.0.0 —
// binding to every interface would expose the daemon on whatever café Wi-Fi is around.
const HOST = process.env['KROG_HOST'] ?? '127.0.0.1'

async function main(): Promise<void> {
  mkdirSync(DATA_DIR, { recursive: true })
  // Agent sessions are stored per working directory; give krogd its own so it never
  // mixes with the user's project histories.
  const sessionCwd = join(DATA_DIR, 'sessions')
  mkdirSync(sessionCwd, { recursive: true })

  const db = openDb(join(DATA_DIR, 'krog.db'))
  const store = new Store(db)

  // Starts empty on purpose: the daemon must run with no credential so the client
  // can connect and walk the user through onboarding.
  // A desktop per bot, created on demand. Separate containers keep one bot's tabs,
  // logins and pointer out of another's.
  const desktops = new DesktopPool()

  const providers = new Map<string, ProviderAdapter>()
  const auth = new AuthManager(
    store,
    providers,
    sessionCwd,
    DATA_DIR,
    `http://127.0.0.1:${PORT}`,
    desktops,
  )
  await auth.applyMode()

  let server: KrogServer
  const sessions = new SessionManager(store, providers, (event) => server.broadcast(event))
  server = new KrogServer({ store, sessions, providers, auth, desktops })

  await server.listen(PORT, HOST)

  const status = await auth.status()
  console.log(`krogd listening on ws://${HOST}:${PORT}  (data: ${DATA_DIR})`)
  console.log(
    status.configured
      ? `anthropic: ${status.mode === 'api_key' ? 'API key' : status.subscription.subscriptionType ?? 'subscription'}`
      : 'anthropic: not configured — finish setup in the app',
  )

  // Seed one bot on an empty database so a fresh install opens onto something usable.
  if (store.listBots(true).length === 0) {
    store.createBot({
      name: 'New Bot',
      systemPrompt: 'You are a helpful, concise assistant.',
      model: 'default',
    })
  }

  const shutdown = async (signal: string) => {
    console.log(`\n${signal} — shutting down`)
    for (const p of providers.values()) p.dispose()
    // Leave the desktops running: their state is the value, and a restart of krogd
    // should not cost the user their browser sessions.
    await server.close()
    db.close()
    process.exit(0)
  }
  process.on('SIGINT', () => void shutdown('SIGINT'))
  process.on('SIGTERM', () => void shutdown('SIGTERM'))
}

main().catch((err) => {
  console.error('krogd failed to start:', err)
  process.exit(1)
})
