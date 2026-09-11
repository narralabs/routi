/** Capability-protected VNC transport, mounted on the core HTTP listeners. */
import { type ChildProcessWithoutNullStreams } from 'node:child_process'
import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { WebSocketServer, createWebSocketStream } from 'ws'

const assets = dirname(dirname(createRequire(import.meta.url).resolve('@novnc/novnc')))
const botID = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i

export function createVncService(options: {
  token: string
  displayFor: (bot: string) => Promise<string>
  acquireDisplay: (display: string) => Promise<{
    open: () => ChildProcessWithoutNullStreams
    release: () => void
  }>
  heartbeatMs?: number
}) {
  const prefix = `/vnc/${options.token}`
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
      const path = (req.url ?? '').split('?')[0]!
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
      const origin = req.headers.origin
      const validOrigin = typeof origin === 'string' && ['http:', 'https:'].includes(new URL(origin).protocol) && new URL(origin).host === req.headers.host
      const path = req.url ?? ''
      const bot = path.startsWith(`${prefix}/connect/`) ? path.slice(`${prefix}/connect/`.length) : ''
      if (!botID.test(bot) || !validOrigin) {
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
    prefix,
    async close() {
      closing = true
      clearInterval(heartbeat)
      for (const ws of wss.clients) ws.terminate()
      await new Promise<void>((done) => wss.close(() => done()))
      if (http.listening) await new Promise<void>((done) => http.close(() => done()))
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
let rfb, retry, stopped = false;
function connect() {
  clearTimeout(retry);
  if (stopped || document.hidden) return;
  const previous = rfb; rfb = null; previous?.disconnect();
  status.hidden = false; status.textContent = 'Connecting to desktop…';
  const connection = new RFB(document.querySelector('#screen'), (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '${prefix}/connect/${bot}');
  rfb = connection;
// noVNC 1.7.0 has no public cursor event. Keep this private hook isolated here.
// Only the native mobile viewer registers this handler; Mac behavior is unchanged.
if (window.webkit?.messageHandlers?.cursor && typeof rfb._updateCursor === 'function') {
  const updateCursor = rfb._updateCursor.bind(rfb);
  rfb._updateCursor = (rgba, hotx, hoty, w, h) => {
    updateCursor(rgba, hotx, hoty, w, h);
    if (!w || !h || w > 256 || h > 256 || !rgba.some((v, i) => i % 4 === 3 && v)) {
      window.webkit.messageHandlers.cursor.postMessage(null);
      return;
    }
    const canvas = document.createElement('canvas');
    canvas.width = w; canvas.height = h;
    canvas.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(rgba), w, h), 0, 0);
    window.webkit.messageHandlers.cursor.postMessage({png: canvas.toDataURL('image/png').split(',')[1], hotx, hoty});
  };
}
rfb.viewOnly = new URLSearchParams(location.search).get('viewOnly') === '1';
rfb.scaleViewport = true;
rfb.resizeSession = false;
rfb.qualityLevel = 6;
rfb.compressionLevel = 2;
rfb.addEventListener('connect', () => { status.hidden = true; rfb.focus(); });
rfb.addEventListener('disconnect', () => {
  if (rfb !== connection) return;
  window.webkit?.messageHandlers?.cursor?.postMessage(null);
  status.hidden = false; status.textContent = 'Desktop disconnected. Reconnecting…';
  if (!stopped && !document.hidden) retry = setTimeout(connect, 2000);
});
rfb.addEventListener('securityfailure', () => { status.hidden = false; status.textContent = 'VNC connection rejected.'; });
}
window.disconnectVNC = () => { stopped = true; clearTimeout(retry); rfb?.disconnect(); };
window.addEventListener('pagehide', window.disconnectVNC);
document.addEventListener('visibilitychange', () => {
  clearTimeout(retry);
  if (document.hidden) rfb?.disconnect(); else connect();
});
connect();
</script></body></html>`
}
