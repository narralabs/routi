import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { createServer } from 'node:http'
import { test, type TestContext } from 'node:test'
import { WebSocketServer } from 'ws'
import type { ImageBlock } from '@routi/protocol'
import { Browser } from '../src/surfaces/browser.js'
import type { Surface } from '../src/surfaces/pool.js'
import { runDesktopTool } from '../src/surfaces/tools.js'

async function fixture(t: TestContext) {
  const calls: Array<{ method: string; params: Record<string, unknown> }> = []
  const metrics = {
    cssContentSize: { x: 0, y: 0, width: 800, height: 2400 },
    cssVisualViewport: { pageX: 0, pageY: 500, clientWidth: 800, clientHeight: 600 },
  }
  let port = 0
  let captureError = false
  const server = createServer((_req, res) => {
    res.setHeader('content-type', 'application/json')
    res.end(JSON.stringify([{ type: 'page', url: 'https://example.test', webSocketDebuggerUrl: `ws://127.0.0.1:${port}/page` }]))
  })
  const wss = new WebSocketServer({ server })
  wss.on('connection', (ws) => ws.on('message', (raw) => {
    const message = JSON.parse(String(raw))
    calls.push(message)
    const response = message.method === 'Page.captureScreenshot' && captureError
      ? { error: { message: 'Browser capture failed' } }
      : { result: message.method === 'Page.getLayoutMetrics' ? metrics : { data: Buffer.from('page pixels').toString('base64') } }
    ws.send(JSON.stringify({ id: message.id, ...response }))
  }))
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  assert.ok(address && typeof address !== 'string')
  port = address.port
  t.after(async () => {
    for (const ws of wss.clients) ws.terminate()
    await new Promise<void>((resolve) => wss.close(() => resolve()))
    server.closeAllConnections()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  })
  const surface = {
    botId: randomUUID(), cdpPort: port,
    status: async () => ({ state: 'running', width: 1024, height: 768 }),
    captureFrame: async () => { throw new Error('Browser capture must not read desktop pixels') },
  } as unknown as Surface
  return { surface, calls, metrics, failCapture: () => { captureError = true } }
}

test('browser captures use page coordinates for the current viewport and full document', async (t) => {
  const f = await fixture(t)
  const browser = new Browser(f.surface)
  const visible = await browser.screenshot()
  assert.equal(visible.width, 800)
  assert.equal(visible.height, 600)
  assert.deepEqual(f.calls[1], {
    id: 2, method: 'Page.captureScreenshot', params: {
      format: 'jpeg', quality: 90, fromSurface: true, captureBeyondViewport: false,
      clip: { x: 0, y: 500, width: 800, height: 600, scale: 1 },
    },
  })
  const full = await browser.screenshot(true)
  assert.equal(full.height, 2400)
  assert.deepEqual(f.calls[3]?.params.clip, { x: 0, y: 0, width: 800, height: 2400, scale: 1 })
  assert.equal(f.calls[3]?.params.captureBeyondViewport, true)
  assert.ok(f.calls.every((call) => ['Page.getLayoutMetrics', 'Page.captureScreenshot'].includes(call.method)))
})

test('browser screenshot attachment uses the page image and reports capture failures', async (t) => {
  const f = await fixture(t)
  const images: ImageBlock[] = []
  const context = { attachImage: (image: ImageBlock) => images.push(image) }
  const result = await runDesktopTool(f.surface, 'browser_screenshot', { fullPage: true, attach: true }, context)
  assert.equal(result.ok, true)
  assert.match(result.output, /Full loaded page is 800x2400/)
  assert.equal(images.length, 1)
  assert.equal(images[0]?.dataUrl, result.imageDataUrl)
  await runDesktopTool(f.surface, 'browser_screenshot', {}, context)
  assert.equal(images.length, 1, 'navigation captures are not attached')
  f.failCapture()
  const failed = await runDesktopTool(f.surface, 'browser_screenshot', { attach: true }, context)
  assert.equal(failed.ok, false)
  assert.match(failed.output, /Browser capture failed/)
  assert.equal(images.length, 1)
})

test('unavailable browser and oversized pages fail instead of returning desktop pixels or cropped output', async (t) => {
  const f = await fixture(t)
  await assert.rejects(new Browser({ ...f.surface, cdpPort: null } as Surface).screenshot(), /managed Chromium/)
  f.metrics.cssContentSize.height = 100_000
  await assert.rejects(new Browser(f.surface).screenshot(true), /too large/)
  assert.equal(f.calls.filter((call) => call.method === 'Page.captureScreenshot').length, 0)
})
