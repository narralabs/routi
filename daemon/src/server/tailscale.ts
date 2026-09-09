import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { homedir, hostname, networkInterfaces } from 'node:os'
import { join } from 'node:path'

/**
 * This Mac's Tailscale address as something the core can bind, if it has one.
 *
 * Tailscale hands every device an IPv4 in 100.64.0.0/10, the carrier-grade NAT range
 * nothing else on a home network uses, so an interface with one is the tailnet. Read
 * off the interfaces rather than asked of the Tailscale CLI, which the App Store build
 * does not put on the PATH. Null when no interface carries one — which is not the same
 * as Tailscale being absent: see `tailscaleReport`. Only an address that is on a real
 * interface can be listened on, so this is what the binding path uses, and only it.
 */
export function bindableAddress(): string | null {
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family !== 'IPv4' || address.internal) continue
      const [a, b] = address.address.split('.').map(Number)
      if (a === 100 && b !== undefined && b >= 64 && b <= 127) return address.address
    }
  }
  return null
}

/**
 * How this Mac stands with Tailscale, for telling the person — never for binding.
 *
 * One null used to stand for four different things: not installed, installed but not
 * running, running without a network interface, and running with one. The third is
 * `tailscaled --tun=userspace-networking`, which keeps the tailnet inside its own
 * process — no interface carries the address, so nothing can bind it — and hands
 * connections to loopback through `tailscale serve`. A core on such a Mac is reachable
 * on its Tailscale address and was reported as having none, which sent one person
 * towards tearing down a working setup. Hence a mode beside the address:
 *
 * - `absent`     — no Tailscale CLI on this Mac, and no interface either
 * - `down`       — the CLI is here but its daemon does not answer
 * - `userspace`  — the daemon answers and has an address, but no interface carries it;
 *                  `reachable` says whether a serve rule forwards the core's port
 * - `interface`  — the address is on an interface; the core binds it itself
 */
export interface TailscaleReport {
  address: string | null
  mode: 'absent' | 'down' | 'userspace' | 'interface'
  /** Whether a connection to the address on the core's port would reach the core. */
  reachable: boolean
}

/** Where the CLI lives when it is not on the PATH: the app bundle, then the package managers. */
const CLI_CANDIDATES = [
  '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
  '/opt/homebrew/bin/tailscale',
  '/usr/local/bin/tailscale',
]

/**
 * Sockets the daemon might be on. The CLI's own default first (no flag), then the
 * per-user path a Homebrew `tailscaled` run as that user is given.
 */
function socketCandidates(): (string | null)[] {
  return [null, join(homedir(), '.tailscale', 'tailscaled.sock')]
}

function cli(): string | null {
  const configured = process.env['ROUTI_TAILSCALE_CLI']
  if (configured) return configured
  return CLI_CANDIDATES.find((path) => existsSync(path)) ?? null
}

/** `tailscale <args>` against one socket, bounded so a hung daemon cannot hold the report. */
function ask(binary: string, socket: string | null, args: string[]): Promise<{ ok: boolean; out: string }> {
  return new Promise((resolve) => {
    const full = socket ? [`--socket=${socket}`, ...args] : args
    execFile(binary, full, { timeout: 2_000 }, (err, stdout, stderr) => {
      resolve({ ok: !err, out: `${stdout}${stderr}` })
    })
  })
}

/**
 * The first socket the daemon answers on, with what it says of itself. `status --json`
 * rather than `ip`: a stopped Tailscale app still answers `ip` with the address it last
 * had (measured on a Mac with the app installed and switched off), so an address alone
 * proves nothing. `BackendState` is "Running" only when the node is actually up. A CLI
 * that cannot reach its daemon at all exits non-zero; that too is `down`, not `absent`.
 */
async function askDaemon(binary: string): Promise<{ address: string | null; socket: string | null; running: boolean }> {
  for (const socket of socketCandidates()) {
    const { ok, out } = await ask(binary, socket, ['status', '--json'])
    if (!ok) continue
    try {
      const status = JSON.parse(out) as { BackendState?: string; Self?: { TailscaleIPs?: string[] } }
      const address = status.Self?.TailscaleIPs?.find((ip) => /^100\.\d+\.\d+\.\d+$/.test(ip)) ?? null
      return { address, socket, running: status.BackendState === 'Running' }
    } catch {
      continue
    }
  }
  return { address: null, socket: null, running: false }
}

/** Whether `tailscale serve` forwards the port to this Mac, read off `serve status`. */
async function served(binary: string, socket: string | null, port: number): Promise<boolean> {
  const { ok, out } = await ask(binary, socket, ['serve', 'status'])
  return ok && new RegExp(`:${port}\\b`).test(out)
}

let cached: { at: number; report: TailscaleReport } | null = null
let inFlight: Promise<TailscaleReport> | null = null

/**
 * The report, no older than half a minute. Asking the daemon is two short processes;
 * Settings asks on every connect, so the answer is kept for a while and one question
 * in flight serves everyone who asks meanwhile. `ROUTI_TAILSCALE_ADDRESS` overrides the
 * address outright, for a Mac whose Tailscale the core cannot see at all.
 */
export function tailscaleReport(port: number, boundOn: readonly string[]): Promise<TailscaleReport> {
  if (cached && Date.now() - cached.at < 30_000) return Promise.resolve(withBinding(cached.report, boundOn))
  if (inFlight) return inFlight.then((report) => withBinding(report, boundOn))
  inFlight = resolveReport(port)
    .then((report) => {
      cached = { at: Date.now(), report }
      return withBinding(report, boundOn)
    })
    .finally(() => { inFlight = null })
  return inFlight
}

/** Binding is the server's to know, so it is applied on the way out, never cached. */
function withBinding(report: TailscaleReport, boundOn: readonly string[]): TailscaleReport {
  if (report.mode !== 'interface') return report
  return { ...report, reachable: report.address !== null && boundOn.includes(report.address) }
}

async function resolveReport(port: number): Promise<TailscaleReport> {
  const onInterface = bindableAddress()
  const override = process.env['ROUTI_TAILSCALE_ADDRESS']?.trim()
  if (override) {
    // Whoever set it knows; on an interface it is bound, otherwise it is assumed served.
    return { address: override, mode: override === onInterface ? 'interface' : 'userspace', reachable: override !== onInterface }
  }
  if (onInterface) return { address: onInterface, mode: 'interface', reachable: false }

  const binary = cli()
  if (!binary) return { address: null, mode: 'absent', reachable: false }
  const daemon = await askDaemon(binary)
  // Down carries no address: one that does not answer is worse than none in Settings.
  if (!daemon.running || !daemon.address) return { address: null, mode: 'down', reachable: false }
  return { address: daemon.address, mode: 'userspace', reachable: await served(binary, daemon.socket, port) }
}

/** The Mac's name as a person knows it, without the .local Bonjour suffix. */
export function machineName(): string {
  return hostname().replace(/\.local$/, '')
}
