import { randomBytes, timingSafeEqual, X509Certificate } from 'node:crypto'
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

/** One phone per provisioned relay pair. QR codes carry an expiring claim, never a private key. */
export class PhonePairing {
  private generation = 0
  private pending?: { secret: string; expiresAt: number; pkcs12: string; certificate: string }
  constructor(private readonly store: Pick<Store, 'getSettings' | 'setSettings'>,
              private readonly hostFile: string, private readonly changed: (certificate?: string) => void) {}

  get paired(): boolean { return this.store.getSettings()['connectPhonePaired'] === true }
  get available(): boolean {
    try { return /^[A-Za-z0-9_-]{43}$/.test(this.host().viewerToken) } catch { return false }
  }
  private host() { return JSON.parse(readFileSync(this.hostFile, 'utf8')) as { viewerToken: string; cert: string; peerCert: string } }

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
    this.pending = { secret, expiresAt, pkcs12, certificate: viewer.cert }
    const payload = { v: 1, relay, token: host.viewerToken, certificate: new X509Certificate(host.cert).raw.toString('base64'),
      secret, expiresAt, name }
    return { url: `routibot://pair?data=${Buffer.from(JSON.stringify(payload)).toString('base64url')}`, expiresAt }
  }

  cancel(): void { this.generation++; this.pending = undefined }

  revoke(): void {
    this.cancel()
    this.store.setSettings({ connectPhonePaired: false })
    this.changed()
  }

  handle(req: IncomingMessage, res: ServerResponse): void {
    res.setHeader('Cache-Control', 'no-store')
    res.setHeader('Connection', 'close')
    const pending = this.pending
    const supplied = req.headers.authorization?.match(/^Bearer ([A-Za-z0-9_-]{43})$/)?.[1] ?? ''
    if (req.method !== 'POST' || req.url !== '/pair' || !pending || Date.now() > pending.expiresAt
        || supplied.length !== pending.secret.length
        || !timingSafeEqual(Buffer.from(supplied), Buffer.from(pending.secret))) {
      res.writeHead(403).end(); return
    }
    // Consume before doing any work: concurrent requests cannot redeem the same QR.
    this.pending = undefined
    try {
      const host = this.host()
      const temporary = `${this.hostFile}.next`
      writeFileSync(temporary, JSON.stringify({ ...host, peerCert: pending.certificate }), { mode: 0o600 })
      renameSync(temporary, this.hostFile)
      this.store.setSettings({ connectPhonePaired: true })
      this.changed(pending.certificate)
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ pkcs12: pending.pkcs12 }))
    } catch { res.writeHead(500).end() }
  }
}
