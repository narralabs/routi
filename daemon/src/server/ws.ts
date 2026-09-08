import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { WebSocketServer, type WebSocket } from 'ws'
import { McpHttp } from './mcp-http.js'
import { ClientMessage, PROTOCOL_VERSION, type ServerEvent, type ServerMessage } from '@routi/protocol'
import { dispatch, RpcError, type RpcContext } from './rpc.js'
import { VERSION } from '../version.js'

interface Client {
  ws: WebSocket
  name: string
  platform: string
  helloed: boolean
  /** Conversations this client is watching; scopes which events it receives. */
  subscriptions: Set<string>
}

export class RoutiServer {
  private readonly http: Server
  private readonly wss: WebSocketServer
  private readonly clients = new Set<Client>()
  /** Further listeners on other addresses — the Tailscale one — sharing the handler. */
  private readonly extra = new Map<string, Server>()
  private readonly handle: (req: IncomingMessage, res: ServerResponse) => void

  constructor(private readonly ctx: RpcContext) {
    const mcp = new McpHttp(
      ctx.desktops, ctx.store, ctx.handovers,
      (owner) => ctx.sessions.memoryChanged(owner, 'bot'),
      (botId) => ctx.sessions.routinesChanged(botId),
    )

    this.handle = (req, res) => {
      // Tools over HTTP, for harnesses that sandbox the processes they launch. Those
      // harnesses run on this Mac, so the tools answer only this Mac: a phone on the
      // tailnet may talk to its bots, not drive their screens directly.
      if (McpHttp.matches(req.url)) {
        if (!isLoopback(req.socket.remoteAddress)) {
          res.writeHead(403).end()
          return
        }
        void mcp.handle(req, res)
        return
      }
      if (req.url === '/health') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true, version: VERSION, protocolVersion: PROTOCOL_VERSION }))
        return
      }
      res.writeHead(404).end()
    }
    this.http = createServer(this.handle)
    // Not tied to one HTTP server: every listener hands its upgrades to the same socket
    // server, so a client is a client whichever address it arrived on.
    this.wss = new WebSocketServer({ noServer: true })
    this.wss.on('connection', (ws) => this.onConnection(ws))
    this.adopt(this.http)
  }

  private adopt(server: Server): void {
    server.on('upgrade', (req, socket, head) => {
      this.wss.handleUpgrade(req, socket, head, (ws) => this.wss.emit('connection', ws, req))
    })
  }

  listen(port: number, host: string): Promise<void> {
    return new Promise((resolve) => this.http.listen(port, host, resolve))
  }

  /**
   * Also answers on another address — the Tailscale one, when it appears.
   *
   * Loopback is where the core lives; the tailnet is how a phone reaches it from
   * anywhere, and only devices signed into the same tailnet can. Resolves false if
   * the address cannot be bound, which is not fatal: this Mac still has the core.
   */
  listenAlso(port: number, host: string): Promise<boolean> {
    if (this.extra.has(host)) return Promise.resolve(true)
    return new Promise((resolve) => {
      const server = createServer(this.handle)
      this.adopt(server)
      server.once('error', () => resolve(false))
      server.listen(port, host, () => {
        this.extra.set(host, server)
        resolve(true)
      })
    })
  }

  /** The addresses beyond loopback this core answers on. */
  get alsoListeningOn(): string[] {
    return [...this.extra.keys()]
  }

  async close(): Promise<void> {
    for (const c of this.clients) c.ws.close()
    await new Promise<void>((r) => this.wss.close(() => r()))
    await new Promise<void>((r) => this.http.close(() => r()))
    for (const server of this.extra.values()) await new Promise<void>((r) => server.close(() => r()))
  }

  /**
   * Fan out an event. Conversation-scoped events go only to subscribers; global ones
   * (bot changes) go to everyone, so every open window's sidebar stays correct.
   */
  broadcast = (event: ServerEvent): void => {
    const convId = conversationIdOf(event)
    for (const client of this.clients) {
      if (!client.helloed) continue
      if (convId && !client.subscriptions.has(convId)) continue
      send(client.ws, { t: 'event', event })
    }
  }

  private onConnection(ws: WebSocket): void {
    const client: Client = { ws, name: 'unknown', platform: 'probe', helloed: false, subscriptions: new Set() }
    this.clients.add(client)

    ws.on('message', (raw) => {
      void this.onMessage(client, raw.toString())
    })
    ws.on('close', () => this.clients.delete(client))
    ws.on('error', () => this.clients.delete(client))
  }

  private async onMessage(client: Client, raw: string): Promise<void> {
    let parsed: ClientMessage
    try {
      parsed = ClientMessage.parse(JSON.parse(raw))
    } catch {
      // Malformed frames are dropped rather than killing the socket; a client mid-
      // upgrade shouldn't lose its whole session to one bad message.
      return
    }

    switch (parsed.t) {
      case 'hello': {
        client.name = parsed.clientName
        client.platform = parsed.platform
        client.helloed = true
        // The handshake has to succeed with no credential configured — that is the
        // state onboarding exists to fix — so account info is best-effort here.
        const adapter = this.ctx.providers.get('anthropic-claude') ?? this.ctx.providers.get('anthropic')
        const account = (await adapter?.accountInfo()) ?? { authMode: 'subscription' as const }
        const auth = await this.ctx.auth.status()
        send(client.ws, {
          t: 'hello_ok', protocolVersion: PROTOCOL_VERSION, serverVersion: VERSION, account, auth,
        })
        break
      }

      case 'subscribe':
        client.subscriptions.add(parsed.conversationId)
        break

      case 'unsubscribe':
        client.subscriptions.delete(parsed.conversationId)
        break

      case 'rpc': {
        try {
          const result = await dispatch(parsed.method, parsed.params, this.ctx)
          send(client.ws, { t: 'rpc_ok', id: parsed.id, result })
        } catch (err) {
          const isRpc = err instanceof RpcError
          if (!isRpc) console.error(`[rpc] ${parsed.method} failed:`, err)
          send(client.ws, {
            t: 'rpc_err',
            id: parsed.id,
            error: {
              code: isRpc ? err.code : 'internal',
              message: err instanceof Error ? err.message : String(err),
            },
          })
        }
        break
      }
    }
  }
}

const isLoopback = (address: string | undefined): boolean =>
  address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1'

function conversationIdOf(event: ServerEvent): string | null {
  /**
   * Busy and error are broadcast to everyone, not just subscribers.
   *
   * Creating a bot starts its greeting immediately, before the client has had a
   * chance to subscribe to the brand-new conversation — so a scoped `busy` went to
   * nobody and the reply simply appeared with no sign anything was happening. These
   * two are also what the sidebar needs to show activity on conversations the user
   * is not currently looking at, which is the same requirement from the other side.
   */
  if (event.e === 'conversation.busy' || event.e === 'error') return null
  // Completion too: a reply finishing in a conversation the person is not looking at
  // is the one a notification is for, and a subscriber-only event never reached them.
  if (event.e === 'message.completed') return null

  if ('conversationId' in event && typeof event.conversationId === 'string') return event.conversationId
  if (event.e === 'message.created') return event.message.conversationId
  if (event.e === 'conversation.updated') return event.conversation.id
  return null
}

function send(ws: WebSocket, msg: ServerMessage): void {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg))
}
