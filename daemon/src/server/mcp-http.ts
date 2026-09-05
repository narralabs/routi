import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Store } from '../db/store.js'
import { routineTools } from '../sessions/routine-tools.js'
import type { DesktopPool } from '../surfaces/pool.js'
import { TOOL_INSTRUCTIONS, desktopToolSpecs, runDesktopTool } from '../surfaces/tools.js'

/**
 * The same tools, over HTTP, for harnesses that sandbox what they launch.
 *
 * The stdio server runs as a child of whatever started it and inherits that process's
 * restrictions. Under Codex's seatbelt that means no Docker socket and no loopback —
 * so every call failed, and the model reported it as being denied permission to use a
 * browser, which is not what happened.
 *
 * Serving over HTTP moves the work back inside the daemon, which is not sandboxed and
 * owns the containers anyway. The harness only makes a request. That also makes this
 * the most portable delivery of the three: anything that can speak HTTP and MCP gets
 * these tools without running our code at all, which matters for a model behind a
 * harness we do not control.
 *
 * Bound to loopback with the rest of the daemon. One URL per bot, because a tool call
 * has to know whose screen it is acting on.
 */
export class McpHttp {
  constructor(
    private readonly desktops: DesktopPool,
    private readonly store: Store,
  ) {}

  /** True when this request is ours to answer. */
  static matches(url: string | undefined): boolean {
    return typeof url === 'string' && url.startsWith('/mcp/')
  }

  /**
   * Everything a bot can do here, not merely everything its screen can do.
   *
   * This was `desktopToolSpecs()` with no context, so a bot served over HTTP got the
   * nine screen verbs and nothing else — and since Codex is served this way, Codex bots
   * could not save routines. Asked to check something daily, one would try, find no such
   * tool, and tell the user it was unable to schedule anything. The tools existed; they
   * were simply never offered down this path.
   */
  private contextFor(botId: string, conversationId: string) {
    return { routines: routineTools(this.store, botId, conversationId) }
  }

  async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    // /mcp/:botId/:conversationId — a routine belongs to a bot in a conversation, so
    // both travel in the path.
    const path = (req.url ?? '').slice('/mcp/'.length).split('?')[0] ?? ''
    const [botId = '', conversationId = ''] = path.split('/').map(decodeURIComponent)
    if (!botId) return this.fail(res, 400, 'No bot in the URL.')

    if (req.method === 'GET') {
      // Some clients probe with GET before posting; say what lives here.
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ name: 'krog-desktop', botId, transport: 'streamable-http' }))
      return
    }
    if (req.method !== 'POST') return this.fail(res, 405, 'POST a JSON-RPC request.')

    const body = await this.readBody(req)
    let request: { id?: unknown; method?: string; params?: Record<string, unknown> }
    try {
      request = JSON.parse(body)
    } catch {
      return this.fail(res, 400, 'Body was not JSON.')
    }

    const result = await this.dispatch(botId, conversationId, request)
    // A notification expects no answer, and MCP says to acknowledge it with 202.
    if (result === undefined) {
      res.writeHead(202).end()
      return
    }
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ jsonrpc: '2.0', id: request.id ?? null, result }))
  }

  private async dispatch(
    botId: string,
    conversationId: string,
    request: { method?: string; params?: Record<string, unknown> },
  ): Promise<unknown> {
    switch (request.method) {
      case 'initialize':
        return {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'krog-desktop', version: '0.1.0' },
          instructions: TOOL_INSTRUCTIONS,
        }

      case 'notifications/initialized':
        return undefined

      case 'tools/list':
        return {
          tools: desktopToolSpecs(this.contextFor(botId, conversationId)).map((spec) => ({
            name: spec.name,
            description: spec.description,
            inputSchema: spec.parameters,
          })),
        }

      case 'tools/call': {
        const name = String(request.params?.['name'] ?? '')
        const args = (request.params?.['arguments'] ?? {}) as Record<string, unknown>
        try {
          const outcome = await runDesktopTool(
            this.desktops.for(botId),
            name,
            args,
            this.contextFor(botId, conversationId),
          )
          const content: unknown[] = []
          if (outcome.imageDataUrl) {
            content.push({
              type: 'image',
              data: outcome.imageDataUrl.split(',')[1] ?? '',
              mimeType: 'image/jpeg',
            })
          }
          content.push({ type: 'text', text: outcome.output })
          return { content, isError: !outcome.ok }
        } catch (err) {
          return {
            content: [{ type: 'text', text: err instanceof Error ? err.message : String(err) }],
            isError: true,
          }
        }
      }

      default:
        return { content: [{ type: 'text', text: `Unknown method: ${request.method}` }], isError: true }
    }
  }

  private readBody(req: IncomingMessage): Promise<string> {
    return new Promise((resolve) => {
      let body = ''
      req.setEncoding('utf8')
      req.on('data', (chunk) => { body += chunk })
      req.on('end', () => resolve(body))
    })
  }

  private fail(res: ServerResponse, status: number, message: string): void {
    res.writeHead(status, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ error: message }))
  }
}
