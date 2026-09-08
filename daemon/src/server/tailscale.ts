import { hostname, networkInterfaces } from 'node:os'

/**
 * This Mac's Tailscale address, if it has one.
 *
 * Tailscale hands every device an IPv4 in 100.64.0.0/10, the carrier-grade NAT range
 * nothing else on a home network uses, so an interface with one is the tailnet. Read
 * off the interfaces rather than asked of the Tailscale CLI, which the App Store build
 * does not put on the PATH. Null until Tailscale is installed and up.
 */
export function tailscaleAddress(): string | null {
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family !== 'IPv4' || address.internal) continue
      const [a, b] = address.address.split('.').map(Number)
      if (a === 100 && b !== undefined && b >= 64 && b <= 127) return address.address
    }
  }
  return null
}

/** The Mac's name as a person knows it, without the .local Bonjour suffix. */
export function machineName(): string {
  return hostname().replace(/\.local$/, '')
}
