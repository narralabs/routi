import { randomBytes, randomUUID, createHash, timingSafeEqual, X509Certificate } from 'node:crypto'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { readFileSync, writeFileSync, renameSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir, hostname } from 'node:os'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { createPairing } from 'routi-relay/pairing'
import type { Store } from '../db/store.js'

async function computerName(): Promise<string> {
  if (process.platform === 'darwin') {
    try {
      const { stdout } = await promisify(execFile)('/usr/sbin/scutil', ['--get', 'ComputerName'], { timeout: 2000 })
      if (stdout.trim()) return stdout.trim()
    } catch { /* Fall back when the system name is unavailable. */ }
  }
  return hostname()
}

export type PairedDevice = { id: string; name: string; certificate: string; createdAt: number }

/** Each device has its own identity; QR codes carry only an expiring claim. */
export class PhonePairing {
  private generation = 0
  private pending?: { secret: string; expiresAt: number; pkcs12: string; certificate: string; token: string; relay: string }
  private busy = false
  constructor(private readonly store: Pick<Store, 'getSettings' | 'setSettings'>,
              private readonly hostFile: string, private readonly changed: () => void) {}

  get devices(): PairedDevice[] {
    let host: ReturnType<PhonePairing['host']>
    try { host = this.host() } catch { return [] }
    const saved = host.devices
    if (saved) return saved
    // Keep the already-paired pilot phone working when upgrading.
    return this.store.getSettings()['connectPhonePaired'] === true
      ? [{ id: 'legacy', name: 'Previously paired device', certificate: host.peerCert, createdAt: 0 }] : []
  }
  identify(raw?: Buffer): string | undefined {
    if (!raw) return undefined
    return this.devices.find(device => new X509Certificate(device.certificate).raw.equals(raw))?.id
  }
  get available(): boolean {
    try { return /^[A-Za-z0-9_-]{43}$/.test(this.host().viewerToken) } catch { return false }
  }
  private host() { return JSON.parse(readFileSync(this.hostFile, 'utf8')) as { token: string; viewerToken: string; cert: string; peerCert: string; devices?: PairedDevice[] } }

  async begin(relay: string): Promise<{ url: string; expiresAt: number }> {
    if (!this.available) throw Error('Phone pairing is not provisioned on this core.')
    this.pending = undefined
    const generation = ++this.generation
    const { viewer } = await createPairing()
    const directory = await mkdtemp(join(tmpdir(), 'routi-phone-'))
    let pkcs12: string
    try {
      await writeFile(join(directory, 'key.pem'), viewer.key, { mode: 0o600 })
      await writeFile(join(directory, 'cert.pem'), viewer.cert, { mode: 0o600 })
      // Apple rejects empty PKCS#12 passwords. This compatibility password is not
      // the protection: transfer uses pinned TLS, then iOS stores it in Keychain.
      await promisify(execFile)('openssl', ['pkcs12', '-export', '-inkey', join(directory, 'key.pem'),
        '-in', join(directory, 'cert.pem'), '-out', join(directory, 'identity.p12'), '-passout', 'pass:routi',
        '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1'])
      pkcs12 = (await readFile(join(directory, 'identity.p12'))).toString('base64')
    } finally { await rm(directory, { recursive: true, force: true }) }
    const name = await computerName()
    if (generation !== this.generation) throw Error('Pairing cancelled')
    const host = this.host()
    const secret = randomBytes(32).toString('base64url')
    const expiresAt = Date.now() + 5 * 60_000
    this.pending = { secret, expiresAt, pkcs12, certificate: viewer.cert, token: viewer.token, relay }
    const payload = { v: 1, relay, token: host.viewerToken, certificate: new X509Certificate(host.cert).raw.toString('base64'),
      secret, expiresAt, name }
    return { url: `routibot://pair?data=${Buffer.from(JSON.stringify(payload)).toString('base64url')}`, expiresAt }
  }

  cancel(): void { this.generation++; this.pending = undefined }

  private save(devices: PairedDevice[]): void {
    const temporary = `${this.hostFile}.next`
    writeFileSync(temporary, JSON.stringify({ ...this.host(), devices }), { mode: 0o600 })
    renameSync(temporary, this.hostFile)
    this.changed()
  }

  private async registry(relay: string, method: string, id = '', body?: unknown) {
    const url = new URL(relay)
    url.protocol = url.protocol === 'wss:' ? 'https:' : 'http:'
    url.pathname = `/v1/devices${id ? `/${id}` : ''}`
    const response = await fetch(url, { method, redirect: 'error', signal: AbortSignal.timeout(10_000),
      headers: { Authorization: `Bearer ${this.host().token}`, 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined })
    if (!response.ok) {
      if (response.status === 409) throw Error('Device allowance reached. Revoke a device before pairing another.')
      throw Error('Could not update devices on the relay. Check the connection and try again.')
    }
    return await response.json() as { maxDevices: number | null; devices: { id: string }[] }
  }

  async revoke(id: string, relay: string): Promise<void> {
    const device = this.devices.find(device => device.id === id)
    if (!device) return
    // Remove local trust first, so revocation works even if the relay is offline.
    this.save(this.devices.filter(device => device.id !== id))
    if (id !== 'legacy') await this.registry(relay, 'DELETE', id)
  }

  async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    res.setHeader('Cache-Control', 'no-store')
    res.setHeader('Connection', 'close')
    const pending = this.pending
    const supplied = req.headers.authorization?.match(/^Bearer ([A-Za-z0-9_-]{43})$/)?.[1] ?? ''
    if (req.method !== 'POST' || req.url !== '/pair' || !pending || Date.now() >= pending.expiresAt
        || supplied.length !== pending.secret.length
        || !timingSafeEqual(Buffer.from(supplied), Buffer.from(pending.secret))) {
      res.writeHead(403).end(); return
    }
    if (this.busy) { res.writeHead(409).end(); return }
    this.pending = undefined
    this.busy = true
    const generation = this.generation
    const id = randomUUID()
    let registered = false
    try {
      let body = ''
      for await (const chunk of req) {
        body += chunk.toString()
        if (Buffer.byteLength(body) > 1024) throw Error('Device name is too long.')
      }
      const { name = 'iPhone' } = body ? JSON.parse(body) : {}
      if (typeof name !== 'string' || !name.trim() || name.length > 80) throw Error('Enter a device name of 1–80 characters.')
      const { maxDevices, devices } = await this.registry(pending.relay, 'GET')
      // Recover slots left by a failed local save or an offline revocation.
      for (const device of devices) {
        if (!this.devices.some(local => local.id === device.id)) await this.registry(pending.relay, 'DELETE', device.id)
      }
      if (maxDevices != null && this.devices.length >= maxDevices) throw Error('Device allowance reached. Revoke a device before pairing another.')
      await this.registry(pending.relay, 'POST', '', { id, hash: createHash('sha256').update(pending.token).digest('hex') })
      registered = true
      if (generation !== this.generation) throw Error('Pairing cancelled. Create a new code.')
      this.save([...this.devices, { id, name: name.trim(), certificate: pending.certificate, createdAt: Date.now() }])
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ pkcs12: pending.pkcs12, token: pending.token }))
    } catch (error) {
      if (registered) { try { await this.registry(pending.relay, 'DELETE', id) } catch { /* Local trust was not saved. */ } }
      res.writeHead(400, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ error: error instanceof Error ? error.message : 'Pairing failed.' }))
    } finally { this.busy = false }
  }
}
