import { JsonRpcStdio, type Json, type RpcEvent } from './json-rpc-stdio.js'

export type AppServerEvent = RpcEvent

export interface CodexAppServerOptions {
  binary: string
  env: Record<string, string>
  onEvent: (event: AppServerEvent) => void
}

/**
 * `codex app-server`, spoken directly.
 *
 * The SDK's thread API only lets a caller *set* an approval policy, never answer one —
 * its event union has no approval event at all. That is fatal here, because Codex asks
 * before every call to a tool it did not bring itself, and a policy of "never" denies
 * rather than allows. Bots ended up telling users they had no browser while their
 * screen sat running. Holding the connection is what lets those questions be answered.
 */
export class CodexAppServer extends JsonRpcStdio {
  constructor(opts: CodexAppServerOptions) {
    super({ ...opts, args: ['app-server'], name: 'Codex' })
  }

  protected async handshake(): Promise<void> {
    await this.request('initialize', {
      clientInfo: { name: 'routi', title: 'Routi', version: '0.0.1' },
    })
  }

  /**
   * Routi's own tools are approved: the user granted that by giving the bot a screen,
   * and a prompt per click would make any real task unusable. Everything else is
   * declined — a bot here is not meant to be running commands or editing files on this
   * machine, so a request to do so is a mistake rather than something to wave through.
   * When there is a UI for this, it goes here.
   */
  protected answer(method: string, params: Json): { result: unknown } {
    if (method === 'mcpServer/elicitation/request') {
      const ours = params['serverName'] === 'routi'
      return { result: { action: ours ? 'accept' : 'decline', content: ours ? {} : null, _meta: null } }
    }
    if (method.endsWith('/requestApproval') || method.endsWith('Approval')) {
      return { result: { decision: 'denied' } }
    }
    // Anything unrecognised gets a shape-agnostic refusal rather than silence, which
    // would stall the turn.
    return { result: {} }
  }
}
