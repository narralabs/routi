/** Local, opt-in VNC experiment. Never started by routid or CI. See docs/VNC_EXPERIMENT.md. */
import { execFile, spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { promisify } from 'node:util'
import { randomBytes } from 'node:crypto'
import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { WebSocketServer, createWebSocketStream } from 'ws'
import { VncViewers } from './vnc-lifecycle.js'

const run = promisify(execFile)
const assets = dirname(dirname(createRequire(import.meta.url).resolve('@novnc/novnc')))
const botID = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i

export function createVncPreview(options: {
  token: string
  displayFor: (bot: string) => Promise<string>
  acquireDisplay: (display: string) => Promise<{
    open: () => ChildProcessWithoutNullStreams
    release: () => void
  }>
  heartbeatMs?: number
}) {
  const prefix = `/${options.token}`
  const wss = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024, perMessageDeflate: false })
  let closing = false
  const alive = new Set<import('ws').WebSocket>()
  const pending = new Set<Promise<void>>()
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!alive.delete(ws)) { ws.terminate(); continue }
      ws.ping()
    }
  }, options.heartbeatMs ?? 15_000)
  heartbeat.unref()
  const http = createServer((req, res) => {
    void (async () => {
      res.setHeader('Cache-Control', 'no-store')
      res.setHeader('Referrer-Policy', 'no-referrer')
      res.setHeader('X-Content-Type-Options', 'nosniff')
      const path = req.url ?? ''
      if (req.method !== 'GET') { res.writeHead(405).end(); return }
      if (path.startsWith(`${prefix}/viewer/`) && botID.test(path.slice(`${prefix}/viewer/`.length))) {
        const bot = path.slice(`${prefix}/viewer/`.length)
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
        res.end(viewerHTML(prefix, bot))
        return
      }
      const asset = path.startsWith(`${prefix}/assets/`) ? path.slice(`${prefix}/assets/`.length) : ''
      // Only noVNC's module tree; never serve arbitrary files or paths outside the package.
      if (!/^(core|vendor)\/[a-zA-Z0-9_./-]+\.js$/.test(asset) || asset.split('/').includes('..')) {
        res.writeHead(404).end(); return
      }
      try {
        const body = await readFile(join(assets, asset))
        res.writeHead(200, { 'Content-Type': 'text/javascript' }).end(body)
      } catch { res.writeHead(404).end() }
    })().catch(() => { if (!res.headersSent) res.writeHead(500); res.end() })
  })

  http.on('upgrade', (req, socket, head) => {
    void (async () => {
      const address = http.address()
      const origin = typeof address === 'object' && address ? `http://127.0.0.1:${address.port}` : ''
      const path = req.url ?? ''
      const bot = path.startsWith(`${prefix}/connect/`) ? path.slice(`${prefix}/connect/`.length) : ''
      if (!botID.test(bot) || req.headers.origin !== origin || req.headers.host !== origin.slice(7)) {
        socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return
      }
      if (closing) { socket.destroy(); return }
      wss.handleUpgrade(req, socket, head, (ws) => {
        alive.add(ws)
        ws.on('pong', () => alive.add(ws))
        let disposed = false
        let release: (() => void) | undefined
        let child: ChildProcessWithoutNullStreams | undefined
        let stream: ReturnType<typeof createWebSocketStream> | undefined
        const cleanup = () => {
          if (disposed) return
          disposed = true
          alive.delete(ws)
          release?.()
          child?.stdin.destroy()
          child?.kill()
          stream?.destroy()
          ws.terminate()
        }
        ws.on('close', cleanup)
        ws.on('error', cleanup)
        // Stop ws from buffering client data while Docker starts the display server.
        ws.pause()
        const setup = (async () => {
          try {
            const display = await options.displayFor(bot)
            if (disposed || closing) { cleanup(); return }
            const lease = await options.acquireDisplay(display)
            release = lease.release
            if (disposed || closing) { lease.release(); cleanup(); return }
            child = lease.open()
            stream = createWebSocketStream(ws)
            stream.on('error', cleanup)
            child.stdin.on('error', cleanup)
            child.stdout.on('error', cleanup)
            child.on('error', cleanup)
            child.on('close', cleanup)
            child.stderr.resume()
            // Backpressure preserves RFB update ordering instead of dropping rectangles.
            stream.pipe(child.stdin)
            child.stdout.pipe(stream)
            ws.resume()
          } catch { cleanup() }
        })()
        pending.add(setup)
        void setup.finally(() => pending.delete(setup))
      })
    })().catch(() => socket.destroy())
  })
  return {
    http,
    async close() {
      closing = true
      clearInterval(heartbeat)
      for (const ws of wss.clients) ws.terminate()
      await new Promise<void>((done) => wss.close(() => done()))
      await new Promise<void>((done) => http.close(() => done()))
      await Promise.allSettled(pending)
    },
  }
}

