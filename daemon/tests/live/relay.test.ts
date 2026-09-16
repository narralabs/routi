/** LIVE relay check, excluded from pnpm test/CI. Reads core health only; no model usage. */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { request } from 'node:http'
import { connectViewer } from 'routi-relay/connection'
import type { Device } from 'routi-relay/pairing'
import { VERSION } from '../../src/version.js'
import { PROTOCOL_VERSION } from '@routi/protocol'

if (process.env['ROUTI_LIVE_TESTS'] !== '1') throw Error('Use the explicit test:live:relay command.')
const [url, viewerFile] = process.argv.slice(2)
if (!url || !viewerFile) throw Error('Usage: test:live:relay wss://connect.routibot.com /private/path/viewer.json')
const device: Device = JSON.parse(readFileSync(viewerFile, 'utf8'))
const signal = AbortSignal.timeout(20_000)
const stream = await connectViewer(url, device, signal)
try {
  const health = await new Promise<unknown>((resolve, reject) => {
    const req = request({ host: 'routi-host', path: '/health', createConnection: () => stream, signal }, res => {
      const chunks: Buffer[] = []
      let size = 0
      res.on('data', (chunk: Buffer) => {
        size += chunk.length
        if (size > 8192) { req.destroy(Error('Unexpectedly large health response')); return }
        chunks.push(chunk)
      })
      res.on('error', reject)
      res.on('end', () => {
        try {
          assert.equal(res.statusCode, 200)
          resolve(JSON.parse(Buffer.concat(chunks).toString()))
        } catch (error) { reject(error) }
      })
    })
    req.on('error', reject)
    req.end()
  })
  assert.deepEqual(health, { ok: true, version: VERSION, protocolVersion: PROTOCOL_VERSION })
  console.log(`PASS: paired client reached Routi Core ${VERSION} through the encrypted relay (TLS ${stream.getProtocol()}).`)
} finally { stream.destroy() }
