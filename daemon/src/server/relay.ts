import { PhonePairing } from './phone-pairing.js'
import type { TLSSocket } from 'node:tls'
import type { IncomingMessage, RequestListener } from 'node:http'
import type { Duplex } from 'node:stream'
import { existsSync, readFileSync, mkdirSync, writeFileSync, renameSync } from 'node:fs'
import { dirname } from 'node:path'
import { createPairing } from 'routi-relay/pairing'
import { createServer } from 'node:http'
import { createHash, X509Certificate } from 'node:crypto'
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
const accessSchema = z.object({ trial: z.boolean(), expiresAt: z.number().nullable(), expired: z.boolean() })
const deviceSchema = z.object({
  token: z.string().regex(/^[A-Za-z0-9_-]{43}$/), key: z.string().min(1), cert: z.string().min(1), peerCert: z.string().min(1),
})

/** Authenticated chat/desktop viewing and single-use pairing over the relay. */
export class RelayConnection {
  private configuring = false
  private lastAccessCheck = 0
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
      this.lastAccessCheck = 0
      void this.refreshStatus()
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

  async refreshStatus(): Promise<RelayStatus> {
    if (existsSync(this.hostFile) && Date.now() - this.lastAccessCheck > 15_000) {
      this.lastAccessCheck = Date.now()
      try {
        const url = this.current.url
        const device = JSON.parse(readFileSync(this.hostFile, 'utf8'))
        if (device.relayUrl && device.relayUrl !== url) return this.status()
        const response = await this.relayRequest(url, '/v1/access')
        if (url === this.current.url && response.ok) this.current.access = accessSchema.parse(await response.json())
      } catch { /* Connection state reports network failures; retain the last known deadline. */ }
    }
    const access = this.current.access
    if (access?.expiresAt != null) access.expired = access.expiresAt <= Date.now()
    return this.status()
  }

  private relayRequest(base: string, path: string, body?: unknown) {
    const url = new URL(path, base)
    url.protocol = url.protocol === 'wss:' ? 'https:' : 'http:'
    const { token } = deviceSchema.parse(JSON.parse(readFileSync(this.hostFile, 'utf8')))
    return fetch(url, { method: body ? 'POST' : 'GET', redirect: 'error',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(10_000) })
  }

  private async enroll(url: string) {
    if (!existsSync(this.hostFile)) {
      const pair = await createPairing()
      mkdirSync(dirname(this.hostFile), { recursive: true, mode: 0o700 })
      writeFileSync(this.hostFile, JSON.stringify({ ...pair.host, viewerToken: pair.viewer.token, relayUrl: url, enrolled: false }), { flag: 'wx', mode: 0o600 })
    }
    this.readDevice()
    const device = JSON.parse(readFileSync(this.hostFile, 'utf8'))
    if (device.relayUrl && device.relayUrl !== url) throw Error('This Mac is registered with a different relay address.')
    if (device.enrolled === false) {
      const response = await this.relayRequest(url, '/v1/trial', { viewerTokenHash: createHash('sha256').update(device.viewerToken).digest('hex') })
      if (!response.ok) throw Error('Could not set up Routi Connect. Please try again later.')
      this.current.access = accessSchema.parse(await response.json())
      writeFileSync(`${this.hostFile}.next`, JSON.stringify({ ...device, enrolled: true }), { mode: 0o600 })
      renameSync(`${this.hostFile}.next`, this.hostFile)
    }
  }

  setChatHandler(handler: (req: IncomingMessage, socket: Duplex, head: Buffer) => void): void { this.chatUpgrade = handler }
  setDesktopHandler(handler: NonNullable<RelayConnection['desktop']>): void { this.desktop = handler }
  async pairPhone() {
    if (this.current.state !== 'connected') throw Error('Connect the relay before pairing a phone.')
    return this.pairing.begin(this.current.url)
  }
  cancelPairing(): void { this.pairing.cancel() }
  async revokeDevice(id: string): Promise<void> { await this.pairing.revoke(id, this.current.url) }

  async configure(input: { url: string; enabled: boolean }): Promise<RelayStatus> {
    const parsed = configuration.safeParse(input)
    if (!parsed.success) throw Error('Use a wss:// relay address without a path or sign-in details.')
    if (this.configuring) throw Error('Routi Connect setup is already in progress.')
    this.configuring = true
    try {
      if (parsed.data.enabled) await this.enroll(parsed.data.url)
      this.stop()
      this.store.setSettings({ connect: parsed.data })
      this.current = { ...this.current, ...parsed.data, error: null }
      this.lastAccessCheck = 0
      if (input.enabled) this.start()
      return this.status()
    } finally { this.configuring = false }
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
      throw Error('Connection credentials are missing, invalid, or expired.')
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
          this.current.error = state === 'rejected' ? 'Relay access was rejected. Check your Connect access.' : null
          if (state === 'connected' || state === 'rejected') { this.lastAccessCheck = 0; void this.refreshStatus() }
        },
      })
    } catch {
      this.current.state = 'error'
      this.current.error = 'Could not start Routi Connect. Check this Mac’s relay address and credentials.'
    }
  }
}
