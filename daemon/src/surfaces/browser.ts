import WebSocket from 'ws'
import type { Surface } from './pool.js'

/**
 * The page as structure, not pixels.
 *
 * Reading a screen costs about 1,400 vision tokens and returns something the model
 * has to squint at — a price misread from a JPEG is a wrong answer delivered
 * confidently. Chromium already knows what is on the page and will say so: this asks
 * it for the accessibility tree, the same source a screen reader uses, and hands the
 * model a few hundred tokens of text.
 *
 * Elements are addressed by opaque refs rather than CSS selectors or coordinates.
 * That is the whole trick. A model asked for a selector invents one; a model given
 * coordinates misses when the layout shifts. A ref is a handle to a node the page
 * itself named, valid for as long as the snapshot it came from.
 *
 * Spoken to over CDP directly rather than through Playwright: the browser is already
 * running on the bot's screen and only needs to be talked to, the tree walk is ours
 * either way, and it keeps a hundred megabytes of driver out of the daemon.
 */

interface AXNode {
  nodeId: string
  ignored?: boolean
  role?: { value?: string }
  name?: { value?: string }
  value?: { value?: string }
  childIds?: string[]
  backendDOMNodeId?: number
}

/** Roles worth putting in front of a model: things you can read or act on. */
const INTERESTING = new Set([
  'button', 'link', 'textbox', 'searchbox', 'combobox', 'checkbox', 'radio',
  'menuitem', 'tab', 'option', 'switch', 'slider', 'heading', 'listitem',
  'paragraph', 'StaticText', 'image', 'article', 'form', 'dialog', 'alert',
])

/** Roles a click or a keystroke can land on. */
const ACTIONABLE = new Set([
  'button', 'link', 'textbox', 'searchbox', 'combobox', 'checkbox', 'radio',
  'menuitem', 'tab', 'option', 'switch',
])

interface Ref {
  backendNodeId: number
  role: string
  name: string
}

/** One CDP request/response cycle over the page's WebSocket. */
class CdpSession {
  private seq = 1
  private readonly pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>()

  private constructor(private readonly ws: WebSocket) {
    ws.on('message', (raw) => {
      const msg = JSON.parse(String(raw)) as { id?: number; result?: unknown; error?: { message: string } }
      if (msg.id === undefined) return
      const waiter = this.pending.get(msg.id)
      if (!waiter) return
      this.pending.delete(msg.id)
      if (msg.error) waiter.reject(new Error(msg.error.message))
      else waiter.resolve(msg.result)
    })
  }

  static async open(wsUrl: string, timeoutMs = 10_000): Promise<CdpSession> {
    const ws = new WebSocket(wsUrl, { perMessageDeflate: false, maxPayload: 64 * 1024 * 1024 })
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Timed out connecting to the browser.')), timeoutMs)
      ws.once('open', () => { clearTimeout(timer); resolve() })
      ws.once('error', (err) => { clearTimeout(timer); reject(err) })
    })
    return new CdpSession(ws)
  }

  send<T = any>(method: string, params: Record<string, unknown> = {}, timeoutMs = 20_000): Promise<T> {
    const id = this.seq++
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`${method} timed out`))
      }, timeoutMs)
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v as T) },
        reject: (e) => { clearTimeout(timer); reject(e) },
      })
      this.ws.send(JSON.stringify({ id, method, params }))
    })
  }

  close(): void {
    this.ws.close()
  }
}

/**
 * The browser on one bot's screen.
 *
 * Refs live here, between a snapshot and the action taken against it, because that is
 * exactly how long they are meaningful: the page can change under them, so a stale
 * ref is told to take another snapshot rather than allowed to click something else.
 */
export class Browser {
  private refs = new Map<string, Ref>()

  constructor(private readonly desktop: Surface) {}

