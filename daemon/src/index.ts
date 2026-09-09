import { homedir } from 'node:os'
import { join } from 'node:path'
import { existsSync, mkdirSync, renameSync } from 'node:fs'
import { openDb } from './db/schema.js'
import { Store } from './db/store.js'
import { AuthManager } from './auth/manager.js'
import type { ProviderAdapter } from './providers/types.js'
import { SessionManager } from './sessions/manager.js'
import { RoutiServer } from './server/ws.js'
import { Scheduler } from './sessions/scheduler.js'
import { Handovers } from './surfaces/handover.js'
import { DesktopPool } from './surfaces/pool.js'
import { Updater } from './update.js'
import { bindableAddress, machineName, tailscaleReport } from './server/tailscale.js'

const DATA_DIR = process.env['ROUTI_DATA_DIR'] ?? join(homedir(), '.routi')

/**
 * The product was called Krog until September 2026. A Mac that ran it then has its
 * bots in ~/.krog; moving the directory the first time the renamed daemon starts is
 * what keeps them. Only the default location moves — an explicit data dir is left to
 * whoever set it.
 */
function adoptOldDataDir(): void {
  if (process.env['ROUTI_DATA_DIR']) return
  const old = join(homedir(), '.krog')
  if (existsSync(DATA_DIR) || !existsSync(old)) return
  renameSync(old, DATA_DIR)
  console.log(`moved ${old} to ${DATA_DIR}`)
}
const PORT = Number(process.env['ROUTI_PORT'] ?? 7171)
// Default to loopback. M2 moves this to the Tailscale interface rather than 0.0.0.0 —
// binding to every interface would expose the daemon on whatever café Wi-Fi is around.
const HOST = process.env['ROUTI_HOST'] ?? '127.0.0.1'

async function main(): Promise<void> {
  adoptOldDataDir()
  mkdirSync(DATA_DIR, { recursive: true })
  // Agent sessions are stored per working directory; give routid its own so it never
  // mixes with the user's project histories.
  const sessionCwd = join(DATA_DIR, 'sessions')
  mkdirSync(sessionCwd, { recursive: true })

  const db = openDb(join(DATA_DIR, existsSync(join(DATA_DIR, 'krog.db')) ? 'krog.db' : 'routi.db'))
  const store = new Store(db)
  // Turns that were running when the last process ended cannot be resumed; what they
  // left is cleared before a client can load it.
  const swept = store.deleteEmptyAssistantMessages()
  if (swept > 0) console.log(`removed ${swept} message(s) left empty by interrupted turns`)

  // Starts empty on purpose: the daemon must run with no credential so the client
  // can connect and walk the user through onboarding.
  // A desktop per bot, created on demand. Separate containers keep one bot's tabs,
  // logins and pointer out of another's.
  const desktops = new DesktopPool(DATA_DIR, store)

  const providers = new Map<string, ProviderAdapter>()
  const auth = new AuthManager(
    store,
    providers,
    sessionCwd,
    DATA_DIR,
    `http://127.0.0.1:${PORT}`,
    desktops,
  )
  // Every bot belongs to a profile; the first one is named after the person, and
  // an upgraded core's bots are moved into it before their adapters are installed.
  store.ensureDefaultProfile()
  await auth.applyMode()

  let server: RoutiServer
  const handovers = new Handovers((event) => server.broadcast(event))
  const updater = new Updater(DATA_DIR, (stage, line) => server.broadcast({ e: 'core.update.progress', stage, line }))
  const sessions = new SessionManager(
    store,
    providers,
    (event) => server.broadcast(event),
    desktops,
    handovers,
  )
  server = new RoutiServer({
    store, sessions, providers, auth, desktops, handovers, updater,
    // For telling the person, not for binding: the report says how Tailscale stands
    // here, which the interface scan below cannot — a userspace daemon has an address
    // and no interface, and the core is reachable on it through `tailscale serve`.
    addresses: async () => {
      const ts = await tailscaleReport(PORT, server.alsoListeningOn)
      return {
        hostname: machineName(),
        tailscale: ts.address,
        listening: ts.address !== null && server.alsoListeningOn.includes(ts.address),
        tailscaleMode: ts.mode,
        reachable: ts.reachable,
      }
    },
  })

  // Routines are saved by bots during ordinary turns; this only fires what is due.
  const scheduler = new Scheduler(store, sessions)
  scheduler.start()

  await server.listen(PORT, HOST)

  /**
   * Also on the tailnet, so a phone can reach this core from anywhere.
   *
   * Loopback is where the core lives. The one other place it answers is this Mac's
   * Tailscale address, which only devices signed into the same tailnet can reach, and
   * which is the same address at home and away. Checked on a timer rather than once,
   * because Tailscale often comes up after the core does at login. An explicit
   * ROUTI_HOST is left alone: whoever set it chose.
   */
  if (!process.env['ROUTI_HOST']) {
    const bindTailscale = async () => {
      // Only an address on a real interface: a userspace daemon's is not bindable,
      // and trying every half minute would be a permanent EADDRNOTAVAIL.
      const address = bindableAddress()
      if (!address || server.alsoListeningOn.includes(address)) return
      if (await server.listenAlso(PORT, address)) console.log(`also listening on ws://${address}:${PORT}  (Tailscale)`)
    }
    await bindTailscale()
    setInterval(() => void bindTailscale(), 30_000).unref()
  }

  const status = await auth.status()
  console.log(`routid listening on ws://${HOST}:${PORT}  (data: ${DATA_DIR})`)
  // Screens whose bot has gone hold a display and a browser for nothing.
  // Only the core on the default data dir reaps. Screens live in one shared container
  // and are named by bot; a second core pointed at another data dir — a development
  // one, say — has none of the real bots in its database and would stop every screen
  // the real core is using. It did, once.
  if (!process.env['ROUTI_DATA_DIR']) {
    const reaped = await desktops.reapOrphans(new Set(store.listBots(true).map((b) => b.id)))
    if (reaped > 0) console.log(`reaped ${reaped} orphaned screen(s)`)
  }

  console.log(scheduler.summary())
  console.log(
    status.configured
      ? `anthropic: ${status.mode === 'api_key' ? 'API key' : status.subscription.subscriptionType ?? 'subscription'}`
      : 'anthropic: not configured — finish setup in the app',
  )

  const shutdown = async (signal: string) => {
    console.log(`\n${signal} — shutting down`)
    scheduler.stop()
    for (const p of providers.values()) p.dispose()
    // Leave the desktops running: their state is the value, and a restart of routid
    // should not cost the user their browser sessions.
    await server.close()
    db.close()
    process.exit(0)
  }
  process.on('SIGINT', () => void shutdown('SIGINT'))
  process.on('SIGTERM', () => void shutdown('SIGTERM'))
}

main().catch((err) => {
  console.error('routid failed to start:', err)
  process.exit(1)
})