function viewerHTML(prefix: string, bot: string) {
  return `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body,#screen{margin:0;width:100%;height:100%;overflow:hidden;background:#18181b}
#status{position:absolute;top:12px;left:12px;color:white;font:14px system-ui;z-index:2}</style></head>
<body><div id="status">Connecting to desktop…</div><div id="screen"></div><script type="module">
import RFB from '${prefix}/assets/core/rfb.js';
const status = document.querySelector('#status');
const rfb = new RFB(document.querySelector('#screen'), 'ws://' + location.host + '${prefix}/connect/${bot}');
rfb.scaleViewport = true;
rfb.resizeSession = false;
rfb.qualityLevel = 6;
rfb.compressionLevel = 2;
rfb.addEventListener('connect', () => { status.hidden = true; rfb.focus(); });
rfb.addEventListener('disconnect', () => { status.hidden = false; status.textContent = 'Desktop disconnected. Switch to JPEG or reopen VNC to retry.'; });
rfb.addEventListener('securityfailure', () => { status.hidden = false; status.textContent = 'VNC connection rejected.'; });
window.addEventListener('pagehide', () => rfb.disconnect());
window.disconnectVNC = () => rfb.disconnect();
</script></body></html>`
}

async function main() {
  const docker = process.env['ROUTI_DOCKER_BIN'] ?? 'docker'
  const container = process.env['ROUTI_VNC_CONTAINER'] ?? 'routi-desktop'
  const port = Number(process.env['ROUTI_VNC_PORT'] ?? 7173)
  const token = randomBytes(24).toString('hex')
  const logPrefix = `/tmp/routi-vnc-${token}`
  const viewers = new VncViewers({
    async start(display: string) {
      const number = Number(display.slice(1))
      const log = `${logPrefix}-${number}.log`
      // XFixes supplies the real cursor shape. Do not use -noxfixes or a fixed arrow.
      await run(docker, ['exec', '-e', `DISPLAY=${display}`, container,
        'x11vnc', '-display', display, '-localhost', '-rfbport', String(15900 + number - 99),
        '-nopw', '-quiet', '-noxdamage', '-noxrecord', '-shared', '-forever', '-bg', '-o', log],
        { timeout: 10000 })
      return log
    },
    async stop(_display: string, log: string) {
      // This random log identifies only this bridge's server, not the X desktop.
      await run(docker, ['exec', container, 'pkill', '-KILL', '-f', `^x11vnc .*${log}$`], { timeout: 5000 })
        .catch((error) => { if (error.code !== 1) throw error })
      await run(docker, ['exec', container, 'rm', '-f', log], { timeout: 5000 })
    },
  })
  const server = createVncPreview({
    token,
    async displayFor(bot) {
      const { stdout } = await run(docker, ['exec', container, 'screenctl', 'live', bot], { timeout: 5000 })
      const number = Number(stdout.trim())
      if (!Number.isInteger(number) || number < 99 || number > 148) throw new Error('Desktop is not running')
      return `:${number}`
    },
    async acquireDisplay(display) {
      const lease = await viewers.acquire(display)
      return {
        release: lease.release,
        // VNC stays on container loopback; no published Docker ports.
        open: () => spawn(docker, ['exec', '-i', container, 'socat', 'STDIO',
          `TCP:127.0.0.1:${15900 + Number(display.slice(1)) - 99}`]),
      }
    },
  })
  server.http.once('error', (error) => { console.error(error.message); process.exitCode = 1 })
  server.http.listen(port, '127.0.0.1', () => {
    console.log(`VNC_PREVIEW_URL=http://127.0.0.1:${port}/${token}/viewer`)
  })
  for (const signal of ['SIGINT', 'SIGTERM'] as const) process.once(signal, () => {
    void (async () => {
      await server.close()
      await viewers.close()
    })()
  })
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) void main()