  private async pageSocket(): Promise<string | null> {
    const port = this.desktop.cdpPort
    if (port === null) return null
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/list`, {
        signal: AbortSignal.timeout(4_000),
      })
      const targets = (await res.json()) as { type: string; url: string; webSocketDebuggerUrl?: string }[]
      // The first real page, skipping devtools' own tabs and blank ones.
      const page = targets.find(
        (t) => t.type === 'page' && t.webSocketDebuggerUrl && !t.url.startsWith('devtools://'),
      )
      return page?.webSocketDebuggerUrl ?? null
    } catch {
      return null
    }
  }

  /** True when the bot's browser is up and reachable. */
  async available(): Promise<boolean> {
    return (await this.pageSocket()) !== null
  }

  private async withSession<T>(fn: (cdp: CdpSession) => Promise<T>): Promise<T> {
    const url = await this.pageSocket()
    if (!url) {
      throw new Error(
        'No page is open on this screen. Open a URL first, then take a snapshot.',
      )
    }
    const cdp = await CdpSession.open(url)
    try {
      return await fn(cdp)
    } finally {
      cdp.close()
    }
  }

  /** Capture page pixels through CDP, without desktop or browser window chrome. */
  async screenshot(fullPage = false): Promise<{ dataUrl: string; width: number; height: number }> {
    if (this.desktop.cdpPort === null) {
      throw new Error('Browser screenshots require Routi’s managed Chromium. Use desktop_screenshot for this screen.')
    }
    return this.withSession(async (cdp) => {
      const metrics = await cdp.send<{
        cssContentSize: { x: number; y: number; width: number; height: number }
        cssVisualViewport: { pageX: number; pageY: number; clientWidth: number; clientHeight: number }
      }>('Page.getLayoutMetrics')
      const view = metrics.cssVisualViewport
      const area = fullPage ? metrics.cssContentSize : {
        x: view.pageX, y: view.pageY, width: view.clientWidth, height: view.clientHeight,
      }
      const width = Math.ceil(area.width)
      const height = Math.ceil(area.height)
      // Bound allocation; never silently crop a requested full-page image.
      if (!Number.isFinite(width * height) || width <= 0 || height <= 0 ||
          width > 16_384 || height > 16_384 || width * height > 32_000_000) {
        throw new Error('This page is too large to capture in one image. Request a visible-page screenshot instead.')
      }
      const { data } = await cdp.send<{ data: string }>('Page.captureScreenshot', {
        format: 'jpeg', quality: 90, fromSurface: true,
        captureBeyondViewport: fullPage,
        clip: { x: area.x, y: area.y, width, height, scale: 1 },
      })
      if (!data) throw new Error('The browser returned an empty screenshot.')
      return { dataUrl: `data:image/jpeg;base64,${data}`, width, height }
    })
  }

  /** Navigates and waits for the load to settle enough to be worth reading. */
  async open(url: string): Promise<string> {
    return this.withSession(async (cdp) => {
      await cdp.send('Page.enable')
      await cdp.send('Page.navigate', { url }, 45_000)
      // Cheaper and steadier than racing load events: give the page a moment, then
      // let the caller take a snapshot when it wants one.
      await new Promise((r) => setTimeout(r, 1_200))
      const { result } = await cdp.send('Runtime.evaluate', {
        expression: 'document.title',
        returnByValue: true,
      })
      return String(result?.value ?? '')
    })
  }

  /**
   * The page as a ref-tagged outline.
   *
   * Deliberately flat and lossy. A full accessibility tree is thousands of nodes and
   * most of them are wrappers; what a model needs is the things it can read and the
   * things it can press, in document order, each with a handle.
   */
  async snapshot(limit = 200): Promise<string> {
    return this.withSession(async (cdp) => {
      await cdp.send('Accessibility.enable')
      const { nodes } = await cdp.send<{ nodes: AXNode[] }>('Accessibility.getFullAXTree', {}, 30_000)

      this.refs = new Map()
      const lines: string[] = []
      let seq = 0

      for (const node of nodes) {
        if (node.ignored) continue
        const role = node.role?.value ?? ''
        const name = (node.name?.value ?? '').replace(/\s+/g, ' ').trim()
        if (!INTERESTING.has(role)) continue
        if (!name && role !== 'textbox' && role !== 'searchbox') continue

        // Only things you can act on get a ref; text gets read, not clicked.
        if (ACTIONABLE.has(role) && node.backendDOMNodeId !== undefined) {
          const ref = `e${++seq}`
          this.refs.set(ref, { backendNodeId: node.backendDOMNodeId, role, name })
          const value = node.value?.value ? ` = ${JSON.stringify(node.value.value)}` : ''
          lines.push(`[ref=${ref}] ${role} ${JSON.stringify(name)}${value}`)
        } else {
          lines.push(`${role} ${JSON.stringify(name)}`)
        }
        if (lines.length >= limit) {
          lines.push(`… ${nodes.length - lines.length} more elements not shown`)
          break
        }
      }

      const { result } = await cdp.send('Runtime.evaluate', {
        expression: 'document.title + "\\n" + location.href',
        returnByValue: true,
      })
      return [String(result?.value ?? ''), '', ...lines].join('\n')
    })
  }

  /** The page's visible text, for reading rather than acting. */
  async text(limit = 8_000): Promise<string> {
    return this.withSession(async (cdp) => {
      const { result } = await cdp.send('Runtime.evaluate', {
        expression: 'document.body ? document.body.innerText : ""',
        returnByValue: true,
      })
      const text = String(result?.value ?? '').replace(/\n{3,}/g, '\n\n').trim()
      return text.length > limit ? `${text.slice(0, limit)}\n… truncated` : text
    })
  }

  async click(ref: string): Promise<string> {
    const target = this.lookup(ref)
    return this.withSession(async (cdp) => {
      const centre = await this.centreOf(cdp, target.backendNodeId)
      for (const type of ['mousePressed', 'mouseReleased'] as const) {
        await cdp.send('Input.dispatchMouseEvent', {
          type, x: centre.x, y: centre.y, button: 'left', clickCount: 1,
        })
      }
      await new Promise((r) => setTimeout(r, 400))
      return `Clicked ${target.role} ${JSON.stringify(target.name)}.`
    })
  }

  async fill(ref: string, text: string): Promise<string> {
    const target = this.lookup(ref)
    return this.withSession(async (cdp) => {
      await cdp.send('DOM.getDocument', { depth: 0 })
      await cdp.send('DOM.focus', { backendNodeId: target.backendNodeId })
      // Clearing first: filling a box that already has text otherwise appends.
      await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'a', modifiers: 2 })
      await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'a', modifiers: 2 })
      await cdp.send('Input.insertText', { text })
      return `Typed into ${target.role} ${JSON.stringify(target.name)}.`
    })
  }

  private lookup(ref: string): Ref {
    const target = this.refs.get(ref)
    if (!target) {
      throw new Error(
        `No element ${ref} in the current snapshot. Take a snapshot first — refs stop ` +
          'being valid once the page changes.',
      )
    }
    return target
  }

  private async centreOf(cdp: CdpSession, backendNodeId: number): Promise<{ x: number; y: number }> {
    await cdp.send('DOM.getDocument', { depth: 0 })
    const { model } = await cdp.send<{ model?: { content: number[] } }>('DOM.getBoxModel', {
      backendNodeId,
    })
    if (!model?.content || model.content.length < 8) {
      throw new Error('That element is not on screen. Scroll to it, or take a new snapshot.')
    }
    const [x1, y1, , , x3, y3] = model.content as number[]
    return { x: ((x1 as number) + (x3 as number)) / 2, y: ((y1 as number) + (y3 as number)) / 2 }
  }
}
