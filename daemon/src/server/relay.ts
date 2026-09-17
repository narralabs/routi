import { PhonePairing } from './phone-pairing.js'
import type { TLSSocket } from 'node:tls'
import type { IncomingMessage } from 'node:http'
import type { Duplex } from 'node:stream'
import { existsSync, readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { X509Certificate } from 'node:crypto'
import { z } from 'zod'
import { startHost } from 'routi-relay/connection'
import { PROTOCOL_VERSION, type RelayStatus } from '@routi/protocol'
import type { Store } from '../db/store.js'
import { VERSION } from '../version.js'

const configuration = z.object({
  url: z.string().trim().max(2048).refine(value => {
    if (!URL.canParse(value)) return false
    const url = new URL(value)
    return (url.protocol === 'wss:' || (url.protocol === 'ws:' && ['127.0.0.1', '[::1]'].includes(url.hostname)))
      && !url.username && !url.password && !url.search && !url.hash && url.pathname === '/'
  }, 'Use a wss:// relay address without a path or sign-in details.'),
  enabled: z.boolean(),
})
const deviceSchema = z.object({
  token: z.string().regex(/^[A-Za-z0-9_-]{43}$/), key: z.string().min(1), cert: z.string().min(1), peerCert: z.string().min(1),
})

/** Authenticated chat and single-use phone pairing over the outbound relay connection. */
export class RelayConnection {
  private readonly pairing: PhonePairing
  private readonly authenticated = new Set<TLSSocket>()
  private readonly pairingHttp = createServer({ requestTimeout: 10_000, headersTimeout: 10_000 }, (req, res) => this.pairing.handle(req, res))
  private chatUpgrade?: (req: IncomingMessage, socket: Duplex, head: Buffer) => void
  private host?: ReturnType<typeof startHost>
  private current: RelayStatus = {
    configured: false, url: 'wss://connect.routibot.com', enabled: false, state: 'disconnected', error: null, canPair: false, phonePaired: false,
  }
  private readonly http = createServer({ requestTimeout: 10_000, headersTimeout: 10_000 }, (req, res) => {
    if (req.method !== 'GET' || req.url !== '/health') { res.writeHead(404).end(); return }
    res.writeHead(200, { 'content-type': 'application/json', connection: 'close' })
    res.end(JSON.stringify({ ok: true, version: VERSION, protocolVersion: PROTOCOL_VERSION }))
  })

  constructor(private readonly store: Pick<Store, 'getSettings' | 'setSettings'>, private readonly hostFile: string) {
    this.pairing = new PhonePairing(store, hostFile, certificate => {
      for (const stream of this.authenticated) stream.destroy()
      if (certificate) this.host?.updatePeerCertificate(certificate)
    })
    this.pairingHttp.on('upgrade', (_req, socket) => socket.destroy())
    this.http.on('upgrade', (req, socket, head) => {
      if (req.url !== '/chat' || !this.pairing.paired || !this.chatUpgrade) { socket.destroy(); return }
      this.chatUpgrade(req, socket, head)
    })
    const saved = configuration.safeParse(store.getSettings()['connect'])
    if (saved.success) this.current = { ...this.current, ...saved.data }
    if (this.current.enabled) this.start()
  }

  status(): RelayStatus {
    return { ...this.current, configured: existsSync(this.hostFile), canPair: this.pairing.available, phonePaired: this.pairing.paired }
  }

  setChatHandler(handler: (req: IncomingMessage, socket: Duplex, head: Buffer) => void): void { this.chatUpgrade = handler }
  async pairPhone() {
    if (this.current.state !== 'connected') throw Error('Connect the relay before pairing a phone.')
    return this.pairing.begin(this.current.url)
  }
  cancelPairing(): void { this.pairing.cancel() }
  revokePhone(): void { this.pairing.revoke() }

  configure(input: { url: string; enabled: boolean }): RelayStatus {
    const parsed = configuration.safeParse(input)
    if (!parsed.success) throw Error('Use a wss:// relay address without a path or sign-in details.')
    // Validate before replacing a working connection or persisting the preference.
    if (input.enabled) this.readDevice()
    this.stop()
    this.store.setSettings({ connect: parsed.data })
    this.current = { ...this.current, ...parsed.data, error: null }
    if (input.enabled) this.start()
    return this.status()
  }

  stop(): void {
    this.pairing.cancel()
    this.host?.stop()
    this.host = undefined
    this.current.state = 'disconnected'
  }

  private readDevice() {
    try {
      const device = deviceSchema.parse(JSON.parse(readFileSync(this.hostFile, 'utf8')))
      for (const pem of [device.cert, device.peerCert]) {
        const cert = new X509Certificate(pem)
        if (Date.parse(cert.validFrom) > Date.now() || Date.parse(cert.validTo) <= Date.now()) throw Error('Expired certificate')
      }
      return device
    } catch {
      throw Error('Pilot credentials are missing, invalid, or expired. Configure this Mac’s connection first.')
    }
  }

  private start(): void {
    try {
      this.host = startHost(this.current.url, this.readDevice(), {
        onConnection: stream => {
          // Check the current pin even for resumed TLS sessions after re-pairing.
          try {
            const expected = new X509Certificate(this.readDevice().peerCert).raw
            if (!stream.getPeerCertificate().raw?.equals(expected)) { stream.destroy(); return }
          } catch { stream.destroy(); return }
          this.authenticated.add(stream)
          stream.on('close', () => this.authenticated.delete(stream))
          this.http.emit('connection', stream)
        },
        onPairingConnection: stream => this.pairingHttp.emit('connection', stream),
        onState: state => {
          this.current.state = state
          this.current.error = state === 'rejected' ? 'Relay access was rejected. Check this Mac’s pilot access and credentials.' : null
        },
      })
    } catch {
      this.current.state = 'error'
      this.current.error = 'Could not start Routi Connect. Check this Mac’s relay address and pilot credentials.'
    }
  }
}
