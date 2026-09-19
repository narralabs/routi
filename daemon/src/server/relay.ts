import { PhonePairing } from './phone-pairing.js'
import type { TLSSocket } from 'node:tls'
import type { IncomingMessage, RequestListener } from 'node:http'
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

/** Authenticated chat/desktop viewing and single-use pairing over the relay. */
export class RelayConnection {
  private readonly pairing: PhonePairing
  private readonly authenticated = new Map<TLSSocket, string | undefined>()
  private readonly pairingHttp = createServer({ requestTimeout: 10_000, headersTimeout: 10_000 }, (req, res) => { void this.pairing.handle(req, res) })
  private desktop?: { handle: RequestListener; upgrade: (req: IncomingMessage, socket: Duplex, head: Buffer) => void }
  private chatUpgrade?: (req: IncomingMessage, socket: Duplex, head: Buffer) => void
  private host?: ReturnType<typeof startHost>
  private current: RelayStatus = {
    configured: false, url: 'wss://connect.routibot.com', enabled: false, state: 'disconnected', error: null, canPair: false, devices: [],
  }
  private readonly http = createServer({ requestTimeout: 10_000, headersTimeout: 10_000 }, (req, res) => {
    if (req.url?.startsWith('/vnc/') && this.desktop) {
      if (!this.authenticated.get(req.socket as TLSSocket)) { res.writeHead(403).end(); return }
      this.desktop.handle(req, res); return
    }
    if (req.method !== 'GET' || req.url !== '/health') { res.writeHead(404).end(); return }
    res.writeHead(200, { 'content-type': 'application/json', connection: 'close' })
    res.end(JSON.stringify({ ok: true, version: VERSION, protocolVersion: PROTOCOL_VERSION }))
  })

  constructor(private readonly store: Pick<Store, 'getSettings' | 'setSettings'>, private readonly hostFile: string) {
    this.pairing = new PhonePairing(store, hostFile, () => {
      for (const [stream, id] of this.authenticated) {
        if (id && !this.pairing.devices.some(device => device.id === id)) stream.destroy()
      }
      this.host?.updatePeerCertificate(this.readDevice().peerCert)
    })
    this.pairingHttp.on('upgrade', (_req, socket) => socket.destroy())
    this.http.on('upgrade', (req, socket, head) => {
      if (!this.authenticated.get(socket as TLSSocket)) { socket.destroy(); return }
      if (req.url?.startsWith('/vnc/') && this.desktop) { this.desktop.upgrade(req, socket, head); return }
      if (req.url === '/chat' && this.chatUpgrade) { this.chatUpgrade(req, socket, head); return }
      socket.destroy()
    })
    const saved = configuration.safeParse(store.getSettings()['connect'])
    if (saved.success) this.current = { ...this.current, ...saved.data }
    if (this.current.enabled) this.start()
  }

  status(): RelayStatus {
    return { ...this.current, configured: existsSync(this.hostFile), canPair: this.pairing.available, devices: this.pairing.devices.map(({ certificate: _certificate, ...device }) => device) }
  }

  setChatHandler(handler: (req: IncomingMessage, socket: Duplex, head: Buffer) => void): void { this.chatUpgrade = handler }
  setDesktopHandler(handler: NonNullable<RelayConnection['desktop']>): void { this.desktop = handler }
  async pairPhone() {
    if (this.current.state !== 'connected') throw Error('Connect the relay before pairing a phone.')
    return this.pairing.begin(this.current.url)
  }
  cancelPairing(): void { this.pairing.cancel() }
  async revokeDevice(id: string): Promise<void> { await this.pairing.revoke(id, this.current.url) }

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
      const cert = new X509Certificate(device.cert)
      if (Date.parse(cert.validFrom) > Date.now() || Date.parse(cert.validTo) <= Date.now()) throw Error('Expired certificate')
      return { ...device, peerCert: [device.peerCert, ...this.pairing.devices.map(device => device.certificate)].join('\n') }
    } catch {
      throw Error('Pilot credentials are missing, invalid, or expired. Configure this Mac’s connection first.')
    }
  }

  private start(): void {
    try {
      this.host = startHost(this.current.url, this.readDevice(), {
        onConnection: stream => {
          try { this.authenticated.set(stream, this.pairing.identify(stream.getPeerCertificate().raw)) }
          catch { stream.destroy(); return }
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
